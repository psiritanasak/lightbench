import CoreImage
import CoreML
import Foundation

/// Runs the bundled monocular depth model (Depth Anything V2 Small, Core ML F16; `scripts/fetch_depth_model.sh` puts it in `Models/` and Xcode compiles it
/// into the bundle as `DepthAnythingV2SmallF16.mlmodelc`). OPTIONAL: when it is not installed `isInstalled` is false and callers fall back to embedded depth.
///
/// Measured on this machine (docs/ROADMAP_HISTORY.md "Depth Range spike"): first load about 7 s (compile / Neural Engine specialisation, so it happens
/// ONCE and the loaded model is kept), then +~50-60 MB RSS and 0.06-0.09 s per JPEG-sized frame; a 24 MP RAW costs about 0.6-0.8 s because the RAW render
/// into the model's 518x392 input dominates. The input is a FIXED 518x392 BGRA image, the output a 518x392 half-float RELATIVE inverse depth (larger =
/// nearer, arbitrary scale per image — `DepthNormalizer` makes it a nearness raster). Portrait photos are rotated to landscape for the model and
/// the result rotated back; a landscape photo of another aspect is stretched (squash was good enough on the D610 set).
enum DepthModelRunner {
    static let modelResource = "DepthAnythingV2SmallF16"
    static let modelID = "depth-anything-v2-small-f16"
    /// Pinned upstream revision (first 12 hex digits), recorded on every mask made with this model so a future model change is visible.
    static let revision = "cfef6f6f2a70"
    static let inputWidth = 518, inputHeight = 392

    enum RunError: Error, Equatable {
        case notInstalled
        case loadFailed(String)
        case renderFailed
        case predictionFailed(String)
    }

    static var modelURL: URL? { Bundle.main.url(forResource: modelResource, withExtension: "mlmodelc") }
    static var isInstalled: Bool { modelURL != nil }
    static var sourceTag: String { DepthSourceTag.model(id: modelID, revision: revision) }

    /// `MLModel` is not audited `Sendable` by CoreML, but its prediction methods are documented as safe to call from any thread; this box only
    /// carries the loaded instance across the loader actor's boundary (same pattern as `RawDecoder.UncheckedSendableBox`).
    private struct ModelBox: @unchecked Sendable { let model: MLModel }

    /// Loads the model once and keeps it; concurrent first callers wait for the same load.
    private actor Loader {
        private var box: ModelBox?
        func get() throws -> ModelBox {
            if let box { return box }
            guard let url = DepthModelRunner.modelURL else { throw RunError.notInstalled }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            do {
                let loaded = ModelBox(model: try MLModel(contentsOf: url, configuration: configuration))
                box = loaded
                return loaded
            } catch {
                throw RunError.loadFailed(error.localizedDescription)
            }
        }
    }
    private static let loader = Loader()

    /// IEEE 754 binary16 -> Float, exactly (zero, subnormals, normals, infinities, NaN).
    static func float(fromHalf bits: UInt16) -> Float {
        let sign: UInt32 = UInt32(bits >> 15) << 31
        let exponent = UInt32((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x3FF)
        switch exponent {
        case 0:
            if mantissa == 0 { return Float(bitPattern: sign) } // +-0
            // Subnormal half: mantissa * 2^-24, exactly representable as a normal Float.
            let value = Float(mantissa) * Float(sign: .plus, exponent: -24, significand: 1)
            return sign == 0 ? value : -value
        case 0x1F:
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13)) // infinity, or NaN with the payload kept
        default:
            return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13)) // rebias 15 -> 127
        }
    }

    struct Output {
        /// Row-major, row 0 = top, UPRIGHT (the input's orientation), larger = nearer.
        let depth: [Float]
        let width: Int
        let height: Int
    }

    /// `image` is the UNEDITED, oriented photo (what `RawDecoder.decode` returns). Heavy work is synchronous and meant for a background task.
    static func run(on image: CIImage) async throws -> Output {
        let model = try await loader.get().model
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { throw RunError.renderFailed }
        let portrait = extent.height > extent.width
        // A realised ~518 px proxy first: for a lazy RAW graph `ProxyBuilder` does the (gated) render once; the rest is cheap.
        let scale = min(1, CGFloat(inputWidth) / max(extent.width, extent.height))
        guard let proxy = await ProxyBuilder.build(image, scale: scale) else { throw RunError.renderFailed }
        var input = proxy
        if portrait { input = input.oriented(.right) } // 90 degrees clockwise: portrait -> landscape
        let e = input.extent
        input = input.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(inputWidth) / e.width, y: CGFloat(inputHeight) / e.height))
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, inputWidth, inputHeight, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        guard let buffer = pixelBuffer, let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw RunError.renderFailed }
        PhotoExporter.context.render(input, to: buffer, bounds: CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight), colorSpace: srgb)
        let result: MLFeatureProvider
        do {
            result = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]))
        } catch {
            throw RunError.predictionFailed(error.localizedDescription)
        }
        guard let depthBuffer = result.featureValue(for: "depth")?.imageBufferValue,
              CVPixelBufferGetPixelFormatType(depthBuffer) == kCVPixelFormatType_OneComponent16Half else { throw RunError.predictionFailed("unexpected model output") }
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }
        let w = CVPixelBufferGetWidth(depthBuffer), h = CVPixelBufferGetHeight(depthBuffer), stride = CVPixelBufferGetBytesPerRow(depthBuffer) / MemoryLayout<UInt16>.size
        // Read the half floats as raw 16-bit words: Swift's `Float16` does not exist on Intel macOS, and the Release build is universal.
        guard let base = CVPixelBufferGetBaseAddress(depthBuffer)?.assumingMemoryBound(to: UInt16.self) else { throw RunError.predictionFailed("no output data") }
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { values[y * w + x] = float(fromHalf: base[y * stride + x]) } }
        guard portrait else { return Output(depth: values, width: w, height: h) }
        // Rotate back: the landscape map (w x h) becomes portrait (h x w); pixel (x, y) goes to (y, w - 1 - x).
        var upright = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { upright[(w - 1 - x) * h + y] = values[y * w + x] } }
        return Output(depth: upright, width: h, height: w)
    }
}
