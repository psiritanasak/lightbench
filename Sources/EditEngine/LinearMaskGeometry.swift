import CoreGraphics

/// Pure, `CoreGraphics`-only geometry for the LINEAR (graduated) mask kind
/// — the two-`CGPoint` math `EditPipeline.applyMasks`'s `.linear` branch
/// feeds directly to `CIFilter.linearGradient()`. Structural sibling of
/// `RadialMaskGeometry` (same file, same doc voice, same
/// nil-on-degenerate-input discipline) — see `resolve`'s own comment for
/// the y-flip/rotation derivation this file uses (a per-point flip,
/// re-derived and confirmed EQUIVALENT to `RadialMaskGeometry`'s own
/// negate-the-angle approach, not a workaround for some hazard in that
/// approach — an earlier draft of this comment incorrectly claimed the
/// two were NOT equivalent; reviewer-corrected).
///
/// MEASURED (not assumed), via a throwaway probe before this file was
/// written: `CIFilter.linearGradient()`'s `outputImage.extent` is
/// `CGRect.infinite` (a linear gradient is constant along the
/// perpendicular direction, unlike a radial gradient's bounded disc), and
/// it CLAMPS to `color0`/`color1` beyond each point — sampled far beyond
/// `point0` returned fully-opaque `color0`, far beyond `point1` returned
/// fully-transparent `color1`, and the midpoint returned ~0.5 alpha. This
/// clamping behavior is load-bearing: it means `EditPipeline.applyMasks`
/// needs no `base`/`CIMaximumCompositing` union for the linear branch
/// (unlike radial, which needs one precisely because a radial gradient is
/// UNDEFINED outside its own bounding disc) — the ramp already has a
/// defined value everywhere.
enum LinearMaskGeometry {
    /// Minimum FULL guide-to-guide width, as a fraction of
    /// `min(extent.width, extent.height)` — mirrors
    /// `RadialMaskGeometry.minimumFeather`'s role, but CLAMPS rather than
    /// causing `resolve` to return `nil`: a zero-width linear mask is a
    /// legitimate hard-edged half-plane covering roughly half the frame
    /// (a real, deliberate look), not "no mask" the way a sub-half-pixel
    /// radial radius is. Also the guard against `point0 == point1`, which
    /// `CILinearGradient` is undefined for.
    static let minimumWidth: Double = 0.01

    struct Resolved: Equatable {
        /// The fully-opaque end (`color0` in `EditPipeline.applyMasks`'s
        /// `CIFilter.linearGradient()` call) — the "full effect" side.
        let point0: CGPoint
        /// The fully-transparent end (`color1`) — the "no effect" side.
        let point1: CGPoint
        /// A conservative axis-aligned bounding rect of the region where
        /// the mask is non-zero, intersected with `extent` — the linear
        /// analogue of `RadialMaskGeometry`'s ROI-cropping optimization in
        /// `applyMasks` (crop `corrected` to this rect, not the whole
        /// extent, before the blend). Because the mask CLAMPS to fully
        /// transparent beyond `point1` (see the file header), the
        /// non-zero region is the closed half-plane on `point0`'s side of
        /// the line through `point1` perpendicular to the gradient
        /// direction — an unbounded half-plane in general, so this is
        /// `extent` clipped by that half-plane, never a hand-rolled
        /// axis-aligned band (which would incorrectly clip the far
        /// corner on the opaque side at a non-axis-aligned angle).
        let regionOfInterest: CGRect
    }

    /// - Parameters:
    ///   - centerX/centerY: fraction of `extent`, SwiftUI top-left-origin,
    ///     y-DOWN — same convention as `Mask.centerX/centerY`.
    ///   - rotationDegrees: the mask's local +X axis direction,
    ///     CLOCKWISE-positive on screen (same field/convention
    ///     `RadialMaskGeometry` uses for the ellipse) — for a linear mask
    ///     this is the LINE's own orientation (0 = horizontal line,
    ///     dividing top/bottom); the falloff runs along local +Y.
    ///   - width: the FULL guide-to-guide distance, a fraction of
    ///     `min(extent.width, extent.height)` (rotation-invariant on-screen
    ///     thickness, matching Definition/Sharpen's own radius-scaling
    ///     precedent) — NOT a half-width.
    static func resolve(
        centerX: Double, centerY: Double, rotationDegrees: Double, width: Double,
        extent: CGRect
    ) -> Resolved? {
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0 else { return nil }
        guard centerX.isFinite, centerY.isFinite, rotationDegrees.isFinite, width.isFinite else { return nil }

        // Reviewer-caught: a `width` too small to matter must CLAMP the
        // pixel half-width, not `return nil` — an earlier draft's guard
        // read `guard halfWidthPixels >= 0.5 else { return nil }`, which
        // silently dropped the WHOLE mask on any extent whose smaller
        // dimension is under ~100px (e.g. a Library thumbnail, capped at
        // 240px) even at `width == minimumWidth`, contradicting this
        // type's own documented contract that a too-small width clamps
        // (a legitimate hard edge), unlike a too-small radial radius
        // (which genuinely covers nothing and should skip). The floor now
        // lives INSIDE `widthInPixels` itself (not applied a second time
        // here) so that function stays the single source of truth its
        // own doc comment claims — a future Session B guide computed
        // from `widthInPixels` directly can never disagree with what
        // actually renders here.
        let halfWidthPixels = widthInPixels(width: width, extent: extent) / 2

        // Re-derived from scratch (reviewer-verified): at rotationDegrees
        // (theta) == 0, the full-effect side (`point0`) is UP on screen —
        // i.e. the direction (0, -1) in this struct's y-DOWN UI
        // convention. Rotating that direction by theta with the SAME
        // CW-positive rotation matrix `RadialMaskGeometry` uses
        // (`[cosθ, -sinθ; sinθ, cosθ]`) gives (sinθ, -cosθ) in UI space.
        // Flipping EACH POINT (not a direction) through the identical
        // `1 - y` formula the center mapping below already uses is
        // mathematically EQUIVALENT to `RadialMaskGeometry.resolve`'s own
        // "negate the whole angle, then apply the same rotation formula
        // in y-up space" approach for this same vector — both give
        // (sinθ, cosθ) as point0's offset from center, confirmed by
        // direct derivation, not merely asserted. The per-point form is
        // used here only because it mirrors the center's own existing
        // y-flip line-for-line, keeping ONE flip idiom in this file
        // rather than mixing it with an angle-negation idiom for the
        // same quantity.
        let radians = rotationDegrees * .pi / 180
        let sinTheta = CGFloat(sin(radians))
        let cosTheta = CGFloat(cos(radians))

        let cx = extent.minX + CGFloat(centerX) * extent.width
        let cy = extent.minY + CGFloat(1 - centerY) * extent.height

        let point0 = CGPoint(x: cx + sinTheta * halfWidthPixels, y: cy + cosTheta * halfWidthPixels)
        let point1 = CGPoint(x: cx - sinTheta * halfWidthPixels, y: cy - cosTheta * halfWidthPixels)

        return Resolved(
            point0: point0,
            point1: point1,
            regionOfInterest: clippedRegionOfInterest(extent: extent, point0: point0, point1: point1)
        )
    }

    /// Full guide-to-guide width in PIXELS for one extent — the single
    /// source of truth shared by `resolve` and (Session B) the overlay's
    /// guide placement, so the drawn guides can never drift from the
    /// rendered falloff. Clamps to `minimumWidth`; NaN-only fallback,
    /// mirroring `RadialMaskGeometry.innerRadiusFraction`'s own
    /// narrowing — `resolve` above already guards `width.isFinite`
    /// before ever reaching this function, so the NaN branch here only
    /// matters for a future standalone caller (the mask overlay) that
    /// calls this directly, same as `innerRadiusFraction`'s own
    /// documented reasoning. Also floors the result to 1 PIXEL (a 0.5px
    /// half-width) regardless of how small `extent` is — reviewer-caught:
    /// this floor used to live a second time, redundantly, in `resolve`
    /// itself, which both duplicated it AND left THIS function (the one
    /// documented as the single source of truth) reporting a smaller,
    /// un-floored width than what actually renders on a small extent.
    static func widthInPixels(width: Double, extent: CGRect) -> CGFloat {
        let clamped = width.isNaN ? minimumWidth : max(width, minimumWidth)
        return max(CGFloat(clamped) * min(extent.width, extent.height), 1)
    }

    /// Bounding rect of `extent` clipped to the closed half-plane
    /// `{ P : dot(P - point1, point1 - point0) <= 0 }` — the side
    /// containing `point0` (and everywhere beyond it), where the mask is
    /// non-zero. A single-edge Sutherland-Hodgman clip of the extent's 4
    /// corners against that one boundary line, collecting kept corners
    /// plus any edge/boundary intersections, then bounding-boxing the
    /// result.
    ///
    /// Reviewer-caught (2 fixes): a degenerate `point0`/`point1` pair (an
    /// adversarial hand-authored sidecar could still drive `centerX`/
    /// `width` to produce non-finite intersection math even though
    /// `resolve`'s own top-level guards reject non-finite INPUTS) is
    /// guarded here directly, independent of those input guards, rather
    /// than trusting every possible future caller to have already
    /// validated `point0`/`point1`. And an empty clip (the whole extent
    /// lies beyond `point1` — the mask has literally zero effect within
    /// the frame) now returns a zero-size rect instead of the full
    /// `extent`: the ORIGINAL fallback was safe (`corrected` cropped to
    /// `extent` still blends to a no-op, since `maskImage` is all-zero
    /// there) but wasted exactly the per-frame cost this ROI exists to
    /// avoid, in precisely the case where the mask does nothing at all.
    private static func clippedRegionOfInterest(extent: CGRect, point0: CGPoint, point1: CGPoint) -> CGRect {
        let dx = point1.x - point0.x
        let dy = point1.y - point0.y
        func side(_ p: CGPoint) -> CGFloat {
            (p.x - point1.x) * dx + (p.y - point1.y) * dy
        }

        let corners = [
            CGPoint(x: extent.minX, y: extent.minY),
            CGPoint(x: extent.maxX, y: extent.minY),
            CGPoint(x: extent.maxX, y: extent.maxY),
            CGPoint(x: extent.minX, y: extent.maxY)
        ]

        let zeroRect = CGRect(x: extent.minX, y: extent.minY, width: 0, height: 0)

        var points: [CGPoint] = []
        for index in corners.indices {
            let current = corners[index]
            let next = corners[(index + 1) % corners.count]
            let sideCurrent = side(current)
            let sideNext = side(next)
            if sideCurrent <= 0 { points.append(current) }
            if (sideCurrent <= 0) != (sideNext <= 0) {
                let t = sideCurrent / (sideCurrent - sideNext)
                guard t.isFinite else { return extent }
                points.append(CGPoint(
                    x: current.x + t * (next.x - current.x),
                    y: current.y + t * (next.y - current.y)
                ))
            }
        }

        guard !points.isEmpty else { return zeroRect }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return extent }

        var minX = points[0].x, maxX = points[0].x
        var minY = points[0].y, maxY = points[0].y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(extent)
    }
}
