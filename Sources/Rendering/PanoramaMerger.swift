import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import simd

/// Panorama engine: orders the frames by capture time, registers each CONSECUTIVE pair with `FeatureMatcher` (the measured way: Vision's own
/// homography only handles ~1 degree steps), chains the pairs into one map per frame to a shared canvas around the MIDDLE frame (`PanoramaPlan`),
/// matches each frame's exposure to its neighbour (auto-exposure drift: `HDRGainRefinement`), blends the warped frames with a feathered weight, crops
/// the ragged edges to the largest valid rectangle, and writes a NEW half-float TIFF next to the first SELECTED photo. No UI import; call off-main.
///
/// LIMITS (measured/known, docs/ROADMAP_HISTORY.md): a flat (homography) projection is exact only for a camera rotating about its nodal point or a
/// planar scene, and stretches toward wide fields of view — a plan with an implausible frame is refused, not stretched; frames need about 50% overlap
/// (the matcher found no model at ~33% on the synthetic scene); no parallax or moving-subject handling; no lens distortion correction; the blend is a
/// distance-to-edge feather, not a seam search, so a moving subject in an overlap can ghost.
enum PanoramaMerger {
    static let filenameSuffix = "-Pano"
    static let proxyLongEdge: CGFloat = 1600

    static func mergePanorama(sourceURLs: [URL], cropToFill: Bool = true, into folder: URL) async throws -> MergeOutcome {
        guard sourceURLs.count >= 2 else { throw PhotoMergeError.panorama(.tooFewFrames) }
        guard sourceURLs.count <= PanoramaPlan.maxFrames else { throw PhotoMergeError.panorama(.tooManyFrames(limit: PanoramaPlan.maxFrames)) }
        for url in sourceURLs where SourceIntegrity.verdict(forFileAt: url) == .truncated {
            throw PhotoMergeError.incompleteSource(url.lastPathComponent)
        }
        let order = PanoramaPlan.shootingOrder(dates: sourceURLs.map { captureDate(of: $0) }, names: sourceURLs.map(\.lastPathComponent))
        let urls = order.map { sourceURLs[$0] }

        var frames: [CIImage] = []
        for url in urls {
            // The camera's own look (default decode): a panorama is a picture, not radiance data.
            guard let decoded = await RawDecoder.decode(contentsOf: url, editState: EditState()) else { throw PhotoMergeError.unreadableSource(url.lastPathComponent) }
            frames.append(decoded.transformed(by: CGAffineTransform(translationX: -decoded.extent.minX, y: -decoded.extent.minY)))
        }
        let frameRect = CGRect(origin: .zero, size: frames[0].extent.size)
        for (i, f) in frames.enumerated() where f.extent.size != frameRect.size { throw PhotoMergeError.sizeMismatch(urls[i].lastPathComponent) }

        // Register consecutive pairs and measure their exposure ratio, two proxies in memory at a time.
        var pairs: [simd_float3x3] = []
        var pairGains: [Float] = []
        var alignment: [MergeOutcome.FrameAlignment] = []
        guard var previous = await MergeProxy.render(frames[0], longEdge: proxyLongEdge) else { throw PhotoMergeError.unreadableSource(urls[0].lastPathComponent) }
        for k in 0..<(frames.count - 1) {
            guard let next = await MergeProxy.render(frames[k + 1], longEdge: proxyLongEdge) else { throw PhotoMergeError.unreadableSource(urls[k + 1].lastPathComponent) }
            guard let previousGray = MergeAlignment.lumaProxy(rgbaFloat: previous.rgba, width: previous.width, height: previous.height, exposureFactor: 1),
                  let nextGray = MergeAlignment.lumaProxy(rgbaFloat: next.rgba, width: next.width, height: next.height, exposureFactor: 1),
                  let registration = FeatureMatcher.register(target: nextGray, reference: previousGray)
            else { throw PhotoMergeError.noOverlap(urls[k].lastPathComponent, urls[k + 1].lastPathComponent) }
            pairs.append(FeatureMatcher.scaled(registration.homography, by: Float(frameRect.width) / Float(previous.width)))
            alignment.append(.init(name: urls[k + 1].lastPathComponent, inlierCount: registration.inlierCount, matchCount: registration.matchCount))
            let previousLuma = MergeAlignment.linearLumaAndValidity(rgbaFloat: previous.rgba, width: previous.width, height: previous.height)
            if let previousLuma, let aligned = await MergeProxy.alignedLuma(of: next, by: registration.homography, width: previous.width, height: previous.height) {
                pairGains.append(HDRGainRefinement.refine(exifGain: 1, referenceLuma: previousLuma.luma, referencePeak: previousLuma.peak,
                                                          frameLuma: aligned.luma, framePeak: aligned.peak, validity: aligned.validity))
            } else {
                pairGains.append(1)
            }
            previous = next
        }

        let plan: PanoramaPlan.Plan
        switch PanoramaPlan.plan(pairs: pairs, frameWidth: Int(frameRect.width), frameHeight: Int(frameRect.height)) {
        case .success(let p): plan = p
        case .failure(let error): throw PhotoMergeError.panorama(error)
        }
        let gains = PanoramaPlan.exposureGains(pairGains: pairGains, referenceIndex: plan.referenceIndex)
        let canvas = CGRect(x: 0, y: 0, width: plan.canvasWidth, height: plan.canvasHeight)

        // Feathered, exposure-matched, warped frames summed (premultiplied: rgb = sum of w * colour, alpha = sum of w), then divided by the weight.
        let ramp = max(64, 0.2 * min(frameRect.width, frameRect.height))
        let mask = featherMask(size: frameRect.size, ramp: ramp)
        var sum = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)
        for (i, frame) in frames.enumerated() {
            var image = frame
            if i != plan.referenceIndex, gains[i] > 0, abs(gains[i] - 1) > 1e-4 { image = scaleExposure(image, by: 1 / gains[i]) }
            let sourceIn = CIFilter.sourceInCompositing()
            sourceIn.inputImage = image
            sourceIn.backgroundImage = mask
            guard let feathered = sourceIn.outputImage,
                  let warped = MergeAlignment.warped(feathered, by: plan.placements[i].toCanvas, extent: canvas)
            else { throw PhotoMergeError.mergeFailed }
            let add = CIFilter.additionCompositing()
            add.inputImage = warped
            add.backgroundImage = sum
            guard let next = add.outputImage else { throw PhotoMergeError.mergeFailed }
            sum = next
        }
        guard var merged = HDRMergeFilter.finalize(sum: sum, extent: canvas) else { throw PhotoMergeError.mergeFailed }

        var cropped = false
        var outputSize = canvas.size
        if cropToFill, let rect = PanoramaPlan.autoCropRectangle(plan: plan, frameWidth: Int(frameRect.width), frameHeight: Int(frameRect.height)) {
            // `rect` is top-left canvas pixels; Core Image is bottom-left.
            let ciRect = CGRect(x: rect.x, y: plan.canvasHeight - rect.y - rect.height, width: rect.width, height: rect.height)
            merged = merged.cropped(to: ciRect).transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
            outputSize = ciRect.size
            cropped = true
        }

        let tempURL = folder.appendingPathComponent(".\(UUID().uuidString)").appendingPathExtension("tiff")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let output = merged
        let write: @Sendable () throws -> Void = {
            try PhotoExporter.context.writeTIFFRepresentation(of: output, to: tempURL, format: .RGBAh, colorSpace: PhotoMerger.linearSpace, options: [:])
        }
        if urls.contains(where: { RawDecoder.isRaw($0) }) {
            try await RawDecoder.RenderGate.shared.run(write)
        } else {
            try write()
        }
        // Named after the first SELECTED photo (`sourceURLs[0]`), because `MergeModel` writes into ITS folder; the first frame in shooting order could live elsewhere.
        let baseName = (sourceURLs[0].lastPathComponent as NSString).deletingPathExtension + filenameSuffix
        let outputURL = try PhotoEnhancer.commitExclusively(tempURL) {
            PhotoExporter.uniqueFileURL(baseName: baseName, fileExtension: "tiff", in: folder)
        }
        var outcome = MergeOutcome(url: outputURL, frameCount: frames.count, referenceName: urls[plan.referenceIndex].lastPathComponent, alignment: alignment,
                                   gains: zip(urls, gains).enumerated().compactMap { i, pair in i == plan.referenceIndex ? nil : .init(name: pair.0.lastPathComponent, exifGain: 1, usedGain: pair.1) })
        outcome.mode = .panorama
        outcome.size = outputSize
        outcome.cropped = cropped
        return outcome
    }

    // MARK: - Helpers

    /// A `size` image whose ALPHA ramps 0 -> 1 over `ramp` pixels from every edge (colour white): the weight of a pixel in the blend.
    static func featherMask(size: CGSize, ramp: CGFloat) -> CIImage {
        func gradient(from p0: CGPoint, to p1: CGPoint) -> CIImage {
            let g = CIFilter.linearGradient()
            g.point0 = p0
            g.point1 = p1
            g.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            g.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            return g.outputImage ?? CIImage.empty()
        }
        let rect = CGRect(origin: .zero, size: size)
        let ramps = [gradient(from: CGPoint(x: 0, y: 0), to: CGPoint(x: ramp, y: 0)),
                     gradient(from: CGPoint(x: size.width, y: 0), to: CGPoint(x: size.width - ramp, y: 0)),
                     gradient(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: ramp)),
                     gradient(from: CGPoint(x: 0, y: size.height), to: CGPoint(x: 0, y: size.height - ramp))]
        var mask = ramps[0]
        for r in ramps.dropFirst() {
            let m = CIFilter.minimumCompositing()
            m.inputImage = r
            m.backgroundImage = mask
            mask = m.outputImage ?? mask
        }
        return mask.cropped(to: rect)
    }

    /// `image` with its colour multiplied by `factor` (alpha untouched): CIColorMatrix works on un-premultiplied colour.
    static func scaleExposure(_ image: CIImage, by factor: Float) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: CGFloat(factor), y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: CGFloat(factor), z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: CGFloat(factor), w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return f.outputImage ?? image
    }

    /// EXIF capture time (with sub-seconds) of a file, nil when absent.
    static func captureDate(of url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        return PanoramaPlan.parseExifDate(text, subsecond: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String)
    }
}
