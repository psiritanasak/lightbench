import CoreImage
import XCTest
@testable import PhotoApp

/// `EditState.styleID/styleTone/styleColor/styleStrength` + their render-time nudges (`StyleMath`) riding
/// `EditPipeline.effectiveTone`, and the style's own tint pass.
final class StylePipelineTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])
    private let tolerance: Float = 0.002

    // MARK: Helpers

    private func solid(_ r: Double, _ g: Double, _ b: Double, alpha: Double = 1, size: Int = 8) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: alpha, colorSpace: linearSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    private func pixel(_ image: CIImage, x: Int = 2, y: Int = 2) -> SIMD4<Float> {
        var b = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: linearSpace)
        return SIMD4(b[0], b[1], b[2], b[3])
    }

    private func render(_ state: EditState, _ r: Double, _ g: Double, _ b: Double, alpha: Double = 1) -> SIMD4<Float> {
        pixel(EditPipeline.apply(state, to: solid(r, g, b, alpha: alpha)))
    }

    private func assertEqual(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ message: String, tolerance: Float? = nil, line: UInt = #line) {
        let t = tolerance ?? self.tolerance
        for i in 0..<4 { XCTAssertEqual(a[i], b[i], accuracy: t, "\(message) [channel \(i)]", line: line) }
    }

    private func style(id: String = "", tone: Double = 0, color: Double = 0, strength: Double = 1) -> EditState {
        var s = EditState()
        s.styleID = id; s.styleTone = tone; s.styleColor = color; s.styleStrength = strength
        return s
    }

    private let samples: [(Double, Double, Double)] = [(0.05, 0.05, 0.05), (0.2, 0.15, 0.1), (0.5, 0.3, 0.2), (0.1, 0.3, 0.6), (0.8, 0.7, 0.6)]

    // MARK: Identity

    func testNoStyleAndAZeroStrengthStyleRenderExactlyLikeAnUnstyledPhoto() {
        for (r, g, b) in samples {
            let base = render(EditState(), r, g, b)
            assertEqual(render(style(), r, g, b), base, "no style", tolerance: 0)
            assertEqual(render(style(strength: 0.3), r, g, b), base, "a lone strength is not an edit", tolerance: 0)
            assertEqual(render(style(id: "builtin:cinema", tone: 0.7, color: -0.4, strength: 0), r, g, b), base, "strength 0", tolerance: 0)
        }
    }

    func testAnUnknownPresetIdWithACentredPadRendersAsNoStyle() {
        for (r, g, b) in samples {
            assertEqual(render(style(id: "builtin:from-a-newer-build"), r, g, b), render(EditState(), r, g, b), "unknown id", tolerance: 0)
        }
    }

    // MARK: The nudges ride the existing stages (equivalence with the manual slider values they add)

    func testTheTonePadIsExactlyTheShadowsAndContrastItAdds() {
        var manual = EditState()
        manual.curvesShadows = StyleMath.toneShadowWeight
        manual.contrast = StyleMath.toneContrastWeight
        for (r, g, b) in samples {
            assertEqual(render(style(tone: 1), r, g, b), render(manual, r, g, b), "tone +1 == shadows+0.5, contrast-0.25")
        }
    }

    func testTheColorPadIsExactlyTheVibranceAndSaturationItAdds() {
        var manual = EditState()
        manual.vibrance = StyleMath.colorVibranceWeight
        manual.hslSaturation = StyleMath.colorSaturationWeight
        for (r, g, b) in samples {
            assertEqual(render(style(color: 1), r, g, b), render(manual, r, g, b), "color +1")
        }
    }

    func testAStyleAddsToTheUsersOwnSlidersInsteadOfReplacingThem() {
        var user = style(tone: 1)
        user.contrast = 0.2
        var manual = EditState()
        manual.curvesShadows = StyleMath.toneShadowWeight
        manual.contrast = 0.2 + StyleMath.toneContrastWeight
        for (r, g, b) in samples { assertEqual(render(user, r, g, b), render(manual, r, g, b), "user contrast + style") }
        XCTAssertEqual(user.contrast, 0.2, "the user's slider keeps its own value")
    }

    func testAPresetWithoutTintsIsExactlyItsNudges() throws {
        let vivid = try XCTUnwrap(StyleLibrary.preset(for: "builtin:vivid"))
        var manual = EditState()
        manual.contrast = vivid.contrast; manual.hslSaturation = vivid.saturation; manual.vibrance = vivid.vibrance
        for (r, g, b) in samples { assertEqual(render(style(id: "builtin:vivid"), r, g, b), render(manual, r, g, b), "vivid") }
    }

    func testStrengthHalfIsHalfTheNudges() throws {
        var manual = EditState()
        manual.contrast = 0.05; manual.hslSaturation = 0.075; manual.vibrance = 0.15
        for (r, g, b) in samples { assertEqual(render(style(id: "builtin:vivid", strength: 0.5), r, g, b), render(manual, r, g, b), "vivid at half") }
    }

    func testNonFiniteStoredValuesRenderAsNoStyleInsteadOfCorruptingPixels() {
        var broken = EditState()
        broken.styleTone = .nan; broken.styleColor = .infinity; broken.styleStrength = .nan
        for (r, g, b) in samples {
            let out = render(broken, r, g, b)
            XCTAssertTrue(out.x.isFinite && out.y.isFinite && out.z.isFinite)
            assertEqual(out, render(EditState(), r, g, b), "NaN style", tolerance: 0)
        }
    }

    // MARK: Tints (the style's own ColorGrading pass)

    func testATintedPresetIsExactlyTheEquivalentColorGradingWheels() throws {
        let honey = try XCTUnwrap(StyleLibrary.preset(for: "builtin:honey"))
        var manual = EditState()
        manual.shadowHue = honey.shadowTint.hue; manual.shadowSaturation = honey.shadowTint.saturation
        manual.midtoneHue = honey.midTint.hue; manual.midtoneSaturation = honey.midTint.saturation
        manual.highlightHue = honey.highlightTint.hue; manual.highlightSaturation = honey.highlightTint.saturation
        for (r, g, b) in samples { assertEqual(render(style(id: "builtin:honey"), r, g, b), render(manual, r, g, b), "honey") }
    }

    func testATintPresetWarmsAGrayAndStrengthScalesTheShift() {
        let neutral = render(EditState(), 0.4, 0.4, 0.4)
        let full = render(style(id: "builtin:copper"), 0.4, 0.4, 0.4)
        let half = render(style(id: "builtin:copper", strength: 0.5), 0.4, 0.4, 0.4)
        XCTAssertGreaterThan(full.x - full.z, neutral.x - neutral.z + 0.01, "copper warms a gray (red above blue)")
        let fullShift = full.x - full.z, halfShift = half.x - half.z
        XCTAssertGreaterThan(fullShift, halfShift)
        XCTAssertGreaterThan(halfShift, 0)
    }

    func testTheUsersOwnColorGradingIsLeftAloneWhenAStyleTintsToo() {
        var both = style(id: "builtin:copper")
        both.shadowHue = 200; both.shadowSaturation = 0.4
        let withStyle = render(both, 0.15, 0.15, 0.15)
        let userOnly = render({ var s = EditState(); s.shadowHue = 200; s.shadowSaturation = 0.4; return s }(), 0.15, 0.15, 0.15)
        XCTAssertNotEqual(withStyle.x, userOnly.x, accuracy: 0.0005, "the style adds its own tint on top")
        XCTAssertEqual(both.shadowSaturation, 0.4, "the user's wheel value is never modified")
    }

    /// Pins the shipped order (the style's tint AFTER the user's wheels). The expected pixels were RECORDED from a run of the
    /// shipped order (not derived); reversing the two passes moves the first sample by 0.0115 (see `EditPipeline`), far
    /// past the 0.002 tolerance.
    func testStyleTintRunsAfterTheUsersColorGrading() {
        var s = style(id: "builtin:copper")
        s.shadowHue = 210; s.shadowSaturation = 0.6; s.midtoneHue = 200; s.midtoneSaturation = 0.5
        s.highlightHue = 40; s.highlightSaturation = 0.6
        let cases: [((Double, Double, Double), SIMD3<Float>)] = [
            ((0.8, 0.7, 0.6), SIMD3(1.3387061, 0.81611335, 0.28216437)),
            ((0.5, 0.3, 0.2), SIMD3(0.32791704, 0.35832715, 0.33264437)),
            ((0.4, 0.4, 0.4), SIMD3(0.30393285, 0.45965365, 0.51177883)),
        ]
        for ((r, g, b), want) in cases {
            let out = render(s, r, g, b)
            XCTAssertEqual(out.x, want.x, accuracy: tolerance, "r of \((r, g, b))")
            XCTAssertEqual(out.y, want.y, accuracy: tolerance, "g of \((r, g, b))")
            XCTAssertEqual(out.z, want.z, accuracy: tolerance, "b of \((r, g, b))")
        }
    }

    // MARK: Invariants every stage keeps

    func testAlphaIsPreservedAndHeadroomAboveOneSurvives() {
        let translucent = render(style(id: "builtin:honey", tone: 0.5, color: 0.5), 0.3, 0.25, 0.2, alpha: 0.5)
        XCTAssertEqual(translucent.w, 0.5, accuracy: 0.002)
        let bright = render(style(id: "builtin:honey", tone: 0.5, color: 0.5), 1.4, 1.4, 1.4)
        XCTAssertGreaterThan(bright.x, 1.0, "a scene-linear value above 1 must survive a style")
    }

    func testAStyleOnlyEditStillRendersBecauseTheActiveGuardKnowsAboutIt() {
        // Every stage's active-check feeds one early-return guard; a style-only state must NOT take it.
        XCTAssertNotEqual(render(style(id: "builtin:cinema"), 0.2, 0.3, 0.4), render(EditState(), 0.2, 0.3, 0.4))
        XCTAssertNotEqual(render(style(id: "builtin:copper"), 0.2, 0.3, 0.4), render(EditState(), 0.2, 0.3, 0.4), "tint-only style")
    }

    // MARK: EditState plumbing

    func testCodableRoundTripTolerantDefaultsAndWrongTypes() throws {
        let state = style(id: "builtin:ink", tone: -0.3, color: 0.2, strength: 0.6)
        let decoded = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.styleID, "builtin:ink")
        XCTAssertEqual(decoded.styleTone, -0.3)
        XCTAssertEqual(decoded.styleColor, 0.2)
        XCTAssertEqual(decoded.styleStrength, 0.6)
        let old = try JSONDecoder().decode(EditState.self, from: Data(#"{ "exposureEV": 1 }"#.utf8))
        XCTAssertEqual(old.styleID, "")
        XCTAssertEqual(old.styleTone, 0)
        XCTAssertEqual(old.styleColor, 0)
        XCTAssertEqual(old.styleStrength, 1.0, "the non-zero identity default must survive an absent key")
        let wrong = try JSONDecoder().decode(EditState.self, from: Data(#"{ "exposureEV": 1, "styleID": 7 }"#.utf8))
        XCTAssertEqual(wrong.exposureEV, 1, "a mistyped style id must not discard the sidecar")
        XCTAssertEqual(wrong.styleID, "")
    }

    func testStyleCountsAsAnEditIsClearedByTheComparisonOriginalAndNotARawRedecode() {
        XCTAssertTrue(EditState().isEffectivelyIdentity)
        for state in [style(id: "builtin:vivid"), style(tone: 0.1), style(color: -0.1), style(strength: 0.5)] {
            XCTAssertFalse(state.isEffectivelyIdentity)
            XCTAssertFalse(state.requiresRawRedecode(comparedTo: EditState()), "a style never forces a RAW re-decode")
        }
        let original = style(id: "builtin:vivid", tone: 0.4, color: 0.4, strength: 0.4).comparisonOriginal()
        XCTAssertEqual(original.styleID, "")
        XCTAssertEqual(original.styleTone, 0)
        XCTAssertEqual(original.styleColor, 0)
        XCTAssertEqual(original.styleStrength, 1)
    }

    func testPresetsAndPasteCarryTheStyle() {
        let source = style(id: "builtin:haze", tone: 0.2, color: -0.5, strength: 0.7)
        let result = source.applyingPreset(onto: style(id: "builtin:vivid", tone: -1, color: 1, strength: 1))
        XCTAssertEqual(result.styleID, "builtin:haze")
        XCTAssertEqual(result.styleTone, 0.2)
        XCTAssertEqual(result.styleColor, -0.5)
        XCTAssertEqual(result.styleStrength, 0.7)
    }

    func testHistorySummaryNamesTheStyle() {
        XCTAssertTrue(EditStateDiff.summary(from: EditState(), to: style(id: "builtin:vivid")).contains("Style"))
        XCTAssertTrue(EditStateDiff.summary(from: EditState(), to: style(tone: 0.5)).contains("Style"))
    }
}
