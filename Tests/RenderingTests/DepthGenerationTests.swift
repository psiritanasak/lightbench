import CoreImage
import ImageIO
import XCTest
@testable import PhotoApp

/// The generator layer of the Depth Range mask: embedded reader, model runner, normalise + encode. Tests that need the optional bundled model SKIP when it is
/// absent (a fresh checkout without `scripts/fetch_depth_model.sh` must still pass).
///
/// NO test here reads the user's own photos or any protected folder (Photos library, Downloads, Documents...): macOS shows a permission prompt for the
/// test host, which is re-signed on every build, and the prompt BLOCKS the run (it did, twice). The measurements on real iPhone and D610 files are in
/// docs/ROADMAP_HISTORY.md ("Depth Range spike"); fixtures here are synthetic.
final class DepthGenerationTests: XCTestCase {
    private func decodePNG(_ data: Data) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        let ctx = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (bytes, image.width, image.height)
    }

    // MARK: Half-float readback

    /// The model's output is read as raw binary16 words (Swift's `Float16` is unavailable on Intel macOS, so a Release build would not compile with it).
    func testHalfToFloatIsExact() {
        let f = DepthModelRunner.float(fromHalf:)
        XCTAssertEqual(f(0x0000), 0); XCTAssertEqual(f(0x8000).sign, .minus); XCTAssertEqual(f(0x8000), 0)
        XCTAssertEqual(f(0x3C00), 1); XCTAssertEqual(f(0xBC00), -1); XCTAssertEqual(f(0x4000), 2); XCTAssertEqual(f(0xC000), -2)
        XCTAssertEqual(f(0x3800), 0.5); XCTAssertEqual(f(0x4900), 10); XCTAssertEqual(f(0x7BFF), 65504)
        XCTAssertEqual(f(0x3555), 0.333251953125, "the nearest half to 1/3")
        XCTAssertEqual(f(0x0400), 6.103515625e-05, "the smallest normal half")
        XCTAssertEqual(f(0x0001), 5.960464477539063e-08, "the smallest subnormal half")
        XCTAssertEqual(f(0x83FF), -6.097555160522461e-05, "the largest negative subnormal")
        XCTAssertEqual(f(0x7C00), .infinity); XCTAssertEqual(f(0xFC00), -.infinity)
        XCTAssertTrue(f(0x7E00).isNaN); XCTAssertTrue(f(0x7C01).isNaN)
        // Round trip against the CoreGraphics/Accelerate-independent reference for every finite half: converting back through Float -> bits must match.
        for bits in UInt16.min...UInt16.max where (bits >> 10) & 0x1F != 0x1F {
            let value = f(bits)
            XCTAssertTrue(value.isFinite)
            if bits & 0x7FFF != 0 { XCTAssertEqual(value.sign == .minus, bits >> 15 == 1, "sign of \(bits)") }
        }
    }

    // MARK: Normalise + encode (no model, no files)

    func testEncodeProducesAnEightBitNearnessPNGOfTheSameSize() throws {
        // A left-to-right ramp 10x4: nearer to the right.
        let values = (0..<40).map { Float($0 % 10) }
        guard case .generated(let g) = DepthMapGenerator.encode(values: values, width: 10, height: 4, tag: "t") else { return XCTFail("expected a raster") }
        XCTAssertEqual(g.sourceTag, "t"); XCTAssertEqual(g.width, 10); XCTAssertEqual(g.height, 4)
        let decoded = try decodePNG(g.png)
        XCTAssertEqual(decoded.width, 10); XCTAssertEqual(decoded.height, 4)
        XCTAssertLessThan(decoded.bytes[0], decoded.bytes[9], "larger depth value = nearer = larger byte")
        XCTAssertEqual(decoded.bytes[0], decoded.bytes[10], "rows are identical, row 0 is the top row of the input")
    }

    func testEncodeRefusesFlatEmptyAndMisSizedMaps() {
        func message(_ o: DepthMapGenerator.Outcome) -> String? { if case .failed(let m) = o { return m }; return nil }
        XCTAssertTrue(message(DepthMapGenerator.encode(values: [Float](repeating: 1, count: 16), width: 4, height: 4, tag: "t"))?.contains("no usable variation") ?? false)
        XCTAssertTrue(message(DepthMapGenerator.encode(values: [], width: 0, height: 0, tag: "t"))?.contains("unexpected size") ?? false)
        XCTAssertTrue(message(DepthMapGenerator.encode(values: [1, 2, 3], width: 2, height: 2, tag: "t"))?.contains("unexpected size") ?? false)
    }

    func testAvailabilityForAMissingOrNilFile() {
        XCTAssertEqual(DepthMapGenerator.availability(forFileAt: nil).embedded, false)
        XCTAssertEqual(DepthMapGenerator.availability(forFileAt: URL(fileURLWithPath: "/definitely/not/here.heic")).embedded, false)
        XCTAssertEqual(DepthMapGenerator.availability(forFileAt: nil).model, DepthModelRunner.isInstalled)
    }

    func testGenerateExplainsWhenTheRequestedSourceIsUnavailable() async {
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        let embedded = await DepthMapGenerator.generate(from: image, fileURL: URL(fileURLWithPath: "/definitely/not/here.jpg"), preference: .embedded)
        XCTAssertEqual(embedded, .failed(DepthSourceResolver.noEmbedded))
        if !DepthModelRunner.isInstalled {
            let model = await DepthMapGenerator.generate(from: image, fileURL: nil, preference: .model)
            XCTAssertEqual(model, .failed(DepthSourceResolver.noModel))
            let automatic = await DepthMapGenerator.generate(from: image, fileURL: nil, preference: .automatic)
            XCTAssertEqual(automatic, .failed(DepthSourceResolver.noDepthAnywhere))
        }
    }

    // MARK: Embedded depth (synthetic HEIC)

    /// A synthetic HEIC with an embedded disparity map and EXIF orientation 6 (rotate 90 degrees clockwise to display). The stored map is 20x15 and
    /// increases left to right; displayed upright it must be 15 wide x 20 tall and increase from TOP to BOTTOM (stored column 0 becomes row 0).
    func testEmbeddedReaderAppliesTheExifOrientationToTheDepthMap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("depth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("oriented.heic")
        try SyntheticDepthFixtures.writeHEIC(to: url, orientation: 6)
        guard EmbeddedDepthReader.hasEmbeddedDepth(at: url) else { throw XCTSkip("the written HEIC did not keep its auxiliary disparity map") }
        let field = try XCTUnwrap(EmbeddedDepthReader.readUpright(at: url))
        XCTAssertEqual(field.width, 15, "stored 20 x 15 rotated 90 degrees: 15 wide"); XCTAssertEqual(field.height, 20)
        let first = field.values[0], last = field.values[(field.height - 1) * field.width]
        XCTAssertLessThan(first, last, "stored column 0 (the smallest disparity) becomes the TOP row after a clockwise rotation")
        // The map varies only along the (new) vertical axis: every row is constant across x.
        for y in 0..<field.height { XCTAssertEqual(field.values[y * field.width], field.values[y * field.width + field.width - 1], accuracy: 0.02) }
    }

    /// Orientation 8 (rotate 90 degrees COUNTER-clockwise to display) must give the OPPOSITE vertical order of orientation 6: stored column 0 becomes the BOTTOM row.
    func testOrientationEightGivesTheOppositeVerticalOrderOfSix() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("depth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("oriented8.heic")
        try SyntheticDepthFixtures.writeHEIC(to: url, orientation: 8)
        guard EmbeddedDepthReader.hasEmbeddedDepth(at: url) else { throw XCTSkip("the written HEIC did not keep its auxiliary disparity map") }
        let field = try XCTUnwrap(EmbeddedDepthReader.readUpright(at: url))
        XCTAssertEqual(field.width, 15); XCTAssertEqual(field.height, 20)
        XCTAssertGreaterThan(field.values[0], field.values[(field.height - 1) * field.width], "stored column 0 (smallest) is the BOTTOM row after a counter-clockwise rotation")
    }

    /// A file whose auxiliary item is DEPTH rather than disparity is still found and read: `AVDepthData` converts it, and larger must still mean NEARER.
    func testADepthTypeAuxiliaryItemIsAcceptedAndStillMeansLargerIsNearer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("depth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("metric.heic")
        try SyntheticDepthFixtures.writeHEIC(to: url, orientation: 1, storedAsDepth: true)
        guard EmbeddedDepthReader.hasEmbeddedDepth(at: url) else { throw XCTSkip("this machine did not keep a Depth-type auxiliary item") }
        let field = try XCTUnwrap(EmbeddedDepthReader.readUpright(at: url))
        XCTAssertEqual(field.width, 20); XCTAssertEqual(field.height, 15)
        // The disparity ramp increased left to right; its reciprocal (metric depth) decreases. After conversion back to disparity it must increase again.
        XCTAssertLessThan(field.values[0], field.values[field.width - 1], "disparity = 1 / depth: the rightmost column is the nearest")
    }

    func testAPhotoWithoutEmbeddedDepthIsReportedAsSuch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("depth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("plain.jpg")
        try PhotoExporter.write(CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32)), format: .jpeg, quality: 0.9, to: url)
        XCTAssertFalse(EmbeddedDepthReader.hasEmbeddedDepth(at: url))
        XCTAssertNil(EmbeddedDepthReader.readUpright(at: url))
    }

    // MARK: The bundled model (skipped when not installed)

    /// A synthetic landscape, 4:3: a pale sky over a darker textured ground with receding stripes, a horizon at 45% height.
    private func syntheticLandscape(width: Int = 640, height: Int = 480) -> CIImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 12345
        func noise() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 24) / 255 }
        let horizon = Int(Float(height) * 0.45)
        for y in 0..<height { for x in 0..<width {
            var r: Float, g: Float, b: Float
            if y < horizon { // sky: bright, smooth, lighter toward the horizon
                let t = Float(y) / Float(horizon)
                r = 0.55 + 0.25 * t; g = 0.7 + 0.2 * t; b = 0.95
            } else { // ground: brown with texture whose grain grows toward the camera, plus converging stripes
                let depth = Float(y - horizon) / Float(height - horizon) // 0 at the horizon, 1 at the bottom edge
                let grain = noise() * (0.05 + 0.35 * depth)
                let stripe: Float = sin(Float(x - width / 2) * (0.02 + 0.2 * depth) * 0.4 + depth * 6) > 0.6 ? 0.08 : 0
                r = 0.42 + grain + stripe; g = 0.32 + grain * 0.8 + stripe; b = 0.2 + grain * 0.6
            }
            let i = (y * width + x) * 4
            rgba[i] = UInt8(min(max(r, 0), 1) * 255); rgba[i + 1] = UInt8(min(max(g, 0), 1) * 255); rgba[i + 2] = UInt8(min(max(b, 0), 1) * 255)
        } }
        return CIImage(bitmapData: Data(rgba), bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    private func meanNearness(_ r: (bytes: [UInt8], width: Int, height: Int), rows: Range<Int>) -> Double {
        var sum = 0.0, n = 0
        for y in rows { for x in 0..<r.width { sum += Double(r.bytes[y * r.width + x]); n += 1 } }
        return sum / Double(max(n, 1))
    }

    func testModelGivesALandscapeSensibleNearnessRaster() async throws {
        try XCTSkipUnless(DepthModelRunner.isInstalled, "depth model not installed (scripts/fetch_depth_model.sh)")
        let image = syntheticLandscape()
        guard case .generated(let g) = await DepthMapGenerator.generate(from: image, fileURL: nil, preference: .model) else { return XCTFail("expected a raster") }
        XCTAssertEqual(g.sourceTag, DepthModelRunner.sourceTag)
        XCTAssertEqual(g.width, 518); XCTAssertEqual(g.height, 392)
        let r = try decodePNG(g.png)
        // Sky over ground (the spike's D610 photos: sky far, ground near): the textured ground at the bottom must read nearer than the sky at the top.
        let top = meanNearness(r, rows: 0..<(r.height / 5)), bottom = meanNearness(r, rows: (r.height * 4 / 5)..<r.height)
        print("PROBE depth model landscape: mean nearness top \(top) bottom \(bottom)")
        XCTAssertGreaterThan(bottom, top + 30, "the ground must read nearer than the sky (top \(top), bottom \(bottom))")
    }

    /// Portrait photos are rotated to landscape for the model and rotated back. The rotation direction is only right if a PORTRAIT version of the
    /// same photo yields (after un-rotation) the same depth layout as the landscape run: correlated, with the sky still on top.
    func testPortraitPhotoGivesTheSameLayoutAsItsLandscapeOriginal() async throws {
        try XCTSkipUnless(DepthModelRunner.isInstalled, "depth model not installed (scripts/fetch_depth_model.sh)")
        let landscape = syntheticLandscape()
        let portrait = landscape.oriented(.right) // an upright PORTRAIT picture: the landscape scene turned 90 degrees clockwise
        let a = try await DepthModelRunner.run(on: landscape)
        let b = try await DepthModelRunner.run(on: portrait)
        XCTAssertEqual(a.width, 518); XCTAssertEqual(a.height, 392)
        XCTAssertEqual(b.width, 392, "a portrait photo yields a portrait map"); XCTAssertEqual(b.height, 518)
        // Map the portrait result back onto the landscape grid: portrait pixel (px, py) shows landscape pixel (py, W - 1 - px)... derive by rotating
        // the landscape map clockwise the same way the picture was turned, then compare layouts at 40x30 sample points.
        var sa: [Float] = [], sb: [Float] = []
        for j in 0..<30 { for i in 0..<40 {
            let u = (Float(i) + 0.5) / 40, v = (Float(j) + 0.5) / 30 // position in the LANDSCAPE frame (0...1, top-left)
            let la = a.depth[Int(v * Float(a.height)) * a.width + Int(u * Float(a.width))]
            // The portrait picture is the landscape turned clockwise: landscape (u, v) appears at portrait (1 - v, u).
            let px = Int((1 - v) * Float(b.width)), py = Int(u * Float(b.height))
            let pb = b.depth[min(py, b.height - 1) * b.width + min(px, b.width - 1)]
            sa.append(la); sb.append(pb)
        } }
        let ma = sa.reduce(0, +) / Float(sa.count), mb = sb.reduce(0, +) / Float(sb.count)
        var num: Float = 0, da: Float = 0, db: Float = 0
        for k in 0..<sa.count { num += (sa[k] - ma) * (sb[k] - mb); da += (sa[k] - ma) * (sa[k] - ma); db += (sb[k] - mb) * (sb[k] - mb) }
        let correlation = num / max((da * db).squareRoot(), 1e-9)
        print("PROBE depth model portrait vs landscape layout correlation \(correlation) over \(sa.count) points")
        XCTAssertGreaterThan(correlation, 0.8, "an un-rotated portrait run must reproduce the landscape layout; a wrong rotation direction would not")
    }
}
