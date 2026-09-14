import UIKit

/// A native asset viewer, pushed from the native timeline.
///
/// Horizontally paged, one zoomable page per asset, fed by the same
/// `ImmichTimelineSource` the grid uses — so opening at index 4000 does not
/// load 4000 assets, it loads the page index 4000 falls in. The title is the
/// asset's date, which is what Photos does and what Immich's own viewer does.
///
/// Deliberately not a port of Immich's asset viewer. No video playback, no
/// edit, no info panel, no share sheet; those are the reason the real viewer
/// is worth keeping in Flutter for now. What this is for is the part a hybrid
/// has to get right regardless: a full-screen native push out of a native
/// grid, with real pixels in it.
final class AssetViewerController: UIViewController {
  private let source: ImmichTimelineSource
  private var index: Int
  private var collectionView: UICollectionView!

  /// Live only while a downward drag is dismissing the viewer. The navigation
  /// controller's delegate reads it to decide whether the pop is interactive.
  private(set) var activeInteraction: UIPercentDrivenInteractiveTransition?
  /// True once the pop has actually begun. UIKit will not accept scrubbing
  /// before that, and a fast flick can end before it does.
  private var interactionReady = false
  private var deferredCommit: Bool?

  /// Prototyping affordance: draw the same decoded image with and without its
  /// extended range, so the difference can be demonstrated rather than
  /// asserted. Deliberately a *display* switch and not a decode switch - the
  /// bytes, the fetch and the decode are identical in both states, so what the
  /// eye is comparing is exactly one variable. Flipping the decode instead
  /// would also change which file was fetched, and prove less.
  private var hdrEnabled = true

  /// Told when the viewer is gone for good, so whoever opened it can let go of
  /// what it was reading. A viewer pushed from a Flutter page holds a timeline
  /// session Dart is serving; the grid's own viewer holds session 0 and this
  /// does nothing.
  var onClosed: (() -> Void)?

  init(source: ImmichTimelineSource, startIndex: Int) {
    self.source = source
    index = startIndex
    super.init(nibName: nil, bundle: nil)
    hidesBottomBarWhenPushed = true
  }

  deinit {
    source.removeObserver(self)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    navigationItem.largeTitleDisplayMode = .never

    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.minimumLineSpacing = 0
    layout.minimumInteritemSpacing = 0

    collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.isPagingEnabled = true
    collectionView.backgroundColor = .systemBackground
    collectionView.showsHorizontalScrollIndicator = false
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.register(AssetPageCell.self, forCellWithReuseIdentifier: AssetPageCell.reuseID)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(collectionView)
    NSLayoutConstraint.activate([
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.topAnchor.constraint(equalTo: view.topAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    if #available(iOS 17.0, *) {
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        title: "HDR",
        style: .plain,
        target: self,
        action: #selector(toggleHDR)
      )
    }

    // Coming back from the background is a state change nothing else reports.
    // The button is computed from the current image, and without this it keeps
    // whatever it last said - which is how it came to claim HDR over a picture
    // that is no longer HDR.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    // A purged decode is one of the three candidates, and a memory warning is
    // the thing that would cause it. Worth knowing whether one arrived.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didReceiveMemoryPressure),
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )

    let dismiss = UIPanGestureRecognizer(target: self, action: #selector(handleDismissDrag))
    dismiss.delegate = self
    view.addGestureRecognizer(dismiss)

    // `-immichShellHdrToggle <seconds>` flips the switch on a timer, so both
    // states can be logged from a script. A bar-button tap cannot be driven on
    // a physical device, and "the button exists" is not evidence that the two
    // states differ.
    if let delay = Double(UserDefaults.standard.string(forKey: "immichShellHdrToggle") ?? "") {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.toggleHDR()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.toggleHDR() }
      }
    }

    // `-immichShellPageBy <n>` pages the viewer programmatically, which runs
    // exactly the dequeue-and-configure path a swipe runs. A swipe cannot be
    // driven on a physical device, and the first page is not evidence about the
    // second.
    if let steps = Int(UserDefaults.standard.string(forKey: "immichShellPageBy") ?? "") {
      for step in 1 ... max(1, steps) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8 + Double(step) * 4) { [weak self] in
          guard let self else { return }
          let next = self.index + 1
          guard next < self.source.total else { return }
          shellLog("[shell:page] paging to %d", next)
          self.collectionView.setContentOffset(
            CGPoint(x: CGFloat(next) * self.collectionView.bounds.width, y: 0),
            animated: true
          )
        }
      }
    }

    // A viewer opened from the grid has its data already. One opened from a
    // Flutter page does not: Dart subscribes to that page's timeline when the
    // route is intercepted, so the first buckets can land after this view is
    // on screen. Without this the viewer would be permanently empty in exactly
    // the case it was built for.
    source.addObserver(
      self,
      bucketsChanged: { [weak self] in
        guard let self else { return }
        self.collectionView.reloadData()
        self.jumpToCurrentIndex()
        self.updateTitle()
      },
      pageLoaded: { [weak self] _ in
        guard let self else { return }
        self.collectionView.reloadItems(at: self.collectionView.indexPathsForVisibleItems)
        self.updateTitle()
      }
    )

    updateTitle()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // `isMovingFromParent` rather than `willMove`, which is where this was
    // first written and where the transition coordinator is still nil -- an
    // abandoned swipe-back would have closed the session under a viewer that
    // is still on screen.
    guard isMovingFromParent else { return }
    onClosed?()
    onClosed = nil
  }

  /// Drag down to put the photo back in the grid.
  ///
  /// The gesture drives `UIPercentDrivenInteractiveTransition`, which scrubs
  /// the same zoom animator the push used, so a cancelled drag rewinds the
  /// flight rather than playing a second animation.
  @objc private func handleDismissDrag(_ gesture: UIPanGestureRecognizer) {
    let translation = gesture.translation(in: view).y
    let progress = max(0, min(1, translation / (view.bounds.height * 0.4)))

    switch gesture.state {
    case .began:
      guard translation > 0 else {
        gesture.state = .cancelled
        return
      }
      activeInteraction = UIPercentDrivenInteractiveTransition()
      interactionReady = false
      deferredCommit = nil
      navigationController?.popViewController(animated: true)
      interactionReady = true
      if let commit = deferredCommit {
        deferredCommit = nil
        settle(commit: commit)
      }

    case .changed:
      if interactionReady { activeInteraction?.update(progress) }

    case .ended, .cancelled, .failed:
      let velocity = gesture.velocity(in: view).y
      // A flick counts even when it barely moved, which is what makes this
      // feel like Photos rather than like a progress bar.
      let commit = progress > 0.3 || velocity > 800
      shellLog("[shell:zoom] drag progress=%.2f velocity=%d commit=%@", progress, Int(velocity), commit ? "yes" : "no")
      if interactionReady {
        settle(commit: commit)
      } else {
        deferredCommit = commit
      }

    default:
      break
    }
  }

  private func settle(commit: Bool) {
    if commit {
      activeInteraction?.finish()
    } else {
      activeInteraction?.cancel()
    }
    activeInteraction = nil
    interactionReady = false
  }

  @objc private func appDidBecomeActive() {
    guard #available(iOS 17.0, *) else { return }
    let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? AssetPageCell
    // Three things can have moved while the app was away and they are fixed in
    // different places: the image can have lost its HDR content (a purged
    // decode), the view can have lost its setting, or the display can simply
    // not have ramped its headroom back up yet. Logged apart so the next build
    // addresses the one that actually happened.
    shellLog(
      "[shell:hdr] foreground image=%@ view=%ld screen=%.2f switch=%@",
      cell?.pageImage?.isHighDynamicRange == true ? "hdr" : "sdr",
      cell?.viewDynamicRange ?? -1,
      UIScreen.main.currentEDRHeadroom,
      hdrEnabled ? "on" : "off"
    )
    // Re-assert the setting and recompute the label from what is actually on
    // screen. Cheap, and correct whichever of the three it turns out to be.
    applyDynamicRange()
    sampleHeadroom()
  }

  /// Follow `currentEDRHeadroom` for a few seconds after returning.
  ///
  /// A single reading said 1.00 where every other sample said 8.00, which is
  /// consistent with the panel ramping rather than with the image or the view
  /// having lost anything - but one reading is an inference, and the shape of
  /// the curve is what settles it. Also says how long the warm-up takes, which
  /// is the part anyone demonstrating this needs to know.
  private func sampleHeadroom() {
    guard #available(iOS 17.0, *) else { return }
    for delay in [0.0, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        shellLog("[shell:hdr] headroom +%.2fs %.2f", delay, UIScreen.main.currentEDRHeadroom)
      }
    }
  }

  @objc private func didReceiveMemoryPressure() {
    shellLog("[shell:hdr] memory warning while viewing")
  }

  @objc private func toggleHDR() {
    hdrEnabled.toggle()
    applyDynamicRange()
    guard #available(iOS 17.0, *) else { return }
    let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? AssetPageCell
    // The view's own answer, not the value just written to it: if these ever
    // disagree the switch is not doing what the demo claims.
    shellLog(
      "[shell:hdr] switch=%@ view=%ld image=%@ button=%@",
      hdrEnabled ? "on" : "off",
      cell?.viewDynamicRange ?? -1,
      cell?.pageImage?.isHighDynamicRange == true ? "hdr" : "sdr",
      navigationItem.rightBarButtonItem?.title ?? "-"
    )
  }

  /// Push the current setting into every page that exists, and say on the
  /// button whether this particular photo has anything to show.
  private func applyDynamicRange() {
    for cell in collectionView.visibleCells.compactMap({ $0 as? AssetPageCell }) {
      cell.setDynamicRangeEnabled(hdrEnabled)
    }
    updateHDRButton()
  }

  func updateHDRButton() {
    guard #available(iOS 17.0, *), let item = navigationItem.rightBarButtonItem else { return }
    let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? AssetPageCell
    // An SDR photo would toggle to no visible effect, which would read as the
    // feature being broken. Say so instead.
    guard cell?.pageImage?.isHighDynamicRange == true else {
      shellLog(
        "[shell:page] button disabled: index=%d cell=%@ image=%@",
        index,
        cell == nil ? "absent" : "present",
        cell?.pageImage == nil ? "none" : "sdr"
      )
      item.title = "SDR file"
      item.isEnabled = false
      return
    }
    item.isEnabled = true
    item.title = hdrEnabled ? "HDR on" : "HDR off"
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(false, animated: animated)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }
    let size = collectionView.bounds.size
    guard size.width > 0, layout.itemSize != size else { return }
    layout.itemSize = size
    // First layout: jump to the tapped asset without an animation, before the
    // push transition has finished, so the viewer never shows the wrong photo.
    jumpToCurrentIndex()
  }

  private func jumpToCurrentIndex() {
    let width = collectionView.bounds.width
    guard width > 0, index < source.total else { return }
    collectionView.setContentOffset(CGPoint(x: CGFloat(index) * width, y: 0), animated: false)
  }

  private func updateTitle() {
    guard let asset = source.asset(at: index) else { return }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    title = formatter.string(from: asset.createdAt)
  }
}

extension AssetViewerController: UIGestureRecognizerDelegate {
  /// Let the drag run alongside the paging scroll view, but only downward and
  /// only when the photo is not zoomed in - otherwise panning around a
  /// magnified photo would dismiss the viewer.
  func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
    guard let pan = gesture as? UIPanGestureRecognizer else { return true }
    let velocity = pan.velocity(in: view)
    guard abs(velocity.y) > abs(velocity.x) * 1.5, velocity.y > 0 else { return false }
    let page = collectionView.visibleCells.compactMap { $0 as? AssetPageCell }.first
    return page?.isZoomedIn != true
  }

  func gestureRecognizer(
    _ gesture: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    true
  }
}

extension AssetViewerController: ZoomTransitionDestination {
  var zoomIndex: Int { index }

  func zoomImage() -> UIImage? {
    // Addressed by the index the viewer is actually on, not by hit-testing the
    // centre: the two agree only once paging has settled, and a transition can
    // ask before it has.
    guard let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? AssetPageCell
    else { return nil }
    return cell.pageImage
  }

  func setZoomContentHidden(_ hidden: Bool) {
    collectionView.isHidden = hidden
  }
}

extension AssetViewerController: UICollectionViewDataSource, UICollectionViewDelegate {
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    source.total
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: AssetPageCell.reuseID,
      for: indexPath
    ) as! AssetPageCell
    cell.configure(source.asset(at: indexPath.item), width: collectionView.bounds.width)
    // A page built while the switch is off has to come up off too.
    cell.setDynamicRangeEnabled(hdrEnabled)
    cell.onImageChanged = { [weak self] in self?.updateHDRButton() }
    return cell
  }

  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    // A programmatic scroll does not decelerate, so the delegate callback the
    // real swipe uses never fires and the viewer would keep describing the
    // page it left.
    scrollViewDidEndDecelerating(scrollView)
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    let width = scrollView.bounds.width
    guard width > 0 else { return }
    index = Int((scrollView.contentOffset.x / width).rounded())
    source.prefetch(around: index)
    updateTitle()
    updateHDRButton()
  }
}

/// One full-screen, zoomable asset.
private final class AssetPageCell: UICollectionViewCell {
  static let reuseID = "page"

  private let scrollView = UIScrollView()
  private let imageView = UIImageView()
  private var previewToken: ThumbnailLoader.Token?
  private var originalToken: ThumbnailLoader.Token?
  /// Set once the original's HDR decode has landed, so a preview that arrives
  /// late cannot overwrite it with the flat version of the same photo.
  private var showingOriginal = false
  /// The grid's thumbnail, shown until the preview lands, so a page is never
  /// blank if the asset has been seen before.
  private var placeholder: UIImage?

  /// What the zoom transition flies home, and whether a drag should be allowed
  /// to dismiss rather than to pan around a magnified photo.
  var pageImage: UIImage? { imageView.image }

  /// What the image view reports, which is the only thing that proves the
  /// switch reached UIKit rather than just a local variable.
  var viewDynamicRange: Int {
    guard #available(iOS 17.0, *) else { return -1 }
    return imageView.imageDynamicRange.rawValue
  }

  func setDynamicRangeEnabled(_ enabled: Bool) {
    guard #available(iOS 17.0, *) else { return }
    imageView.preferredImageDynamicRange = enabled ? .high : .standard
  }
  var isZoomedIn: Bool { scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 }

  /// The HDR original arrives after the page is already on screen, and it is
  /// the arrival that decides whether the switch has anything to act on.
  var onImageChanged: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    scrollView.frame = bounds
    scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    scrollView.delegate = self
    scrollView.maximumZoomScale = 6
    scrollView.minimumZoomScale = 1
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    contentView.addSubview(scrollView)

    imageView.contentMode = .scaleAspectFit
    // Willing to draw above SDR. Without this a correctly decoded HDR image is
    // tone-mapped on the way to the screen and every bit of the work in
    // [ThumbnailLoader.decodeHDR] is thrown away at the last step. This is also
    // the one line the prototype's HDR switch moves.
    if #available(iOS 17.0, *) {
      imageView.preferredImageDynamicRange = .high
    }
    imageView.frame = scrollView.bounds
    imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    scrollView.addSubview(imageView)

    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
    doubleTap.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTap)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  /// Three pictures of the same photo, each better than the last.
  ///
  /// The grid's tile is already decoded, so it goes up immediately. The
  /// server's preview is a tenth the bytes of the original and lands quickly.
  /// The original is the only one of the three that still carries a gain map -
  /// measured, four assets out of four: Immich's preview re-encode strips it -
  /// so it is the only one that can be HDR, and it is worth ~2.9MB against
  /// ~370KB to get there.
  func configure(_ asset: TimelineAsset?, width: CGFloat) {
    previewToken?.cancel()
    previewToken = nil
    originalToken?.cancel()
    originalToken = nil
    showingOriginal = false
    scrollView.zoomScale = 1
    guard let asset else {
      imageView.image = nil
      return
    }

    // The grid already has this at tile size; show it immediately rather than
    // flashing an empty page while anything downloads.
    placeholder = ThumbnailLoader.shared.cached(asset, size: width / 3)
    imageView.image = placeholder

    let preview = TimelineAsset.preview(of: asset)
    shellLog(
      "[shell:page] configure %@ w=%.0f placeholder=%@ previewURL=%@ originalURL=%@ video=%@",
      asset.name, width,
      placeholder == nil ? "none" : "yes",
      asset.previewURL == nil ? "NIL" : "ok",
      asset.originalURL == nil ? "NIL" : "ok",
      asset.isVideo ? "yes" : "no"
    )
    if let hit = ThumbnailLoader.shared.cached(preview, size: width) {
      shellLog("[shell:page] preview cache hit %@", asset.name)
      imageView.image = hit
    } else {
      previewToken = ThumbnailLoader.shared.load(preview, size: width) { [weak self] image in
        // The original may already have beaten it; a preview is never an
        // upgrade on one.
        guard let self else { return }
        guard let image else {
          shellLog("[shell:page] preview FAILED %@", asset.name)
          return
        }
        guard !self.showingOriginal else { return }
        shellLog("[shell:page] preview landed %@", asset.name)
        self.imageView.image = image
      }
    }

    // Video frames come from the player, not from here, and an asset with no
    // original URL is local-only.
    guard !asset.isVideo, asset.originalURL != nil else {
      shellLog("[shell:page] no original for %@ (video=%@)", asset.name, asset.isVideo ? "yes" : "no")
      return
    }
    let original = TimelineAsset.original(of: asset)
    if let hit = ThumbnailLoader.shared.cached(original, size: width, hdr: true) {
      shellLog("[shell:page] original cache hit %@", asset.name)
      showingOriginal = true
      imageView.image = hit
      reportDynamicRange()
      return
    }
    originalToken = ThumbnailLoader.shared.load(original, size: width, hdr: true) { [weak self] image in
      guard let self else { return }
      guard let image else {
        shellLog("[shell:page] original FAILED %@", asset.name)
        return
      }
      shellLog("[shell:page] original landed %@", asset.name)
      self.showingOriginal = true
      self.imageView.image = image
      self.reportDynamicRange()
      self.onImageChanged?()
    }
  }

  /// What UIKit decided, as opposed to what the decode produced. The two can
  /// disagree — an HDR image in a view that will not draw it, or a view
  /// willing to draw one that was handed a flat picture — and only this pair
  /// tells you which half to go and look at.
  private func reportDynamicRange() {
    guard #available(iOS 17.0, *) else { return }
    shellLog(
      "[shell:hdr] page image=%@ view=%ld screen=%.2f",
      imageView.image?.isHighDynamicRange == true ? "hdr" : "sdr",
      imageView.imageDynamicRange.rawValue,
      UIScreen.main.currentEDRHeadroom
    )
  }

  @objc private func handleDoubleTap() {
    scrollView.setZoomScale(scrollView.zoomScale > 1 ? 1 : 3, animated: true)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    previewToken?.cancel()
    previewToken = nil
    originalToken?.cancel()
    originalToken = nil
    showingOriginal = false
    onImageChanged = nil
    imageView.image = nil
    scrollView.zoomScale = 1
  }
}

extension AssetPageCell: UIScrollViewDelegate {
  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
}

extension TimelineAsset {
  /// The same asset addressed at preview size, so the loader caches the two
  /// resolutions separately.
  static func preview(of asset: TimelineAsset) -> TimelineAsset {
    var raw: [String: Any] = [
      "name": asset.name,
      "isVideo": asset.isVideo,
      "createdAt": Int(asset.createdAt.timeIntervalSince1970 * 1000),
      "isFavorite": asset.isFavorite,
    ]
    if let localId = asset.localId { raw["localId"] = localId }
    if let remoteId = asset.remoteId { raw["remoteId"] = remoteId }
    if let durationMs = asset.durationMs { raw["durationMs"] = durationMs }
    // The preview URL becomes this asset's thumbnail: same fetch path, bigger
    // picture.
    if let previewURL = asset.previewURL { raw["thumbUrl"] = previewURL.absoluteString }
    return TimelineAsset(raw)!
  }

  /// The same asset addressed at its original file, which is the only one that
  /// still has the gain map on it.
  static func original(of asset: TimelineAsset) -> TimelineAsset {
    var raw: [String: Any] = [
      "name": asset.name,
      "isVideo": asset.isVideo,
      "createdAt": Int(asset.createdAt.timeIntervalSince1970 * 1000),
      "isFavorite": asset.isFavorite,
    ]
    if let localId = asset.localId { raw["localId"] = localId }
    if let remoteId = asset.remoteId { raw["remoteId"] = remoteId }
    if let durationMs = asset.durationMs { raw["durationMs"] = durationMs }
    if let originalURL = asset.originalURL { raw["thumbUrl"] = originalURL.absoluteString }
    return TimelineAsset(raw)!
  }
}
