import CoreImage
import XCTest
@testable import PhotoApp

/// `EditState.lookID`/`lookIntensity` + `EditPipeline.applyLook`: a 3D LUT applied to PERCEPTUAL values at the
/// start of the perceptual stage, with headroom re-added by `LookHeadroom.cikernel`.
final class LookPipelineTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])
    private let tolerance: Float = 0.006

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

    /// The sRGB transfer functions, extended to negative/over-1 values the way Core Image's tone curves are
    /// (odd-symmetric, continuing the power segment).
    private func encode(_ v: Float) -> Float {
        let a = abs(v)
        let e = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return v < 0 ? -e : e
    }

    private func decode(_ v: Float) -> Float {
        let a = abs(v)
        let d = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return v < 0 ? -d : d
    }

    private func looked(_ cube: CubeLUT, _ linear: SIMD3<Float>, intensity: Float = 1) -> SIMD3<Float> {
        let enc = SIMD3(encode(linear.x), encode(linear.y), encode(linear.z))
        let clamped = SIMD3(min(max(enc.x, 0), 1), min(max(enc.y, 0), 1), min(max(enc.z, 0), 1))
        let withHeadroom = cube.sample(clamped) + (enc - clamped)
        let mixed = withHeadroom * intensity + enc * (1 - intensity)
        return SIMD3(decode(mixed.x), decode(mixed.y), decode(mixed.z))
    }

    private func render(_ state: EditState, _ input: CIImage) -> CIImage { EditPipeline.apply(state, to: input) }

    private func sepia() throws -> CubeLUT { try XCTUnwrap(BuiltInLooks.cube(id: "builtin:sepia")) }

    // MARK: Rendering

    func testLookMatchesTheCubeInPerceptualSpace() throws {
        let cube = try sepia()
        for rgb in [SIMD3<Float>(0.2, 0.2, 0.2), SIMD3(0.6, 0.3, 0.1), SIMD3(0.05, 0.4, 0.8), SIMD3(0.9, 0.9, 0.9)] {
            let out = pixel(render(EditState(lookID: "builtin:sepia"), solid(Double(rgb.x), Double(rgb.y), Double(rgb.z))))
            let want = looked(cube, rgb)
            XCTAssertEqual(out.x, want.x, accuracy: tolerance, "r of \(rgb)")
            XCTAssertEqual(out.y, want.y, accuracy: tolerance, "g of \(rgb)")
            XCTAssertEqual(out.z, want.z, accuracy: tolerance, "b of \(rgb)")
            XCTAssertEqual(out.w, 1, accuracy: 1e-4)
        }
    }

    func testIntensityBlendsLinearlyInPerceptualSpace() throws {
        let cube = try sepia()
        let rgb = SIMD3<Float>(0.5, 0.3, 0.2)
        for intensity in [0.25, 0.5, 0.8] as [Float] {
            var state = EditState(lookID: "builtin:sepia")
            state.lookIntensity = Double(intensity)
            let out = pixel(render(state, solid(0.5, 0.3, 0.2)))
            let want = looked(cube, rgb, intensity: intensity)
            XCTAssertEqual(out.x, want.x, accuracy: tolerance, "intensity \(intensity)")
            XCTAssertEqual(out.z, want.z, accuracy: tolerance, "intensity \(intensity)")
        }
    }

    func testNoLookZeroIntensityNonFiniteIntensityAndUnknownIDAreIdentity() {
        let input = solid(0.5, 0.3, 0.2)
        let base = pixel(render(EditState(), input))
        var zero = EditState(lookID: "builtin:sepia"); zero.lookIntensity = 0
        var nan = EditState(lookID: "builtin:sepia"); nan.lookIntensity = .nan
        var intensityOnly = EditState(); intensityOnly.lookIntensity = 0.3
        for (label, state) in [("zero", zero), ("nan", nan), ("intensity only", intensityOnly),
                               ("unknown builtin", EditState(lookID: "builtin:nope")),
                               ("unknown user", EditState(lookID: "user:deadbeef-Gone"))] {
            XCTAssertEqual(pixel(render(state, input)), base, label)
        }
    }

    func testLookAloneRendersEvenWhenEveryOtherAdjustmentIsIdentity() {
        // The perceptual stage's early-return guard must include the look (an otherwise-identity photo).
        let input = solid(0.5, 0.3, 0.2)
        XCTAssertNotEqual(pixel(render(EditState(lookID: "builtin:vivid"), input)), pixel(render(EditState(), input)))
    }

    // MARK: Headroom, alpha

    func testHighlightsAboveOnePassThroughInsteadOfClipping() throws {
        let cube = try sepia()
        let bright = SIMD3<Float>(2.0, 2.0, 2.0) // linear 2.0 -> perceptual ~1.35
        let out = pixel(render(EditState(lookID: "builtin:sepia"), solid(2, 2, 2)))
        let want = looked(cube, bright)
        XCTAssertEqual(out.x, want.x, accuracy: 0.02)
        XCTAssertEqual(out.y, want.y, accuracy: 0.02)
        let atOne = pixel(render(EditState(lookID: "builtin:sepia"), solid(1, 1, 1)))
        XCTAssertGreaterThan(out.x, atOne.x + 0.1, "2.0 must stay brighter than 1.0 (headroom kept, not clipped to the cube's top)")
    }

    func testNegativeValuesPassThrough() throws {
        let cube = try sepia()
        let out = pixel(render(EditState(lookID: "builtin:sepia"), solid(-0.05, -0.05, -0.05)))
        let want = looked(cube, SIMD3(repeating: -0.05))
        XCTAssertEqual(out.x, want.x, accuracy: 0.01)
        XCTAssertLessThan(out.x, 0, "a below-black value stays below black")
    }

    func testHalfAlphaKeepsAlphaAndLooksTheStraightColor() throws {
        let cube = try sepia()
        let out = pixel(render(EditState(lookID: "builtin:sepia"), solid(0.5, 0.3, 0.2, alpha: 0.5)))
        XCTAssertEqual(out.w, 0.5, accuracy: 1e-3)
        let want = looked(cube, SIMD3(0.5, 0.3, 0.2))
        XCTAssertEqual(out.x / out.w, want.x, accuracy: 0.01, "premultiplied output / alpha = looked straight color")
        XCTAssertEqual(out.z / out.w, want.z, accuracy: 0.01)
    }

    func testFullyTransparentPixelsStayTransparentAndFinite() {
        let out = pixel(render(EditState(lookID: "builtin:teal-orange"), solid(0, 0, 0, alpha: 0)))
        XCTAssertEqual(out.w, 0)
        XCTAssertTrue(out.x.isFinite && out.y.isFinite && out.z.isFinite)
        XCTAssertEqual(out.x, 0, accuracy: 1e-6)
    }

    // MARK: Order

    /// The look is the BASE the user's sliders act on: look-then-contrast (the pipeline's order) equals
    /// contrast applied to an already-looked image, and differs measurably from the reverse order.
    func testLookRunsBeforeContrast() {
        let input = solid(0.4, 0.25, 0.15)
        var both = EditState(lookID: "builtin:warm-film")
        both.contrast = 0.5
        let pipeline = pixel(render(both, input))
        let lookThenContrast = pixel(render(EditState(contrast: 0.5), render(EditState(lookID: "builtin:warm-film"), input)))
        let contrastThenLook = pixel(render(EditState(lookID: "builtin:warm-film"), render(EditState(contrast: 0.5), input)))
        XCTAssertEqual(pipeline.x, lookThenContrast.x, accuracy: 0.003)
        XCTAssertEqual(pipeline.y, lookThenContrast.y, accuracy: 0.003)
        XCTAssertEqual(pipeline.z, lookThenContrast.z, accuracy: 0.003)
        let gap = max(abs(pipeline.x - contrastThenLook.x), abs(pipeline.y - contrastThenLook.y), abs(pipeline.z - contrastThenLook.z))
        print("LOOK-ORDER-GAP look-then-contrast vs contrast-then-look:", gap)
        XCTAssertGreaterThan(gap, 0.01, "the two orders must be measurably different, or the ordering claim is vacuous")
    }

    func testLookComposesWithBlackAndWhite() {
        var state = EditState(lookID: "builtin:teal-orange")
        state.blackAndWhite = true
        let out = pixel(render(state, solid(0.5, 0.3, 0.2)))
        XCTAssertEqual(out.x, out.y, accuracy: 0.003)
        XCTAssertEqual(out.y, out.z, accuracy: 0.003)
    }

    /// Regression tripwire only: every stage of the look is per-pixel (clamp, cube, kernel, mix), so this cannot
    /// fail unless someone introduces a neighborhood operation.
    func testLookIsResolutionIndependent() {
        func edge(size: Int) -> CIImage {
            let left = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.5, alpha: 1, colorSpace: linearSpace)!)
                .cropped(to: CGRect(x: 0, y: 0, width: size / 2, height: size))
            let right = CIImage(color: CIColor(red: 0.8, green: 0.5, blue: 0.1, alpha: 1, colorSpace: linearSpace)!)
                .cropped(to: CGRect(x: size / 2, y: 0, width: size / 2, height: size))
            return left.composited(over: right)
        }
        let state = EditState(lookID: "builtin:cross-process")
        let big = render(state, edge(size: 400)), small = render(state, edge(size: 100))
        XCTAssertEqual(pixel(big, x: 50, y: 200).x, pixel(small, x: 12, y: 50).x, accuracy: 1e-4)
        XCTAssertEqual(pixel(big, x: 350, y: 200).z, pixel(small, x: 87, y: 50).z, accuracy: 1e-4)
    }

    // MARK: User looks through the registry

    func testRegisteredUserLookRendersAndUnregisteringMakesItFailOpen() throws {
        let invert = try XCTUnwrap(CubeLUT.build(size: 17) { SIMD3(1 - $0.x, 1 - $0.y, 1 - $0.z) })
        let id = "user:test-\(UUID().uuidString.prefix(8))-Invert"
        LookLibrary.shared.register(.init(id: id, name: "Invert", cube: invert))
        defer { LookLibrary.shared.unregister(id: id) }
        let input = solid(0.5, 0.3, 0.2)
        let with = pixel(render(EditState(lookID: id), input))
        let want = looked(invert, SIMD3(0.5, 0.3, 0.2))
        XCTAssertEqual(with.x, want.x, accuracy: tolerance)
        LookLibrary.shared.unregister(id: id)
        XCTAssertEqual(pixel(render(EditState(lookID: id), input)), pixel(render(EditState(), input)), "missing user look = no look")
    }

    // MARK: EditState plumbing

    func testCodableRoundTripAndTolerantDefaults() throws {
        var state = EditState(lookID: "builtin:noir")
        state.lookIntensity = 0.4
        let decoded = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.lookID, "builtin:noir")
        XCTAssertEqual(decoded.lookIntensity, 0.4)
        let old = try JSONDecoder().decode(EditState.self, from: Data(#"{ "exposureEV": 1 }"#.utf8))
        XCTAssertEqual(old.lookID, "")
        XCTAssertEqual(old.lookIntensity, 1.0, "the non-zero identity default must survive an absent key")
        let wrongType = try JSONDecoder().decode(EditState.self, from: Data(#"{ "exposureEV": 1, "lookID": 7 }"#.utf8))
        XCTAssertEqual(wrongType.exposureEV, 1, "a mistyped look id must not discard the sidecar")
        XCTAssertEqual(wrongType.lookID, "")
    }

    func testLookCountsAsAnEditAndIsClearedByTheComparisonOriginal() {
        XCTAssertTrue(EditState().isEffectivelyIdentity)
        let state = EditState(lookID: "builtin:vivid")
        XCTAssertFalse(state.isEffectivelyIdentity)
        XCTAssertEqual(state.comparisonOriginal().lookID, "", "Compare's 'original' side must show NO look")
        var intensityOnly = EditState(); intensityOnly.lookIntensity = 0.5
        XCTAssertFalse(intensityOnly.isEffectivelyIdentity, "a literal non-default field is still an edit")
    }

    func testPresetsCarryTheLook() {
        var source = EditState(lookID: "builtin:faded-matte")
        source.lookIntensity = 0.7
        let result = source.applyingPreset(onto: EditState(lookID: "builtin:vivid"))
        XCTAssertEqual(result.lookID, "builtin:faded-matte")
        XCTAssertEqual(result.lookIntensity, 0.7)
    }

    func testHistorySummaryNamesTheLook() {
        let summary = EditStateDiff.summary(from: EditState(), to: EditState(lookID: "builtin:noir"))
        XCTAssertTrue(summary.contains("Look"), summary)
    }
}
