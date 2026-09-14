import Flutter
import UIKit

final class FlutterStackController: UIViewController, ShellFlutterHost {
  let shellRoute = ""
  let shellLabel: String
  private var nativeTitle: String?
  private var actions: [[String: Any]] = []

  private var hero = false
  private var collapsed = false

  private var menuHandlers: [String: () -> Void] = [:]

  var surfaceToken: String { shellLabel }
  var prefersNativeBarHidden: Bool { nativeTitle == nil }
  var prefersFullBleedTop: Bool { hero }
  var still: UIImage?

  var flutterContainer: UIView { view }

  var suppressDartPop = false

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
    guard !sameBar(as: actions) else {
      shellLog("[shell:nav] %@ bar unchanged (%d actions)", shellLabel, actions.count)
      return
    }
    shellLog("[shell:nav] %@ bar -> [%@]", shellLabel, actions.map { raw in
      let head = (raw["symbol"] as? String) ?? (raw["label"] as? String) ?? "?"
      guard let rows = raw["menu"] as? [[String: Any]] else { return head }
      return "\(head){\(rows.compactMap { $0["label"] as? String }.joined(separator: "/"))}"
    }.joined(separator: ","))
    self.actions = actions
    applyActions()
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

  private func sameBar(as other: [[String: Any]]) -> Bool {
    (actions as NSArray).isEqual(to: other)
  }

  private func menu(from rows: [[String: Any]], action index: Int) -> UIMenu {
    var ordinary: [UIAction] = []
    var destructive: [UIAction] = []
    menuHandlers = menuHandlers.filter { !$0.key.hasPrefix("\(index).") }
    for (row, raw) in rows.enumerated() {
      let enabled = raw["enabled"] as? Bool ?? true
      let isDestructive = raw["destructive"] as? Bool ?? false
      var attributes: UIMenuElement.Attributes = []
      if !enabled { attributes.insert(.disabled) }
      if isDestructive { attributes.insert(.destructive) }
      let element = UIAction(
        title: raw["label"] as? String ?? "",
        image: (raw["symbol"] as? String).flatMap { UIImage(systemName: $0) },
        attributes: attributes
      ) { [weak self] _ in self?.fire(action: index, row: row) }
      menuHandlers["\(index).\(row)"] = { [weak self] in self?.fire(action: index, row: row) }
      if isDestructive {
        destructive.append(element)
      } else {
        ordinary.append(element)
      }
    }
    if destructive.isEmpty {
      return UIMenu(children: ordinary)
    }
    return UIMenu(children: ordinary + [UIMenu(options: .displayInline, children: destructive)])
  }

  private func fire(action index: Int, row: Int) {
    shellLog("[shell:nav] bar menu %@ #%d row %d", shellLabel, index, row)
    ShellBridge.shared.barAction(route: shellLabel, index: index, item: row)
  }

  func debugPerformMenu(action index: Int, row: Int) -> Bool {
    guard let handler = menuHandlers["\(index).\(row)"] else { return false }
    handler()
    return true
  }

  private func applyActions() {
    navigationItem.rightBarButtonItems = actions.enumerated().reversed().map { index, raw in
      let item: UIBarButtonItem
      if let rows = raw["menu"] as? [[String: Any]] {
        item = UIBarButtonItem(
          image: (raw["symbol"] as? String).flatMap { UIImage(systemName: $0) },
          menu: menu(from: rows, action: index)
        )
      } else if let symbol = raw["symbol"] as? String {
        item = UIBarButtonItem(
          image: UIImage(systemName: symbol),
          style: .plain,
          target: self,
          action: #selector(barActionTapped(_:))
        )
      } else {
        item = UIBarButtonItem(
          title: raw["label"] as? String,
          style: .plain,
          target: self,
          action: #selector(barActionTapped(_:))
        )
      }
      item.tag = index
      item.isEnabled = raw["enabled"] as? Bool ?? true
      return item
    }
  }

  @objc private func barActionTapped(_ sender: UIBarButtonItem) {
    shellLog("[shell:nav] bar action %@ #%d", shellLabel, sender.tag)
    ShellBridge.shared.barAction(route: shellLabel, index: sender.tag, item: -1)
  }

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
