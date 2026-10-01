import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Runs Apple's on-device foreground-instance segmentation (`VNGenerateForegroundInstanceMaskRequest`)
/// and packages the result for `Mask.subjectMaskPNG`. The ONLY file in the project that imports Vision.
/// Feasibility numbers (latency, native 512x512 mask, determinism, empty-result behavior) are in
/// `docs/ROADMAP_HISTORY.md`'s Vision spike entry and pinned by `VisionSubjectMaskProbeTests`.
///
/// The returned PNG is 8-bit grayscale, row 0 = the TOP of the image (what `EditPipeline.decodedSubjectRaster`
/// expects), in the frame of the image that was passed in — which must be the UNEDITED, oriented source.
enum SubjectMaskGenerator {
    enum Result: Equatable {
        case mask(png: Data, revision: Int)
        /// Vision ran and found no foreground subject (nil observation) or an all-empty mask.
        case noSubject
        case failed(String)
    }

    /// Long-side cap for the image handed to Vision AND for the stored raster. The raster is
    /// stretched over the photo at render time, so more pixels only add sidecar bytes.
    static let maxLongSide: CGFloat = 1024

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Synchronous and slow-ish (tens of ms warm, up to ~1s cold): call off the main thread.
    static func generate(from image: CIImage) -> Result {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width >= 1, extent.height >= 1 else {
            return .failed("The photo has no usable size.")
        }
        let scale = min(1, maxLongSide / max(extent.width, extent.height))
        let origin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        var scaled = origin
        if scale < 1 { // Lanczos, like `ProxyBuilder`: plain bilinear aliases at large ratios (~8x for 8192px)
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = origin.clampedToExtent() // else the border rows blend in transparent pixels
            lanczos.scale = Float(scale)
            lanczos.aspectRatio = 1
            scaled = lanczos.outputImage ?? origin.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        // Rounded DOWN so the render rect never reaches past the scaled image's last column/row.
        let size = CGRect(x: 0, y: 0, width: max(1, (extent.width * scale).rounded(.down)), height: max(1, (extent.height * scale).rounded(.down)))
        guard let cgImage = context.createCGImage(scaled, from: size) else {
            return .failed("Couldn't read the photo's pixels.")
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        do { try handler.perform([request]) } catch {
            return .failed("Subject detection failed: \(error.localizedDescription)")
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return .noSubject }

        let buffer: CVPixelBuffer
        do {
            buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        } catch {
            return .failed("Couldn't build the subject mask: \(error.localizedDescription)")
        }
        guard let gray = quantizedGray(buffer) else { return .failed("Unexpected subject mask format.") }
        guard gray.bytes.contains(where: { $0 > 0 }) else { return .noSubject }
        guard let png = encodePNG(gray) else { return .failed("Couldn't encode the subject mask.") }
        return .mask(png: png, revision: request.revision) // the revision that actually produced the pixels
    }

    private struct Gray { var width: Int; var height: Int; var bytes: [UInt8] }

    /// Vision's scaled mask is one 32-bit float per pixel in 0...1.
    private static func quantizedGray(_ buffer: CVPixelBuffer) -> Gray? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                let v = row[x]
                bytes[y * width + x] = v.isFinite ? UInt8((min(max(v, 0), 1) * 255).rounded()) : 0
            }
        }
        return Gray(width: width, height: height, bytes: bytes)
    }

    private static func encodePNG(_ gray: Gray) -> Data? {
        guard let provider = CGDataProvider(data: Data(gray.bytes) as CFData),
              let image = CGImage(
                  width: gray.width, height: gray.height, bitsPerComponent: 8, bitsPerPixel: 8,
                  bytesPerRow: gray.width, space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
