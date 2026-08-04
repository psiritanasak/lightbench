import SwiftUI

/// Shared rule-of-thirds grid-drawing math, used by `CropOverlayView`'s
/// own crop-rect grid. (A separate always-visible guideline overlay for
/// Straighten/Vertical/Horizontal existed briefly but was removed once
/// those controls moved into the Crop tab — at that point they're only
/// ever visible while the crop overlay's own grid is already showing, so a
/// second grid would have been redundant. This matches Apple Photos' own
/// behavior: no separate guideline, the crop tool's grid IS the guideline.)
enum GridLines {
    /// Major (rule-of-thirds) grid lines: 2 lines each direction, at 1/3 and
    /// 2/3, in the given rect's own LOCAL coordinate space (caller
    /// positions/sizes the resulting Path's container).
    static func major(in rect: CGRect) -> Path {
        lines(in: rect, at: [1, 2], of: 3)
    }

    /// Minor grid lines subdividing each major third into `subdivisions`
    /// further cells (default 3, giving a fine 9-cells-per-major-cell
    /// grid). Excludes the positions `major(in:)` already draws, so the two
    /// paths never overlap — draw both, styled differently (thinner/fainter
    /// for minor), to get a Photoshop/Lightroom-style two-tier grid.
    static func minor(in rect: CGRect, subdivisions: Int = 3) -> Path {
        let count = 3 * subdivisions
        let majorPositions = Set([1, 2].map { $0 * subdivisions })
        let positions = (1..<count).filter { !majorPositions.contains($0) }
        return lines(in: rect, at: positions, of: count)
    }

    private static func lines(in rect: CGRect, at positions: [Int], of count: Int) -> Path {
        Path { path in
            for i in positions {
                let x = rect.minX + rect.width * CGFloat(i) / CGFloat(count)
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))

                let y = rect.minY + rect.height * CGFloat(i) / CGFloat(count)
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
    }
}
