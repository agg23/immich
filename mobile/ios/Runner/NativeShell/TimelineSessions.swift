import Flutter

final class TimelineSessions {
  static let shared = TimelineSessions()

  static let mainSession = 0

  private var channel: FlutterMethodChannel?
  private var sources: [Int: ImmichTimelineSource] = [:]

  func attach(to engine: FlutterEngine) {
    let channel = FlutterMethodChannel(name: "immich/timeline", binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "invalidate", let args = call.arguments as? [String: Any] {
        let session = args["session"] as? Int ?? Self.mainSession
        self?.source(for: session)?.apply(args)
      }
      result(nil)
    }
    self.channel = channel
  }

  func source(for session: Int) -> ImmichTimelineSource? {
    if let existing = sources[session] {
      return existing
    }
    guard let channel else {
      shellLog("[shell:timeline] session %d before the engine; dropped", session)
      return nil
    }
    let source = ImmichTimelineSource(session: session, channel: channel)
    sources[session] = source
    return source
  }

  func close(session: Int) {
    guard session != Self.mainSession, sources.removeValue(forKey: session) != nil else { return }
    shellLog("[shell:timeline] session %d closed", session)
    channel?.invokeMethod("closeSession", arguments: ["session": session])
  }
}
