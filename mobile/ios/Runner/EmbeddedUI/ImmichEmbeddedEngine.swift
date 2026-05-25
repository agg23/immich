import Combine
import Flutter
import Foundation

final class ImmichEmbeddedEngine: NSObject, ObservableObject {
  static let shared = ImmichEmbeddedEngine()

  let engine = FlutterEngine(name: "ImmichEmbedded")
  let flutterApi: EmbeddedFlutterApi
  let timelineApi: TimelineFlutterApi

  @Published private(set) var isFlutterReady = false
  @Published private(set) var lastError: String?
  @Published private(set) var isAuthenticated = false
  @Published private(set) var embeddedCanPop = false
  @Published private(set) var embeddedTitle = "Settings"

  var requestNativePop: (() -> Void)?
  var didAuthenticate: (() -> Void)?

  private var hasStarted = false

  private override init() {
    flutterApi = EmbeddedFlutterApi(binaryMessenger: engine.binaryMessenger)
    timelineApi = TimelineFlutterApi(binaryMessenger: engine.binaryMessenger)
    super.init()
  }

  @discardableResult
  func start() -> Bool {
    if hasStarted {
      return true
    }

    NSLog("[EmbeddedUI] starting Flutter engine")
    let isRunning = engine.run(
      withEntrypoint: "embeddedForegroundEntrypoint",
      libraryURI: "package:immich_mobile/embedded_entrypoint.dart"
    )

    guard isRunning else {
      lastError = "Failed to start embedded Flutter engine"
      NSLog("[EmbeddedUI] failed to start Flutter engine")
      return false
    }

    hasStarted = true
    GeneratedPluginRegistrant.register(with: engine)
    AppDelegate.registerPlugins(with: engine, messenger: engine.binaryMessenger)
    EmbeddedHostApiSetup.setUp(binaryMessenger: engine.binaryMessenger, api: self)
    TimelineHostApiSetup.setUp(binaryMessenger: engine.binaryMessenger, api: EmbeddedTimelineHostApi())
    NSLog("[EmbeddedUI] Flutter engine started")
    return true
  }

  func navigate(to routeName: String, args: [String: Any?] = [:], completion: ((Bool) -> Void)? = nil) {
    NSLog("[EmbeddedUI] navigateTo \(routeName)")
    flutterApi.navigateTo(routeName: routeName, args: args) { [weak self] result in
      DispatchQueue.main.async {
        switch result {
        case .success:
          completion?(true)
        case .failure(let error):
          self?.lastError = "Failed to navigate to \(routeName): \(error)"
          NSLog("[EmbeddedUI] navigateTo failed: \(error)")
          completion?(false)
        }
      }
    }
  }

  func maybePop(completion: @escaping (Bool) -> Void) {
    NSLog("[EmbeddedUI] maybePop")
    flutterApi.maybePop { [weak self] result in
      DispatchQueue.main.async {
        switch result {
        case .success(let didPop):
          completion(didPop)
        case .failure(let error):
          self?.lastError = "Failed to pop embedded Flutter route: \(error)"
          NSLog("[EmbeddedUI] maybePop failed: \(error)")
          completion(false)
        }
      }
    }
  }

  func resetToRoot(completion: ((Bool) -> Void)? = nil) {
    NSLog("[EmbeddedUI] resetToRoot")
    flutterApi.resetToRoot { [weak self] result in
      DispatchQueue.main.async {
        switch result {
        case .success:
          completion?(true)
        case .failure(let error):
          self?.lastError = "Failed to reset embedded Flutter route: \(error)"
          NSLog("[EmbeddedUI] resetToRoot failed: \(error)")
          completion?(false)
        }
      }
    }
  }

  func setEmbeddedMode(hideChrome: Bool) {
    NSLog("[EmbeddedUI] setEmbeddedMode hideChrome=\(hideChrome)")
    flutterApi.setEmbeddedMode(hideChrome: hideChrome) { [weak self] result in
      if case .failure(let error) = result {
        self?.lastError = "Failed to set embedded mode: \(error)"
        NSLog("[EmbeddedUI] setEmbeddedMode failed: \(error)")
      }
    }
  }
}

extension ImmichEmbeddedEngine: EmbeddedHostApi {
  func onFlutterReady() throws {
    NSLog("[EmbeddedUI] onFlutterReady")
    DispatchQueue.main.async {
      self.isFlutterReady = true
    }
  }

  func onRequestPop() throws {
    NSLog("[EmbeddedUI] onRequestPop")
    DispatchQueue.main.async {
      self.requestNativePop?()
    }
  }

  func onAuthChanged(isAuthenticated: Bool) throws {
    NSLog("[EmbeddedUI] onAuthChanged \(isAuthenticated)")
    DispatchQueue.main.async {
      let wasAuthenticated = self.isAuthenticated
      self.isAuthenticated = isAuthenticated
      if isAuthenticated && !wasAuthenticated {
        self.didAuthenticate?()
      }
    }
  }

  func onRouteStateChanged(canPop: Bool, title: String) throws {
    NSLog("[EmbeddedUI] onRouteStateChanged canPop=\(canPop) title=\(title)")
    DispatchQueue.main.async {
      self.embeddedCanPop = canPop
      self.embeddedTitle = title.isEmpty ? "Settings" : title
    }
  }
}

final class EmbeddedTimelineHostApi: TimelineHostApi {
  func onTimelineChanged() throws {
    NSLog("[EmbeddedUI] onTimelineChanged")
  }

  func onAssetsChanged(assetIds: [String]) throws {
    NSLog("[EmbeddedUI] onAssetsChanged count=\(assetIds.count)")
  }
}
