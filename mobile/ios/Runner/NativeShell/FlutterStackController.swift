import Flutter
import UIKit

final class FlutterStackController: UIViewController, ShellFlutterHost {
  let shellRoute = ""
  let shellLabel: String
  private var nativeTitle: String?
  private var hero = false
  private var collapsed = false

  var surfaceToken: String { shellLabel }
  var prefersNativeBarHidden: Bool { nativeTitle == nil }
  var prefersFullBleedTop: Bool { hero }
  var still: UIImage?

  var flutterContainer: UIView { view }

  /// See `ShellFlutterHost`: the Flutter view controller below never hears it left the screen.
  override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

  var suppressDartPop = false

  private lazy var bar = ShellBarItems(route: shellLabel)

  func apply(title: String?, actions: [[String: Any]], hero: Bool = false) {
    if hero != self.hero {
      self.hero = hero
      applyBarAppearance(animated: false)
      view.setNeedsLayout()
    }
    if title != nativeTitle {
      nativeTitle = title
      self.title = barTitle
      applyChrome(overlayPresent: ShellEngine.shared.overlayPresent)
    }
    _ = bar.apply(actions, to: navigationItem)
  }

  func setCollapsed(_ collapsed: Bool) {
    guard hero, collapsed != self.collapsed else { return }
    self.collapsed = collapsed
    title = barTitle
    applyBarAppearance(animated: true)
  }

  private var barTitle: String? { hero && !collapsed ? "" : nativeTitle }

  private func applyBarAppearance(animated: Bool) {
    let appearance = UINavigationBarAppearance()
    if hero && !collapsed {
      appearance.configureWithTransparentBackground()
    } else {
      appearance.configureWithDefaultBackground()
    }
    navigationItem.standardAppearance = hero ? appearance : nil
    navigationItem.scrollEdgeAppearance = hero ? appearance : nil
    navigationController?.navigationBar.tintColor = hero && !collapsed ? .white : nil
    guard let bar = navigationController?.navigationBar else { return }
    if animated {
      UIView.transition(with: bar, duration: 0.25, options: .transitionCrossDissolve) {
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
      }
    } else {
      bar.setNeedsLayout()
    }
  }

  #if SHELL_DEBUG
    func debugPerformMenu(action index: Int, row: Int) -> Bool {
      guard let handler = bar.menuHandlers["\(index).\(row)"] else { return false }
      handler()
      return true
    }
  #endif

  init(label: String, nativeTitle: String?) {
    self.shellLabel = label
    self.nativeTitle = nativeTitle
    super.init(nibName: nil, bundle: nil)
    title = nativeTitle
    // Stays up: each tab owns its own outlet, so this lives in *this* tab's stack.
    hidesBottomBarWhenPushed = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    navigationItem.largeTitleDisplayMode = .never
  }

  /// Neither obvious hook works: `didMove(toParent:)` fires after the animation,
  /// and `willMove(toParent:)` has no `transitionCoordinator` yet.
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    guard isMovingFromParent, !suppressDartPop, !dartPopRequested else { return }

    guard let coordinator = transitionCoordinator, coordinator.isInteractive else {
      requestDartPop("non-interactive")
      return
    }
    coordinator.notifyWhenInteractionChanges { [weak self] context in
      guard !context.isCancelled else {
        shellLog("[shell:nav] swipe-back on %@ cancelled, dart untouched", self?.shellLabel ?? "?")
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
    shellLog("[shell:nav] native pop of %@ -> dart (%@)", shellLabel, reason)
    ShellBridge.shared.requestDartPop(route: shellLabel)
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    guard parent == nil else { return }
    if suppressDartPop {
      shellLog("[shell:nav] native frame removed for %@ (dart-initiated)", shellLabel)
      return
    }
    requestDartPop("removal backstop")
  }
}
