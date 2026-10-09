import CoreImage

/// Merges already-ALIGNED bracket frames into one linear HDR image on the GPU (`HDRAccumulate` / `HDRFinalize` kernels; maths in
/// `HDRMergeMath`). Alignment and warping are the caller's job: each frame must already be in the reference frame's pixel grid, with
/// alpha 0 wherever the warp left no data (Core Image's `transformed(by:)` does that outside the source extent only if the frame is
/// composited over a transparent canvas / cropped to the reference extent by the caller).
enum HDRMergeFilter {
    struct Frame {
        let image: CIImage
        /// 2^EV relative to the reference frame (the reference has gain 1).
        let gain: Float
    }

    /// Power-of-two scale of the packed accumulator (see `HDRAccumulate.cikernel`: lifts the weight sum out of half-float's subnormal range;
    /// dark pixels stay imprecise below ~1e-4). Limits: at most `maxFrames` frames and gains within 1/16...16 so the packed RGB stays below
    /// half-float's 65504 (about 31.7k worst case at this scale).
    static let packingScale: Float = 1024
    static let maxFrames = 9
    static let gainRange: ClosedRange<Float> = (1.0 / 16)...16

    /// Lazy merged image cropped to `extent`, or nil when a kernel is unavailable, `frames` is empty or beyond `maxFrames`, or a gain is outside
    /// `gainRange`. Values above 1.0 are preserved. `materializeBetweenPasses` forces a separate render buffer after every accumulate pass
    /// (what Core Image may choose to do on its own); tests use it to prove the result does not depend on that choice.
    static func merge(_ frames: [Frame], extent: CGRect, materializeBetweenPasses: Bool = false) -> CIImage? {
        guard !frames.isEmpty, frames.count <= maxFrames, frames.allSatisfy({ gainRange.contains($0.gain) }),
              let accumulate = accumulateKernel, let finalize = finalizeKernel else { return nil }
        var acc = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        for frame in frames {
            guard var next = accumulate.apply(extent: extent, arguments: [acc, frame.image, frame.gain, packingScale]) else { return nil }
            if materializeBetweenPasses { next = next.insertingIntermediate(cache: false) }
            acc = next
        }
        return finalize.apply(extent: extent, arguments: [acc])?.cropped(to: extent)
    }

    /// The finalize step alone: turns a PREMULTIPLIED sum image (rgb = sum of w * colour, alpha = sum of w) into the weighted mean colour, alpha 1
    /// where anything contributed. `PanoramaMerger` feeds it a sum of feathered, warped frames.
    static func finalize(sum: CIImage, extent: CGRect) -> CIImage? {
        finalizeKernel?.apply(extent: extent, arguments: [sum])?.cropped(to: extent)
    }

    private static func kernel(named name: String) -> CIColorKernel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "cikernel"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return CIColorKernel(source: source)
    }

    private static let accumulateKernel = kernel(named: "HDRAccumulate")
    private static let finalizeKernel = kernel(named: "HDRFinalize")
}
