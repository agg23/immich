import Flutter
import UIKit

final class FlutterTabController: UIViewController, ShellFlutterHost {
  let shellRoute: String
  let shellLabel: String

  var surfaceToken: String { shellRoute }
  var prefersNativeBarHidden: Bool { true }
  var still: UIImage?

  var flutterContainer: UIView { view }

  init(route: String, label: String) {
    self.shellRoute = route
    self.shellLabel = label
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
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
}
