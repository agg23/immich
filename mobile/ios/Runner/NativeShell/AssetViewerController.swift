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

  init(source: ImmichTimelineSource, startIndex: Int) {
    self.source = source
    index = startIndex
    super.init(nibName: nil, bundle: nil)
    hidesBottomBarWhenPushed = true
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

    updateTitle()
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
    collectionView.setContentOffset(CGPoint(x: CGFloat(index) * size.width, y: 0), animated: false)
  }

  private func updateTitle() {
    guard let asset = source.asset(at: index) else { return }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    title = formatter.string(from: asset.createdAt)
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
    return cell
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    let width = scrollView.bounds.width
    guard width > 0 else { return }
    index = Int((scrollView.contentOffset.x / width).rounded())
    source.prefetch(around: index)
    updateTitle()
  }
}

/// One full-screen, zoomable asset.
private final class AssetPageCell: UICollectionViewCell {
  static let reuseID = "page"

  private let scrollView = UIScrollView()
  private let imageView = UIImageView()
  private var token: ThumbnailLoader.Token?
  /// The grid's thumbnail, shown until the preview lands, so a page is never
  /// blank if the asset has been seen before.
  private var placeholder: UIImage?

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
    token?.cancel()
    token = nil
    scrollView.zoomScale = 1
    guard let asset else {
      imageView.image = nil
      return
    }

    // The grid already has this at tile size; show it immediately rather than
    // flashing an empty page while the preview downloads.
    placeholder = ThumbnailLoader.shared.cached(asset, size: width / 3)
    imageView.image = placeholder

    let preview = TimelineAsset.preview(of: asset)
    if let hit = ThumbnailLoader.shared.cached(preview, size: width) {
      imageView.image = hit
      return
    }
    token = ThumbnailLoader.shared.load(preview, size: width) { [weak self] image in
      guard let image else { return }
      self?.imageView.image = image
    }
  }

  @objc private func handleDoubleTap() {
    scrollView.setZoomScale(scrollView.zoomScale > 1 ? 1 : 3, animated: true)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    token?.cancel()
    token = nil
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
}
