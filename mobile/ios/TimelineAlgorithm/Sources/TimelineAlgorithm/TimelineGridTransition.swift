import Foundation

public struct GridTransitionInput: Equatable, Sendable {
  public let targetIndex: Int
  public let fromColumns: Int
  public let toColumns: Int
  public let rowRadius: Int
  public let columnOverscan: Int
  public let itemCount: Int

  public init(
    targetIndex: Int,
    fromColumns: Int,
    toColumns: Int,
    rowRadius: Int,
    columnOverscan: Int = 0,
    itemCount: Int
  ) {
    self.targetIndex = targetIndex
    self.fromColumns = fromColumns
    self.toColumns = toColumns
    self.rowRadius = rowRadius
    self.columnOverscan = columnOverscan
    self.itemCount = itemCount
  }
}

public struct GridTransitionSlot: Equatable, Sendable {
  public let relativeRow: Int
  public let relativeColumn: Int
  public let sourceIndex: Int?
  public let targetIndex: Int?

  public init(relativeRow: Int, relativeColumn: Int, sourceIndex: Int?, targetIndex: Int?) {
    self.relativeRow = relativeRow
    self.relativeColumn = relativeColumn
    self.sourceIndex = sourceIndex
    self.targetIndex = targetIndex
  }
}

public struct ColumnTransitionWindow: Equatable, Sendable {
  public let sourceStart: Int
  public let sourceEnd: Int
  public let targetStart: Int
  public let targetEnd: Int
  public let sourceFocusColumn: Int
  public let targetFocusColumn: Int

  public init(
    sourceStart: Int,
    sourceEnd: Int,
    targetStart: Int,
    targetEnd: Int,
    sourceFocusColumn: Int,
    targetFocusColumn: Int
  ) {
    self.sourceStart = sourceStart
    self.sourceEnd = sourceEnd
    self.targetStart = targetStart
    self.targetEnd = targetEnd
    self.sourceFocusColumn = sourceFocusColumn
    self.targetFocusColumn = targetFocusColumn
  }
}

public enum TimelineGridTransition {
  public struct GridMetrics: Equatable, Sendable {
    public let tileSize: Double
    public let step: Double

    public init(width: Double, columns: Double, spacing: Double) {
      let columns = max(1, columns)
      tileSize = floor((width - spacing * (columns + 1)) / columns)
      step = tileSize + spacing
    }
  }

  public static func sourceColumn(anchorIndex: Int, columns: Int) -> Int {
    precondition(columns > 0, "columns must be positive")
    return positiveModulo(anchorIndex, columns)
  }

  public static func columnTransitionWindow(sourceColumn: Int, fromColumns: Int, toColumns: Int) -> ColumnTransitionWindow {
    precondition(fromColumns > 0, "fromColumns must be positive")
    precondition(toColumns > 0, "toColumns must be positive")
    precondition((0..<fromColumns).contains(sourceColumn), "sourceColumn must be in fromColumns")

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

  public static func destinationColumnPreservingVisualPosition(sourceColumn: Int, fromColumns: Int, toColumns: Int) -> Int {
    columnTransitionWindow(
      sourceColumn: sourceColumn,
      fromColumns: fromColumns,
      toColumns: toColumns
    ).targetFocusColumn
  }

  public static func columnOffset(anchorIndex: Int, columns: Int, desiredColumn: Int) -> Int {
    precondition(columns > 0, "columns must be positive")
    precondition((0..<columns).contains(desiredColumn), "desiredColumn must be in columns")

    let currentColumn = positiveModulo(anchorIndex, columns)
    return positiveModulo(desiredColumn - currentColumn, columns)
  }

  public static func column(anchorIndex: Int, columns: Int, columnOffset: Int) -> Int {
    precondition(columns > 0, "columns must be positive")
    return positiveModulo(anchorIndex + columnOffset, columns)
  }

  public static func rowCount(itemCount: Int, columns: Int, gridColumnOffset: Int) -> Int {
    precondition(itemCount >= 0, "itemCount must be non-negative")
    precondition(columns > 0, "columns must be positive")
    guard itemCount > 0 else { return 0 }
    return floorDiv(itemCount - 1 + gridColumnOffset, columns) + 1
  }

  public static func indexAtGridOffset(
    anchorIndex: Int,
    columns: Int,
    gridColumnOffset: Int,
    relativeRow: Int,
    relativeColumn: Int,
    itemCount: Int
  ) -> Int? {
    precondition(columns > 0, "columns must be positive")
    precondition(itemCount >= 0, "itemCount must be non-negative")

    let adjustedAnchorIndex = anchorIndex + gridColumnOffset
    let anchorRow = floorDiv(adjustedAnchorIndex, columns)
    let anchorColumn = positiveModulo(adjustedAnchorIndex, columns)
    let adjustedIndex = (anchorRow + relativeRow) * columns + anchorColumn + relativeColumn
    let index = adjustedIndex - gridColumnOffset
    guard (0..<itemCount).contains(index) else { return nil }
    return index
  }

  public static func anchorX(column: Int, unitX: Double, metrics: GridMetrics, spacing: Double) -> Double {
    spacing + Double(column) * metrics.step + metrics.tileSize * unitX
  }

  public static func relativeColumnWindow(anchorColumn: Int, columns: Int) -> ClosedRange<Int> {
    precondition(columns > 0, "columns must be positive")
    return (-anchorColumn)...(columns - 1 - anchorColumn)
  }

  public static func cellLeftX(column: Int, metrics: GridMetrics, spacing: Double) -> Double {
    spacing + Double(column) * metrics.step
  }

  public static func interpolatedOriginX(sourceOriginX: Double, targetOriginX: Double, progress: Double) -> Double {
    sourceOriginX + (targetOriginX - sourceOriginX) * progress
  }

  public static func hitTestGridIndex(
    x: Double,
    y: Double,
    columns: Int,
    width: Double,
    spacing: Double,
    gridColumnOffset: Int,
    itemCount: Int
  ) -> Int? {
    precondition(columns > 0, "columns must be positive")
    let metrics = GridMetrics(width: width, columns: Double(columns), spacing: spacing)
    let column = Int(floor((x - spacing) / metrics.step))
    let row = Int(floor((y - spacing) / metrics.step))

    guard row >= 0, (0..<columns).contains(column) else { return nil }
    let columnX = spacing + Double(column) * metrics.step
    let rowY = spacing + Double(row) * metrics.step
    guard x >= columnX,
          x <= columnX + metrics.tileSize,
          y >= rowY,
          y <= rowY + metrics.tileSize else {
      return nil
    }

    let index = row * columns + column - gridColumnOffset
    guard (0..<itemCount).contains(index) else { return nil }
    return index
  }

  public static func localAnchoredSlots(input: GridTransitionInput) -> [GridTransitionSlot] {
    precondition(input.fromColumns > 0, "fromColumns must be positive")
    precondition(input.toColumns > 0, "toColumns must be positive")
    precondition(input.rowRadius >= 0, "rowRadius must be non-negative")
    precondition(input.columnOverscan >= 0, "columnOverscan must be non-negative")
    precondition(input.itemCount >= 0, "itemCount must be non-negative")

    let sourceColumn = sourceColumn(anchorIndex: input.targetIndex, columns: input.fromColumns)
    let transitionWindow = columnTransitionWindow(
      sourceColumn: sourceColumn,
      fromColumns: input.fromColumns,
      toColumns: input.toColumns
    )
    let targetColumn = transitionWindow.targetFocusColumn
    let sourceColumnWindow = relativeColumnWindow(anchorColumn: sourceColumn, columns: input.fromColumns)
    let targetColumnWindow = relativeColumnWindow(anchorColumn: targetColumn, columns: input.toColumns)
    let columnRadius = max(
      abs(min(sourceColumnWindow.lowerBound, targetColumnWindow.lowerBound)),
      abs(max(sourceColumnWindow.upperBound, targetColumnWindow.upperBound))
    ) + input.columnOverscan
    var slots: [GridTransitionSlot] = []

    for row in (-input.rowRadius)...input.rowRadius {
      for column in (-columnRadius)...columnRadius {
        let sourceIndex = index(
          anchoredAt: input.targetIndex,
          relativeRow: row,
          relativeColumn: column,
          columns: input.fromColumns,
          allowedColumnWindow: sourceColumnWindow,
          itemCount: input.itemCount
        )
        let targetIndex = index(
          anchoredAt: input.targetIndex,
          relativeRow: row,
          relativeColumn: column,
          columns: input.toColumns,
          allowedColumnWindow: targetColumnWindow,
          itemCount: input.itemCount
        )

        guard sourceIndex != nil || targetIndex != nil else { continue }
        slots.append(GridTransitionSlot(
          relativeRow: row,
          relativeColumn: column,
          sourceIndex: sourceIndex,
          targetIndex: targetIndex
        ))
      }
    }

    return slots
  }

  private static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
    let remainder = value % modulus
    return remainder >= 0 ? remainder : remainder + modulus
  }

  private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
    precondition(divisor > 0, "divisor must be positive")
    let quotient = value / divisor
    let remainder = value % divisor
    return remainder < 0 ? quotient - 1 : quotient
  }

  private static func index(
    anchoredAt targetIndex: Int,
    relativeRow: Int,
    relativeColumn: Int,
    columns: Int,
    allowedColumnWindow: ClosedRange<Int>,
    itemCount: Int
  ) -> Int? {
    guard allowedColumnWindow.contains(relativeColumn) else { return nil }

    let index = targetIndex + relativeRow * columns + relativeColumn
    guard (0..<itemCount).contains(index) else { return nil }
    return index
  }
}
