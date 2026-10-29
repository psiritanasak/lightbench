import CoreImage
import XCTest
@testable import PhotoApp

final class PhotoOrientationTests: XCTestCase {
    /// 3 x 2 image whose six pixels are all different (red channel = index * 40), so any permutation is visible.
    private func sample() -> CIImage {
        var rgba: [UInt8] = []
        for i in 0..<6 { rgba += [UInt8(i * 40), 100, 200, 255] }
        return CIImage(bitmapData: Data(rgba), bytesPerRow: 12, size: CGSize(width: 3, height: 2), format: .RGBA8, colorSpace: nil)
    }

    private func pixels(_ image: CIImage) -> (w: Int, h: Int, red: [Int]) {
        let e = image.extent
        XCTAssertEqual(e.origin, .zero)
        let w = Int(e.width), h = Int(e.height)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            .render(image, toBitmap: &buf, rowBytes: w * 4, bounds: e, format: .RGBA8, colorSpace: nil)
        return (w, h, (0..<(w * h)).map { Int(buf[$0 * 4]) })
    }

    func testReadsOnlyTheThreeOrientationFields() {
        var state = EditState.identity
        state.rotationQuarterTurns = 3
        state.flipHorizontal = true
        state.exposureEV = 2
        state.straightenAngle = 5
        XCTAssertEqual(PhotoOrientation(from: state), PhotoOrientation(quarterTurns: 3, flipHorizontal: true, flipVertical: false))
        XCTAssertTrue(PhotoOrientation(from: .identity).isIdentity)
        XCTAssertEqual(PhotoOrientation(quarterTurns: -1).quarterTurns, 3)
    }

    func testIdentityLeavesThePixelsAlone() {
        XCTAssertEqual(pixels(PhotoOrientation.identity.apply(to: sample())).red, [0, 40, 80, 120, 160, 200])
    }

    func testAQuarterTurnIsClockwiseAndSwapsTheDimensions() {
        let p = pixels(PhotoOrientation(quarterTurns: 1).apply(to: sample()))
        XCTAssertEqual(p.w, 2)
        XCTAssertEqual(p.h, 3)
        // top-down source rows [0 40 80] / [120 160 200]; clockwise: [120 0] / [160 40] / [200 80]
        XCTAssertEqual(p.red, [120, 0, 160, 40, 200, 80])
    }

    func testFlipsAreExact() {
        XCTAssertEqual(pixels(PhotoOrientation(flipHorizontal: true).apply(to: sample())).red, [80, 40, 0, 200, 160, 120])
        XCTAssertEqual(pixels(PhotoOrientation(flipVertical: true).apply(to: sample())).red, [120, 160, 200, 0, 40, 80])
    }

    /// The pipeline turns FIRST and flips later; turn-then-flip differs from flip-then-turn, so this pins the order.
    func testTurnThenFlipMatchesTheEditPipelineForEveryCombination() {
        for turns in 0...3 { for h in [false, true] { for v in [false, true] {
            var state = EditState.identity
            state.rotationQuarterTurns = turns
            state.flipHorizontal = h
            state.flipVertical = v
            let viaPipeline = pixels(EditPipeline.apply(state, to: sample()))
            let viaOrientation = pixels(PhotoOrientation(from: state).apply(to: sample()))
            XCTAssertEqual(viaOrientation.red, viaPipeline.red, "turns \(turns) h \(h) v \(v)")
            XCTAssertEqual(viaOrientation.w, viaPipeline.w)
        } } }
    }

    func testAnOffsetExtentIsShiftedBackToTheOrigin() {
        let shifted = sample().transformed(by: CGAffineTransform(translationX: 7, y: -3))
        let o = PhotoOrientation(quarterTurns: 1, flipHorizontal: true)
        XCTAssertEqual(pixels(o.apply(to: shifted)).red, pixels(o.apply(to: sample())).red)
    }
}
