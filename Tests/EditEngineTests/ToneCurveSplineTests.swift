import CoreImage
import XCTest
@testable import PhotoApp

/// Covers the spline solve behind `ToneCurve.cikernel` — the maths that
/// replaced `CIToneCurve` in Curves v2 slice 1 — without needing a
/// `CIContext`, plus one test that checks the GPU kernel and this Swift twin
/// genuinely agree rather than merely both existing.
final class ToneCurveSplineTests: XCTestCase {
    private let accuracy = 0.002

    /// Mirrors `EditPipeline.curveControlPoints` (private there). Kept
    /// deliberately as a literal copy: if that mapping changes, the twin
    /// test below starts failing, which is the intended alarm.
    private func controlPoints(shadows: Double = 0, highlights: Double = 0, blackPoint: Double = 0) -> [CGPoint] {
        [
            CGPoint(x: max(0, -blackPoint) * 0.20, y: max(0, blackPoint) * 0.20),
            CGPoint(x: 0.25, y: 0.25 + shadows * 0.15),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.75, y: 0.75 + highlights * 0.15),
            CGPoint(x: 1, y: 1)
        ]
    }

    // MARK: - The solve itself

    func testNaturalEndConditionPinsSecondDerivativesToZero() {
        // "Natural" is not a label here — it is the end condition that makes
        // the fit match CIToneCurve to 3e-7. Catmull-Rom and monotone cubic
        // were both measured and both wrong (0.016 and 0.046); see
        // PROGRESS.md's pre-work section.
        let spline = ToneCurveSpline(points: controlPoints(shadows: 1))!
        XCTAssertEqual(spline.secondDerivatives.first!, 0, accuracy: 1e-12)
        XCTAssertEqual(spline.secondDerivatives.last!, 0, accuracy: 1e-12)
    }

    func testSplinePassesThroughItsOwnControlPoints() {
        // The property the FIRST reverse-engineering probe assumed and that
        // CIToneCurve itself famously does NOT satisfy in linear space (it
        // returned 0.23731 at the (0.25, 0.40) control point) — because its
        // control points live in sRGB space. This spline is fed sRGB-space
        // values directly, so here the property must hold exactly.
        let points = controlPoints(shadows: 1, highlights: -1)
        let spline = ToneCurveSpline(points: points)!
        for point in points {
            // value(at:) encodes its input first, so feed the linear value
            // whose encoding IS the control point's x.
            let linearInput = ToneCurveSpline.srgbDecode(Double(point.x))
            XCTAssertEqual(
                spline.value(at: linearInput),
                ToneCurveSpline.srgbDecode(Double(point.y)),
                accuracy: 1e-9,
                "at control point \(point)"
            )
        }
    }

    func testRejectsDegenerateControlPoints() {
        // A zero-width interval would divide by zero in the solve. Callers
        // treat nil as "leave the image alone", never as "carry on".
        XCTAssertNil(ToneCurveSpline(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 1)]))
        XCTAssertNil(ToneCurveSpline(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0.7, y: 0.5), CGPoint(x: 0.3, y: 1)]))
        XCTAssertNil(ToneCurveSpline(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]))
    }

    // MARK: - The deliberately asymmetric out-of-domain rules

    func testClampsBelowTheBlackPointRatherThanExtrapolating() {
        // Black Point's whole purpose: below point0.x everything is black.
        // Linear extrapolation here would go NEGATIVE instead — this is why
        // the fix is applied to the top end only.
        let spline = ToneCurveSpline(points: controlPoints(blackPoint: -1))!
        let belowBlackPoint = ToneCurveSpline.srgbDecode(0.1)
        XCTAssertEqual(spline.value(at: belowBlackPoint), 0, accuracy: 1e-12)
        XCTAssertEqual(spline.value(at: -0.5), 0, accuracy: 1e-12)
    }

    func testClampBelowUsesPoint0YNotZero() {
        // Black Point on its LIFT side puts point0 at (0, 0.20): the clamp
        // floor is the control point's own y, so a lifted black stays lifted
        // all the way down. Matches CIToneCurve, which read 0.03310 here.
        let spline = ToneCurveSpline(points: controlPoints(blackPoint: 1))!
        XCTAssertEqual(spline.value(at: 0), ToneCurveSpline.srgbDecode(0.20), accuracy: 1e-12)
    }

    func testExtrapolatesLinearlyAboveTheLastControlPoint() {
        // The headroom fix. Beyond x4 the curve follows its own end slope,
        // so equal steps in the encoded domain give equal steps in output —
        // that constant first difference is what "linear" means here, and is
        // what distinguishes it from continuing the cubic (which curves away)
        // and from CIToneCurve's clamp (which flatlines at 1.0).
        let spline = ToneCurveSpline(points: controlPoints(shadows: 1))!
        let encodedSteps = [1.0, 1.1, 1.2, 1.3]
        let outputs = encodedSteps.map { spline.value(at: ToneCurveSpline.srgbDecode($0)) }
            .map { ToneCurveSpline.srgbEncode($0) }

        let firstDifference = outputs[1] - outputs[0]
        XCTAssertGreaterThan(firstDifference, 0, "must keep climbing, not flatline as CIToneCurve did")
        XCTAssertEqual(outputs[2] - outputs[1], firstDifference, accuracy: 1e-9)
        XCTAssertEqual(outputs[3] - outputs[2], firstDifference, accuracy: 1e-9)
    }

    func testExtrapolationIsContinuousWithTheFinalSegment() {
        // C1, not merely C0: the extrapolation uses the spline's OWN
        // derivative at x4, so there is no kink at the seam. A step or kink
        // would band the brightest tones of a real photo.
        for highlights in [-1.0, 0.0, 1.0] {
            let spline = ToneCurveSpline(points: controlPoints(highlights: highlights))!
            let justBelow = ToneCurveSpline.srgbEncode(spline.value(at: ToneCurveSpline.srgbDecode(0.9999)))
            let atEnd = ToneCurveSpline.srgbEncode(spline.value(at: ToneCurveSpline.srgbDecode(1.0)))
            let justAbove = ToneCurveSpline.srgbEncode(spline.value(at: ToneCurveSpline.srgbDecode(1.0001)))

            XCTAssertEqual(atEnd, 1.0, accuracy: 1e-9, "highlights \(highlights)")
            // Slopes either side of the seam match to well under a rounding
            // step — a kink would show as a mismatch here.
            XCTAssertEqual(justAbove - atEnd, atEnd - justBelow, accuracy: 1e-5, "highlights \(highlights)")
        }
    }

    // MARK: - Swift twin vs. the real compiled kernel

    func testKernelMatchesTheSwiftTwin() {
        // The twin check: ToneCurve.cikernel and ToneCurveSpline implement
        // the same maths in two languages, and nothing but this test stops
        // them drifting apart. Runs the REAL pipeline (so the real compiled
        // kernel) and compares against the Swift model applied by hand
        // through the same encode/decode sandwich applyCurves sits inside.
        //
        // It also fails loudly if the .cikernel goes missing from the bundle:
        // that failure mode returns the image UNCHANGED, which looks exactly
        // like a working identity curve and has bitten this project before.
        let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])

        let cases: [(name: String, state: EditState, points: [CGPoint])] = [
            ("shadows +1", EditState(curvesShadows: 1), controlPoints(shadows: 1)),
            ("shadows -1", EditState(curvesShadows: -1), controlPoints(shadows: -1)),
            ("highlights +1", EditState(curvesHighlights: 1), controlPoints(highlights: 1)),
            ("highlights -1", EditState(curvesHighlights: -1), controlPoints(highlights: -1)),
            ("black point -1", EditState(blackPoint: -1), controlPoints(blackPoint: -1)),
            ("black point +1", EditState(blackPoint: 1), controlPoints(blackPoint: 1))
        ]

        for testCase in cases {
            let spline = ToneCurveSpline(points: testCase.points)!
            for input in [0.002, 0.01, 0.05, 0.214, 0.5, 0.7, 0.95, 1.0, 1.2, 1.6] {
                let color = CIColor(red: input, green: input, blue: input, alpha: 1, colorSpace: linearSpace)!
                let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
                var buffer = [Float](repeating: 0, count: 4)
                context.render(
                    EditPipeline.apply(testCase.state, to: image),
                    toBitmap: &buffer, rowBytes: 16,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBAf, colorSpace: linearSpace
                )

                // applyCurves runs INSIDE encodeToPerceptual/decodeToLinear,
                // so the value reaching the curve is already perceptual —
                // hence the outer encode/decode here. The curve's own second
                // encode lives inside value(at:).
                let expected = ToneCurveSpline.srgbDecode(spline.value(at: ToneCurveSpline.srgbEncode(input)))

                XCTAssertEqual(
                    Double(buffer[0]), expected, accuracy: accuracy,
                    "\(testCase.name) at linear \(input)"
                )
            }
        }
    }
}
