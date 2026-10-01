import CoreGraphics
import CoreImage
import ImageIO
import Vision
import XCTest
@testable import PhotoApp

/// `SubjectMaskGenerator` on synthetic fixtures, including the end-to-end contract with
/// `EditPipeline` (the generator's PNG orientation/extent convention is what the renderer assumes).
/// `XCTSkip`s when Vision finds nothing in the synthetic subject (see `VisionSubjectMaskProbeTests`).
final class SubjectMaskGeneratorTests: XCTestCase {
    private static let width = 1500
    private static let height = 1000

    /// Gradient background; optional red body + skin head. `atTop` puts the figure in the TOP half
    /// (CG's y-up origin means high y = top of the picture), otherwise the left third, vertically centred.
    private static func fixture(subject: Bool, atTop: Bool = false) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let gradient = try XCTUnwrap(CGGradient(
            colorsSpace: space,
            colors: [CGColor(red: 0.55, green: 0.7, blue: 0.85, alpha: 1), CGColor(red: 0.35, green: 0.5, blue: 0.3, alpha: 1)] as CFArray,
            locations: [0, 1]))
        let w = CGFloat(width), h = CGFloat(height)
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        if subject {
            let yShift: CGFloat = atTop ? h * 0.3 : 0
            ctx.setFillColor(CGColor(red: 0.85, green: 0.15, blue: 0.1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: w * 0.12, y: h * 0.2 + yShift, width: w * 0.26, height: h * 0.5 * (atTop ? 0.6 : 1)))
            ctx.setFillColor(CGColor(red: 0.95, green: 0.75, blue: 0.6, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: w * 0.18, y: h * 0.62 + yShift * (atTop ? 0.9 : 1), width: w * 0.14, height: h * 0.2 * (atTop ? 0.8 : 1)))
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    private func generate(_ cg: CGImage) -> SubjectMaskGenerator.Result {
        SubjectMaskGenerator.generate(from: CIImage(cgImage: cg))
    }

    private func decodeGray(_ png: Data) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bitsPerPixel, 8, "8-bit grayscale")
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(ctx.data)
        return (image.width, image.height, Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height)))
    }

    private func requireMask(_ cg: CGImage) throws -> (png: Data, revision: Int) {
        switch generate(cg) {
        case .mask(let png, let revision): return (png, revision)
        case .noSubject: throw XCTSkip("Vision found no subject in the synthetic fixture.")
        case .failed(let reason): throw XCTSkip("Vision failed on this machine: \(reason)")
        }
    }

    func testSubjectFixtureProducesAnEightBitGrayPNGWithinTheSizeCap() throws {
        let (png, revision) = try requireMask(try Self.fixture(subject: true))
        XCTAssertEqual(revision, VNGenerateForegroundInstanceMaskRequest.currentRevision)
        let gray = try decodeGray(png)
        XCTAssertLessThanOrEqual(max(gray.width, gray.height), Int(SubjectMaskGenerator.maxLongSide))
        // Aspect preserved: 1500x1000.
        XCTAssertEqual(Double(gray.width) / Double(gray.height), 1.5, accuracy: 0.01)
        XCTAssertTrue(gray.bytes.contains { $0 > 200 } && gray.bytes.contains { $0 < 50 })
    }

    func testMaskMassIsOnTheLeftWhereTheSubjectIs() throws {
        let (png, _) = try requireMask(try Self.fixture(subject: true))
        let gray = try decodeGray(png)
        var left = 0, right = 0
        for y in 0..<gray.height { for x in 0..<gray.width {
            if x < gray.width / 2 { left += Int(gray.bytes[y * gray.width + x]) } else { right += Int(gray.bytes[y * gray.width + x]) }
        } }
        XCTAssertGreaterThan(left, 100_000)
        XCTAssertLessThan(right, left / 100)
    }

    /// PNG row 0 must be the TOP of the picture (the renderer's convention), not the bottom.
    func testRowZeroIsTheTopOfThePicture() throws {
        let (png, _) = try requireMask(try Self.fixture(subject: true, atTop: true))
        let gray = try decodeGray(png)
        var top = 0, bottom = 0
        for y in 0..<gray.height { for x in 0..<gray.width {
            if y < gray.height / 2 { top += Int(gray.bytes[y * gray.width + x]) } else { bottom += Int(gray.bytes[y * gray.width + x]) }
        } }
        XCTAssertGreaterThan(top, bottom * 2, "figure was drawn in the top half")
    }

    func testFeaturelessImageIsNoSubject() throws {
        _ = try requireMask(try Self.fixture(subject: true)) // skip where Vision finds nothing at all
        XCTAssertEqual(generate(try Self.fixture(subject: false)), .noSubject)
    }

    func testEmptyExtentFailsWithoutCrashing() {
        if case .failed = SubjectMaskGenerator.generate(from: CIImage.empty()) {} else { XCTFail("expected .failed") }
    }

    /// The real contract: generator output fed to the renderer darkens the SUBJECT only — correct side
    /// AND correct vertical orientation — at a different (proxy) size than the one Vision ran on.
    /// Uses the figure drawn in the TOP-LEFT: a row-reversed PNG would darken the mirrored (bottom) probe.
    func testGeneratedMaskDrivesThePipelineOnTheRightSide() throws {
        let cg = try Self.fixture(subject: true, atTop: true)
        let (png, revision) = try requireMask(cg)
        let mask = Mask(kind: .subject, exposureEV: -2, subjectMaskPNG: png, subjectMaskRevision: revision)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let ctx = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200)) // proxy-sized, same 3:2 aspect
        let out = EditPipeline.apply(EditState(masks: [mask]), to: flat)
        func value(_ x: Int, _ y: Int) -> Float {
            var b = [Float](repeating: 0, count: 4)
            ctx.render(out, toBitmap: &b, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: space)
            return b[0]
        }
        // Body spans y 0.5-0.8 of the height (CIImage y is up => the upper half) and x 0.12-0.38.
        XCTAssertLessThan(value(75, 130), 0.2, "subject body darkened (0.5 * 2^-2 = 0.125)")
        XCTAssertEqual(value(75, 70), 0.5, accuracy: 0.01, "the vertically mirrored point is background")
        XCTAssertEqual(value(250, 130), 0.5, accuracy: 0.01, "right side is background")
    }
}
