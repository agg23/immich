import SwiftUI
import UIKit

struct NativeTimelineView: View {
  @StateObject private var viewModel = TimelineViewModel()
  @State private var selectedAsset: TimelineAssetViewData?
  let openSettings: () -> Void
  let openLogin: () -> Void

  var body: some View {
    Group {
      if let errorMessage = viewModel.errorMessage {
        TimelineErrorView(message: errorMessage, openLogin: openLogin)
      } else if viewModel.assets.isEmpty && viewModel.isLoading {
        ProgressView("Loading timeline")
      } else if viewModel.assets.isEmpty {
        TimelineEmptyView()
      } else {
        TimelineCollectionView(
          viewModel: viewModel,
          onSelectAsset: { asset in
            selectedAsset = asset
          }
        )
        .ignoresSafeArea(.container, edges: [.top, .bottom])
      }
    }
    .navigationTitle("Immich")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(action: openSettings) {
          Image(systemName: "gearshape")
        }
      }
    }
    .task {
      await viewModel.loadInitial()
    }
    .fullScreenCover(item: $selectedAsset) { asset in
      NativePhotoViewer(asset: asset)
    }
  }
}

private struct TimelineEmptyView: View {
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "photo.on.rectangle.angled")
        .font(.system(size: 36))
        .foregroundStyle(.secondary)
      Text("No timeline assets")
        .font(.headline)
      Text("The native timeline loaded successfully, but Dart returned no assets.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct TimelineErrorView: View {
  let message: String
  let openLogin: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 36))
        .foregroundStyle(.secondary)
      Text("Unable to load timeline")
        .font(.headline)
      Text(message)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
      if message.contains("embedded-timeline-auth-unavailable") {
        Button("Log in with Flutter", action: openLogin)
          .buttonStyle(.borderedProminent)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

@MainActor
final class TimelineViewModel: ObservableObject {
  @Published private(set) var assets: [TimelineAssetViewData] = []
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?

  private let api = ImmichEmbeddedEngine.shared.timelineApi
  private var totalCount = 0
  private var nextOffset = 0
  private let pageSize: Int64 = 90

  func loadInitial() async {
    guard assets.isEmpty, !isLoading else { return }
    await reload()
  }

  func reload() async {
    isLoading = true
    errorMessage = nil
    assets = []
    nextOffset = 0
    do {
      let buckets = try await loadBuckets()
      totalCount = buckets.reduce(0) { $0 + Int($1.count) }
      NSLog("[EmbeddedUI] Native timeline loaded buckets=\(buckets.count) totalAssets=\(totalCount)")
      try await loadNextPage()
    } catch {
      let message = describeTimelineError(error)
      NSLog("[EmbeddedUI] Native timeline reload failed: \(message)")
      errorMessage = message
    }
    isLoading = false
  }

  func loadMoreIfNeeded(currentAsset: TimelineAssetViewData) async {
    guard currentAsset.id == assets.last?.id else { return }
    await loadMoreIfNeeded()
  }

  func loadMoreIfNeeded() async {
    guard !isLoading, nextOffset < totalCount else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      try await loadNextPage()
    } catch {
      let message = describeTimelineError(error)
      NSLog("[EmbeddedUI] Native timeline pagination failed: \(message)")
      errorMessage = message
    }
  }

  func loadMoreIfNeeded(visibleIndex: Int) async {
    guard visibleIndex >= assets.count - 18 else { return }
    await loadMoreIfNeeded()
  }

  private func loadNextPage() async throws {
    guard nextOffset < totalCount else { return }
    let count = min(Int(pageSize), totalCount - nextOffset)
    let metas = try await loadAssets(offset: Int64(nextOffset), count: Int64(count))
    NSLog("[EmbeddedUI] Native timeline loaded assets offset=\(nextOffset) requested=\(count) returned=\(metas.count)")
    assets.append(contentsOf: metas.map(TimelineAssetViewData.init(meta:)))
    nextOffset += metas.count
  }

  private func loadBuckets() async throws -> [TimelineBucket] {
    try await withCheckedThrowingContinuation { continuation in
      api.loadBuckets { result in
        continuation.resume(with: result)
      }
    }
  }

  private func loadAssets(offset: Int64, count: Int64) async throws -> [AssetMeta] {
    try await withCheckedThrowingContinuation { continuation in
      api.loadAssets(offset: offset, count: count) { result in
        continuation.resume(with: result)
      }
    }
  }
}

private func describeTimelineError(_ error: Error) -> String {
  if let pigeonError = error as? PigeonError {
    return "PigeonError(code: \(pigeonError.code), message: \(pigeonError.message ?? "<nil>"), details: \(String(describing: pigeonError.details)))"
  }
  return String(describing: error)
}

struct TimelineAssetViewData: Identifiable, Equatable {
  let id: String
  let remoteId: String?
  let localId: String?
  let createdAt: Date
  let isFavorite: Bool
  let isVideo: Bool
  let isEdited: Bool
  let thumbhash: String?

  init(meta: AssetMeta) {
    id = meta.id
    remoteId = meta.remoteId
    localId = meta.localId
    createdAt = Date(timeIntervalSince1970: TimeInterval(meta.createdAtEpochMilliseconds) / 1000)
    isFavorite = meta.isFavorite
    isVideo = meta.isVideo
    isEdited = meta.isEdited
    thumbhash = meta.thumbhash
  }
}

private struct TimelineCollectionView: UIViewControllerRepresentable {
  @ObservedObject var viewModel: TimelineViewModel
  let onSelectAsset: (TimelineAssetViewData) -> Void

  func makeUIViewController(context: Context) -> TimelineCollectionViewController {
    TimelineCollectionViewController(
      viewModel: viewModel,
      onSelectAsset: onSelectAsset
    )
  }

  func updateUIViewController(_ uiViewController: TimelineCollectionViewController, context: Context) {
    uiViewController.update(assets: viewModel.assets)
  }
}

private enum TimelineZoomLevel: Int, CaseIterable {
  case oneColumnAspect
  case threeColumns
  case fiveColumns
  case sevenColumns

  init(columns: Int) {
    switch columns {
    case 7:
      self = .sevenColumns
    case 5:
      self = .fiveColumns
    case 3:
      self = .threeColumns
    default:
      self = .threeColumns
    }
  }

  var columns: Int? {
    switch self {
    case .oneColumnAspect: nil
    case .threeColumns: 3
    case .fiveColumns: 5
    case .sevenColumns: 7
    }
  }

  var zoomedInLevel: TimelineZoomLevel {
    switch self {
    case .oneColumnAspect: .oneColumnAspect
    case .threeColumns: .oneColumnAspect
    case .fiveColumns: .threeColumns
    case .sevenColumns: .fiveColumns
    }
  }

  var zoomedOutLevel: TimelineZoomLevel {
    switch self {
    case .oneColumnAspect: .threeColumns
    case .threeColumns: .fiveColumns
    case .fiveColumns: .sevenColumns
    case .sevenColumns: .sevenColumns
    }
  }
}

private struct AnchoredGridSlot: Equatable {
  let relativeRow: Int
  let canvasColumn: Int
  let sourceAssetIndex: Int?
  let targetAssetIndex: Int?

  var zIndex: Int {
    10_000 - abs(relativeRow) * 100 - abs(canvasColumn)
  }
}

private struct ColumnTransitionWindow: Equatable {
  let sourceStart: Int
  let sourceEnd: Int
  let targetStart: Int
  let targetEnd: Int
  let sourceFocusColumn: Int
  let targetFocusColumn: Int
}

private let enablePinchTargetDebugHighlight = true

private enum PinchAnchorDebugSource: Equatable {
  case exactGrid
  case nearest
  case collectionHit
  case firstVisible
}

private struct AnchoredGridTransition: Equatable {
  let targetAssetIndex: Int
  let contentCentroid: CGPoint
  let viewportCentroid: CGPoint
  let anchorUnitPoint: CGPoint
  let fromColumns: Int
  let toColumns: Int
  let sourceGridOriginX: CGFloat
  let targetGridOriginX: CGFloat
  let sourceGridColumnOffset: Int
  let targetGridColumnOffset: Int
  var continuousColumns: CGFloat
  var geometryProgress: CGFloat
  var contentProgress: CGFloat
  let slots: [AnchoredGridSlot]
}

@MainActor
private final class TimelineCollectionViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
  private let viewModel: TimelineViewModel
  private let onSelectAsset: (TimelineAssetViewData) -> Void
  private let collectionView: UICollectionView
  private let layout: TimelineZoomLayout
  private var assets: [TimelineAssetViewData] = []
  private let spacing: CGFloat = 2
  private enum PresentationMode: Equatable {
    case resting
    case transitioning
  }

  private var presentationMode: PresentationMode = .resting
  private var anchoredTransition: AnchoredGridTransition?
  private var currentZoomLevel: TimelineZoomLevel = .threeColumns
  private var currentGridColumnOffset = 0
  private var pinchBaselineScale: CGFloat = 1
  private var pinchTransitionTarget: TimelineZoomLevel?
  private var pinchTransitionProgress: CGFloat = 0
  private var wasScrollEnabledBeforePinch = true
  private var pinchTargetAssetIndex: Int?
  private var pinchStartContentOffset: CGPoint = .zero
  private var pinchAnchorIndexPath: IndexPath?
  private var pinchCentroidInContent: CGPoint = .zero
  private var pinchCentroidInViewport: CGPoint = .zero
  private var pinchAnchorUnitPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
  private var pinchAnchorDebugSource: PinchAnchorDebugSource?

  init(viewModel: TimelineViewModel, onSelectAsset: @escaping (TimelineAssetViewData) -> Void) {
    self.viewModel = viewModel
    self.onSelectAsset = onSelectAsset

    layout = TimelineZoomLayout(spacing: spacing)
    collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    collectionView.backgroundColor = .systemBackground
    collectionView.alwaysBounceVertical = true
    collectionView.contentInsetAdjustmentBehavior = .always
    collectionView.register(TimelineThumbnailCollectionCell.self, forCellWithReuseIdentifier: TimelineThumbnailCollectionCell.reuseIdentifier)

    super.init(nibName: nil, bundle: nil)

    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.prefetchDataSource = self

    let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
    pinchGesture.delegate = self
    collectionView.addGestureRecognizer(pinchGesture)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    layout.itemCount = assets.count
    layout.currentZoomLevel = currentZoomLevel
    layout.gridColumnOffset = currentGridColumnOffset
    view.addSubview(collectionView)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      collectionView.topAnchor.constraint(equalTo: view.topAnchor),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  func update(assets: [TimelineAssetViewData]) {
    guard self.assets != assets else { return }
    self.assets = assets
    layout.itemCount = assets.count
    layout.itemAspectRatios = assets.map { $0.isVideo ? 16 / 9 : 4 / 3 }
    layout.currentZoomLevel = currentZoomLevel
    layout.gridColumnOffset = currentGridColumnOffset
    collectionView.reloadData()
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    switch presentationMode {
    case .resting:
      assets.count
    case .transitioning:
      anchoredTransition?.slots.count ?? 0
    }
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TimelineThumbnailCollectionCell.reuseIdentifier, for: indexPath) as! TimelineThumbnailCollectionCell

    switch presentationMode {
    case .resting:
      let asset = assets[indexPath.item]
      cell.configure(asset: asset)
      if enablePinchTargetDebugHighlight {
        cell.setDebugPinchTargetHighlight(indexPath.item == pinchTargetAssetIndex ? pinchAnchorDebugSource : nil)
      }
      Task { [weak viewModel] in
        await viewModel?.loadMoreIfNeeded(visibleIndex: indexPath.item)
      }
    case .transitioning:
      guard let transition = anchoredTransition,
            transition.slots.indices.contains(indexPath.item) else { return cell }
      let slot = transition.slots[indexPath.item]
      configure(cell: cell, for: slot, progress: transition.contentProgress)
      if enablePinchTargetDebugHighlight {
        let isPinchTarget = slot.sourceAssetIndex == transition.targetAssetIndex || slot.targetAssetIndex == transition.targetAssetIndex
        cell.setDebugPinchTargetHighlight(isPinchTarget ? pinchAnchorDebugSource : nil)
      }
    }

    return cell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard presentationMode == .resting, assets.indices.contains(indexPath.item) else { return }
    onSelectAsset(assets[indexPath.item])
  }

  func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    guard let maxIndex = indexPaths.map(\.item).max() else { return }
    Task { [weak viewModel] in
      await viewModel?.loadMoreIfNeeded(visibleIndex: maxIndex)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layout.currentZoomLevel = currentZoomLevel
    layout.gridColumnOffset = currentGridColumnOffset
  }

  @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
    guard collectionView.bounds.width > 0 else { return }

    switch gesture.state {
    case .began:
      pinchBaselineScale = gesture.scale
      pinchTransitionTarget = nil
      pinchTransitionProgress = 0
      wasScrollEnabledBeforePinch = collectionView.isScrollEnabled
      pinchStartContentOffset = collectionView.contentOffset
      pinchCentroidInContent = gesture.location(in: collectionView)
      pinchCentroidInViewport = CGPoint(
        x: pinchCentroidInContent.x - collectionView.contentOffset.x,
        y: pinchCentroidInContent.y - collectionView.contentOffset.y
      )
      captureGridPinchAnchor(at: pinchCentroidInContent)
      pinchTargetAssetIndex = pinchAnchorIndexPath?.item
      if enablePinchTargetDebugHighlight {
        updateDebugPinchTargetHighlight()
      }

    case .changed:
      let relativeScale = gesture.scale / max(0.01, pinchBaselineScale)
      let target = relativeScale >= 1 ? currentZoomLevel.zoomedInLevel : currentZoomLevel.zoomedOutLevel

      guard target != currentZoomLevel else {
        return
      }

      if pinchTransitionTarget != target {
        beginSlotTransition(to: target)
        pinchTransitionTarget = target
        pinchBaselineScale = gesture.scale
      }

      let adjustedScale = gesture.scale / max(0.01, pinchBaselineScale)
      let progress = transitionProgress(for: adjustedScale, target: target)
      updateSlotTransition(progress: progress)

    case .ended, .cancelled, .failed:
      finishPinchTransition(cancelled: gesture.state != .ended)

    default:
      break
    }
  }

  private func configure(cell: TimelineThumbnailCollectionCell, for slot: AnchoredGridSlot, progress: CGFloat) {
    switch (slot.sourceAssetIndex, slot.targetAssetIndex) {
    case let (.some(sourceIndex), .some(targetIndex))
      where assets.indices.contains(sourceIndex) && assets.indices.contains(targetIndex):
      cell.configureTransition(source: assets[sourceIndex], target: assets[targetIndex], progress: progress)
    case let (.some(sourceIndex), .none) where assets.indices.contains(sourceIndex):
      cell.configureTransition(source: assets[sourceIndex], target: assets[sourceIndex], progress: 0)
    case let (.none, .some(targetIndex)) where assets.indices.contains(targetIndex):
      cell.configureTransition(source: assets[targetIndex], target: assets[targetIndex], progress: 1)
    default:
      break
    }
  }

  private func transitionProgress(for relativeScale: CGFloat, target: TimelineZoomLevel) -> CGFloat {
    if target.rawValue < currentZoomLevel.rawValue {
      return min(1, max(0, (relativeScale - 1) / 0.65))
    }
    return min(1, max(0, (1 - relativeScale) / 0.42))
  }

  private func beginSlotTransition(to target: TimelineZoomLevel) {
    guard let targetAssetIndex = pinchTargetAssetIndex,
          assets.indices.contains(targetAssetIndex),
          let fromColumns = currentZoomLevel.columns,
          let toColumns = target.columns else {
      return
    }

    let slots = makeAnchoredGridSlots(targetAssetIndex: targetAssetIndex, fromColumns: fromColumns, toColumns: toColumns)
    guard slots.count >= 6 else { return }

    let sourceColumn = layout.column(for: targetAssetIndex, columns: fromColumns, columnOffset: currentGridColumnOffset)
    let transitionWindow = layout.columnTransitionWindow(sourceColumn: sourceColumn, fromColumns: fromColumns, toColumns: toColumns)
    let targetColumn = transitionWindow.targetFocusColumn
    let targetGridColumnOffset = layout.columnOffset(anchorIndex: targetAssetIndex, columns: toColumns, desiredColumn: targetColumn)
    let sourceGridOriginX = layout.cellLeftX(column: transitionWindow.sourceStart, columns: CGFloat(fromColumns), width: collectionView.bounds.width)
    let targetGridOriginX = layout.cellLeftX(column: transitionWindow.targetStart, columns: CGFloat(toColumns), width: collectionView.bounds.width)

    let transition = AnchoredGridTransition(
      targetAssetIndex: targetAssetIndex,
      contentCentroid: pinchCentroidInContent,
      viewportCentroid: pinchCentroidInViewport,
      anchorUnitPoint: pinchAnchorUnitPoint,
      fromColumns: fromColumns,
      toColumns: toColumns,
      sourceGridOriginX: sourceGridOriginX,
      targetGridOriginX: targetGridOriginX,
      sourceGridColumnOffset: currentGridColumnOffset,
      targetGridColumnOffset: targetGridColumnOffset,
      continuousColumns: CGFloat(fromColumns),
      geometryProgress: 0,
      contentProgress: 0,
      slots: slots
    )

    anchoredTransition = transition
    pinchTransitionProgress = 0
    prewarmTransitionThumbnails(for: transition.slots)
    presentationMode = .transitioning
    layout.anchoredTransition = transition
    collectionView.isScrollEnabled = false
    collectionView.reloadData()
  }

  private func updateSlotTransition(progress: CGFloat) {
    pinchTransitionProgress = progress
    guard var transition = anchoredTransition else { return }
    let geometryProgress = smoothstep(progress)
    transition.geometryProgress = geometryProgress
    transition.continuousColumns = CGFloat(transition.fromColumns) + (CGFloat(transition.toColumns) - CGFloat(transition.fromColumns)) * geometryProgress
    transition.contentProgress = transitionImageProgress(progress)
    anchoredTransition = transition
    layout.anchoredTransition = transition
    collectionView.collectionViewLayout.invalidateLayout()
    collectionView.visibleCells.forEach { cell in
      guard let cell = cell as? TimelineThumbnailCollectionCell,
            let indexPath = collectionView.indexPath(for: cell),
            transition.slots.indices.contains(indexPath.item),
            let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
        return
      }
      cell.alpha = attributes.alpha
      configure(cell: cell, for: transition.slots[indexPath.item], progress: transition.contentProgress)
    }
  }

  private func finishPinchTransition(cancelled: Bool) {
    guard presentationMode == .transitioning,
          let target = pinchTransitionTarget,
          let transition = anchoredTransition else {
      resetPinchState()
      return
    }

    let shouldCommit = !cancelled && pinchTransitionProgress >= 0.42
    let finalProgress: CGFloat = shouldCommit ? 1 : 0

    UIView.animate(
      withDuration: 0.18,
      delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
    ) {
      self.updateSlotTransition(progress: finalProgress)
      self.collectionView.layoutIfNeeded()
    } completion: { _ in
      let finalLevel = shouldCommit ? target : TimelineZoomLevel(columns: transition.fromColumns)
      let finalGridColumnOffset = shouldCommit ? transition.targetGridColumnOffset : transition.sourceGridColumnOffset
      let finalIndex = min(max(0, transition.targetAssetIndex), max(0, self.assets.count - 1))
      let finalOffset = self.restingContentOffset(
        anchorIndex: finalIndex,
        unitPoint: transition.anchorUnitPoint,
        viewportPoint: transition.viewportCentroid,
        level: finalLevel,
        gridColumnOffset: finalGridColumnOffset
      )

      self.currentZoomLevel = finalLevel
      self.currentGridColumnOffset = finalGridColumnOffset

      UIView.performWithoutAnimation {
        self.presentationMode = .resting
        self.anchoredTransition = nil
        self.layout.anchoredTransition = nil
        self.layout.currentZoomLevel = self.currentZoomLevel
        self.layout.gridColumnOffset = self.currentGridColumnOffset
        self.collectionView.setContentOffset(finalOffset, animated: false)
        self.collectionView.reloadData()
        self.collectionView.layoutIfNeeded()
      }

      self.collectionView.isScrollEnabled = self.wasScrollEnabledBeforePinch
      self.resetPinchState()
    }
  }

  private func makeAnchoredGridSlots(targetAssetIndex: Int, fromColumns: Int, toColumns: Int) -> [AnchoredGridSlot] {
    let maxColumns = max(fromColumns, toColumns)
    let minTileSize = collectionView.bounds.width / CGFloat(maxColumns)
    let rowRadius = Int(ceil(collectionView.bounds.height / max(1, minTileSize))) + 4
    let sourceColumn = layout.column(for: targetAssetIndex, columns: fromColumns, columnOffset: currentGridColumnOffset)
    let transitionWindow = layout.columnTransitionWindow(sourceColumn: sourceColumn, fromColumns: fromColumns, toColumns: toColumns)
    let targetColumn = transitionWindow.targetFocusColumn
    let targetGridColumnOffset = layout.columnOffset(anchorIndex: targetAssetIndex, columns: toColumns, desiredColumn: targetColumn)
    let sourceColumnWindow = layout.relativeColumnWindow(anchorColumn: sourceColumn, columns: fromColumns)
    let targetColumnWindow = layout.relativeColumnWindow(anchorColumn: targetColumn, columns: toColumns)
    let leftCanvasColumn = min(
      sourceColumnWindow.lowerBound + sourceColumn - transitionWindow.sourceStart,
      targetColumnWindow.lowerBound + targetColumn - transitionWindow.targetStart
    ) - 3
    let rightCanvasColumn = max(
      sourceColumnWindow.upperBound + sourceColumn - transitionWindow.sourceStart,
      targetColumnWindow.upperBound + targetColumn - transitionWindow.targetStart
    ) + 3
    var slots: [AnchoredGridSlot] = []

    for row in (-rowRadius)...rowRadius {
      for canvasColumn in leftCanvasColumn...rightCanvasColumn {
        let sourceRelativeColumn = canvasColumn + transitionWindow.sourceStart - sourceColumn
        let targetRelativeColumn = canvasColumn + transitionWindow.targetStart - targetColumn
        let sourceIndex = indexAtGridOffset(
          anchorIndex: targetAssetIndex,
          columns: fromColumns,
          gridColumnOffset: currentGridColumnOffset,
          relativeRow: row,
          relativeColumn: sourceRelativeColumn
        )
        let targetIndex = indexAtGridOffset(
          anchorIndex: targetAssetIndex,
          columns: toColumns,
          gridColumnOffset: targetGridColumnOffset,
          relativeRow: row,
          relativeColumn: targetRelativeColumn
        )
        let sourceAssetIndex = sourceColumnWindow.contains(sourceRelativeColumn) ? sourceIndex : nil
        let targetAssetIndex = targetColumnWindow.contains(targetRelativeColumn) ? targetIndex : nil
        guard sourceAssetIndex != nil || targetAssetIndex != nil else { continue }
        slots.append(AnchoredGridSlot(
          relativeRow: row,
          canvasColumn: canvasColumn,
          sourceAssetIndex: sourceAssetIndex,
          targetAssetIndex: targetAssetIndex
        ))
      }
    }

    return slots.sorted { $0.zIndex < $1.zIndex }
  }

  private func indexAtGridOffset(
    anchorIndex: Int,
    columns: Int,
    gridColumnOffset: Int,
    relativeRow: Int,
    relativeColumn: Int
  ) -> Int? {
    let adjustedAnchorIndex = anchorIndex + gridColumnOffset
    let anchorRow = adjustedAnchorIndex.floorDiv(columns)
    let anchorColumn = positiveModulo(adjustedAnchorIndex, columns)
    let adjustedIndex = (anchorRow + relativeRow) * columns + anchorColumn + relativeColumn
    let index = adjustedIndex - gridColumnOffset
    guard assets.indices.contains(index) else { return nil }
    return index
  }

  private func prewarmTransitionThumbnails(for slots: [AnchoredGridSlot]) {
    let indices = Set(slots.flatMap { [$0.sourceAssetIndex, $0.targetAssetIndex].compactMap { $0 } })
    for index in indices where assets.indices.contains(index) {
      let asset = assets[index]
      guard let remoteId = asset.remoteId else { continue }
      Task {
        _ = try? await TimelineThumbnailLoader.shared.loadThumbnail(asset: asset, remoteId: remoteId)
      }
    }
  }

  private func restingContentOffset(
    anchorIndex: Int,
    unitPoint: CGPoint,
    viewportPoint: CGPoint,
    level: TimelineZoomLevel,
    gridColumnOffset: Int
  ) -> CGPoint {
    layout.contentOffset(
      anchorIndex: anchorIndex,
      unitPoint: unitPoint,
      viewportPoint: viewportPoint,
      level: level,
      width: collectionView.bounds.width,
      boundsSize: collectionView.bounds.size,
      adjustedContentInset: collectionView.adjustedContentInset,
      gridColumnOffset: gridColumnOffset
    )
  }

  private func transitionImageProgress(_ progress: CGFloat) -> CGFloat {
    smoothstep(min(1, max(0, (progress - 0.15) / 0.55)))
  }

  private func smoothstep(_ value: CGFloat) -> CGFloat {
    let value = min(1, max(0, value))
    return value * value * (3 - 2 * value)
  }

  private func nearestVisibleAssetIndex(toContentPoint contentPoint: CGPoint) -> Int? {
    collectionView.visibleCells.compactMap { cell -> (Int, CGFloat)? in
      guard let indexPath = collectionView.indexPath(for: cell),
            assets.indices.contains(indexPath.item) else {
        return nil
      }
      return (indexPath.item, squaredDistance(from: contentPoint, to: cell.frame.center))
    }
    .min { $0.1 < $1.1 }?
    .0
  }

  private func captureGridPinchAnchor(at contentPoint: CGPoint) {
    let exactGridIndexPath = layout.gridIndexPath(
      at: contentPoint,
      level: currentZoomLevel,
      width: collectionView.bounds.width
    )
    let nearestIndexPath = exactGridIndexPath == nil
      ? layout.nearestIndexPath(to: contentPoint, visibleIndexPaths: collectionView.indexPathsForVisibleItems)
      : nil
    let collectionHitIndexPath = exactGridIndexPath == nil && nearestIndexPath == nil
      ? collectionView.indexPathForItem(at: contentPoint)
      : nil
    let firstVisibleIndexPath = exactGridIndexPath == nil && nearestIndexPath == nil && collectionHitIndexPath == nil
      ? collectionView.indexPathsForVisibleItems.sorted().first
      : nil

    pinchAnchorIndexPath = exactGridIndexPath ?? nearestIndexPath ?? collectionHitIndexPath ?? firstVisibleIndexPath
    if exactGridIndexPath != nil {
      pinchAnchorDebugSource = .exactGrid
    } else if nearestIndexPath != nil {
      pinchAnchorDebugSource = .nearest
    } else if collectionHitIndexPath != nil {
      pinchAnchorDebugSource = .collectionHit
    } else if firstVisibleIndexPath != nil {
      pinchAnchorDebugSource = .firstVisible
    } else {
      pinchAnchorDebugSource = nil
    }

    guard let indexPath = pinchAnchorIndexPath,
          let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
      pinchAnchorUnitPoint = CGPoint(x: 0.5, y: 0.5)
      return
    }

    pinchAnchorUnitPoint = CGPoint(
      x: attributes.frame.width > 0 ? min(1, max(0, (contentPoint.x - attributes.frame.minX) / attributes.frame.width)) : 0.5,
      y: attributes.frame.height > 0 ? min(1, max(0, (contentPoint.y - attributes.frame.minY) / attributes.frame.height)) : 0.5
    )
  }

  private func updateDebugPinchTargetHighlight() {
    guard enablePinchTargetDebugHighlight else { return }
    collectionView.visibleCells.forEach { cell in
      guard let cell = cell as? TimelineThumbnailCollectionCell,
            let indexPath = collectionView.indexPath(for: cell) else {
        return
      }

      switch presentationMode {
      case .resting:
        cell.setDebugPinchTargetHighlight(indexPath.item == pinchTargetAssetIndex ? pinchAnchorDebugSource : nil)
      case .transitioning:
        guard let transition = anchoredTransition,
              transition.slots.indices.contains(indexPath.item) else {
          cell.setDebugPinchTargetHighlight(nil)
          return
        }
        let slot = transition.slots[indexPath.item]
        let isPinchTarget = slot.sourceAssetIndex == transition.targetAssetIndex || slot.targetAssetIndex == transition.targetAssetIndex
        cell.setDebugPinchTargetHighlight(isPinchTarget ? pinchAnchorDebugSource : nil)
      }
    }
  }

  private func clampedContentOffset(_ offset: CGPoint) -> CGPoint {
    clampedContentOffset(offset, contentSize: collectionView.contentSize)
  }

  private func clampedContentOffset(_ offset: CGPoint, contentSize: CGSize) -> CGPoint {
    let minimumOffset = CGPoint(
      x: -collectionView.adjustedContentInset.left,
      y: -collectionView.adjustedContentInset.top
    )
    let maximumOffset = CGPoint(
      x: max(minimumOffset.x, contentSize.width - collectionView.bounds.width + collectionView.adjustedContentInset.right),
      y: max(minimumOffset.y, contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
    )
    return CGPoint(
      x: min(maximumOffset.x, max(minimumOffset.x, offset.x)),
      y: min(maximumOffset.y, max(minimumOffset.y, offset.y))
    )
  }

  private func resetPinchState() {
    pinchBaselineScale = 1
    pinchTransitionTarget = nil
    pinchTransitionProgress = 0
    wasScrollEnabledBeforePinch = true
    pinchTargetAssetIndex = nil
    pinchStartContentOffset = .zero
    pinchAnchorIndexPath = nil
    pinchCentroidInContent = .zero
    pinchCentroidInViewport = .zero
    pinchAnchorUnitPoint = CGPoint(x: 0.5, y: 0.5)
    pinchAnchorDebugSource = nil
    if enablePinchTargetDebugHighlight {
      updateDebugPinchTargetHighlight()
    }
  }

  private func point(in frame: CGRect, unitPoint: CGPoint) -> CGPoint {
    CGPoint(
      x: frame.minX + frame.width * unitPoint.x,
      y: frame.minY + frame.height * unitPoint.y
    )
  }
}

extension TimelineCollectionViewController: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    true
  }
}

private final class TimelineZoomLayout: UICollectionViewLayout {
  var itemCount: Int = 0 {
    didSet { invalidateLayout() }
  }
  var itemAspectRatios: [CGFloat] = [] {
    didSet { invalidateLayout() }
  }
  var currentZoomLevel: TimelineZoomLevel = .threeColumns {
    didSet { invalidateLayout() }
  }
  var gridColumnOffset: Int = 0 {
    didSet { invalidateLayout() }
  }
  var anchoredTransition: AnchoredGridTransition? {
    didSet { invalidateLayout() }
  }

  private struct LevelMetrics {
    let contentSize: CGSize
    let yOffsets: [CGFloat]?
  }

  private let spacing: CGFloat
  private var cachedAttributes: [UICollectionViewLayoutAttributes] = []
  private var cachedContentSize: CGSize = .zero

  init(spacing: CGFloat) {
    self.spacing = spacing
    super.init()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var collectionViewContentSize: CGSize {
    cachedContentSize
  }

  override func prepare() {
    super.prepare()
    guard let collectionView else {
      cachedAttributes = []
      cachedContentSize = .zero
      return
    }

    let width = collectionView.bounds.width
    guard width > 0, itemCount > 0 else {
      cachedAttributes = []
      cachedContentSize = CGSize(width: width, height: 0)
      return
    }

    if let anchoredTransition {
      cachedAttributes = anchoredTransition.slots.enumerated().map { item, slot in
        let indexPath = IndexPath(item: item, section: 0)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = anchoredFrame(for: slot, transition: anchoredTransition, width: width)
        attributes.alpha = anchoredAlpha(for: slot, progress: anchoredTransition.contentProgress)
        attributes.zIndex = slot.zIndex
        return attributes
      }
      let fromSize = contentSize(
        for: TimelineZoomLevel(columns: anchoredTransition.fromColumns),
        width: width,
        gridColumnOffset: anchoredTransition.sourceGridColumnOffset
      )
      let toSize = contentSize(
        for: TimelineZoomLevel(columns: anchoredTransition.toColumns),
        width: width,
        gridColumnOffset: anchoredTransition.targetGridColumnOffset
      )
      cachedContentSize = CGSize(
        width: max(fromSize.width, toSize.width),
        height: max(
          fromSize.height,
          toSize.height,
          collectionView.contentOffset.y + collectionView.bounds.height + collectionView.adjustedContentInset.bottom
        )
      )
      return
    }

    let levelMetrics = metrics(for: currentZoomLevel, width: width)
    cachedAttributes = (0..<itemCount).map { item in
      let indexPath = IndexPath(item: item, section: 0)
      let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
      attributes.frame = frame(for: item, level: currentZoomLevel, width: width, metrics: levelMetrics)
      return attributes
    }

    cachedContentSize = levelMetrics.contentSize
  }

  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    cachedAttributes.filter { $0.frame.intersects(rect) }
  }

  override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
    guard cachedAttributes.indices.contains(indexPath.item) else { return nil }
    return cachedAttributes[indexPath.item]
  }

  func nearestIndexPath(to point: CGPoint, visibleIndexPaths: [IndexPath]) -> IndexPath? {
    let candidates = visibleIndexPaths.isEmpty ? cachedAttributes.map(\.indexPath) : visibleIndexPaths
    return candidates.min { lhs, rhs in
      guard let lhsAttributes = layoutAttributesForItem(at: lhs),
            let rhsAttributes = layoutAttributesForItem(at: rhs) else {
        return false
      }
      return squaredDistance(from: point, to: lhsAttributes.frame.center) < squaredDistance(from: point, to: rhsAttributes.frame.center)
    }
  }

  func frameForItem(_ item: Int, level: TimelineZoomLevel, width: CGFloat) -> CGRect {
    frame(for: item, level: level, width: width, metrics: metrics(for: level, width: width))
  }

  func gridIndexPath(at point: CGPoint, level: TimelineZoomLevel, width: CGFloat) -> IndexPath? {
    guard let columns = level.columns else {
      return (0..<itemCount)
        .map { IndexPath(item: $0, section: 0) }
        .first { frameForItem($0.item, level: level, width: width).contains(point) }
    }

    let tileMetrics = gridTileMetrics(columns: CGFloat(columns), width: width)
    let column = Int(floor((point.x - spacing) / tileMetrics.step))
    let row = Int(floor((point.y - spacing) / tileMetrics.step))
    guard row >= 0, (0..<columns).contains(column) else { return nil }

    let cellFrame = CGRect(
      x: spacing + CGFloat(column) * tileMetrics.step,
      y: spacing + CGFloat(row) * tileMetrics.step,
      width: tileMetrics.tileSize,
      height: tileMetrics.tileSize
    )
    guard cellFrame.contains(point) else { return nil }

    let item = row * columns + column - gridColumnOffset
    guard (0..<itemCount).contains(item) else { return nil }
    return IndexPath(item: item, section: 0)
  }

  func column(for item: Int, columns: Int, columnOffset: Int) -> Int {
    positiveModulo(item + columnOffset, columns)
  }

  func columnTransitionWindow(sourceColumn: Int, fromColumns: Int, toColumns: Int) -> ColumnTransitionWindow {
    if fromColumns > toColumns {
      let targetCenterColumn = (toColumns - 1) / 2
      let maxSourceStart = fromColumns - toColumns
      let sourceStart = min(maxSourceStart, max(0, sourceColumn - targetCenterColumn))
      let targetFocusColumn = sourceColumn - sourceStart
      return ColumnTransitionWindow(
        sourceStart: sourceStart,
        sourceEnd: sourceStart + toColumns - 1,
        targetStart: 0,
        targetEnd: toColumns - 1,
        sourceFocusColumn: sourceColumn,
        targetFocusColumn: targetFocusColumn
      )
    }

    if fromColumns < toColumns {
      let targetStart = (toColumns - fromColumns) / 2
      return ColumnTransitionWindow(
        sourceStart: 0,
        sourceEnd: fromColumns - 1,
        targetStart: targetStart,
        targetEnd: targetStart + fromColumns - 1,
        sourceFocusColumn: sourceColumn,
        targetFocusColumn: sourceColumn + targetStart
      )
    }

    return ColumnTransitionWindow(
      sourceStart: 0,
      sourceEnd: fromColumns - 1,
      targetStart: 0,
      targetEnd: toColumns - 1,
      sourceFocusColumn: sourceColumn,
      targetFocusColumn: sourceColumn
    )
  }

  func destinationColumnPreservingVisualPosition(sourceColumn: Int, fromColumns: Int, toColumns: Int) -> Int {
    columnTransitionWindow(
      sourceColumn: sourceColumn,
      fromColumns: fromColumns,
      toColumns: toColumns
    ).targetFocusColumn
  }

  func columnOffset(anchorIndex: Int, columns: Int, desiredColumn: Int) -> Int {
    positiveModulo(desiredColumn - positiveModulo(anchorIndex, columns), columns)
  }

  func anchorX(column: Int, unitX: CGFloat, columns: CGFloat, width: CGFloat) -> CGFloat {
    let metrics = gridTileMetrics(columns: columns, width: width)
    return spacing + CGFloat(column) * metrics.step + metrics.tileSize * unitX
  }

  func cellLeftX(column: Int, columns: CGFloat, width: CGFloat) -> CGFloat {
    let metrics = gridTileMetrics(columns: columns, width: width)
    return spacing + CGFloat(column) * metrics.step
  }

  func relativeColumnWindow(anchorColumn: Int, columns: Int) -> ClosedRange<Int> {
    (-anchorColumn)...(columns - 1 - anchorColumn)
  }

  func contentSize(for level: TimelineZoomLevel, width: CGFloat) -> CGSize {
    metrics(for: level, width: width).contentSize
  }

  private func contentSize(for level: TimelineZoomLevel, width: CGFloat, gridColumnOffset: Int) -> CGSize {
    let previousGridColumnOffset = self.gridColumnOffset
    self.gridColumnOffset = gridColumnOffset
    defer { self.gridColumnOffset = previousGridColumnOffset }
    return metrics(for: level, width: width).contentSize
  }

  func contentOffset(
    anchorIndex: Int,
    unitPoint: CGPoint,
    viewportPoint: CGPoint,
    level: TimelineZoomLevel,
    width: CGFloat,
    boundsSize: CGSize,
    adjustedContentInset: UIEdgeInsets,
    gridColumnOffset: Int? = nil
  ) -> CGPoint {
    let previousGridColumnOffset = self.gridColumnOffset
    if let gridColumnOffset {
      self.gridColumnOffset = gridColumnOffset
    }
    defer {
      if gridColumnOffset != nil {
        self.gridColumnOffset = previousGridColumnOffset
      }
    }

    let anchorFrame = frameForItem(anchorIndex, level: level, width: width)
    let anchorPoint = CGPoint(
      x: anchorFrame.minX + anchorFrame.width * unitPoint.x,
      y: anchorFrame.minY + anchorFrame.height * unitPoint.y
    )
    let proposedOffset = CGPoint(x: anchorPoint.x - viewportPoint.x, y: anchorPoint.y - viewportPoint.y)
    let contentSize = contentSize(for: level, width: width)
    let minimumOffset = CGPoint(x: -adjustedContentInset.left, y: -adjustedContentInset.top)
    let maximumOffset = CGPoint(
      x: max(minimumOffset.x, contentSize.width - boundsSize.width + adjustedContentInset.right),
      y: max(minimumOffset.y, contentSize.height - boundsSize.height + adjustedContentInset.bottom)
    )
    return CGPoint(
      x: min(maximumOffset.x, max(minimumOffset.x, proposedOffset.x)),
      y: min(maximumOffset.y, max(minimumOffset.y, proposedOffset.y))
    )
  }

  func visibleIndices(in rect: CGRect, level: TimelineZoomLevel, width: CGFloat) -> [Int] {
    guard itemCount > 0 else { return [] }
    switch level {
    case .oneColumnAspect:
      return (0..<itemCount).filter { frameForItem($0, level: level, width: width).intersects(rect) }
    case .threeColumns, .fiveColumns, .sevenColumns:
      guard let columns = level.columns else { return [] }
      let tileMetrics = gridTileMetrics(columns: CGFloat(columns), width: width)
      let firstRow = Int(floor((rect.minY - spacing) / tileMetrics.step))
      let lastRow = Int(ceil((rect.maxY - spacing) / tileMetrics.step))
      guard firstRow <= lastRow else { return [] }
      let start = max(0, firstRow * columns - gridColumnOffset)
      let end = min(itemCount - 1, (lastRow + 1) * columns - 1 - gridColumnOffset)
      guard start <= end else { return [] }
      return Array(start...end).filter { frameForItem($0, level: level, width: width).intersects(rect) }
    }
  }

  private func rowCount(itemCount: Int, columns: Int, gridColumnOffset: Int) -> Int {
    guard itemCount > 0 else { return 0 }
    return (itemCount - 1 + gridColumnOffset).floorDiv(columns) + 1
  }

  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
    newBounds.size != collectionView?.bounds.size
  }

  private func anchoredFrame(for slot: AnchoredGridSlot, transition: AnchoredGridTransition, width: CGFloat) -> CGRect {
    let metrics = gridTileMetrics(columns: max(1, transition.continuousColumns), width: width)
    let sourceContentOriginX = collectionView.map { $0.contentOffset.x + transition.sourceGridOriginX } ?? transition.sourceGridOriginX
    let targetContentOriginX = collectionView.map { $0.contentOffset.x + transition.targetGridOriginX } ?? transition.targetGridOriginX
    let originX = sourceContentOriginX + (targetContentOriginX - sourceContentOriginX) * transition.geometryProgress
    return CGRect(
      x: originX + CGFloat(slot.canvasColumn) * metrics.step,
      y: transition.contentCentroid.y + CGFloat(slot.relativeRow) * metrics.step - metrics.tileSize * transition.anchorUnitPoint.y,
      width: metrics.tileSize,
      height: metrics.tileSize
    )
  }

  private func anchoredAlpha(for slot: AnchoredGridSlot, progress: CGFloat) -> CGFloat {
    switch (slot.sourceAssetIndex, slot.targetAssetIndex) {
    case (.some, .some):
      1
    case (.some, .none):
      1 - progress
    case (.none, .some):
      progress
    case (.none, .none):
      0
    }
  }

  private func metrics(for level: TimelineZoomLevel, width: CGFloat) -> LevelMetrics {
    switch level {
    case .oneColumnAspect:
      var yOffsets: [CGFloat] = []
      yOffsets.reserveCapacity(itemCount)
      var y = spacing
      for item in 0..<itemCount {
        yOffsets.append(y)
        y += oneColumnHeight(for: item, width: width) + spacing
      }
      return LevelMetrics(
        contentSize: CGSize(width: width, height: y),
        yOffsets: yOffsets
      )
    case .threeColumns:
      return gridMetrics(columns: 3, width: width)
    case .fiveColumns:
      return gridMetrics(columns: 5, width: width)
    case .sevenColumns:
      return gridMetrics(columns: 7, width: width)
    }
  }

  private struct GridTileMetrics {
    let tileSize: CGFloat
    let step: CGFloat
  }

  private func gridTileMetrics(columns: CGFloat, width: CGFloat) -> GridTileMetrics {
    let columns = max(1, columns)
    let tileSize = floor((width - spacing * (columns + 1)) / columns)
    return GridTileMetrics(tileSize: tileSize, step: tileSize + spacing)
  }

  private func gridMetrics(columns: Int, width: CGFloat) -> LevelMetrics {
    let tileMetrics = gridTileMetrics(columns: CGFloat(columns), width: width)
    let rows = rowCount(itemCount: itemCount, columns: columns, gridColumnOffset: gridColumnOffset)
    return LevelMetrics(
      contentSize: CGSize(
        width: width,
        height: spacing + CGFloat(rows) * tileMetrics.step
      ),
      yOffsets: nil
    )
  }

  private func frame(for item: Int, level: TimelineZoomLevel, width: CGFloat, metrics: LevelMetrics) -> CGRect {
    switch level {
    case .oneColumnAspect:
      let itemWidth = width
      return CGRect(
        x: 0,
        y: metrics.yOffsets?[item] ?? spacing,
        width: itemWidth,
        height: oneColumnHeight(for: item, width: itemWidth)
      )
    case .threeColumns:
      return gridFrame(for: item, columns: 3, width: width)
    case .fiveColumns:
      return gridFrame(for: item, columns: 5, width: width)
    case .sevenColumns:
      return gridFrame(for: item, columns: 7, width: width)
    }
  }

  private func gridFrame(for item: Int, columns: Int, width: CGFloat) -> CGRect {
    let tileMetrics = gridTileMetrics(columns: CGFloat(columns), width: width)
    let adjustedItem = item + gridColumnOffset
    let row = adjustedItem.floorDiv(columns)
    let column = positiveModulo(adjustedItem, columns)
    return CGRect(
      x: spacing + CGFloat(column) * tileMetrics.step,
      y: spacing + CGFloat(row) * tileMetrics.step,
      width: tileMetrics.tileSize,
      height: tileMetrics.tileSize
    )
  }

  private func oneColumnHeight(for item: Int, width: CGFloat) -> CGFloat {
    let aspectRatio = itemAspectRatios.indices.contains(item) ? itemAspectRatios[item] : 4 / 3
    return max(140, width / max(0.2, aspectRatio))
  }
}

private func squaredDistance(from point: CGPoint, to other: CGPoint) -> CGFloat {
  let dx = point.x - other.x
  let dy = point.y - other.y
  return dx * dx + dy * dy
}

private func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
  let remainder = value % modulus
  return remainder >= 0 ? remainder : remainder + modulus
}

private extension Int {
  func floorDiv(_ divisor: Int) -> Int {
    precondition(divisor > 0)
    let quotient = self / divisor
    let remainder = self % divisor
    return remainder < 0 ? quotient - 1 : quotient
  }
}

private extension CGRect {
  var center: CGPoint {
    CGPoint(x: midX, y: midY)
  }

  func interpolated(to target: CGRect, progress: CGFloat) -> CGRect {
    CGRect(
      x: origin.x + (target.origin.x - origin.x) * progress,
      y: origin.y + (target.origin.y - origin.y) * progress,
      width: width + (target.width - width) * progress,
      height: height + (target.height - height) * progress
    )
  }
}

private final class TimelineThumbnailCollectionCell: UICollectionViewCell {
  static let reuseIdentifier = "TimelineThumbnailCollectionCell"

  private let imageView = UIImageView()
  private let targetImageView = UIImageView()
  private let placeholderView = UIView()
  private let symbolView = UIImageView()
  private let videoBadge = UIImageView(image: UIImage(systemName: "play.fill"))
  private let debugHighlightView = UIView()
  private var representedAssetId: String?
  private var representedTargetAssetId: String?
  private var imageTask: Task<Void, Never>?
  private var targetImageTask: Task<Void, Never>?

  override init(frame: CGRect) {
    super.init(frame: frame)

    contentView.backgroundColor = UIColor.systemGray5
    contentView.clipsToBounds = true

    placeholderView.backgroundColor = UIColor.systemGray5
    placeholderView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(placeholderView)

    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(imageView)

    targetImageView.contentMode = .scaleAspectFill
    targetImageView.clipsToBounds = true
    targetImageView.translatesAutoresizingMaskIntoConstraints = false
    targetImageView.alpha = 0
    contentView.addSubview(targetImageView)

    symbolView.contentMode = .center
    symbolView.tintColor = .secondaryLabel
    symbolView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(symbolView)

    videoBadge.tintColor = .white
    videoBadge.translatesAutoresizingMaskIntoConstraints = false
    videoBadge.layer.shadowColor = UIColor.black.cgColor
    videoBadge.layer.shadowOpacity = 0.45
    videoBadge.layer.shadowRadius = 2
    videoBadge.layer.shadowOffset = .zero
    contentView.addSubview(videoBadge)

    debugHighlightView.isHidden = true
    debugHighlightView.isUserInteractionEnabled = false
    debugHighlightView.backgroundColor = .clear
    debugHighlightView.layer.borderWidth = 4
    debugHighlightView.layer.cornerRadius = 2
    debugHighlightView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(debugHighlightView)

    NSLayoutConstraint.activate([
      placeholderView.topAnchor.constraint(equalTo: contentView.topAnchor),
      placeholderView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      placeholderView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      placeholderView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
      imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      targetImageView.topAnchor.constraint(equalTo: contentView.topAnchor),
      targetImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      targetImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      targetImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      symbolView.topAnchor.constraint(equalTo: contentView.topAnchor),
      symbolView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      symbolView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      symbolView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      videoBadge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
      videoBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),

      debugHighlightView.topAnchor.constraint(equalTo: contentView.topAnchor),
      debugHighlightView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      debugHighlightView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      debugHighlightView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    imageTask?.cancel()
    targetImageTask?.cancel()
    imageTask = nil
    targetImageTask = nil
    representedAssetId = nil
    representedTargetAssetId = nil
    imageView.image = nil
    imageView.alpha = 1
    targetImageView.image = nil
    targetImageView.alpha = 0
    symbolView.image = nil
    videoBadge.isHidden = true
    setDebugPinchTargetHighlight(nil)
  }

  func configure(asset: TimelineAssetViewData) {
    representedAssetId = asset.id
    representedTargetAssetId = nil
    imageView.alpha = 1
    targetImageView.image = nil
    targetImageView.alpha = 0
    symbolView.image = nil
    videoBadge.isHidden = !asset.isVideo
    imageTask?.cancel()
    targetImageTask?.cancel()
    targetImageTask = nil
    load(asset: asset, into: imageView, representedKeyPath: \.representedAssetId, taskKeyPath: \.imageTask, clearsWhileLoading: true)
  }

  func configureTransition(source: TimelineAssetViewData, target: TimelineAssetViewData, progress: CGFloat) {
    representedAssetId = source.id
    representedTargetAssetId = target.id
    symbolView.image = nil
    videoBadge.isHidden = !(source.isVideo || target.isVideo)
    imageTask?.cancel()
    targetImageTask?.cancel()

    load(asset: source, into: imageView, representedKeyPath: \.representedAssetId, taskKeyPath: \.imageTask, clearsWhileLoading: false)
    if source.id == target.id {
      targetImageView.image = nil
      targetImageView.alpha = 0
      imageView.alpha = 1
    } else {
      load(asset: target, into: targetImageView, representedKeyPath: \.representedTargetAssetId, taskKeyPath: \.targetImageTask, clearsWhileLoading: false)
      updateTransition(source: source, target: target, progress: progress)
    }
  }

  func updateTransition(source: TimelineAssetViewData, target: TimelineAssetViewData, progress: CGFloat) {
    if representedAssetId != source.id || representedTargetAssetId != target.id {
      configureTransition(source: source, target: target, progress: progress)
      return
    }

    let progress = min(1, max(0, progress))
    if source.id == target.id {
      imageView.alpha = 1
      targetImageView.alpha = 0
    } else {
      imageView.alpha = 1 - progress
      targetImageView.alpha = progress
    }
  }

  func setDebugPinchTargetHighlight(_ source: PinchAnchorDebugSource?) {
    guard let source else {
      debugHighlightView.isHidden = true
      debugHighlightView.layer.borderColor = nil
      debugHighlightView.layer.shadowOpacity = 0
      return
    }

    debugHighlightView.isHidden = false
    debugHighlightView.layer.borderColor = debugHighlightColor(for: source).cgColor
    debugHighlightView.layer.shadowColor = UIColor.black.cgColor
    debugHighlightView.layer.shadowOffset = .zero
    debugHighlightView.layer.shadowRadius = 4
    debugHighlightView.layer.shadowOpacity = 0.55
  }

  private func debugHighlightColor(for source: PinchAnchorDebugSource) -> UIColor {
    switch source {
    case .exactGrid:
      return .systemGreen
    case .nearest:
      return .systemYellow
    case .collectionHit:
      return .systemOrange
    case .firstVisible:
      return .systemRed
    }
  }

  private func load(
    asset: TimelineAssetViewData,
    into imageView: UIImageView,
    representedKeyPath: ReferenceWritableKeyPath<TimelineThumbnailCollectionCell, String?>,
    taskKeyPath: ReferenceWritableKeyPath<TimelineThumbnailCollectionCell, Task<Void, Never>?>,
    clearsWhileLoading: Bool
  ) {
    if let cachedImage = TimelineThumbnailLoader.shared.cachedImage(assetId: asset.id) {
      imageView.image = cachedImage
      return
    }

    if clearsWhileLoading {
      imageView.image = nil
    }

    guard let remoteId = asset.remoteId else {
      symbolView.image = UIImage(systemName: asset.isVideo ? "video" : "photo")
      return
    }

    self[keyPath: taskKeyPath]?.cancel()
    self[keyPath: taskKeyPath] = Task { [weak self, weak imageView] in
      do {
        let image = try await TimelineThumbnailLoader.shared.loadThumbnail(asset: asset, remoteId: remoteId)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard self?[keyPath: representedKeyPath] == asset.id else { return }
          imageView?.image = image
        }
      } catch {
        guard !Task.isCancelled else { return }
        NSLog("[EmbeddedUI] Native collection thumbnail load failed asset=\(asset.id): \(describeTimelineError(error))")
        await MainActor.run {
          guard self?[keyPath: representedKeyPath] == asset.id else { return }
          self?.symbolView.image = UIImage(systemName: asset.isVideo ? "video" : "photo")
        }
      }
    }
  }
}

private actor TimelineThumbnailLoader {
  static let shared = TimelineThumbnailLoader()

  nonisolated private static let cache = NSCache<NSString, UIImage>()
  private var inFlight: [String: Task<UIImage, Error>] = [:]

  nonisolated func cachedImage(assetId: String) -> UIImage? {
    Self.cache.object(forKey: assetId as NSString)
  }

  func loadThumbnail(asset: TimelineAssetViewData, remoteId: String) async throws -> UIImage {
    if let cached = Self.cache.object(forKey: asset.id as NSString) {
      return cached
    }

    if let task = inFlight[asset.id] {
      return try await task.value
    }

    let task = Task<UIImage, Error> {
      let urlString = try await thumbnailUrl(asset: asset, remoteId: remoteId)
      guard let url = URL(string: urlString) else {
        throw PigeonError(code: "invalid-thumbnail-url", message: "Invalid thumbnail URL for asset \(asset.id): \(urlString)", details: nil)
      }
      var request = URLRequest(url: url)
      request.cachePolicy = .returnCacheDataElseLoad
      let (data, _) = try await URLSessionManager.shared.session.data(for: request)
      return try await Self.decodeImage(data: data, assetId: asset.id)
    }

    inFlight[asset.id] = task
    do {
      let image = try await task.value
      Self.cache.setObject(image, forKey: asset.id as NSString)
      inFlight[asset.id] = nil
      return image
    } catch {
      inFlight[asset.id] = nil
      throw error
    }
  }

  private static func decodeImage(data: Data, assetId: String) async throws -> UIImage {
    try await Task.detached(priority: .utility) {
      guard let image = UIImage(data: data) else {
        throw PigeonError(code: "thumbnail-decode-failed", message: "Could not decode thumbnail for asset \(assetId), bytes=\(data.count)", details: nil)
      }
      return image
    }.value
  }

  private func thumbnailUrl(asset: TimelineAssetViewData, remoteId: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      ImmichEmbeddedEngine.shared.timelineApi.thumbnailUrl(assetId: remoteId, thumbhash: asset.thumbhash, edited: asset.isEdited) { result in
        continuation.resume(with: result)
      }
    }
  }
}

private struct NativePhotoViewer: View {
  @Environment(\.dismiss) private var dismiss
  let asset: TimelineAssetViewData

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Color.black
        .ignoresSafeArea()

      TimelineViewerImage(asset: asset)
        .ignoresSafeArea()

      Button(action: { dismiss() }) {
        Image(systemName: "xmark")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white)
          .padding(12)
          .background(.black.opacity(0.45), in: Circle())
      }
      .padding(.top, 16)
      .padding(.trailing, 16)
    }
  }
}

private struct ZoomableImageView: UIViewRepresentable {
  let image: UIImage

  func makeUIView(context: Context) -> UIScrollView {
    let scrollView = UIScrollView()
    scrollView.delegate = context.coordinator
    scrollView.backgroundColor = .clear
    scrollView.minimumZoomScale = 1
    scrollView.maximumZoomScale = 6
    scrollView.bouncesZoom = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.decelerationRate = .fast

    let imageView = UIImageView(image: image)
    imageView.contentMode = .scaleAspectFit
    imageView.isUserInteractionEnabled = true
    imageView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(imageView)
    context.coordinator.imageView = imageView

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])

    let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
    doubleTap.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTap)

    return scrollView
  }

  func updateUIView(_ scrollView: UIScrollView, context: Context) {
    context.coordinator.imageView?.image = image
    if context.coordinator.representedImage !== image {
      context.coordinator.representedImage = image
      scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
      context.coordinator.centerImage(in: scrollView)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator: NSObject, UIScrollViewDelegate {
    weak var imageView: UIImageView?
    weak var representedImage: UIImage?

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
      centerImage(in: scrollView)
    }

    func scrollViewDidLayoutSubviews(_ scrollView: UIScrollView) {
      centerImage(in: scrollView)
    }

    @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
      guard let scrollView = recognizer.view as? UIScrollView else { return }

      if scrollView.zoomScale > scrollView.minimumZoomScale {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        return
      }

      let point = recognizer.location(in: imageView)
      let targetScale = min(scrollView.maximumZoomScale, max(3, scrollView.minimumZoomScale * 3))
      let size = CGSize(
        width: scrollView.bounds.width / targetScale,
        height: scrollView.bounds.height / targetScale
      )
      let rect = CGRect(
        x: point.x - size.width / 2,
        y: point.y - size.height / 2,
        width: size.width,
        height: size.height
      )
      scrollView.zoom(to: rect, animated: true)
    }

    func centerImage(in scrollView: UIScrollView) {
      guard let imageView else { return }
      let horizontalInset = max(0, (scrollView.bounds.width - imageView.frame.width) / 2)
      let verticalInset = max(0, (scrollView.bounds.height - imageView.frame.height) / 2)
      scrollView.contentInset = UIEdgeInsets(
        top: verticalInset,
        left: horizontalInset,
        bottom: verticalInset,
        right: horizontalInset
      )
    }
  }
}

private struct TimelineViewerImage: View {
  let asset: TimelineAssetViewData
  @State private var image: UIImage?
  @State private var didFail = false

  var body: some View {
    Group {
      if let image {
        ZoomableImageView(image: image)
      } else if didFail || asset.remoteId == nil {
        VStack(spacing: 12) {
          Image(systemName: asset.isVideo ? "video" : "photo")
            .font(.system(size: 42))
          Text(asset.isVideo ? "Video preview not in prototype" : "Unable to load image")
            .font(.footnote)
        }
        .foregroundStyle(.white.opacity(0.8))
      } else {
        ProgressView()
          .tint(.white)
      }
    }
    .task(id: asset.id) {
      await loadImage()
    }
  }

  private func loadImage() async {
    guard image == nil, let remoteId = asset.remoteId else { return }
    do {
      image = try await TimelineThumbnailLoader.shared.loadThumbnail(asset: asset, remoteId: remoteId)
    } catch {
      NSLog("[EmbeddedUI] Native viewer image load failed asset=\(asset.id): \(describeTimelineError(error))")
      didFail = true
    }
  }
}
