import AuthenticationServices
import UIKit

/// Swaps the window's root between the launch surface and the shell.
///
/// Not a container view controller: `UITabBarController` is only supported as a
/// window's root, and nested as a child it loses the iOS 26 tab bar treatment —
/// the search tab stays in the group instead of standing apart.
final class ShellRoot {
  private weak var window: UIWindow?

  private(set) var current: UIViewController?

  init(window: UIWindow) {
    self.window = window
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
    current = next
    window?.rootViewController = next
    // Dart's stack predates this one, so its first `sync` was dropped.
    if next is UITabBarController {
      ShellBridge.shared.requestSync()
    }
  }
}

/// `flutter_web_auth_2` presents from `window.rootViewController`, and only declares
/// this conformance on `FlutterViewController`, which is never the root here.
extension NativeShellController: ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    view.window ?? ASPresentationAnchor()
  }
}

extension FlutterTabController: ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    view.window ?? ASPresentationAnchor()
  }
}
