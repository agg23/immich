import UIKit

/// Zoom a grid tile into the viewer and back.
///
/// There is no stock version of this to inherit the way a push has one, so it
/// is hand written. Ported from the `flutter-native-containers` spike, where
/// the T rungs proved the shape against both an all-native grid and a Flutter
/// one. The seam there was asynchronous, because asking a Flutter grid where a
/// tile is costs a channel round trip; Immich's photos grid is a native
/// `UICollectionView`, so here it answers immediately and the protocol is
/// synchronous. Restore the async form if a Flutter grid ever drives this.
protocol ZoomTransitionSource: AnyObject {
  /// Frame of an item **in the source controller's own view coordinates**.
  ///
  /// Not window coordinates, which is the obvious choice and is wrong: by the
  /// time a dismissal asks, the completed push has removed the grid's view from
  /// the window, and converting against no window silently answers in some
  /// other space — the dismissal then flies to the top-left corner. The
  /// animator converts once it has put the grid's view back in the container.
  func zoomSourceFrame(forIndex index: Int) -> CGRect?
  /// The picture to fly, at whatever fidelity the source already has.
  func zoomSourceImage(forIndex index: Int) -> UIImage?
  /// Hide the tile so the flying copy is the only one of it on screen.
  func setZoomItem(_ index: Int, hidden: Bool)
  /// Bring an item into view so a dismissal has somewhere to land.
  func scrollZoomItemIntoView(_ index: Int)
}

/// The viewer's half: the animator hides its content for the flight so exactly
/// one copy of the photo is on screen at any moment.
protocol ZoomTransitionDestination: AnyObject {
  var zoomIndex: Int { get }
  func zoomImage() -> UIImage?
  func setZoomContentHidden(_ hidden: Bool)
}

final class ZoomTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  private let presenting: Bool
  private weak var source: (ZoomTransitionSource & UIViewController)?

  init(presenting: Bool, source: (ZoomTransitionSource & UIViewController)?) {
    self.presenting = presenting
    self.source = source
    super.init()
  }

  func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
    UserDefaults.standard.bool(forKey: "immichShellSlowAnimations") ? 2.0 : 0.42
  }

  func animateTransition(using context: UIViewControllerContextTransitioning) {
    let container = context.containerView
    guard let toVC = context.viewController(forKey: .to),
          let fromVC = context.viewController(forKey: .from)
    else {
      context.completeTransition(false)
      return
    }

    let viewer = (presenting ? toVC : fromVC) as? (ZoomTransitionDestination & UIViewController)
    let finalFrame = context.finalFrame(for: toVC)

    if presenting {
      toVC.view.frame = finalFrame
      container.addSubview(toVC.view)
    } else {
      container.insertSubview(toVC.view, belowSubview: fromVC.view)
      toVC.view.frame = finalFrame
    }

    // A dismissal may be landing on a tile that was never on screen, because
    // the viewer paged somewhere else. Ask for it before measuring.
    let index = viewer?.zoomIndex ?? 0
    if !presenting {
      source?.scrollZoomItemIntoView(index)
    }
    // Both directions, not just the dismissal: a grid can have a computed
    // layout and no cells yet, and then the rect resolves while the picture
    // does not. Forcing the pass realises the cell the flight wants to copy.
    source?.view.layoutIfNeeded()

    // Resolved here rather than at tap time: the grid's view is in the
    // container by now in both directions, so this conversion has a real
    // hierarchy behind it.
    let sourceFrame = source.flatMap { grid in
      grid.zoomSourceFrame(forIndex: index).map { grid.view.convert($0, to: container) }
    }
    // Whichever side already has the better picture, and in an order that
    // does not depend on layout timing: on the way in the viewer has not
    // scrolled to the asset yet, so asking it would answer for whatever cell
    // happens to sit at the centre. On the way out it holds the HDR original,
    // which is the one worth flying home.
    let image = presenting
      ? (source?.zoomSourceImage(forIndex: index) ?? viewer?.zoomImage())
      : (viewer?.zoomImage() ?? source?.zoomSourceImage(forIndex: index))

    guard let sourceFrame, let image else {
      // Nothing to fly from or to. A cross-fade beats animating to garbage.
      // Which of the two is missing matters: a missing rect is a layout
      // question, a missing image is a cache question, and they are fixed in
      // different places.
      shellLog(
        "[shell:zoom] cross-fading index=%d rect=%@ image=%@ source=%@",
        index,
        sourceFrame == nil ? "MISSING" : "ok",
        image == nil ? "MISSING" : "ok",
        source == nil ? "MISSING" : "ok"
      )
      toVC.view.alpha = presenting ? 0 : 1
      UIView.animate(withDuration: transitionDuration(using: context)) {
        toVC.view.alpha = 1
        if !self.presenting { fromVC.view.alpha = 0 }
      } completion: { _ in
        fromVC.view.alpha = 1
        context.completeTransition(!context.transitionWasCancelled)
      }
      return
    }

    source?.setZoomItem(index, hidden: true)

    // A plain image view rather than the viewer's own, so the viewer never has
    // to be half-built mid-flight.
    let flying = UIImageView(image: image)
    flying.contentMode = .scaleAspectFill
    flying.clipsToBounds = true
    if #available(iOS 17.0, *) {
      flying.preferredImageDynamicRange = .high
    }

    let expandedFrame = Self.aspectFit(image.size, in: finalFrame)
    flying.frame = presenting ? sourceFrame : expandedFrame
    container.addSubview(flying)

    shellLog(
      "[shell:zoom] flight presenting=%@ index=%d from=%@ to=%@",
      presenting ? "yes" : "no",
      index,
      NSCoder.string(for: presenting ? sourceFrame : expandedFrame),
      NSCoder.string(for: presenting ? expandedFrame : sourceFrame)
    )

    viewer?.setZoomContentHidden(true)
    let backdrop = viewer?.view
    backdrop?.alpha = presenting ? 0 : 1

    UIView.animate(
      withDuration: transitionDuration(using: context),
      delay: 0,
      usingSpringWithDamping: 0.92,
      initialSpringVelocity: 0,
      options: [.curveEaseInOut],
      animations: {
        flying.frame = self.presenting ? expandedFrame : sourceFrame
        backdrop?.alpha = self.presenting ? 1 : 0
      },
      completion: { _ in
        flying.removeFromSuperview()
        viewer?.setZoomContentHidden(false)
        backdrop?.alpha = 1
        let finished = !context.transitionWasCancelled
        // The tile is hidden exactly while the viewer is covering the grid, so
        // there is never both a flying copy and a tile, and never a hole. A
        // cancelled dismissal leaves the viewer up and so keeps it hidden.
        let viewerEndsUpCovering = self.presenting == finished
        self.source?.setZoomItem(index, hidden: viewerEndsUpCovering)
        context.completeTransition(finished)
      }
    )
  }

  static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0 else { return bounds }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    let fitted = CGSize(width: size.width * scale, height: size.height * scale)
    return CGRect(
      x: bounds.midX - fitted.width / 2,
      y: bounds.midY - fitted.height / 2,
      width: fitted.width,
      height: fitted.height
    )
  }
}
