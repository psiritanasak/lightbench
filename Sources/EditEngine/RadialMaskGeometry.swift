import CoreGraphics

/// Pure, SwiftUI/CoreImage-independent geometry for a rotated-ellipse radial
/// mask — mirrors `CropAspectMath`'s precedent (real arithmetic factored out
/// for direct unit test coverage) but lives in `EditEngine`, not `Sources/UI`,
/// because `EditPipeline.applyMasks` consumes it directly, not just a UI
/// overlay (`EditEngine` must stay UI-free, per CLAUDE.md's architecture
/// principles).
///
/// `CIRadialGradient` only produces CIRCLES. To get a rotated ELLIPSE at an
/// arbitrary center: generate a circular gradient at the origin, sized to the
/// LARGER of the two requested pixel radii, then scale the SMALLER axis down
/// to match — never magnify, since magnifying a procedural generator by
/// 100-1000x would depend on unverified resampling behavior — then rotate,
/// then translate into place. `resolve` computes exactly that transform; the
/// caller (`EditPipeline.applyMasks`) builds the actual `CIRadialGradient`
/// and applies `.transformed(by:)`.
enum RadialMaskGeometry {
    /// Minimum feather, as a fraction of the outer radius. A literally hard
    /// edge (radius0 == radius1) would alias visibly once the ellipse is
    /// rotated and resampled — defense-in-depth, same role as this codebase's
    /// other tuned minimum-gap constants (e.g. `EditPipeline.kMaxCropInset`).
    /// NEEDS A LIVE LOOK (see PROGRESS.md's Phase 7 slice 2 write-up) — not
    /// yet confirmed against a real rendered edge, only chosen to be small.
    static let minimumFeather: Double = 0.02

    /// Resolved, ready-to-use geometry for one mask against one extent.
    struct Resolved: Equatable {
        /// Pixel radius the base circular gradient should be generated at —
        /// the LARGER of the two requested pixel radii, so the transform's
        /// scale is always a downscale on the other axis, never a
        /// magnification.
        let gradientRadius: CGFloat
        /// `radius0` for the base circular gradient: the fully-opaque core,
        /// before feather falloff begins. `radius1` is `gradientRadius`.
        let innerRadius: CGFloat
        /// Composed scale → rotate → translate transform mapping the base
        /// circular gradient (centered at the origin) onto the actual
        /// ellipse, in the CURRENT extent's own (`CIImage`, y-UP) coordinate
        /// space.
        let transform: CGAffineTransform
    }

    /// `centerX`/`centerY`/`radiusX`/`radiusY` are fractions of `extent`
    /// (`radiusX` of `extent.width`, `radiusY` of `extent.height`, each
    /// axis of its own dimension — matching `ProxyScale`'s own documented
    /// constraint that every extent-dependent stage express geometry as a
    /// fraction of the CURRENT extent, so both stay proportionally correct
    /// under a P2 proxy downscale same as a single shared denominator
    /// would). The reason these are two independent fields rather than one
    /// shared radius is the ELLIPSE aspect this buys (radiusX == radiusY
    /// draws an ellipse matching the extent's own aspect ratio, not a
    /// circle — see `Mask.radiusX`'s own doc comment), not proxy-scale
    /// correctness. `centerX`/
    /// `centerY` use the SAME SwiftUI top-left/y-DOWN convention as
    /// `RedEyePoint`; this function performs the y-flip into `CIImage`'s
    /// bottom-left/y-UP space internally, mirroring `EditPipeline
    /// .applyRedEye`'s existing `1 - point.y` flip. `rotationDegrees` is
    /// CLOCKWISE-positive in that same y-DOWN UI space;
    /// `CGAffineTransform(rotationAngle:)` is CCW-positive in `CIImage`'s
    /// y-UP space (verified, not derived — see `EditPipeline
    /// .applyStraighten`'s own doc comment), so this function negates it
    /// internally. Callers should never pre-negate.
    ///
    /// Returns `nil` on any degenerate input (non-finite value, an infinite/
    /// null/non-positive extent, a zero/negative radius, or a radius under
    /// half a pixel — too small to cover any pixel) — callers should treat
    /// `nil` as "skip this mask entirely," rendering byte-identical to no
    /// mask at all.
    static func resolve(
        centerX: Double, centerY: Double,
        radiusX: Double, radiusY: Double,
        rotationDegrees: Double, feather: Double,
        extent: CGRect
    ) -> Resolved? {
        // `CGRect.infinite`'s width/height are `CGFloat.greatestFiniteMagnitude`
        // — finite by IEEE semantics — so `.isFinite` alone would NOT catch
        // it; `.isInfinite`/`.isNull` are the correct checks, the same trap
        // `ProxyBuilder.build`/`RawDecoder.materialize` already recorded.
        guard !extent.isInfinite, !extent.isNull,
              extent.width > 0, extent.height > 0,
              centerX.isFinite, centerY.isFinite,
              radiusX.isFinite, radiusY.isFinite,
              rotationDegrees.isFinite, feather.isFinite
        else { return nil }

        let rx = CGFloat(max(radiusX, 0)) * extent.width
        let ry = CGFloat(max(radiusY, 0)) * extent.height
        let gradientRadius = max(rx, ry)
        // rx/ry < 0.5px covers no pixel — also the NaN source: without this
        // guard, gradientRadius could be 0 and rx/gradientRadius would
        // divide by zero. (`gradientRadius > 0` is implied by `rx >= 0.5`
        // and not spelled out separately.)
        guard rx >= 0.5, ry >= 0.5 else { return nil }

        let innerRadius = gradientRadius * CGFloat(innerRadiusFraction(feather: feather))

        // CIImage is bottom-left/y-UP; stored centerY is SwiftUI top-left/
        // y-DOWN. Same flip `applyRedEye` already uses.
        let cx = extent.minX + CGFloat(centerX) * extent.width
        let cy = extent.minY + CGFloat(1 - centerY) * extent.height

        // Stored rotation is CLOCKWISE-positive in y-down UI space;
        // CGAffineTransform(rotationAngle:) is CCW-positive in CIImage's
        // y-up space (applyStraighten's doc comment) — negate to translate
        // between the two conventions.
        let radians = -rotationDegrees * .pi / 180

        // scale -> rotate -> translate. A circle has no orientation, so
        // scaling before rotating is what makes the rotation meaningful;
        // rotate before translate so the rotation happens about the
        // gradient's own origin-centered axes, not the final on-screen
        // center.
        let transform = CGAffineTransform(scaleX: rx / gradientRadius, y: ry / gradientRadius)
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))

        return Resolved(gradientRadius: gradientRadius, innerRadius: innerRadius, transform: transform)
    }

    /// Fully-opaque inner radius as a FRACTION of the outer radius — the
    /// SINGLE SOURCE OF TRUTH shared by `resolve` above (which needs it in
    /// pixels) and Phase 7 slice 2's future mask overlay (which will draw a
    /// feather guide from this same fraction), so the on-screen guide can
    /// never drift from where the render is actually solid.
    static func innerRadiusFraction(feather: Double) -> Double {
        // Only NaN needs a special-cased fallback: `min`/`max` silently
        // propagate NaN through the expression below, but they clamp
        // `+.infinity`/`-.infinity` correctly on their own (to 1 and
        // `minimumFeather` respectively) — a `.isFinite` guard here would
        // have redirected `+.infinity` to the fallback's hardest-edge
        // value instead of the clamp's own correct fully-soft result, an
        // overcorrection this file's own review caught. `resolve` above
        // already rejects non-finite feather outright, so this only
        // matters for a future standalone caller (the overlay's feather
        // guide) that doesn't go through `resolve` first.
        guard !feather.isNaN else { return 1 - minimumFeather }
        return 1 - min(max(feather, minimumFeather), 1)
    }
}
