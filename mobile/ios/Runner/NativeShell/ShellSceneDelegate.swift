import UIKit

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

    if UserDefaults.standard.bool(forKey: "immichShellSlowAnimations") {
      window.layer.speed = 0.15
      shellLog("[shell] animations slowed to 15%%")
    }

    shellLog("[shell] scene connected")
  }
}
