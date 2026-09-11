import UIKit

/// The native replacement for `TabShellPage`.
///
/// Same four destinations in the same order as Immich's `AutoTabsRouter`, so
/// muscle memory carries over: photos, search, albums, library. The first is
/// native; the other three are the Flutter app, hosted.
final class NativeShellController: UITabBarController, UITabBarControllerDelegate {
  /// Route names the Dart side understands. Kept as strings rather than an
  /// index so the bridge stays readable in logs and so a native screen that is
  /// not a tab can use the same call.
  // Not private: the mirror addresses syncs by tab name, so this order is the
  // one source of truth for which index a name means.
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

    /// Immich uses Material icons; these are the SF Symbols closest to them.
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
      let root: UIViewController = tab == .photos
        ? NativeTimelineViewController(messenger: ShellEngine.shared.engine.binaryMessenger)
        : FlutterTabController(route: tab.rawValue, label: tab.title)

      // Every tab gets a navigation controller, including the Flutter ones:
      // that is the stack a Dart push is mirrored into. The Flutter tab roots
      // draw their own headers, so they hide the native bar in
      // `viewWillAppear` and pushed frames show it again.
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

    // No input tooling for the simulator here and no UI test target in this
    // repo, so the way to look at a Flutter tab is to start on it.
    if let name = UserDefaults.standard.string(forKey: "immichShellTab"),
       let index = Tab.allCases.firstIndex(where: { $0.rawValue == name }) {
      selectedIndex = index
      NSLog("[shell] initial tab=%@", name)
    }

    // `-immichShellSwitchTo <tab>` switches tabs a few seconds in, so the tab
    // path can be checked without a pointer. A tab switch moves the one
    // surface exactly as a pop does, so it had the same defect.
    if let names = UserDefaults.standard.string(forKey: "immichShellSwitchTo") {
      // Comma-separated, applied in order: returning to a tab is the case worth
      // checking, because only a container's second visit has a still of its own
      // to hold while it waits for Dart.
      for (step, name) in names.split(separator: ",").enumerated() {
        guard let index = Tab.allCases.firstIndex(where: { $0.rawValue == name }) else { continue }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6 + Double(step) * 4) { [weak self] in
          NSLog("[shell] debug: switching to tab=%@", String(name))
          self?.selectedIndex = index
          self?.announceSelectedTab()
        }
      }
    }

    // For `didSelect`: the tab bar has to tell Dart which tab is active, because
    // a tab container can come back covered by a pushed frame.
    delegate = self

    if #available(iOS 26.0, *) {
      // Scroll-linked minimize, which the native timeline gets for free and
      // the hosted Flutter tabs only get through the shim.
      tabBarMinimizeBehavior = .onScrollDown
    }
  }

  /// Tell Dart which tab is now active.
  ///
  /// The tab *container* used to be the only thing that said this, from its own
  /// `viewWillAppear`. That was enough while a pushed route hid the tab bar,
  /// because you could only ever arrive at a tab root. Now that a tab can be
  /// left and returned to with a route still on its stack, the container comes
  /// back *underneath* that route's frame — and UIKit does not call
  /// `viewWillAppear` on a covered controller, so nobody told Dart the tab had
  /// changed. It kept answering with the tab you left, the surface never matched
  /// the frame holding it, and the placement sat until the settle deadline gave
  /// up and revealed the wrong page.
  ///
  /// The tab bar is the instruction, so the tab bar has to be what sends it.
  func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
    announceSelectedTab()
  }

  /// Say which tab is active, whoever changed it.
  ///
  /// `didSelect` covers taps and nothing else — UIKit does not call it when
  /// `selectedIndex` is set in code — so anything that selects a tab
  /// programmatically has to call this too, or Dart is left on the previous tab
  /// with no way to find out.
  func announceSelectedTab() {
    guard selectedIndex >= 0, selectedIndex < Tab.allCases.count else { return }
    let tab = Tab.allCases[selectedIndex]
    NSLog("[shell] tab bar selected %@", tab.rawValue)
    ShellBridge.shared.show(route: tab.rawValue) { surface in
      ShellEngine.shared.dartIsShowing(surface)
    }
  }

  // There was a `shouldSelect` here that froze the outgoing tab on the way out,
  // because `UITabBarController` calls the incoming `viewWillAppear` before the
  // outgoing `viewWillDisappear` and by then UIKit could no longer photograph
  // the surface. Flutter now takes each container's picture just after it
  // settles, so every tab already has a recent one and there is nothing to
  // catch at the last moment.
}
