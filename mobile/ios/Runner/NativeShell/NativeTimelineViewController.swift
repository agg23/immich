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

  init(messenger: FlutterBinaryMessenger) {
    source = ImmichTimelineSource(messenger: messenger)
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

    source.onBucketsChanged = { [weak self] in
      self?.collectionView.reloadData()
    }
    source.onPageLoaded = { [weak self] page in
      self?.reloadVisible(in: page)
      self?.openRequestedAsset()
    }
    source.open()
  }

  /// `-immichShellOpenAsset <flat index>` opens the viewer as soon as there
  /// is data for it.
  ///
  /// There is no pointer automation for the simulator and no UI test target in
  /// this repo, so without something like this a screen reachable only by a
  /// tap cannot be looked at from a script at all.
  private var openedRequestedAsset = false

  private func openRequestedAsset() {
    guard !openedRequestedAsset,
          let requested = UserDefaults.standard.string(forKey: "immichShellOpenAsset"),
          let index = Int(requested),
          source.asset(at: index) != nil
    else { return }
    openedRequestedAsset = true
    NSLog("[shell:timeline] opening requested asset %d", index)
    open(assetAt: index)
  }

  private func open(assetAt flatIndex: Int) {
    let viewer = AssetViewerController(source: source, startIndex: flatIndex)
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
