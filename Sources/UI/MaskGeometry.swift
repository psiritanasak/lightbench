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

    // MARK: - Linear (graduated) mask — Phase 7 slice 3 Session B

    /// Matches `MaskDetailView`'s Width row bounds exactly — `0` is a
    /// legitimate hard edge for a Linear mask (unlike `minRadius` above,
    /// where a too-small radial radius covers nothing), so this is a
    /// SEPARATE constant pair, not a reuse of `minRadius`/`maxRadius`.
    static let minWidth: Double = 0
    static let maxWidth: Double = 1.0

    /// `.fullEffect`/`.noEffect` name the two draggable parallel guides by
    /// what the render actually does there (`LinearMaskGeometry.Resolved`'s
    /// own `point0`/`point1` doc comments), not by screen position (which
    /// side is "up" depends on `rotationDegrees`). `.center` is the
    /// draggable center line, not a resize handle.
    enum LinearHandle {
        case fullEffect, noEffect, center
    }

    /// On-screen point for one Linear-mask handle. Re-derived from
    /// `LinearMaskGeometry.resolve`'s own render-side formula (see that
    /// type's doc comment) by converting its `point0`/`point1` back
    /// through the SAME y-flip the center mapping already uses: the
    /// result is `center ∓ axes(rotationDegrees).y · halfWidthPoints` —
    /// the identical rotated-axis math `handlePoint` above already uses
    /// for the ellipse, just offset along `yAxis` only (a Linear mask has
    /// no independent X-axis radius). `halfWidthPoints` is computed by
    /// calling `LinearMaskGeometry.widthInPixels(width:extent:)` DIRECTLY
    /// with `fitRect` standing in for `extent` — that function is a pure
    /// fraction-of-`min(width,height)` scaling, dimensionally identical
    /// whether the rect passed in is the render extent (pixels) or the
    /// UI `fitRect` (points, proportionally identical under `AspectFit`)
    /// — so the drawn guide can never drift from the render's
    /// `minimumWidth` clamp, exactly as that function's own doc comment
    /// reserves for this call site. Reviewer-noted: this equivalence is
    /// exact for the `minimumWidth` clamp (a FRACTION, unaffected by
    /// which coordinate space calls it) but only approximate for
    /// `widthInPixels`'s separate 1-PIXEL floor, which is 1 render pixel
    /// here vs. 1 UI point there — two different absolute units that
    /// only coincide at 1:1 zoom. Unreachable in practice for this app's
    /// own images (`minimumWidth` already dominates unless
    /// `min(fitRect.width, fitRect.height) < 100`), so left as an
    /// accepted, documented imprecision rather than a fix.
    static func linearGuidePoint(
        _ handle: LinearHandle, centerX: Double, centerY: Double,
        rotationDegrees: Double, width: Double, fitRect: CGRect
    ) -> CGPoint {
        let center = CGPoint(
            x: fitRect.minX + centerX * fitRect.width,
            y: fitRect.minY + centerY * fitRect.height
        )
        guard handle != .center else { return center }

        let halfWidthPoints = LinearMaskGeometry.widthInPixels(width: width, extent: fitRect) / 2
        let (_, yAxis) = axes(rotationDegrees: rotationDegrees)

        switch handle {
        case .fullEffect:
            return CGPoint(x: center.x - yAxis.dx * halfWidthPoints, y: center.y - yAxis.dy * halfWidthPoints)
        case .noEffect:
            return CGPoint(x: center.x + yAxis.dx * halfWidthPoints, y: center.y + yAxis.dy * halfWidthPoints)
        case .center:
            return center // unreachable, guarded above
        }
    }

    /// New `width` from a guide-handle drag: project the drag's
    /// POINT-space translation onto the ROTATED perpendicular axis
    /// (`axes(rotationDegrees).y` — the same axis `linearGuidePoint`
    /// offsets along), divide by `min(fitRect.width, fitRect.height)` —
    /// `width`'s own denominator (see `Mask.width`'s doc comment), NOT
    /// per-axis like `resized`'s radii above — then DOUBLE the result:
    /// `width` is the FULL guide-to-guide distance, while each handle
    /// sits only HALF that from a stationary center, so moving one guide
    /// out by `d` points grows `width` by `2d / min(w,h)`. `.fullEffect`
    /// and `.noEffect` grow `width` for opposite-signed projections
    /// (the same sign-flip shape `resized`'s own `.plusX`/`.minusX` use),
    /// since both handles are symmetric about the SAME stationary center
    /// but write the one shared field rather than two independent radii.
    /// Clamps to `minWidth...maxWidth` — deliberately not `minRadius`,
    /// since `width == 0` is a legitimate hard edge here, unlike a
    /// too-small radial radius. Reviewer-noted: this clamp floor (a true
    /// `0`) is slightly BELOW `LinearMaskGeometry.minimumWidth` (`0.01`),
    /// the floor `linearGuidePoint`'s own `widthInPixels` call effectively
    /// applies — so across `width ∈ [0, 0.01)` the stored value keeps
    /// changing while the drawn handle stops moving, a dead zone at the
    /// very bottom of an inward drag. Round-3-corrected magnitude (an
    /// earlier draft of this comment guessed "~1-2pt" without deriving
    /// it): the handle sits at `halfWidthPoints = minimumWidth ·
    /// min(fitRect.width, fitRect.height) / 2` for the whole stuck range,
    /// so the dead zone SCALES with the pane — roughly 1.0pt at a 200pt
    /// minimum dimension, 3.0pt at 600pt, 6.0pt at 1200pt, not a fixed
    /// small constant. Still consistent between the overlay and the
    /// render (both bottom out at the same visual width, scaling
    /// together), so this remains cosmetic, not a correctness bug — the
    /// one place in this gesture where the handle does not track the
    /// cursor exactly 1:1 — just a larger cosmetic range than first
    /// claimed on a large editor pane.
    static func resizedWidth(
        _ handle: LinearHandle, startWidth: Double,
        translation: CGSize, rotationDegrees: Double, fitRect: CGRect
    ) -> Double {
        guard fitRect.width > 0, fitRect.height > 0, handle != .center else { return startWidth }
        let (_, yAxis) = axes(rotationDegrees: rotationDegrees)

        let projected = translation.width * yAxis.dx + translation.height * yAxis.dy
        let sign: Double = (handle == .noEffect) ? 1 : -1
        let minDimension = min(fitRect.width, fitRect.height)
        let deltaFraction = (2 * sign * projected) / minDimension
        return min(max(startWidth + deltaFraction, minWidth), maxWidth)
    }

    /// Length (in points) for `LinearMaskOverlayView`'s three drawn lines
    /// (center + two guides) — long enough to visibly span `fitRect` at
    /// ANY rotation, ANY on-screen position (including a center dragged to
    /// an edge — `movedCenter` clamps `centerX`/`centerY` to `0...1`
    /// precisely to allow that), for both the center line itself and a
    /// guide line offset up to `halfWidthPoints` away from it. Extracted
    /// here (round-3 reviewer suggestion) so the exact constant that
    /// failed live/rendered review TWICE (`* 1.5`, too short; `* 3.0`,
    /// correct) has an automated regression test, not just a doc-comment
    /// derivation nobody re-checks on the next edit.
    ///
    /// Proof of sufficiency: a line anchored at a point already inside
    /// `fitRect` can need a half-length up to the full diagonal `D =
    /// hypot(fitRect.width, fitRect.height)` (anchored at one corner,
    /// running along the diagonal toward the opposite one), plus up to
    /// `halfWidthPoints_max = 0.5 · min(fitRect.width, fitRect.height)`
    /// more for a guide line offset from the center line. So the required
    /// half-length is `D + 0.5·min(w,h)`, and `1.5·D ≥ D + 0.5·min(w,h)`
    /// holds for every rect since `D ≥ min(w,h)` always — so `1.5·D` is
    /// itself a SUFFICIENT half-length, and this function's `3·D` (twice
    /// that sufficient half-length, i.e. a full length covering both
    /// directions from the anchor) covers every case with margin to
    /// spare. Verified live by re-rendering the exact configurations that
    /// failed at `1.5·D` as a FULL length (i.e. a `0.75·D` half-length —
    /// not sufficient).
    static func guideLineLength(fitRect: CGRect) -> CGFloat {
        hypot(fitRect.width, fitRect.height) * 3.0
    }

    // MARK: - Brush mask — Phase 7 slice 4

    /// Minimum on-screen distance (in points) between two consecutive
    /// appended `brushPoints` — a decimation threshold, NOT a visual
    /// smoothing one: every `DragGesture.onChanged` firing that passes it
    /// is a full `editState` write (and, via the undo-coalescing debounce,
    /// contributes to that debounce window), so this bounds how fast
    /// `brushPoints` can grow on a slow drag without being visually
    /// detectable at any normal drag speed (SwiftUI's own drag callback
    /// rate is already far coarser than 3pt of travel at a normal pace).
    static let minimumBrushPointSpacing: CGFloat = 3

    /// Pane-space screen point -> clamped 0...1 fraction of `fitRect`. Same
    /// clamp-at-edge reasoning as `movedCenter`: a stroke can be dragged
    /// with its cursor past the image edge (common near a border), and the
    /// stored point must still resolve to a valid, on-image fraction.
    static func normalizedBrushPoint(_ location: CGPoint, fitRect: CGRect) -> BrushPoint {
        guard fitRect.width > 0, fitRect.height > 0 else { return BrushPoint(x: 0.5, y: 0.5) }
        let x = (location.x - fitRect.minX) / fitRect.width
        let y = (location.y - fitRect.minY) / fitRect.height
        return BrushPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// Exact inverse of `normalizedBrushPoint` — used by the live in-progress
    /// stroke path to draw already-appended points back in pane space.
    static func brushScreenPoint(_ point: BrushPoint, fitRect: CGRect) -> CGPoint {
        CGPoint(x: fitRect.minX + point.x * fitRect.width, y: fitRect.minY + point.y * fitRect.height)
    }

    /// Whether a new drag location is far enough from the last APPENDED
    /// point (not the last raw callback location) to be worth appending —
    /// the decimation `BrushMaskOverlayView.onChanged` applies to every
    /// callback after the stroke's first point.
    static func shouldAppendBrushPoint(
        _ location: CGPoint, after last: CGPoint, minimumSpacing: CGFloat = minimumBrushPointSpacing
    ) -> Bool {
        hypot(location.x - last.x, location.y - last.y) >= minimumSpacing
    }
}
