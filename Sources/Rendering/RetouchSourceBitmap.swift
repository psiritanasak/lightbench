import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Builds the small PERCEPTUAL (sRGB-gamma) RGB bitmap `RetouchSourceSearch` scans: the photo downscaled to
/// `longSide` px (Lanczos, like `ProxyBuilder`), encoded to sRGB gamma, rendered to float RGBA and repacked as RGB
/// with row 0 = the TOP. Synchronous and tens of milliseconds on a full-size photo: call off the main thread.
enum RetouchSourceBitmap {
    static let longSide = 512

    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
        .workingFormat: CIFormat.RGBAf,
        .cacheIntermediates: false
    ])

    static func make(from image: CIImage) -> RetouchSourceSearch.Bitmap? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        let scale = min(1, Double(longSide) / Double(max(extent.width, extent.height)))
        let origin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        var scaled = origin
        if scale < 1 {
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = origin
            lanczos.scale = Float(scale)
            lanczos.aspectRatio = 1
            scaled = lanczos.outputImage ?? origin
        }
        let width = max(1, Int((extent.width * scale).rounded(.down)))
        let height = max(1, Int((extent.height * scale).rounded(.down)))
        let encode = CIFilter.linearToSRGBToneCurve()
        encode.inputImage = scaled
        guard let encoded = encode.outputImage else { return nil }
        var floats = [Float](repeating: 0, count: width * height * 4)
        context.render(
            encoded, toBitmap: &floats, rowBytes: width * 16,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        )
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = floats[i * 4]; rgb[i * 3 + 1] = floats[i * 4 + 1]; rgb[i * 3 + 2] = floats[i * 4 + 2]
        }
        return RetouchSourceSearch.Bitmap(width: width, height: height, rgb: rgb)
    }
}
