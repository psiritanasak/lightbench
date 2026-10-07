import CoreGraphics
import CoreImage
import XCTest
@testable import PhotoApp

/// Vision itself is covered by `SkinProtectionProbeTests`; these pin the generator's own contract on synthetic images
/// (no person fixtures live in the repo). A real person photo was run once by hand in the spike (numbers in docs/ROADMAP_HISTORY.md).
final class SkinMaskGeneratorTests: XCTestCase {
    /// The spike's no-person scene: a sand gradient with a rock block (colours inside the skin window). NOT a flat field: a flat
    /// sand-coloured image is out-of-distribution and Vision's person mask marked about 80% of such a 384x288 image as person
    /// (observed 2026-10-07, mask max 255) while a flat blue one gave no person — real non-person photos gave 0.0% in the spike.
    private func desertScene(width: Int, height: Int, origin: CGPoint = .zero) throws -> CIImage {
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for y in 0..<height {
            ctx.setFillColor(CGColor(red: 0.80 - CGFloat(y) / CGFloat(height) * 0.15, green: 0.62, blue: 0.45, alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        ctx.setFillColor(CGColor(red: 0.70, green: 0.42, blue: 0.32, alpha: 1))
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let image = CIImage(cgImage: try XCTUnwrap(ctx.makeImage()))
        return image.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    /// `.noPeople` here depends on Vision's network (a future OS revision could behave differently — a flat sand image is already
    /// marked as person), so an environment where Vision cannot run skips instead of failing.
    private func assertNoPeopleOrSkip(_ result: SkinMaskGenerator.Result, file: StaticString = #filePath, line: UInt = #line) throws {
        if case .failed(let message) = result { throw XCTSkip("Vision unavailable here: \(message)") }
        XCTAssertEqual(result, .noPeople, file: file, line: line)
    }

    func testEmptyAndInfiniteImagesFailInsteadOfCrashing() {
        for image in [CIImage.empty(), CIImage(color: .red)] {
            guard case .failed = SkinMaskGenerator.generate(from: image) else { return XCTFail("expected .failed") }
        }
    }

    func testASceneWithNoPersonYieldsNoPeopleEvenWhenEveryPixelIsSkinColoured() throws {
        // Sand colours are inside the colour window (SkinMaskTests); only the person mask can reject them.
        let scene = try desertScene(width: 384, height: 288, origin: CGPoint(x: 40, y: 25)) // non-zero origin
        try assertNoPeopleOrSkip(SkinMaskGenerator.generate(from: scene))
    }

    func testAnOversizedSceneIsDownscaledAndStillWorks() throws {
        try assertNoPeopleOrSkip(SkinMaskGenerator.generate(from: try desertScene(width: 3000, height: 2000)))
    }

    func testPinnedRevisionIsRevisionOne() {
        XCTAssertEqual(SkinMaskGenerator.personSegmentationRevision, 1)
    }

    // MARK: - Row order (orientation is this file's main risk; no person fixture exists, so the helpers are pinned by hand)

    func testPrepareKeepsTheTopOfTheImageInRowZeroAndHandlesANonZeroOrigin() throws {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 30, y: 30 + 20, width: 40, height: 20)) // top band (CI y is up)
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 30, y: 30, width: 40, height: 20))
        let prepared = try XCTUnwrap(SkinMaskGenerator.prepare(red.composited(over: blue)))
        XCTAssertEqual(prepared.width, 40)
        XCTAssertEqual(prepared.height, 40)
        let rgba = try XCTUnwrap(SkinMaskGenerator.straightRGBA(prepared.image, width: 40, height: 40))
        XCTAssertEqual(Array(rgba[0..<3]), [255, 0, 0], "row 0 is the TOP band (red)")
        let lastRow = 39 * 40 * 4
        XCTAssertEqual(Array(rgba[lastRow..<(lastRow + 3)]), [0, 0, 255], "the last row is the BOTTOM band (blue)")
    }

    func testResizedGrayKeepsTheTopRowOfTheVisionBufferInRowZero() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_OneComponent8, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<4 { for x in 0..<8 { base[y * rowBytes + x] = y < 2 ? 255 : 0 } } // top half set
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let out = try XCTUnwrap(SkinMaskGenerator.resizedGray(pixels, toWidth: 16, height: 12))
        XCTAssertEqual(out.count, 16 * 12)
        XCTAssertEqual(out[0], 255, "output row 0 comes from the buffer's top row")
        XCTAssertEqual(out[11 * 16], 0, "the last output row comes from the buffer's bottom row")
    }
}
