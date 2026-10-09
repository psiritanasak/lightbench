import CoreImage
import Foundation
import ImageIO
import simd

struct MergeOutcome: Sendable {
    struct FrameAlignment: Sendable {
        let name: String
        let inlierCount: Int
        let matchCount: Int
    }

    /// The exposure gain used for one non-reference frame: what EXIF implied and what was measured from the aligned image data and used.
    struct FrameGain: Sendable {
        let name: String
        let exifGain: Float
        let usedGain: Float
        /// Relative difference, e.g. 0.12 = the measured gain is 12% above the EXIF one.
        var correction: Float { usedGain / exifGain - 1 }
    }

    let url: URL
    let frameCount: Int
    let referenceName: String
    /// One entry per NON-reference frame when alignment ran; empty when alignment was turned off.
    let alignment: [FrameAlignment]
    /// One entry per NON-reference frame, always.
    var gains: [FrameGain] = []
}

enum PhotoMergeError: LocalizedError {
    case unreadableSource(String)
    case incompleteSource(String)
    case plan(HDRBracket.PlanError)
    case sizeMismatch(String)
    case alignmentFailed(String)
    case mergeFailed

    var errorDescription: String? {
        switch self {
        case .unreadableSource(let name): return "Couldn't read \"\(name)\"."
        case .incompleteSource(let name): return "\"\(name)\" looks cut off (an incomplete or damaged file), so it can't be merged. Nothing was written."
        case .plan(let error):
            switch error {
            case .tooFewFrames: return "Select at least two photos taken at different exposures."
            case .tooManyFrames(let limit): return "HDR merge supports at most \(limit) photos."
            case .missingExposureData(let i): return "Photo \(i + 1) has no shutter / aperture / ISO information, so its exposure is unknown."
            case .gainOutOfRange(let i): return "Photo \(i + 1) is more than 4 stops away from the middle exposure; HDR merge supports up to 4."
            case .noExposureDifference: return "These photos all have the same exposure, so there is nothing to merge. Select a bracket (different shutter speeds)."
            }
        case .sizeMismatch(let name): return "\"\(name)\" has a different size than the others; HDR merge needs photos of identical dimensions."
        case .alignmentFailed(let name): return "Couldn't align \"\(name)\" with the others (not enough matching detail). If the camera was on a tripod, turn off Auto-align."
        case .mergeFailed: return "Couldn't merge these photos."
        }
    }
}

/// HDR bracket merge engine: reads each source's exposure, picks the middle exposure as reference, aligns the other frames to it
/// (`FeatureMatcher` on exposure-matched proxies, then a perspective warp), merges them in linear light on the GPU (`HDRMergeFilter`) and writes the
/// result as a NEW half-float TIFF next to the reference photo. No UI import; call off-main.
///
/// The output is a HALF-FLOAT TIFF, not the 16-bit integer TIFF the plan first assumed: measured in `FloatTIFFProbeTests`, an integer RGBA16 TIFF
/// clips linear 3.0 to 1.0, while half-float and float32 TIFFs return exact values through `RawDecoder.decode`, so the merged highlights stay
/// recoverable by later edits. Files are large (about 8 bytes per pixel before the container: ~190 MB for 24 MP) — callers should say so.
///
/// RAW sources are decoded with their tone-shaping fields neutralised (`linearDecodeState`); that is NOT yet measured on a real RAW.
///
/// Sources are never opened for writing and no sidecar is touched or created (the new file is a fresh photo to this app).
enum PhotoMerger {
    static let filenameSuffix = "-HDR"
    static let proxyLongEdge: CGFloat = 960

    /// `sourceURLs`: 2...`HDRMergeFilter.maxFrames` photos of identical pixel size. `align: false` skips registration (tripod brackets).
    static func mergeHDR(sourceURLs: [URL], align: Bool = true, into folder: URL) async throws -> MergeOutcome {
        for url in sourceURLs where SourceIntegrity.verdict(forFileAt: url) == .truncated {
            throw PhotoMergeError.incompleteSource(url.lastPathComponent)
        }
        let plan: HDRBracket.Plan
        switch HDRBracket.plan(sourceURLs.map { exposureMetadata(of: $0) }, maxFrames: HDRMergeFilter.maxFrames, gainRange: HDRMergeFilter.gainRange) {
        case .success(let p): plan = p
        case .failure(let error): throw PhotoMergeError.plan(error)
        }

        var frames: [CIImage] = []
        for url in sourceURLs {
            guard let decoded = await RawDecoder.decode(contentsOf: url, editState: linearDecodeState) else {
                throw PhotoMergeError.unreadableSource(url.lastPathComponent)
            }
            frames.append(decoded.transformed(by: CGAffineTransform(translationX: -decoded.extent.minX, y: -decoded.extent.minY)))
        }
        let extent = frames[plan.referenceIndex].extent
        for (i, f) in frames.enumerated() where f.extent.size != extent.size {
            throw PhotoMergeError.sizeMismatch(sourceURLs[i].lastPathComponent)
        }
        let referenceURL = sourceURLs[plan.referenceIndex]

        var alignment: [MergeOutcome.FrameAlignment] = []
        var gains: [MergeOutcome.FrameGain] = []
        var mergeFrames: [HDRMergeFilter.Frame] = []
        let referenceProxy = await renderedProxy(of: frames[plan.referenceIndex])
        let referenceLuma = referenceProxy.flatMap { MergeAlignment.linearLumaAndValidity(rgbaFloat: $0.rgba, width: $0.width, height: $0.height) }
        for (i, image) in frames.enumerated() {
            if i == plan.referenceIndex {
                mergeFrames.append(.init(image: image, gain: 1))
                continue
            }
            let g = plan.gains[i]
            let targetProxy = await renderedProxy(of: image)
            var frameImage = image
            var proxyHomography = matrix_identity_float3x3
            if align {
                guard let referenceProxy, let targetProxy,
                      // Brighten the DARKER frame to the brighter one's exposure before matching (measured requirement).
                      let refGray = MergeAlignment.lumaProxy(rgbaFloat: referenceProxy.rgba, width: referenceProxy.width, height: referenceProxy.height, exposureFactor: max(g, 1)),
                      let targetGray = MergeAlignment.lumaProxy(rgbaFloat: targetProxy.rgba, width: targetProxy.width, height: targetProxy.height, exposureFactor: max(1 / g, 1)),
                      let registration = FeatureMatcher.register(target: targetGray, reference: refGray)
                else { throw PhotoMergeError.alignmentFailed(sourceURLs[i].lastPathComponent) }
                proxyHomography = registration.homography
                let full = FeatureMatcher.scaled(registration.homography, by: Float(extent.width) / Float(referenceProxy.width))
                guard let warped = MergeAlignment.warped(image, by: full, extent: extent) else {
                    throw PhotoMergeError.alignmentFailed(sourceURLs[i].lastPathComponent)
                }
                frameImage = warped
                alignment.append(.init(name: sourceURLs[i].lastPathComponent, inlierCount: registration.inlierCount, matchCount: registration.matchCount))
            }
            // Measure the frame's real gain on the aligned proxies; EXIF is the fallback (see `HDRGainRefinement`).
            var usedGain = g
            if let referenceProxy, let referenceLuma, let targetProxy,
               let aligned = await alignedLuma(of: targetProxy, by: align ? proxyHomography : nil, width: referenceProxy.width, height: referenceProxy.height) {
                usedGain = HDRGainRefinement.refine(
                    exifGain: g, referenceLuma: referenceLuma.luma, referencePeak: referenceLuma.peak,
                    frameLuma: aligned.luma, framePeak: aligned.peak, validity: aligned.validity
                )
            }
            gains.append(.init(name: sourceURLs[i].lastPathComponent, exifGain: g, usedGain: usedGain))
            mergeFrames.append(.init(image: frameImage, gain: usedGain))
        }
        guard let merged = HDRMergeFilter.merge(mergeFrames, extent: extent) else { throw PhotoMergeError.mergeFailed }

        let tempURL = folder.appendingPathComponent(".\(UUID().uuidString)").appendingPathExtension("tiff")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let write: @Sendable () throws -> Void = {
            try PhotoExporter.context.writeTIFFRepresentation(of: merged, to: tempURL, format: .RGBAh, colorSpace: linearSpace, options: [:])
        }
        if sourceURLs.contains(where: { RawDecoder.isRaw($0) }) {
            try await RawDecoder.RenderGate.shared.run(write)
        } else {
            try write()
        }
        let baseName = (referenceURL.lastPathComponent as NSString).deletingPathExtension + filenameSuffix
        let outputURL = try PhotoEnhancer.commitExclusively(tempURL) {
            PhotoExporter.uniqueFileURL(baseName: baseName, fileExtension: "tiff", in: folder)
        }
        return MergeOutcome(url: outputURL, frameCount: frames.count, referenceName: referenceURL.lastPathComponent, alignment: alignment, gains: gains)
    }

    // MARK: - Helpers

    /// The decode settings for merge sources. The merge model (`x / gain`, `HDRMergeMath`) needs pixel values PROPORTIONAL to exposure, but a default
    /// `CIRAWFilter` decode applies the camera's global tone curve (`boostAmount` 1), shadow boost, contrast, sharpening and detail, which compress the
    /// brighter frame's midtones and highlights unevenly — the frames then disagree after dividing by their gains and the merge shows tonal steps
    /// where the weights hand over (reviewer-found). So the tone-shaping RAW fields are zeroed; noise reduction, moire and the decoder-version pin are
    /// left at their defaults (they do not change the transfer curve). NOT yet measured on a real RAW file (none in the repo or tests): this pins
    /// the intent and is a no-op for non-RAW sources. JPEG/HEIC sources are used AS DECODED and carry the camera's own tone curve, so a bracket of
    /// those is only approximately linear — the synthetic test figure (pure sRGB encoding) is the best case.
    static let linearDecodeState: EditState = {
        var state = EditState()
        state.boostAmount = 0
        state.shadowBoostScale = 0
        state.rawSharpnessScale = 0
        state.rawContrastAdjust = -1
        state.rawDetailAdjust = -3
        return state
    }()

    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// EXIF shutter, aperture and ISO of a file (nil members when absent).
    static func exposureMetadata(of url: URL) -> HDRBracket.ExposureMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return HDRBracket.ExposureMetadata() }
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue
        return HDRBracket.ExposureMetadata(
            exposureTime: (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue,
            fNumber: (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue,
            iso: iso
        )
    }

    private struct ProxyBitmap {
        let width: Int
        let height: Int
        let rgba: [Float]
        /// The realised proxy image (origin 0,0), kept so it can be warped again without rebuilding it.
        let image: CIImage
    }

    /// Linear luminance and coverage of `proxy` after warping it by the PROXY-space homography `h` (nil = as is) onto a `width x height` canvas.
    private static func alignedLuma(of proxy: ProxyBitmap, by h: simd_float3x3?, width: Int, height: Int) async -> (luma: [Float], peak: [Float], validity: [Float])? {
        guard proxy.width == width, proxy.height == height else { return nil }
        guard let h else { return MergeAlignment.linearLumaAndValidity(rgbaFloat: proxy.rgba, width: width, height: height) }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        guard let warped = MergeAlignment.warped(proxy.image, by: h, extent: canvas) else { return nil }
        var buffer = [Float](repeating: 0, count: width * height * 4)
        PhotoExporter.context.render(warped, toBitmap: &buffer, rowBytes: width * 16, bounds: canvas, format: .RGBAf, colorSpace: linearSpace)
        PhotoExporter.context.clearCaches() // proxy-sized, but keep the shared context from holding intermediates (same finding as ProxyBuilder)
        return MergeAlignment.linearLumaAndValidity(rgbaFloat: buffer, width: width, height: height)
    }

    /// A ~960 px linear RGBAf bitmap of `image` (top row first), built through `ProxyBuilder` (which routes a RAW render through `RenderGate`).
    private static func renderedProxy(of image: CIImage) async -> ProxyBitmap? {
        let longEdge = max(image.extent.width, image.extent.height)
        let scale = min(1, proxyLongEdge / longEdge)
        guard let proxy = await ProxyBuilder.build(image, scale: scale) else { return nil }
        let w = Int(proxy.extent.width), h = Int(proxy.extent.height)
        var buffer = [Float](repeating: 0, count: w * h * 4)
        PhotoExporter.context.render(proxy, toBitmap: &buffer, rowBytes: w * 16, bounds: proxy.extent, format: .RGBAf, colorSpace: linearSpace)
        return ProxyBitmap(width: w, height: h, rgba: buffer, image: proxy)
    }
}
