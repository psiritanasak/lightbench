import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import PhotoApp

final class LookPreviewRendererTests: XCTestCase {
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private func solid(_ r: Double, _ g: Double, _ b: Double, width: Int, height: Int, origin: CGPoint = .zero) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: srgb)!)
            .cropped(to: CGRect(x: origin.x, y: origin.y, width: CGFloat(width), height: CGFloat(height)))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return Array(data[offset..<(offset + 4)])
    }

    private func base(width: Int = 160, height: Int = 100) async throws -> CIImage {
        try await unwrappedBase(solid(0.55, 0.40, 0.30, width: width, height: height))
    }

    /// `XCTUnwrap` cannot take an `await` inside its autoclosure.
    private func unwrappedBase(_ image: CIImage, longSide: CGFloat = LookPreviewRenderer.baseLongSide) async throws -> CIImage {
        let made = await LookPreviewRenderer.makeBase(from: image, longSide: longSide)
        return try XCTUnwrap(made)
    }

    // MARK: makeBase

    func testMakeBaseScalesTheLongSideDownToTheTargetAndKeepsTheAspect() async throws {
        let b = try await unwrappedBase(solid(0.5, 0.5, 0.5, width: 3000, height: 2000))
        XCTAssertEqual(b.extent.width, 160)
        XCTAssertEqual(b.extent.height, 107, accuracy: 1)
        XCTAssertEqual(b.extent.origin, .zero)
        let portrait = try await unwrappedBase(solid(0.5, 0.5, 0.5, width: 1000, height: 4000))
        XCTAssertEqual(portrait.extent.height, 160)
    }

    func testMakeBaseNeverUpscalesASmallImageAndHandlesANonZeroOrigin() async throws {
        let small = try await unwrappedBase(solid(0.5, 0.5, 0.5, width: 100, height: 60, origin: CGPoint(x: 30, y: 12)))
        XCTAssertEqual(small.extent.size, CGSize(width: 100, height: 60))
        XCTAssertEqual(small.extent.origin, .zero)
    }

    func testMakeBaseRejectsDegenerateInput() async {
        let a = await LookPreviewRenderer.makeBase(from: CIImage.empty())
        let b = await LookPreviewRenderer.makeBase(from: CIImage(color: .red))   // infinite extent
        let c = await LookPreviewRenderer.makeBase(from: solid(0.5, 0.5, 0.5, width: 10, height: 10), longSide: 0)
        XCTAssertNil(a); XCTAssertNil(b); XCTAssertNil(c)
    }

    // MARK: render

    func testIdentityRendersTheBasePixelsAtTheBaseSize() async throws {
        let b0 = try await base()
        let image = try XCTUnwrap(LookPreviewRenderer.render(EditState(), base: b0))
        XCTAssertEqual(image.width, 160); XCTAssertEqual(image.height, 100)
        let p = pixel(image, x: 80, y: 50)
        XCTAssertEqual(Double(p[0]), 0.55 * 255, accuracy: 2)
        XCTAssertEqual(Double(p[1]), 0.40 * 255, accuracy: 2)
        XCTAssertEqual(Double(p[2]), 0.30 * 255, accuracy: 2)
        XCTAssertEqual(p[3], 255)
    }

    func testALookChangesThePreviewAndNoneMatchesNoLook() async throws {
        let b = try await base()
        let plain = try XCTUnwrap(LookPreviewRenderer.render(EditState(), base: b))
        var withNone = EditState(); withNone.lookID = ""
        XCTAssertEqual(pixel(try XCTUnwrap(LookPreviewRenderer.render(withNone, base: b)), x: 80, y: 50), pixel(plain, x: 80, y: 50))
        let items = LookPreviewItem.looks(userLooks: []).dropFirst()
        var changed = 0
        for item in items {
            let img = try XCTUnwrap(LookPreviewRenderer.render(item.applying(to: EditState()), base: b))
            let p = pixel(img, x: 80, y: 50), q = pixel(plain, x: 80, y: 50)
            if zip(p, q).contains(where: { abs(Int($0) - Int($1)) >= 3 }) { changed += 1 }
        }
        XCTAssertGreaterThanOrEqual(changed, items.count - 1, "every built-in look visibly changes this colour (at most one is near-neutral for it)")
    }

    func testAStylePresetChangesThePreview() async throws {
        let b = try await base()
        let plain = try XCTUnwrap(LookPreviewRenderer.render(EditState(), base: b))
        let cinema = try XCTUnwrap(LookPreviewRenderer.render(LookPreviewItem(kind: .style, id: "builtin:cinema", name: "Cinema").applying(to: EditState()), base: b))
        XCTAssertNotEqual(pixel(plain, x: 80, y: 50), pixel(cinema, x: 80, y: 50))
    }

    func testTheStatesCropAppliesSoPreviewsHaveTheFramingTheUserSees() async throws {
        var s = EditState(); s.cropInsetLeft = 0.25; s.cropInsetRight = 0.25
        let b0 = try await base()
        let image = try XCTUnwrap(LookPreviewRenderer.render(s, base: b0))
        XCTAssertEqual(image.width, 80, accuracy: 1)
        XCTAssertEqual(image.height, 100)
    }

    func testPreviewStateRendersIdenticallyWithOrWithoutLocalEdits() async throws {
        let b = try await base()
        var local = EditState()
        var mask = Mask(); mask.kind = .radial; mask.exposureEV = 1.5
        local.masks = [mask]; local.retouchSpots = [RetouchSpot()]; local.redEyePoints = [RedEyePoint(x: 0.5, y: 0.5)]
        let a = try XCTUnwrap(LookPreviewRenderer.render(LookPreviewItem.previewState(from: local), base: b))
        let c = try XCTUnwrap(LookPreviewRenderer.render(EditState(), base: b))
        // Non-vacuous: rendering the UNSTRIPPED state really does change the centre (the radial mask has +1.5 EV).
        let unstripped = try XCTUnwrap(LookPreviewRenderer.render(local, base: b))
        XCTAssertNotEqual(pixel(unstripped, x: 80, y: 50), pixel(c, x: 80, y: 50), "the premise: local edits would change the preview")
        XCTAssertEqual(pixel(a, x: 80, y: 50), pixel(c, x: 80, y: 50))
        XCTAssertEqual(pixel(a, x: 20, y: 20), pixel(c, x: 20, y: 20))
    }

    func testAnUnusableOutputExtentReturnsNil() throws {
        let huge = solid(0.5, 0.5, 0.5, width: 5000, height: 100)
        XCTAssertNil(LookPreviewRenderer.render(EditState(), base: huge))
        XCTAssertNil(LookPreviewRenderer.render(EditState(), base: CIImage.empty()))
    }

    // MARK: pixel layout

    /// CGImage row 0 is the TOP of the picture (Core Image's y axis points up).
    func testRowZeroIsTheTopOfThePicture() throws {
        let g = CIFilter.linearGradient()
        g.point0 = CGPoint(x: 0, y: 0); g.point1 = CGPoint(x: 0, y: 100)
        g.color0 = CIColor(red: 0, green: 0, blue: 1, colorSpace: srgb)!   // bottom: blue
        g.color1 = CIColor(red: 1, green: 0, blue: 0, colorSpace: srgb)!   // top: red
        let base = g.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 160, height: 100))
        let image = try XCTUnwrap(LookPreviewRenderer.render(EditState(), base: base))
        let top = pixel(image, x: 80, y: 0), bottom = pixel(image, x: 80, y: 99)
        XCTAssertGreaterThan(top[0], 200); XCTAssertLessThan(top[2], 60)
        XCTAssertGreaterThan(bottom[2], 200); XCTAssertLessThan(bottom[0], 60)
    }

    /// A transparent margin (Transform Scale below 1) stays transparent, with the centre opaque (premultiplied RGBA).
    func testATransparentMarginIsKeptAndTheCentreIsOpaque() async throws {
        var s = EditState(); s.transformScale = 0.5
        let b0 = try await base()
        let image = try XCTUnwrap(LookPreviewRenderer.render(s, base: b0))
        XCTAssertEqual(pixel(image, x: 0, y: 0), [0, 0, 0, 0])
        XCTAssertEqual(pixel(image, x: 80, y: 50)[3], 255)
    }
}
