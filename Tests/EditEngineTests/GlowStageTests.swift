import CoreImage
import XCTest
@testable import PhotoApp

/// The Style's Glow stage (`EditPipeline.applyGlow`): a highlight bloom from stock Core Image filters.
final class GlowStageTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])

    /// A dark field (0.02) with a bright square (0.9) in the middle.
    private func scene(size: Int = 400, alpha: Double = 1) -> CIImage {
        let dark = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02, alpha: alpha, colorSpace: linearSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let q = size / 4
        let bright = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: alpha, colorSpace: linearSpace)!)
            .cropped(to: CGRect(x: size / 2 - q / 2, y: size / 2 - q / 2, width: q, height: q))
        return bright.composited(over: dark)
    }

    private func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> SIMD4<Float> {
        var b = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: linearSpace)
        return SIMD4(b[0], b[1], b[2], b[3])
    }

    private func glow(_ amount: Double = 1) -> EditState {
        var s = EditState(); s.styleTexture = "glow"; s.styleTextureAmount = amount
        return s
    }

    func testGlowBleedsLightIntoTheDarkSurroundingsAndLeavesTheFarFieldAlone() {
        let input = scene()
        let base = EditPipeline.apply(EditState(), to: input)
        let lit = EditPipeline.apply(glow(), to: input)
        // The bright square's edge is at x = 250. MEASURED falloff of the final stage on this scene (base 0.02): +0.0735 at
        // 2 px outside, +0.0247 at 10 px, +0.0064 at 20 px, nothing from ~50 px out.
        let near = pixel(lit, 260, 200).x, nearBase = pixel(base, 260, 200).x
        XCTAssertGreaterThan(near, nearBase + 0.015, "light must bleed outside the highlight (\(nearBase) -> \(near))")
        XCTAssertGreaterThan(pixel(lit, 252, 200).x, near, "the bloom is strongest at the highlight's edge and falls off")
        XCTAssertEqual(pixel(lit, 300, 200).x, pixel(base, 300, 200).x, accuracy: 0.002, "50 px out the bloom has faded")
        let far = pixel(lit, 5, 5).x, farBase = pixel(base, 5, 5).x
        XCTAssertEqual(far, farBase, accuracy: 0.004, "the far field must be untouched")
    }

    func testGlowAlsoBrightensTheHighlightItself() {
        let input = scene()
        XCTAssertGreaterThan(pixel(EditPipeline.apply(glow(), to: input), 200, 200).x, pixel(EditPipeline.apply(EditState(), to: input), 200, 200).x)
    }

    func testStrengthScalesTheBloomAndZeroIsExactlyOff() {
        let input = scene()
        let base = pixel(EditPipeline.apply(EditState(), to: input), 260, 200).x
        let half = pixel(EditPipeline.apply(glow(0.5), to: input), 260, 200).x - base
        let full = pixel(EditPipeline.apply(glow(1), to: input), 260, 200).x - base
        XCTAssertGreaterThan(full, half * 1.5, "more strength, clearly more bloom (\(half) vs \(full))")
        XCTAssertGreaterThan(half, 0)
        let off = pixel(EditPipeline.apply(glow(0), to: input), 260, 200)
        XCTAssertEqual(off.x, base, accuracy: 0, "amount 0 renders exactly like no style")
    }

    func testFlatImagesBelowTheThresholdAreUntouched() {
        let flat = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1, colorSpace: linearSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(pixel(EditPipeline.apply(glow(), to: flat), 100, 100).x, pixel(EditPipeline.apply(EditState(), to: flat), 100, 100).x, accuracy: 0.0005)
    }

    func testAlphaIsPreservedAndSceneHeadroomAboveOneSurvives() {
        let translucent = EditPipeline.apply(glow(), to: scene(alpha: 0.5))
        // MEASURED through the FULL pipeline: alpha is exactly 0.5 away from the bloom and 0.5025 at (260, 200). The source of
        // that 0.0025 is NOT isolated: `applyGlow` run alone restores alpha exactly (reviewer's standalone copy), and this state
        // also carries the style's own small negative-Clarity nudge, a blur-based stage that runs across the alpha boundary.
        // So the bound is 0.005, and the claim is only that the drift stays small.
        XCTAssertEqual(pixel(translucent, 260, 200).w, 0.5, accuracy: 0.005)
        XCTAssertEqual(pixel(translucent, 5, 5).w, 0.5, accuracy: 0.002)
        let hot = CIImage(color: CIColor(red: 3, green: 3, blue: 3, alpha: 1, colorSpace: linearSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertGreaterThan(pixel(EditPipeline.apply(glow(), to: hot), 100, 100).x, 3.0, "additive bloom must not clamp highlights to 1")
    }

    /// A scene value of 40 must bloom no more than the stage's own gain allows (0.6 at full strength): a boundedness check.
    /// About the mask's upper clamp (`CIColorClamp.maxComponents`, default (1,1,1,1) so deleting the line is a no-op): through
    /// the REAL pipeline, raising it to 100 or 1000 gives bit-identical output here (measured 0.1555 both ways), i.e. no
    /// perceptual value above 1 reaches it on this input; a standalone copy of the stage that SKIPPED `encodeToPerceptual` did
    /// show a large difference (reviewer: 22.3 vs 0.095). So the clamp is defense in depth, not covered by any test.
    func testAVeryHotHighlightBloomsNoMoreThanTheGainAllows() {
        let dark = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02, colorSpace: linearSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
        let hot = CIImage(color: CIColor(red: 40, green: 40, blue: 40, colorSpace: linearSpace)!).cropped(to: CGRect(x: 150, y: 150, width: 100, height: 100))
        let input = hot.composited(over: dark)
        let added = pixel(EditPipeline.apply(glow(), to: input), 252, 200).x - pixel(EditPipeline.apply(EditState(), to: input), 252, 200).x
        XCTAssertLessThan(added, 0.7, "the bloom stays within the gain (0.6); measured \(added)")
        XCTAssertGreaterThan(added, 0.05)
    }

    func testWorksOnACroppedExtentWithANonZeroOrigin() {
        let shifted = scene().transformed(by: CGAffineTransform(translationX: 500, y: 300))
        let a = EditPipeline.apply(glow(), to: scene())
        let b = EditPipeline.apply(glow(), to: shifted)
        XCTAssertEqual(b.extent, shifted.extent)
        XCTAssertEqual(pixel(b, 760, 500).x, pixel(a, 260, 200).x, accuracy: 0.002, "the bloom must not depend on where the extent sits")
    }

    func testTinyImagesAreLeftAlone() {
        let tiny = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1, colorSpace: linearSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertEqual(pixel(EditPipeline.apply(glow(), to: tiny), 2, 2).x, pixel(EditPipeline.apply(EditState(), to: tiny), 2, 2).x, accuracy: 0.0005)
    }

    func testBloomIsResolutionConsistentAcrossSizes() {
        // The same picture at 200/400/800 px: the bloom 3% of the frame outside the square's edge must match (the blur radius is
        // an extent fraction). A fixed-pixel-radius stage gives different lifts at different sizes; the lift must be clearly > 0.
        func lift(_ size: Int) -> Float {
            let x = size / 2 + size / 8 + Int(Double(size) * 0.03)
            return pixel(EditPipeline.apply(glow(), to: scene(size: size)), x, size / 2).x - pixel(EditPipeline.apply(EditState(), to: scene(size: size)), x, size / 2).x
        }
        let a = lift(200), b = lift(400), c = lift(800)
        XCTAssertGreaterThan(b, 0.02, "the bloom is really there at this distance: \(a) \(b) \(c)")
        XCTAssertEqual(a, b, accuracy: 0.02, "200 vs 400: \(a) \(b) \(c)")
        XCTAssertEqual(c, b, accuracy: 0.02, "800 vs 400: \(a) \(b) \(c)")
    }

    /// A side that is not a multiple of 4 (and a non-zero origin) must not fade the bloom along the right/top edge (the
    /// fractional edge pixel of the downscaled layer used to be blurred inward). A flat bright field blooms uniformly.
    func testBloomDoesNotFadeAtTheEdgesOfAnOddSizedCroppedImage() {
        let w = 401, h = 403
        let flat = CIImage(color: CIColor(red: 0.95, green: 0.95, blue: 0.95, colorSpace: linearSpace)!)
            .cropped(to: CGRect(x: 13, y: 7, width: w, height: h))
        let out = EditPipeline.apply(glow(), to: flat)
        let interior = pixel(out, 13 + w / 2, 7 + h / 2).x
        XCTAssertGreaterThan(interior, 1.2, "the field really blooms")
        for (x, y) in [(13 + w - 1, 7 + h / 2), (13 + w - 4, 7 + h - 3), (13 + w / 2, 7 + h - 1), (13 + 1, 7 + 1), (13 + w - 30, 7 + h - 30)] {
            XCTAssertEqual(pixel(out, x, y).x, interior, accuracy: 0.03, "edge pixel (\(x), \(y)) faded: \(pixel(out, x, y).x) vs interior \(interior)")
        }
    }

    /// Pins the shipped order (Glow AFTER Clarity/Texture, BEFORE Noise Reduction/Sharpen). The expected pixels were RECORDED
    /// from a run of the shipped order (not derived). MEASURED 2026-10-07 by temporary swaps on this exact scene: moving Glow
    /// after Sharpen shifts these pixels by up to 0.058 (the (119,300) red channel, 1.1949 -> 1.2527) and moving it before
    /// Clarity by up to 0.038 (the (200,200) red channel, 2.3875 -> 2.3490) — ~29x and ~19x this suite's 0.002 tolerance, so
    /// either swap fails this test. The order is a measured convention (the bloom is a soft layer the detail stages then see
    /// as part of the photo), not proof it is the only valid one.
    func testGlowRunsAfterLocalContrastAndBeforeNoiseReductionAndSharpen() {
        let size = 400
        let dark = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02, colorSpace: linearSpace)!).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let bright = CIImage(color: CIColor(red: 0.9, green: 0.85, blue: 0.8, colorSpace: linearSpace)!).cropped(to: CGRect(x: 150, y: 150, width: 100, height: 100))
        let mid = CIImage(color: CIColor(red: 0.35, green: 0.3, blue: 0.25, colorSpace: linearSpace)!).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 400))
        let input = bright.composited(over: mid.composited(over: dark))
        var s = glow()
        s.clarity = 0.5; s.texture = 0.5; s.noiseReduction = 0.4; s.sharpness = 0.6
        let out = EditPipeline.apply(s, to: input)
        let cases: [((Int, Int), SIMD3<Float>)] = [
            ((200, 200), SIMD3(2.3874695, 2.0936246, 1.8108426)),
            ((119, 300), SIMD3(1.1949269, 0.97587436, 0.7856616)),
            ((121, 300), SIMD3(0.01969743, 0.015773837, 0.013114453)),
            ((255, 200), SIMD3(0.034347042, 0.034637075, 0.033780996)),
        ]
        for ((x, y), want) in cases {
            let got = pixel(out, x, y)
            XCTAssertEqual(got.x, want.x, accuracy: 0.002, "r at (\(x), \(y))")
            XCTAssertEqual(got.y, want.y, accuracy: 0.002, "g at (\(x), \(y))")
            XCTAssertEqual(got.z, want.z, accuracy: 0.002, "b at (\(x), \(y))")
        }
    }
}
