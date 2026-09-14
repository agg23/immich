import Flutter
import Photos
import UIKit

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

final class ImmichTimelineSource {
  struct Bucket {
    let date: Date?
    let count: Int
    let offset: Int
  }

  let session: Int

  private(set) var buckets: [Bucket] = []
  private(set) var total = 0

  private var pages: [Int: [TimelineAsset]] = [:]
  private var inFlight: Set<Int> = []
  private var retries: [Int: Int] = [:]
  private static let pageSize = 120
  private static let maxRetries = 12
  private static let retryDelay = 0.25

  private let channel: FlutterMethodChannel

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

  func open() {
    channel.invokeMethod("open", arguments: ["session": session])
  }

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
    pages = [:]
    inFlight = []
    retries = [:]
    shellLog("[shell:timeline] session=%d buckets=%d total=%d", session, buckets.count, total)
    for entry in observers { entry.observer.bucketsChanged() }
  }

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
      // A short answer is not a page: Dart reports bucket counts before its buffer
      // catches up, and caching that leaves those tiles blank forever.
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

  func range(ofPage page: Int) -> Range<Int> {
    let start = page * Self.pageSize
    return start..<min(start + Self.pageSize, total)
  }
}
