import Flutter
import UIKit

// `SHELL_DEBUG` is Debug and Profile, never Release; the stubs below keep the
// call sites compiling either way.
#if SHELL_DEBUG

/// Driven by `-immichShell…` launch arguments, and inert without one.
extension ShellBridge {
  func scheduleDebugHooks() {
    scheduleDebugDartTab()
    scheduleDebugBarAction()
    guard let name = UserDefaults.standard.string(forKey: "immichShellPushRoute") else { return }
    let delay = Double(UserDefaults.standard.integer(forKey: "immichShellPushDelay")) / 1000
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      shellLog("[shell:nav] asking dart to push %@", name)
      self.channel?.invokeMethod("debugPush", arguments: ["name": name])
    }
  }

  func scheduleDebugPop(on nav: UINavigationController) {
    if UserDefaults.standard.bool(forKey: "immichShellCancelSwipe") {
      DispatchQueue.main.asyncAfter(deadline: .now() + cycleDelay) { [weak nav] in
        shellLog("[shell:nav] debug: swipe started then cancelled, frame stays: %@", nav.map(self.describe) ?? "?")
        self.requestDartPop(route: (nav?.viewControllers.last as? ShellFlutterHost)?.shellLabel ?? "?")
        self.scheduleDebugRepush()
      }
      return
    }
    if UserDefaults.standard.bool(forKey: "immichShellFakeSwipe") {
      DispatchQueue.main.asyncAfter(deadline: .now() + cycleDelay) { [weak nav] in
        guard let nav, let top = nav.viewControllers.last as? FlutterStackController else { return }
        shellLog("[shell:nav] debug: dragging %@ away with dart untouched", top.shellLabel)
        top.suppressDartPop = true
        nav.popViewController(animated: true)
      }
      return
    }
    guard let origin = UserDefaults.standard.string(forKey: "immichShellPopFrom") else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + cycleDelay) { [weak nav] in
      guard let nav else { return }
      switch origin {
      case "native":
        shellLog("[shell:nav] debug: popping natively from %@", self.describe(nav))
        nav.popViewController(animated: true)
      case "dart":
        shellLog("[shell:nav] debug: asking dart to pop")
        self.channel?.invokeMethod("debugPop", arguments: nil)
      default:
        break
      }
      if UserDefaults.standard.bool(forKey: "immichShellStrayPop") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
          shellLog("[shell:nav] debug: stray pop request, no native frame for it")
          self.requestDartPop(route: "VideoRoute")
        }
      }
      self.scheduleDebugRepush()
    }
  }

  private static var cyclesLeft = UserDefaults.standard.integer(forKey: "immichShellCycle")

  private var cycleDelay: Double {
    let ms = UserDefaults.standard.integer(forKey: "immichShellCycleDelay")
    return ms > 0 ? Double(ms) / 1000 : 3
  }

  func scheduleDebugViewer(on engine: FlutterEngine) {
    let delay = UserDefaults.standard.integer(forKey: "immichShellOpenViewer")
    guard delay > 0 else { return }
    let channel = FlutterMethodChannel(name: "immich/timeline", binaryMessenger: engine.binaryMessenger)
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000) {
      shellLog("[shell:nav] debug: opening the flutter asset viewer")
      channel.invokeMethod(
        "debugOpenViewer",
        arguments: ["timeline": UserDefaults.standard.string(forKey: "immichShellViewerTimeline") ?? "main"]
      )
      DispatchQueue.main.asyncAfter(deadline: .now() + self.cycleDelay) {
        if self.activeNavigationController?.topViewController is AssetViewerController {
          shellLog("[shell:nav] debug: closing the native asset viewer")
          self.activeNavigationController?.popViewController(animated: true)
        } else {
          shellLog("[shell:nav] debug: closing the flutter asset viewer")
          self.channel?.invokeMethod("debugPop", arguments: nil)
        }
      }
    }
  }

  func scheduleDebugAlbum(on engine: FlutterEngine) {
    let delay = UserDefaults.standard.integer(forKey: "immichShellOpenAlbum")
    guard delay > 0 else { return }
    let channel = FlutterMethodChannel(name: "immich/timeline", binaryMessenger: engine.binaryMessenger)
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000) {
      shellLog("[shell:nav] debug: opening an album")
      channel.invokeMethod("debugPushAlbum", arguments: nil)
    }
  }
  private func scheduleDebugRepush() {
    guard Self.cyclesLeft > 0, let name = UserDefaults.standard.string(forKey: "immichShellPushRoute") else { return }
    Self.cyclesLeft -= 1
    let left = Self.cyclesLeft
    DispatchQueue.main.asyncAfter(deadline: .now() + cycleDelay) {
      shellLog("[shell:nav] debug: cycle re-push %@ (%d left after this)", name, left)
      self.channel?.invokeMethod("debugPush", arguments: ["name": name])
    }
  }

  func scheduleDebugBarAction() {
    let delay = UserDefaults.standard.integer(forKey: "immichShellTapBarAction")
    guard delay > 0 else { return }
    for (index, offset) in [Double(delay) / 1000, Double(delay) / 1000 + 1.5].enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
        guard let top = self.activeNavigationController?.viewControllers.last,
              let item = top.navigationItem.rightBarButtonItems?.first else {
          shellLog("[shell:nav] debug: no bar action to tap")
          return
        }
        if item.menu != nil, let frame = top as? FlutterStackController {
          shellLog("[shell:nav] debug: choosing menu row %d", index)
          if !frame.debugPerformMenu(action: 0, row: index) {
            shellLog("[shell:nav] debug: no menu row %d", index)
          }
          return
        }
        guard let target = item.target, let action = item.action else {
          shellLog("[shell:nav] debug: bar action has neither menu nor target")
          return
        }
        shellLog("[shell:nav] debug: tapping bar action, pass %d", index + 1)
        _ = target.perform(action, with: item)
      }
    }
  }

  func scheduleDebugDartTab() {
    guard let tab = UserDefaults.standard.string(forKey: "immichShellDartTab") else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
      shellLog("[shell] debug: asking dart to switch to %@", tab)
      self?.channel?.invokeMethod("debugTab", arguments: ["tab": tab])
    }
  }
}

extension NativeShellController {
  func scheduleDebugTabHooks() {
    if let name = UserDefaults.standard.string(forKey: "immichShellTab"), index(ofTab: name) != nil {
      select(tabId: name)
      shellLog("[shell] initial tab=%@", name)
    }

    if let delay = UserDefaults.standard.string(forKey: "immichShellRetap"), let seconds = Double(delay) {
      DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
        guard let self, let id = self.selectedTabId else { return }
        shellLog("[shell] debug: re-tapping the selected tab")
        self.reselect(tabId: id)
      }
    }

    guard let names = UserDefaults.standard.string(forKey: "immichShellSwitchTo") else { return }
    for (step, name) in names.split(separator: ",").enumerated() {
      let id = String(name)
      guard index(ofTab: id) != nil else { continue }
      DispatchQueue.main.asyncAfter(deadline: .now() + 6 + Double(step) * 4) { [weak self] in
        shellLog("[shell] debug: switching to tab=%@", id)
        self?.select(tabId: id)
        self?.announceSelectedTab()
      }
    }
  }
}

#else

extension ShellBridge {
  func scheduleDebugHooks() {}
  func scheduleDebugPop(on nav: UINavigationController) {}
  func scheduleDebugViewer(on engine: FlutterEngine) {}
  func scheduleDebugAlbum(on engine: FlutterEngine) {}
}

extension NativeShellController {
  func scheduleDebugTabHooks() {}
}

#endif
