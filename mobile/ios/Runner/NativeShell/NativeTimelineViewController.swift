import Flutter
import UIKit

/// The native timeline: the tab this whole exercise is about.
///
/// Grid geometry is copied from Immich's own constants so the two are
/// comparable — three columns, 2pt gutters, 320pt thumbnails. The day header
/// is not: Immich's is 80pt of Flutter layout, and matching that number would
/// only reproduce a Material header in UIKit. The question this demo is asked
/// to answer is what the native version should feel like, so the header is
/// sized and weighted like the one in Photos.
///
/// The data is Immich's, over a channel: see `ImmichTimelineSource`. The
/// chrome is the point — a `UICollectionView` is a real `UIScrollView`, so the
/// large title collapses, the navigation bar picks up its scroll edge
/// appearance and the iOS 26 tab bar minimizes, none of it forwarded and none
/// of it a frame behind.
final class NativeTimelineViewController: UIViewController {
  private let source: ImmichTimelineSource
  private var collectionView: UICollectionView!

  private enum Metrics {
    /// kTimelineColumnCount
    static let columns = 3
    /// kTimelineSpacing
    static let spacing: CGFloat = 2
    static let headerHeight: CGFloat = 44
  }

  init(source: ImmichTimelineSource) {
    self.source = source
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(false, animated: animated)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Photos"
    navigationItem.largeTitleDisplayMode = .always

    collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
    collectionView.backgroundColor = .systemBackground
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.prefetchDataSource = self
    collectionView.register(TimelineTileCell.self, forCellWithReuseIdentifier: TimelineTileCell.reuseID)
    collectionView.register(
      TimelineDayHeader.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: TimelineDayHeader.reuseID
    )
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(collectionView)
    NSLayoutConstraint.activate([
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.topAnchor.constraint(equalTo: view.topAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    // Explicit registration as well as the implicit one, so the bottom bar
    // reacts too rather than only the navigation bar.
    setContentScrollView(collectionView, for: [.top, .bottom])

    source.addObserver(
      self,
      bucketsChanged: { [weak self] in
        self?.collectionView.reloadData()
      },
      pageLoaded: { [weak self] page in
        self?.reloadVisible(in: page)
        self?.openRequestedAsset()
        self?.runHDRProbeIfRequested()
      }
    )
    source.open()
  }

  /// `-immichShellOpenAsset <flat index>` opens the viewer as soon as there
  /// is data for it.
  ///
  /// There is no pointer automation for the simulator and no UI test target in
  /// this repo, so without something like this a screen reachable only by a
  /// tap cannot be looked at from a script at all.
  /// `-immichShellHdrProbe <count>` runs [ThumbnailLoader.probeHDR] over the
  /// first N assets, so the question is answered against this library's real
  /// photos rather than against one asset that might not be HDR at all.
  private var probedHDR = false

  private func runHDRProbeIfRequested() {
    guard !probedHDR,
          let requested = UserDefaults.standard.string(forKey: "immichShellHdrProbe"),
          let count = Int(requested),
          source.asset(at: count - 1) != nil
    else { return }
    probedHDR = true
    guard #available(iOS 17.0, *) else { return }
    let scanned = (0 ..< count).compactMap { source.asset(at: $0) }

    // What is actually in this library. The first run probed six assets that
    // turned out to be Immich's own generated derivatives stored as assets -
    // one "original" was a 21KB webp thumbnail - so every row read SDR for a
    // reason that had nothing to do with the decode.
    var extensions: [String: Int] = [:]
    for asset in scanned {
      let ext = (asset.name as NSString).pathExtension.lowercased()
      extensions[ext, default: 0] += 1
    }
    shellLog("[shell:probe] scanned %d: %@", scanned.count, extensions.sorted { $0.value > $1.value }
      .map { "\($0.key)=\($0.value)" }.joined(separator: " "))

    // A camera original is the only thing that can carry a gain map, and on an
    // iPhone that means HEIC. Fall back to anything not obviously a derivative
    // so the probe still says something on a library with no HEIC in it.
    let cameraish = scanned.filter { ($0.name as NSString).pathExtension.lowercased() == "heic" }
    let candidates = cameraish.isEmpty
      ? scanned.filter { !$0.name.contains("_preview") && !$0.name.contains("_thumbnail") }
      : cameraish
    shellLog("[shell:probe] %d candidates (%@)", candidates.count, cameraish.isEmpty ? "fallback" : "heic")
    ThumbnailLoader.shared.probeHDR(Array(candidates.prefix(4)))
  }

  private var openedRequestedAsset = false

  private func openRequestedAsset() {
    guard !openedRequestedAsset,
          let requested = UserDefaults.standard.string(forKey: "immichShellOpenAsset")
    else { return }
    // `heic` rather than a number: the HDR path can only be judged on a camera
    // original, and which index holds one differs per library. The first probe
    // opened asset 0, which was a generated webp derivative.
    let index: Int
    if requested == "heic" {
      guard let found = (0 ..< 400).first(where: {
        ($0 < 400) && ((source.asset(at: $0)?.name as NSString?)?.pathExtension.lowercased() == "heic")
      }) else { return }
      index = found
    } else if let parsed = Int(requested) {
      index = parsed
    } else {
      return
    }
    guard source.asset(at: index) != nil else { return }
    openedRequestedAsset = true
    // `-immichShellOpenDelay <seconds>` waits before opening. Without it the
    // open fires from the first page-loaded callback, when the grid has a
    // computed layout but has dequeued no cells - so the zoom degrades to its
    // cross-fade for a reason that has nothing to do with a real tap. Two runs
    // were read as a transition bug before that was understood.
    let delay = Double(UserDefaults.standard.string(forKey: "immichShellOpenDelay") ?? "") ?? 0
    shellLog("[shell:timeline] opening requested asset %d after %.1fs", index, delay)
    guard delay > 0 else {
      open(assetAt: index)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      // A tap can only ever start from a tile that is on screen. Opening an
      // off-screen index from a script is not the same event, and reads as a
      // broken transition: index 20 with 15 cells visible has no cell, so the
      // flight correctly degrades to a cross-fade and proves nothing.
      self.scrollZoomItemIntoView(index)
      self.view.layoutIfNeeded()
      shellLog("[shell:timeline] grid has %ld cells", self.collectionView.visibleCells.count)
      self.open(assetAt: index)
    }
  }

  private func open(assetAt flatIndex: Int) {
    let viewer = AssetViewerController(source: source, startIndex: flatIndex)
    // Claimed for the duration of the viewer. The same navigation controller
    // carries mirrored Flutter frames, so the delegate answers nil for every
    // transition that is not this viewer and UIKit keeps its own animation for
    // those — see [navigationController(_:animationControllerFor:...)].
    navigationController?.delegate = self
    navigationController?.pushViewController(viewer, animated: true)
  }

  /// A page landing does not change the layout, only the contents of tiles
  /// that were drawn empty. Reloading just those avoids a full reload during
  /// a scroll, which would fight the scroll.
  private func reloadVisible(in page: Int) {
    let range = source.range(ofPage: page)
    let paths = collectionView.indexPathsForVisibleItems.filter { range.contains(source.flatIndex(for: $0)) }
    guard !paths.isEmpty else { return }
    collectionView.reloadItems(at: paths)
  }

  private static func makeLayout() -> UICollectionViewLayout {
    let fraction = 1.0 / CGFloat(Metrics.columns)
    let item = NSCollectionLayoutItem(
      layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1))
    )
    let group = NSCollectionLayoutGroup.horizontal(
      layoutSize: NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1),
        heightDimension: .fractionalWidth(fraction)
      ),
      // `repeatingSubitem:` is iOS 16; the Runner target is 15.
      subitem: item,
      count: Metrics.columns
    )
    group.interItemSpacing = .fixed(Metrics.spacing)

    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = Metrics.spacing
    let header = NSCollectionLayoutBoundarySupplementaryItem(
      layoutSize: NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1),
        heightDimension: .absolute(Metrics.headerHeight)
      ),
      elementKind: UICollectionView.elementKindSectionHeader,
      alignment: .top
    )
    // Sticky day headers, which Immich's sliver list also does.
    header.pinToVisibleBounds = true
    section.boundarySupplementaryItems = [header]
    return UICollectionViewCompositionalLayout(section: section)
  }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, d MMMM yyyy"
    return formatter
  }()

  private func title(for date: Date?) -> String {
    guard let date else { return "" }
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    return Self.dayFormatter.string(from: date)
  }
}

extension NativeTimelineViewController: UICollectionViewDataSource {
  func numberOfSections(in collectionView: UICollectionView) -> Int {
    source.buckets.count
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    source.buckets[section].count
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: TimelineTileCell.reuseID,
      for: indexPath
    ) as! TimelineTileCell
    let width = collectionView.bounds.width / CGFloat(Metrics.columns)
    cell.configure(source.asset(at: source.flatIndex(for: indexPath)), size: width)
    return cell
  }

  func collectionView(
    _ collectionView: UICollectionView,
    viewForSupplementaryElementOfKind kind: String,
    at indexPath: IndexPath
  ) -> UICollectionReusableView {
    let header = collectionView.dequeueReusableSupplementaryView(
      ofKind: kind,
      withReuseIdentifier: TimelineDayHeader.reuseID,
      for: indexPath
    ) as! TimelineDayHeader
    header.configure(title: title(for: source.buckets[indexPath.section].date))
    return header
  }
}

extension NativeTimelineViewController: UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
  func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    for path in indexPaths {
      source.prefetch(around: source.flatIndex(for: path))
    }
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: false)
    let flatIndex = source.flatIndex(for: indexPath)
    guard source.asset(at: flatIndex) != nil else { return }
    open(assetAt: flatIndex)
  }
}

private final class TimelineTileCell: UICollectionViewCell {
  static let reuseID = "tile"
  private let imageView = UIImageView()

  /// What the zoom transition flies, and whether this tile is currently
  /// standing in for a photo that is on its way to or from the viewer.
  var tileImage: UIImage? { imageView.image }
  var tileHidden: Bool {
    get { imageView.isHidden }
    set { imageView.isHidden = newValue }
  }

  private let duration = UILabel()
  private var token: ThumbnailLoader.Token?

  override init(frame: CGRect) {
    super.init(frame: frame)
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.frame = bounds
    imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentView.addSubview(imageView)

    duration.font = .systemFont(ofSize: 11, weight: .semibold)
    duration.textColor = .white
    duration.shadowColor = UIColor.black.withAlphaComponent(0.6)
    duration.shadowOffset = CGSize(width: 0, height: 0.5)
    duration.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(duration)
    NSLayoutConstraint.activate([
      duration.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
      duration.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  func configure(_ asset: TimelineAsset?, size: CGFloat) {
    token?.cancel()
    token = nil
    contentView.backgroundColor = .secondarySystemBackground

    guard let asset else {
      // The page this tile belongs to has not arrived yet. It will, and only
      // this tile is reloaded when it does.
      imageView.image = nil
      duration.text = nil
      return
    }

    duration.text = asset.isVideo ? Self.format(asset.durationMs) : nil
    if let hit = ThumbnailLoader.shared.cached(asset, size: size) {
      imageView.image = hit
      return
    }
    imageView.image = nil
    token = ThumbnailLoader.shared.load(asset, size: size) { [weak self] image in
      self?.imageView.image = image
    }
  }

  private static func format(_ durationMs: Int?) -> String? {
    guard let durationMs, durationMs > 0 else { return nil }
    let seconds = durationMs / 1000
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    token?.cancel()
    token = nil
    imageView.image = nil
    duration.text = nil
  }
}

private final class TimelineDayHeader: UICollectionReusableView {
  static let reuseID = "day"
  private let label = UILabel()
  private let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))

  override init(frame: CGRect) {
    super.init(frame: frame)
    background.frame = bounds
    background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(background)

    label.font = UIFont.preferredFont(forTextStyle: .headline)
    label.adjustsFontForContentSizeCategory = true
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not supported") }

  func configure(title: String) {
    label.text = title
  }
}

extension NativeTimelineViewController: ZoomTransitionSource {
  func zoomSourceFrame(forIndex index: Int) -> CGRect? {
    guard let path = source.indexPath(for: index) else {
      shellLog("[shell:zoom] no index path for %d", index)
      return nil
    }
    guard let attributes = collectionView.layoutAttributesForItem(at: path) else {
      shellLog("[shell:zoom] no layout attributes for %d (%ld/%ld)", index, path.section, path.item)
      return nil
    }
    // Layout attributes rather than the cell: a tile scrolled out of the window
    // has no cell but still has a frame, which is exactly the case a dismissal
    // onto an off-screen tile needs answered.
    return collectionView.convert(attributes.frame, to: view)
  }

  func zoomSourceImage(forIndex index: Int) -> UIImage? {
    guard let path = source.indexPath(for: index) else {
      shellLog("[shell:zoom] index %d maps to no path", index)
      return nil
    }
    let cell = collectionView.cellForItem(at: path) as? TimelineTileCell
    if let image = cell?.tileImage {
      return image
    }
    // Kept apart deliberately. Folding these into one `if let` and reporting
    // "no cell" sent two builds after a missing cell that was never missing:
    // the cell was there and its thumbnail had simply not downloaded yet,
    // because the tile had been scrolled into view a moment earlier.
    if cell != nil {
      shellLog("[shell:zoom] cell %ld/%ld exists but has no picture yet", path.section, path.item)
    }
    // No cell, so fall back to whatever the loader has cached at tile size.
    guard let asset = source.asset(at: index) else { return nil }
    // Keyed exactly as `cellForItemAt` keys it, or the lookup is a guaranteed
    // miss: `view` and `collectionView` do not have to be the same width.
    let tileSize = collectionView.bounds.width / CGFloat(Metrics.columns)
    let hit = ThumbnailLoader.shared.cached(asset, size: tileSize)
    shellLog(
      "[shell:zoom] falling back for %d at %ld/%ld (cell %@), cache %.0f: %@",
      index,
      path.section,
      path.item,
      cell == nil ? "absent" : "present",
      tileSize,
      hit == nil ? "miss" : "hit"
    )
    return hit
  }

  func setZoomItem(_ index: Int, hidden: Bool) {
    guard let path = source.indexPath(for: index) else { return }
    (collectionView.cellForItem(at: path) as? TimelineTileCell)?.tileHidden = hidden
  }

  func scrollZoomItemIntoView(_ index: Int) {
    guard let path = source.indexPath(for: index) else { return }
    guard !collectionView.indexPathsForVisibleItems.contains(path) else { return }
    collectionView.scrollToItem(at: path, at: .centeredVertically, animated: false)
  }
}

extension NativeTimelineViewController: UINavigationControllerDelegate {
  func navigationController(
    _ navigationController: UINavigationController,
    animationControllerFor operation: UINavigationController.Operation,
    from fromVC: UIViewController,
    to toVC: UIViewController
  ) -> UIViewControllerAnimatedTransitioning? {
    // Only the two transitions that have a tile at one end of them. Everything
    // else on this stack is a mirrored Flutter frame and keeps the system push.
    if operation == .push, toVC is AssetViewerController, fromVC === self {
      return ZoomTransitionAnimator(presenting: true, source: self)
    }
    if operation == .pop, fromVC is AssetViewerController, toVC === self {
      return ZoomTransitionAnimator(presenting: false, source: self)
    }
    return nil
  }

  func navigationController(
    _ navigationController: UINavigationController,
    interactionControllerFor animationController: UIViewControllerAnimatedTransitioning
  ) -> UIViewControllerInteractiveTransitioning? {
    // Consulted only when the method above returned an animator, which is why
    // the drag has to be driven from the viewer rather than from here.
    (navigationController.topViewController as? AssetViewerController)?.activeInteraction
  }

  func navigationController(
    _ navigationController: UINavigationController,
    didShow viewController: UIViewController,
    animated: Bool
  ) {
    // Hand the stack back once the viewer is gone, so nothing else on this tab
    // is transitioning through a delegate that belongs to the grid.
    if viewController === self {
      navigationController.delegate = nil
    }
  }
}
