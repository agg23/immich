import Flutter
import UIKit

/// The one Flutter engine behind every Flutter surface in the native shell.
///
/// Immich normally lets Flutter own the window: the storyboard instantiates a
/// `FlutterViewController`, which creates an *implicit* engine, and
/// `FlutterSceneDelegate` puts it on screen. That path is convenient and gives
/// us no handle on the engine, because `FlutterImplicitEngineBridge` exposes
/// only a plugin registry and a messenger — never the engine itself. A native
/// shell has to host the surface in its own containers, so it needs the engine
/// object, which means creating it explicitly and registering the plugins by
/// hand.
///
/// One engine for all of it, not one per tab. Engines do not share a Dart
/// isolate, so a second engine would mean a second riverpod graph, a second
/// drift connection and a second SQLite page cache — and Immich's page cache
/// alone is 32MB by configuration. The surface is rebuilt in whichever
/// container should have it instead; sibling tabs are never visible at once.
///
/// One engine also means one surface, so exactly one container can be live at a
/// time. Everything below is about deciding which — and the answer is not
/// "whichever container is appearing". During an interactive swipe-back two
/// containers are on screen and the one being *left* is the one Dart is
/// drawing. Every other container shows a still.
final class ShellEngine {
  static let shared = ShellEngine()

  let engine: FlutterEngine

  /// The container currently holding the surface.
  private weak var holder: ShellFlutterHost?
  private var flutterVC: FlutterViewController?
  private var attachCount = 0

  /// Containers on screen, in the order they appeared.
  private var visible: [ShellFlutterHost] = []

  /// What Dart last said it is drawing. The surface belongs to whichever
  /// visible container owns this, and to no other.
  private var dartSurface = ""

  /// Whether a settle request is outstanding, so a burst of routing events does
  /// not queue one each.
  private var settling = false

  /// How long a container will wait for Dart before showing the live surface
  /// regardless.
  ///
  /// A deadline rather than a promise: a placement that never settles would
  /// otherwise leave a frozen image on screen forever, which is a worse failure
  /// than a brief flash.
  private static let settleDeadline: DispatchTimeInterval = .milliseconds(700)

  private init() {
    engine = FlutterEngine(name: "immich-shell", project: nil, allowHeadlessExecution: true)
    let started = engine.run()
    NSLog("[shell] engine run=%@", started ? "yes" : "no")
    // The same registration the implicit path would have done for us.
    GeneratedPluginRegistrant.register(with: engine)
    AppDelegate.registerPlugins(with: engine, messenger: engine.binaryMessenger)
    ShellBridge.shared.attach(to: engine)
    ShellBridge.shared.scheduleDebugViewer(on: engine)
  }

  // MARK: - What is on screen

  func hostBecameVisible(_ host: ShellFlutterHost) {
    if !visible.contains(where: { $0 === host }) {
      visible.append(host)
    }
    // A tab container is also the *instruction* to change tabs: the native tab
    // bar is what tells Dart which tab is active. A mirrored stack frame is not
    // — Dart pushed that route itself and is already showing it.
    if !host.shellRoute.isEmpty {
      ShellBridge.shared.show(route: host.shellRoute) { [weak self] surface in
        self?.dartIsShowing(surface)
      }
    }
    updatePlacement()
  }

  func hostDisappeared(_ host: ShellFlutterHost) {
    visible.removeAll { $0 === host }
    // The container that left may have been the one holding the surface, in
    // which case there is now nothing live on screen and someone has to be
    // given it.
    updatePlacement()
  }

  /// Dart has said what it is drawing.
  ///
  /// `overlay` means Flutter has something of its own over the page — the asset
  /// viewer, which fades in over the page it was opened from and is not a stack
  /// frame. The container keeps the surface, because the content underneath is
  /// still its own, but it has to stop drawing native chrome over the top of it.
  func dartIsShowing(_ surface: String, overlay: Bool = false) {
    dartSurface = surface
    if overlayPresent != overlay {
      overlayPresent = overlay
      NSLog("[shell] flutter overlay %@", overlay ? "opened" : "closed")
      holder?.applyChrome(overlayPresent: overlay)
    }
    updatePlacement()
  }

  /// Whether Flutter is drawing one of its own overlays over everything.
  private(set) var overlayPresent = false

  /// Whether `host` currently owns the surface, so a container does not report
  /// its geometry over a surface that has moved on.
  func holds(_ host: ShellFlutterHost) -> Bool { holder === host }

  // MARK: - Placement

  /// Put the surface in the container Dart is drawing, and reveal it only once
  /// Dart has confirmed a frame for it.
  ///
  /// This was `claim(by:)`, called from `viewWillAppear`, which took the surface
  /// on the way in and asked Dart to catch up. That is backwards during an
  /// interactive pop: the gesture can still be abandoned, so Dart must not be
  /// moved; so the container being revealed is not the one Dart is drawing; so
  /// taking the surface from the outgoing frame put the *outgoing* page in the
  /// incoming slot for the whole drag.
  private func updatePlacement() {
    if let desired = visible.last(where: { $0.surfaceToken == dartSurface }) {
      if holder !== desired || flutterVC == nil {
        attachSurface(to: desired)
      }
      confirmFrame(for: desired)
      return
    }

    // Dart is drawing something none of the visible containers owns. If the
    // container holding the surface is still on screen, leave it there: that is
    // the ordinary mid-swipe state, where the live page is the one being dragged
    // away under the user's thumb and everything else shows a still.
    if let holder, visible.contains(where: { $0 === holder }) {
      NSLog(
        "[shell] dart is showing %@; surface stays with %@ until dart moves",
        dartSurface.isEmpty ? "(nothing)" : dartSurface,
        holder.shellLabel
      )
      return
    }

    // The holder has left the screen, so nothing on screen is live and the user
    // is looking at a photograph of the app. This is the ordinary way round for
    // a tab switch — the outgoing tab goes before Dart answers — and the only
    // recovery if the two sides have genuinely lost each other. Hand the surface
    // to whatever is in front; it stays behind its still until Dart confirms, or
    // until the deadline gives up. A page that is briefly the wrong one
    // recovers; a frozen one does not.
    guard let front = visible.last else { return }
    NSLog("[shell] nothing live on screen; surface goes to %@ ahead of dart", front.shellLabel)
    attachSurface(to: front)
    // Ask straight away rather than waiting for the answer to whatever question
    // is already outstanding. Without this the reveal costs an extra round trip
    // and a tab switch runs into the deadline instead of settling inside it.
    confirmFrame(for: front)
  }

  /// Build a fresh `FlutterViewController` for `host` and move the surface into
  /// it.
  ///
  /// Fresh, not re-parented. Moving a live controller's view between containers
  /// leaves the old raster behind: the accessibility tree and the Dart state are
  /// correct while the pixels are a frame from the previous container, with no
  /// callback to tell you. A new controller per move costs ~40ms warm and always
  /// renders.
  private func attachSurface(to host: ShellFlutterHost) {
    attachCount += 1
    let attach = attachCount
    let startedAt = CFAbsoluteTimeGetCurrent()

    if let vc = flutterVC {
      // Whatever the old container does next — slide away, sit behind a push,
      // wait to be returned to — it has to show something, and the surface is
      // leaving. This is the still Flutter took of it after it last settled.
      holder?.installStill()
      vc.willMove(toParent: nil)
      vc.view.removeFromSuperview()
      vc.removeFromParent()
      flutterVC = nil
    }

    // Dart lays out for the container the surface is going *to*, so it has to
    // be told the new geometry before the surface moves rather than after. Sent
    // here, the relayout happens while this controller is being built; sent
    // afterwards, it happens in a view that is already on screen, and the first
    // frames that view produces are laid out for the container the surface just
    // left.
    host.view.layoutIfNeeded()
    host.reportSettledInsets()

    let vc = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    vc.view.backgroundColor = .systemBackground
    flutterVC = vc
    vc.setFlutterViewDidRenderCallback {
      NSLog("[shell] attach#%d first frame=%.1fms", attach, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    }

    host.addChild(vc)
    // `addChild` only establishes the controller relationship; the view still
    // has to be added before anything can be constrained to it.
    host.flutterContainer.addSubview(vc.view)
    host.pinFlutterSurface(vc.view)
    vc.didMove(toParent: host)
    holder = host

    NSLog("[shell] attach#%d host=%@ token=%@", attach, host.shellLabel, host.surfaceToken)

    // Before Dart is running there is nothing correct to wait for and nothing
    // wrong to hide: the surface renders the splash and that is the right
    // answer. Gating here would blank the app for the length of the deadline.
    guard ShellBridge.shared.isReady else {
      host.clearStill()
      return
    }

    // Dart's route is right, but the frame for it may not be built yet. Hide the
    // live surface behind this container's own still until Dart confirms one.
    //
    // `alpha`, not `isHidden`: a hidden Flutter view can stop being asked for
    // frames, and this code is waiting for one.
    vc.view.alpha = 0
    host.bringStillToFront()

    DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDeadline) { [weak self, weak host] in
      guard let host, self?.holder === host, host.isWaitingForDart else { return }
      NSLog("[shell] attach#%d settle deadline expired", attach)
      host.reveal()
    }
  }

  /// Ask Dart to confirm it has built and rastered a frame, and reveal the
  /// surface if what it confirms is what this container owns.
  private func confirmFrame(for host: ShellFlutterHost) {
    guard host.isWaitingForDart, !settling else { return }
    settling = true
    let startedAt = CFAbsoluteTimeGetCurrent()
    // No route named: this is a question, not an instruction. The tab change, if
    // there was one, was asked for when the container appeared.
    ShellBridge.shared.show(route: "") { [weak self] surface in
      guard let self else { return }
      settling = false
      dartSurface = surface
      guard let holder, holder.surfaceToken == surface else {
        // Dart moved on while we were asking. Start again from what it says now.
        updatePlacement()
        return
      }
      NSLog("[shell] %@ revealed in %.1fms", holder.shellLabel, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
      holder.reveal()
      // With the right thing on screen, take the picture that will stand in for
      // this container the next time the surface is somewhere else.
      keepStill(of: holder)
    }
  }

  /// Store a still of what this container is showing, for later.
  ///
  /// Taken after a reveal rather than on the way out: by the time a container is
  /// losing the surface Dart has usually already moved on, and the picture would
  /// be of the *next* page. A container's content does not change while it is
  /// not being shown, so a still from its last visit is still accurate.
  private func keepStill(of host: ShellFlutterHost) {
    ShellBridge.shared.capture { [weak host] image in
      guard let image else { return }
      host?.still = image
    }
  }
}

/// A native container that can host the shared Flutter surface.
///
/// Containers are responsible for telling Dart what part of their surface is
/// obscured: a Flutter page hosted under a native navigation bar and a native
/// tab bar has no way of knowing either exists. Flutter's own view fills the
/// container, so its `MediaQuery.padding` is the window's — the status bar and
/// the home indicator — and every page that lays out against `context.padding`
/// draws underneath the native chrome.
protocol ShellFlutterHost: UIViewController {
  /// The view the surface is installed into.
  var flutterContainer: UIView { get }
  /// The route this container asks Dart to show when it appears. Empty for a
  /// container that shows whatever Dart already has — a mirrored stack frame, or
  /// the launch surface.
  var shellRoute: String { get }
  /// What Dart calls the content this container owns: a tab name for a tab root,
  /// a route name for a mirrored stack frame. Compared against Dart's own answer
  /// to decide where the surface belongs.
  var surfaceToken: String { get }
  var shellLabel: String { get }
  /// Whether this container wants the native navigation bar out of the way even
  /// when nothing is covering it — true for pages that draw their own header.
  var prefersNativeBarHidden: Bool { get }
  /// A picture of this container's content, taken by Flutter while it was live.
  var still: UIImage? { get set }
  /// How the surface is constrained inside the container. Separate from
  /// `flutterContainer` because a scroll-driven container pins to its
  /// `frameLayoutGuide` rather than to its content.
  func pinFlutterSurface(_ surface: UIView)
}

extension ShellFlutterHost {
  /// Push this container's obscured edges to Dart.
  ///
  /// `view.safeAreaInsets` is exactly the right number and UIKit has already
  /// worked it out: inside a navigation controller it includes the bar, inside a
  /// tab bar controller it includes the tab bar, and it is in points.
  func reportInsets() {
    guard ShellEngine.shared.holds(self) else { return }
    reportSettledInsets()
  }

  /// The insets this container will have once it has finished appearing.
  ///
  /// Separate from `reportInsets()` because it is also called on the way in,
  /// before this container holds the surface, and so cannot ask whether it does.
  func reportSettledInsets() {
    var insets = view.safeAreaInsets
    // A container that hides the tab bar is measured while UIKit is still
    // taking the bar away, so the first reading counts a bar that is on its way
    // out. Reporting it costs Dart an entire relayout of the tree for a number
    // that is about to change again — which is exactly what a push used to do,
    // twice per push. The settled value is the window's own bottom inset; UIKit
    // still supplies it, we just have to ask the right view.
    if hidesBottomBarWhenPushed, let window = view.window {
      insets.bottom = window.safeAreaInsets.bottom
    }
    // A placement happens before the container has been laid out, so the first
    // reading is all zeros — and Dart acting on it lays the page out under the
    // status bar for a frame before the real number arrives. Every container in
    // this shell sits under at least a status bar, so all-zero means "not
    // measured yet", not "nothing is covering me".
    guard insets != .zero else { return }
    ShellBridge.shared.report(insets: insets)
  }

  /// Show or withdraw this container's native chrome.
  ///
  /// A Flutter overlay covers the whole surface, so the native bar would be
  /// drawn on top of a full-screen viewer, and the swipe-back would pop the page
  /// the viewer was opened *from* while the viewer is still up. Both belong to
  /// the page underneath, and the page underneath is not what the user is
  /// looking at.
  func applyChrome(overlayPresent: Bool) {
    // Animated only when there is a transition for it to ride along with. A tab
    // switch has none — the tab bar changes content instantly — so animating the
    // bar there is a third thing moving on its own schedule next to a switch
    // that has already happened.
    let animated = transitionCoordinator != nil
    navigationController?.setNavigationBarHidden(prefersNativeBarHidden || overlayPresent, animated: animated)
    navigationController?.interactivePopGestureRecognizer?.isEnabled = !overlayPresent
  }

  /// Cover this container with its own last frame.
  ///
  /// The still is what makes an interactive swipe-back look like one: the page
  /// being revealed cannot be live, because the live surface is in the page
  /// being dragged away and the gesture can still be abandoned. Both pages are
  /// static during a drag, so a picture is not a compromise there.
  func installStill() {
    clearStill()
    guard let still else {
      NSLog("[shell] no still for %@ yet", shellLabel)
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

  /// Keep the still above the live surface, which is added after it.
  func bringStillToFront() {
    flutterContainer.subviews.filter { $0.tag == Self.stillTag }.forEach {
      flutterContainer.bringSubviewToFront($0)
    }
  }

  /// Whether this container is hiding its live surface — behind a still, or
  /// behind nothing — and so is still waiting on Dart.
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
