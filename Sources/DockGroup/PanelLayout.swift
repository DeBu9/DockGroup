import AppKit

/// Single source of truth for panel geometry. Both the AppKit window and the
/// SwiftUI root use these numbers, so a drill-down can resize the window
/// without leaving letterboxing or clipping behind.
enum PanelLayout {
    static let maxColumns = 4
    static let maxRows = 5
    static let cell = CGSize(width: 80, height: 88)
    static let spacing: CGFloat = 8
    static let sidePadding: CGFloat = 14
    static let gridPadding: CGFloat = 12
    static let headerHeight: CGFloat = 46
    static let footerHeight: CGFloat = 30
    static let dividerHeight: CGFloat = 1
    static let minWidth: CGFloat = 268
    static let cornerRadius: CGFloat = 22

    static func columnCount(for count: Int) -> Int {
        min(max(count, 1), maxColumns)
    }

    static func visibleRowCount(for count: Int) -> Int {
        let cols = maxColumns
        let rows = (max(count, 1) + cols - 1) / cols
        return min(max(rows, 1), maxRows)
    }

    static func gridWidth(for count: Int) -> CGFloat {
        let cols = columnCount(for: count)
        return CGFloat(cols) * cell.width + CGFloat(cols - 1) * spacing
    }

    static func size(for count: Int) -> NSSize {
        let width = max(minWidth, gridWidth(for: count) + sidePadding * 2)
        let rows = visibleRowCount(for: count)
        let gridHeight = gridPadding * 2
            + CGFloat(rows) * cell.height
            + CGFloat(rows - 1) * spacing
        let height = headerHeight + dividerHeight * 2 + gridHeight + footerHeight
        return NSSize(width: width, height: height)
    }
}
