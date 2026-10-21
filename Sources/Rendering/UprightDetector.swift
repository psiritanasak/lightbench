import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Finds the near-vertical / near-horizontal lines of the UNEDITED, oriented source image for Upright:
/// downscale to `maxLongSide` (Lanczos, the same recipe as `HorizonDetector`), render linear RGBA floats, take the
/// gamma-encoded luma (`MergeAlignment.lumaProxy`), and hand it to the pure `UprightLineDetector`.
enum UprightDetector {
    enum Result: Equatable {
        case lines(UprightLineDetector.Lines)
        case failed(String)
    }

    /// Long-side cap of the analysed proxy.
    static let maxLongSide: CGFloat = 768

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Synchronous: call off the main thread.
    static func detect(in image: CIImage) -> Result {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width >= 1, extent.height >= 1 else {
            return .failed("The photo has no usable size.")
        }
        let scale = min(1, maxLongSide / max(extent.width, extent.height))
        let origin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        var scaled = origin
        if scale < 1 {
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = origin.clampedToExtent()
            lanczos.scale = Float(scale)
            lanczos.aspectRatio = 1
            scaled = lanczos.outputImage ?? origin.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let width = max(1, Int((extent.width * scale).rounded(.down)))
        let height = max(1, Int((extent.height * scale).rounded(.down)))
        guard let space = CGColorSpace(name: CGColorSpace.linearSRGB) else { return .failed("No colour space.") }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        // CIContext.render(toBitmap:) writes the TOP row first.
        context.render(
            scaled, toBitmap: &rgba, rowBytes: width * 16,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: space)
        guard let gray = MergeAlignment.lumaProxy(rgbaFloat: rgba, width: width, height: height, exposureFactor: 1) else {
            return .failed("Couldn't read the photo's pixels.")
        }
        return .lines(UprightLineDetector.detect(in: gray))
    }
}
