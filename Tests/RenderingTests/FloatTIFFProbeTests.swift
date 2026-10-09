import CoreImage
import XCTest
@testable import PhotoApp

/// PERMANENT probe for Photo Merge output: can a TIFF written by Core Image carry linear values ABOVE 1.0 and give them back through the app's own
/// decode path (`RawDecoder.decode` for a non-RAW file)? An integer RGBA16 TIFF cannot (it clips at 1.0) — the original plan wrongly assumed it
/// could — so the merge output must be a floating-point TIFF. Results: docs/ROADMAP_HISTORY.md "Photo Merge spike".
final class FloatTIFFProbeTests: XCTestCase {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private func roundTrip(format: CIFormat, value: CGFloat) async throws -> (r: Float, g: Float, b: Float) {
        let image = CIImage(color: CIColor(red: value, green: value * 0.5, blue: value * 0.25, colorSpace: linear)!).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        try PhotoExporter.context.writeTIFFRepresentation(of: image, to: url, format: format, colorSpace: linear, options: [:])
        let decodedOptional = await RawDecoder.decode(contentsOf: url, editState: EditState())
        let decoded = try XCTUnwrap(decodedOptional)
        var px = [Float](repeating: 0, count: 4)
        PhotoExporter.context.render(decoded, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 4, y: 4, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        print("PROBE TIFF \(format.rawValue) wrote \(value) -> read \(px[0]) \(px[1]) \(px[2]), file \((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) ?? 0) bytes for 16x16")
        return (px[0], px[1], px[2])
    }

    func testIntegerSixteenBitTIFFClipsAboveOne() async throws {
        let r = try await roundTrip(format: .RGBA16, value: 3.0)
        XCTAssertLessThanOrEqual(r.r, 1.001, "the integer format is expected to clip: the plan's original assumption was wrong")
    }

    func testHalfFloatTIFFKeepsValuesAboveOne() async throws {
        let r = try await roundTrip(format: .RGBAh, value: 3.0)
        XCTAssertEqual(r.r, 3.0, accuracy: 0.01)
        XCTAssertEqual(r.g, 1.5, accuracy: 0.01)
        XCTAssertEqual(r.b, 0.75, accuracy: 0.01)
    }

    func testFloat32TIFFKeepsValuesAboveOne() async throws {
        let r = try await roundTrip(format: .RGBAf, value: 7.25)
        XCTAssertEqual(r.r, 7.25, accuracy: 0.001)
    }
}
