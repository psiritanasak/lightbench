import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoApp

/// The content-addressed logo folder behind the image watermark. Every test uses its own UUID temp folder.
final class WatermarkLogoStoreTests: XCTestCase {
    private var root: URL!
    private var store: WatermarkLogoStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WatermarkLogoStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = WatermarkLogoStore(directory: root.appendingPathComponent("logos"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a solid picture (`red` with alpha `alpha`) of the given size in `type` and returns its URL.
    func writePicture(_ name: String, width: Int, height: Int, type: UTType, alpha: CGFloat = 1, red: CGFloat = 1) throws -> URL {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: 0, blue: 0, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testImportsPNGJPEGAndHEICAsPNGAndLoadsThemBack() throws {
        for (name, type) in [("a.png", UTType.png), ("a.jpg", .jpeg), ("a.heic", .heic)] {
            let id = try store.importLogo(from: writePicture(name, width: 120, height: 60, type: type))
            XCTAssertTrue(WatermarkLogoStore.isValidID(id), name)
            let stored = try XCTUnwrap(store.fileURL(forID: id))
            XCTAssertEqual(stored.pathExtension, "png")
            let image = try XCTUnwrap(store.loadImage(id: id), name)
            XCTAssertEqual(image.width, 120, name)
            XCTAssertEqual(image.height, 60, name)
        }
    }

    func testTheSamePictureImportedTwiceSharesOneFile() throws {
        let one = try writePicture("one.png", width: 80, height: 40, type: .png)
        let copy = root.appendingPathComponent("copy.png")
        try FileManager.default.copyItem(at: one, to: copy)
        let first = try store.importLogo(from: one), second = try store.importLogo(from: copy)
        XCTAssertEqual(first, second)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertEqual(files, ["\(first).png"], "one file for two imports")
        let different = try store.importLogo(from: writePicture("two.png", width: 80, height: 40, type: .png, red: 0.5))
        XCTAssertNotEqual(different, first)
    }

    func testALargeLogoIsDownscaledToTheLongEdgeLimitAndASmallOneIsNotUpscaled() throws {
        let big = try store.importLogo(from: writePicture("big.png", width: 3000, height: 1500, type: .png))
        let bigImage = try XCTUnwrap(store.loadImage(id: big))
        XCTAssertEqual(max(bigImage.width, bigImage.height), WatermarkLogoStore.maximumLongEdge)
        XCTAssertEqual(Double(bigImage.width) / Double(bigImage.height), 2, accuracy: 0.01, "aspect kept")
        let small = try store.importLogo(from: writePicture("small.png", width: 50, height: 20, type: .png))
        let smallImage = try XCTUnwrap(store.loadImage(id: small))
        XCTAssertEqual(smallImage.width, 50, "never upscaled")
    }

    func testTransparencyIsKept() throws {
        let id = try store.importLogo(from: writePicture("t.png", width: 40, height: 40, type: .png, alpha: 0.5))
        let image = try XCTUnwrap(store.loadImage(id: id))
        XCTAssertNotEqual(image.alphaInfo, .none)
        XCTAssertNotEqual(image.alphaInfo, .noneSkipLast)
        XCTAssertNotEqual(image.alphaInfo, .noneSkipFirst)
    }

    func testAnOversizedSourceFileIsRefusedBeforeDecoding() throws {
        let junk = root.appendingPathComponent("huge.png")
        try Data(count: WatermarkLogoStore.maximumSourceBytes + 1).write(to: junk)
        XCTAssertThrowsError(try store.importLogo(from: junk)) { error in
            guard case WatermarkLogoStore.ImportError.tooLarge = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path), "nothing was stored")
    }

    func testNonImagesAndOtherImageTypesAreRefused() throws {
        let text = root.appendingPathComponent("notes.png")
        try Data("not an image".utf8).write(to: text)
        XCTAssertThrowsError(try store.importLogo(from: text)) { XCTAssertEqual($0 as? WatermarkLogoStore.ImportError, .unreadable) }
        let gif = try writePicture("a.gif", width: 10, height: 10, type: .gif)
        XCTAssertThrowsError(try store.importLogo(from: gif)) { XCTAssertEqual($0 as? WatermarkLogoStore.ImportError, .unreadable) }
        XCTAssertThrowsError(try store.importLogo(from: root.appendingPathComponent("missing.png")))
    }

    /// A PNG cannot be shrunk while decoding, so the TOTAL pixel count is capped, not just each side. The limit is
    /// injected (a real 100 MP file would be the very thing being avoided).
    func testTotalPixelCapRefusesAnImageWhoseSidesAreEachFine() throws {
        let capped = WatermarkLogoStore(directory: root.appendingPathComponent("capped"), maximumSourcePixels: 5000)
        let tooMany = try writePicture("100x100.png", width: 100, height: 100, type: .png)   // 10000 px, each side < 30000
        XCTAssertThrowsError(try capped.importLogo(from: tooMany)) { XCTAssertEqual($0 as? WatermarkLogoStore.ImportError, .tooManyPixels) }
        let tall = try writePicture("1x6000.png", width: 1, height: 6000, type: .png)       // 6000 px
        XCTAssertThrowsError(try capped.importLogo(from: tall)) { XCTAssertEqual($0 as? WatermarkLogoStore.ImportError, .tooManyPixels) }
        let fits = try writePicture("70x70.png", width: 70, height: 70, type: .png)         // 4900 px
        XCTAssertNoThrow(try capped.importLogo(from: fits))
        let exact = try writePicture("50x100.png", width: 50, height: 100, type: .png)      // exactly 5000 px is allowed
        XCTAssertNoThrow(try capped.importLogo(from: exact))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("capped").path + "/.png"))
    }

    func testTheDefaultTotalPixelCapIsOneHundredMegapixels() {
        XCTAssertEqual(WatermarkLogoStore.defaultMaximumSourcePixels, 100_000_000)
        XCTAssertEqual(store.maximumSourcePixels, 100_000_000)
    }

    /// Dimensions that cannot be read are a refusal, never "fine".
    func testAFileWhoseDimensionsCannotBeReadIsRefused() throws {
        let garbage = try XCTUnwrap(CGImageSourceCreateWithData(Data("definitely not an image".utf8) as CFData, nil))
        XCTAssertNil(WatermarkLogoStore.pixelSize(of: garbage))
        let valid = try writePicture("ok.png", width: 12, height: 7, type: .png)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(valid as CFURL, nil))
        XCTAssertEqual(WatermarkLogoStore.pixelSize(of: source)?.width, 12)
        XCTAssertEqual(WatermarkLogoStore.pixelSize(of: source)?.height, 7)
        // A PNG cut off after its header: refused, whatever stage notices.
        let data = try Data(contentsOf: valid)
        let cut = root.appendingPathComponent("cut.png")
        try data.prefix(20).write(to: cut)
        XCTAssertThrowsError(try store.importLogo(from: cut))
    }

    func testAMissingSourceFileIsRefusedAsUnreadable() {
        XCTAssertThrowsError(try store.importLogo(from: root.appendingPathComponent("nope.png"))) {
            XCTAssertEqual($0 as? WatermarkLogoStore.ImportError, .unreadable)
        }
    }

    func testADamagedStoredFileIsRewrittenByTheNextImport() throws {
        let picture = try writePicture("heal.png", width: 30, height: 30, type: .png)
        let id = try store.importLogo(from: picture)
        let stored = try XCTUnwrap(store.fileURL(forID: id))
        try Data("damaged".utf8).write(to: stored)
        XCTAssertNil(store.loadImage(id: id))
        XCTAssertEqual(try store.importLogo(from: picture), id)
        XCTAssertNotNil(store.loadImage(id: id), "the damaged file healed")
    }

    /// ImageIO decodes lazily, so a PNG cut off AFTER a valid header still yields an image; only the content hash tells.
    func testAPNGTruncatedAfterItsHeaderIsNeverLoadedAndHealsOnReimport() throws {
        let picture = try writePicture("trunc.png", width: 300, height: 300, type: .png, red: 0.6)
        let id = try store.importLogo(from: picture)
        let stored = try XCTUnwrap(store.fileURL(forID: id))
        let full = try Data(contentsOf: stored)
        try full.prefix(full.count - 20).write(to: stored)   // header intact, tail gone
        XCTAssertNil(store.loadImage(id: id), "a truncated stored logo is never drawn")
        var watermark = ExportWatermark()
        watermark.isEnabled = true
        watermark.kind = .image
        watermark.logoID = id
        XCTAssertNotNil(watermark.inactiveReason(store: store))
        XCTAssertEqual(try store.importLogo(from: picture), id)
        XCTAssertEqual(try Data(contentsOf: stored), full, "rewritten byte-identical")
        XCTAssertNotNil(store.loadImage(id: id))
        XCTAssertNil(watermark.inactiveReason(store: store))
    }

    func testMissingFileMalformedAndTraversalIdsLoadNothing() throws {
        let id = try store.importLogo(from: writePicture("a.png", width: 10, height: 10, type: .png))
        XCTAssertNotNil(store.loadImage(id: id))
        try FileManager.default.removeItem(at: try XCTUnwrap(store.fileURL(forID: id)))
        XCTAssertNil(store.loadImage(id: id), "file deleted")
        XCTAssertNil(store.loadImage(id: String(repeating: "a", count: 64)), "well-formed but absent")
        for bad in ["", "../a", "../../etc/passwd", String(repeating: "A", count: 64), String(repeating: "a", count: 63), id + "/"] {
            XCTAssertFalse(WatermarkLogoStore.isValidID(bad), bad)
            XCTAssertNil(store.fileURL(forID: bad), bad)
            XCTAssertNil(store.loadImage(id: bad), bad)
        }
    }

    func testTheDefaultFolderUnderXCTestIsNotTheRealApplicationSupport() {
        let url = WatermarkLogoStore.defaultDirectory(isRunningUnderXCTest: true)
        XCTAssertFalse(url.path.contains("Application Support"))
        XCTAssertTrue(WatermarkLogoStore.defaultDirectory(isRunningUnderXCTest: false).path.hasSuffix("PhotoApp/WatermarkLogos"))
    }
}
