import CoreGraphics

/// Pure, `CoreGraphics`-only geometry for the BRUSH (freehand stroke) mask
/// kind — Phase 7 slice 4. Structural sibling of `RadialMaskGeometry`/
/// `LinearMaskGeometry` (same file, same doc voice, same
/// nil-on-degenerate-input discipline), but the shape this file resolves is
/// a raster (a small `CGContext` bitmap `EditPipeline.applyMasks`'s
/// `.brush` branch rasterizes and blurs), not a Core Image gradient — so
/// this file resolves ONLY sizes/rects/points, never touches Core Image or
/// `CGContext` itself, matching `EditEngine`'s own UI/rendering-API-free
/// architecture principle.
enum BrushMaskGeometry {
    /// `brushSize` clamp bounds, as a fraction of `min(extent.width,
    /// extent.height)` — mirrors `LinearMaskGeometry.minimumWidth`'s role:
    /// a too-small brush is a legitimate, deliberate fine-detail tool (F1),
    /// never "no mask," so `radiusInPixels` CLAMPS into this range rather
    /// than `resolve` returning `nil`.
    static let minimumSize: Double = 0.005
    static let maximumSize: Double = 0.5

    /// Absolute pixel floor under `radiusInPixels`'s clamp, regardless of
    /// how small `extent` is (e.g. a Library thumbnail) — the same
    /// "floor lives in the single-source-of-truth sizing function itself"
    /// shape `LinearMaskGeometry.widthInPixels` already established.
    static let minimumRadiusPixels: CGFloat = 0.5

    /// `blurRadiusInPixels` scales the dab radius by this fraction at
    /// `feather == 1` (fully soft) — same 0.5 role `RadialMaskGeometry`
    /// gives its own feather fraction. Reviewer-measured (not just
    /// argued): because a Gaussian blur, unlike `.radial`'s gradient, has
    /// no separate "fully opaque inner radius," the mask never reaches
    /// alpha 1.0 anywhere once `feather > 0` — at `feather == 1` a single
    /// dab's own CENTER measures ~0.865 (exactly `1 - e^-2`, the analytic
    /// result of blurring a disc of radius `2·sigma`), a long stroke's
    /// core measures higher (~0.95) since points farther from either end
    /// are less affected by the blur's falloff. This is a real, accepted
    /// cap on max feather strength, not a bug — a deliberate tradeoff for
    /// a visibly soft edge rather than a exactly-1.0, unsoftened core.
    static let featherRadiusFraction: Double = 0.5

    /// Below this, the blur's visual effect is imperceptible — skip the
    /// `CIGaussianBlur` node entirely rather than pay for a no-op filter.
    /// `feather == 0` (a legitimate hard edge) always lands here.
    static let minimumBlurRadiusPixels: CGFloat = 0.1

    /// How many blur-radius multiples of padding a Gaussian's mass needs
    /// before truncating it is imperceptible — see `padding`'s own doc
    /// comment for the sufficiency proof.
    static let blurPaddingMultiple: CGFloat = 3

    /// Bitmap area ceiling (in pixels) before `resolve` engages a
    /// downscale — bounds the `CGContext` this geometry feeds to a sane
    /// size regardless of how large a stroke's own padded bounding box
    /// gets on a very high-resolution image.
    static let maximumRasterPixels: CGFloat = 4_000_000

    struct Resolved: Equatable {
        /// Every stroke point, in the extent's own pixel space (CIImage's
        /// bottom-left/y-UP convention — already flipped from the stored
        /// SwiftUI top-left/y-DOWN fraction), in original paint order.
        let points: [CGPoint]
        /// The dab radius in pixels — `EditPipeline`'s brush rasterizer
        /// strokes at `lineWidth = radiusPixels * 2` / fills a circle of
        /// this radius for a single-point stroke.
        let radiusPixels: CGFloat
        /// The Gaussian blur radius in pixels to apply to the rasterized
        /// stroke bitmap. `0` means: skip the blur node entirely (a hard
        /// edge), not "blur with radius 0."
        let blurRadiusPixels: CGFloat
        /// The bounding rect (in the extent's own pixel space) the stroke
        /// bitmap should be rasterized at, padded for the stroke radius and
        /// blur tail. Deliberately NOT clipped to the bare `extent` — only
        /// to `extent` GROWN by the same padding — so a stroke near the
        /// image edge still gets its full padding and the blur is computed
        /// as if on an unbounded canvas before the final composite crops to
        /// `extent` (F2's "no `.clampedToExtent()`" reasoning: an
        /// artificially edge-clipped raster would make the blur read as an
        /// incorrect hard cutoff exactly at the image boundary).
        let rasterRect: CGRect
        /// `<= 1`. Engages only when `rasterRect`'s own pixel area would
        /// exceed `maximumRasterPixels` — the `CGContext`/blur should be
        /// built at `rasterRect.size * rasterScale`, then the result
        /// transformed back up by `1 / rasterScale` before cropping to
        /// `rasterRect`.
        let rasterScale: CGFloat
        /// `rasterRect.size * rasterScale`, rounded up to whole pixels —
        /// the exact `CGContext` size to allocate.
        let bitmapSize: CGSize
        /// `rasterRect` intersected with the BARE `extent` — the region
        /// `EditPipeline.applyMasks` should crop `corrected` to before the
        /// blend, mirroring `RadialMaskGeometry`'s/`LinearMaskGeometry`'s
        /// own ROI-cropping optimization. Unlike `rasterRect` itself, this
        /// one genuinely IS clipped to the visible image, since nothing
        /// outside `extent` is ever rendered.
        let regionOfInterest: CGRect
    }

    /// - Parameters:
    ///   - points: the stroke's points, SwiftUI top-left/y-DOWN fraction of
    ///     `extent` — same convention `Mask.centerX`/`RedEyePoint` already
    ///     use — in paint order. Empty means "no stroke painted" and
    ///     resolves to `nil` (the caller should treat that as "skip this
    ///     mask," matching every other degenerate-geometry case in this
    ///     app).
    ///   - brushSize: fraction of `min(extent.width, extent.height)` — see
    ///     `Mask.brushSize`'s own doc comment.
    ///   - feather: `0...1`, same soft-edge meaning as `Mask.feather` for
    ///     `.radial`.
    ///
    /// Returns `nil` when: `extent` is infinite/null/non-positive; `points`
    /// is empty or contains a non-finite coordinate; `brushSize`/`feather`
    /// is non-finite; or the padded stroke bounds don't reach the visible
    /// image at all (the whole stroke is off-frame).
    static func resolve(
        points: [BrushPoint], brushSize: Double, feather: Double, extent: CGRect
    ) -> Resolved? {
        // `CGRect.infinite`'s width/height are `CGFloat.greatestFiniteMagnitude`
        // — finite by IEEE semantics — so `.isFinite` alone would NOT catch
        // it; `.isInfinite`/`.isNull` are the correct checks, the same trap
        // `RadialMaskGeometry`/`LinearMaskGeometry` already document.
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0 else { return nil }
        guard !points.isEmpty, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        guard brushSize.isFinite, feather.isFinite else { return nil }

        // Same `1 - y` flip every other mask kind's geometry already uses:
        // stored points are SwiftUI top-left/y-DOWN, `CIImage` is
        // bottom-left/y-UP.
        let pixelPoints = points.map { point in
            CGPoint(
                x: extent.minX + CGFloat(point.x) * extent.width,
                y: extent.minY + CGFloat(1 - point.y) * extent.height
            )
        }

        let radiusPixels = radiusInPixels(brushSize: brushSize, extent: extent)
        let blurRadiusPixels = blurRadiusInPixels(feather: feather, radiusPixels: radiusPixels)
        let pad = padding(radiusPixels: radiusPixels, blurRadiusPixels: blurRadiusPixels)

        var minX = pixelPoints[0].x, maxX = pixelPoints[0].x
        var minY = pixelPoints[0].y, maxY = pixelPoints[0].y
        for point in pixelPoints.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let strokeBounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let paddedBounds = strokeBounds.insetBy(dx: -pad, dy: -pad)
        // Grown, not bare, `extent` — see `rasterRect`'s own doc comment
        // for why clipping to the bare extent here would be wrong.
        let paddedExtent = extent.insetBy(dx: -pad, dy: -pad)
        let rasterRect = paddedBounds.intersection(paddedExtent).integral

        let regionOfInterest = rasterRect.intersection(extent)
        guard !regionOfInterest.isNull, regionOfInterest.width > 0, regionOfInterest.height > 0 else { return nil }

        let rasterArea = rasterRect.width * rasterRect.height
        let rasterScale: CGFloat = rasterArea > maximumRasterPixels
            ? (maximumRasterPixels / rasterArea).squareRoot()
            : 1
        let bitmapSize = CGSize(
            width: max(1, (rasterRect.width * rasterScale).rounded(.up)),
            height: max(1, (rasterRect.height * rasterScale).rounded(.up))
        )

        return Resolved(
            points: pixelPoints,
            radiusPixels: radiusPixels,
            blurRadiusPixels: blurRadiusPixels,
            rasterRect: rasterRect,
            rasterScale: rasterScale,
            bitmapSize: bitmapSize,
            regionOfInterest: regionOfInterest
        )
    }

    /// Dab radius in PIXELS for one extent — the single source of truth
    /// shared by `resolve` and `BrushMaskOverlayView`'s live preview
    /// band, so the two can never drift. Clamps `brushSize` into
    /// `minimumSize...maximumSize` (NaN falls to `minimumSize`, the
    /// smallest/most conservative end, mirroring
    /// `RadialMaskGeometry.innerRadiusFraction`'s own NaN-fallback
    /// direction), then floors the PIXEL result at `minimumRadiusPixels`
    /// regardless of how small `extent` is (F1: a too-small brush must
    /// clamp, never make `resolve` return `nil` the way a too-small radial
    /// radius does).
    static func radiusInPixels(brushSize: Double, extent: CGRect) -> CGFloat {
        let clampedSize = brushSize.isNaN ? minimumSize : min(max(brushSize, minimumSize), maximumSize)
        return max(CGFloat(clampedSize) * min(extent.width, extent.height), minimumRadiusPixels)
    }

    /// Blur radius in PIXELS for a given feather amount and dab radius —
    /// the single source of truth `resolve` uses. Clamps `feather` to
    /// `0...1` (NaN falls to `0`, the conservative/hard-edge direction, NOT
    /// the softest one — the opposite fallback direction from
    /// `radiusInPixels` above, deliberately: an unreadable feather should
    /// degrade to "no softening" rather than silently maximizing it).
    /// Returns exactly `0` (meaning: skip the blur node) whenever the
    /// computed radius is under `minimumBlurRadiusPixels` — `feather == 0`
    /// always lands here, and is a legitimate hard edge, not a case
    /// needing defensive softening.
    static func blurRadiusInPixels(feather: Double, radiusPixels: CGFloat) -> CGFloat {
        let clampedFeather = feather.isNaN ? 0 : min(max(feather, 0), 1)
        let radius = CGFloat(clampedFeather) * featherRadiusFraction * radiusPixels
        return radius >= minimumBlurRadiusPixels ? radius : 0
    }

    /// Padding (in pixels) to add around a stroke's own bounding box before
    /// rasterizing, on every side.
    ///
    /// Sufficiency proof (mirrors `MaskGeometry.guideLineLength`'s own
    /// proof style): stroking a path with round caps/joins at
    /// `lineWidth = 2 * radiusPixels` paints exactly the Minkowski sum of
    /// the path with a disc of radius `radiusPixels` — so `radiusPixels`
    /// alone is exactly enough room for the OPAQUE stroke geometry itself,
    /// with zero slack. A Gaussian's mass is >99.7% within 3 standard
    /// deviations under either plausible `inputRadius` convention Core
    /// Image's `CIGaussianBlur` might use for that parameter (whether it
    /// names a standard deviation directly or some small multiple of one),
    /// so `blurPaddingMultiple (3) * blurRadiusPixels` bounds the
    /// truncated tail to a visually negligible fraction. The `+1` absorbs
    /// antialiasing/rounding at the stroke's own edge and the final
    /// `.integral` rect-rounding, matching `RadialMaskGeometry.resolve`'s
    /// own "+1" hedge for the same class of rounding slack.
    static func padding(radiusPixels: CGFloat, blurRadiusPixels: CGFloat) -> CGFloat {
        radiusPixels + blurPaddingMultiple * blurRadiusPixels + 1
    }
}
