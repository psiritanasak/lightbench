import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies an `EditState` to a `CIImage`.
///
/// The edit pipeline order is fixed (see CLAUDE.md):
/// decode → WB → exposure → contrast → curves → HSL → crop → output transform.
/// Decode already happened before this point (the caller loads the file);
/// output transform (display color space conversion) happens at render time,
/// outside this type. Only exposure exists today — WB, contrast, curves, HSL,
/// and crop stages are not implemented yet and are intentionally absent
/// rather than stubbed; they'll be inserted here, in order, as they're built.
enum EditPipeline {
    static func apply(_ state: EditState, to input: CIImage) -> CIImage {
        var image = input
        image = applyExposure(state.exposureEV, to: image)
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
}
