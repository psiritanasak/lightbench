import CoreImage
import XCTest
@testable import PhotoApp

/// Rotate Left / Right moves radial / linear / brush masks and red-eye points with the picture: their stored
/// fractions live in the DISPLAY frame (after rotation and crop), so `EditState.rotated(byQuarterTurns:)` rotates them in
/// the same step. Value tests per kind, then PIXEL properties against a real render (the picture shown after a turn must
/// be the picture shown before, turned: masks included), then the algebra (round trips, flips, Lightroom import).
final class MaskRotationTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linearSpace, .workingFormat: CIFormat.RGBAf])

    // MARK: - Helpers

    /// A NON-square (80x40) image with a smooth, asymmetric gradient so a mask landing in the wrong place shows.
    private func gradientImage(width: Int = 80, height: Int = 40) -> CIImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8(40 + 160 * x / width)
                pixels[i + 1] = UInt8(40 + 160 * y / height)
                pixels[i + 2] = UInt8(60 + 100 * (x + y) / (width + height))
            }
        }
        // A red patch top-left so red-eye correction has something to darken.
        for y in 2..<14 { for x in 4..<20 { let i = (y * width + x) * 4; pixels[i] = 255; pixels[i + 1] = 20; pixels[i + 2] = 20 } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return CIImage(cgImage: cg)
    }

    private func pixels(_ image: CIImage) -> [Float] {
        let e = image.extent
        var buffer = [Float](repeating: 0, count: Int(e.width * e.height) * 4)
        context.render(image, toBitmap: &buffer, rowBytes: Int(e.width) * 16, bounds: e, format: .RGBAf, colorSpace: linearSpace)
        return buffer
    }

    private func worstDifference(_ a: CIImage, _ b: CIImage) -> Float {
        XCTAssertEqual(a.extent.size, b.extent.size)
        let pa = pixels(a), pb = pixels(b)
        guard pa.count == pb.count else { return .infinity }
        return zip(pa, pb).map { abs($0 - $1) }.max() ?? 0
    }

    private func assertTurnedPicture(_ before: EditState, turns: Int = 1, tolerance: Float = 0.02, _ message: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let input = gradientImage()
        let shownBefore = EditPipeline.apply(before, to: input)
        let shownAfter = EditPipeline.apply(before.rotated(byQuarterTurns: turns), to: input)
        XCTAssertLessThan(worstDifference(shownAfter, QuarterTurn.apply(turns, to: shownBefore)), tolerance, message, file: file, line: line)
        // Not vacuous: the local edit changed the picture.
        var plain = before
        plain.masks = []
        plain.redEyePoints = []
        XCTAssertGreaterThan(worstDifference(shownBefore, EditPipeline.apply(plain, to: input)), 0.05, "\(message): the edit shows", file: file, line: line)
    }

    private func radial() -> Mask {
        Mask(kind: .radial, centerX: 0.25, centerY: 0.3, radiusX: 0.2, radiusY: 0.35, rotationDegrees: 30, feather: 0.4, exposureEV: 1.5)
    }

    private func linear() -> Mask {
        Mask(kind: .linear, centerX: 0.6, centerY: 0.4, rotationDegrees: 20, width: 0.3, exposureEV: 1.5)
    }

    private func brush() -> Mask {
        Mask(kind: .brush, feather: 0.3, brushSize: 0.12,
             brushPoints: [BrushPoint(x: 0.2, y: 0.25), BrushPoint(x: 0.4, y: 0.3), BrushPoint(x: 0.5, y: 0.6)], exposureEV: 1.5)
    }

    private func state(with masks: [Mask] = [], redEye: [RedEyePoint] = []) -> EditState {
        var s = EditState()
        s.masks = masks
        s.redEyePoints = redEye
        return s
    }

    // MARK: - The fraction rotation

    func testRotateFractionClockwiseTurns() {
        let p = (x: 0.2, y: 0.7)
        let one = QuarterTurn.rotateFraction(x: p.x, y: p.y, turns: 1)
        XCTAssertEqual(one.x, 0.3, accuracy: 1e-12); XCTAssertEqual(one.y, 0.2, accuracy: 1e-12)
        let two = QuarterTurn.rotateFraction(x: p.x, y: p.y, turns: 2)
        XCTAssertEqual(two.x, 0.8, accuracy: 1e-12); XCTAssertEqual(two.y, 0.3, accuracy: 1e-12)
        let three = QuarterTurn.rotateFraction(x: p.x, y: p.y, turns: 3)
        XCTAssertEqual(three.x, 0.7, accuracy: 1e-12); XCTAssertEqual(three.y, 0.8, accuracy: 1e-12)
        let zero = QuarterTurn.rotateFraction(x: p.x, y: p.y, turns: 0)
        XCTAssertEqual(zero.x, 0.2); XCTAssertEqual(zero.y, 0.7)
        let five = QuarterTurn.rotateFraction(x: p.x, y: p.y, turns: 5)   // normalised like every turn count
        XCTAssertEqual(five.x, 0.3, accuracy: 1e-12)
    }

    // MARK: - Per kind

    func testRadialCentreRotatesAndRadiiSwapOnOddTurnsOnly() {
        let m = radial()
        let r1 = m.rotatedOnScreen(byQuarterTurns: 1)
        XCTAssertEqual(r1.centerX, 0.7, accuracy: 1e-12); XCTAssertEqual(r1.centerY, 0.25, accuracy: 1e-12)
        XCTAssertEqual(r1.radiusX, 0.35); XCTAssertEqual(r1.radiusY, 0.2)
        XCTAssertEqual(r1.rotationDegrees, 30, "an ellipse's own axis angle is unchanged: its axes swap instead")
        let r2 = m.rotatedOnScreen(byQuarterTurns: 2)
        XCTAssertEqual(r2.centerX, 0.75, accuracy: 1e-12); XCTAssertEqual(r2.centerY, 0.7, accuracy: 1e-12)
        XCTAssertEqual(r2.radiusX, 0.2); XCTAssertEqual(r2.radiusY, 0.35)
        let r3 = m.rotatedOnScreen(byQuarterTurns: 3)
        XCTAssertEqual(r3.centerX, 0.3, accuracy: 1e-12); XCTAssertEqual(r3.centerY, 0.75, accuracy: 1e-12)
        XCTAssertEqual(r3.radiusX, 0.35); XCTAssertEqual(r3.radiusY, 0.2)
        XCTAssertEqual(r1.feather, m.feather); XCTAssertEqual(r1.exposureEV, m.exposureEV); XCTAssertEqual(r1.id, m.id)
    }

    func testLinearCentreRotatesAndAngleTurnsAndWraps() {
        let m = linear()
        let r1 = m.rotatedOnScreen(byQuarterTurns: 1)
        XCTAssertEqual(r1.centerX, 0.6, accuracy: 1e-12); XCTAssertEqual(r1.centerY, 0.6, accuracy: 1e-12)
        XCTAssertEqual(r1.rotationDegrees, 110, accuracy: 1e-9)
        XCTAssertEqual(r1.width, m.width)
        XCTAssertEqual(m.rotatedOnScreen(byQuarterTurns: 2).rotationDegrees, -160, accuracy: 1e-9, "200 wraps to -160")
        XCTAssertEqual(m.rotatedOnScreen(byQuarterTurns: 3).rotationDegrees, -70, accuracy: 1e-9)
        var edge = linear()
        edge.rotationDegrees = 150
        XCTAssertEqual(edge.rotatedOnScreen(byQuarterTurns: 1).rotationDegrees, -120, accuracy: 1e-9, "240 wraps to -120")
        edge.rotationDegrees = 0
        XCTAssertEqual(edge.rotatedOnScreen(byQuarterTurns: 2).rotationDegrees, 180, accuracy: 1e-9, "the range is (-180, 180]")
        edge.rotationDegrees = -270
        XCTAssertEqual(edge.rotatedOnScreen(byQuarterTurns: 1).rotationDegrees, 180, accuracy: 1e-9, "-180 is written as 180")
        edge.rotationDegrees = -90
        XCTAssertEqual(edge.rotatedOnScreen(byQuarterTurns: 2).rotationDegrees, 90, accuracy: 1e-9, "-90 + 180 = 90")
        edge.rotationDegrees = -170
        XCTAssertEqual(edge.rotatedOnScreen(byQuarterTurns: 2).rotationDegrees, 10, accuracy: 1e-9)
    }

    func testBrushEveryPointRotatesAndSizeAndFeatherStay() {
        let m = brush()
        let r = m.rotatedOnScreen(byQuarterTurns: 1)
        XCTAssertEqual(r.brushPoints.count, 3)
        for (old, new) in zip(m.brushPoints, r.brushPoints) {
            XCTAssertEqual(new.x, 1 - old.y, accuracy: 1e-12)
            XCTAssertEqual(new.y, old.x, accuracy: 1e-12)
        }
        XCTAssertEqual(r.brushSize, m.brushSize); XCTAssertEqual(r.feather, m.feather)
        XCTAssertEqual(Mask(kind: .brush).rotatedOnScreen(byQuarterTurns: 1).brushPoints, [])
    }

    func testRasterAndRangeKindsAreReturnedUnchanged() {
        var subject = Mask(kind: .subject)
        subject.subjectMaskPNG = Data([1, 2, 3])
        var depth = Mask(kind: .depthRange)
        depth.depthRasterPNG = Data([4, 5])
        for m in [subject, depth, Mask(kind: .luminanceRange), Mask(kind: .colorRange)] {
            XCTAssertEqual(m.rotatedOnScreen(byQuarterTurns: 1), m, "\(m.kind)")
            XCTAssertEqual(m.rotatedOnScreen(byQuarterTurns: 3), m, "\(m.kind)")
        }
    }

    func testRedEyePointRotates() {
        let p = RedEyePoint(x: 0.2, y: 0.7).rotatedOnScreen(byQuarterTurns: 1)
        XCTAssertEqual(p.x, 0.3, accuracy: 1e-12); XCTAssertEqual(p.y, 0.2, accuracy: 1e-12)
    }

    // MARK: - EditState

    func testRotatedStateMovesMasksAndRedEyeAndLeavesRetouchSpotsAlone() {
        var s = state(with: [radial(), linear(), brush(), Mask(kind: .luminanceRange)], redEye: [RedEyePoint(x: 0.2, y: 0.7)])
        s.retouchSpots = [RetouchSpot()]
        let r = s.rotated(byQuarterTurns: 1)
        for i in 0..<3 { XCTAssertEqual(r.masks[i], s.masks[i].rotatedOnScreen(byQuarterTurns: 1), "mask \(i)") }
        XCTAssertEqual(r.masks[3], s.masks[3])
        XCTAssertEqual(r.redEyePoints[0].x, 0.3, accuracy: 1e-12)
        XCTAssertEqual(r.retouchSpots, s.retouchSpots, "spots live in the source frame and follow through the pipeline")
    }

    /// A flip never enters the screen turn: only the STORED count is inverted. The fractions are display-frame.
    func testOneFlipUsesTheScreenTurnForMasksNotTheStoredOne() {
        var s = state(with: [radial()], redEye: [RedEyePoint(x: 0.2, y: 0.7)])
        s.flipHorizontal = true
        let r = s.rotated(byQuarterTurns: 1)
        XCTAssertEqual(r.rotationQuarterTurns, 3, "stored count moves the other way")
        XCTAssertEqual(r.masks[0], s.masks[0].rotatedOnScreen(byQuarterTurns: 1), "masks turn by the SCREEN turn")
        XCTAssertEqual(r.redEyePoints[0].x, 0.3, accuracy: 1e-12)
    }

    func testSettingStoredTurnsMovesMasksByTheScreenDelta() {
        let s = state(with: [radial()], redEye: [RedEyePoint(x: 0.2, y: 0.7)])
        let r = s.settingStoredQuarterTurns(1)
        XCTAssertEqual(r.masks[0], s.masks[0].rotatedOnScreen(byQuarterTurns: 1))
        var flipped = s
        flipped.flipVertical = true
        let f = flipped.settingStoredQuarterTurns(1)   // stored +1 with one flip = screen -1
        XCTAssertEqual(f.rotationQuarterTurns, 1)
        XCTAssertEqual(f.masks[0], s.masks[0].rotatedOnScreen(byQuarterTurns: 3))
        XCTAssertEqual(f.redEyePoints[0].x, 0.7, accuracy: 1e-12)
        XCTAssertEqual(s.settingStoredQuarterTurns(0), s)
    }

    func testRightThenLeftAndFourPressesReturnTheOriginalWithinFloatingPoint() {
        let s = state(with: [radial(), linear(), brush()], redEye: [RedEyePoint(x: 0.2, y: 0.7)])
        func assertClose(_ a: EditState, _ b: EditState, _ message: String) {
            XCTAssertEqual(a.rotationQuarterTurns, b.rotationQuarterTurns, message)
            for (m, n) in zip(a.masks, b.masks) {
                XCTAssertEqual(m.centerX, n.centerX, accuracy: 1e-9, message); XCTAssertEqual(m.centerY, n.centerY, accuracy: 1e-9, message)
                XCTAssertEqual(m.radiusX, n.radiusX, message); XCTAssertEqual(m.radiusY, n.radiusY, message)
                XCTAssertEqual(m.rotationDegrees, n.rotationDegrees, accuracy: 1e-9, message)
                for (p, q) in zip(m.brushPoints, n.brushPoints) {
                    XCTAssertEqual(p.x, q.x, accuracy: 1e-9, message); XCTAssertEqual(p.y, q.y, accuracy: 1e-9, message)
                }
            }
            XCTAssertEqual(a.redEyePoints[0].x, b.redEyePoints[0].x, accuracy: 1e-9, message)
            XCTAssertEqual(a.redEyePoints[0].y, b.redEyePoints[0].y, accuracy: 1e-9, message)
        }
        assertClose(s.rotated(byQuarterTurns: 1).rotated(byQuarterTurns: -1), s, "right then left")
        var four = s
        for _ in 0..<4 { four = four.rotated(byQuarterTurns: 1) }
        assertClose(four, s, "four presses")
        var fourLeft = s
        for _ in 0..<4 { fourLeft = fourLeft.rotated(byQuarterTurns: -1) }
        assertClose(fourLeft, s, "four left presses")
        XCTAssertEqual(s.rotated(byQuarterTurns: 4), s, "a multiple of four returns self exactly")
    }

    func testRotatingAnEditWithNoLocalEditsLeavesThemEmpty() {
        let s = EditState()
        XCTAssertEqual(s.rotated(byQuarterTurns: 1).masks, [])
        XCTAssertEqual(s.rotated(byQuarterTurns: 1).redEyePoints, [])
    }

    // MARK: - Pixels: the picture shown after a turn is the picture shown before, turned

    func testRadialMaskFollowsTheTurnOnARealRender() {
        for k in [1, 2, 3, -1] { assertTurnedPicture(state(with: [radial()]), turns: k, "radial k=\(k)") }
    }

    func testLinearMaskFollowsTheTurnOnARealRender() {
        for k in [1, 2, 3, -1] { assertTurnedPicture(state(with: [linear()]), turns: k, "linear k=\(k)") }
    }

    func testBrushMaskFollowsTheTurnOnARealRender() {
        for k in [1, 2, 3] { assertTurnedPicture(state(with: [brush()]), turns: k, tolerance: 0.04, "brush k=\(k)") }
    }

    func testRedEyeFollowsTheTurnOnARealRender() {
        var s = state(redEye: [RedEyePoint(x: 0.15, y: 0.25)])
        s.redEyeStrength = 1
        s.redEyeSize = 1
        for k in [1, 2, 3] { assertTurnedPicture(s, turns: k, "red-eye k=\(k)") }
    }

    func testMasksFollowTheTurnWithStraightenCropAndEveryFlipCase() {
        for (h, v) in [(true, false), (false, true), (true, true), (false, false)] {
            var s = state(with: [radial(), linear(), brush()], redEye: [RedEyePoint(x: 0.15, y: 0.25)])
            s.redEyeStrength = 1
            s.flipHorizontal = h
            s.flipVertical = v
            s.straightenAngle = 5
            s.cropInsetTop = 0.1
            s.cropInsetLeft = 0.05
            s.rotationQuarterTurns = 1
            assertTurnedPicture(s, turns: 1, tolerance: 0.05, "flip \(h),\(v)")
            assertTurnedPicture(s, turns: -1, tolerance: 0.05, "flip \(h),\(v) left")
        }
    }

    /// A mask that stayed where it was would show a different picture: guards the pixel tests against passing by luck.
    func testLeavingTheMasksInPlaceWouldNotMatch() {
        let before = state(with: [radial(), linear()])
        var stale = before.rotated(byQuarterTurns: 1)
        stale.masks = before.masks
        let input = gradientImage()
        let expected = QuarterTurn.apply(1, to: EditPipeline.apply(before, to: input))
        XCTAssertGreaterThan(worstDifference(EditPipeline.apply(stale, to: input), expected), 0.05)
    }

    // MARK: - Crop tab Reset

    /// Reset turns the picture back to 0 turns, so masks and points must turn back with it (the pixel property).
    func testCropTabResetTurnsMasksBackWithThePicture() {
        for (h, v) in [(false, false), (true, false), (false, true), (true, true)] {
            var s = state(with: [radial(), linear(), brush()], redEye: [RedEyePoint(x: 0.15, y: 0.25)])
            s.redEyeStrength = 1
            s.flipHorizontal = h
            s.flipVertical = v
            let rotated = s.rotated(byQuarterTurns: 1)
            XCTAssertNotEqual(rotated.rotationQuarterTurns, 0)
            let reset = rotated.resettingCropTab()
            XCTAssertEqual(reset.rotationQuarterTurns, 0)
            XCTAssertFalse(reset.flipHorizontal || reset.flipVertical)
            // Masks live in display coordinates, so clearing a flip does not move them: the net effect of Reset is
            // that the masks sit at the position they had before the rotation.
            for (a, b) in zip(reset.masks, s.masks) {
                XCTAssertEqual(a.centerX, b.centerX, accuracy: 1e-9, "flip \(h),\(v)")
                XCTAssertEqual(a.centerY, b.centerY, accuracy: 1e-9)
                XCTAssertEqual(a.radiusX, b.radiusX); XCTAssertEqual(a.radiusY, b.radiusY)
                XCTAssertEqual(a.rotationDegrees, b.rotationDegrees, accuracy: 1e-9)
            }
            XCTAssertEqual(reset.redEyePoints[0].x, 0.15, accuracy: 1e-9)
            XCTAssertEqual(reset.redEyePoints[0].y, 0.25, accuracy: 1e-9)
        }
    }

    func testCropTabResetClearsTheCropTabFieldsAndLeavesTheRest() {
        var s = state(with: [radial()])
        s.straightenAngle = 5; s.verticalPerspective = 0.2; s.horizontalPerspective = 0.1
        s.transformScale = 1.2; s.transformAspect = 0.3
        s.flipHorizontal = true; s.cropInsetTop = 0.1; s.cropInsetLeft = 0.2
        s.exposureEV = 0.7
        let r = s.rotated(byQuarterTurns: 1).resettingCropTab()
        XCTAssertEqual(r.straightenAngle, 0); XCTAssertEqual(r.verticalPerspective, 0); XCTAssertEqual(r.horizontalPerspective, 0)
        XCTAssertEqual(r.transformScale, 1); XCTAssertEqual(r.transformAspect, 0)
        XCTAssertEqual(r.rotationQuarterTurns, 0)
        XCTAssertEqual([r.cropInsetTop, r.cropInsetRight, r.cropInsetBottom, r.cropInsetLeft], [0, 0, 0, 0])
        XCTAssertEqual(r.exposureEV, 0.7)
    }

    // MARK: - Lightroom import

    func testLightroomRotationMovesMasksWithThePicture() {
        let s = state(with: [radial()], redEye: [RedEyePoint(x: 0.2, y: 0.7)])
        let merged = s.settingStoredQuarterTurns(QuarterTurn.relativeTurns(packetOrientation: 6, photoOrientation: 1) ?? 0)
        XCTAssertEqual(merged.rotationQuarterTurns, 1)
        XCTAssertEqual(merged.masks[0], s.masks[0].rotatedOnScreen(byQuarterTurns: 1))
    }
}
