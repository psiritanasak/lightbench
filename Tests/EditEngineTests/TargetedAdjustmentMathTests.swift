import XCTest
import CoreImage
@testable import PhotoApp

final class TargetedAdjustmentMathTests: XCTestCase {
    // MARK: - delta

    func testDeltaIsDragOverPaneHeight() {
        XCTAssertEqual(TargetedAdjustmentMath.delta(upwardDrag: 100, paneHeight: 400), 0.25, accuracy: 1e-12)
        XCTAssertEqual(TargetedAdjustmentMath.delta(upwardDrag: -200, paneHeight: 400), -0.5, accuracy: 1e-12)
        XCTAssertEqual(TargetedAdjustmentMath.delta(upwardDrag: 400, paneHeight: 400), 1.0, accuracy: 1e-12)
    }

    func testDeltaRefusesDegenerateInput() {
        XCTAssertEqual(TargetedAdjustmentMath.delta(upwardDrag: 10, paneHeight: 0), 0)
        XCTAssertEqual(TargetedAdjustmentMath.delta(upwardDrag: .nan, paneHeight: 100), 0)
        XCTAssertEqual(TargetedAdjustmentMath.delta(upwardDrag: 10, paneHeight: .infinity), 0)
    }

    // MARK: - curveX

    func testCurveXIsEncodedRec709Luma() {
        // Grey: luma == the grey, then encoded once more.
        let grey = TargetedAdjustmentMath.curveX(forPerceptualRGB: 0.5, 0.5, 0.5)
        XCTAssertEqual(grey, PerceptualEncoding.srgbEncode(0.5), accuracy: 1e-9)
        // Weights: pure green carries 0.7152.
        let green = TargetedAdjustmentMath.curveX(forPerceptualRGB: 0, 1, 0)
        XCTAssertEqual(green, PerceptualEncoding.srgbEncode(0.7152), accuracy: 1e-9)
        let red = TargetedAdjustmentMath.curveX(forPerceptualRGB: 1, 0, 0)
        XCTAssertEqual(red, PerceptualEncoding.srgbEncode(0.2126), accuracy: 1e-9)
    }

    func testCurveXClampsAndSurvivesNonFinite() {
        XCTAssertEqual(TargetedAdjustmentMath.curveX(forPerceptualRGB: 2, 2, 2), 1, accuracy: 1e-12)
        XCTAssertEqual(TargetedAdjustmentMath.curveX(forPerceptualRGB: -1, -1, -1), 0, accuracy: 1e-12)
        XCTAssertEqual(TargetedAdjustmentMath.curveX(forPerceptualRGB: .nan, 0, 0), 0)
    }

    // MARK: - CurveDrag point selection

    func testEmptyCurveAddsAPointAtTheSampleOnTheDiagonal() throws {
        let drag = try XCTUnwrap(TargetedAdjustmentMath.CurveDrag(points: [], x: 0.5))
        XCTAssertEqual(drag.basePoints.count, 3)
        XCTAssertEqual(drag.basePoints[1].x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(drag.basePoints[1].y, 0.5, accuracy: 1e-6, "an added point starts ON the current curve (no jump)")
        XCTAssertEqual(drag.index, 1)
        XCTAssertEqual(drag.points(forDelta: 0), [], "zero delta leaves the curve exactly as it was")
    }

    func testPointWithinSnapDistanceIsMovedNotAdded() throws {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.6), ToneCurvePoint(x: 1, y: 1)]
        let drag = try XCTUnwrap(TargetedAdjustmentMath.CurveDrag(points: points, x: 0.5 + 0.039))
        XCTAssertEqual(drag.index, 1)
        XCTAssertEqual(drag.basePoints.count, 3)
        let moved = drag.points(forDelta: 0.1)
        XCTAssertEqual(moved.count, 3)
        XCTAssertEqual(moved[1].x, 0.5, accuracy: 1e-12, "x of a moved point is kept")
        XCTAssertEqual(moved[1].y, 0.7, accuracy: 1e-9)
    }

    func testPointJustBeyondSnapDistanceAddsANewOne() throws {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.6), ToneCurvePoint(x: 1, y: 1)]
        let drag = try XCTUnwrap(TargetedAdjustmentMath.CurveDrag(points: points, x: 0.5 + 0.045))
        XCTAssertEqual(drag.basePoints.count, 4)
        XCTAssertEqual(drag.basePoints[drag.index].x, 0.545, accuracy: 1e-9)
    }

    func testEndpointNearTheSampleMovesInYOnly() throws {
        let drag = try XCTUnwrap(TargetedAdjustmentMath.CurveDrag(points: [], x: 0.02))
        XCTAssertEqual(drag.index, 0)
        let moved = drag.points(forDelta: 0.2)
        XCTAssertEqual(moved.first?.x, 0, "endpoint x stays pinned at 0")
        XCTAssertEqual(try XCTUnwrap(moved.first).y, 0.2, accuracy: 1e-9)
        XCTAssertEqual(moved.count, 2)
    }

    func testAtTheCapTheNearestPointMovesAndNoneIsAdded() throws {
        let points = (0..<8).map { ToneCurvePoint(x: Double($0) / 7, y: Double($0) / 7) }
        let drag = try XCTUnwrap(TargetedAdjustmentMath.CurveDrag(points: points, x: 0.2))
        XCTAssertEqual(drag.basePoints.count, 8)
        XCTAssertEqual(drag.index, 1, "x 0.2 is nearest 1/7 = 0.143")
        XCTAssertEqual(drag.points(forDelta: 0.05).count, 8)
    }

    func testDragIsClampedToTheUnitSquare() throws {
        let drag = try XCTUnwrap(TargetedAdjustmentMath.CurveDrag(points: [], x: 0.5))
        XCTAssertEqual(drag.points(forDelta: 5)[1].y, 1, accuracy: 1e-12)
        XCTAssertEqual(drag.points(forDelta: -5)[1].y, 0, accuracy: 1e-12)
    }

    func testDraggingBackToTheDiagonalAfterAnAddedPointKeepsAValidCurve() throws {
        let drag = try XCTUnwrap(TargetedAdjustmentMath.CurveDrag(points: [], x: 0.5))
        let result = drag.points(forDelta: 1e-9)
        XCTAssertNotNil(MonotoneToneCurve(points: result))
    }

    func testResultIsAlwaysAValidCurve() throws {
        let drag = try XCTUnwrap(TargetedAdjustmentMath.CurveDrag(points: [], x: 0.3))
        for delta in stride(from: -1.0, through: 1.0, by: 0.1) {
            XCTAssertNotNil(MonotoneToneCurve(points: drag.points(forDelta: delta)), "delta \(delta)")
        }
    }

    /// The dragged point may not cross its neighbours' heights, so the curve can never invert.
    func testDraggedPointStaysBetweenItsNeighboursHeights() throws {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.3, y: 0.4), ToneCurvePoint(x: 0.7, y: 0.6), ToneCurvePoint(x: 1, y: 1)]
        let drag = try XCTUnwrap(TargetedAdjustmentMath.CurveDrag(points: points, x: 0.3))
        XCTAssertEqual(drag.index, 1)
        XCTAssertEqual(drag.points(forDelta: 0.5)[1].y, 0.6, accuracy: 1e-12, "capped at the next point's height")
        XCTAssertEqual(drag.points(forDelta: -0.9)[1].y, 0, accuracy: 1e-12, "floored at the previous point's height")
        let upper = try XCTUnwrap(TargetedAdjustmentMath.CurveDrag(points: points, x: 0.7))
        XCTAssertEqual(upper.points(forDelta: -0.9)[2].y, 0.4, accuracy: 1e-12)
    }

    func testNoDragEverProducesAnInvertedCurve() throws {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.3, y: 0.4), ToneCurvePoint(x: 0.7, y: 0.6), ToneCurvePoint(x: 1, y: 1)]
        for x in stride(from: 0.0, through: 1.0, by: 0.05) {
            let drag = try XCTUnwrap(TargetedAdjustmentMath.CurveDrag(points: points, x: x))
            for delta in stride(from: -1.2, through: 1.2, by: 0.1) {
                let ys = drag.points(forDelta: delta).map(\.y)
                XCTAssertEqual(ys, ys.sorted(), "x \(x) delta \(delta): \(ys)")
            }
        }
    }

    func testEndpointDragCannotCrossItsNeighbour() throws {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.3), ToneCurvePoint(x: 1, y: 1)]
        let drag = try XCTUnwrap(TargetedAdjustmentMath.CurveDrag(points: points, x: 0.01))
        XCTAssertEqual(drag.index, 0)
        XCTAssertEqual(drag.points(forDelta: 0.9)[0].y, 0.3, accuracy: 1e-12)
    }

    func testInvalidInputGivesNoDrag() {
        XCTAssertNil(TargetedAdjustmentMath.CurveDrag(points: [], x: .nan))
        let unsorted = [ToneCurvePoint(x: 0.5, y: 0.5), ToneCurvePoint(x: 0.2, y: 0.2)]
        XCTAssertNil(TargetedAdjustmentMath.CurveDrag(points: unsorted, x: 0.3))
    }

    // MARK: - bandDeltas

    func testBandDeltasScaleByWeightOverMax() throws {
        let weights = [0.2, 0.8, 0.4, 0, 0, 0, 0, 0]
        let deltas = try XCTUnwrap(TargetedAdjustmentMath.bandDeltas(weights: weights, delta: 0.5))
        XCTAssertEqual(deltas[1], 0.5, accuracy: 1e-12, "the strongest band moves by the full delta")
        XCTAssertEqual(deltas[0], 0.125, accuracy: 1e-12)
        XCTAssertEqual(deltas[2], 0.25, accuracy: 1e-12)
        XCTAssertEqual(deltas[3], 0)
    }

    func testBandDeltasNilForANeutralPixel() {
        XCTAssertNil(TargetedAdjustmentMath.bandDeltas(weights: Array(repeating: 0, count: 8), delta: 0.5))
        XCTAssertNil(TargetedAdjustmentMath.bandDeltas(weights: [0.00005, 0, 0, 0, 0, 0, 0, 0], delta: 0.5))
    }

    /// A nearly neutral pixel (peak weight under the cutoff) starts no drag; at the cutoff it does.
    func testBandDeltasPeakWeightCutoff() {
        XCTAssertEqual(TargetedAdjustmentMath.minimumPeakWeight, 0.05)
        XCTAssertNil(TargetedAdjustmentMath.bandDeltas(weights: [0.049, 0.01, 0, 0, 0, 0, 0, 0], delta: 0.5))
        let atCutoff = TargetedAdjustmentMath.bandDeltas(weights: [0.05, 0.01, 0, 0, 0, 0, 0, 0], delta: 0.5)
        XCTAssertEqual(atCutoff?[0] ?? 0, 0.5, accuracy: 1e-12)
    }

    func testApplyingBandDeltasClampsToUnitRange() {
        var start = EditState()
        start.redSaturation = 0.9
        start.orangeSaturation = -0.9
        let result = TargetedAdjustmentMath.applyingBandDeltas(
            [0.5, -0.5, 0, 0, 0, 0, 0, 0],
            keyPaths: SelectiveColorBandWeights.selectiveColorKeyPaths(for: .saturation), to: start)
        XCTAssertEqual(result.redSaturation, 1)
        XCTAssertEqual(result.orangeSaturation, -1)
        XCTAssertEqual(result.yellowSaturation, 0)
        XCTAssertEqual(result.redHue, 0, "other properties untouched")
    }

    func testKeyPathTablesCoverEightDistinctFields() {
        for property in SelectiveColorProperty.allCases {
            var state = EditState()
            for (i, keyPath) in SelectiveColorBandWeights.selectiveColorKeyPaths(for: property).enumerated() {
                state[keyPath: keyPath] = Double(i + 1) / 10
            }
            XCTAssertEqual(state.redHue == 0.1, property == .hue)
            XCTAssertEqual(state.magentaLuminance == 0.8, property == .luminance)
        }
        var state = EditState()
        for (i, keyPath) in SelectiveColorBandWeights.grayMixKeyPaths.enumerated() { state[keyPath: keyPath] = Double(i + 1) / 10 }
        XCTAssertEqual([state.grayMixRed, state.grayMixOrange, state.grayMixYellow, state.grayMixGreen,
                        state.grayMixAqua, state.grayMixBlue, state.grayMixPurple, state.grayMixMagenta],
                       [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])
    }

    func testToolHistorySummaries() {
        XCTAssertEqual(TargetedTool.curve.historySummary, "Targeted Curve")
        XCTAssertEqual(TargetedTool.selectiveColor(.saturation).historySummary, "Targeted Saturation")
        XCTAssertEqual(TargetedTool.grayMix.historySummary, "Targeted B&W Mix")
        XCTAssertEqual(TargetedTool.curve.sampleTruncation, .beforePointCurve)
        XCTAssertEqual(TargetedTool.selectiveColor(.hue).sampleTruncation, .beforeSelectiveColor)
        XCTAssertEqual(TargetedTool.grayMix.sampleTruncation, .beforeGrayMix)
    }
}

/// The Swift weights must agree with the REAL kernels: render each kernel through `EditPipeline` and recover the weight it applied.
final class SelectiveColorBandWeightsTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])

    private func render(_ state: EditState, perceptual p: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
        let color = CIColor(red: ToneCurveSpline.srgbDecode(p.r), green: ToneCurveSpline.srgbDecode(p.g),
                            blue: ToneCurveSpline.srgbDecode(p.b), alpha: 1, colorSpace: linearSpace)!
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let out = EditPipeline.apply(state, to: image)
        var buffer = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &buffer, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: linearSpace)
        return (PerceptualEncoding.srgbEncode(Double(buffer[0])), PerceptualEncoding.srgbEncode(Double(buffer[1])),
                PerceptualEncoding.srgbEncode(Double(buffer[2])))
    }

    private let hues: [Double] = [0, 12, 30, 45, 60, 90, 120, 150, 180, 210, 240, 262, 280, 300, 320, 340, 355]

    func testWindowAndCentreConstants() {
        XCTAssertEqual(SelectiveColorBandWeights.centers, [0, 30, 60, 120, 180, 240, 280, 320])
        XCTAssertEqual(SelectiveColorBandWeights.selectiveWindow(range: 0), 20)
        XCTAssertEqual(SelectiveColorBandWeights.selectiveWindow(range: 0.5), 50)
        XCTAssertEqual(SelectiveColorBandWeights.selectiveWindow(range: 1), 80)
        let atCentre = SelectiveColorBandWeights.rawWeights(hue: 120, window: 50)
        XCTAssertEqual(atCentre[3], 1, accuracy: 1e-12)
        XCTAssertEqual(SelectiveColorBandWeights.rawWeights(hue: 350, window: 50)[0], 0.5 * (1 + cos(Double.pi * 10 / 50)), accuracy: 1e-12,
                       "wraps around 360")
    }

    func testGrayMixClampsSaturation() {
        XCTAssertEqual(SelectiveColorBandWeights.grayMixWeights(hue: 0, saturation: 5)[0], 1, accuracy: 1e-12)
        XCTAssertEqual(SelectiveColorBandWeights.grayMixWeights(hue: 0, saturation: -2)[0], 0)
        XCTAssertEqual(SelectiveColorBandWeights.selectiveColorWeights(hue: 0, saturation: 2, range: 0.5)[0], 2, accuracy: 1e-12,
                       "Selective Color does not clamp, like its kernel")
    }

    /// Selective Color: with band `k` Saturation at +0.5 the kernel multiplies S by 1 + 0.5 * w_k (w includes S); recover w from the
    /// rendered output and compare it with the Swift weight, for every band at hues inside and outside its window, at two ranges.
    func testSelectiveColorWeightsMatchTheKernel() {
        let keyPaths = SelectiveColorBandWeights.selectiveColorKeyPaths(for: .saturation)
        for range in [0.0, 0.5, 1.0] {
            for hue in hues {
                let p = ColorRangeSelection.rgb(forHue: hue, saturation: 0.5, lightness: 0.45)
                let (h, s) = PointColorSelection.hueSaturation(forPerceptualRGB: p.r, p.g, p.b)
                let predicted = SelectiveColorBandWeights.selectiveColorWeights(hue: h, saturation: s, range: range)
                for band in 0..<8 {
                    var state = EditState()
                    state.selectiveColorRange = range
                    state[keyPath: keyPaths[band]] = 0.5
                    let out = render(state, perceptual: p)
                    let (_, sOut) = PointColorSelection.hueSaturation(forPerceptualRGB: out.r, out.g, out.b)
                    let measured = (sOut / s - 1) / 0.5
                    XCTAssertEqual(measured, predicted[band], accuracy: 0.03,
                                   "hue \(hue) range \(range) band \(band): kernel \(measured) vs Swift \(predicted[band])")
                }
            }
        }
    }

    /// B&W Mix: grey is scaled by 2^(w_k * mix) (stops 1.0, Intensity 0).
    func testGrayMixWeightsMatchTheKernel() {
        let keyPaths = SelectiveColorBandWeights.grayMixKeyPaths
        for hue in hues {
            let p = ColorRangeSelection.rgb(forHue: hue, saturation: 0.6, lightness: 0.45)
            let (h, s) = PointColorSelection.hueSaturation(forPerceptualRGB: p.r, p.g, p.b)
            let predicted = SelectiveColorBandWeights.grayMixWeights(hue: h, saturation: s)
            var base = EditState()
            base.blackAndWhite = true
            let baseGrey = render(base, perceptual: p).g
            for band in 0..<8 {
                var state = base
                state[keyPath: keyPaths[band]] = 0.5
                let grey = render(state, perceptual: p).g
                let measured = log2(grey / baseGrey) / 0.5
                XCTAssertEqual(measured, predicted[band], accuracy: 0.05,
                               "hue \(hue) band \(band): kernel \(measured) vs Swift \(predicted[band])")
            }
        }
    }
}
