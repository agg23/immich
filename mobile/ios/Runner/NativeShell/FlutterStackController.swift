import Flutter
import UIKit

/// A native stack entry standing in for a Flutter route.
///
/// When Dart pushes a route, the native side pushes one of these into the
/// selected tab's `UINavigationController`. The Flutter page itself is already
/// on screen — Dart pushed it inside its own Navigator — so this container's
/// job is not to navigate but to *be* the native stack frame for it: it takes
/// the surface, and it gives the page a real native push animation, a real
/// interactive swipe-back and a real position in the native stack.
///
/// Why mirror at all rather than move Immich's routing wholesale: 70 routes,
/// nested tab routers, guards and deep links all live in `AutoRoute` today. A
/// mirror keeps one router authoritative and lets the native stack agree with
/// it, which is a change you can make in an afternoon rather than a quarter.
final class FlutterStackController: UIViewController, ShellFlutterHost {
  /// Dart is already showing this route, so there is nothing to ask it for.
  let shellRoute = ""
  let shellLabel: String
  /// Nil when the Flutter page keeps drawing its own header — most of Immich,
  /// where 47 pages each build their own `appBar:` and there is no shared one
  /// to switch off. Where it is set, the native bar shows it and the Flutter
  /// header is suppressed on the Dart side.
  private let nativeTitle: String?

  /// A mirrored frame owns exactly the route it mirrors.
  var surfaceToken: String { shellLabel }
  /// A frame shows the native bar only where the Flutter page gave up its own.
  var prefersNativeBarHidden: Bool { nativeTitle == nil }
  var still: UIImage?

  var flutterContainer: UIView { view }

  /// Set when this frame is going away because Dart said so, so it does not
  /// turn around and ask Dart to pop what Dart has already popped.
  var suppressDartPop = false

  init(label: String, nativeTitle: String?) {
    self.shellLabel = label
    self.nativeTitle = nativeTitle
    super.init(nibName: nil, bundle: nil)
    title = nativeTitle
    // The tab bar stays up, the way it does in an iOS app that pushes within a
    // tab. It used to be hidden because every pushable route was a sibling of
    // `TabShellRoute` and so covered the whole shell, which made a tab switch an
    // instruction Dart could not honour — it would still be drawing this route
    // whatever tab you picked. Each tab now owns its own `AutoRouter` outlet, so
    // this route lives in *this* tab's stack and the others keep theirs.
    hidesBottomBarWhenPushed = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    navigationItem.largeTitleDisplayMode = .never
  }

  /// Ask Dart to pop as the transition *begins*, and only if it is a pop that
  /// is actually going to happen.
  ///
  /// This is the hook, and finding it took two wrong ones.
  /// `didMove(toParent: nil)` fires after the animation completes, so Dart kept
  /// showing this page for the whole transition and the container being
  /// returned to rendered it in its own slot. `willMove(toParent: nil)` fires
  /// early enough but has no `transitionCoordinator` yet — it is always nil
  /// there — so the check for a cancellable transition could never be true and
  /// every abandoned swipe-back popped Dart anyway, leaving this frame on a
  /// stack Dart no longer had. `viewWillDisappear` is both: the transition has
  /// started and the coordinator exists.
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // Being covered by a push is also a disappearance, and is not a pop.
    guard isMovingFromParent, !suppressDartPop, !dartPopRequested else { return }

    guard let coordinator = transitionCoordinator, coordinator.isInteractive else {
      requestDartPop("non-interactive")
      return
    }
    coordinator.notifyWhenInteractionChanges { [weak self] context in
      guard !context.isCancelled else {
        NSLog("[shell:nav] swipe-back on %@ cancelled, dart untouched", self?.shellLabel ?? "?")
        return
      }
      self?.requestDartPop("swipe committed")
    }
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    reportInsets()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    applyChrome(overlayPresent: ShellEngine.shared.overlayPresent)
    ShellEngine.shared.hostBecameVisible(self)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    ShellEngine.shared.hostDisappeared(self)
  }

  private var dartPopRequested = false

  private func requestDartPop(_ reason: String) {
    guard !dartPopRequested else { return }
    dartPopRequested = true
    NSLog("[shell:nav] native pop of %@ -> dart (%@)", shellLabel, reason)
    ShellBridge.shared.requestDartPop(route: shellLabel)
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    guard parent == nil else { return }
    if suppressDartPop {
      NSLog("[shell:nav] native frame removed for %@ (dart-initiated)", shellLabel)
      return
    }
    // A backstop. If `viewWillDisappear` did not fire — an unusual removal, a
    // container being torn down — Dart still has to be told, late being better
    // than never. A request Dart cannot match is now declined rather than
    // answered with whatever is on top, so a spurious one costs nothing.
    requestDartPop("removal backstop")
  }
}
