import UIKit

/// The window's root. Swaps between the launch surface and the tab shell as
/// Dart reports whether anyone is signed in.
///
/// Immich resolves login in Dart — `SplashScreenRoute` leads to either the
/// login page or the tab shell — so at launch the native side does not know
/// whether a tab bar makes sense. Showing one over the login form would be
/// wrong, and guessing from a keychain read would duplicate a decision Dart
/// already owns. So the shell starts as a plain full-screen Flutter surface
/// and grows a tab bar when Dart says there is something to tab between.
final class ShellRootController: UIViewController {
  private var current: UIViewController?

  /// The shell or launch surface currently installed, so the bridge can find
  /// the tab bar without reaching through view hierarchies.
  var currentChild: UIViewController? { current }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    ShellBridge.shared.onAuthStateChange = { [weak self] state in
      DispatchQueue.main.async { self?.apply(state) }
    }
    apply(ShellBridge.shared.authState)
  }

  private func apply(_ state: ShellBridge.AuthState) {
    let next: UIViewController
    switch state {
    case .unknown, .signedOut:
      // Splash, login, onboarding: all Dart, all full screen.
      next = FlutterTabController(route: "", label: "launch")
    case .signedIn:
      next = NativeShellController()
    }
    if let current, type(of: current) == type(of: next) { return }
    shellLog("[shell] root -> %@", String(describing: type(of: next)))
    swap(to: next)
  }

  private func swap(to next: UIViewController) {
    if let current {
      current.willMove(toParent: nil)
      current.view.removeFromSuperview()
      current.removeFromParent()
    }
    addChild(next)
    next.view.frame = view.bounds
    next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(next.view)
    next.didMove(toParent: self)
    current = next
    // Dart's stack exists before this one does, so its first `sync` arrived
    // with nowhere to go and was dropped. Ask for it again now there is
    // somewhere to put it — otherwise launching straight into a pushed route (a
    // deep link, a share) leaves the native side a frame short with nothing to
    // correct it.
    if next is UITabBarController {
      ShellBridge.shared.requestSync()
    }
  }
}
