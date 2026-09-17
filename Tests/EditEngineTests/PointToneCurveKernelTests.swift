import CoreImage
import XCTest
@testable import PhotoApp

/// Checks that `PointToneCurve.cikernel` and `MonotoneToneCurve` — the same
/// maths written twice, in two languages — actually agree. Nothing else
/// stops them drifting apart.
///
/// It also fails loudly if the `.cikernel` goes missing from the bundle:
/// that failure mode returns the image UNCHANGED, which looks exactly like a
/// working identity curve and has bitten this project before.
final class PointToneCurveKernelTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linearSpace,
        .workingFormat: CIFormat.RGBAf
    ])
    private let accuracy: Double = 0.002

    private func solidColorImage(_ value: Double) -> CIImage {
        let color = CIColor(red: value, green: value, blue: value, alpha: 1, colorSpace: linearSpace)!
        return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func linearPixel(of image: CIImage) -> (r: Float, g: Float, b: Float, a: Float) {
        var buffer = [Float](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &buffer, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf, colorSpace: linearSpace
        )
        return (buffer[0], buffer[1], buffer[2], buffer[3])
    }

    private func points(_ pairs: [(Double, Double)]) -> [ToneCurvePoint] {
        pairs.map { ToneCurvePoint(x: $0.0, y: $0.1) }
    }

    func testKernelMatchesTheSwiftTwin() {
        // Sweeps several point COUNTS as well as several inputs: 2, 3, 5 and
        // 8 all render through the same fixed-arity kernel via the pad-to-8
        // scheme, so this is what proves padding is output-identical across
        // N on the real GPU path, not just in Swift.
        let cases: [(name: String, points: [ToneCurvePoint])] = [
            ("2 points, lifted", points([(0, 0.15), (1, 1)])),
            ("3 points, S-curve", points([(0, 0), (0.5, 0.62), (1, 1)])),
            ("5 points", points([(0, 0.05), (0.25, 0.18), (0.5, 0.5), (0.75, 0.86), (1, 0.97)])),
            ("8 points, full arity", points([
                (0, 0), (0.14, 0.10), (0.28, 0.30), (0.42, 0.44),
                (0.56, 0.60), (0.70, 0.78), (0.85, 0.90), (1, 1)
            ]))
        ]

        for testCase in cases {
            let curve = MonotoneToneCurve(points: testCase.points)!
            for input in [0.002, 0.01, 0.05, 0.214, 0.5, 0.7, 0.95, 1.0, 1.2, 1.6] {
                let output = EditPipeline.apply(
                    EditState(toneCurvePoints: testCase.points), to: solidColorImage(input)
                )
                // applyPointCurve runs INSIDE encodeToPerceptual/
                // decodeToLinear, so the value reaching the curve is already
                // perceptual — hence the outer encode/decode here. The
                // curve's own second encode lives inside value(at:).
                let expected = ToneCurveSpline.srgbDecode(curve.value(at: ToneCurveSpline.srgbEncode(input)))
                XCTAssertEqual(
                    Double(linearPixel(of: output).r), expected, accuracy: accuracy,
                    "\(testCase.name) at linear \(input)"
                )
            }
        }
    }

    func testPaddingDoesNotChangeTheRenderedResult() {
        // Makes the collinearity argument behind pad-to-8 a CHECKED claim
        // rather than a comment: a 3-point curve and the same curve
        // hand-padded to the kernel's full arity must render identically.
        let real = points([(0, 0), (0.4, 0.55), (1, 1)])
        let padded = MonotoneToneCurve(points: real)!.paddedForKernel().points

        XCTAssertEqual(padded.count, MonotoneToneCurve.maximumPointCount)
        XCTAssertNotEqual(padded, real, "the fixture must actually differ, or this proves nothing")

        for input in [0.05, 0.3, 0.7, 1.0, 1.4] {
            let a = linearPixel(of: EditPipeline.apply(EditState(toneCurvePoints: real), to: solidColorImage(input)))
            let b = linearPixel(of: EditPipeline.apply(EditState(toneCurvePoints: padded), to: solidColorImage(input)))
            XCTAssertEqual(Double(a.r), Double(b.r), accuracy: 1e-5, "at linear \(input)")
        }
    }

    func testPointCurvePreservesAlpha() {
        let color = CIColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 0.5, colorSpace: linearSpace)!
        let input = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let output = EditPipeline.apply(
            EditState(toneCurvePoints: points([(0, 0), (0.5, 0.65), (1, 1)])), to: input
        )
        XCTAssertEqual(linearPixel(of: output).a, 0.5, accuracy: 0.002)
    }
}
