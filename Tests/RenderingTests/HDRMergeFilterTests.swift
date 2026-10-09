import CoreImage
import simd
import XCTest
@testable import PhotoApp

final class HDRMergeFilterTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAh])
    private let extent = CGRect(x: 0, y: 0, width: 2, height: 1)

    private func solid(_ rgb: SIMD3<Float>, alpha: Float = 1, extent: CGRect? = nil) -> CIImage {
        CIImage(color: CIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: CGFloat(alpha), colorSpace: linearSpace)!)
            .cropped(to: extent ?? self.extent)
    }

    private func pixel(_ image: CIImage, x: Int = 0) -> SIMD4<Float> {
        var buffer = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &buffer, rowBytes: 16, bounds: CGRect(x: x, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linearSpace)
        return SIMD4(buffer[0], buffer[1], buffer[2], buffer[3])
    }

    private func merged(_ frames: [(SIMD3<Float>, Float, Float)], intermediates: Bool = false) throws -> SIMD4<Float> {
        let image = try XCTUnwrap(HDRMergeFilter.merge(frames.map { .init(image: solid($0.0, alpha: $0.2), gain: $0.1) }, extent: extent,
                                                       materializeBetweenPasses: intermediates))
        return pixel(image)
    }

    /// The GPU kernels must agree with the pure reference on a spread of inputs, including values above 1 and clipped channels.
    func testKernelMatchesTheReferenceMathAcrossManyInputs() throws {
        let radiances: [SIMD3<Float>] = [SIMD3(0.01, 0.02, 0.015), SIMD3(0.2, 0.15, 0.1), SIMD3(0.6, 0.5, 0.45), SIMD3(2.5, 1.4, 0.9), SIMD3(5, 5, 4),
                                          SIMD3(1.6, 0.3, 0.05), SIMD3(0.9, 0.04, 0.5)] // channels that clip at different frames
        let gains: [Float] = [0.25, 1, 4]
        for radiance in radiances {
            let frames = gains.map { g in (simd_clamp(radiance * g, .zero, SIMD3(repeating: 1)), g, Float(1)) }
            let expected = try XCTUnwrap(HDRMergeMath.merge(frames.map { .init(linear: $0.0, gain: $0.1) }))
            let got = try merged(frames)
            XCTAssertEqual(got.x, expected.x, accuracy: max(expected.x * 0.01, 2e-4), "r for \(radiance)")
            XCTAssertEqual(got.y, expected.y, accuracy: max(expected.y * 0.01, 2e-4), "g for \(radiance)")
            XCTAssertEqual(got.z, expected.z, accuracy: max(expected.z * 0.01, 2e-4), "b for \(radiance)")
            XCTAssertEqual(got.w, 1, accuracy: 1e-4)
        }
    }

    func testHighlightAboveOneComesBackFromTheUnderexposedFrame() throws {
        let radiance = SIMD3<Float>(3.0, 2.4, 1.8)
        let got = try merged([0.25, 1, 4].map { g in (simd_clamp(radiance * g, .zero, SIMD3(repeating: 1)), g, Float(1)) })
        XCTAssertEqual(got.x, 3.0, accuracy: 0.05)
        XCTAssertEqual(got.y, 2.4, accuracy: 0.05)
        XCTAssertEqual(got.z, 1.8, accuracy: 0.05)
    }

    /// A frame with alpha 0 (outside the warped extent) must contribute nothing; with every frame transparent the result is transparent.
    func testTransparentFrameContributesNothingAndAllTransparentStaysTransparent() throws {
        let with = try merged([(SIMD3(0.1, 0.1, 0.1), 1, 1), (SIMD3(0.9, 0.9, 0.9), 1, 0)])
        XCTAssertEqual(with.x, 0.1, accuracy: 2e-4)
        let none = try merged([(SIMD3(0.5, 0.5, 0.5), 1, 0), (SIMD3(0.5, 0.5, 0.5), 2, 0)])
        XCTAssertEqual(none.w, 0, accuracy: 1e-6)
    }

    /// A frame with PARTIAL alpha (an edge pixel of a warped frame) is weighted by that validity: kernel == reference with validity 0.25.
    func testPartialAlphaScalesTheFramesWeight() throws {
        let a = SIMD3<Float>(0.05, 0.05, 0.05), b = SIMD3<Float>(0.2, 0.2, 0.2)
        let expected = try XCTUnwrap(HDRMergeMath.merge([.init(linear: a, gain: 1), .init(linear: b, gain: 1, validity: 0.25)]))
        let unweighted = try XCTUnwrap(HDRMergeMath.merge([.init(linear: a, gain: 1), .init(linear: b, gain: 1)]))
        XCTAssertGreaterThan(abs(expected.x - unweighted.x), 0.01, "fixture must distinguish validity-weighted from unweighted")
        let got = try merged([(a, 1, 1), (b, 1, 0.25)])
        XCTAssertEqual(got.x, expected.x, accuracy: 1e-3)
    }

    /// DOCUMENTED LIMIT (IMPROVEMENTS.md): an all-dark bracket (brightest frame x ~ radiance at gain 1) is accurate down to a radiance of about
    /// 3e-4 at the half-float intermediate path; below ~1e-4 the packed rgb is quantised. Asserts the accurate side of that bound only.
    func testAllDarkBracketIsAccurateAboveTheDocumentedFloor() throws {
        let radiance = SIMD3<Float>(3e-4, 3e-4, 3e-4)
        let frames = [Float(1.0 / 16), 0.25, 1].map { g in (radiance * g, g, Float(1)) }
        let expected = try XCTUnwrap(HDRMergeMath.merge(frames.map { .init(linear: $0.0, gain: $0.1) }))
        for materialize in [false, true] {
            let got = try merged(frames, intermediates: materialize)
            XCTAssertEqual(got.x, expected.x, accuracy: expected.x * 0.03, "intermediates \(materialize)")
        }
    }

    func testEmptyOversizedOrOutOfRangeFrameListsYieldNil() {
        XCTAssertNil(HDRMergeFilter.merge([], extent: extent))
        let tooMany = (0..<(HDRMergeFilter.maxFrames + 1)).map { _ in HDRMergeFilter.Frame(image: solid(SIMD3(repeating: 0.2)), gain: 1) }
        XCTAssertNil(HDRMergeFilter.merge(tooMany, extent: extent))
        XCTAssertNil(HDRMergeFilter.merge([.init(image: solid(SIMD3(repeating: 0.2)), gain: 32)], extent: extent))
    }

    /// Core Image may store a half-float buffer between accumulate passes. Forcing one must not change the result: all-clipped pixels
    /// (only the weight FLOOR contributes), deep shadows, and a 9-frame bracket at the extreme gains. Before the packing scale these came back
    /// +69% (clipped radiance 20) and -6% (shadow 5e-4) per the reviewer's probe.
    func testResultDoesNotDependOnIntermediateBuffersBetweenPasses() throws {
        let cases: [(name: String, radiance: SIMD3<Float>, gains: [Float])] = [
            ("all-clipped highlight", SIMD3(20, 20, 20), [1.0 / 16, 0.25, 1, 4, 16, 1.0 / 8, 2, 8, 1.0 / 4]),
            ("three-frame all-clipped", SIMD3(5, 5, 4), [0.25, 1, 4]),
            ("deep shadow", SIMD3(0.0005, 0.0004, 0.0003), [1.0 / 16, 0.25, 1, 4, 16, 1.0 / 8, 2, 8, 1.0 / 4]),
            ("mid-tone", SIMD3(0.3, 0.2, 0.1), [0.25, 1, 4]),
        ]
        for c in cases {
            let frames = c.gains.map { g in (simd_clamp(c.radiance * g, .zero, SIMD3(repeating: 1)), g, Float(1)) }
            let expected = try XCTUnwrap(HDRMergeMath.merge(frames.map { .init(linear: $0.0, gain: $0.1) }))
            for materialize in [false, true] {
                let got = try merged(frames, intermediates: materialize)
                XCTAssertEqual(got.x, expected.x, accuracy: max(expected.x * 0.02, 1e-5), "\(c.name) r, intermediates \(materialize)")
                XCTAssertEqual(got.z, expected.z, accuracy: max(expected.z * 0.02, 1e-5), "\(c.name) b, intermediates \(materialize)")
            }
        }
    }

    /// Frame ORDER must not matter (the accumulator is a plain sum) — within half-float rounding.
    func testFrameOrderDoesNotMatter() throws {
        let radiance = SIMD3<Float>(0.3, 0.2, 0.1)
        let frames = [0.5, 1, 2].map { g in (simd_clamp(radiance * Float(g), .zero, SIMD3(repeating: 1)), Float(g), Float(1)) }
        let a = try merged(frames), b = try merged(frames.reversed())
        XCTAssertEqual(a.x, b.x, accuracy: 1e-3)
        XCTAssertEqual(a.z, b.z, accuracy: 1e-3)
    }
}
