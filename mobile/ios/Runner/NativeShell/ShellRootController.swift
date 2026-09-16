import AuthenticationServices
import UIKit

final class ShellRootController: UIViewController {
  private var current: UIViewController?

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
    let tabs = ShellBridge.shared.tabs
    switch state {
    case .unknown, .signedOut:
      next = FlutterTabController(route: "", label: "launch")
    case .signedIn where tabs.isEmpty:
      // `ready` carries the tabs and precedes `auth`, so this is a bug, not a race.
      shellLog("[shell] signed in before dart declared any tabs; staying on launch")
      next = FlutterTabController(route: "", label: "launch")
    case .signedIn:
      next = NativeShellController(tabs: tabs)
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
    // Dart's stack predates this one, so its first `sync` was dropped.
    if next is UITabBarController {
      ShellBridge.shared.requestSync()
    }
  }
}

/// `flutter_web_auth_2` presents from `window.rootViewController`, and only declares
/// this conformance on `FlutterViewController` — which is a grandchild here, not the
/// root. Without it, OAuth fails with ACQUIRE_ROOT_VIEW_CONTROLLER_FAILED.
extension ShellRootController: ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    view.window ?? UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.keyWindow }
      .first ?? ASPresentationAnchor()
  }
}
