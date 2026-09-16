import UIKit

/// One tab, as Dart declared it; only the icon is decided on this side.
struct ShellTab {
  let id: String
  let label: String
  let icon: ShellIcon?

  init?(_ raw: [String: Any]) {
    guard let id = raw["id"] as? String else { return nil }
    self.id = id
    label = raw["label"] as? String ?? id
    icon = (raw["icon"] as? String).flatMap(ShellIcon.init(rawValue:))
  }
}

final class NativeShellController: UITabBarController, UITabBarControllerDelegate {
  private let shellTabs: [ShellTab]

  init(tabs: [ShellTab]) {
    shellTabs = tabs
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()

    viewControllers = shellTabs.enumerated().map { index, tab in
      let root: UIViewController
      if index == 0, let main = TimelineSessions.shared.source(for: TimelineSessions.mainSession) {
        root = NativeTimelineViewController(source: main)
      } else {
        root = FlutterTabController(route: tab.id, label: tab.label)
      }

      let nav = UINavigationController(rootViewController: root)
      nav.navigationBar.prefersLargeTitles = index == 0

      nav.tabBarItem = UITabBarItem(title: tab.label, image: tab.icon?.image, tag: index)
      nav.tabBarItem.accessibilityIdentifier = "tab-\(tab.id)"
      return nav
    }

    scheduleDebugTabHooks()

    delegate = self

    if #available(iOS 26.0, *) {
      tabBarMinimizeBehavior = .onScrollDown
    }
  }

  private func tab(at index: Int) -> ShellTab? { shellTabs.indices.contains(index) ? shellTabs[index] : nil }

  func index(ofTab id: String) -> Int? { shellTabs.firstIndex { $0.id == id } }

  /// The container cannot say this: returned to covered, it gets no `viewWillAppear`.
  func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
    announceSelectedTab()
  }

  func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
    if viewControllers?.firstIndex(of: viewController) == selectedIndex, let tab = tab(at: selectedIndex) {
      ShellBridge.shared.popToRoot(tab: tab.id)
    }
    return true
  }

  func announceSelectedTab() {
    guard let tab = tab(at: selectedIndex) else { return }
    shellLog("[shell] tab bar selected %@", tab.id)
    ShellBridge.shared.show(route: tab.id) { surface in
      ShellEngine.shared.dartIsShowing(surface)
    }
  }
}
