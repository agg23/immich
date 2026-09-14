import UIKit

final class AssetViewerController: UIViewController {
  private let source: ImmichTimelineSource
  private var index: Int
  private var collectionView: UICollectionView!

  private(set) var activeInteraction: UIPercentDrivenInteractiveTransition?
  private var interactionReady = false
  private var deferredCommit: Bool?

  private var hdrEnabled = true

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

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didReceiveMemoryPressure),
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )

    let dismiss = UIPanGestureRecognizer(target: self, action: #selector(handleDismissDrag))
    dismiss.delegate = self
    view.addGestureRecognizer(dismiss)

    if let delay = Double(UserDefaults.standard.string(forKey: "immichShellHdrToggle") ?? "") {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.toggleHDR()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.toggleHDR() }
      }
    }

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
    guard isMovingFromParent else { return }
    onClosed?()
    onClosed = nil
  }

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
    shellLog(
      "[shell:hdr] foreground image=%@ view=%ld screen=%.2f switch=%@",
      cell?.pageImage?.isHighDynamicRange == true ? "hdr" : "sdr",
      cell?.viewDynamicRange ?? -1,
      UIScreen.main.currentEDRHeadroom,
      hdrEnabled ? "on" : "off"
    )
    applyDynamicRange()
    sampleHeadroom()
  }

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
    shellLog(
      "[shell:hdr] switch=%@ view=%ld image=%@ button=%@",
      hdrEnabled ? "on" : "off",
      cell?.viewDynamicRange ?? -1,
      cell?.pageImage?.isHighDynamicRange == true ? "hdr" : "sdr",
      navigationItem.rightBarButtonItem?.title ?? "-"
    )
  }

  private func applyDynamicRange() {
    for cell in collectionView.visibleCells.compactMap({ $0 as? AssetPageCell }) {
      cell.setDynamicRangeEnabled(hdrEnabled)
    }
    updateHDRButton()
  }

  func updateHDRButton() {
    guard #available(iOS 17.0, *), let item = navigationItem.rightBarButtonItem else { return }
    let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? AssetPageCell
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
    cell.setDynamicRangeEnabled(hdrEnabled)
    cell.onImageChanged = { [weak self] in self?.updateHDRButton() }
    return cell
  }

  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
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

private final class AssetPageCell: UICollectionViewCell {
  static let reuseID = "page"

  private let scrollView = UIScrollView()
  private let imageView = UIImageView()
  private var previewToken: ThumbnailLoader.Token?
  private var originalToken: ThumbnailLoader.Token?
  private var showingOriginal = false
  private var placeholder: UIImage?

  var pageImage: UIImage? { imageView.image }

  var viewDynamicRange: Int {
    guard #available(iOS 17.0, *) else { return -1 }
    return imageView.imageDynamicRange.rawValue
  }

  func setDynamicRangeEnabled(_ enabled: Bool) {
    guard #available(iOS 17.0, *) else { return }
    imageView.preferredImageDynamicRange = enabled ? .high : .standard
  }
  var isZoomedIn: Bool { scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 }

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
    // Willing to draw above SDR, or the HDR decode is tone-mapped at the last step.
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
    if let previewURL = asset.previewURL { raw["thumbUrl"] = previewURL.absoluteString }
    return TimelineAsset(raw)!
  }

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
