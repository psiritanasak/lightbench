import CoreImage
import XCTest
@testable import PhotoApp

/// The Color Grading Global wheel (`globalHue/Saturation/Luminance`): weight 1 at every pixel, added after the normalised
/// Shadows/Midtones/Highlights sum.
final class ColorGradingGlobalWheelTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])

    private func encode(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    private func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    private func render(_ state: EditState, linear r: Double, _ g: Double, _ b: Double, alpha: Double = 1) -> SIMD4<Float> {
        let image = CIImage(color: CIColor(red: r, green: g, blue: b, alpha: alpha, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        var px = [Float](repeating: 0, count: 4)
        context.render(EditPipeline.apply(state, to: image), toBitmap: &px, rowBytes: 16,
                       bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        return SIMD4(px[0], px[1], px[2], px[3])
    }

    /// Perceptual r - g of a grey patch at perceptual luminance `l` (a small tint so no channel clamps).
    private func redMinusGreen(_ state: EditState, perceptual l: Double) -> Double {
        let lin = decode(l)
        let out = render(state, linear: lin, lin, lin)
        return encode(Double(out.x)) - encode(Double(out.y))
    }

    private func globalTint(saturation: Double = 0.25) -> EditState {
        var s = EditState(); s.globalHue = 0; s.globalSaturation = saturation
        return s
    }

    // MARK: Uniformity

    func testTheGlobalTintIsTheSameStrengthAtEveryTone() {
        // hue 0, saturation 0.25: perceptual r - g = 2 * 0.125 * 0.8 = 0.2 wherever the pixel sits (no weights involved).
        for l in [0.1, 0.3, 0.5, 0.7, 0.9] {
            XCTAssertEqual(redMinusGreen(globalTint(), perceptual: l), 0.2, accuracy: 0.004, "L = \(l)")
        }
    }

    func testBlendingAndBalanceNeverReshapeIt() {
        var s = globalTint()
        for (blending, balance) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0), (1.0, -1.0)] {
            s.colorGradingBlending = blending; s.colorGradingBalance = balance
            for l in [0.1, 0.5, 0.9] {
                XCTAssertEqual(redMinusGreen(s, perceptual: l), 0.2, accuracy: 0.004, "blending \(blending) balance \(balance) L \(l)")
            }
        }
    }

    func testItAddsToTheThreeRangesWithoutNormalisationOrInterference() {
        // A Shadows tint of the same size gives weight w(L) * 0.2 at hue 0 / sat 0.25; the Global one adds a flat 0.2 on top.
        var s = globalTint()
        s.shadowHue = 0; s.shadowSaturation = 0.25
        let l = 0.25   // bright enough that no channel clamps at 0 once both tints are subtracted from green
        let shadowWeight = 0.5 * (1 + cos(Double.pi * 0.25 / 0.4))
        XCTAssertEqual(redMinusGreen(s, perceptual: l), 0.2 * shadowWeight + 0.2, accuracy: 0.006)
        // At default width the three ranges alone add up to at most 1; wide Blending normalises ONLY them: still +0.2.
        s.colorGradingBlending = 1
        let mid = 0.5
        let weights = [0.0, 0.5, 1.0].map { anchor -> Double in
            let d = abs(mid - anchor); return d >= 0.8 ? 0 : 0.5 * (1 + cos(Double.pi * d / 0.8))
        }
        let shadowShare = weights[0] / max(weights.reduce(0, +), 1)
        XCTAssertEqual(redMinusGreen(s, perceptual: mid), 0.2 * shadowShare + 0.2, accuracy: 0.006)
    }

    // MARK: Luminance, hue, saturation rules

    func testGlobalLuminanceLiftsAndDarkensEveryToneAlike() {
        for l in [0.3, 0.5, 0.7] {
            let base = decode(l)
            var up = EditState(); up.globalLuminance = 0.4
            var down = EditState(); down.globalLuminance = -0.4
            let lifted = encode(Double(render(up, linear: base, base, base).x)) - l
            let dropped = encode(Double(render(down, linear: base, base, base).x)) - l
            XCTAssertEqual(lifted, 0.4 * 0.5, accuracy: 0.01, "perceptual lift at \(l) (lumStrength 0.5)")
            XCTAssertEqual(dropped, -0.4 * 0.5, accuracy: 0.01)
        }
    }

    func testHueAloneIsSkippedByTheActivationGate() {
        // Hue without Saturation or Luminance never reaches the kernel (the same rule as the other wheels).
        var hueOnly = EditState(); hueOnly.globalHue = 120
        XCTAssertEqual(render(hueOnly, linear: 0.3, 0.2, 0.1), render(EditState(), linear: 0.3, 0.2, 0.1))
    }

    func testAnActiveGlobalWheelAtZeroSaturationAndLuminanceChangesNothingInTheKernel() {
        // Force the kernel to run (a Shadows luminance tiny enough to matter nowhere on a mid-grey) with the global wheel at
        // zero: the pixel must equal the same state without any global field (they ARE the same state, so also compare to an
        // explicit global tint of exactly 0 saturation).
        var a = EditState(); a.shadowLuminance = 0.5
        var b = a; b.globalHue = 90; b.globalSaturation = 0; b.globalLuminance = 0
        XCTAssertEqual(render(a, linear: 0.3, 0.2, 0.1), render(b, linear: 0.3, 0.2, 0.1))
    }

    func testOutOfRangeStoredValuesAreClamped() {
        var wild = EditState(); wild.globalSaturation = 40; wild.globalLuminance = 40
        var max = EditState(); max.globalSaturation = 1; max.globalLuminance = 1
        XCTAssertEqual(render(wild, linear: 0.2, 0.2, 0.2), render(max, linear: 0.2, 0.2, 0.2))
    }

    // MARK: Safety, composition

    func testHeadroomAlphaAndBlackAndWhite() {
        var s = globalTint(saturation: 0.5)
        let bright = render(s, linear: 1.4, 1.4, 1.4)
        XCTAssertGreaterThan(bright.x, 1.0)
        XCTAssertTrue(bright.x.isFinite && bright.y.isFinite && bright.z.isFinite)
        XCTAssertEqual(render(s, linear: 0.25, 0.25, 0.25, alpha: 0.5).w, 0.5, accuracy: 1e-6)
        s.blackAndWhite = true
        let out = render(s, linear: 0.214, 0.15, 0.05)
        XCTAssertGreaterThan(abs(out.x - out.y), 0.02, "a global tint survives Black & White like the other wheels")
    }

    func testAStyleTintStacksOnTopOfTheUsersGlobalWheelWithoutDoubleCounting() throws {
        // Reference: the style's three tints as PLAIN wheels plus the user's global wheel, in ONE kernel pass. The real render
        // is two passes (the user's wheels, then the style's tint), so they agree only to within the small non-commutation of
        // two additive passes (well under 0.02 here) — but a style pass that also received the user's global vector (double
        // counting it, +0.15 on red-minus-blue for this wheel) is far outside that.
        let copper = try XCTUnwrap(StyleLibrary.preset(for: "builtin:copper"))
        var real = EditState(); real.styleID = "builtin:copper"; real.globalHue = 210; real.globalSaturation = 0.3
        var reference = EditState()
        reference.shadowHue = copper.shadowTint.hue; reference.shadowSaturation = copper.shadowTint.saturation
        reference.midtoneHue = copper.midTint.hue; reference.midtoneSaturation = copper.midTint.saturation
        reference.highlightHue = copper.highlightTint.hue; reference.highlightSaturation = copper.highlightTint.saturation
        reference.globalHue = 210; reference.globalSaturation = 0.3
        for lin in [0.05, 0.2, 0.5] {
            let a = render(real, linear: lin, lin, lin), b = render(reference, linear: lin, lin, lin)
            for i in 0..<3 { XCTAssertEqual(a[i], b[i], accuracy: 0.02, "channel \(i) at linear \(lin)") }
        }
        XCTAssertEqual(real.globalSaturation, 0.3)
    }
}
