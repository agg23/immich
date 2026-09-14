import Flutter
import UIKit

/// A native stack entry standing in for a Flutter route.
///
/// When Dart pushes a route, the native side pushes one of these into the
/// selected tab's `UINavigationController`. The Flutter page itself is already
/// on screen — Dart pushed it inside its own Navigator — so this container's
/// job is not to navigate but to *be* the native stack frame for it: it takes
/// the surface, and it gives the page a real native push animation, a real
/// interactive swipe-back and a real position in the native stack.
///
/// Why mirror at all rather than move Immich's routing wholesale: 70 routes,
/// nested tab routers, guards and deep links all live in `AutoRoute` today. A
/// mirror keeps one router authoritative and lets the native stack agree with
/// it, which is a change you can make in an afternoon rather than a quarter.
final class FlutterStackController: UIViewController, ShellFlutterHost {
  /// Dart is already showing this route, so there is nothing to ask it for.
  let shellRoute = ""
  let shellLabel: String
  /// Nil when the Flutter page keeps drawing its own header — most of Immich,
  /// where 47 pages each build their own `appBar:` and there is no shared one
  /// to switch off. Where it is set, the native bar shows it and the Flutter
  /// header is suppressed on the Dart side.
  private var nativeTitle: String?
  private var actions: [[String: Any]] = []

  /// A page whose header is a cover photo rather than chrome. The bar floats
  /// over it, transparent, and holds its title back until Dart says the photo
  /// has scrolled away.
  private var hero = false
  private var collapsed = false

  /// What each menu row does, keyed "action.row".
  ///
  /// Kept only so a script can run the closure a tap would run: UIKit has no
  /// public way to perform a `UIAction`, and "the button has a menu" is not
  /// evidence that choosing a row reaches Dart.
  private var menuHandlers: [String: () -> Void] = [:]

  /// A mirrored frame owns exactly the route it mirrors.
  var surfaceToken: String { shellLabel }
  /// A frame shows the native bar only where the Flutter page gave up its own.
  var prefersNativeBarHidden: Bool { nativeTitle == nil }
  /// A floating bar must not push the page down: the photo is already drawing
  /// to the top edge and an inset for the bar would leave a band above it.
  var prefersFullBleedTop: Bool { hero }
  var still: UIImage?

  var flutterContainer: UIView { view }

  /// Set when this frame is going away because Dart said so, so it does not
  /// turn around and ask Dart to pop what Dart has already popped.
  var suppressDartPop = false

  /// Take the title and actions from a sync.
  ///
  /// Separate from `init` because a frame outlives the sync that created it: the
  /// page behind it rebuilds its header whenever its own state changes, and the
  /// frame has to follow without being torn down and rebuilt.
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
    guard !sameActions(actions) else {
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

  /// Dart crossed the threshold its own title used to fade at.
  ///
  /// One message per crossing, so this is where the fade lives: UIKit will not
  /// animate an appearance swap on its own, and a bar that changed instantly
  /// under a scrolling photo reads as a glitch rather than a transition.
  func setCollapsed(_ collapsed: Bool) {
    guard hero, collapsed != self.collapsed else { return }
    self.collapsed = collapsed
    title = barTitle
    applyBarAppearance(animated: true)
  }

  /// Nothing over the photo; the album name once the photo has gone.
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
    // White over a photo, the bar tint once it has a background —
    // which is the same pair the Flutter header lerped between.
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

  private func sameActions(_ other: [[String: Any]]) -> Bool {
    guard other.count == actions.count else { return false }
    for (a, b) in zip(actions, other) {
      if a["symbol"] as? String != b["symbol"] as? String
        || a["label"] as? String != b["label"] as? String
        || a["enabled"] as? Bool != b["enabled"] as? Bool
        || !sameMenu(a["menu"] as? [[String: Any]], b["menu"] as? [[String: Any]]) {
        return false
      }
    }
    return true
  }

  /// A menu belongs to a page's state, not to its bar: an album grows a "leave
  /// album" row the moment it is shared, and every row after it moves down one.
  /// A `UIMenu` left in place would then fire the wrong callback, so the rows
  /// are part of what makes two bars the same bar.
  private func sameMenu(_ a: [[String: Any]]?, _ b: [[String: Any]]?) -> Bool {
    guard let a, let b else { return (a == nil) == (b == nil) }
    guard a.count == b.count else { return false }
    for (x, y) in zip(a, b) {
      if x["label"] as? String != y["label"] as? String
        || x["symbol"] as? String != y["symbol"] as? String
        || x["enabled"] as? Bool != y["enabled"] as? Bool
        || x["destructive"] as? Bool != y["destructive"] as? Bool {
        return false
      }
    }
    return true
  }

  /// The rows Dart sent, as a `UIMenu`.
  ///
  /// Destructive rows are pulled into their own inline section at the bottom,
  /// which is what iOS does and what the Flutter menu spells with a `Divider`
  /// above a red row. Built from the index Dart gave, not from the position in
  /// the section, so splitting them does not renumber anything.
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

  /// Run what the row's `UIAction` runs. Debug only; see [menuHandlers].
  func debugPerformMenu(action index: Int, row: Int) -> Bool {
    guard let handler = menuHandlers["\(index).\(row)"] else { return false }
    handler()
    return true
  }

  private func applyActions() {
    // Reversed: `rightBarButtonItems` fills from the trailing edge, so the
    // first item in the array lands furthest right. Flutter's `actions` read
    // left to right, and a page's primary action is its last one.
    navigationItem.rightBarButtonItems = actions.enumerated().reversed().map { index, raw in
      let item: UIBarButtonItem
      if let rows = raw["menu"] as? [[String: Any]] {
        // No target and no action: a bar button with a menu opens it itself, so
        // there is no tap to forward and Dart's own trigger never runs.
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
    // The tab bar stays up, the way it does in an iOS app that pushes within a
    // tab. It used to be hidden because every pushable route was a sibling of
    // `TabShellRoute` and so covered the whole shell, which made a tab switch an
    // instruction Dart could not honour — it would still be drawing this route
    // whatever tab you picked. Each tab now owns its own `AutoRouter` outlet, so
    // this route lives in *this* tab's stack and the others keep theirs.
    hidesBottomBarWhenPushed = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    navigationItem.largeTitleDisplayMode = .never
  }

  /// Ask Dart to pop as the transition *begins*, and only if it is a pop that
  /// is actually going to happen.
  ///
  /// This is the hook, and finding it took two wrong ones.
  /// `didMove(toParent: nil)` fires after the animation completes, so Dart kept
  /// showing this page for the whole transition and the container being
  /// returned to rendered it in its own slot. `willMove(toParent: nil)` fires
  /// early enough but has no `transitionCoordinator` yet — it is always nil
  /// there — so the check for a cancellable transition could never be true and
  /// every abandoned swipe-back popped Dart anyway, leaving this frame on a
  /// stack Dart no longer had. `viewWillDisappear` is both: the transition has
  /// started and the coordinator exists.
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // Being covered by a push is also a disappearance, and is not a pop.
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
    // A backstop. If `viewWillDisappear` did not fire — an unusual removal, a
    // container being torn down — Dart still has to be told, late being better
    // than never. A request Dart cannot match is now declined rather than
    // answered with whatever is on top, so a spurious one costs nothing.
    requestDartPop("removal backstop")
  }
}
