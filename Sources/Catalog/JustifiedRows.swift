import Foundation

/// Pure layout maths for the Library's "justified rows" grid: rows of equal height in which every photo keeps its own aspect ratio and every
/// full row is stretched to the available width exactly (the Flickr / Google Photos look). No UI imports, like `LibraryGridColumns`: the view
/// only draws what this returns, and the keyboard's Up/Down movement is decided here too (`neighbor`).
///
/// Rules (all covered by `JustifiedRowsTests`):
/// - A row gets as many photos as fit at `targetRowHeight`; whether the NEXT photo joins is decided by which choice leaves the row's scale
///   factor closest to 1 (so rows stay near the target height instead of one outlier squeezing a whole row).
/// - Widths in a full row plus the gaps sum to `availableWidth` (within floating-point rounding); every photo in a row has the row's height.
/// - The LAST row stays at the target height, left-aligned, unless it is at least `lastRowFillThreshold` full (then it is justified too).
/// - A cell is never narrower than `minCellWidth` (the star/flag row under a thumbnail needs ~116 pt). If the available width is smaller than
///   that, the width is raised to `minCellWidth` (the cell is then clipped by the scroll view, not squeezed).
/// - An aspect ratio that is not finite or not positive counts as 1 (square); aspects are clamped to `minCellWidth/targetRowHeight ... maxAspect`,
///   so one panorama cannot take a whole row at a distorted height.
enum JustifiedRows {
    struct Item: Equatable, Sendable {
        /// Index into the caller's `aspects` array (the grid's display order).
        var index: Int
        var x: Double
        var width: Double
    }

    struct Row: Equatable, Sendable {
        var items: [Item]
        var height: Double
        /// False only for a short last row that was left at the target height.
        var isJustified: Bool
    }

    static let defaultMinCellWidth = 116.0
    static let defaultMaxAspect = 3.0
    static let lastRowFillThreshold = 0.7

    static func layout(aspects: [Double], availableWidth: Double, targetRowHeight: Double, spacing: Double,
                       minCellWidth: Double = defaultMinCellWidth, maxAspect: Double = defaultMaxAspect) -> [Row] {
        guard !aspects.isEmpty else { return [] }
        let minWidth = (minCellWidth.isFinite && minCellWidth > 0) ? minCellWidth : defaultMinCellWidth
        let target = (targetRowHeight.isFinite && targetRowHeight >= 1) ? targetRowHeight : 140
        let gap = (spacing.isFinite && spacing >= 0) ? spacing : 0
        let width = max((availableWidth.isFinite ? availableWidth : 0), minWidth)
        let cap = (maxAspect.isFinite && maxAspect >= 1) ? maxAspect : defaultMaxAspect
        let floorAspect = min(minWidth / target, cap)
        // The most photos a row may hold and still give each its minimum width.
        let maxItems = max(1, Int(((width + gap) / (minWidth + gap)).rounded(.down)))

        let natural: [Double] = aspects.map { raw in
            let value = (raw.isFinite && raw > 0) ? raw : 1
            return min(cap, max(floorAspect, value)) * target
        }

        var rows: [Row] = []
        var start = 0
        while start < natural.count {
            // Fill at the target height.
            var end = start
            var sum = 0.0
            while end < natural.count, end - start < maxItems {
                let candidate = sum + natural[end]
                if end > start, candidate + Double(end - start) * gap > width { break }
                sum = candidate
                end += 1
            }
            // Maybe the next photo fits better by being squeezed in than by leaving the row short.
            if end < natural.count, end - start < maxItems, end > start {
                let gaps = Double(end - start) * gap
                let without = (width - gaps + gap) / max(sum, 1)     // scale of the row as it is (> 1: stretched)
                let withNext = (width - gaps) / (sum + natural[end]) // scale if the next photo joins (< 1: squeezed)
                if abs(log(max(withNext, 1e-9))) < abs(log(max(without, 1e-9))) {
                    sum += natural[end]
                    end += 1
                }
            }
            let count = end - start
            let gaps = Double(max(0, count - 1)) * gap
            let isLast = end >= natural.count
            let fill = (sum + gaps) / width
            let justify = !isLast || fill >= lastRowFillThreshold
            let scale = justify ? (width - gaps) / sum : 1
            var widths = (start..<end).map { natural[$0] * scale }
            if justify { widths = enforceMinimum(widths, minWidth: minWidth, total: width - gaps) }
            else { widths = widths.map { max($0, minWidth) } }
            var x = 0.0
            var items: [Item] = []
            for (offset, w) in widths.enumerated() {
                items.append(Item(index: start + offset, x: x, width: w))
                x += w + gap
            }
            rows.append(Row(items: items, height: target * scale, isJustified: justify))
            start = end
        }
        return rows
    }

    /// Raises any width below `minWidth` to it and shrinks the others proportionally so the total stays `total` (repeated until nothing is below).
    private static func enforceMinimum(_ input: [Double], minWidth: Double, total: Double) -> [Double] {
        var widths = input
        var fixed = Set<Int>()
        for _ in 0..<widths.count {
            var changed = false
            for i in widths.indices where !fixed.contains(i) && widths[i] < minWidth {
                widths[i] = minWidth
                fixed.insert(i)
                changed = true
            }
            guard changed else { break }
            let freeIndices = widths.indices.filter { !fixed.contains($0) }
            let freeSum = freeIndices.reduce(0.0) { $0 + input[$1] }
            let remaining = total - Double(fixed.count) * minWidth
            guard !freeIndices.isEmpty, freeSum > 0, remaining > 0 else { break }
            for i in freeIndices { widths[i] = input[i] * remaining / freeSum }
        }
        return widths
    }

    enum Direction { case up, down }

    /// The row holding photo `index`, or nil.
    static func rowIndex(of index: Int, in rows: [Row]) -> Int? {
        rows.firstIndex { $0.items.contains { $0.index == index } }
    }

    /// The photo one row up or down from `index` whose horizontal centre is nearest to the current photo's (the lower index wins a tie), or nil at the top / bottom.
    static func neighbor(of index: Int, direction: Direction, in rows: [Row]) -> Int? {
        guard let rowNumber = rowIndex(of: index, in: rows),
              let current = rows[rowNumber].items.first(where: { $0.index == index }) else { return nil }
        let target = direction == .up ? rowNumber - 1 : rowNumber + 1
        guard rows.indices.contains(target), !rows[target].items.isEmpty else { return nil }
        let centre = current.x + current.width / 2
        return rows[target].items.min { a, b in
            let da = abs(a.x + a.width / 2 - centre), db = abs(b.x + b.width / 2 - centre)
            return da == db ? a.index < b.index : da < db
        }?.index
    }
}
