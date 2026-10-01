import CoreImage
import SwiftUI
import XCTest
@testable import PhotoApp

final class RetouchOverlayGeometryTests: XCTestCase {
    private let fit = CGRect(x: 100, y: 50, width: 800, height: 400)   // min side 400
    private func spot(x: Double = 0.5, y: Double = 0.5, radius: Double = 0.1, dx: Double = 0.25, dy: Double = 0.1) -> RetouchSpot {
        var s = RetouchSpot(); s.x = x; s.y = y; s.radius = radius; s.sourceDX = dx; s.sourceDY = dy; return s
    }

    func testCenterRadiusAndSourcePointsFlipYAndScaleByTheMinSide() {
        let s = spot(x: 0.25, y: 0.75)
        let c = RetouchOverlayGeometry.centerPoint(of: s, in: fit)
        XCTAssertEqual(c.x, 100 + 0.25 * 800)
        XCTAssertEqual(c.y, 50 + (1 - 0.75) * 400, "spot y runs UP, screen y runs DOWN")
        XCTAssertEqual(RetouchOverlayGeometry.radiusPoints(of: s, in: fit), 40, "radius is a fraction of the MIN side (400)")
        let src = RetouchOverlayGeometry.sourcePoint(of: s, in: fit)
        XCTAssertEqual(src.x, c.x + 0.25 * 400, "x offset: fraction of the min side, rightwards")
        XCTAssertEqual(src.y, c.y - 0.1 * 400, "positive dy is UP on screen")
    }

    func testDraggingTheSpotMovesItAndClampsToTheFrame() {
        let moved = RetouchOverlayGeometry.movedCenter(baseline: (0.5, 0.5), translation: CGSize(width: 80, height: 40), fitRect: fit)
        XCTAssertEqual(moved.x, 0.6, accuracy: 1e-9)
        XCTAssertEqual(moved.y, 0.4, accuracy: 1e-9, "dragging DOWN lowers the y-up coordinate")
        let clamped = RetouchOverlayGeometry.movedCenter(baseline: (0.9, 0.1), translation: CGSize(width: 5000, height: 5000), fitRect: fit)
        XCTAssertEqual(clamped.x, 1)
        XCTAssertEqual(clamped.y, 0)
        let clampedLow = RetouchOverlayGeometry.movedCenter(baseline: (0.1, 0.9), translation: CGSize(width: -5000, height: -5000), fitRect: fit)
        XCTAssertEqual(clampedLow.x, 0)
        XCTAssertEqual(clampedLow.y, 1)
    }

    func testDraggingTheSourceChangesTheOffsetInMinSideUnitsAndClamps() {
        let moved = RetouchOverlayGeometry.movedOffset(baseline: (0.1, 0.1), translation: CGSize(width: 40, height: -40), fitRect: fit)
        XCTAssertEqual(moved.dx, 0.2, accuracy: 1e-9)
        XCTAssertEqual(moved.dy, 0.2, accuracy: 1e-9, "dragging UP raises dy")
        let big = RetouchOverlayGeometry.movedOffset(baseline: (0, 0), translation: CGSize(width: 99999, height: -99999), fitRect: fit)
        XCTAssertEqual(big.dx, 1)
        XCTAssertEqual(big.dy, 1)
    }

    func testDegenerateFitRectsLeaveValuesAlone() {
        let flat = CGRect(x: 0, y: 0, width: 0, height: 0)
        XCTAssertEqual(RetouchOverlayGeometry.movedCenter(baseline: (0.3, 0.4), translation: CGSize(width: 9, height: 9), fitRect: flat).x, 0.3)
        XCTAssertEqual(RetouchOverlayGeometry.movedOffset(baseline: (0.3, 0.4), translation: CGSize(width: 9, height: 9), fitRect: flat).dy, 0.4)
    }

    func testNewSpotIsNudgedPerExistingSpotAndRefusedAtTheCap() throws {
        let first = try XCTUnwrap(RetouchOverlayGeometry.newSpot(existingCount: 0))
        let second = try XCTUnwrap(RetouchOverlayGeometry.newSpot(existingCount: 1))
        XCTAssertEqual(first.x, 0.5)
        XCTAssertNotEqual(first.x, second.x, "successive spots must not stack exactly")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotNil(RetouchOverlayGeometry.newSpot(existingCount: EditState.maxRetouchSpots - 1))
        XCTAssertNil(RetouchOverlayGeometry.newSpot(existingCount: EditState.maxRetouchSpots))
        var positions = Set<String>()
        for count in 0..<EditState.maxRetouchSpots {
            let s = try XCTUnwrap(RetouchOverlayGeometry.newSpot(existingCount: count))
            XCTAssertTrue((0.05...0.95).contains(s.x) && (0.05...0.95).contains(s.y), "spots stay well inside the frame")
            positions.insert(String(format: "%.4f,%.4f", s.x, s.y))
        }
        XCTAssertEqual(positions.count, EditState.maxRetouchSpots, "no two spots may start on the same point")
    }

    // MARK: Binding

    func testBindingResolvesByIdentityAndRefusesNonFiniteWrites() throws {
        var state = EditState()
        var a = RetouchSpot(); a.x = 0.1
        var b = RetouchSpot(); b.x = 0.9
        state.retouchSpots = [a, b]
        let editState = Binding(get: { state }, set: { state = $0 })
        let binding = try XCTUnwrap(editState.retouchSpot(id: b.id))
        XCTAssertEqual(binding.wrappedValue.x, 0.9)
        var changed = binding.wrappedValue; changed.x = 0.55
        binding.wrappedValue = changed
        XCTAssertEqual(state.retouchSpots[1].x, 0.55)
        XCTAssertEqual(state.retouchSpots[0].x, 0.1, "the other spot is untouched")
        var bad = changed; bad.radius = .nan
        binding.wrappedValue = bad
        XCTAssertEqual(state.retouchSpots[1].radius, changed.radius, "a NaN write would make every sidecar save throw")
        state.retouchSpots.removeFirst()                  // delete the earlier spot: positions shift
        XCTAssertEqual(binding.wrappedValue.x, 0.55, "still resolves b by id, not by its old index")
        XCTAssertNil(editState.retouchSpot(id: a.id))
    }

    // MARK: Bitmap for the source search

    func testSourceBitmapIsPerceptualTopDownAndDownscaled() throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        // CIImage y is UP: bottom half dark (linear 0.05), top half bright (linear 0.8).
        let dark = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 2000, height: 500))
        let bright = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 500, width: 2000, height: 500))
        let bitmap = try XCTUnwrap(RetouchSourceBitmap.make(from: bright.composited(over: dark)))
        XCTAssertEqual(bitmap.width, 512)
        XCTAssertEqual(bitmap.height, 256)
        XCTAssertEqual(bitmap.value(10, 5, 0), 0.9, accuracy: 0.03, "row 0 is the TOP: bright, sRGB-encoded (0.8 linear = 0.906)")
        XCTAssertEqual(bitmap.value(10, 250, 0), 0.25, accuracy: 0.03, "bottom rows are dark: 0.05 linear = 0.247 sRGB")
    }

    func testSourceBitmapRefusesEmptyOrInfiniteImages() {
        XCTAssertNil(RetouchSourceBitmap.make(from: CIImage.empty()))
        XCTAssertNil(RetouchSourceBitmap.make(from: CIImage(color: .red)))
    }
}
