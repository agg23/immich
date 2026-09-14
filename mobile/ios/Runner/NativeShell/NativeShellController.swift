import UIKit

final class NativeShellController: UITabBarController, UITabBarControllerDelegate {
  enum Tab: String, CaseIterable {
    case photos
    case search
    case albums
    case library

    var title: String {
      switch self {
      case .photos: "Photos"
      case .search: "Search"
      case .albums: "Albums"
      case .library: "Library"
      }
    }

    var index: Int { Self.allCases.firstIndex(of: self)! }

    static func at(_ index: Int) -> Tab? { allCases.indices.contains(index) ? allCases[index] : nil }

    var symbol: String {
      switch self {
      case .photos: "photo.on.rectangle"
      case .search: "magnifyingglass"
      case .albums: "rectangle.stack"
      case .library: "square.grid.2x2"
      }
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    viewControllers = Tab.allCases.enumerated().map { index, tab in
      let root: UIViewController
      if tab == .photos, let main = TimelineSessions.shared.source(for: TimelineSessions.mainSession) {
        root = NativeTimelineViewController(source: main)
      } else {
        root = FlutterTabController(route: tab.rawValue, label: tab.title)
      }

      let nav = UINavigationController(rootViewController: root)
      nav.navigationBar.prefersLargeTitles = tab == .photos
      let container: UIViewController = nav

      container.tabBarItem = UITabBarItem(
        title: tab.title,
        image: UIImage(systemName: tab.symbol),
        tag: index
      )
      container.tabBarItem.accessibilityIdentifier = "tab-\(tab.rawValue)"
      return container
    }

    scheduleDebugTabHooks()

    delegate = self

    if #available(iOS 26.0, *) {
      tabBarMinimizeBehavior = .onScrollDown
    }
  }

  /// The container cannot say this: returned to covered, it gets no `viewWillAppear`.
  func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
    announceSelectedTab()
  }

  func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
    if viewControllers?.firstIndex(of: viewController) == selectedIndex, let tab = Tab.at(selectedIndex) {
      ShellBridge.shared.popToRoot(tab: tab.rawValue)
    }
    return true
  }

  func announceSelectedTab() {
    guard let tab = Tab.at(selectedIndex) else { return }
    shellLog("[shell] tab bar selected %@", tab.rawValue)
    ShellBridge.shared.show(route: tab.rawValue) { surface in
      ShellEngine.shared.dartIsShowing(surface)
    }
  }
}
