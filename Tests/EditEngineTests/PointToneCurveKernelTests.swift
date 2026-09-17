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

    // MARK: - Curves v2 slice 3 — per-channel curves

    /// The composite curve's render must be BYTE-IDENTICAL after slice 3's
    /// `channelMask` argument was added to the kernel — these four values
    /// were captured from the real, compiled kernel immediately BEFORE that
    /// change (the same "3 points, S-curve" fixture `testKernelMatchesTheSwiftTwin`
    /// already uses), specifically so this is an exact regression gate, not
    /// just a re-check against the 0.002-tolerance Swift twin above (which
    /// could in principle hide a small drift within its own budget).
    func testCompositeCurveRenderIsUnchangedByTheChannelMaskArgument() {
        let curvePoints = points([(0, 0), (0.5, 0.62), (1, 1)])
        let captured: [Double: Float] = [
            0.05: 0.122585,
            0.214: 0.35345027,
            0.5: 0.6141887,
            0.95: 0.96203387,
        ]
        for (input, expected) in captured {
            let px = linearPixel(of: EditPipeline.apply(EditState(toneCurvePoints: curvePoints), to: solidColorImage(input)))
            XCTAssertEqual(px.r, expected, accuracy: 0, "at linear \(input)")
            XCTAssertEqual(px.g, expected, accuracy: 0, "at linear \(input)")
            XCTAssertEqual(px.b, expected, accuracy: 0, "at linear \(input)")
        }
    }

    /// A red curve must leave green/blue BIT-IDENTICAL to an untouched
    /// render — proof that `channelMask`'s ternary select, not `mix()`, is
    /// doing its job.
    ///
    /// NOT `accuracy: 0` — measured, not assumed: comparing against a
    /// render from a fully-EMPTY `EditState` takes a DIFFERENT code path
    /// (`pointCurveActive` is false, so `applyPerceptualAdjustments`'
    /// whole sandwich is skipped entirely), while the red-curve render
    /// enters that sandwich's `encodeToPerceptual`/`decodeToLinear`
    /// round-trip on EVERY channel, including green/blue. That round-trip
    /// alone measured ~1e-7 off exact even for an untouched value (0.3 ->
    /// 0.2999999) — real, sub-tolerance floating-point noise from entering
    /// the sandwich at all, unrelated to the channel-mask logic this test
    /// is actually checking. `1e-5` is comfortably above that measured
    /// noise floor and comfortably below the suite's own 0.002 budget.
    func testChannelMaskLeavesOtherChannelsUnaffectedByTheCurve() {
        let redCurve = points([(0, 0), (0.5, 0.85), (1, 1)])
        var state = EditState()
        state.toneCurvePointsRed = redCurve
        let input = solidColorImage(0.3)
        let output = linearPixel(of: EditPipeline.apply(state, to: input))
        let untouched = linearPixel(of: EditPipeline.apply(EditState(), to: input))

        XCTAssertNotEqual(output.r, untouched.r, "the fixture must actually move the red channel, or this proves nothing")
        XCTAssertEqual(Double(output.g), Double(untouched.g), accuracy: 1e-5)
        XCTAssertEqual(Double(output.b), Double(untouched.b), accuracy: 1e-5)
    }

    /// Each channel curve independently matches the Swift twin on its OWN
    /// component — the per-channel twin of `testKernelMatchesTheSwiftTwin`
    /// above, which only ever asserted `.r` (safe before slice 3, since
    /// every channel got the identical composite curve).
    func testEachChannelCurveMatchesTheSwiftTwinOnItsOwnChannel() {
        let curvePoints = points([(0, 0.05), (0.4, 0.3), (0.7, 0.82), (1, 0.97)])
        let curve = MonotoneToneCurve(points: curvePoints)!
        for input in [0.05, 0.214, 0.5, 0.7, 0.95] {
            let expected = Double(ToneCurveSpline.srgbDecode(curve.value(at: ToneCurveSpline.srgbEncode(input))))

            var redState = EditState(); redState.toneCurvePointsRed = curvePoints
            let redPixel = linearPixel(of: EditPipeline.apply(redState, to: solidColorImage(input)))
            XCTAssertEqual(Double(redPixel.r), expected, accuracy: accuracy, "red at \(input)")

            var greenState = EditState(); greenState.toneCurvePointsGreen = curvePoints
            let greenPixel = linearPixel(of: EditPipeline.apply(greenState, to: solidColorImage(input)))
            XCTAssertEqual(Double(greenPixel.g), expected, accuracy: accuracy, "green at \(input)")

            var blueState = EditState(); blueState.toneCurvePointsBlue = curvePoints
            let bluePixel = linearPixel(of: EditPipeline.apply(blueState, to: solidColorImage(input)))
            XCTAssertEqual(Double(bluePixel.b), expected, accuracy: accuracy, "blue at \(input)")
        }
    }

    /// All four curves active at once, plus alpha < 1 — alpha preservation
    /// only, same scope as `testPointCurvePreservesAlpha` above, now with
    /// all four passes live rather than one. NOT an RGB round-trip
    /// assertion: computing an independently-derived expected RGB for a
    /// four-pass composite+per-channel chain would need this suite to take
    /// a position on this kernel's un/re-premultiply convention that no
    /// other test here asserts either — see `testEachChannelCurveMatchesTheSwiftTwinOnItsOwnChannel`
    /// above for the RGB-correctness gate, at alpha 1.
    func testAllFourCurvesActiveWithPartialAlphaStaysWithinTolerance() {
        var state = EditState()
        state.toneCurvePoints = points([(0, 0), (0.5, 0.58), (1, 1)])
        state.toneCurvePointsRed = points([(0, 0), (0.5, 0.7), (1, 1)])
        state.toneCurvePointsGreen = points([(0, 0), (0.5, 0.4), (1, 1)])
        state.toneCurvePointsBlue = points([(0, 0), (0.5, 0.55), (1, 1)])
        let color = CIColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 0.5, colorSpace: linearSpace)!
        let input = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let output = linearPixel(of: EditPipeline.apply(state, to: input))
        XCTAssertEqual(output.a, 0.5, accuracy: 0.002)
    }
}
