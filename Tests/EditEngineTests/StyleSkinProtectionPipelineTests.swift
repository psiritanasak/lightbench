import CoreImage
import XCTest
@testable import PhotoApp

/// Styles v3 "Protect skin" rendering: with a stored skin raster, the style's COLOUR changes (saturation/vibrance/tints) are held
/// back where the raster is 1 while its TONE changes stay. Rasters here are hand-made PNGs (no Vision).
final class StyleSkinProtectionPipelineTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])
    private let tolerance: Float = 0.002
    /// A skin-like linear colour with enough chroma for a style's colour changes to be clearly visible.
    private let skin: (Double, Double, Double) = (0.50, 0.30, 0.22)

    // MARK: Helpers

    private func solid(size: Int = 64, origin: CGPoint = .zero, scale: Double = 1) -> CIImage {
        CIImage(color: CIColor(red: skin.0 * scale, green: skin.1 * scale, blue: skin.2 * scale, alpha: 1, colorSpace: linearSpace)!)
            .cropped(to: CGRect(x: origin.x, y: origin.y, width: CGFloat(size), height: CGFloat(size)))
    }

    private func pixel(_ image: CIImage, x: Int, y: Int) -> SIMD4<Float> {
        var b = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: linearSpace)
        return SIMD4(b[0], b[1], b[2], b[3])
    }

    /// A grayscale raster PNG, `side` px square, built row 0 = TOP. `value(x, y)` with y counted from the top.
    private func raster(side: Int = 16, _ value: (Int, Int) -> UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side { for x in 0..<side { bytes[y * side + x] = value(x, y) } }
        return SubjectMaskGenerator.encodePNG(.init(width: side, height: side, bytes: bytes)) ?? Data()
    }

    private func style(protectedBy png: Data?, amount: Double = 1, on: Bool = true) -> EditState {
        var s = EditState()
        s.styleID = "builtin:cinema"
        s.styleTone = 0.5
        s.styleColor = 0.6
        s.styleProtectSkin = on
        s.styleProtectAmount = amount
        s.styleSkinMaskPNG = png
        s.styleSkinMaskRevision = 1
        return s
    }

    /// The same style with protection OFF: what an unmasked pixel must show.
    private func unprotected(_ s: EditState) -> EditState {
        var u = s
        u.styleProtectSkin = false; u.styleSkinMaskPNG = nil; u.styleSkinMaskRevision = nil
        return u
    }

    /// What a fully protected pixel must show: the style's TONE nudges as manual sliders, and none of its colour.
    private func plainReference(_ s: EditState) -> EditState {
        let n = StyleMath.nudges(id: s.styleID, tone: s.styleTone, color: s.styleColor, strength: s.styleStrength)
        var m = EditState()
        m.contrast = n.contrast; m.curvesShadows = n.shadows; m.curvesHighlights = n.highlights
        return m
    }

    private func assertEqual(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ message: String, tolerance: Float? = nil, line: UInt = #line) {
        let t = tolerance ?? self.tolerance
        for i in 0..<4 { XCTAssertEqual(a[i], b[i], accuracy: t, "\(message) [channel \(i)]", line: line) }
    }

    private func maxGap(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { (0..<4).map { abs(a[$0] - b[$0]) }.max() ?? 0 }

    private func render(_ s: EditState, size: Int = 64, origin: CGPoint = .zero, x: Int, y: Int) -> SIMD4<Float> {
        pixel(EditPipeline.apply(s, to: solid(size: size, origin: origin)), x: Int(origin.x) + x, y: Int(origin.y) + y)
    }

    private lazy var leftHalf = raster { x, _ in x < 8 ? 255 : 0 }
    private lazy var full = raster { _, _ in 255 }

    // MARK: The blend

    func testAFullyMaskedPixelShowsTheStylesToneButNoneOfItsColour() {
        let s = style(protectedBy: full)
        let plain = render(plainReference(s), x: 10, y: 10)
        assertEqual(render(s, x: 10, y: 10), plain, "protected == tone-only manual sliders")
        // Non-vacuous: the style really changes this colour, and the tone part really changes it too.
        XCTAssertGreaterThan(maxGap(render(unprotected(s), x: 10, y: 10), plain), 0.02, "the colour part is visible")
        XCTAssertGreaterThan(maxGap(render(EditState(), x: 10, y: 10), plain), 0.01, "the tone part is kept")
    }

    func testOnlyTheMaskedHalfIsProtected() {
        let s = style(protectedBy: leftHalf)
        assertEqual(render(s, x: 6, y: 30), render(plainReference(s), x: 6, y: 30), "left (masked) is plain")
        assertEqual(render(s, x: 58, y: 30), render(unprotected(s), x: 58, y: 30), "right (unmasked) is the normal style")
    }

    func testRasterRowZeroIsTheTopOfThePhoto() {
        let s = style(protectedBy: raster { _, y in y < 8 ? 255 : 0 }) // top half masked
        // CI y grows upward: y = 58 is near the TOP of a 64 px image.
        assertEqual(render(s, x: 30, y: 58), render(plainReference(s), x: 30, y: 58), "top is protected")
        assertEqual(render(s, x: 30, y: 6), render(unprotected(s), x: 30, y: 6), "bottom is not")
    }

    func testAmountBlendsLinearlyBetweenTheNormalAndTheProtectedRender() {
        let s = style(protectedBy: full, amount: 0.4)
        let styled = render(unprotected(s), x: 10, y: 10), plain = render(plainReference(s), x: 10, y: 10)
        let expected = styled + (plain - styled) * 0.4   // blend in scene-linear
        assertEqual(render(s, x: 10, y: 10), expected, "amount 0.4")
    }

    func testPartialRasterValueScalesTheSameWay() {
        let s = style(protectedBy: raster { _, _ in 128 })
        let styled = render(unprotected(s), x: 10, y: 10), plain = render(plainReference(s), x: 10, y: 10)
        assertEqual(render(s, x: 10, y: 10), styled + (plain - styled) * Float(128.0 / 255.0), "raster 128", tolerance: 0.004)
    }

    func testAmountAboveOneClampsAndANonFiniteAmountCountsAsOne() {
        let at1 = render(style(protectedBy: full, amount: 1), x: 10, y: 10)
        assertEqual(render(style(protectedBy: full, amount: 7), x: 10, y: 10), at1, "7 -> 1")
        assertEqual(render(style(protectedBy: full, amount: .nan), x: 10, y: 10), at1, "NaN -> 1 (the decode's own fallback)")
        assertEqual(render(style(protectedBy: full, amount: .infinity), x: 10, y: 10), at1, "inf -> 1")
    }

    /// Extended-range input (a highlight above 1.0 after a Look/exposure) must pass through the blend unclamped.
    func testHighlightsAboveOneSurviveTheBlend() {
        let s = style(protectedBy: full)
        let bright = solid(scale: 2.4) // red channel 1.2 linear
        let out = pixel(EditPipeline.apply(s, to: bright), x: 10, y: 10)
        let plain = pixel(EditPipeline.apply(plainReference(s), to: bright), x: 10, y: 10)
        XCTAssertGreaterThan(plain[0], 1.0, "the premise: the reference itself is above 1")
        assertEqual(out, plain, "protected == tone-only, headroom intact")
        // And at a fractional weight, where both legs contribute: the mix of the two renders, neither clamped.
        let half = style(protectedBy: full, amount: 0.5)
        let styled = pixel(EditPipeline.apply(unprotected(half), to: bright), x: 10, y: 10)
        assertEqual(pixel(EditPipeline.apply(half, to: bright), x: 10, y: 10), styled + (plain - styled) * 0.5, "amount 0.5 mix")
    }

    // MARK: Inactive cases render exactly like an unprotected style

    func testEveryInactiveCaseRendersExactlyLikeTheUnprotectedStyle() {
        let base = style(protectedBy: full)
        var cases: [(String, EditState)] = []
        cases.append(("toggle off", style(protectedBy: full, on: false)))
        cases.append(("no raster", style(protectedBy: nil)))
        cases.append(("amount 0", style(protectedBy: full, amount: 0)))
        cases.append(("negative amount", style(protectedBy: full, amount: -1)))
        var bw = base; bw.blackAndWhite = true; cases.append(("black & white", bw))
        var silver = base; silver.styleID = "builtin:silver"; cases.append(("silver (monochrome preset)", silver))
        var ink = base; ink.styleID = "builtin:ink"; cases.append(("ink (monochrome preset)", ink))
        var toneOnly = base; toneOnly.styleID = ""; toneOnly.styleColor = 0; toneOnly.styleTone = 0.6; cases.append(("tone-only style", toneOnly))
        var zero = base; zero.styleStrength = 0; cases.append(("strength 0", zero))
        cases.append(("undecodable raster", style(protectedBy: Data([1, 2, 3, 4]))))
        for (name, state) in cases {
            for (x, y) in [(10, 10), (50, 40)] {
                XCTAssertEqual(render(state, x: x, y: y), render(unprotected(state), x: x, y: y), "\(name) at \(x),\(y)")
            }
        }
        XCTAssertFalse(EditPipeline.skinProtectionActive(zero))
        XCTAssertTrue(EditPipeline.skinProtectionActive(base), "and the base case really is active")
    }

    // MARK: Frame and scale

    func testTheRasterIsStretchedOverWhateverSizeAndOriginArrives() {
        let s = style(protectedBy: leftHalf)
        for (size, origin) in [(32, CGPoint.zero), (128, CGPoint(x: 40, y: 25)), (200, CGPoint(x: -17, y: 9))] {
            let w = size
            assertEqual(render(s, size: size, origin: origin, x: w / 8, y: w / 2), render(plainReference(s), size: size, origin: origin, x: w / 8, y: w / 2), "protected side, \(size)px")
            assertEqual(render(s, size: size, origin: origin, x: w - w / 8, y: w / 2), render(unprotected(s), size: size, origin: origin, x: w - w / 8, y: w / 2), "unprotected side, \(size)px")
        }
    }

    /// The stage runs BEFORE geometry, so the raster stays in the SOURCE frame: after a horizontal flip the protected area follows
    /// the pixels it was drawn on, to the right side of the result.
    func testTheRasterFollowsTheSourcePixelsThroughAFlip() {
        var s = style(protectedBy: leftHalf)
        s.flipHorizontal = true
        assertEqual(render(s, x: 58, y: 30), render(plainReference(s).withFlip(), x: 58, y: 30), "protected area moved right")
        assertEqual(render(s, x: 6, y: 30), render(unprotected(s), x: 6, y: 30), "left is now the unprotected half")
    }

    func testAnEyedropperTruncationIsNeverProtected() {
        let s = style(protectedBy: full)
        var a = [Float](repeating: 0, count: 4), b = [Float](repeating: 0, count: 4)
        var withPoint = s; withPoint.pointColors = [PointColor()]
        var withoutRaster = unprotected(withPoint)
        withoutRaster.pointColors = withPoint.pointColors
        let x = EditPipeline.apply(withPoint, to: solid(), truncatingColorAt: .pointColor(index: 0))
        let y = EditPipeline.apply(withoutRaster, to: solid(), truncatingColorAt: .pointColor(index: 0))
        context.render(x, toBitmap: &a, rowBytes: 16, bounds: CGRect(x: 10, y: 10, width: 1, height: 1), format: .RGBAf, colorSpace: linearSpace)
        context.render(y, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: 10, y: 10, width: 1, height: 1), format: .RGBAf, colorSpace: linearSpace)
        XCTAssertEqual(a, b)
    }
}

private extension EditState {
    func withFlip() -> EditState { var s = self; s.flipHorizontal = true; return s }
}
