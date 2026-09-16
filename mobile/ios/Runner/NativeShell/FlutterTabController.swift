import Flutter
import UIKit

final class FlutterTabController: UIViewController, ShellFlutterHost {
  let shellRoute: String
  let shellLabel: String

  /// The search tab hosts a real `UISearchBar`; Dart draws only the results.
  private let isSearch: Bool

  var surfaceToken: String { shellRoute }
  var prefersNativeBarHidden: Bool { !isSearch && !hasBar }
  var still: UIImage?

  var flutterContainer: UIView { view }

  private var search: UISearchController?

  private let bar = ShellBarItems(route: "")

  /// The Dart route whose bar this tab shows: its root, not the tab itself.
  var barRoute = "" {
    didSet { bar.route = barRoute }
  }

  private var hasBar = false

  init(route: String, label: String, isSearch: Bool = false) {
    self.shellRoute = route
    self.shellLabel = label
    self.isSearch = isSearch
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    guard isSearch else { return }
    installSearch()
  }

  func apply(title: String?, actions: [[String: Any]]) {
    // A search tab keeps the field in the bar; a title would push it into a second row.
    if !isSearch, title != self.title {
      self.title = title
    }
    let changed = bar.apply(actions, to: navigationItem)
    guard !hasBar || changed else { return }
    hasBar = true
    applyChrome(overlayPresent: ShellEngine.shared.overlayPresent)
    if #available(iOS 16.0, *) {
      shellLog(
        "[shell:nav] %@ search placement=%ld left=%ld right=%ld",
        barRoute,
        navigationItem.searchBarPlacement.rawValue,
        navigationItem.leftBarButtonItems?.count ?? 0,
        navigationItem.rightBarButtonItems?.count ?? 0
      )
    }
  }

  private func installSearch() {
    let controller = UISearchController(searchResultsController: nil)
    controller.obscuresBackgroundDuringPresentation = false
    // Defaults to true, which takes the bar — and its actions — away the moment
    // `automaticallyActivatesSearch` presents.
    controller.hidesNavigationBarDuringPresentation = false
    controller.delegate = self
    controller.searchBar.delegate = self
    controller.searchBar.placeholder = ShellBridge.shared.searchPlaceholder
    search = controller

    // No title: a stacked search bar sits under one, and it flashes before the
    // field takes the bar over.
    navigationItem.searchController = controller
    navigationItem.hidesSearchBarWhenScrolling = false
    if #available(iOS 26.0, *) {
      navigationItem.preferredSearchBarPlacement = .integratedCentered
    } else if #available(iOS 16.0, *) {
      navigationItem.preferredSearchBarPlacement = .stacked
    }
    definesPresentationContext = true

    ShellBridge.shared.onSearchPlaceholderChange = { [weak self] placeholder in
      self?.search?.searchBar.placeholder = placeholder
    }
    ShellBridge.shared.onSearchTextChange = { [weak self] text in
      self?.search?.searchBar.text = text
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
}

extension FlutterTabController: UISearchControllerDelegate {
  func didPresentSearchController(_ searchController: UISearchController) {
    shellLog(
      "[shell:nav] search presented, left=%ld right=%ld",
      navigationItem.leftBarButtonItems?.count ?? 0,
      navigationItem.rightBarButtonItems?.count ?? 0
    )
  }
}

extension FlutterTabController: UISearchBarDelegate {
  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    ShellBridge.shared.submitSearch(searchBar.text ?? "")
    searchBar.resignFirstResponder()
  }

  func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
    ShellBridge.shared.submitSearch("")
  }
}
