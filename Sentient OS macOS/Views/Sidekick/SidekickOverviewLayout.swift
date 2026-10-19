import Foundation
import CoreGraphics

/// A readable, bounded spread. Short windows page through cards instead of compressing
/// their type or overlapping the next row. Heights come from the actual rendered cards.
nonisolated struct SidekickOverviewLayout {
    static let gap: CGFloat = 24
    static let pagerHeight: CGFloat = 48
    let region: CGRect
    let cardWidth: CGFloat
    let rowHeight: CGFloat
    let columns: Int
    let rows: Int
    let capacity: Int
    let pageCount: Int
    let page: Int
    let visibleRange: Range<Int>
    let positions: [CGPoint]

    static func width(for size: CGSize, count: Int) -> CGFloat {
        let columns = min(max(count, 1), size.width >= 1_180 ? 3 : 2)
        return min(400, max(240, (size.width - 76 - CGFloat(columns - 1) * gap) / CGFloat(columns)))
    }

    init(size: CGSize, top: CGFloat, bottom: CGFloat, heights: [CGFloat], requestedPage: Int) {
        let count = heights.count
        columns = min(max(count, 1), size.width >= 1_180 ? 3 : 2)
        cardWidth = Self.width(for: size, count: count)
        region = CGRect(x: 0, y: top, width: size.width, height: max(0, bottom - top))
        rowHeight = max(1, heights.max() ?? 200)
        let room = max(0, region.height - Self.pagerHeight)
        rows = count > columns && rowHeight * 2 + Self.gap <= room ? 2 : 1
        capacity = columns * rows
        pageCount = max(1, (count + capacity - 1) / capacity)
        page = min(max(0, requestedPage), pageCount - 1)
        let start = page * capacity
        visibleRange = start..<min(count, start + capacity)
        let visibleRows = max(1, (visibleRange.count + columns - 1) / columns)
        let usedHeight = CGFloat(visibleRows) * rowHeight + CGFloat(visibleRows - 1) * Self.gap
        let startY = top + max(0, room - usedHeight) * 0.28
        var centers: [CGPoint] = []
        for index in heights.indices {
            let local = index % capacity
            let row = local / columns
            let column = local % columns
            // Center the shorter final row, including a lone welcome envelope.
            let itemsOnRow = max(1, min(columns, visibleRange.count - row * columns))
            let spread = CGFloat(itemsOnRow) * cardWidth + CGFloat(itemsOnRow - 1) * Self.gap
            centers.append(CGPoint(x: (size.width - spread) / 2 + CGFloat(column) * (cardWidth + Self.gap) + cardWidth / 2,
                                   y: startY + CGFloat(row) * (rowHeight + Self.gap) + heights[index] / 2))
        }
        positions = centers
    }
}
