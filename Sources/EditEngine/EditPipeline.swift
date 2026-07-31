import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies an `EditState` to a `CIImage`.
///
/// The edit pipeline order is fixed (see CLAUDE.md):
/// decode → WB → exposure → contrast → curves → HSL → crop → output transform.
/// Decode already happened before this point (the caller loads the file);
/// output transform (display color space conversion) happens at render time,
/// outside this type. Only exposure and contrast exist today — WB, curves,
/// HSL, and crop stages are not implemented yet and are intentionally absent
/// rather than stubbed; they'll be inserted here, in order, as they're built.
enum EditPipeline {
    static func apply(_ state: EditState, to input: CIImage) -> CIImage {
        var image = input
        image = applyExposure(state.exposureEV, to: image)   // scene-linear
        image = applyPerceptualAdjustments(state, to: image) // sRGB-gamma domain
        return image
    }

    // MARK: - Exposure

    /// Multiplies linear-light pixel values by `2^ev` (a camera-style
    /// exposure-stops gain), using Core Image's built-in exposure filter.
    private static func applyExposure(_ ev: Double, to image: CIImage) -> CIImage {
        guard ev != 0 else { return image }

        let filter = CIFilter.exposureAdjust()
        filter.inputImage = image
        filter.ev = Float(ev)
        return filter.outputImage ?? image
    }

    // MARK: - Perceptual domain (contrast, and later curves + HSL)

    /// Contrast — and later curves and HSL — are applied in the sRGB
    /// gamma-encoded (perceptual / display-referred) domain, not scene-linear
    /// light. This is a DOCUMENTED DEVIATION from CLAUDE.md's default "all
    /// image math in linear light" rule (which CLAUDE.md itself permits when
    /// documented). Rationale, verified empirically against Core Image's real
    /// behavior in this app's working space: a linear-light pivot of 0.5 sits
    /// at ~0.735 perceptual brightness, so a linear-domain contrast pivot
    /// crushes photographic middle gray (linear ≈0.214) toward black —
    /// wrong, and unlike every real photo editor. Encoding to sRGB gamma
    /// first puts the pivot at perceptual middle gray instead. The tone-curve
    /// filters below are exact inverses of each other and do NOT clamp
    /// values above 1.0, so highlight headroom created by exposure (which
    /// runs before this step) survives the round-trip back to linear.
    ///
    /// Future curves/HSL stages belong INSIDE this same encode/decode
    /// sandwich (extend the guard below), not given their own — they share
    /// the identical "must be perceptual" requirement.
    private static func applyPerceptualAdjustments(_ state: EditState, to image: CIImage) -> CIImage {
        guard state.contrast != 0 else { return image } // later: || curves active || hsl active

        var img = encodeToPerceptual(image)
        img = applyContrast(state.contrast, to: img)
        img = decodeToLinear(img)
        return img
    }

    // MARK: - Contrast

    /// Adjusts contrast around a perceptual middle-gray pivot via Core
    /// Image's built-in color-controls filter. `contrast` (-1...1) maps to
    /// the filter's native `1 + contrast` factor (0...2); brightness and
    /// saturation are left at their identity defaults.
    private static func applyContrast(_ contrast: Double, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.contrast = Float(1 + contrast)
        return filter.outputImage ?? image
    }

    private static func encodeToPerceptual(_ image: CIImage) -> CIImage {
        let filter = CIFilter.linearToSRGBToneCurve()
        filter.inputImage = image
        return filter.outputImage ?? image
    }

    private static func decodeToLinear(_ image: CIImage) -> CIImage {
        let filter = CIFilter.sRGBToneCurveToLinear()
        filter.inputImage = image
        return filter.outputImage ?? image
    }
}
