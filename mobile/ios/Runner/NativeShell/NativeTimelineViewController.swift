import Flutter
import UIKit

final class NativeTimelineViewController: UIViewController {
  private let source: ImmichTimelineSource
  private var collectionView: UICollectionView!

  private enum Metrics {
    static let columns = 3
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

    setContentScrollView(collectionView, for: [.top, .bottom])

    source.addObserver(
      self,
      sectionsChanged: { [weak self] in
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

    var extensions: [String: Int] = [:]
    for asset in scanned {
      let ext = (asset.name as NSString).pathExtension.lowercased()
      extensions[ext, default: 0] += 1
    }
    shellLog("[shell:probe] scanned %d: %@", scanned.count, extensions.sorted { $0.value > $1.value }
      .map { "\($0.key)=\($0.value)" }.joined(separator: " "))

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
    let delay = Double(UserDefaults.standard.string(forKey: "immichShellOpenDelay") ?? "") ?? 0
    shellLog("[shell:timeline] opening requested asset %d after %.1fs", index, delay)
    guard delay > 0 else {
      open(assetAt: index)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.scrollZoomItemIntoView(index)
      self.view.layoutIfNeeded()
      shellLog("[shell:timeline] grid has %ld cells", self.collectionView.visibleCells.count)
      self.open(assetAt: index)
    }
  }

  private func open(assetAt flatIndex: Int) {
    let viewer = AssetViewerController(source: source, startIndex: flatIndex)
    navigationController?.delegate = self
    navigationController?.pushViewController(viewer, animated: true)
  }

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
    source.sections.count
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    source.sections[section].count
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
    header.configure(title: title(for: source.sections[indexPath.section].date))
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
    if cell != nil {
      shellLog("[shell:zoom] cell %ld/%ld exists but has no picture yet", path.section, path.item)
    }
    guard let asset = source.asset(at: index) else { return nil }
    // Keyed as `cellForItemAt` keys it, or the lookup is a guaranteed miss.
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
    (navigationController.topViewController as? AssetViewerController)?.activeInteraction
  }

  func navigationController(
    _ navigationController: UINavigationController,
    didShow viewController: UIViewController,
    animated: Bool
  ) {
    if viewController === self {
      navigationController.delegate = nil
    }
  }
}
