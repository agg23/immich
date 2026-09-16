import UIKit

/// Builds a navigation item's right-hand buttons from Dart's action descriptions.
///
/// Shared because any Flutter surface can publish a bar — a pushed route hosted by
/// `FlutterStackController`, or a tab's root hosted by `FlutterTabController`.
final class ShellBarItems {
  /// Identifies the publishing route when an action fires. A tab host learns its
  /// route from the first bar it is given, so this is not fixed at init.
  var route: String

  private var actions: [[String: Any]] = []

  #if SHELL_DEBUG
    /// So a scripted run can fire a menu row without a real touch.
    private(set) var menuHandlers: [String: () -> Void] = [:]
  #endif

  init(route: String) {
    self.route = route
  }

  /// Returns whether anything changed; an identical bar is republished constantly.
  func apply(_ next: [[String: Any]], to item: UINavigationItem) -> Bool {
    guard !(actions as NSArray).isEqual(to: next) else { return false }
    actions = next
    shellLog("[shell:nav] %@ bar -> [%@]", route, ShellBarItems.describe(next))
    item.rightBarButtonItems = next.enumerated().reversed().map(button)
    return true
  }

  static func describe(_ actions: [[String: Any]]) -> String {
    actions.map { raw in
      let head = (raw["icon"] as? String) ?? (raw["label"] as? String) ?? "?"
      guard let rows = raw["menu"] as? [[String: Any]] else { return head }
      return "\(head){\(rows.compactMap { $0["label"] as? String }.joined(separator: "/"))}"
    }.joined(separator: ",")
  }

  private func button(index: Int, raw: [String: Any]) -> UIBarButtonItem {
    let item: UIBarButtonItem
    if let rows = raw["menu"] as? [[String: Any]] {
      item = UIBarButtonItem(image: ShellIcon.image(for: raw["icon"]), menu: menu(from: rows, action: index))
    } else if let image = ShellIcon.image(for: raw["icon"]) {
      item = UIBarButtonItem(image: image, style: .plain, target: self, action: #selector(tapped(_:)))
    } else {
      item = UIBarButtonItem(title: raw["label"] as? String, style: .plain, target: self, action: #selector(tapped(_:)))
    }
    item.tag = index
    item.isEnabled = raw["enabled"] as? Bool ?? true
    return item
  }

  private func menu(from rows: [[String: Any]], action index: Int) -> UIMenu {
    var ordinary: [UIAction] = []
    var destructive: [UIAction] = []
    #if SHELL_DEBUG
      menuHandlers = menuHandlers.filter { !$0.key.hasPrefix("\(index).") }
    #endif
    for (row, raw) in rows.enumerated() {
      var attributes: UIMenuElement.Attributes = []
      if !(raw["enabled"] as? Bool ?? true) { attributes.insert(.disabled) }
      let isDestructive = raw["destructive"] as? Bool ?? false
      if isDestructive { attributes.insert(.destructive) }
      let element = UIAction(
        title: raw["label"] as? String ?? "",
        image: ShellIcon.image(for: raw["icon"]),
        attributes: attributes,
        state: raw["selected"] as? Bool ?? false ? .on : .off
      ) { [weak self] _ in self?.fire(action: index, row: row) }
      #if SHELL_DEBUG
        menuHandlers["\(index).\(row)"] = { [weak self] in self?.fire(action: index, row: row) }
      #endif
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
    shellLog("[shell:nav] bar menu %@ #%d row %d", route, index, row)
    ShellBridge.shared.barAction(route: route, index: index, item: row)
  }

  @objc private func tapped(_ sender: UIBarButtonItem) {
    shellLog("[shell:nav] bar action %@ #%d", route, sender.tag)
    ShellBridge.shared.barAction(route: route, index: sender.tag, item: -1)
  }
}
