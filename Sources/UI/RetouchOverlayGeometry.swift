import CoreGraphics
import Foundation

/// Pure screen<->spot math for `RetouchOverlayView` (no SwiftUI), so it is unit-testable. All spot values are
/// fractions in the UNEDITED source frame (see `RetouchSpot`); the overlay is only shown at identity geometry,
/// where the displayed image IS that frame, so `fitRect` maps 1:1. Screen y runs DOWN, spot `y` runs UP.
enum RetouchOverlayGeometry {
    /// `radius` and the source offset are fractions of the MIN side, so circles stay circles.
    static func minSide(_ fitRect: CGRect) -> CGFloat { min(fitRect.width, fitRect.height) }

    static func centerPoint(of spot: RetouchSpot, in fitRect: CGRect) -> CGPoint {
        CGPoint(x: fitRect.minX + spot.x * fitRect.width, y: fitRect.minY + (1 - spot.y) * fitRect.height)
    }

    static func radiusPoints(of spot: RetouchSpot, in fitRect: CGRect) -> CGFloat {
        spot.radius * minSide(fitRect)
    }

    static func sourcePoint(of spot: RetouchSpot, in fitRect: CGRect) -> CGPoint {
        let c = centerPoint(of: spot, in: fitRect)
        let m = minSide(fitRect)
        return CGPoint(x: c.x + spot.sourceDX * m, y: c.y - spot.sourceDY * m)
    }

    /// New spot centre after dragging the spot circle by `translation` from `baseline` (clamped to the frame).
    /// The source offset is left alone, so the source circle travels with the spot.
    static func movedCenter(baseline: (x: Double, y: Double), translation: CGSize, fitRect: CGRect) -> (x: Double, y: Double) {
        guard fitRect.width > 0, fitRect.height > 0 else { return baseline }
        return (
            min(max(baseline.x + translation.width / fitRect.width, 0), 1),
            min(max(baseline.y - translation.height / fitRect.height, 0), 1)
        )
    }

    /// New source offset after dragging the source circle by `translation` from `baseline`. Limited to ±1 min side
    /// (a source further than the whole frame is never useful, and the pipeline clamps it into the frame anyway).
    static func movedOffset(baseline: (dx: Double, dy: Double), translation: CGSize, fitRect: CGRect) -> (dx: Double, dy: Double) {
        let m = Double(minSide(fitRect))
        guard m > 0 else { return baseline }
        return (
            min(max(baseline.dx + translation.width / m, -1), 1),
            min(max(baseline.dy - translation.height / m, -1), 1)
        )
    }

    /// A fresh spot for the "Add Spot" button: the first at the middle of the frame, later ones spiralled outward by
    /// the golden angle so NO two of the (at most 50) spots ever start on the same point, or `nil` at the cap.
    static func newSpot(existingCount: Int) -> RetouchSpot? {
        guard existingCount < EditState.maxRetouchSpots else { return nil }
        var spot = RetouchSpot()
        let angle = Double(existingCount) * 2.399963229728653 // golden angle
        let distance = min(0.05 * Double(existingCount).squareRoot(), 0.4)
        spot.x = 0.5 + distance * cos(angle)
        spot.y = 0.5 + distance * sin(angle)
        return spot
    }
}
