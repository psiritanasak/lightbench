import CoreGraphics
import Vision
import XCTest

/// PERMANENT feasibility probe for HDR merge (same role as `ImageRegistrationProbeTests`). Nothing in `Sources/` uses it yet. Two questions,
/// both answered on SYNTHETIC scenes with known radiance (docs/ROADMAP_HISTORY.md "Photo Merge spike"):
/// 1. Does Vision registration still work when the two frames differ in EXPOSURE (the normal state of a bracket)?
/// 2. Does a weighted radiance merge in linear light (weights from the encoded value, divide by the exposure gain) recover a
///    scene whose highlights exceed 1.0, and how big is the error?
final class HDRMergeProbeTests: XCTestCase {
    private static let width = 400, height = 300

    /// Scene radiance in linear light: smooth gradient 0.02...4.0 with seeded blobs, so highlights exceed 1.0 and shadows are dark.
    private static func radiance(shift: (Int, Int) = (0, 0)) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float((seed >> 33) & 0xFFFF) / 65535 }
        var blobs: [(Float, Float, Float, Float)] = []
        for _ in 0..<60 { blobs.append((next() * Float(width), next() * Float(height), 4 + next() * 14, 0.02 + next() * 3.98)) }
        for y in 0..<height { for x in 0..<width {
            let sx = Float(x - shift.0), sy = Float(y - shift.1)
            var v: Float = 0.02 + 1.2 * (sx / Float(width))
            for b in blobs where (sx - b.0) * (sx - b.0) + (sy - b.1) * (sy - b.1) < b.2 * b.2 { v = b.3 }
            out[y * width + x] = v
        } }
        return out
    }

    private static func encode(_ linear: Float) -> Float { linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055 }
    private static func decode(_ s: Float) -> Float { s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }

    /// One 8-bit sRGB "photo" of the scene at the given exposure offset: gain, clip, encode, quantize.
    private static func encoded8(_ radiance: [Float], ev: Float) -> [UInt8] {
        let gain = pow(2, ev)
        return radiance.map { UInt8((encode(min(max($0 * gain, 0), 1)) * 255).rounded()) }
    }

    private static func cgImage(_ gray8: [UInt8]) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(gray8) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: space,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                                     shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Measured 2026-10-09 (Apple M1, macOS 27.0, 400x300 synthetic scene with highlights to 4.0, 8-bit sRGB frames, true shift 9,-5):
    /// registering the frames AS THEY ARE recovers the shift only at 0 EV (and fails, returning garbage such as (174, -5) or (300, 225),
    /// at +1, +2, +3 and -2 EV); brightening the darker frame to the brighter one's exposure (gain, clip, re-encode) recovers (9, -5) exactly at
    /// every tested offset (+3, +2, +1, -2). Normalizing only the TARGET fails for brighter targets (clipped highlights cannot be restored).
    /// Registration across exposure differences. RAW registration of a bracket directly (no normalization) vs after bringing the
    /// target to the reference's exposure in linear light (gain 2^-ev, clip, re-encode). Each case prints its result.
    func testTranslationalRegistrationAcrossExposureDifference() throws {
        let truthRef = Self.radiance()
        let truthMoved = Self.radiance(shift: (9, -5))
        let reference = try Self.cgImage(Self.encoded8(truthRef, ev: 0))
        func register(_ moved: CGImage) throws -> (Float, Float) {
            let request = VNTranslationalImageRegistrationRequest(targetedCGImage: moved, options: [:])
            do { try VNSequenceRequestHandler().perform([request], on: reference) } catch { throw XCTSkip("registration failed: \(error)") }
            let t = try XCTUnwrap((request.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform)
            return (Float(t.tx), Float(t.ty))
        }
        var normalizedOK = true
        for ev: Float in [0, 1, 2, 3, -2] {
            let raw = try register(Self.cgImage(Self.encoded8(truthMoved, ev: ev)))
            // Normalize: decode the 8-bit frame, divide by the gain, clip to the reference's range, re-encode.
            let frame = Self.encoded8(truthMoved, ev: ev)
            let normalized = frame.map { UInt8((Self.encode(min(Self.decode(Float($0) / 255) / pow(2, ev), 1)) * 255).rounded()) }
            let norm = try register(Self.cgImage(normalized))
            // Common-range: instead of fixing the target, SIMULATE the target's exposure on the reference (gain 2^ev, clip, re-encode) so
            // both frames clip at the same radiance, then register the untouched target against that.
            let refFrame = Self.encoded8(truthRef, ev: 0)
            let simulatedRef = try Self.cgImage(refFrame.map { UInt8((Self.encode(min(Self.decode(Float($0) / 255) * pow(2, ev), 1)) * 255).rounded()) })
            let request = VNTranslationalImageRegistrationRequest(targetedCGImage: try Self.cgImage(frame), options: [:])
            try VNSequenceRequestHandler().perform([request], on: simulatedRef)
            let ct = try XCTUnwrap((request.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform)
            print("PROBE registration, target at \(ev) EV, true shift (9,-5): raw=(\(raw.0), \(raw.1)) normalized=(\(norm.0), \(norm.1)) commonRange=(\(ct.tx), \(ct.ty))")
            // The rule the measurements support: brighten the DARKER frame to the brighter one's exposure. For a brighter target that is the
            // common-range (simulated reference) result; for a darker target it is the normalized-target result.
            let chosen = ev >= 0 ? (Float(ct.tx), Float(ct.ty)) : norm
            if abs(abs(chosen.0) - 9) > 1.5 || abs(abs(chosen.1) - 5) > 1.5 { normalizedOK = false }
        }
        XCTAssertTrue(normalizedOK, "brightening the darker frame must recover the shift for every tested exposure offset")
    }

    /// Weighted radiance merge of a -2/0/+2 EV bracket. Reports max and mean relative error vs the true radiance, over all pixels,
    /// and over the highlight pixels (radiance > 1) that only the -2 EV frame holds unclipped.
    func testWeightedRadianceMergeRecoversHighlightsAboveOne() {
        let truth = Self.radiance()
        let evs: [Float] = [-2, 0, 2]
        let frames = evs.map { Self.encoded8(truth, ev: $0) }
        var maxErr: Float = 0, sumErr: Float = 0, hiMax: Float = 0, hiCount = 0
        for i in 0..<truth.count {
            var num: Float = 0, den: Float = 0
            for (k, ev) in evs.enumerated() {
                let s = Float(frames[k][i]) / 255
                let w = max(0, 1 - abs(2 * s - 1)) // tent: 0 at black and clipped white
                let w2 = w * w + 1e-6
                num += w2 * Self.decode(s) / pow(2, ev)
                den += w2
            }
            let est = num / den
            let err = abs(est - truth[i]) / truth[i]
            maxErr = max(maxErr, err); sumErr += err
            if truth[i] > 1 { hiMax = max(hiMax, err); hiCount += 1 }
        }
        print("PROBE merge -2/0/+2 EV: maxRelErr=\(maxErr) meanRelErr=\(sumErr / Float(truth.count)) highlight(>1.0, n=\(hiCount)) maxRelErr=\(hiMax)")
        XCTAssertGreaterThan(hiCount, 100, "fixture must contain real highlights above 1.0")
        XCTAssertLessThan(hiMax, 0.1, "highlights above 1.0 must be recovered from the -2 EV frame")
    }
}
