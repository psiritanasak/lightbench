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

    enum Mode: Sendable {
        case hdr
        case panorama
    }

    var mode: Mode = .hdr
    /// Pixel size of the written file (panorama); `.zero` when not recorded.
    var size: CGSize = .zero
    /// Panorama only: whether the ragged edges were cropped away.
    var cropped = false
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
    case panorama(PanoramaPlan.PlanError)
    /// Two consecutive panorama frames (by shooting order) could not be registered.
    case noOverlap(String, String)
    case sizeMismatch(String)
    case alignmentFailed(String)
    case mergeFailed
    /// The caller passed a different number of orientations than sources (a programming error: refused, never merged unturned).
    case orientationCountMismatch

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
        case .panorama(let error):
            switch error {
            case .tooFewFrames: return "Select at least two overlapping photos to make a panorama."
            case .tooManyFrames(let limit): return "A panorama supports at most \(limit) photos."
            case .implausibleFrame(let i): return "Photo \(i + 1) (in shooting order) lands in an impossible place — the sweep is too wide or too curved for a flat panorama. Try fewer photos, or a narrower sweep."
            case .canvasTooLarge: return "The panorama would be too large to write."
            }
        case .noOverlap(let a, let b): return "Couldn't match “\(a)” with “\(b)”: they need to overlap by at least about half and share detail. Photos taken in a different order, or with too little overlap, can't be joined."
        case .sizeMismatch(let name): return "\"\(name)\" has a different size than the others (after any turning); merging needs photos of identical dimensions."
        case .alignmentFailed(let name): return "Couldn't align \"\(name)\" with the others (not enough matching detail). If the camera was on a tripod, turn off Auto-align."
        case .mergeFailed: return "Couldn't merge these photos."
        case .orientationCountMismatch: return "Couldn't work out how each photo is turned, so nothing was merged."
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
/// Sources are never opened for writing and no sidecar is touched or created (the new file is a fresh photo to this app). The engine itself reads
/// no edit files: a caller may pass each photo's turn/flip (`PhotoOrientation`), which is baked into the output pixels (no Orientation tag); no other
/// edit is applied.
enum PhotoMerger {
    static let filenameSuffix = "-HDR"
    static let proxyLongEdge: CGFloat = 960

    /// `sourceURLs`: 2...`HDRMergeFilter.maxFrames` photos of identical pixel size AFTER `orientations` (one per source, in the same order: each
    /// photo's turn/flip edit, applied exactly after decoding; nil = as stored). `align: false` skips registration (tripod brackets).
    static func mergeHDR(sourceURLs: [URL], align: Bool = true, orientations: [PhotoOrientation]? = nil, into folder: URL) async throws -> MergeOutcome {
        for url in sourceURLs where SourceIntegrity.verdict(forFileAt: url) == .truncated {
            throw PhotoMergeError.incompleteSource(url.lastPathComponent)
        }
        let plan: HDRBracket.Plan
        switch HDRBracket.plan(sourceURLs.map { exposureMetadata(of: $0) }, maxFrames: HDRMergeFilter.maxFrames, gainRange: HDRMergeFilter.gainRange) {
        case .success(let p): plan = p
        case .failure(let error): throw PhotoMergeError.plan(error)
        }

        var frames: [CIImage] = []
        // `orientations` (one per source, same order) turn/flip each frame exactly, right after decode, so the size check, the proxies, the
        // alignment and the warp all work in the orientation the Library shows. A count that does not match is refused (`orientationCountMismatch`), never merged unturned.
        if let orientations, orientations.count != sourceURLs.count { throw PhotoMergeError.orientationCountMismatch }
        let frameOrientations = orientations
        for (i, url) in sourceURLs.enumerated() {
            guard let decoded = await RawDecoder.decode(contentsOf: url, editState: linearDecodeState) else {
                throw PhotoMergeError.unreadableSource(url.lastPathComponent)
            }
            let origin = decoded.transformed(by: CGAffineTransform(translationX: -decoded.extent.minX, y: -decoded.extent.minY))
            frames.append(frameOrientations.map { $0[i].apply(to: origin) } ?? origin)
        }
        let extent = frames[plan.referenceIndex].extent
        for (i, f) in frames.enumerated() where f.extent.size != extent.size {
            throw PhotoMergeError.sizeMismatch(sourceURLs[i].lastPathComponent)
        }
        let referenceURL = sourceURLs[plan.referenceIndex]

        var alignment: [MergeOutcome.FrameAlignment] = []
        var gains: [MergeOutcome.FrameGain] = []
        var mergeFrames: [HDRMergeFilter.Frame] = []
        let referenceProxy = await MergeProxy.render(frames[plan.referenceIndex], longEdge: proxyLongEdge)
        let referenceLuma = referenceProxy.flatMap { MergeAlignment.linearLumaAndValidity(rgbaFloat: $0.rgba, width: $0.width, height: $0.height) }
        for (i, image) in frames.enumerated() {
            if i == plan.referenceIndex {
                mergeFrames.append(.init(image: image, gain: 1))
                continue
            }
            let g = plan.gains[i]
            let targetProxy = await MergeProxy.render(image, longEdge: proxyLongEdge)
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
               let aligned = await MergeProxy.alignedLuma(of: targetProxy, by: align ? proxyHomography : nil, width: referenceProxy.width, height: referenceProxy.height) {
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

    static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()

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
}
