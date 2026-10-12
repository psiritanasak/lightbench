import CoreImage
import XCTest
@testable import PhotoApp

/// Color Grading Blending / Balance (`colorGradingBlending`, `colorGradingBalance` -> `ColorGradingZones` -> the two new
/// `ColorGrading.cikernel` arguments). Weights are MEASURED from real renders and compared with the kernel's documented
/// formula `0.5 * (1 + cos(pi * d / width))`, where d = |remapped L - anchor|, L remapped by the Balance midpoint move, and the
/// three weights divided by their sum when it exceeds 1.
final class ColorGradingBlendBalanceTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])

    private func encode(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    private func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    private func render(_ state: EditState, linear r: Double, _ g: Double, _ b: Double) -> SIMD4<Float> {
        let image = CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: linearSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        var px = [Float](repeating: 0, count: 4)
        context.render(EditPipeline.apply(state, to: image), toBitmap: &px, rowBytes: 16,
                       bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBAf, colorSpace: linearSpace)
        return SIMD4(px[0], px[1], px[2], px[3])
    }

    private enum Range: CaseIterable { case shadow, mid, highlight
        var anchor: Double { switch self { case .shadow: return 0; case .mid: return 0.5; case .highlight: return 1 } }
    }

    /// A small tint (saturation 0.25, hue 0: delta (+0.125, -0.125, -0.125) in perceptual units) on ONE range, so no channel
    /// clamps at 0 on the dark patch and the range's weight is recoverable: perceptual (r - g) = 2 * 0.125 * 0.8 * w.
    private func state(tinting range: Range, blending: Double, balance: Double) -> EditState {
        var s = EditState()
        switch range {
        case .shadow: s.shadowHue = 0; s.shadowSaturation = 0.25
        case .mid: s.midtoneHue = 0; s.midtoneSaturation = 0.25
        case .highlight: s.highlightHue = 0; s.highlightSaturation = 0.25
        }
        s.colorGradingBlending = blending
        s.colorGradingBalance = balance
        return s
    }

    /// The range's weight at a mid-grey patch of PERCEPTUAL luminance `l`, measured from the render.
    private func measuredWeight(_ range: Range, perceptual l: Double, blending: Double, balance: Double) -> Double {
        let lin = decode(l)
        let out = render(state(tinting: range, blending: blending, balance: balance), linear: lin, lin, lin)
        return (encode(Double(out.x)) - encode(Double(out.y))) / 0.2
    }

    /// The Balance remap: the midpoint moves to 0.5 + shift, both ends stay fixed.
    private func remapped(_ l: Double, shift: Double) -> Double {
        if shift == 0 { return l }
        return l < 0.5 ? l * (1 + 2 * shift) : 0.5 + shift + (l - 0.5) * (1 - 2 * shift)
    }

    private func rawWeights(perceptual l: Double, blending: Double, balance: Double) -> [Double] {
        let width = ColorGradingZones.width(blending: blending)
        let moved = remapped(l, shift: ColorGradingZones.shift(balance: balance))
        return Range.allCases.map { range in
            let d = abs(moved - range.anchor)
            return d >= width ? 0 : 0.5 * (1 + cos(Double.pi * d / width))
        }
    }

    private func expectedWeight(_ range: Range, perceptual l: Double, blending: Double, balance: Double) -> Double {
        let weights = rawWeights(perceptual: l, blending: blending, balance: balance)
        let index = Range.allCases.firstIndex(of: range) ?? 0
        return weights[index] / max(weights.reduce(0, +), 1)
    }

    // MARK: The weight grid

    func testMeasuredWeightsMatchTheDocumentedFormulaAcrossBlendingAndBalance() {
        let combos: [(Double, Double)] = [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1), (0.5, -0.5), (-0.7, 0.4), (1, 1), (-1, -1)]
        for (blending, balance) in combos {
            for l in [0.1, 0.3, 0.5, 0.7, 0.9] {
                for range in Range.allCases {
                    XCTAssertEqual(
                        measuredWeight(range, perceptual: l, blending: blending, balance: balance),
                        expectedWeight(range, perceptual: l, blending: blending, balance: balance),
                        accuracy: 0.012, "\(range) at L=\(l), blending \(blending), balance \(balance)"
                    )
                }
            }
        }
    }

    // MARK: Specific, readable cases

    func testDefaultWeightsAreTheOriginalPartition() {
        XCTAssertEqual(measuredWeight(.mid, perceptual: 0.5, blending: 0, balance: 0), 1, accuracy: 0.012)
        XCTAssertEqual(measuredWeight(.shadow, perceptual: 0.5, blending: 0, balance: 0), 0, accuracy: 0.012, "mid-grey has no shadow weight")
        XCTAssertEqual(measuredWeight(.highlight, perceptual: 0.5, blending: 0, balance: 0), 0, accuracy: 0.012)
    }

    func testWideBlendingLetsTheShadowsReachMidGreyAndNarrowBlendingStillTouchesNeighbours() {
        // Width 0.8 at mid-grey: raw shadow weight 0.309, but the weights add up to 1.618 there, so after normalisation 0.191.
        let wide = measuredWeight(.shadow, perceptual: 0.5, blending: 1, balance: 0)
        XCTAssertEqual(wide, 0.309 / 1.618, accuracy: 0.012)
        XCTAssertGreaterThan(wide, 0.15)
        // Narrow Blending (width 0.33) leaves no ungraded tone: the weight sum dips to 1 + cos(pi * 0.25 / 0.33) = 0.28 halfway
        // between two ranges (0.617 at the default width) — pin the real trough so a narrower limit is caught.
        var trough = Double.infinity
        for l in stride(from: 0.0, through: 1.0, by: 0.01) {
            trough = min(trough, rawWeights(perceptual: l, blending: -1, balance: 0).reduce(0, +))
        }
        XCTAssertEqual(trough, 1 + cos(Double.pi * 0.25 / 0.33), accuracy: 0.01)
        XCTAssertGreaterThan(trough, 0.27)
        XCTAssertEqual(measuredWeight(.shadow, perceptual: 0.5, blending: -1, balance: 0), 0, accuracy: 0.012)
    }

    func testPositiveBalanceFavoursTheHighlightsAndNegativeTheShadows() {
        // Positive Balance moves the midpoint up: the scale looks brighter to the weights.
        XCTAssertLessThan(measuredWeight(.shadow, perceptual: 0.3, blending: 0, balance: 1),
                          measuredWeight(.shadow, perceptual: 0.3, blending: 0, balance: 0) - 0.1, "shadows reach less far up (0.146 -> 0)")
        XCTAssertGreaterThan(measuredWeight(.highlight, perceptual: 0.7, blending: 0, balance: 1),
                             measuredWeight(.highlight, perceptual: 0.7, blending: 0, balance: 0) + 0.2, "highlights reach further down")
        // Negative Balance: the mirror image.
        XCTAssertGreaterThan(measuredWeight(.shadow, perceptual: 0.3, blending: 0, balance: -1),
                             measuredWeight(.shadow, perceptual: 0.3, blending: 0, balance: 0) + 0.2)
        XCTAssertLessThan(measuredWeight(.highlight, perceptual: 0.7, blending: 0, balance: -1),
                          measuredWeight(.highlight, perceptual: 0.7, blending: 0, balance: 0) - 0.1)
    }

    /// The reviewer-found flaw of a plain `L + shift`: at Balance -1 white kept only 0.309 of its Highlights weight (0 at the
    /// narrow width). The midpoint move keeps BOTH ends fixed, for every Balance and every Blending.
    func testBothEndsKeepTheirOwnRangeFullyWhateverTheBalanceAndBlending() {
        for blending in [-1.0, 0, 1.0] {
            for balance in [-1.0, -0.5, 0, 0.5, 1.0] {
                // L = 0.1 and 0.9 are the darkest/lightest patches whose tint channels do not clamp at 0 in the measurement,
                // so check the pure remap for the true endpoints and the render for the near-endpoints.
                XCTAssertEqual(remapped(0, shift: ColorGradingZones.shift(balance: balance)), 0)
                XCTAssertEqual(remapped(1, shift: ColorGradingZones.shift(balance: balance)), 1, accuracy: 1e-12)
                let nearBlack = measuredWeight(.shadow, perceptual: 0.1, blending: blending, balance: balance)
                let nearWhite = measuredWeight(.highlight, perceptual: 0.9, blending: blending, balance: balance)
                XCTAssertEqual(nearBlack, expectedWeight(.shadow, perceptual: 0.1, blending: blending, balance: balance), accuracy: 0.012)
                XCTAssertEqual(nearWhite, expectedWeight(.highlight, perceptual: 0.9, blending: blending, balance: balance), accuracy: 0.012)
                // The far wheel is never stripped from its own end: at least the weight an UNSHIFTED L=0.1/0.9 would give at
                // that width, scaled for normalisation (a plain shift gave 0 here at Balance -1 / narrow width).
                XCTAssertGreaterThan(nearWhite, 0.4, "white keeps its Highlights range (blending \(blending), balance \(balance))")
                XCTAssertGreaterThan(nearBlack, 0.4, "black keeps its Shadows range (blending \(blending), balance \(balance))")
            }
        }
    }

    func testTheRemapIsMonotonicSoToneOrderIsNeverReversed() {
        for balance in [-1.0, -0.4, 0.4, 1.0] {
            let shift = ColorGradingZones.shift(balance: balance)
            var last = -1.0
            for l in stride(from: 0.0, through: 1.0, by: 0.01) {
                let moved = remapped(l, shift: shift)
                XCTAssertGreaterThan(moved, last, "balance \(balance) at L=\(l)")
                last = moved
            }
        }
    }

    // MARK: Normalisation

    func testWideBlendingSpreadsTheGradeInsteadOfStrengtheningIt() {
        // The same tint on ALL THREE wheels is a uniform wash: with normalisation its strength can never exceed one wheel's.
        var s = EditState()
        s.shadowHue = 0; s.shadowSaturation = 0.25; s.midtoneHue = 0; s.midtoneSaturation = 0.25
        s.highlightHue = 0; s.highlightSaturation = 0.25
        func strength(_ blending: Double, _ l: Double) -> Double {
            var state = s; state.colorGradingBlending = blending
            let lin = decode(l)
            let out = render(state, linear: lin, lin, lin)
            return (encode(Double(out.x)) - encode(Double(out.y))) / 0.2
        }
        for l in [0.3, 0.4, 0.5, 0.6, 0.7] {
            // At the default width the weights never add up to more than 1 (0.646 at L = 0.3 where two ranges only touch), so
            // the sum itself is the wash strength there; wide Blending raises it but normalisation caps it at one full wheel.
            let defaultSum = rawWeights(perceptual: l, blending: 0, balance: 0).reduce(0, +)
            XCTAssertLessThanOrEqual(defaultSum, 1.0001)
            XCTAssertEqual(strength(0, l), defaultSum, accuracy: 0.05, "default wash strength at L=\(l)")
            XCTAssertLessThanOrEqual(strength(1, l), 1.02, "wide blending must not exceed one full wheel (unnormalised it reached 1.6x) at L=\(l)")
            XCTAssertGreaterThan(strength(1, l), strength(0, l) - 0.02, "wide blending fills the dips between the ranges")
        }
        // Unnormalised the sum at mid-grey would be 1.618: pin that the formula really exceeds 1 there.
        XCTAssertGreaterThan(rawWeights(perceptual: 0.5, blending: 1, balance: 0).reduce(0, +), 1.6)
    }

    // MARK: Identity, safety

    func testBlendingAndBalanceAloneChangeNothing() {
        var s = EditState()
        s.colorGradingBlending = 1; s.colorGradingBalance = -1
        let plain = render(EditState(), linear: 0.3, 0.2, 0.1)
        let slid = render(s, linear: 0.3, 0.2, 0.1)
        XCTAssertEqual(plain, slid, "with every tint at zero the stage is skipped and the sliders do nothing")
    }

    func testDefaultsGiveTheSamePixelsAsAStateThatNeverHeardOfThem() {
        var tinted = EditState()
        tinted.shadowHue = 210; tinted.shadowSaturation = 0.6; tinted.highlightHue = 40; tinted.highlightSaturation = 0.5
        var explicit = tinted
        explicit.colorGradingBlending = 0; explicit.colorGradingBalance = 0
        for lin in [0.01, 0.214, 0.7876] {
            XCTAssertEqual(render(tinted, linear: lin, lin, lin), render(explicit, linear: lin, lin, lin))
        }
    }

    func testOutOfRangeStoredValuesAreClampedNotExtrapolated() {
        let clamped = measuredWeight(.shadow, perceptual: 0.5, blending: 1, balance: 1)
        let wild = measuredWeight(.shadow, perceptual: 0.5, blending: 40, balance: 40)
        XCTAssertEqual(wild, clamped, accuracy: 1e-5)
        let nan = render(state(tinting: .mid, blending: .nan, balance: .nan), linear: 0.214, 0.214, 0.214)
        let base = render(state(tinting: .mid, blending: 0, balance: 0), linear: 0.214, 0.214, 0.214)
        XCTAssertEqual(nan, base, "NaN sliders read as the original look")
    }

    func testHeadroomAndAlphaSurviveExtremeSettings() {
        var s = state(tinting: .highlight, blending: 1, balance: 1)
        let bright = render(s, linear: 1.4, 1.4, 1.4)
        XCTAssertGreaterThan(bright.x, 1.0, "highlight headroom is preserved")
        XCTAssertTrue(bright.x.isFinite && bright.y.isFinite && bright.z.isFinite)
        XCTAssertEqual(bright.w, 1)
        s = state(tinting: .shadow, blending: -1, balance: -1)
        let black = render(s, linear: 0, 0, 0)
        XCTAssertTrue(black.x.isFinite && black.x >= 0)
    }

    func testBlackAndWhiteStillCarriesTheTintWithExtremeSliders() {
        var s = state(tinting: .mid, blending: 1, balance: 0.5)
        s.blackAndWhite = true
        let out = render(s, linear: 0.214, 0.15, 0.05)
        XCTAssertGreaterThan(abs(out.x - out.z), 0.02, "the split-tone survives B&W (the grading runs after the desaturation)")
    }

    // MARK: The style tint is independent of the user's sliders

    func testAStyleTintIgnoresTheUsersBlendingAndBalance() {
        var base = EditState()
        base.styleID = "builtin:copper"
        var slid = base
        slid.colorGradingBlending = 1; slid.colorGradingBalance = -1   // no user wheels: only the style pass tints
        // The absolute reference: the same tints as plain user wheels at the DEFAULT width/shift.
        let copper = StyleLibrary.preset(for: "builtin:copper")
        var manual = EditState()
        if let copper {
            manual.shadowHue = copper.shadowTint.hue; manual.shadowSaturation = copper.shadowTint.saturation
            manual.midtoneHue = copper.midTint.hue; manual.midtoneSaturation = copper.midTint.saturation
            manual.highlightHue = copper.highlightTint.hue; manual.highlightSaturation = copper.highlightTint.saturation
        }
        XCTAssertNotNil(copper)
        for (r, g, b) in [(0.05, 0.05, 0.05), (0.2, 0.15, 0.1), (0.5, 0.3, 0.2), (0.8, 0.7, 0.6)] {
            XCTAssertEqual(render(base, linear: r, g, b), render(slid, linear: r, g, b), "the user's sliders do not reach the style pass")
            let want = render(manual, linear: r, g, b), got = render(base, linear: r, g, b)
            for i in 0..<3 { XCTAssertEqual(got[i], want[i], accuracy: 0.002, "style pass = the wheels at width 0.4 / shift 0 [channel \(i)]") }
        }
    }
}
