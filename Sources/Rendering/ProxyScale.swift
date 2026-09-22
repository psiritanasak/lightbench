import CoreGraphics

/// Pure geometry for IMPROVEMENTS.md P2 (interactive-drag preview proxy) —
/// same "pure, unit-tested helper" shape as `AspectFit`/`ZoomPanGeometry`/
/// `CompareLayout`/`ThinSliderGeometry`.
///
/// Deliberately takes plain sizes, not `EditState`: the displayed (post-crop/
/// straighten/perspective) extent is supplied by the caller as an EXACT
/// probe — one `EditPipeline.apply(editState, to: image).extent.size` call,
/// cheap because Core Image doesn't render pixels just to report an extent —
/// rather than estimated here from crop insets. An estimate would either
/// duplicate `EditPipeline`'s own private `kMaxCropInset` clamp (a
/// silent-drift hazard) or be conservatively wrong in the wasteful direction
/// on an asymmetric crop.
///
/// Every extent-dependent `EditPipeline` stage derives its geometry as a
/// FRACTION of the current extent (crop insets, vignette center + half-
/// diagonal radius, straighten around the extent's own center, perspective
/// corner shifts as fractions of width/height, red-eye radius as a fraction
/// of `min(extent)`, Clarity/Texture/Sharpen radii, Dehaze's
/// patch and atmosphere-blur radii, and Defringe's edge-detection radius,
/// all as `fraction * min(extent)`) —
/// the same argument `ThumbnailGenerator.thumbnail(for:maxPixelSize:
/// editState:)` already documents and ships. So running the pipeline on a
/// proportionally-downscaled source is APPROXIMATELY correct — but
/// "approximately" is doing real work, and an earlier version of this comment
/// claiming it was exact "for every stage except Noise Reduction" was measured
/// WRONG. Downscale-correctness is a spectrum, via two DIFFERENT mechanisms.
/// Clarity, Sharpen and Dehaze carry absolute-pixel radii derived from extent
/// fractions, which quantize differently at each scale. Noise Reduction
/// diverges for the OPPOSITE reason: it has deliberately no extent term at
/// all (`kNoiseReductionSpan`). All four measure as divergent, by amounts
/// that swap rank with BOTH scale and image content: on a pixel-noise
/// fixture Noise Reduction is largest at 0.5 and Dehaze at 0.25, but on
/// band-limited (photo-like) content Dehaze leads at every scale measured.
/// Dehaze additionally estimates its atmospheric light as a whole-frame
/// STATISTIC, which the "geometry as a fraction of extent" premise above does
/// not cover at all. Texture and Defringe both appear in the geometry
/// enumeration above but were NOT part of D18's measurements, so no
/// divergence claim is made for either — structurally the same class,
/// just not separately measured.
/// See IMPROVEMENTS.md D18 for the measured matrix.
enum ProxyScale {
    /// Proxy pixels per DRAWABLE pixel. `MTKView.drawableSize` is device
    /// PIXELS (backing-scale-multiplied), not points — an earlier draft of
    /// this feature reasoned about "headroom" in points against a
    /// pixel-valued `drawableSize`, which made the proxy silently never
    /// engage below ~42MP on a Retina display (caught in design review, not
    /// live). 1.0 is pixel-exact at fit zoom: the display cannot show more
    /// than one proxy pixel per device pixel, so there is no upsampling and
    /// no added softness at that value. 1.25 buys a small margin for
    /// fit-rect rounding and a little zoom before the proxy is dropped for
    /// that burst (see `worthwhileScaleCeiling`).
    static let headroom: CGFloat = 1.25

    /// Above this required scale, downscaling isn't worth the build cost —
    /// render full-res instead, same as any non-interactive frame. A
    /// judgment call, not a measurement, same category as this codebase's
    /// other "tuned by feel" constants (e.g. the RAW re-decode debounce).
    static let worthwhileScaleCeiling: CGFloat = 0.85

    /// Below this many source pixels, never proxy — small photos already
    /// render fast, so the one-time build cost and the preview/final
    /// divergence would be pure loss with no smoothness to gain.
    static let minimumSourcePixels: CGFloat = 8_000_000

    /// The drawable region one side of the render actually fits into.
    /// `CompareLayout.sideBySideFitRects` fits each half into HALF the
    /// drawable's width; Split and the single-image path both fit into the
    /// whole drawable. Using the wrong container over-estimates the
    /// requirement (safe) but wastefully — Side by Side would otherwise ask
    /// for 2x the pixels it actually needs.
    static func effectiveContainer(drawableSize: CGSize, isSideBySide: Bool) -> CGSize {
        guard isSideBySide else { return drawableSize }
        return CGSize(width: drawableSize.width / 2, height: drawableSize.height)
    }

    /// Drawable (or half-drawable) pixels per source pixel, at the given
    /// zoom — the same `min(...)` `AspectFit.rect` uses, times `zoomScale`
    /// (matching how `ImageRenderer.fitted` folds zoom into its own scale).
    /// `nil` on any degenerate input. Never returns more than 1 scaled by
    /// `headroom` clamped to 1 — i.e. the result is always in `(0, 1]`, so a
    /// proxy is never upscaled beyond the source.
    static func requiredScale(
        displayedExtentSize: CGSize, container: CGSize, zoomScale: CGFloat
    ) -> CGFloat? {
        guard displayedExtentSize.width > 0, displayedExtentSize.height > 0,
              container.width > 0, container.height > 0,
              displayedExtentSize.width.isFinite, displayedExtentSize.height.isFinite,
              container.width.isFinite, container.height.isFinite,
              zoomScale.isFinite
        else {
            return nil
        }
        let fitScale = min(
            container.width / displayedExtentSize.width,
            container.height / displayedExtentSize.height
        )
        let effectiveZoom = max(zoomScale, 1)
        return min(1, headroom * fitScale * effectiveZoom)
    }

    /// Whether proxying is worth doing at all for this frame.
    static func isWorthwhile(requiredScale: CGFloat, sourcePixelCount: CGFloat) -> Bool {
        requiredScale < worthwhileScaleCeiling && sourcePixelCount >= minimumSourcePixels
    }

    /// Grow-only reuse: a `nil` cached scale never reuses (nothing built
    /// yet); otherwise reuse whenever the cached proxy already has at least
    /// as many pixels as currently required, so a drag never rebuilds the
    /// proxy mid-gesture as `requiredScale` fluctuates by a hair.
    static func canReuse(cachedScale: CGFloat?, requiredScale: CGFloat) -> Bool {
        guard let cachedScale else { return false }
        return cachedScale >= requiredScale
    }
}
