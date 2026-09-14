import Flutter
import UIKit

final class ShellEngine {
  static let shared = ShellEngine()

  let engine: FlutterEngine

  private weak var holder: ShellFlutterHost?
  private var flutterVC: FlutterViewController?
  private var attachCount = 0

  private var visible: [ShellFlutterHost] = []

  private var dartSurface = ""

  private var settling = false

  private static let settleDeadline: DispatchTimeInterval = .milliseconds(700)

  private init() {
    engine = FlutterEngine(name: "immich-shell", project: nil, allowHeadlessExecution: true)
    let started = engine.run()
    shellLog("[shell] engine run=%@", started ? "yes" : "no")
    GeneratedPluginRegistrant.register(with: engine)
    AppDelegate.registerPlugins(with: engine, messenger: engine.binaryMessenger)
    ShellBridge.shared.attach(to: engine)
    TimelineSessions.shared.attach(to: engine)
    ShellBridge.shared.scheduleDebugViewer(on: engine)
    ShellBridge.shared.scheduleDebugAlbum(on: engine)
  }


  func hostBecameVisible(_ host: ShellFlutterHost) {
    if !visible.contains(where: { $0 === host }) {
      visible.append(host)
    }
    if !host.shellRoute.isEmpty {
      ShellBridge.shared.show(route: host.shellRoute) { [weak self] surface in
        self?.dartIsShowing(surface)
      }
    }
    updatePlacement()
  }

  func hostDisappeared(_ host: ShellFlutterHost) {
    visible.removeAll { $0 === host }
    updatePlacement()
  }

  func dartIsShowing(_ surface: String, overlay: Bool = false) {
    dartSurface = surface
    if overlayPresent != overlay {
      overlayPresent = overlay
      shellLog("[shell] flutter overlay %@", overlay ? "opened" : "closed")
      holder?.applyChrome(overlayPresent: overlay)
    }
    updatePlacement()
  }

  private(set) var overlayPresent = false

  func holds(_ host: ShellFlutterHost) -> Bool { holder === host }


  /// The surface follows Dart; a container never claims it on the way in.
  private func updatePlacement() {
    if let desired = visible.last(where: { $0.surfaceToken == dartSurface }) {
      if holder !== desired || flutterVC == nil {
        attachSurface(to: desired)
      }
      confirmFrame(for: desired)
      return
    }

    if let holder, visible.contains(where: { $0 === holder }) {
      shellLog(
        "[shell] dart is showing %@; surface stays with %@ until dart moves",
        dartSurface.isEmpty ? "(nothing)" : dartSurface,
        holder.shellLabel
      )
      return
    }

    guard let front = visible.last else { return }
    shellLog("[shell] nothing live on screen; surface goes to %@ ahead of dart", front.shellLabel)
    attachSurface(to: front)
    confirmFrame(for: front)
  }

  /// Fresh, not re-parented: re-parenting leaves the old raster behind.
  private func attachSurface(to host: ShellFlutterHost) {
    attachCount += 1
    let attach = attachCount
    let startedAt = CFAbsoluteTimeGetCurrent()

    if let vc = flutterVC {
      holder?.installStill()
      vc.willMove(toParent: nil)
      vc.view.removeFromSuperview()
      vc.removeFromParent()
      flutterVC = nil
    }

    // Before the move: sent after, the first frames are laid out for the old one.
    host.view.layoutIfNeeded()
    host.reportSettledInsets()

    let vc = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    vc.view.backgroundColor = .systemBackground
    flutterVC = vc
    vc.setFlutterViewDidRenderCallback {
      shellLog("[shell] attach#%d first frame=%.1fms", attach, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    }

    host.addChild(vc)
    host.flutterContainer.addSubview(vc.view)
    host.pinFlutterSurface(vc.view)
    vc.didMove(toParent: host)
    holder = host

    shellLog("[shell] attach#%d host=%@ token=%@", attach, host.shellLabel, host.surfaceToken)

    guard ShellBridge.shared.isReady else {
      host.clearStill()
      return
    }

    // `alpha`, not `isHidden`: a hidden Flutter view stops producing frames.
    vc.view.alpha = 0
    host.bringStillToFront()

    DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDeadline) { [weak self, weak host] in
      guard let host, self?.holder === host, host.isWaitingForDart else { return }
      shellLog("[shell] attach#%d settle deadline expired", attach)
      host.reveal()
    }
  }

  private func confirmFrame(for host: ShellFlutterHost) {
    guard host.isWaitingForDart, !settling else { return }
    settling = true
    let startedAt = CFAbsoluteTimeGetCurrent()
    ShellBridge.shared.show(route: "") { [weak self] surface in
      guard let self else { return }
      settling = false
      dartSurface = surface
      guard let holder, holder.surfaceToken == surface else {
        updatePlacement() // Dart moved on while we were asking.
        return
      }
      shellLog("[shell] %@ revealed in %.1fms", holder.shellLabel, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
      holder.reveal()
      keepStill(of: holder)
    }
  }

  private func keepStill(of host: ShellFlutterHost) {
    ShellBridge.shared.capture { [weak host] image in
      guard let image else { return }
      host?.still = image
    }
  }
}

protocol ShellFlutterHost: UIViewController {
  var flutterContainer: UIView { get }
  var shellRoute: String { get }
  var surfaceToken: String { get }
  var shellLabel: String { get }
  var prefersNativeBarHidden: Bool { get }
  var prefersFullBleedTop: Bool { get }
  var still: UIImage? { get set }
  func pinFlutterSurface(_ surface: UIView)
}

extension ShellFlutterHost {
  var prefersFullBleedTop: Bool { false }

  func reportInsets() {
    guard ShellEngine.shared.holds(self) else { return }
    reportSettledInsets()
  }

  func reportSettledInsets() {
    var insets = view.safeAreaInsets
    // Measured mid-transition, so the first reading counts a bar on its way out.
    if hidesBottomBarWhenPushed, let window = view.window {
      insets.bottom = window.safeAreaInsets.bottom
    }
    // A cover photo already draws to the top edge; the bar must not inset it.
    if prefersFullBleedTop, let window = view.window {
      insets.top = window.safeAreaInsets.top
    }
    // Every container sits under a status bar, so all-zero means "not measured".
    guard insets != .zero else { return }
    ShellBridge.shared.report(insets: insets)
  }

  func applyChrome(overlayPresent: Bool) {
    let animated = transitionCoordinator != nil
    navigationController?.setNavigationBarHidden(prefersNativeBarHidden || overlayPresent, animated: animated)
    navigationController?.interactivePopGestureRecognizer?.isEnabled = !overlayPresent
  }

  func installStill() {
    clearStill()
    guard let still else {
      shellLog("[shell] no still for %@ yet", shellLabel)
      return
    }
    let image = UIImageView(image: still)
    image.tag = Self.stillTag
    image.contentMode = .scaleAspectFill
    image.frame = flutterContainer.bounds
    image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    flutterContainer.addSubview(image)
  }

  func clearStill() {
    flutterContainer.subviews.filter { $0.tag == Self.stillTag }.forEach { $0.removeFromSuperview() }
  }

  func bringStillToFront() {
    flutterContainer.subviews.filter { $0.tag == Self.stillTag }.forEach {
      flutterContainer.bringSubviewToFront($0)
    }
  }

  var isWaitingForDart: Bool {
    flutterContainer.subviews.contains { $0.tag == Self.stillTag || $0.alpha == 0 }
  }

  func reveal() {
    flutterContainer.subviews.forEach { if $0.tag != Self.stillTag { $0.alpha = 1 } }
    clearStill()
  }

  static var stillTag: Int { 0x5_A_F_E }

  func pinFlutterSurface(_ surface: UIView) {
    surface.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      surface.leadingAnchor.constraint(equalTo: flutterContainer.leadingAnchor),
      surface.trailingAnchor.constraint(equalTo: flutterContainer.trailingAnchor),
      surface.topAnchor.constraint(equalTo: flutterContainer.topAnchor),
      surface.bottomAnchor.constraint(equalTo: flutterContainer.bottomAnchor),
    ])
  }
}
