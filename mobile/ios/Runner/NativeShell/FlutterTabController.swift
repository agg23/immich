import Flutter
import UIKit

/// A native container whose content is one of Immich's Flutter tab roots.
///
/// The Flutter page draws its own app bar, so this container hides the native
/// navigation bar — a half-converted page with two stacked headers would say
/// nothing useful. It still sits inside a `UINavigationController`, because
/// that is the stack Dart's pushes are mirrored into.
///
/// Giving these roots native chrome as well is the V6 shim from the spike: a
/// real `UIScrollView` as the root view with the surface pinned to its frame
/// layout guide. Not done here.
final class FlutterTabController: UIViewController, ShellFlutterHost {
  let shellRoute: String
  let shellLabel: String

  /// A tab root owns its tab, and Dart names the active tab the same way.
  var surfaceToken: String { shellRoute }
  /// The Flutter tab roots all draw their own headers.
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
    // Registered here rather than in viewDidAppear so the surface can be in
    // place before the container is on screen — if Dart says this container is
    // the one it is drawing. That decision is not this container's to make.
    ShellEngine.shared.hostBecameVisible(self)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    ShellEngine.shared.hostDisappeared(self)
  }
}
