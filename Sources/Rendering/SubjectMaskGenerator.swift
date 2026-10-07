import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Runs Apple's on-device foreground-instance segmentation (`VNGenerateForegroundInstanceMaskRequest`)
/// and packages the result for `Mask.subjectInstancePNGs`. One of two files that import Vision (the other is `SkinMaskGenerator`).
/// Feasibility numbers (latency, native 512x512 mask, determinism, empty-result behavior) are in
/// `docs/ROADMAP_HISTORY.md`'s Vision spike entry and pinned by `VisionSubjectMaskProbeTests`.
///
/// The returned PNG is 8-bit grayscale, row 0 = the TOP of the image (what `EditPipeline.decodedSubjectRaster`
/// expects), in the frame of the image that was passed in — which must be the UNEDITED, oriented source.
enum SubjectMaskGenerator {
    enum Result: Equatable {
        /// One PNG per person/object, ordered left-to-right (see `Mask.subjectInstancePNGs`).
        case mask(instances: [Data], revision: Int)
        /// Vision ran and found no foreground subject (nil observation) or an all-empty mask.
        case noSubject
        case failed(String)
    }

    /// Long-side cap for the image handed to Vision AND for the stored raster. The raster is
    /// stretched over the photo at render time, so more pixels only add sidecar bytes.
    static let maxLongSide: CGFloat = 1024

    /// Most people/objects kept per mask (largest by area); bounds the sidecar size.
    static let maxInstances = 8

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

        // One soft mask PER instance (Vision refines each against the full-resolution image, unlike its
        // blocky native label map), so the user can include/exclude people later.
        struct Candidate { var gray: Gray; var mass: Double; var centroidX: Double }
        var candidates: [Candidate] = []
        for index in observation.allInstances {
            // One instance failing to refine must not throw away the ones that worked.
            guard let buffer = try? observation.generateScaledMaskForImage(forInstances: IndexSet(integer: index), from: handler),
                  let gray = quantizedGray(buffer) else { continue }
            var mass = 0.0, weightedX = 0.0
            for y in 0..<gray.height {
                for x in 0..<gray.width {
                    let v = Double(gray.bytes[y * gray.width + x])
                    mass += v
                    weightedX += v * Double(x)
                }
            }
            candidates.append(Candidate(
                gray: gray, mass: mass, centroidX: mass > 0 ? weightedX / mass / Double(gray.width) : 0))
        }
        let pixelCount = candidates.first.map { $0.gray.width * $0.gray.height } ?? 0
        let kept = selectInstances(
            candidates.map { (mass: $0.mass, centroidX: $0.centroidX) }, pixelCount: pixelCount, limit: maxInstances
        ).map { candidates[$0] }
        guard !kept.isEmpty else { return candidates.isEmpty ? .failed("Couldn't build the subject mask.") : .noSubject }
        var pngs: [Data] = []
        for instance in kept {
            guard let png = encodePNG(instance.gray) else { return .failed("Couldn't encode the subject mask.") }
            pngs.append(png)
        }
        return .mask(instances: pngs, revision: request.revision) // the revision that actually produced the pixels
    }

    /// Which candidate instances to keep, as indices into `candidates`, in final (left-to-right) order:
    /// drops empty instances and specks (under 0.05% of the frame fully selected), keeps the `limit`
    /// largest by mass, then orders those by `centroidX` so "Subject 1…N" matches the picture. Pure, so
    /// the cap — which bounds the sidecar size — is unit-testable without Vision.
    static func selectInstances(
        _ candidates: [(mass: Double, centroidX: Double)], pixelCount: Int, limit: Int
    ) -> [Int] {
        let minimumMass = 0.0005 * 255 * Double(pixelCount)
        let survivors = candidates.indices.filter { candidates[$0].mass > 0 && candidates[$0].mass >= minimumMass }
        let largest = survivors.sorted { candidates[$0].mass > candidates[$1].mass }.prefix(max(0, limit))
        return largest.sorted { candidates[$0].centroidX < candidates[$1].centroidX }
    }

    struct Gray { var width: Int; var height: Int; var bytes: [UInt8] }

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

    static func encodePNG(_ gray: Gray) -> Data? {
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
