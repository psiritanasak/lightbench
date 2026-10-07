import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Builds the persisted skin raster behind Styles v3 "Protect skin": the pixels that are BOTH inside Vision's person
/// segmentation (`VNGeneratePersonSegmentationRequest`, revision 1 pinned, `.accurate`) AND inside `SkinWindow`'s colour box
/// (`SkinMaskBuilder.combine`). Neither alone is enough: the colour box alone marks sand and rock, the person mask alone
/// includes hair and clothes. Feasibility and coverage numbers: docs/ROADMAP_HISTORY.md, "Styles v3 skin-protection spike";
/// OS facts pinned by `SkinProtectionProbeTests`.
///
/// Like `SubjectMaskGenerator`, the PNG is 8-bit grayscale, row 0 = the TOP of the image, in the frame of the image passed in —
/// the UNEDITED, oriented source — at most `maxLongSide` px on the long side (it is stretched over the photo at render time).
/// Known limits (shown to the user): people only — printed faces and underwater skin are missed; skin-coloured clothing counts
/// as skin; the colour window was tested on a narrow range of skin tones; and large flat skin-coloured areas (a beige wall,
/// sand close-up) may be marked even with no person — from ONE synthetic observation (a flat sand-coloured 384x288 image had
/// about 80% marked as person by Vision, 2026-10-07; a flat blue one none), not measured on real photos.
enum SkinMaskGenerator {
    enum Result: Equatable {
        case mask(png: Data, revision: Int)
        /// Vision ran and found no person, or no skin-coloured pixel inside one.
        case noPeople
        case failed(String)
    }

    static let maxLongSide: CGFloat = 1024

    /// The pinned Vision revision: a different one is a different network, so the persisted raster must say which made it.
    static let personSegmentationRevision = VNGeneratePersonSegmentationRequestRevision1

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Synchronous and slow (first Vision call ~3.4 s measured in the spike, warm well under a second): call off the main thread.
    static func generate(from image: CIImage) -> Result {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width >= 1, extent.height >= 1 else {
            return .failed("The photo has no usable size.")
        }
        guard let prepared = prepare(image) else { return .failed("Couldn't read the photo's pixels.") }
        let (cgImage, width, height) = (prepared.image, prepared.width, prepared.height)

        let request = VNGeneratePersonSegmentationRequest()
        request.revision = personSegmentationRevision
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do { try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request]) } catch {
            return .failed("Person detection failed: \(error.localizedDescription)")
        }
        guard let buffer = request.results?.first?.pixelBuffer,
              let person = resizedGray(buffer, toWidth: width, height: height),
              let rgba = straightRGBA(cgImage, width: width, height: height),
              let combined = SkinMaskBuilder.combine(person: person, rgba: rgba, width: width, height: height) else {
            return .failed("Couldn't build the skin mask.")
        }
        guard combined.contains(where: { $0 > 0 }) else { return .noPeople }
        guard let png = SubjectMaskGenerator.encodePNG(.init(width: width, height: height, bytes: combined)) else {
            return .failed("Couldn't encode the skin mask.")
        }
        return .mask(png: png, revision: request.revision)
    }

    struct Prepared { var image: CGImage; var width: Int; var height: Int }

    /// The input downscaled (Lanczos) to at most `maxLongSide`, moved to origin 0,0, forced opaque and rendered as an sRGB
    /// bitmap whose row 0 is the TOP of the image. Opaque first: the window is defined on straight sRGB, and
    /// `settingAlphaOne` turns transparent margins black (outside the window's luma floor) rather than letting them read as colour.
    static func prepare(_ image: CIImage) -> Prepared? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return nil }
        let scale = min(1, maxLongSide / max(extent.width, extent.height))
        let origin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        var scaled = origin
        if scale < 1 { // Lanczos, like `SubjectMaskGenerator`/`ProxyBuilder`: bilinear aliases at large ratios
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = origin.clampedToExtent()
            lanczos.scale = Float(scale)
            lanczos.aspectRatio = 1
            scaled = lanczos.outputImage ?? origin.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let width = max(1, Int((extent.width * scale).rounded(.down)))
        let height = max(1, Int((extent.height * scale).rounded(.down)))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let cgImage = context.createCGImage(scaled.settingAlphaOne(in: rect), from: rect, format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return Prepared(image: cgImage, width: width, height: height)
    }

    /// The pixels as straight 8-bit sRGB, 4 bytes each (alpha ignored: the image was forced opaque above).
    static func straightRGBA(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// Vision's one-component-8 mask (its own size, rows top to bottom) resampled to `width` x `height` (bilinear, keeps the soft edge).
    static func resizedGray(_ buffer: CVPixelBuffer, toWidth width: Int, height: Int) -> [UInt8]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let sw = CVPixelBufferGetWidth(buffer), sh = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard sw > 0, sh > 0, let provider = CGDataProvider(data: Data(bytes: base, count: rowBytes * sh) as CFData),
              let source = CGImage(width: sw, height: sh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: rowBytes,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                   decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}
