import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Runs Apple's `VNDetectHorizonRequest` (revision pinned) on the UNEDITED, oriented source image.
/// Returns Vision's raw angle; `StraightenSolver` turns it into the app's Straighten convention.
enum HorizonDetector {
    enum Result: Equatable {
        /// `VNHorizonObservation.angle`, radians, exactly as Vision reports it.
        case angle(Double)
        case none
        case failed(String)
    }

    /// Long-side cap for the image handed to Vision (same recipe as `SubjectMaskGenerator`).
    static let maxLongSide: CGFloat = 1024

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
        let size = CGRect(x: 0, y: 0, width: max(1, (extent.width * scale).rounded(.down)), height: max(1, (extent.height * scale).rounded(.down)))
        guard let cgImage = context.createCGImage(scaled, from: size) else {
            return .failed("Couldn't read the photo's pixels.")
        }
        let request = VNDetectHorizonRequest()
        request.revision = VNDetectHorizonRequestRevision1
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        do { try handler.perform([request]) } catch {
            return .failed("Horizon detection failed: \(error.localizedDescription)")
        }
        guard let observation = request.results?.first else { return .none }
        return .angle(Double(observation.angle))
    }
}
