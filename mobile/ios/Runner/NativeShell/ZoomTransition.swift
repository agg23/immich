import UIKit

protocol ZoomTransitionSource: AnyObject {
  func zoomSourceFrame(forIndex index: Int) -> CGRect?
  func zoomSourceImage(forIndex index: Int) -> UIImage?
  func setZoomItem(_ index: Int, hidden: Bool)
  func scrollZoomItemIntoView(_ index: Int)
}

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

    let index = viewer?.zoomIndex ?? 0
    if !presenting {
      source?.scrollZoomItemIntoView(index)
    }
    source?.view.layoutIfNeeded()

    let sourceFrame = source.flatMap { grid in
      grid.zoomSourceFrame(forIndex: index).map { grid.view.convert($0, to: container) }
    }
    let image = presenting
      ? (source?.zoomSourceImage(forIndex: index) ?? viewer?.zoomImage())
      : (viewer?.zoomImage() ?? source?.zoomSourceImage(forIndex: index))

    guard let sourceFrame, let image else {
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
