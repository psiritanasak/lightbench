import CoreImage
import XCTest
@testable import PhotoApp

/// B&W Mix (`grayMix*` fields + `GrayMix.cikernel`): per-hue-band stop multipliers on the Black & White grey.
final class GrayMixTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])

    private func solid(_ r: Double, _ g: Double, _ b: Double, a: Double = 1) -> CIImage {
        let color = CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func pixel(_ image: CIImage) -> (r: Float, g: Float, b: Float, a: Float) {
        var buffer = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &buffer, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: linearSpace)
        return (buffer[0], buffer[1], buffer[2], buffer[3])
    }

    private func render(_ state: EditState, _ input: CIImage) -> (r: Float, g: Float, b: Float, a: Float) {
        pixel(EditPipeline.apply(state, to: input))
    }

    private func bw(_ configure: (inout EditState) -> Void = { _ in }) -> EditState {
        var s = EditState()
        s.blackAndWhite = true
        configure(&s)
        return s
    }

    // A saturated blue and red, each sitting near its band centre (hue ~ 230 and ~ 0 degrees in HSL).
    private let blue = (0.1, 0.2, 0.8)
    private let red = (0.8, 0.2, 0.2)

    func testActiveMixLeavesPixelsOutsideEveryNonZeroBandExactlyAsPlainBlackAndWhite() {
        // The stage IS active (Magenta set) but a blue pixel has zero Magenta weight: RGBA must match plain B&W exactly.
        let plain = render(bw(), solid(blue.0, blue.1, blue.2))
        let active = render(bw { $0.grayMixMagenta = 1 }, solid(blue.0, blue.1, blue.2))
        XCTAssertEqual(active.r, plain.r, accuracy: 1e-6)
        XCTAssertEqual(active.g, plain.g, accuracy: 1e-6)
        XCTAssertEqual(active.b, plain.b, accuracy: 1e-6)
        XCTAssertEqual(active.a, plain.a, accuracy: 1e-6)
    }

    func testAlphaIsNeverScaled() {
        for mix in [-1.0, 1.0] {
            let opaque = render(bw { $0.grayMixBlue = mix }, solid(blue.0, blue.1, blue.2))
            XCTAssertEqual(opaque.a, 1, accuracy: 1e-6, "mix \(mix)")
            let half = render(bw { $0.grayMixBlue = mix }, solid(blue.0 * 0.5, blue.1 * 0.5, blue.2 * 0.5, a: 0.5))
            XCTAssertEqual(half.a, 0.5, accuracy: 1e-6, "mix \(mix)")
        }
    }

    func testMixReadsTheColourAfterHueAndNotTheDesaturatedGrey() {
        // Rotating the hue by 120 degrees moves a blue pixel out of the Blue band: Blue then does nothing, while a band the
        // rotated pixel now sits in does change it. Pins that the stage reads the colour as it stood just BEFORE desaturation
        // (after the Hue stage), not the grey after it (which would give every band zero weight).
        let input = solid(blue.0, blue.1, blue.2)
        let rotated = bw { $0.hslHue = 120 }
        let base = render(rotated, input).r
        XCTAssertEqual(render(bw { $0.hslHue = 120; $0.grayMixBlue = -1 }, input).r, base, accuracy: 1e-5)
        let bands: [WritableKeyPath<EditState, Double>] = [
            \.grayMixRed, \.grayMixOrange, \.grayMixYellow, \.grayMixGreen,
            \.grayMixAqua, \.grayMixPurple, \.grayMixMagenta
        ]
        let changed = bands.contains { path in
            var s = rotated
            s[keyPath: path] = -1
            return abs(render(s, input).r - base) > 0.01
        }
        XCTAssertTrue(changed, "some band other than Blue must now respond to the hue-rotated pixel")
    }

    func testBlueMixDarkensAndLightensBlueOnly() {
        let base = render(bw(), solid(blue.0, blue.1, blue.2)).r
        let dark = render(bw { $0.grayMixBlue = -1 }, solid(blue.0, blue.1, blue.2)).r
        let light = render(bw { $0.grayMixBlue = 1 }, solid(blue.0, blue.1, blue.2)).r
        XCTAssertLessThan(dark, base * 0.7)
        XCTAssertGreaterThan(light, base * 1.4)
        // A red pixel is outside the Blue band's window: untouched.
        let redBase = render(bw(), solid(red.0, red.1, red.2)).r
        let redMixed = render(bw { $0.grayMixBlue = -1 }, solid(red.0, red.1, red.2)).r
        XCTAssertEqual(redMixed, redBase, accuracy: 0.0001)
    }

    func testOutputStaysNeutral() {
        let p = render(bw { $0.grayMixBlue = -0.7; $0.grayMixAqua = 0.4 }, solid(blue.0, blue.1, blue.2))
        XCTAssertEqual(p.r, p.g, accuracy: 0.0001)
        XCTAssertEqual(p.g, p.b, accuracy: 0.0001)
    }

    func testNoEffectWhileBlackAndWhiteIsOff() {
        var colour = EditState()
        colour.grayMixBlue = -1
        let p = render(colour, solid(blue.0, blue.1, blue.2))
        let q = render(EditState(), solid(blue.0, blue.1, blue.2))
        XCTAssertEqual(p.r, q.r, accuracy: 0.0001)
        XCTAssertEqual(p.b, q.b, accuracy: 0.0001)
    }

    func testMixIgnoredWhenOnlyTheSaturationSliderIsDesaturating() {
        // The saturation stage runs here without Black & White: the mix must not apply to a merely desaturated colour image.
        var a = EditState(); a.hslSaturation = -0.5
        var b = a; b.grayMixBlue = -1
        let pa = render(a, solid(blue.0, blue.1, blue.2))
        let pb = render(b, solid(blue.0, blue.1, blue.2))
        XCTAssertEqual(pa.b, pb.b, accuracy: 0.0001)
    }

    func testNeutralPixelsAreUntouchedAndHeadroomSurvives() {
        let input = solid(1.4, 1.4, 1.4)
        let base = render(bw(), input).r
        let mixed = render(bw { $0.grayMixRed = 1; $0.grayMixBlue = -1; $0.grayMixMagenta = 1 }, input).r
        XCTAssertEqual(mixed, base, accuracy: 0.0001)
        XCTAssertGreaterThan(mixed, 1.0)
    }

    func testColouredHeadroomPixelStillRespondsToItsBand() {
        // A bright blue above 1.0 must still be inside the Blue band (the HSL headroom normalisation).
        let input = solid(0.2, 0.4, 1.6)
        let base = render(bw(), input).r
        let dark = render(bw { $0.grayMixBlue = -1 }, input).r
        XCTAssertLessThan(dark, base * 0.7)
    }

    func testMultiplierMathAtExactBandCentreInThePerceptualDomain() {
        // (0,0,0.5) has HSL hue exactly 240 (the Blue centre), S = 1: weight 1. The multiplier acts on the sRGB-ENCODED grey,
        // so the linear output is decode(encode(base) * 2^-k).
        func encode(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let input = solid(0, 0, 0.5)
        let base = Double(render(bw(), input).r)
        let dark = Double(render(bw { $0.grayMixBlue = -1 }, input).r)
        let expected = decode(encode(base) * pow(2, -EditPipeline.kGrayMixStops))
        XCTAssertEqual(dark, expected, accuracy: 0.0002)
        XCTAssertLessThan(dark, base * 0.5, "the perceptual multiplier is stronger than a linear halving")
    }

    func testOutOfGamutPixelsKeepAFiniteBoundedMultiplier() {
        // Extended sRGB allows negative channels (wide-gamut shadows). Unclamped saturation made the multiplier explode (measured
        // by the round-2 review: up to ~4e26x) or flip sign; it must stay within the 2^(+-k * ~1.7) overlap-sum bound.
        let bound = pow(2.0, EditPipeline.kGrayMixStops * 1.7)
        for c in [(0.01, -0.005, -0.005), (0.002, -0.0019, -0.0019), (0.3, -0.05, -0.05), (0.05, -0.02, 0.0)] {
            let base = Double(render(bw(), solid(c.0, c.1, c.2)).r)
            for mix in [-1.0, 1.0] {
                let out = Double(render(bw { $0.grayMixRed = mix }, solid(c.0, c.1, c.2)).r)
                XCTAssertTrue(out.isFinite, "\(c) mix \(mix)")
                if abs(base) > 1e-6 {
                    XCTAssertLessThanOrEqual(abs(out / base), bound + 0.05, "\(c) mix \(mix)")
                    XCTAssertGreaterThanOrEqual(out / base, 0, "\(c) mix \(mix): slider direction must not flip")
                }
            }
        }
    }

    func testColorGradingStillTintsOnTop() {
        // A dark blue (so the shadows wheel applies), mixed, then tinted: R, G, B must differ.
        var s = bw { $0.grayMixBlue = -0.5 }
        s.shadowHue = 210
        s.shadowSaturation = 1
        let p = render(s, solid(0.01, 0.02, 0.1))
        XCTAssertNotEqual(p.r, p.b, accuracy: 0.0001, "Colour Grading must still tint the mixed grey")
        let plain = render(bw { $0.grayMixBlue = -0.5 }, solid(0.01, 0.02, 0.1))
        XCTAssertEqual(plain.r, plain.b, accuracy: 0.0001)
    }

    func testCodableRoundTripAndMissingKeyDecode() throws {
        var s = EditState()
        s.grayMixRed = 0.25; s.grayMixMagenta = -0.5
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(EditState.self, from: data)
        XCTAssertEqual(back.grayMixRed, 0.25)
        XCTAssertEqual(back.grayMixMagenta, -0.5)
        let empty = try JSONDecoder().decode(EditState.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.grayMixBlue, 0)
    }

    func testPresetCarriesMixAndComparisonOriginalResetsIt() {
        var preset = EditState()
        preset.blackAndWhite = true
        preset.grayMixGreen = 0.6
        XCTAssertEqual(preset.applyingPreset(onto: EditState()).grayMixGreen, 0.6)
        XCTAssertEqual(preset.comparisonOriginal().grayMixGreen, 0)
    }
}
