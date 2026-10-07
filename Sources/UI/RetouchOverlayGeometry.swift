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

    /// The circle's radius in points. Clamped to `RetouchSpot.radiusRange` like the renderer's `clamped` (a hand-edited sidecar can
    /// hold any number), so what is drawn, hit-tested and handled is what the pipeline actually repairs.
    static func radiusPoints(of spot: RetouchSpot, in fitRect: CGRect) -> CGFloat {
        let r = min(max(spot.radius, RetouchSpot.radiusRange.lowerBound), RetouchSpot.radiusRange.upperBound)
        return r * minSide(fitRect)
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

    // MARK: - Placing and picking spots on the image (Place Spots tool)

    /// The default radius for a spot placed by a plain click (a drag shorter than `minimumSizingDrag`): `RetouchSpot`'s own default.
    static let defaultNewRadius = RetouchSpot().radius

    /// A mouse drag shorter than this many points is a CLICK: the new spot takes the remembered radius instead of one measured
    /// from a few pixels of hand jitter.
    static let minimumSizingDrag: CGFloat = 4

    /// How far outside a circle's edge a click still selects it, so a tiny spot (a 0.002 radius is ~1-2 px on screen) can be hit.
    static let hitSlop: CGFloat = 6

    /// The inverse of `centerPoint`: a view point -> a normalized spot position (x right, y UP) in the unedited frame, clamped to
    /// the frame. nil for a degenerate `fitRect` or a non-finite point (a NaN must never become a spot position).
    static func normalizedPoint(from point: CGPoint, in fitRect: CGRect) -> (x: Double, y: Double)? {
        guard fitRect.width > 0, fitRect.height > 0, fitRect.width.isFinite, fitRect.height.isFinite,
              fitRect.minX.isFinite, fitRect.minY.isFinite, point.x.isFinite, point.y.isFinite else { return nil }
        let x = (point.x - fitRect.minX) / fitRect.width
        let y = 1 - (point.y - fitRect.minY) / fitRect.height
        return (min(max(Double(x), 0), 1), min(max(Double(y), 0), 1))
    }

    /// A radius (fraction of the min side) from the distance between a centre and a drag point, clamped to
    /// `RetouchSpot.radiusRange`. nil for a degenerate frame or non-finite points.
    static func radius(fromCenter center: CGPoint, dragPoint: CGPoint, fitRect: CGRect) -> Double? {
        let m = minSide(fitRect)
        guard m > 0, center.x.isFinite, center.y.isFinite, dragPoint.x.isFinite, dragPoint.y.isFinite else { return nil }
        let distance = hypot(dragPoint.x - center.x, dragPoint.y - center.y)
        let raw = Double(distance / m)
        return min(max(raw, RetouchSpot.radiusRange.lowerBound), RetouchSpot.radiusRange.upperBound)
    }

    /// The radius for a NEW spot after the user pressed at `center` and released at `dragPoint`: a click (shorter than
    /// `minimumSizingDrag`) uses `defaultRadius` (clamped to the legal range, and `defaultNewRadius` if it is not finite); a drag
    /// uses the measured one. nil only for a degenerate frame or non-finite points.
    static func newSpotRadius(fromCenter center: CGPoint, dragPoint: CGPoint, fitRect: CGRect, defaultRadius: Double) -> Double? {
        guard minSide(fitRect) > 0, center.x.isFinite, center.y.isFinite, dragPoint.x.isFinite, dragPoint.y.isFinite else { return nil }
        if hypot(dragPoint.x - center.x, dragPoint.y - center.y) < minimumSizingDrag {
            let fallback = defaultRadius.isFinite ? defaultRadius : defaultNewRadius
            return min(max(fallback, RetouchSpot.radiusRange.lowerBound), RetouchSpot.radiusRange.upperBound)
        }
        return radius(fromCenter: center, dragPoint: dragPoint, fitRect: fitRect)
    }

    /// The spot a click at `point` selects: among the spots whose circle (plus `hitSlop`) contains the point, the one whose CENTRE
    /// is nearest (so a small spot nested inside a big one stays selectable); on an equal distance the SMALLER circle (a small spot
    /// exactly centred on a big one is picked for every click inside it), and on a full tie the one later in the array (drawn on
    /// top). nil if none, or for a non-finite point.
    static func hitTest(point: CGPoint, spots: [RetouchSpot], fitRect: CGRect) -> UUID? {
        guard point.x.isFinite, point.y.isFinite, minSide(fitRect) > 0 else { return nil }
        var best: (id: UUID, distance: CGFloat, radius: CGFloat)?
        for spot in spots where spot.isFinite {
            let c = centerPoint(of: spot, in: fitRect)
            let radius = radiusPoints(of: spot, in: fitRect)
            let distance = hypot(point.x - c.x, point.y - c.y)
            guard distance <= radius + hitSlop else { continue }
            if let current = best, distance > current.distance || (distance == current.distance && radius > current.radius) { continue }
            best = (spot.id, distance, radius)
        }
        return best?.id
    }

    /// Where the selected spot's radius handle sits: on the right edge of its circle.
    static func radiusHandlePoint(of spot: RetouchSpot, in fitRect: CGRect) -> CGPoint {
        let c = centerPoint(of: spot, in: fitRect)
        return CGPoint(x: c.x + radiusPoints(of: spot, in: fitRect), y: c.y)
    }

    /// The radius after dragging the handle to `point` (the spot's own centre is the pivot), clamped to the legal range.
    static func radius(afterHandleDragTo point: CGPoint, spot: RetouchSpot, fitRect: CGRect) -> Double? {
        radius(fromCenter: centerPoint(of: spot, in: fitRect), dragPoint: point, fitRect: fitRect)
    }
}
