import SwiftUI

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

/// Non-interactive rule-of-thirds guideline (major + minor grid) shown over
/// the full displayed image while actively dragging Straighten/Vertical/
/// Horizontal — helps align horizons/verticals. No handles, no dimming, no
/// gestures (unlike `CropOverlayView`, which this shares its grid-drawing
/// math with via `GridLines`).
struct GridGuidelineView: View {
    let fitRect: CGRect

    var body: some View {
        let local = CGRect(origin: .zero, size: fitRect.size)
        ZStack {
            // Dark "shadow" stroke under each line so it stays legible over
            // bright image content, not just dark — the white line alone
            // washes out against light backgrounds.
            GridLines.minor(in: local)
                .stroke(Color.black.opacity(0.5), lineWidth: 1.5)
            GridLines.minor(in: local)
                .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
            GridLines.major(in: local)
                .stroke(Color.black.opacity(0.6), lineWidth: 2.5)
            GridLines.major(in: local)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
        }
        .frame(width: fitRect.width, height: fitRect.height)
        .position(x: fitRect.midX, y: fitRect.midY)
        .allowsHitTesting(false)
    }
}
