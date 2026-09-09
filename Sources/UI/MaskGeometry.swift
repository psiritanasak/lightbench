import CoreGraphics

/// Pure, SwiftUI-independent geometry for `MaskOverlayView`'s resize/move
/// handles — mirrors `CropAspectMath`'s precedent (real arithmetic factored
/// out for direct unit test coverage) and is the UI-side SIBLING of
/// `Sources/EditEngine/RadialMaskGeometry.swift`, which explicitly reserves
/// this split in its own doc comment: that file owns the FORWARD render
/// transform (mask fractions → the actual `CIImage` mask), this one owns the
/// INVERSE/drag math (screen drag → new mask fractions) the render side
/// never needs. All inputs/outputs are FRACTIONS of `fitRect`
/// (`centerX`/`radiusX` of `fitRect.width`, `centerY`/`radiusY` of
/// `fitRect.height` — the SAME `Mask` convention, so no denominator
/// conversion happens here beyond what each function's own math requires).
enum MaskGeometry {
    /// Matches the Radius X/Y slider's own lower/upper bounds in
    /// `MaskDetailView` — keep the two in sync, or a drag could produce a
    /// value the slider then silently clamps away.
    static let minRadius: Double = 0.02
    static let maxRadius: Double = 1.0

    enum Handle {
        case plusX, minusX, plusY, minusY, center
    }

    /// Unit vectors of the ellipse's own local X/Y axes, in SwiftUI POINT
    /// space (y-DOWN), for `rotationDegrees` CLOCKWISE-positive AS SEEN ON
    /// SCREEN — the same sign convention `Mask.rotationDegrees`'s own doc
    /// comment declares, and the SAME NUMERIC FORMULA as a textbook
    /// counterclockwise rotation matrix: in a y-DOWN space, the standard
    /// `(cosθ, sinθ)` rotation of `(1, 0)` visually rotates CLOCKWISE as a
    /// viewer sees it (the y-flip between "math CCW" and "screen CW" is
    /// exactly why `RadialMaskGeometry.resolve` has to NEGATE this same
    /// stored value before it reaches `CIImage`'s y-UP space — this
    /// function deliberately does NOT negate, since it stays in y-DOWN
    /// screen space throughout). Verified, not just derived: hand-checked
    /// at 90° below (`MaskGeometryTests`) — local +X rotates to point
    /// straight down on screen, matching "East rotated 90° clockwise is
    /// South."
    static func axes(rotationDegrees: Double) -> (x: CGVector, y: CGVector) {
        let radians = rotationDegrees * .pi / 180
        let xAxis = CGVector(dx: cos(radians), dy: sin(radians))
        let yAxis = CGVector(dx: -sin(radians), dy: cos(radians))
        return (xAxis, yAxis)
    }

    /// On-screen point of one handle, given the mask's current (fraction)
    /// geometry and the `fitRect` it's drawn against. `.center` is the
    /// ellipse's own center point (used for the interior move region, not
    /// a resize handle).
    static func handlePoint(
        _ handle: Handle, centerX: Double, centerY: Double,
        radiusX: Double, radiusY: Double, rotationDegrees: Double, fitRect: CGRect
    ) -> CGPoint {
        let center = CGPoint(
            x: fitRect.minX + centerX * fitRect.width,
            y: fitRect.minY + centerY * fitRect.height
        )
        guard handle != .center else { return center }

        let rxPoints = radiusX * fitRect.width
        let ryPoints = radiusY * fitRect.height
        let (xAxis, yAxis) = axes(rotationDegrees: rotationDegrees)

        switch handle {
        case .plusX:
            return CGPoint(x: center.x + xAxis.dx * rxPoints, y: center.y + xAxis.dy * rxPoints)
        case .minusX:
            return CGPoint(x: center.x - xAxis.dx * rxPoints, y: center.y - xAxis.dy * rxPoints)
        case .plusY:
            return CGPoint(x: center.x + yAxis.dx * ryPoints, y: center.y + yAxis.dy * ryPoints)
        case .minusY:
            return CGPoint(x: center.x - yAxis.dx * ryPoints, y: center.y - yAxis.dy * ryPoints)
        case .center:
            return center // unreachable, guarded above
        }
    }

    /// New radii from a handle drag: project the drag's POINT-space
    /// translation onto the handle's own (rotated) axis, add to the
    /// baseline radius (converted to points, so the projection and the
    /// baseline are in the same unit before dividing back to a fraction),
    /// clamp to `minRadius...maxRadius`. Each handle drags its OWN single
    /// radius, symmetric about a STATIONARY center — deliberately not
    /// Crop's opposite-corner anchoring, since the data model here is one
    /// center + two independent radii, not four independent edges.
    static func resized(
        _ handle: Handle, startRadiusX: Double, startRadiusY: Double,
        translation: CGSize, rotationDegrees: Double, fitRect: CGRect
    ) -> (radiusX: Double, radiusY: Double) {
        guard fitRect.width > 0, fitRect.height > 0 else { return (startRadiusX, startRadiusY) }
        let (xAxis, yAxis) = axes(rotationDegrees: rotationDegrees)

        func clamp(_ value: Double) -> Double {
            min(max(value, minRadius), maxRadius)
        }

        switch handle {
        case .plusX, .minusX:
            // Dragging the +X handle further along +xAxis grows the
            // radius; dragging -X further along -xAxis (i.e. away from
            // center on ITS side) also grows — hence the sign flip below,
            // not a different formula.
            let projected = translation.width * xAxis.dx + translation.height * xAxis.dy
            let sign: Double = (handle == .plusX) ? 1 : -1
            let deltaFraction = (sign * projected) / fitRect.width
            return (clamp(startRadiusX + deltaFraction), startRadiusY)
        case .plusY, .minusY:
            let projected = translation.width * yAxis.dx + translation.height * yAxis.dy
            let sign: Double = (handle == .plusY) ? 1 : -1
            let deltaFraction = (sign * projected) / fitRect.height
            return (startRadiusX, clamp(startRadiusY + deltaFraction))
        case .center:
            return (startRadiusX, startRadiusY) // unreachable — center never resizes
        }
    }

    /// New center from an interior drag, clamped to 0...1 on both axes so
    /// the mask can never be dragged fully off-image and become
    /// unreachable. Deliberately does NOT clamp the radii to keep the
    /// ellipse inside the frame — the opposite of Crop's own interior-drag
    /// double-bounding: a crop rect leaving the frame is meaningless, a
    /// mask extending past the edge is a normal, desirable thing.
    static func movedCenter(
        startX: Double, startY: Double, translation: CGSize, fitRect: CGRect
    ) -> (x: Double, y: Double) {
        guard fitRect.width > 0, fitRect.height > 0 else { return (startX, startY) }
        let newX = startX + translation.width / fitRect.width
        let newY = startY + translation.height / fitRect.height
        return (min(max(newX, 0), 1), min(max(newY, 0), 1))
    }
}
