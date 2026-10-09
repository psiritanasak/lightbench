import Foundation
import simd

/// Measures a bracket frame's exposure gain from the image data, to correct what the EXIF numbers imply.
///
/// EXIF shutter / aperture / ISO give a gain `g = brightness_frame / brightness_reference`, but cameras are not that exact (a real Nikon D610 RAW
/// pair at 1/400 s vs 1/200 s, f/5, ISO 160, measured about 12% brighter than the EXIF 2.0x across all midtones: docs/ROADMAP_HISTORY.md Stage 2b).
/// The merge divides each frame by its gain, so a gain that is off by 12% leaves a 12% step wherever the frame weights hand over.
///
/// The estimate is a WEIGHTED MEDIAN of the per-pixel ratio `frame luma / reference luma`, each pixel weighted by the product of the two frames'
/// merge weights (`HDRMergeMath.weight`: the largest channel through the sRGB tent). That is deliberate (reviewer-found): the weights fall to zero
/// at black AND at clipped white, per CHANNEL via the largest one, so pixels with one blown channel (blue sky) and the noise-dominated, non-proportional
/// dark tones (a real RAW's ratio is 2.6x/1.6x/1.2x at its 5/10/20th luminance percentiles) barely count, there is no hard luminance window whose edges
/// bias the ratio toward 1 (only a cutoff at a combined weight of 1e-3, where weights are already tiny), and the gain is measured where the frames' weights actually hand over — the only place a gain error shows. The median
/// is robust to moving subjects and small misregistration. A measurement more than `maxDeviation` from the EXIF gain is rejected (wrong scene, failed
/// alignment), as is one with too little weight.
enum HDRGainRefinement {
    static let maxDeviation: Float = 0.25
    /// A pixel's combined weight must reach this to be a sample at all (the product of the two frames' squared tents, i.e. a tent product of about 0.03).
    static let minimumPixelWeight: Float = 1e-3
    /// At least this many samples, and this fraction of the pixels.
    static let minimumSamples = 1000
    static let minimumUsableFraction = 0.02

    /// - Parameters:
    ///   - exifGain: gain from `HDRBracket` (frame brightness / reference brightness).
    ///   - referenceLuma / referencePeak: LINEAR luminance and largest channel of the reference.
    ///   - frameLuma / framePeak: the same for the frame warped onto the reference (same size and order).
    ///   - validity: coverage of the warped frame (0...1); only pixels with validity >= 0.99 count.
    /// - Returns: the measured gain, or `exifGain` when the measurement is thin or implausible.
    static func refine(
        exifGain: Float, referenceLuma: [Float], referencePeak: [Float], frameLuma: [Float], framePeak: [Float], validity: [Float]
    ) -> Float {
        let n = referenceLuma.count
        guard exifGain > 0, exifGain.isFinite, referencePeak.count == n, frameLuma.count == n, framePeak.count == n, validity.count == n else { return exifGain }
        var samples: [(ratio: Float, weight: Float)] = []
        samples.reserveCapacity(n / 4)
        for i in 0..<n {
            let a = referenceLuma[i], f = frameLuma[i]
            guard validity[i] >= 0.99, a.isFinite, f.isFinite, a > 0, f > 0, referencePeak[i].isFinite, framePeak[i].isFinite else { continue }
            let w = HDRMergeMath.weight(linear: SIMD3(repeating: referencePeak[i])) * HDRMergeMath.weight(linear: SIMD3(repeating: framePeak[i]))
            guard w >= minimumPixelWeight else { continue }
            let r = f / a
            if r > exifGain / 2, r < exifGain * 2 { samples.append((r, w)) } // a wild ratio is a different object / a motion edge, not exposure
        }
        guard samples.count >= minimumSamples, Double(samples.count) >= minimumUsableFraction * Double(n) else { return exifGain }
        samples.sort { $0.ratio < $1.ratio }
        let half = samples.reduce(Float(0)) { $0 + $1.weight } / 2
        var running: Float = 0
        var median = samples[samples.count - 1].ratio
        for s in samples {
            running += s.weight
            if running >= half { median = s.ratio; break }
        }
        guard abs(median / exifGain - 1) <= maxDeviation else { return exifGain }
        return median
    }
}
