import XCTest
@testable import TimelineAlgorithm

final class TimelineGridTransitionTests: XCTestCase {
  func testCenterSlotAlwaysRepresentsAnchorInBothLayouts() {
    let slots = TimelineGridTransition.localAnchoredSlots(input: GridTransitionInput(
      targetIndex: 12,
      fromColumns: 5,
      toColumns: 3,
      rowRadius: 1,
      itemCount: 100
    ))

    let center = slot(in: slots, row: 0, column: 0)
    XCTAssertEqual(center?.sourceIndex, 12)
    XCTAssertEqual(center?.targetIndex, 12)
  }

  func testFiveToThreeMiddleAnchorKeepsSymmetricDestinationWindowWhenModuloAlsoMiddle() {
    let slots = TimelineGridTransition.localAnchoredSlots(input: GridTransitionInput(
      targetIndex: 7,
      fromColumns: 5,
      toColumns: 3,
      rowRadius: 0,
      itemCount: 100
    ))

    XCTAssertEqual(sourceColumns(in: slots, row: 0), [-2, -1, 0, 1, 2])
    XCTAssertEqual(targetColumns(in: slots, row: 0), [-1, 0, 1])
    XCTAssertEqual(slot(in: slots, row: 0, column: -1)?.targetIndex, 6)
    XCTAssertEqual(slot(in: slots, row: 0, column: 0)?.targetIndex, 7)
    XCTAssertEqual(slot(in: slots, row: 0, column: 1)?.targetIndex, 8)
  }

  func testFiveToThreeMiddleAnchorKeepsSymmetricDestinationWindowEvenWhenModuloWouldBeLeft() {
    let slots = TimelineGridTransition.localAnchoredSlots(input: GridTransitionInput(
      targetIndex: 12,
      fromColumns: 5,
      toColumns: 3,
      rowRadius: 0,
      itemCount: 100
    ))

    XCTAssertEqual(12 % 5, 2)
    XCTAssertEqual(12 % 3, 0)
    XCTAssertEqual(sourceColumns(in: slots, row: 0), [-2, -1, 0, 1, 2])
    XCTAssertEqual(targetColumns(in: slots, row: 0), [-1, 0, 1])
    XCTAssertEqual(slot(in: slots, row: 0, column: -1)?.targetIndex, 11)
    XCTAssertEqual(slot(in: slots, row: 0, column: 0)?.targetIndex, 12)
    XCTAssertEqual(slot(in: slots, row: 0, column: 1)?.targetIndex, 13)
  }

  func testFiveToThreeLeftSourceColumnKeepsFocusColumnAndPansRightColumnsOffscreen() {
    let slots = TimelineGridTransition.localAnchoredSlots(input: GridTransitionInput(
      targetIndex: 11,
      fromColumns: 5,
      toColumns: 3,
      rowRadius: 0,
      itemCount: 100
    ))

    XCTAssertEqual(11 % 5, 1)
    XCTAssertEqual(TimelineGridTransition.destinationColumnPreservingVisualPosition(sourceColumn: 1, fromColumns: 5, toColumns: 3), 1)
    XCTAssertEqual(sourceColumns(in: slots, row: 0), [-1, 0, 1, 2, 3])
    XCTAssertEqual(targetColumns(in: slots, row: 0), [-1, 0, 1])
    XCTAssertEqual(slot(in: slots, row: 0, column: -1)?.targetIndex, 10)
    XCTAssertEqual(slot(in: slots, row: 0, column: 0)?.targetIndex, 11)
    XCTAssertEqual(slot(in: slots, row: 0, column: 1)?.targetIndex, 12)
    XCTAssertNil(slot(in: slots, row: 0, column: 2)?.targetIndex)
  }

  func testFiveToThreeRightSourceColumnKeepsFocusColumnAndPansLeftColumnsOffscreen() {
    let slots = TimelineGridTransition.localAnchoredSlots(input: GridTransitionInput(
      targetIndex: 13,
      fromColumns: 5,
      toColumns: 3,
      rowRadius: 0,
      itemCount: 100
    ))

    XCTAssertEqual(13 % 5, 3)
    XCTAssertEqual(TimelineGridTransition.destinationColumnPreservingVisualPosition(sourceColumn: 3, fromColumns: 5, toColumns: 3), 1)
    XCTAssertEqual(sourceColumns(in: slots, row: 0), [-3, -2, -1, 0, 1])
    XCTAssertEqual(targetColumns(in: slots, row: 0), [-1, 0, 1])
    XCTAssertNil(slot(in: slots, row: 0, column: -2)?.targetIndex)
    XCTAssertEqual(slot(in: slots, row: 0, column: -1)?.targetIndex, 12)
    XCTAssertEqual(slot(in: slots, row: 0, column: 0)?.targetIndex, 13)
    XCTAssertEqual(slot(in: slots, row: 0, column: 1)?.targetIndex, 14)
  }

  func testFiveToThreeDoesNotDropLeftDestinationColumnForMiddleVisualAnchorBecauseAnchorModuloIsLeft() {
    let slots = TimelineGridTransition.localAnchoredSlots(input: GridTransitionInput(
      targetIndex: 12,
      fromColumns: 5,
      toColumns: 3,
      rowRadius: 0,
      itemCount: 100
    ))

    XCTAssertNotNil(slot(in: slots, row: 0, column: -1)?.targetIndex)
    XCTAssertNotNil(slot(in: slots, row: 0, column: 0)?.targetIndex)
    XCTAssertNotNil(slot(in: slots, row: 0, column: 1)?.targetIndex)
    XCTAssertNil(slot(in: slots, row: 0, column: -2)?.targetIndex)
    XCTAssertNil(slot(in: slots, row: 0, column: 2)?.targetIndex)
  }

  func testThreeToFiveExpandsAroundMappedAnchorColumn() {
    let slots = TimelineGridTransition.localAnchoredSlots(input: GridTransitionInput(
      targetIndex: 12,
      fromColumns: 3,
      toColumns: 5,
      rowRadius: 0,
      itemCount: 100
    ))

    XCTAssertEqual(12 % 3, 0)
    XCTAssertEqual(TimelineGridTransition.destinationColumnPreservingVisualPosition(sourceColumn: 0, fromColumns: 3, toColumns: 5), 1)
    XCTAssertEqual(sourceColumns(in: slots, row: 0), [0, 1, 2])
    XCTAssertEqual(targetColumns(in: slots, row: 0), [-1, 0, 1, 2, 3])
    XCTAssertEqual(slot(in: slots, row: 0, column: -1)?.targetIndex, 11)
    XCTAssertEqual(slot(in: slots, row: 0, column: 3)?.targetIndex, 15)
  }

  func testSevenToFiveMiddleAnchorKeepsSymmetricDestinationWindow() {
    let slots = TimelineGridTransition.localAnchoredSlots(input: GridTransitionInput(
      targetIndex: 17,
      fromColumns: 7,
      toColumns: 5,
      rowRadius: 0,
      itemCount: 100
    ))

    XCTAssertEqual(17 % 7, 3)
    XCTAssertEqual(sourceColumns(in: slots, row: 0), [-3, -2, -1, 0, 1, 2, 3])
    XCTAssertEqual(targetColumns(in: slots, row: 0), [-2, -1, 0, 1, 2])
  }

  func testAssetListEdgesDropOutOfBoundsIndicesInsideVisibleWindow() {
    let slots = TimelineGridTransition.localAnchoredSlots(input: GridTransitionInput(
      targetIndex: 0,
      fromColumns: 5,
      toColumns: 3,
      rowRadius: 0,
      itemCount: 10
    ))

    XCTAssertEqual(TimelineGridTransition.relativeColumnWindow(anchorColumn: 0, columns: 3), 0...2)
    XCTAssertNil(slot(in: slots, row: 0, column: -1)?.targetIndex)
    XCTAssertEqual(slot(in: slots, row: 0, column: 0)?.targetIndex, 0)
    XCTAssertEqual(slot(in: slots, row: 0, column: 1)?.targetIndex, 1)
    XCTAssertEqual(slot(in: slots, row: 0, column: 2)?.targetIndex, 2)
    XCTAssertNil(slot(in: slots, row: 0, column: -1)?.sourceIndex)
    XCTAssertEqual(slot(in: slots, row: 0, column: 0)?.sourceIndex, 0)
    XCTAssertEqual(slot(in: slots, row: 0, column: 1)?.sourceIndex, 1)
    XCTAssertEqual(slot(in: slots, row: 0, column: 2)?.sourceIndex, 2)
  }

  func testRowsAreSampledAroundAnchorUsingEachLayoutsColumnCount() {
    let slots = TimelineGridTransition.localAnchoredSlots(input: GridTransitionInput(
      targetIndex: 12,
      fromColumns: 5,
      toColumns: 3,
      rowRadius: 1,
      itemCount: 100
    ))

    XCTAssertEqual(slot(in: slots, row: -1, column: 0)?.sourceIndex, 7)
    XCTAssertEqual(slot(in: slots, row: 1, column: 0)?.sourceIndex, 17)
    XCTAssertEqual(slot(in: slots, row: -1, column: 0)?.targetIndex, 9)
    XCTAssertEqual(slot(in: slots, row: 1, column: 0)?.targetIndex, 15)
  }

  func testColumnTransitionWindowShrinksSevenToFiveAroundFocusColumn() {
    let windows = (0..<7).map {
      TimelineGridTransition.columnTransitionWindow(sourceColumn: $0, fromColumns: 7, toColumns: 5)
    }

    XCTAssertEqual(windows.map(\.sourceStart), [0, 0, 0, 1, 2, 2, 2])
    XCTAssertEqual(windows.map(\.sourceEnd), [4, 4, 4, 5, 6, 6, 6])
    XCTAssertEqual(windows.map(\.targetFocusColumn), [0, 1, 2, 2, 2, 3, 4])
  }

  func testColumnTransitionWindowShrinksFiveToThreeAroundFocusColumn() {
    let windows = (0..<5).map {
      TimelineGridTransition.columnTransitionWindow(sourceColumn: $0, fromColumns: 5, toColumns: 3)
    }

    XCTAssertEqual(windows.map(\.sourceStart), [0, 0, 1, 2, 2])
    XCTAssertEqual(windows.map(\.sourceEnd), [2, 2, 3, 4, 4])
    XCTAssertEqual(windows.map(\.targetFocusColumn), [0, 1, 1, 1, 2])
  }

  func testDestinationColumnPreservesVisualPositionWhenShrinkingFiveToThree() {
    let mappedColumns = (0..<5).map {
      TimelineGridTransition.destinationColumnPreservingVisualPosition(sourceColumn: $0, fromColumns: 5, toColumns: 3)
    }

    XCTAssertEqual(mappedColumns, [0, 1, 1, 1, 2])
  }

  func testColumnTransitionWindowExpandsThreeToFiveAroundSourceCanvas() {
    let windows = (0..<3).map {
      TimelineGridTransition.columnTransitionWindow(sourceColumn: $0, fromColumns: 3, toColumns: 5)
    }

    XCTAssertEqual(windows.map(\.sourceStart), [0, 0, 0])
    XCTAssertEqual(windows.map(\.sourceEnd), [2, 2, 2])
    XCTAssertEqual(windows.map(\.targetStart), [1, 1, 1])
    XCTAssertEqual(windows.map(\.targetEnd), [3, 3, 3])
    XCTAssertEqual(windows.map(\.targetFocusColumn), [1, 2, 3])
  }

  func testDestinationColumnPreservesVisualPositionWhenExpandingThreeToFive() {
    let mappedColumns = (0..<3).map {
      TimelineGridTransition.destinationColumnPreservingVisualPosition(sourceColumn: $0, fromColumns: 3, toColumns: 5)
    }

    XCTAssertEqual(mappedColumns, [1, 2, 3])
  }

  func testColumnOffsetMovesAnchorToDesiredDestinationColumn() {
    XCTAssertEqual(TimelineGridTransition.columnOffset(anchorIndex: 12, columns: 3, desiredColumn: 1), 1)
    XCTAssertEqual(TimelineGridTransition.column(anchorIndex: 12, columns: 3, columnOffset: 1), 1)

    XCTAssertEqual(TimelineGridTransition.columnOffset(anchorIndex: 13, columns: 3, desiredColumn: 1), 0)
    XCTAssertEqual(TimelineGridTransition.column(anchorIndex: 13, columns: 3, columnOffset: 0), 1)

    XCTAssertEqual(TimelineGridTransition.columnOffset(anchorIndex: 14, columns: 3, desiredColumn: 1), 2)
    XCTAssertEqual(TimelineGridTransition.column(anchorIndex: 14, columns: 3, columnOffset: 2), 1)
  }

  func testGridOriginInterpolatesFromSourceColumnToDestinationColumnWithoutSnapping() {
    let sourceMetrics = TimelineGridTransition.GridMetrics(width: 390, columns: 5, spacing: 2)
    let targetMetrics = TimelineGridTransition.GridMetrics(width: 390, columns: 3, spacing: 2)
    let sourceColumn = TimelineGridTransition.sourceColumn(anchorIndex: 11, columns: 5)
    let destinationColumn = TimelineGridTransition.destinationColumnPreservingVisualPosition(
      sourceColumn: sourceColumn,
      fromColumns: 5,
      toColumns: 3
    )
    let sourceOriginX = TimelineGridTransition.cellLeftX(column: sourceColumn, metrics: sourceMetrics, spacing: 2)
    let targetOriginX = TimelineGridTransition.cellLeftX(column: destinationColumn, metrics: targetMetrics, spacing: 2)

    XCTAssertEqual(sourceColumn, 1)
    XCTAssertEqual(destinationColumn, 1)
    XCTAssertEqual(sourceOriginX, 79)
    XCTAssertEqual(targetOriginX, 131)
    XCTAssertEqual(TimelineGridTransition.interpolatedOriginX(sourceOriginX: sourceOriginX, targetOriginX: targetOriginX, progress: 0), sourceOriginX)
    XCTAssertEqual(TimelineGridTransition.interpolatedOriginX(sourceOriginX: sourceOriginX, targetOriginX: targetOriginX, progress: 0.5), 105)
    XCTAssertEqual(TimelineGridTransition.interpolatedOriginX(sourceOriginX: sourceOriginX, targetOriginX: targetOriginX, progress: 1), targetOriginX)
  }

  func testDestinationWindowFitsViewportAtTargetOrigin() {
    let metrics = TimelineGridTransition.GridMetrics(width: 390, columns: 3, spacing: 2)
    let targetColumn = 0
    let originX = TimelineGridTransition.cellLeftX(column: targetColumn, metrics: metrics, spacing: 2)
    let window = TimelineGridTransition.relativeColumnWindow(anchorColumn: targetColumn, columns: 3)
    let leftX = originX + Double(window.lowerBound) * metrics.step
    let rightX = originX + Double(window.upperBound) * metrics.step + metrics.tileSize

    XCTAssertEqual(window, 0...2)
    XCTAssertEqual(leftX, 2)
    XCTAssertLessThanOrEqual(rightX, 390)
  }

  func testContinuousZoomPositionMovesOneLevelPerScaleStep() {
    XCTAssertEqual(TimelineGridTransition.continuousZoomPosition(
      startPosition: 0,
      startScale: 1,
      currentScale: 1,
      scalePerLevel: 1.65,
      minPosition: 0,
      maxPosition: 2
    ), 0, accuracy: 0.0001)
    XCTAssertEqual(TimelineGridTransition.continuousZoomPosition(
      startPosition: 0,
      startScale: 1,
      currentScale: 1.65,
      scalePerLevel: 1.65,
      minPosition: 0,
      maxPosition: 2
    ), 1, accuracy: 0.0001)
    XCTAssertEqual(TimelineGridTransition.continuousZoomPosition(
      startPosition: 0,
      startScale: 1,
      currentScale: 1.65 * 1.65,
      scalePerLevel: 1.65,
      minPosition: 0,
      maxPosition: 2
    ), 2, accuracy: 0.0001)
  }

  func testContinuousZoomPositionClampsWhenReversingFromThreeColumns() {
    XCTAssertEqual(TimelineGridTransition.continuousZoomPosition(
      startPosition: 2,
      startScale: 1,
      currentScale: 1 / 1.65,
      scalePerLevel: 1.65,
      minPosition: 0,
      maxPosition: 2
    ), 1, accuracy: 0.0001)
    XCTAssertEqual(TimelineGridTransition.continuousZoomPosition(
      startPosition: 2,
      startScale: 1,
      currentScale: 1 / (1.65 * 1.65 * 1.65),
      scalePerLevel: 1.65,
      minPosition: 0,
      maxPosition: 2
    ), 0, accuracy: 0.0001)
  }

  func testZoomSegmentIndicesFollowPinchDirectionAtBoundaries() {
    XCTAssertEqual(TimelineGridTransition.zoomSegmentIndices(position: 1.25, previousPosition: 0.75, minPosition: 0, maxPosition: 2)?.from, 1)
    XCTAssertEqual(TimelineGridTransition.zoomSegmentIndices(position: 1.25, previousPosition: 0.75, minPosition: 0, maxPosition: 2)?.to, 2)
    XCTAssertEqual(TimelineGridTransition.zoomSegmentIndices(position: 0.75, previousPosition: 1.25, minPosition: 0, maxPosition: 2)?.from, 1)
    XCTAssertEqual(TimelineGridTransition.zoomSegmentIndices(position: 0.75, previousPosition: 1.25, minPosition: 0, maxPosition: 2)?.to, 0)
  }

  func testZoomSegmentProgressSupportsBothDirections() {
    XCTAssertEqual(TimelineGridTransition.zoomSegmentProgress(position: 0.25, fromPosition: 0, toPosition: 1), 0.25, accuracy: 0.0001)
    XCTAssertEqual(TimelineGridTransition.zoomSegmentProgress(position: 0.75, fromPosition: 1, toPosition: 0), 0.25, accuracy: 0.0001)
    XCTAssertEqual(TimelineGridTransition.nearestZoomPosition(1.49, minPosition: 0, maxPosition: 2), 1)
    XCTAssertEqual(TimelineGridTransition.nearestZoomPosition(1.5, minPosition: 0, maxPosition: 2), 2)
  }

  func testHitTestingSelectsExactSourceColumnUnderPoint() {
    let width = 390.0
    let spacing = 2.0
    let metrics = TimelineGridTransition.GridMetrics(width: width, columns: 5, spacing: spacing)

    for column in 0..<5 {
      let x = spacing + Double(column) * metrics.step + metrics.tileSize / 2
      let index = TimelineGridTransition.hitTestGridIndex(
        x: x,
        y: spacing + metrics.tileSize / 2,
        columns: 5,
        width: width,
        spacing: spacing,
        gridColumnOffset: 0,
        itemCount: 100
      )
      XCTAssertEqual(index, column)
    }
  }

  func testHitTestingAccountsForGridColumnOffset() {
    let index = TimelineGridTransition.hitTestGridIndex(
      x: 2 + 2 * 78 + 37.5,
      y: 2 + 3 * 78 + 37.5,
      columns: 5,
      width: 390,
      spacing: 2,
      gridColumnOffset: 2,
      itemCount: 100
    )

    XCTAssertEqual(index, 15)
  }

  func testRowCountAccountsForGridColumnOffset() {
    XCTAssertEqual(TimelineGridTransition.rowCount(itemCount: 15, columns: 5, gridColumnOffset: 0), 3)
    XCTAssertEqual(TimelineGridTransition.rowCount(itemCount: 15, columns: 5, gridColumnOffset: 1), 4)
    XCTAssertEqual(TimelineGridTransition.rowCount(itemCount: 16, columns: 5, gridColumnOffset: 4), 4)
    XCTAssertEqual(TimelineGridTransition.rowCount(itemCount: 0, columns: 5, gridColumnOffset: 4), 0)
  }

  func testIndexAtGridOffsetUsesAdjustedGridCoordinates() {
    XCTAssertEqual(TimelineGridTransition.indexAtGridOffset(
      anchorIndex: 11,
      columns: 5,
      gridColumnOffset: 2,
      relativeRow: 0,
      relativeColumn: -1,
      itemCount: 100
    ), 10)
    XCTAssertEqual(TimelineGridTransition.indexAtGridOffset(
      anchorIndex: 11,
      columns: 5,
      gridColumnOffset: 2,
      relativeRow: 1,
      relativeColumn: 0,
      itemCount: 100
    ), 16)
    XCTAssertEqual(TimelineGridTransition.indexAtGridOffset(
      anchorIndex: 0,
      columns: 5,
      gridColumnOffset: 2,
      relativeRow: 0,
      relativeColumn: -3,
      itemCount: 100
    ), nil)
  }

  func testHitTestingRejectsSpacingGutters() {
    let index = TimelineGridTransition.hitTestGridIndex(
      x: 78,
      y: 20,
      columns: 5,
      width: 390,
      spacing: 2,
      gridColumnOffset: 0,
      itemCount: 100
    )

    XCTAssertNil(index)
  }

  private func slot(in slots: [GridTransitionSlot], row: Int, column: Int) -> GridTransitionSlot? {
    slots.first { $0.relativeRow == row && $0.relativeColumn == column }
  }

  private func sourceColumns(in slots: [GridTransitionSlot], row: Int) -> [Int] {
    slots
      .filter { $0.relativeRow == row && $0.sourceIndex != nil }
      .map(\.relativeColumn)
      .sorted()
  }

  private func targetColumns(in slots: [GridTransitionSlot], row: Int) -> [Int] {
    slots
      .filter { $0.relativeRow == row && $0.targetIndex != nil }
      .map(\.relativeColumn)
      .sorted()
  }
}
