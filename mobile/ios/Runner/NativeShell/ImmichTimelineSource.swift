import Flutter
import Photos
import UIKit

/// One tile's worth of Immich's timeline, as described by Dart.
struct TimelineAsset {
  let name: String
  let localId: String?
  let remoteId: String?
  let isVideo: Bool
  let durationMs: Int?
  let createdAt: Date
  let isFavorite: Bool
  let thumbURL: URL?
  let previewURL: URL?
  let originalURL: URL?

  init?(_ raw: [String: Any]) {
    guard let name = raw["name"] as? String else { return nil }
    self.name = name
    localId = raw["localId"] as? String
    remoteId = raw["remoteId"] as? String
    isVideo = raw["isVideo"] as? Bool ?? false
    durationMs = raw["durationMs"] as? Int
    createdAt = Date(timeIntervalSince1970: Double(raw["createdAt"] as? Int ?? 0) / 1000)
    isFavorite = raw["isFavorite"] as? Bool ?? false
    thumbURL = (raw["thumbUrl"] as? String).flatMap(URL.init(string:))
    previewURL = (raw["previewUrl"] as? String).flatMap(URL.init(string:))
    originalURL = (raw["originalUrl"] as? String).flatMap(URL.init(string:))
  }
}

/// The native timeline's data source, backed by Immich's `TimelineService`.
///
/// Dart owns the query; this owns the window. The collection view asks for a
/// flat index, which is resolved against the bucket list into a section and an
/// item, and the assets themselves arrive in pages over the channel — the same
/// windowed access pattern the Flutter timeline uses, for the same reason.
final class ImmichTimelineSource {
  struct Bucket {
    let date: Date?
    let count: Int
    /// Flat index of this bucket's first asset.
    let offset: Int
  }

  /// Which of Dart's timelines this is.
  ///
  /// Immich's timeline is not one query. The grid shows the main timeline, but
  /// a viewer opened from an album, a person or a search is looking at a
  /// different `TimelineService` with its own buckets and its own flat indices.
  /// Dart numbers those; a source is one session's view of one of them.
  let session: Int

  private(set) var buckets: [Bucket] = []
  private(set) var total = 0

  /// Pages of assets keyed by page index. A dictionary rather than a sparse
  /// array so a reload can drop everything without resizing anything.
  private var pages: [Int: [TimelineAsset]] = [:]
  private var inFlight: Set<Int> = []
  /// How many times a page has come back short. See [request].
  private var retries: [Int: Int] = [:]
  private static let pageSize = 120
  private static let maxRetries = 12
  private static let retryDelay = 0.25

  private let channel: FlutterMethodChannel

  /// Who wants to hear about it. Two single closures would have been enough
  /// while the grid was the only consumer, and stopped being enough the moment
  /// a viewer could share the main timeline with it -- the second assignment
  /// silently unsubscribed the first.
  private struct Observer {
    let bucketsChanged: () -> Void
    let pageLoaded: (Int) -> Void
  }

  private var observers: [(id: ObjectIdentifier, observer: Observer)] = []

  init(session: Int, channel: FlutterMethodChannel) {
    self.session = session
    self.channel = channel
  }

  func addObserver(
    _ owner: AnyObject,
    bucketsChanged: @escaping () -> Void,
    pageLoaded: @escaping (Int) -> Void
  ) {
    let id = ObjectIdentifier(owner)
    observers.removeAll { $0.id == id }
    observers.append((id, Observer(bucketsChanged: bucketsChanged, pageLoaded: pageLoaded)))
  }

  func removeObserver(_ owner: AnyObject) {
    let id = ObjectIdentifier(owner)
    observers.removeAll { $0.id == id }
  }

  /// Tell Dart the grid is ready. The state comes back as an `invalidate`,
  /// not as this call's reply — a reply would carry the timeline as it was
  /// when the call was made, which on a cold start is before the first bucket
  /// query has finished.
  func open() {
    channel.invokeMethod("open", arguments: ["session": session])
  }

  /// Called by [TimelineSessions], which owns the channel and routes each
  /// `invalidate` to the session it names.
  func apply(_ args: [String: Any]) {
    let raw = args["buckets"] as? [[String: Any]] ?? []
    var offset = 0
    var next: [Bucket] = []
    next.reserveCapacity(raw.count)
    for entry in raw {
      let count = entry["count"] as? Int ?? 0
      let date = (entry["date"] as? Int).map { Date(timeIntervalSince1970: Double($0) / 1000) }
      next.append(Bucket(date: date, count: count, offset: offset))
      offset += count
    }
    buckets = next
    total = args["total"] as? Int ?? offset
    // Any bucket change can move every asset's flat index, so cached pages are
    // no longer addressable. Dropping them is correct and cheap; keeping them
    // would show the wrong photo under the right date.
    pages = [:]
    inFlight = []
    retries = [:]
    shellLog("[shell:timeline] session=%d buckets=%d total=%d", session, buckets.count, total)
    for entry in observers { entry.observer.bucketsChanged() }
  }

  /// The asset at a flat index, if its page is already loaded. Requests the
  /// page if not.
  func asset(at flatIndex: Int) -> TimelineAsset? {
    guard flatIndex >= 0, flatIndex < total else { return nil }
    let page = flatIndex / Self.pageSize
    guard let loaded = pages[page] else {
      request(page: page)
      return nil
    }
    let offset = flatIndex - page * Self.pageSize
    return offset < loaded.count ? loaded[offset] : nil
  }

  func flatIndex(for indexPath: IndexPath) -> Int {
    guard indexPath.section < buckets.count else { return 0 }
    return buckets[indexPath.section].offset + indexPath.item
  }

  func indexPath(for flatIndex: Int) -> IndexPath? {
    guard let section = buckets.lastIndex(where: { $0.offset <= flatIndex }) else { return nil }
    return IndexPath(item: flatIndex - buckets[section].offset, section: section)
  }

  func prefetch(around flatIndex: Int) {
    request(page: flatIndex / Self.pageSize)
  }

  private func request(page: Int) {
    guard !inFlight.contains(page), pages[page] == nil else { return }
    inFlight.insert(page)
    let index = page * Self.pageSize
    let started = CFAbsoluteTimeGetCurrent()
    let expected = min(Self.pageSize, total - index)
    channel.invokeMethod(
      "assets",
      arguments: ["session": session, "index": index, "count": Self.pageSize]
    ) { [weak self] response in
      guard let self else { return }
      self.inFlight.remove(page)
      guard let raw = response as? [[String: Any]] else { return }
      let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
      // A short answer is not a page. Dart's timeline service reports its
      // bucket counts before its asset buffer has caught up, so a request made
      // in that window comes back empty — and caching that as a loaded page
      // leaves those tiles permanently blank, because nothing ever asks again.
      //
      // "Nothing ever asks again" is the whole problem, and this used to say
      // "will retry" without retrying: the grid got away with it because
      // scrolling re-asks, and a viewer pushed straight onto a timeline that
      // has just been created does not scroll and stayed blank forever.
      guard raw.count >= expected else {
        let attempt = (self.retries[page] ?? 0) + 1
        self.retries[page] = attempt
        shellLog(
          "[shell:timeline] session=%d page=%d short (%d of %d) in %.1fms, retry %d",
          self.session, page, raw.count, expected, ms, attempt
        )
        guard attempt <= Self.maxRetries else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
          self?.request(page: page)
        }
        return
      }
      self.retries[page] = nil
      self.pages[page] = raw.compactMap(TimelineAsset.init)
      shellLog("[shell:timeline] session=%d page=%d assets=%d in %.1fms", self.session, page, raw.count, ms)
      for entry in self.observers { entry.observer.pageLoaded(page) }
    }
  }

  /// Which flat indices a loaded page covers, so only the visible tiles that
  /// actually gained data get reloaded.
  func range(ofPage page: Int) -> Range<Int> {
    let start = page * Self.pageSize
    return start..<min(start + Self.pageSize, total)
  }
}
