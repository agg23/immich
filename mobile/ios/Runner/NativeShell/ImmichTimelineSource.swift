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

  private(set) var buckets: [Bucket] = []
  private(set) var total = 0

  /// Pages of assets keyed by page index. A dictionary rather than a sparse
  /// array so a reload can drop everything without resizing anything.
  private var pages: [Int: [TimelineAsset]] = [:]
  private var inFlight: Set<Int> = []
  private static let pageSize = 120

  private let channel: FlutterMethodChannel
  /// Called when the set of sections changes, or when a page lands.
  var onBucketsChanged: (() -> Void)?
  var onPageLoaded: ((Int) -> Void)?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "immich/timeline", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "invalidate", let args = call.arguments as? [String: Any] {
        self?.apply(args)
      }
      result(nil)
    }
  }

  /// Tell Dart the grid is ready. The state comes back as an `invalidate`,
  /// not as this call's reply — a reply would carry the timeline as it was
  /// when the call was made, which on a cold start is before the first bucket
  /// query has finished.
  func open() {
    channel.invokeMethod("open", arguments: nil)
  }

  private func apply(_ args: [String: Any]) {
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
    NSLog("[shell:timeline] buckets=%d total=%d", buckets.count, total)
    onBucketsChanged?()
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
    channel.invokeMethod("assets", arguments: ["index": index, "count": Self.pageSize]) { [weak self] response in
      guard let self else { return }
      self.inFlight.remove(page)
      guard let raw = response as? [[String: Any]] else { return }
      let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
      // A short answer is not a page. Dart's timeline service reports its
      // bucket counts before its asset buffer has caught up, so a request made
      // in that window comes back empty — and caching that as a loaded page
      // leaves those tiles permanently blank, because nothing ever asks again.
      guard raw.count >= expected else {
        NSLog("[shell:timeline] page=%d short (%d of %d) in %.1fms, will retry", page, raw.count, expected, ms)
        return
      }
      self.pages[page] = raw.compactMap(TimelineAsset.init)
      NSLog("[shell:timeline] page=%d assets=%d in %.1fms", page, raw.count, ms)
      self.onPageLoaded?(page)
    }
  }

  /// Which flat indices a loaded page covers, so only the visible tiles that
  /// actually gained data get reloaded.
  func range(ofPage page: Int) -> Range<Int> {
    let start = page * Self.pageSize
    return start..<min(start + Self.pageSize, total)
  }
}
