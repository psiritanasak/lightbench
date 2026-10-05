import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Optional sharpening applied to an exported image AFTER it has been resized, so a downsized export doesn't look
/// soft. Not an edit: it is never stored in the photo's `EditState` and never affects the Editor, thumbnails or
/// Enhance — it only shapes the pixels written by Export.
///
/// KNOWN LIMITATIONS (measured 2026-10-02; logged in IMPROVEMENTS.md D48):
/// - FIXED (2026-10-05): it used to sharpen Grain too (noise std 0.0837 -> 0.0954 / 0.1128 on a flat field with Grain 0.5).
///   `PhotoExporter.export` now renders the pipeline without grain and adds it after this sharpen when both are on. Noise
///   left by Noise Reduction and source JPEG blocking are still sharpened with everything else.
/// - Next to a transparent margin INSIDE the frame (e.g. `transformScale` < 1 without a crop) the opaque edge gets a
///   bright rim (measured +44% linear at print settings, fading over ~8px; alpha itself stays exactly 0/1). It is a
///   normal edge in JPEG (the margin is black) but shows as a halo against transparency in PNG/TIFF. The image's
///   own outer border is not affected. `EditPipeline.applySharpen` has the same unmeasured gap.
enum ExportSharpening: String, CaseIterable, Identifiable, Sendable, Codable {
    case none, screen, print

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .screen: return "For screen"
        case .print: return "For print"
        }
    }
}

enum OutputSharpen {
    /// `CISharpenLuminance.sharpness` per setting. PRINCIPLED STARTING VALUES, to be tuned by eye on a real
    /// downsized photo (see PROGRESS.md's live check), not claimed as optima. Chosen from a measurement (2026-10-02,
    /// 0.2 | 0.5 perceptual step edge, 1600px square, radius fractions below): a first draft of 0.5 / 0.9 swung the
    /// edge to 0.140 / 0.560 (screen) and 0.082 / 0.619 (print) — a 20% / 40% overshoot of the 0.3 step, visibly
    /// haloed — so the values were scaled down roughly linearly. Print is stronger than screen because print softens
    /// (dot gain, paper). The halo's PIXEL size follows the radius fraction, so apparent size is consistent across
    /// output sizes, but a sub-pixel radius (400px output: 0.48px) gives a much weaker effect than at 1600px.
    /// Eyeballed 2026-10-05 on two real photos at 2048px (3x zoom of matching crops, none/screen/print): screen gives modestly crisper edges and fur texture with no visible halo; print is clearly crisper with a faint dark rim along the strongest bright/blue and fur/sky boundaries, still natural. Judged by one reviewer (me), not a panel: kept as is.
    static let screenSharpness: Float = 0.2
    static let printSharpness: Float = 0.4

    /// Radius as a fraction of `min(extent)` of the image BEING SHARPENED (the resized output), the same
    /// resolution rule `EditPipeline.kSharpenRadiusFraction` documents: a fixed pixel radius would give a 1000px
    /// and a 4000px export different halos. Print uses a slightly wider radius.
    static let screenRadiusFraction: Double = 0.0012
    static let printRadiusFraction: Double = 0.002

    /// Output sharpening is normally a 1-3px effect at OUTPUT resolution; a pure fraction would give a full-size
    /// 6016x4016 export 4.8px (screen) / 8px (print), which is closer to local contrast than to sharpening. The
    /// fraction therefore only decides the radius up to this cap (it is not reached below ~2500px min side for
    /// screen / ~1500px for print, so the 1600px measurements above are essentially unaffected: print at 1600px goes from 3.2px to 3.0px).
    static let maximumRadiusPixels: Double = 3

    /// The radius in pixels for an image whose short side is `shortSide`.
    static func radiusPixels(for setting: ExportSharpening, shortSide: Double) -> Double {
        let fraction: Double
        switch setting {
        case .none: return 0
        case .screen: fraction = screenRadiusFraction
        case .print: fraction = printRadiusFraction
        }
        return min(fraction * shortSide, maximumRadiusPixels)
    }

    static func apply(_ setting: ExportSharpening, to image: CIImage) -> CIImage {
        let sharpness: Float
        switch setting {
        case .none:
            return image
        case .screen:
            sharpness = screenSharpness
        case .print:
            sharpness = printSharpness
        }
        let extent = image.extent
        let shortSide = Double(min(extent.width, extent.height))
        guard shortSide > 0, extent.width.isFinite, extent.height.isFinite else { return image }

        // Same shape as `EditPipeline.applySharpen`: sharpen the PERCEPTUAL (gamma-encoded) values — a
        // luminance-sharpen of linear light puts much too strong a halo on the dark side — then go back to linear.
        let encode = CIFilter.linearToSRGBToneCurve()
        encode.inputImage = image
        let encoded = encode.outputImage ?? image
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = encoded
        sharpen.sharpness = sharpness
        sharpen.radius = Float(radiusPixels(for: setting, shortSide: shortSide))
        let sharpened = sharpen.outputImage ?? encoded
        let decode = CIFilter.sRGBToneCurveToLinear()
        decode.inputImage = sharpened
        // Defensive: the export's pixel size must never change. (Measured: with this crop removed the extent of a
        // 1600px step edge stayed identical, so `CISharpenLuminance` does not grow it today.)
        return (decode.outputImage ?? sharpened).cropped(to: extent)
    }
}
