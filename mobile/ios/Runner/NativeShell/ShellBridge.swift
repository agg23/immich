import Flutter
import UIKit

final class ShellBridge {
  static let shared = ShellBridge()

  enum AuthState {
    case unknown
    case signedOut
    case signedIn
  }

  private(set) var authState: AuthState = .unknown
  var onAuthStateChange: ((AuthState) -> Void)?

  /// Declared by Dart: order is identity across the channel, and labels are localised.
  private(set) var tabs: [ShellTab] = []

  private(set) var searchPlaceholder: String?
  var onSearchPlaceholderChange: ((String?) -> Void)?
  var onSearchTextChange: ((String) -> Void)?

  var channel: FlutterMethodChannel?
  private var dartIsReady = false

  var isReady: Bool { dartIsReady }
  private var pendingRoute: String?
  private var pendingSettle: ((String) -> Void)?

  func attach(to engine: FlutterEngine) {
    let channel = FlutterMethodChannel(name: "immich/shell", binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call)
      result(nil)
    }
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "ready":
      dartIsReady = true
      tabs = (args["tabs"] as? [[String: Any]] ?? []).compactMap(ShellTab.init)
      shellLog("[shell] dart ready, tabs=[%@]", tabs.map(\.id).joined(separator: ","))
      if let route = pendingRoute {
        pendingRoute = nil
        let settle = pendingSettle ?? { _ in }
        pendingSettle = nil
        send(route: route, whenSettled: settle)
      }
      scheduleDebugHooks()
    case "auth":
      let signedIn = args["signedIn"] as? Bool ?? false
      let next: AuthState = signedIn ? .signedIn : .signedOut
      guard next != authState else { return }
      authState = next
      shellLog("[shell] auth signedIn=%@", signedIn ? "yes" : "no")
      onAuthStateChange?(next)
    case "route":
      shellLog("[shell] dart route=%@", args["name"] as? String ?? "?")
    case "openViewer":
      openViewer(
        session: args["session"] as? Int ?? TimelineSessions.mainSession,
        index: args["index"] as? Int ?? 0
      )
    case "log":
      shellLog("[shell:dart] %@", args["text"] as? String ?? "?")
    case "search":
      if let placeholder = args["placeholder"] as? String {
        searchPlaceholder = placeholder
        onSearchPlaceholderChange?(placeholder)
      }
      if let text = args["text"] as? String {
        onSearchTextChange?(text)
      }
    case "barCollapsed":
      let route = args["route"] as? String ?? ""
      let collapsed = args["collapsed"] as? Bool ?? false
      frame(named: route)?.setCollapsed(collapsed)
    case "sync":
      let routes = (args["routes"] as? [[String: Any]] ?? []).map {
        MirrorFrame(
          name: $0["name"] as? String ?? "?",
          title: $0["title"] as? String,
          actions: $0["actions"] as? [[String: Any]] ?? [],
          hero: $0["hero"] as? Bool ?? false
        )
      }
      let tab = args["tab"] as? String ?? ""
      if args["claimTab"] as? Bool ?? false {
        selectIfNeeded(tab: tab)
      }
      applyTabBars(args["tabBars"] as? [String: [String: Any]] ?? [:])
      reconcile(to: routes, tab: tab)
      ShellEngine.shared.dartIsShowing(
        args["surface"] as? String ?? "",
        overlay: args["overlay"] as? Bool ?? false
      )
    default:
      shellLog("[shell] unhandled dart call %@", call.method)
    }
  }


  private func openViewer(session: Int, index: Int) {
    guard let nav = activeNavigationController else {
      shellLog("[shell:nav] viewer at %ld with no native stack to put it in", index)
      return
    }
    guard let source = TimelineSessions.shared.source(for: session) else { return }
    let viewer = AssetViewerController(source: source, startIndex: index)
    viewer.onClosed = {
      TimelineSessions.shared.close(session: session)
    }
    shellLog("[shell:nav] native viewer at %ld on session %ld over %@", index, session, describe(nav))
    nav.pushViewController(viewer, animated: true)
  }


  /// Setting `UITabBarController.tabs` retires `viewControllers` and `selectedIndex`,
  /// so every lookup goes through the shell rather than the tab bar itself.
  private var shell: NativeShellController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
      .first
    return root as? NativeShellController
  }

  var activeNavigationController: UINavigationController? { shell?.activeNavigationController }

  private func selectIfNeeded(tab: String) {
    guard let shell, shell.selectedTabId != tab else { return }
    shellLog("[shell:nav] dart moved to %@", tab)
    shell.select(tabId: tab)
  }

  /// A tab's root is not a stack frame, so its bar arrives separately.
  private func applyTabBars(_ bars: [String: [String: Any]]) {
    for (tab, bar) in bars {
      guard let host = navigationController(forTab: tab)?.viewControllers.first as? FlutterTabController else {
        continue
      }
      host.barRoute = bar["name"] as? String ?? tab
      host.apply(title: bar["title"] as? String, actions: bar["actions"] as? [[String: Any]] ?? [])
    }
  }

  private func navigationController(forTab tab: String) -> UINavigationController? {
    shell?.navigationController(forTab: tab)
  }

  private func frame(named route: String) -> FlutterStackController? {
    activeNavigationController?.viewControllers
      .compactMap { $0 as? FlutterStackController }
      .first { $0.shellLabel == route }
  }

  struct MirrorFrame {
    let name: String
    let title: String?
    let actions: [[String: Any]]
    let hero: Bool
  }

  private func reconcile(to frames: [MirrorFrame], tab: String) {
    guard let nav = navigationController(forTab: tab) else {
      shellLog("[shell:nav] sync [%@] with no native stack to put it in", frames.map(\.name).joined(separator: ","))
      return
    }
    let current = nav.viewControllers
    if (current.last as? AssetViewerController) != nil {
      shellLog("[shell:nav] sync [%@] under the native viewer, ignored", frames.map(\.name).joined(separator: ","))
      return
    }
    let base = current.prefix { !($0 is FlutterStackController) }
    let existing = current.compactMap { $0 as? FlutterStackController }

    var shared = 0
    while shared < existing.count, shared < frames.count, existing[shared].shellLabel == frames[shared].name {
      shared += 1
    }

    for (index, frame) in frames.prefix(shared).enumerated() {
      existing[index].apply(title: frame.title, actions: frame.actions, hero: frame.hero)
    }

    guard shared != existing.count || shared != frames.count else { return }

    for frame in existing.dropFirst(shared) {
      frame.suppressDartPop = true
    }

    var target: [UIViewController] = Array(base) + Array(existing.prefix(shared))
    for frame in frames.dropFirst(shared) {
      let controller = FlutterStackController(label: frame.name, nativeTitle: frame.title)
      controller.apply(title: frame.title, actions: frame.actions, hero: frame.hero)
      target.append(controller)
    }

    shellLog(
      "[shell:nav] sync %@ -> [%@]",
      describe(nav),
      target.map { ($0 as? ShellFlutterHost)?.shellLabel ?? "?" }.joined(separator: ",")
    )

    if target.count == current.count + 1, shared == existing.count, let pushed = target.last {
      nav.pushViewController(pushed, animated: true) // One added on top.
    } else if target.count < current.count, shared == frames.count {
      nav.setViewControllers(target, animated: true) // Removed from the top.
    } else {
      nav.setViewControllers(target, animated: false)
    }

    if target.count > current.count {
      scheduleDebugPop(on: nav)
    }
  }

  func describe(_ nav: UINavigationController) -> String {
    let labels = nav.viewControllers.map { ($0 as? ShellFlutterHost)?.shellLabel ?? String(describing: type(of: $0)) }
    return "[\(labels.joined(separator: ","))]"
  }

  func requestSync() {
    channel?.invokeMethod("resync", arguments: nil)
  }

  func requestDartPop(route: String) {
    channel?.invokeMethod("popFromNative", arguments: ["name": route])
  }

  func barAction(route: String, index: Int, item: Int) {
    channel?.invokeMethod("barAction", arguments: ["route": route, "index": index, "item": item])
  }

  func submitSearch(_ text: String) {
    shellLog("[shell] search submit %@", text.isEmpty ? "(cleared)" : text)
    channel?.invokeMethod("searchSubmitted", arguments: ["text": text])
  }

  func popToRoot(tab: String) {
    channel?.invokeMethod("popToRoot", arguments: ["tab": tab])
  }


  private var reportedInsets: UIEdgeInsets?

  func report(insets: UIEdgeInsets) {
    guard reportedInsets != insets else { return }
    reportedInsets = insets
    channel?.invokeMethod(
      "insets",
      arguments: [
        "top": Double(insets.top),
        "bottom": Double(insets.bottom),
        "left": Double(insets.left),
        "right": Double(insets.right),
      ]
    )
    shellLog("[shell] insets top=%.0f bottom=%.0f", insets.top, insets.bottom)
  }

  func show(route: String, whenSettled: @escaping (String) -> Void) {
    guard dartIsReady else {
      pendingRoute = route
      pendingSettle = whenSettled
      return
    }
    send(route: route, whenSettled: whenSettled)
  }

  private func send(route: String, whenSettled: @escaping (String) -> Void) {
    shellLog("[shell] show route=%@", route)
    guard let channel else {
      whenSettled("")
      return
    }
    channel.invokeMethod("show", arguments: ["route": route]) { reply in
      whenSettled((reply as? [String: Any])?["surface"] as? String ?? "")
    }
  }

  func capture(_ completion: @escaping (UIImage?) -> Void) {
    guard dartIsReady, let channel else {
      completion(nil)
      return
    }
    channel.invokeMethod("capture", arguments: nil) { reply in
      guard let data = reply as? FlutterStandardTypedData else {
        completion(nil)
        return
      }
      completion(UIImage(data: data.data, scale: 1))
    }
  }
}
