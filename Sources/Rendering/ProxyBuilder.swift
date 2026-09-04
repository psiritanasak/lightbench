import CoreImage
import CoreImage.CIFilterBuiltins

/// Builds the downscaled preview proxy for IMPROVEMENTS.md P2 (interactive
/// slider drags), mirroring `RawDecoder.materialize`'s own shape and
/// reasoning closely — see that function's doc comment for the fuller
/// argument this one only summarizes.
enum ProxyBuilder {
    /// Downscales `image` via Lanczos into a realized `CVPixelBuffer`,
    /// matching `RawDecoder.materialize`'s "a `CIImage` is a lazy recipe,
    /// not decoded pixels" argument: a per-frame LAZY scale filter would
    /// leave the full-resolution source touched every drag frame — for a
    /// non-RAW photo, `image` is a lazy `CIImage(contentsOf:)` graph, so
    /// that would risk re-decoding a large JPEG every frame, reintroducing
    /// for non-RAW exactly the bug class `materialize` exists to prevent
    /// for RAW. Building once and reusing (grow-only, see
    /// `ProxyScale.canReuse`) is the whole point of this type existing.
    ///
    /// Lanczos, not a plain affine scale (unlike `PhotoExporter.resized`):
    /// this is paid once per burst rather than once per export, and a
    /// plain scale aliases visibly at the downscale ratios this feature
    /// uses (~0.3-0.85) — Noise Reduction and Sharpen would then act on
    /// that aliasing, making the preview-vs-final divergence
    /// `ImageRenderer`'s proxy section documents worse than necessary.
    ///
    /// Renders in `extendedLinearSRGB`/`RGBAh` (`colorSpace` below),
    /// matching this app's working space everywhere else `EditPipeline`
    /// runs. An 8-bit/sRGB intermediate would gamma-encode and clip
    /// extended range/gamut before any edit math sees it — the same defect
    /// class the thumbnail pipeline was reviewer-caught on once already.
    ///
    /// Routed through `RawDecoder.RenderGate`. Not required on the common
    /// path — by the time this runs, a RAW source is already a
    /// materialized `CIImage(cvPixelBuffer:)`, no longer a `CIRAWFilter`
    /// graph touching `RawCamera.framework` — but `materialize` itself
    /// falls back to returning its lazy input unchanged if its own
    /// degenerate-extent guard fails, and gating here closes that edge
    /// case instead of leaving it merely improbable.
    ///
    /// Emits at origin (0,0), not `image.extent`'s scaled origin: the
    /// whole pipeline is origin-agnostic (crop/vignette/red-eye/straighten
    /// all read the extent's own min/mid, never an absolute value) and
    /// `ImageRenderer.fitted` re-origins anyway via `-image.extent.minX/
    /// minY`, so there's nothing to preserve — the RESULT's origin is
    /// always the exact integer (0,0). Note this doesn't make the
    /// intermediate resample phase-aligned: `extent.minX * scale` is
    /// rarely an integer, so the crop-then-translate below still resamples
    /// at a fractional offset when the source origin is non-zero. Harmless
    /// for a preview proxy (a sub-pixel resample phase shift, not a
    /// content error) and rare in practice — both `RawDecoder.materialize`'s
    /// output and a fresh `CIImage(contentsOf:)` already have origin (0,0).
    ///
    /// Returns `nil` on any failure — degenerate extent, filter failure,
    /// or `CVPixelBufferCreate` failure — never a force-unwrap. A `nil`
    /// result means "stay on full-res this frame," never a lost image;
    /// the caller only reconsiders building on the next `draw(in:)` where
    /// `ProxyScale.canReuse` is still false, the normal per-frame cadence,
    /// not a retry loop.
    static func build(_ image: CIImage, scale: CGFloat) async -> CIImage? {
        let extent = image.extent
        // `CGRect.infinite`'s width/height are `CGFloat.greatestFiniteMagnitude`
        // — finite by IEEE semantics — so `.isFinite` alone would NOT catch
        // it; `.isInfinite` is the correct check, same trap `RawDecoder
        // .materialize`'s own guard (and its test) already recorded once.
        // `scale <= 1` (not just `.isFinite, > 0`) matters beyond
        // documenting intent: without an upper bound, `extent.width *
        // scale` can exceed `Int64.max` and `Int(_:)` traps on the
        // conversion below — reviewer-caught via a live crash on a
        // pathological scale, even though `ProxyScale.requiredScale`'s
        // own contract never hands this function anything above 1.
        guard !extent.isInfinite, !extent.isNull,
              extent.width > 0, extent.height > 0,
              extent.width < CGFloat(Int32.max), extent.height < CGFloat(Int32.max),
              scale.isFinite, scale > 0, scale <= 1
        else {
            return nil
        }

        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale
        let pixelWidth = Int(scaledWidth.rounded())
        let pixelHeight = Int(scaledHeight.rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let filter = CIFilter.lanczosScaleTransform()
        // `.clampedToExtent()` before scaling avoids sampling outside the
        // source's own bounds at the edges, which otherwise pulls in
        // transparent black and produces a dark/soft 1-3px border —
        // there's no existing precedent for this scale filter in the
        // codebase (`PhotoExporter.resized` uses a plain, unclamped affine
        // scale, a fine tradeoff there since it runs once at export, not
        // worth the softening this proxy would otherwise show every drag).
        filter.inputImage = image.clampedToExtent()
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        guard let scaledUnclamped = filter.outputImage else { return nil }

        // Crop to the exact integer-pixel rect at the source's own scaled
        // position, then translate that crop down to origin (0,0) — see
        // this function's own doc comment for why the origin isn't
        // preserved.
        let scaledOrigin = CGPoint(x: extent.minX * scale, y: extent.minY * scale)
        let sourceRect = CGRect(
            x: scaledOrigin.x, y: scaledOrigin.y,
            width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)
        )
        let scaled = scaledUnclamped
            .cropped(to: sourceRect)
            .transformed(by: CGAffineTransform(translationX: -scaledOrigin.x, y: -scaledOrigin.y))

        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, pixelWidth, pixelHeight,
            kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        // `CVPixelBuffer` isn't (yet) audited `Sendable` by CoreVideo —
        // same crossing `RawDecoder.materialize` needs, reusing its own
        // wrapper (widened to internal for exactly this) rather than
        // duplicating it.
        let pixelBufferBox = RawDecoder.UncheckedSendableBox(value: pixelBuffer)
        await RawDecoder.RenderGate.shared.run {
            context.render(
                scaled, to: pixelBufferBox.value,
                bounds: CGRect(origin: .zero, size: CGSize(width: pixelWidth, height: pixelHeight)),
                colorSpace: colorSpace
            )
            // `context` is a long-lived static — without this, its internal
            // intermediate caches hold onto this render's working buffers
            // indefinitely, same rationale as `RawDecoder.materialize`'s own
            // `clearCaches()` call, and arguably more important here: this
            // runs once per drag BURST for the photo's whole editing
            // session, not once per photo load. Reviewer-measured: ~284MB
            // held across 8 successive builds from a 24MP source without
            // this call.
            context.clearCaches()
        }

        return CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: colorSpace])
    }

    /// Not `private`: tests need to construct an out-of-`[0,1]`-range
    /// fixture in this exact working space, same reason
    /// `RawDecoder.materializeColorSpace` is non-private.
    static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    private static let context = CIContext(options: [
        .workingColorSpace: colorSpace, .workingFormat: CIFormat.RGBAh
    ])
}
