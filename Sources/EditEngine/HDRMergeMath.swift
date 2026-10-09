import Foundation
import simd

/// Pure reference math for the HDR bracket merge: a weighted radiance average in LINEAR light.
/// `HDRAccumulate.cikernel` / `HDRFinalize.cikernel` run the same arithmetic per pixel on the GPU and must agree with this file
/// (`HDRMergeFilterTests` checks that); this copy exists so the maths is testable with exact numbers.
///
/// Model (docs/ROADMAP_HISTORY.md, "Photo Merge spike": 1.1% max / 0.37% mean relative error on a synthetic -2/0/+2 EV bracket,
/// highlights above 1.0 recovered to 0.75%): each frame i, aligned to the reference, holds linear values `x_i` taken with exposure gain
/// `g_i` (2^EV relative to the reference). Its estimate of scene radiance is `x_i / g_i`. The merge is the weight-averaged estimate
///
///     radiance = sum_i w_i * x_i / g_i  /  sum_i w_i
///
/// where `w_i` is a "well-exposedness" weight computed from the frame's own pixel: the largest channel is clamped to 0...1, encoded with
/// the sRGB curve, and fed to a tent (0 at black and at clipped white, 1 at mid-grey) that is then squared; a tiny floor keeps a pixel that
/// is clipped in EVERY frame defined (it then averages them instead of dividing by zero). Using the LARGEST channel means a pixel with
/// one blown channel is down-weighted as a whole, which avoids hue shifts from partially clipped pixels. Frame `validity` (0...1, the alpha
/// of the warped frame: 0 outside the frame after alignment) scales the weight, so a missing frame contributes nothing there.
enum HDRMergeMath {
    /// Floor added to every valid frame's weight; also the weight of a pixel that is exactly black or clipped.
    static let weightFloor: Float = 1e-6

    static func srgbEncode(_ linear: Float) -> Float {
        linear <= 0.0031308 ? 12.92 * linear : 1.055 * powf(linear, 1 / 2.4) - 0.055
    }

    /// Weight of one frame's pixel (`linear` is its un-premultiplied RGB), times `validity`.
    static func weight(linear: SIMD3<Float>, validity: Float = 1) -> Float {
        let peak = min(max(max(linear.x, max(linear.y, linear.z)), 0), 1)
        let tent = max(0, 1 - abs(2 * srgbEncode(peak) - 1))
        return (tent * tent + weightFloor) * validity
    }

    struct Sample {
        let linear: SIMD3<Float>
        /// 2^EV of this frame relative to the reference frame.
        let gain: Float
        let validity: Float

        init(linear: SIMD3<Float>, gain: Float, validity: Float = 1) {
            self.linear = linear
            self.gain = gain
            self.validity = validity
        }
    }

    /// Merged linear radiance in the reference frame's exposure, or nil if no sample has any weight.
    static func merge(_ samples: [Sample]) -> SIMD3<Float>? {
        var numerator = SIMD3<Float>(repeating: 0)
        var denominator: Float = 0
        for s in samples where s.gain > 0 && s.validity > 0 {
            let w = weight(linear: s.linear, validity: s.validity)
            numerator += w * s.linear / s.gain
            denominator += w
        }
        return denominator > 0 ? numerator / denominator : nil
    }
}
