import Flutter
import UIKit

/// The native shell's channel to Immich's router.
///
/// The shell replaces `TabShellPage`: the tab bar is a real `UITabBar` and
/// each tab tells Dart which of Immich's routes to show. Immich's routing is
/// `AutoRoute` all the way down, so the shell does not navigate — it names a
/// destination and Dart's router does the work. Anything Dart pushes on top
/// (an asset viewer, a settings page) still happens entirely in Flutter, and
/// the shell only needs to know when that content wants the whole screen.
final class ShellBridge {
  static let shared = ShellBridge()

  /// Immich decides whether you are logged in in Dart: `SplashScreenRoute`
  /// resolves to the login page or the tab shell. The native shell therefore
  /// cannot draw a tab bar at launch — it does not yet know if there is
  /// anything behind it. It shows the Flutter surface full screen until Dart
  /// says otherwise.
  enum AuthState {
    case unknown
    case signedOut
    case signedIn
  }

  private(set) var authState: AuthState = .unknown
  var onAuthStateChange: ((AuthState) -> Void)?

  private var channel: FlutterMethodChannel?
  private var dartIsReady = false

  /// Whether Dart is far enough along to answer a settle request.
  var isReady: Bool { dartIsReady }
  /// A route named before Dart could listen. The shell claims the engine in
  /// `viewWillAppear`, which happens well before the first Dart frame.
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
      shellLog("[shell] dart ready")
      if let route = pendingRoute {
        pendingRoute = nil
        let settle = pendingSettle ?? { _ in }
        pendingSettle = nil
        send(route: route, whenSettled: settle)
      }
      scheduleDebugNativePage()
      scheduleDebugDartTab()
      scheduleDebugBarAction()
      if let name = UserDefaults.standard.string(forKey: "immichShellPushRoute") {
        // `-immichShellPushDelay <ms>` holds the push back, so it can be made
        // to happen after a tab switch rather than at launch.
        let delay = Double(UserDefaults.standard.integer(forKey: "immichShellPushDelay")) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          shellLog("[shell:nav] asking dart to push %@", name)
          self.channel?.invokeMethod("debugPush", arguments: ["name": name])
        }
      }
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
      // Dart's own diagnostics, through NSLog so the two sides appear in one
      // ordered stream. `debugPrint` does not reach the device console at all,
      // which is how a routing race stayed invisible.
      shellLog("[shell:dart] %@", args["text"] as? String ?? "?")
    case "barCollapsed":
      // Addressed by route rather than by position: a scroll is not a routing
      // event and the stack may have moved under it.
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
      reconcile(to: routes, tab: tab)
      // After the stack, because reconciling may create the very container the
      // surface now belongs in.
      ShellEngine.shared.dartIsShowing(
        args["surface"] as? String ?? "",
        overlay: args["overlay"] as? Bool ?? false
      )
    default:
      shellLog("[shell] unhandled dart call %@", call.method)
    }
  }

  // MARK: - The asset viewer

  /// Open the native viewer in place of Immich's Flutter one.
  ///
  /// Dart never pushes `AssetViewerRoute` under the shell: a guard intercepts
  /// it and calls this instead. So there is no mirrored frame for the viewer
  /// and nothing for [reconcile] to reconcile, which is the whole reason this
  /// is a call rather than another kind of frame. The viewer is not a Flutter
  /// route being decorated natively -- it is a native screen that has replaced
  /// one, and the stack Dart reports is the same before and after.
  ///
  /// It also sidesteps the thing that made the Flutter viewer awkward to mirror
  /// at all: that route is `opaque: false`, a layer over the page it was opened
  /// from rather than a frame on top of it, and giving a layer a native frame
  /// played both transitions at once.
  private func openViewer(session: Int, index: Int) {
    guard let nav = activeNavigationController else {
      shellLog("[shell:nav] viewer at %ld with no native stack to put it in", index)
      return
    }
    guard let source = TimelineSessions.shared.source(for: session) else { return }
    let viewer = AssetViewerController(source: source, startIndex: index)
    viewer.onClosed = {
      // Dart is holding a subscription to that page's timeline for as long as
      // this viewer is up. Nothing else will tell it the viewer is gone: the
      // route was never pushed, so no pop is coming.
      TimelineSessions.shared.close(session: session)
    }
    shellLog("[shell:nav] native viewer at %ld on session %ld over %@", index, session, describe(nav))
    // No zoom flight: the push does not start from a native tile. The grid's
    // transition delegate declines anything that is not coming from the grid
    // itself, so this correctly gets the system push.
    nav.pushViewController(viewer, animated: true)
  }

  // MARK: - Stack mirroring

  /// The navigation controller the mirrored stack lives in: whichever tab is
  /// selected. A route pushed while the albums tab is front belongs on the
  /// albums tab, and coming back to that tab should still show it — which is
  /// what a per-tab stack gives for free and a single global stack would not.
  private var tabBarController: UITabBarController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
      .first
    return (root as? ShellRootController)?.currentChild as? UITabBarController
  }

  private var activeNavigationController: UINavigationController? {
    tabBarController?.selectedViewController as? UINavigationController
  }

  /// Follow a tab change Dart made on its own.
  ///
  /// The other direction has been wired since the tab bar started announcing
  /// taps, but nothing carried a Dart-initiated switch the other way, so
  /// "view in timeline" moved Dart to the photos tab and left the tab bar
  /// sitting on Memories. The sync already names its tab for addressing; this
  /// just also believes it.
  ///
  /// Only called for a sync that *claims* the tab. Every sync names one, but a
  /// name is not a request: most syncs report the stack of whatever tab is
  /// current, and acting on those reverses a tap that has not reached Dart yet
  /// — the same unaddressed-instruction failure as reconciling into the
  /// selected tab instead of the named one, in the other direction. Dart knows
  /// which of its syncs are assertions because it knows which tab native last
  /// announced, so it says so and this believes only that.
  private func selectIfNeeded(tab: String) {
    guard let shell = tabBarController,
          let index = NativeShellController.Tab.allCases.firstIndex(where: { $0.rawValue == tab }),
          index < (shell.viewControllers?.count ?? 0),
          shell.selectedIndex != index else { return }
    shellLog("[shell:nav] dart moved to %@", tab)
    shell.selectedIndex = index
  }

  /// The navigation controller belonging to a named tab.
  ///
  /// A sync describes one tab's stack, and it has to be applied to *that* tab.
  /// Reconciling into whichever tab is selected when the message lands is an
  /// unaddressed instruction, and it fails the same way the unaddressed pops
  /// did: the native selection changes before Dart answers, so a stack computed
  /// for the tab you left was pushed into the tab you were entering — two
  /// stacks animating at once for something neither of them asked for.
  private func navigationController(forTab tab: String) -> UINavigationController? {
    guard let shell = tabBarController else { return nil }
    guard !tab.isEmpty, let index = NativeShellController.Tab.allCases.firstIndex(where: { $0.rawValue == tab }),
          index < (shell.viewControllers?.count ?? 0) else {
      return activeNavigationController
    }
    return shell.viewControllers?[index] as? UINavigationController
  }

  /// The mirrored frame for a route, wherever it is in the active stack.
  private func frame(named route: String) -> FlutterStackController? {
    activeNavigationController?.viewControllers
      .compactMap { $0 as? FlutterStackController }
      .first { $0.shellLabel == route }
  }

  struct MirrorFrame {
    let name: String
    let title: String?
    /// The page's own app bar actions, already reduced by Dart to a symbol or a
    /// label. A page whose header could not be translated sends none and keeps
    /// its Flutter header instead, so an empty list here is not "no actions" --
    /// it is "this page is not using the native bar".
    let actions: [[String: Any]]
    /// A page whose header is a cover photo. Its bar floats over the page
    /// instead of sitting above it.
    let hero: Bool
  }

  /// Make the native stack agree with the stack Dart just described.
  ///
  /// Dart sends the whole stack rather than a change, so this is the only place
  /// frames are created or removed, and it is idempotent: whatever the native
  /// stack currently is, it ends up matching. That is the property the previous
  /// delta mirror did not have — one dropped or doubled message left the two
  /// sides off by one for good, and every later pop then had no frame behind
  /// it, which is how a back tap ended up switching tabs.
  private func reconcile(to frames: [MirrorFrame], tab: String) {
    guard let nav = navigationController(forTab: tab) else {
      shellLog("[shell:nav] sync [%@] with no native stack to put it in", frames.map(\.name).joined(separator: ","))
      return
    }
    let current = nav.viewControllers
    // A native screen the shell pushed itself -- the asset viewer -- sits above
    // the mirrored frames and Dart does not know it is there. Reconciling under
    // it would rebuild the stack from frames that cannot describe it, and
    // `setViewControllers` would take the viewer off the screen the user is
    // looking at. Dart's stack cannot legitimately change while it is up, so
    // doing nothing is both safe and correct.
    if (current.last as? AssetViewerController) != nil {
      shellLog("[shell:nav] sync [%@] under the native viewer, ignored", frames.map(\.name).joined(separator: ","))
      return
    }
    // The tab root, which is not part of the mirror and never moves.
    let base = current.prefix { !($0 is FlutterStackController) }
    let existing = current.compactMap { $0 as? FlutterStackController }

    var shared = 0
    while shared < existing.count, shared < frames.count, existing[shared].shellLabel == frames[shared].name {
      shared += 1
    }

    // A frame that is staying can still have a different bar: a page's actions
    // are built from its own state, and the memories filter changes its icon
    // without touching the stack at all. Applied before the early return, which
    // is the path every one of those syncs takes.
    for (index, frame) in frames.prefix(shared).enumerated() {
      existing[index].apply(title: frame.title, actions: frame.actions, hero: frame.hero)
    }

    guard shared != existing.count || shared != frames.count else { return }

    // Frames being dropped must not turn around and ask Dart to pop what Dart
    // has already popped.
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
      // One route added on top: the ordinary push, and the only case that
      // deserves the push animation.
      nav.pushViewController(pushed, animated: true)
    } else if target.count < current.count, shared == frames.count {
      // Frames removed from the top: animate as the pop it is.
      nav.setViewControllers(target, animated: true)
    } else {
      // The stacks diverge somewhere in the middle. Rare, and there is no
      // honest animation for it.
      nav.setViewControllers(target, animated: false)
    }

    if target.count > current.count {
      scheduleDebugPop(on: nav)
    }
  }

  /// The native stack as the log should see it, so it can be compared with what
  /// Dart says its own stack is at the same moment.
  private func describe(_ nav: UINavigationController) -> String {
    let labels = nav.viewControllers.map { ($0 as? ShellFlutterHost)?.shellLabel ?? String(describing: type(of: $0)) }
    return "[\(labels.joined(separator: ","))]"
  }

  /// `-immichShellPopFrom native|dart` pops the mirrored frame a few seconds
  /// after it appears.
  ///
  /// A programmatic `popViewController` takes exactly the path a back tap
  /// takes, so this exercises the half of the mirror that a screenshot cannot
  /// reach — the half where the two stacks could pop each other in a loop.
  private func scheduleDebugPop(on nav: UINavigationController) {
    // `-immichShellCancelSwipe YES` injects the fault that produced the
    // reported jank: Dart is asked to pop while the native frame stays. It used
    // to be what every abandoned swipe-back did, because the check for a
    // cancellable transition could never be true. It is kept as the regression
    // check — the two stacks must now survive it.
    if UserDefaults.standard.bool(forKey: "immichShellCancelSwipe") {
      DispatchQueue.main.asyncAfter(deadline: .now() + cycleDelay) { [weak nav] in
        shellLog("[shell:nav] debug: swipe started then cancelled, frame stays: %@", nav.map(self.describe) ?? "?")
        self.requestDartPop(route: (nav?.viewControllers.last as? ShellFlutterHost)?.shellLabel ?? "?")
        self.scheduleDebugRepush()
      }
      return
    }
    // `-immichShellFakeSwipe YES` holds the transition in the state a swipe-back
    // is in while your thumb is still down: the native frame is being dragged
    // off and Dart has not been told anything, because the gesture can still be
    // abandoned. Run it with `-immichShellSlowAnimations YES` and photograph the
    // middle — that is the frame the user was complaining about.
    if UserDefaults.standard.bool(forKey: "immichShellFakeSwipe") {
      DispatchQueue.main.asyncAfter(deadline: .now() + cycleDelay) { [weak nav] in
        guard let nav, let top = nav.viewControllers.last as? FlutterStackController else { return }
        shellLog("[shell:nav] debug: dragging %@ away with dart untouched", top.shellLabel)
        top.suppressDartPop = true
        nav.popViewController(animated: true)
      }
      return
    }
    guard let origin = UserDefaults.standard.string(forKey: "immichShellPopFrom") else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + cycleDelay) { [weak nav] in
      guard let nav else { return }
      switch origin {
      case "native":
        shellLog("[shell:nav] debug: popping natively from %@", self.describe(nav))
        nav.popViewController(animated: true)
      case "dart":
        shellLog("[shell:nav] debug: asking dart to pop")
        self.channel?.invokeMethod("debugPop", arguments: nil)
      default:
        break
      }
      // `-immichShellStrayPop YES` asks Dart to pop a second time, with no
      // native frame behind the request. Dart must decline it: answering one of
      // these is how the app used to end up on the Flutter timeline with the
      // tab bar still saying Search.
      if UserDefaults.standard.bool(forKey: "immichShellStrayPop") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
          shellLog("[shell:nav] debug: stray pop request, no native frame for it")
          self.requestDartPop(route: "VideoRoute")
        }
      }
      self.scheduleDebugRepush()
    }
  }

  /// `-immichShellCycle <n>` repeats the whole open-and-close, which is the only
  /// way the reported fault shows up: one cycle is always clean.
  private lazy var debugCyclesLeft = UserDefaults.standard.integer(forKey: "immichShellCycle")

  /// Seconds between the two halves of a cycle. A tap-driven open-and-close is
  /// about this fast, and the fault is a race, so the interval is the knob.
  private lazy var cycleDelay: Double = {
    let ms = UserDefaults.standard.integer(forKey: "immichShellCycleDelay")
    return ms > 0 ? Double(ms) / 1000 : 3
  }()

  /// `-immichShellOpenViewer <ms>` opens Immich's own asset viewer over
  /// whatever is showing, which is the one route that is an overlay rather than
  /// a stack frame. Sent on the timeline channel because that is where the
  /// `TimelineService` the route needs lives.
  func scheduleDebugViewer(on engine: FlutterEngine) {
    let delay = UserDefaults.standard.integer(forKey: "immichShellOpenViewer")
    guard delay > 0 else { return }
    let channel = FlutterMethodChannel(name: "immich/timeline", binaryMessenger: engine.binaryMessenger)
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000) {
      shellLog("[shell:nav] debug: opening the flutter asset viewer")
      channel.invokeMethod(
        "debugOpenViewer",
        arguments: ["timeline": UserDefaults.standard.string(forKey: "immichShellViewerTimeline") ?? "main"]
      )
      // And close it again the way its back button does. Under the shell that
      // is a native pop, not a Dart one: the route was declined, so Dart has
      // nothing to pop and asking it to would pop the page underneath instead.
      DispatchQueue.main.asyncAfter(deadline: .now() + self.cycleDelay) {
        if self.activeNavigationController?.topViewController is AssetViewerController {
          shellLog("[shell:nav] debug: closing the native asset viewer")
          self.activeNavigationController?.popViewController(animated: true)
        } else {
          shellLog("[shell:nav] debug: closing the flutter asset viewer")
          self.channel?.invokeMethod("debugPop", arguments: nil)
        }
      }
    }
  }

  /// `-immichShellOpenAlbum <ms>` opens the first album the server returns.
  ///
  /// `-immichShellPushRoute` can only name a route, and every page worth
  /// looking at right now takes an argument. Sent on the timeline channel for
  /// the same reason the viewer hook is: that is where the `Ref` that can
  /// fetch a `RemoteAlbum` lives.
  func scheduleDebugAlbum(on engine: FlutterEngine) {
    let delay = UserDefaults.standard.integer(forKey: "immichShellOpenAlbum")
    guard delay > 0 else { return }
    let channel = FlutterMethodChannel(name: "immich/timeline", binaryMessenger: engine.binaryMessenger)
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000) {
      shellLog("[shell:nav] debug: opening an album")
      channel.invokeMethod("debugPushAlbum", arguments: nil)
    }
  }
  /// `-immichShellScroll <ms>` scrolls the visible timeline, and
  /// `-immichShellScrollTo <points>` says how far (default 600).
  ///
  /// The simulator accepts no touch input from a script, so anything driven by
  /// a scroll — a cover photo collapsing, a native bar taking over its title —
  /// has no other way to be exercised.
  func scheduleDebugScroll(on engine: FlutterEngine) {
    let delay = UserDefaults.standard.integer(forKey: "immichShellScroll")
    guard delay > 0 else { return }
    let requested = UserDefaults.standard.integer(forKey: "immichShellScrollTo")
    let offset = requested > 0 ? requested : 600
    let channel = FlutterMethodChannel(name: "immich/timeline", binaryMessenger: engine.binaryMessenger)
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000) {
      shellLog("[shell:nav] debug: scrolling to %d", offset)
      channel.invokeMethod("debugScroll", arguments: ["offset": offset])
    }
  }

  /// `-immichShellNativePage <ms>` pushes a page with no Flutter in it at all
  /// onto the same navigation controller, with the same
  /// `hidesBottomBarWhenPushed` every mirrored frame uses.
  ///
  /// This is the control for the tab bar's glass backing. Swiping back from a
  /// mirrored frame brings the tab bar in immediately with no liquid glass
  /// behind it, and the glass then animates in over the gesture. If a page that
  /// has never touched the Flutter surface does the same thing, the behaviour
  /// belongs to UIKit — `hidesBottomBarWhenPushed` under iOS 26 is a thinner
  /// path than it used to be — and nothing in this shell is worth changing for
  /// it. If it does *not*, the suspects are ours: `applyChrome` touching the
  /// navigation bar while a transition coordinator is live, the tab bar's
  /// minimize behaviour, or the glass failing to sample a Metal layer.
  func scheduleDebugNativePage() {
    let delay = UserDefaults.standard.integer(forKey: "immichShellNativePage")
    guard delay > 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000) {
      guard let nav = self.activeNavigationController else {
        shellLog("[shell:nav] debug: no navigation controller for the native control page")
        return
      }
      let page = DebugNativePageController()
      // The property under suspicion, set exactly as a mirrored frame sets it.
      // Everything else about this page is stock UIKit.
      page.hidesBottomBarWhenPushed = true

      shellLog("[shell:nav] debug: pushing the native control page onto %@", self.describe(nav))
      nav.pushViewController(page, animated: true)
    }
  }

  private func scheduleDebugRepush() {
    guard debugCyclesLeft > 0, let name = UserDefaults.standard.string(forKey: "immichShellPushRoute") else { return }
    debugCyclesLeft -= 1
    let left = debugCyclesLeft
    DispatchQueue.main.asyncAfter(deadline: .now() + cycleDelay) {
      shellLog("[shell:nav] debug: cycle re-push %@ (%d left after this)", name, left)
      self.channel?.invokeMethod("debugPush", arguments: ["name": name])
    }
  }

  /// The native stack dismissed a frame. Ask Dart to pop *that* route.
  ///
  /// Named, not "pop one". An unaddressed request is answered by whatever
  /// happens to be on top, and when nothing is, by Immich's own `PopScope` —
  /// which quietly switches tabs. Dart declines a request it cannot match and
  /// re-asserts its stack instead.
  /// Ask Dart to describe its stack again, for when the native side was not in
  /// a position to act on what it last said.
  func requestSync() {
    channel?.invokeMethod("resync", arguments: nil)
  }

  func requestDartPop(route: String) {
    channel?.invokeMethod("popFromNative", arguments: ["name": route])
  }

  // MARK: - Geometry

  /// `-immichShellTapBarAction <ms>` taps the first action on whatever frame is
  /// on top, twice, a second apart.
  ///
  /// Through the real `UIBarButtonItem` target/action, so it exercises the
  /// whole round trip -- native tap, Dart callback, page state change, the bar
  /// it republishes, and the item this side rebuilds from it. Twice because a
  /// toggle that only ever went one way would look identical to one that
  /// applied once and stuck.
  func scheduleDebugBarAction() {
    let delay = UserDefaults.standard.integer(forKey: "immichShellTapBarAction")
    guard delay > 0 else { return }
    for (index, offset) in [Double(delay) / 1000, Double(delay) / 1000 + 1.5].enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
        guard let top = self.activeNavigationController?.viewControllers.last,
              let item = top.navigationItem.rightBarButtonItems?.first else {
          shellLog("[shell:nav] debug: no bar action to tap")
          return
        }
        // A bar button with a menu has no target or action -- UIKit opens the
        // menu itself -- so the two passes choose two different rows instead,
        // which is also the more interesting test: the rows must not be
        // interchangeable.
        if item.menu != nil, let frame = top as? FlutterStackController {
          shellLog("[shell:nav] debug: choosing menu row %d", index)
          if !frame.debugPerformMenu(action: 0, row: index) {
            shellLog("[shell:nav] debug: no menu row %d", index)
          }
          return
        }
        guard let target = item.target, let action = item.action else {
          shellLog("[shell:nav] debug: bar action has neither menu nor target")
          return
        }
        shellLog("[shell:nav] debug: tapping bar action, pass %d", index + 1)
        _ = target.perform(action, with: item)
      }
    }
  }

  /// `-immichShellDartTab <tab>` makes Dart change tab on its own after a
  /// delay, which is the only way to see whether the native tab bar follows.
  func scheduleDebugDartTab() {
    guard let tab = UserDefaults.standard.string(forKey: "immichShellDartTab") else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
      shellLog("[shell] debug: asking dart to switch to %@", tab)
      self?.channel?.invokeMethod("debugTab", arguments: ["tab": tab])
    }
  }

  /// Ask a tab to return to its root, because it was tapped while selected.
  ///
  /// Fire-and-forget: Dart pops and the sync that follows drives the native
  /// removal, so the pop animation comes out of `reconcile` like every other
  /// one rather than from a second call here racing it.
  /// A native bar button was tapped. Dart holds the callback, so the index it
  /// published is the whole identity -- there is no action name to invent and
  /// no registry on this side to keep in step.
  /// `item` is the menu row, or -1 for a plain button.
  func barAction(route: String, index: Int, item: Int) {
    channel?.invokeMethod("barAction", arguments: ["route": route, "index": index, "item": item])
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

  /// Ask Dart to show `route` and call back once it has actually rendered it.
  ///
  /// The reply is the settle signal. Dart applies any pop that is still in
  /// flight, switches the tab, waits for a frame to be built and rastered, and
  /// only then answers — so the caller knows the surface is showing the right
  /// page rather than merely that the message was delivered.
  /// The reply names what Dart ended up drawing, which is the only answer worth
  /// having. Asking for a tab and taking "delivered" as confirmation is what put
  /// Videos in the Search slot for the length of a swipe-back: the tab was
  /// right and a pushed route was covering it.
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

  /// Ask Flutter for a picture of what it is drawing right now.
  ///
  /// Answers nil until Dart is running, and whenever the boundary has not been
  /// laid out. Callers treat a still as an improvement, never as a requirement.
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
      // Captured at Flutter's logical scale, so the image is in points and
      // covers the container exactly.
      completion(UIImage(data: data.data, scale: 1))
    }
  }
}

/// The control page for the tab bar's glass backing: everything a mirrored
/// frame is, minus the Flutter surface.
///
/// A bare `UIViewController` is not a control. The shell hides the navigation
/// bar for tab containers, and UIKit disables `interactivePopGestureRecognizer`
/// whenever the bar is hidden — so a pushed page that does not ask for the bar
/// back has no chrome and no swipe, and there is nothing to compare. This does
/// what `FlutterStackController` does in `viewWillAppear`, and nothing else.
final class DebugNativePageController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Native Control"
    view.backgroundColor = .secondarySystemBackground
    navigationItem.largeTitleDisplayMode = .never

    let label = UILabel()
    label.text = "No Flutter here.\nSwipe back and watch the tab bar."
    label.numberOfLines = 0
    label.textAlignment = .center
    label.textColor = .secondaryLabel
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
  }

  /// The same two lines `applyChrome` runs for a mirrored frame that carries a
  /// native title — which is the case being compared against.
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(false, animated: true)
    navigationController?.interactivePopGestureRecognizer?.isEnabled = true
  }
}
