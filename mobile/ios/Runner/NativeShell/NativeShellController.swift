import UIKit

/// One tab, as Dart declared it; only the icon is decided on this side.
struct ShellTab {
  let id: String
  let label: String
  let icon: ShellIcon?
  let isSearch: Bool

  init?(_ raw: [String: Any]) {
    guard let id = raw["id"] as? String else { return nil }
    self.id = id
    label = raw["label"] as? String ?? id
    icon = (raw["icon"] as? String).flatMap(ShellIcon.init(rawValue:))
    isSearch = raw["role"] as? String == "search"
  }
}

final class NativeShellController: UITabBarController, UITabBarControllerDelegate {
  private let shellTabs: [ShellTab]

  /// iOS 26 gives a `UISearchTab` its own section in the tab bar. Setting `tabs` at
  /// all takes `viewControllers` and `selectedIndex` out of play, so the two paths
  /// are kept apart behind the accessors below.
  private let usesTabObjects: Bool

  init(tabs: [ShellTab]) {
    shellTabs = tabs
    if #available(iOS 26.0, *) {
      usesTabObjects = true
    } else {
      usesTabObjects = false
    }
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self

    if usesTabObjects, #available(iOS 26.0, *) {
      tabs = shellTabs.enumerated().map(makeTab)
      // Prominence is what sets a tab apart from the group. It is only inferred for
      // a search tab that activates search itself, which ours does not — its field
      // is Flutter's — so name it explicitly.
      if #available(iOS 27.0, *), let search = tabs.first(where: { $0 is UISearchTab }) {
        prominentTabIdentifier = search.identifier
        shellLog("[shell] prominent tab=%@", search.identifier)
      }
      shellLog(
        "[shell] tab objects: %@",
        tabs.map { "\(type(of: $0))/\($0.userInfo as? String ?? "?")/placement=\($0.preferredPlacement.rawValue)" }
          .joined(separator: ",")
      )
    } else {
      shellLog("[shell] legacy view controllers; UITab unavailable")
      viewControllers = shellTabs.enumerated().map(makeNavigation)
    }

    scheduleDebugTabHooks()

    if #available(iOS 26.0, *) {
      tabBarMinimizeBehavior = .onScrollDown
    }
  }

  private func makeNavigation(index: Int, tab: ShellTab) -> UINavigationController {
    let root: UIViewController
    if index == 0, let main = TimelineSessions.shared.source(for: TimelineSessions.mainSession) {
      root = NativeTimelineViewController(source: main)
    } else {
      root = FlutterTabController(route: tab.id, label: tab.label, isSearch: tab.isSearch)
    }

    let nav = UINavigationController(rootViewController: root)
    nav.navigationBar.prefersLargeTitles = index == 0
    nav.tabBarItem = UITabBarItem(title: tab.label, image: tab.icon?.image, tag: index)
    nav.tabBarItem.accessibilityIdentifier = "tab-\(tab.id)"
    return nav
  }

  @available(iOS 26.0, *)
  private func makeTab(index: Int, tab: ShellTab) -> UITab {
    let provider: (UITab) -> UIViewController = { [unowned self] _ in makeNavigation(index: index, tab: tab) }

    let item: UITab
    if tab.isSearch {
      // A search tab's identifier is assigned by the system, which is why every
      // lookup below goes through `userInfo` instead.
      let search = UISearchTab(viewControllerProvider: provider)
      search.title = tab.label
      // Left off deliberately: it presents search on every entry to the tab, and an
      // active field takes the bar over, so the tab's own actions never show.
      // Prominence comes from `prominentTabIdentifier` instead.
      item = search
    } else {
      item = UITab(title: tab.label, image: tab.icon?.image, identifier: tab.id, viewControllerProvider: provider)
    }
    item.userInfo = tab.id
    return item
  }

  // MARK: Tab access, in whichever mode is running

  private func shellTab(at index: Int) -> ShellTab? { shellTabs.indices.contains(index) ? shellTabs[index] : nil }

  func index(ofTab id: String) -> Int? { shellTabs.firstIndex { $0.id == id } }

  var selectedTabId: String? {
    if usesTabObjects, #available(iOS 26.0, *) {
      return selectedTab?.userInfo as? String
    }
    return shellTab(at: selectedIndex)?.id
  }

  func select(tabId: String) {
    if usesTabObjects, #available(iOS 26.0, *) {
      guard let match = tabs.first(where: { ($0.userInfo as? String) == tabId }) else { return }
      selectedTab = match
      return
    }
    guard let index = index(ofTab: tabId), index < (viewControllers?.count ?? 0) else { return }
    selectedIndex = index
  }

  var activeNavigationController: UINavigationController? {
    if usesTabObjects, #available(iOS 26.0, *) {
      return selectedTab?.viewController as? UINavigationController
    }
    return selectedViewController as? UINavigationController
  }

  /// Resolves the tab's view controller, building it if this tab has not been shown.
  func navigationController(forTab id: String) -> UINavigationController? {
    if usesTabObjects, #available(iOS 26.0, *) {
      let match = tabs.first { ($0.userInfo as? String) == id }
      return match?.viewController as? UINavigationController ?? activeNavigationController
    }
    guard let index = index(ofTab: id), let controllers = viewControllers, index < controllers.count else {
      return activeNavigationController
    }
    return controllers[index] as? UINavigationController
  }

  // MARK: Selection

  func announceSelectedTab() {
    guard let id = selectedTabId else { return }
    shellLog("[shell] tab bar selected %@", id)
    ShellBridge.shared.show(route: id) { surface in
      ShellEngine.shared.dartIsShowing(surface)
    }
  }

  func reselect(tabId: String) {
    ShellBridge.shared.popToRoot(tab: tabId)
  }

  // MARK: Delegate, both vintages

  @available(iOS 18.0, *)
  func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
    if let id = tab.userInfo as? String, id == selectedTabId {
      reselect(tabId: id)
    }
    return true
  }

  @available(iOS 18.0, *)
  func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
    announceSelectedTab()
  }

  /// The container cannot say this: returned to covered, it gets no `viewWillAppear`.
  func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
    guard !usesTabObjects else { return }
    announceSelectedTab()
  }

  func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
    guard !usesTabObjects else { return true }
    if viewControllers?.firstIndex(of: viewController) == selectedIndex, let id = selectedTabId {
      reselect(tabId: id)
    }
    return true
  }
}
