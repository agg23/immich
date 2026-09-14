import UIKit

/// Immich ships `FlutterSceneDelegate` plus a storyboard, which puts a
/// `FlutterViewController` straight into the window. The native shell owns the
/// window instead, so it supplies its own scene delegate and the storyboard
/// entry point goes unused.
final class ShellSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = ShellRootController()
    window.makeKeyAndVisible()
    self.window = window

    // `-immichShellSlowAnimations YES` stretches every animation in the
    // window. A 350ms push becomes ~2.3s, which is the only way to get a
    // screenshot from the *middle* of a transition — and the middle of the
    // transition is where the surface handoff is either right or wrong.
    if UserDefaults.standard.bool(forKey: "immichShellSlowAnimations") {
      window.layer.speed = 0.15
      shellLog("[shell] animations slowed to 15%%")
    }

    shellLog("[shell] scene connected")
  }
}
