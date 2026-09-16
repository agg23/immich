import UIKit

final class ShellSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  private var root: ShellRoot?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    self.window = window
    root = ShellRoot(window: window)
    window.makeKeyAndVisible()

    if UserDefaults.standard.bool(forKey: "immichShellSlowAnimations") {
      window.layer.speed = 0.15
      shellLog("[shell] animations slowed to 15%%")
    }

    shellLog("[shell] scene connected")
  }
}
