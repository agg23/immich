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

/// A window onto one Dart timeline. Offsets, page size and window completeness are
/// Dart's; what is left here is what a collection view needs synchronously.
final class ImmichTimelineSource {
  struct Section {
    let date: Date?
    let count: Int
    let offset: Int
  }

  let session: Int

  private(set) var sections: [Section] = []
  private(set) var total = 0

  /// A window from an older generation describes indices that have since moved.
  private(set) var generation = -1

  private var pages: [Int: [TimelineAsset]] = [:]
  private var inFlight: Set<Int> = []

  private var pageSize = 120

  private let channel: FlutterMethodChannel

  private struct Observer {
    let sectionsChanged: () -> Void
    let pageLoaded: (Int) -> Void
  }

  private var observers: [(id: ObjectIdentifier, observer: Observer)] = []

  init(session: Int, channel: FlutterMethodChannel) {
    self.session = session
    self.channel = channel
  }

  func addObserver(
    _ owner: AnyObject,
    sectionsChanged: @escaping () -> Void,
    pageLoaded: @escaping (Int) -> Void
  ) {
    let id = ObjectIdentifier(owner)
    observers.removeAll { $0.id == id }
    observers.append((id, Observer(sectionsChanged: sectionsChanged, pageLoaded: pageLoaded)))
  }

  func removeObserver(_ owner: AnyObject) {
    let id = ObjectIdentifier(owner)
    observers.removeAll { $0.id == id }
  }

  func open() {
    channel.invokeMethod("open", arguments: ["session": session])
  }

  func apply(_ args: [String: Any]) {
    sections = (args["sections"] as? [[String: Any]] ?? []).map {
      Section(
        date: ($0["date"] as? Int).map { Date(timeIntervalSince1970: Double($0) / 1000) },
        count: $0["count"] as? Int ?? 0,
        offset: $0["offset"] as? Int ?? 0
      )
    }
    total = args["total"] as? Int ?? sections.reduce(0) { $0 + $1.count }
    pageSize = args["pageSize"] as? Int ?? pageSize
    generation = args["generation"] as? Int ?? generation
    pages = [:]
    inFlight = []
    shellLog(
      "[shell:timeline] session=%d gen=%d sections=%d total=%d",
      session, generation, sections.count, total
    )
    for entry in observers { entry.observer.sectionsChanged() }
  }

  func asset(at flatIndex: Int) -> TimelineAsset? {
    guard flatIndex >= 0, flatIndex < total else { return nil }
    let page = flatIndex / pageSize
    guard let loaded = pages[page] else {
      request(page: page)
      return nil
    }
    let offset = flatIndex - page * pageSize
    return offset < loaded.count ? loaded[offset] : nil
  }

  func flatIndex(for indexPath: IndexPath) -> Int {
    guard indexPath.section < sections.count else { return 0 }
    return sections[indexPath.section].offset + indexPath.item
  }

  func indexPath(for flatIndex: Int) -> IndexPath? {
    guard let section = sections.lastIndex(where: { $0.offset <= flatIndex }) else { return nil }
    return IndexPath(item: flatIndex - sections[section].offset, section: section)
  }

  func prefetch(around flatIndex: Int) {
    request(page: flatIndex / pageSize)
  }

  func range(ofPage page: Int) -> Range<Int> {
    let start = page * pageSize
    return start..<min(start + pageSize, total)
  }

  private func request(page: Int) {
    guard !inFlight.contains(page), pages[page] == nil else { return }
    inFlight.insert(page)
    let asked = generation
    let started = CFAbsoluteTimeGetCurrent()
    channel.invokeMethod(
      "window",
      arguments: ["session": session, "start": page * pageSize, "count": pageSize]
    ) { [weak self] response in
      guard let self else { return }
      self.inFlight.remove(page)
      guard let reply = response as? [String: Any],
            let raw = reply["assets"] as? [[String: Any]] else { return }
      let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
      let served = reply["generation"] as? Int ?? -1
      guard served == asked, served == self.generation else {
        shellLog(
          "[shell:timeline] session=%d page=%d from gen %d, now %d: dropped",
          self.session, page, served, self.generation
        )
        return
      }
      self.pages[page] = raw.compactMap(TimelineAsset.init)
      shellLog("[shell:timeline] session=%d page=%d assets=%d in %.1fms", self.session, page, raw.count, ms)
      for entry in self.observers { entry.observer.pageLoaded(page) }
    }
  }
}
