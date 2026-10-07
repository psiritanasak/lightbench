import CoreImage
import XCTest
@testable import PhotoApp

/// The Style's texture group (`styleTexture/styleTextureAmount/styleGrain`) riding `EditPipeline.effectiveDetail`.
final class StyleDetailPipelineTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])
    private let tolerance: Float = 0.002

    // MARK: Helpers

    /// A 96x96 image with a vertical step edge (0.2 | 0.55 linear), so local-contrast and grain stages have something to act on
    /// (a flat colour makes them no-ops). At 96 px the Sharpen radius is a fraction of a pixel, so Sharpen's own nudge is pinned
    /// through `effectiveDetail` (clamp test), not through pixels.
    private func scene(size: Int = 96) -> CIImage {
        let left = CIImage(color: CIColor(red: 0.2, green: 0.18, blue: 0.15, alpha: 1, colorSpace: linearSpace)!)
            .cropped(to: CGRect(x: 0, y: 0, width: size / 2, height: size))
        let right = CIImage(color: CIColor(red: 0.55, green: 0.5, blue: 0.45, alpha: 1, colorSpace: linearSpace)!)
            .cropped(to: CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        return right.composited(over: left)
    }

    private func pixels(_ image: CIImage, points: [(Int, Int)]) -> [SIMD4<Float>] {
        points.map { x, y in
            var b = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: linearSpace)
            return SIMD4(b[0], b[1], b[2], b[3])
        }
    }

    private let points = [(10, 10), (46, 40), (47, 40), (48, 40), (49, 40), (60, 70), (30, 20)]

    private func render(_ state: EditState) -> [SIMD4<Float>] { pixels(EditPipeline.apply(state, to: scene()), points: points) }

    private func assertEqual(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>], _ message: String, tolerance: Float? = nil, line: UInt = #line) {
        let t = tolerance ?? self.tolerance
        for (i, (p, q)) in zip(a, b).enumerated() {
            for c in 0..<4 { XCTAssertEqual(p[c], q[c], accuracy: t, "\(message) [point \(i) channel \(c)]", line: line) }
        }
    }

    private func detail(texture: String = "", amount: Double = 1, grain: Bool = false) -> EditState {
        var s = EditState()
        s.styleTexture = texture; s.styleTextureAmount = amount; s.styleGrain = grain
        return s
    }

    // MARK: Identity

    func testNoTextureAndGrainOffRendersExactlyLikeAnUnstyledPhotoWhateverTheAmount() {
        let base = render(EditState())
        assertEqual(render(detail()), base, "none", tolerance: 0)
        assertEqual(render(detail(amount: 0.3)), base, "a lone amount is not an edit", tolerance: 0)
        assertEqual(render(detail(texture: "soft", amount: 0)), base, "amount 0", tolerance: 0)
        assertEqual(render(detail(texture: "from-a-newer-build")), base, "unknown id renders as none", tolerance: 0)
    }

    // MARK: Equivalence with the manual sliders each texture adds

    func testSoftIsExactlyNegativeTextureAndClarity() {
        var manual = EditState(); manual.texture = -0.5; manual.clarity = -0.15
        let styled = render(detail(texture: "soft"))
        assertEqual(styled, render(manual), "soft")
        XCTAssertNotEqual(styled[2], render(EditState())[2], "Soft really changes the edge")
    }

    func testFilmIsExactlyMildTextureAndSharpen() {
        var manual = EditState(); manual.texture = 0.2; manual.sharpness = 0.15
        let styled = render(detail(texture: "film"))
        assertEqual(styled, render(manual), "film")
        XCTAssertNotEqual(styled[2], render(EditState())[2])
    }

    func testTextureAmountHalfIsHalfTheNudges() {
        var manual = EditState(); manual.texture = -0.25; manual.clarity = -0.075
        assertEqual(render(detail(texture: "soft", amount: 0.5)), render(manual), "soft at half")
    }

    func testGrainToggleIsExactlyTheFixedGrainAmount() {
        var manual = EditState(); manual.grain = StyleMath.toggleGrainAmount
        let styled = render(detail(grain: true))
        assertEqual(styled, render(manual), "grain toggle")
        XCTAssertNotEqual(styled[0], render(EditState())[0], "the grain is really there")
    }

    func testStyleGrainAddsToTheUsersOwnGrainThenClamps() {
        var user = detail(grain: true); user.grain = 0.2
        var manual = EditState(); manual.grain = 0.2 + StyleMath.toggleGrainAmount
        assertEqual(render(user), render(manual), "0.2 + toggle")
        var heavy = detail(grain: true); heavy.grain = 0.9
        var capped = EditState(); capped.grain = 1.0
        assertEqual(render(heavy), render(capped), "clamped to 1, not 1.15")
        XCTAssertEqual(user.grain, 0.2, "the user's own slider is never rewritten")
    }

    func testStyleAddsToTheUsersTextureInsteadOfReplacingItAndSharpenGrainAreClamped() {
        var user = detail(texture: "soft"); user.texture = 0.4
        var manual = EditState(); manual.texture = 0.4 - 0.5; manual.clarity = -0.15
        assertEqual(render(user), render(manual), "user +0.4 and soft -0.5")
        var s = detail(texture: "film"); s.sharpness = 0.95
        XCTAssertEqual(EditPipeline.effectiveDetail(s).sharpness, 1.0, "0.95 + 0.15 clamps to 1")
        var t = detail(texture: "soft"); t.texture = -0.8
        XCTAssertEqual(EditPipeline.effectiveDetail(t).texture, -1.3, accuracy: 1e-12,
                       "Texture/Clarity are not clamped (the negative side saturates in the blur itself)")
    }

    func testEffectiveGrainSeesTheStyleToggleForExport() {
        XCTAssertEqual(EditPipeline.effectiveGrain(EditState()), 0)
        XCTAssertEqual(EditPipeline.effectiveGrain(detail(grain: true)), StyleMath.toggleGrainAmount)
        var both = detail(grain: true); both.grain = 0.3
        XCTAssertEqual(EditPipeline.effectiveGrain(both), 0.3 + StyleMath.toggleGrainAmount, accuracy: 1e-12)
    }

    func testNonFiniteStoredAmountRendersAsNoTextureInsteadOfCorruptingPixels() {
        var broken = detail(texture: "soft"); broken.styleTextureAmount = .nan
        for p in render(broken) { XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite) }
        assertEqual(render(broken), render(EditState()), "NaN amount", tolerance: 0)
    }

    // MARK: Plumbing

    func testCodableRoundTripTolerantDefaultsAndWrongTypes() throws {
        let state = detail(texture: "glow", amount: 0.4, grain: true)
        let decoded = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.styleTexture, "glow"); XCTAssertEqual(decoded.styleTextureAmount, 0.4); XCTAssertTrue(decoded.styleGrain)
        let old = try JSONDecoder().decode(EditState.self, from: Data(#"{ "exposureEV": 1 }"#.utf8))
        XCTAssertEqual(old.styleTexture, ""); XCTAssertFalse(old.styleGrain)
        XCTAssertEqual(old.styleTextureAmount, 1.0, "the non-zero identity default must survive an absent key")
        let wrong = try JSONDecoder().decode(EditState.self, from: Data(#"{ "exposureEV": 1, "styleTexture": 7, "styleGrain": "yes" }"#.utf8))
        XCTAssertEqual(wrong.exposureEV, 1, "mistyped style fields must not discard the sidecar")
        XCTAssertEqual(wrong.styleTexture, ""); XCTAssertFalse(wrong.styleGrain)
    }

    func testCountsAsAnEditIsClearedByTheComparisonOriginalCarriedByPresetsAndNotARawRedecode() {
        XCTAssertTrue(EditState().isEffectivelyIdentity)
        for state in [detail(texture: "film"), detail(grain: true), detail(amount: 0.5)] {
            XCTAssertFalse(state.isEffectivelyIdentity)
            XCTAssertFalse(state.requiresRawRedecode(comparedTo: EditState()))
        }
        let original = detail(texture: "glow", amount: 0.4, grain: true).comparisonOriginal()
        XCTAssertEqual(original.styleTexture, ""); XCTAssertEqual(original.styleTextureAmount, 1); XCTAssertFalse(original.styleGrain)
        let result = detail(texture: "film", amount: 0.6, grain: true).applyingPreset(onto: detail(texture: "soft", amount: 1, grain: false))
        XCTAssertEqual(result.styleTexture, "film"); XCTAssertEqual(result.styleTextureAmount, 0.6); XCTAssertTrue(result.styleGrain)
    }

    func testHistorySummaryNamesTheTextureAndGrain() {
        XCTAssertTrue(EditStateDiff.summary(from: EditState(), to: detail(texture: "soft")).contains("Style"))
        XCTAssertTrue(EditStateDiff.summary(from: EditState(), to: detail(grain: true)).contains("Style"))
    }
}
