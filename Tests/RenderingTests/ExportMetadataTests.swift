import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoApp

/// Export metadata policy + the stale-Orientation fix. Measured before this existed (2026-10-02): export kept ALL
/// source metadata including GPS, and left Orientation=6 on already-rotated pixels.
final class ExportMetadataTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ExportMetadataTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A 40x20 JPEG tagged Orientation 6 (displays 20x40) with EXIF, TIFF, GPS and IPTC (incl. a place name).
    private func makeSource() throws -> Photo {
        let base = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        let cg = try XCTUnwrap(CIContext().createCGImage(base, from: base.extent))
        let url = dir.appendingPathComponent("src.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestMake", kCGImagePropertyTIFFModel: "TestModel"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 13.7, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 100.5, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "a caption", kCGImagePropertyIPTCCity: "Bangkok"],
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return Photo(id: 1, path: url.path, filename: "src.jpg", fileSize: nil, importedAt: Date())
    }

    private func export(_ photo: Photo, format: ExportFormat, policy: ExportMetadataPolicy) async throws -> URL {
        try await PhotoExporter.export(
            photo, editState: .identity, to: dir,
            settings: ExportSettings(format: format, namingTemplate: "out-\(format.rawValue)-\(policy.rawValue)", metadata: policy)
        )
    }

    private func properties(of url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    private func dictionary(_ key: CFString, in props: [String: Any]) -> [String: Any]? { props[key as String] as? [String: Any] }

    /// The size a viewer that honours the Orientation tag would display.
    private func displayedSize(of url: URL) throws -> (Int, Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let thumb = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1000,
        ] as CFDictionary))
        return (thumb.width, thumb.height)
    }

    /// The names of the tags ImageIO's metadata view reports (a mirror of the property dictionaries plus any XMP).
    private func metadataTagNames(of url: URL) throws -> [String] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return [] }
        return tags.compactMap { CGImageMetadataTagCopyName($0) as String? }
    }

    // MARK: - Orientation (every policy, every format)

    func testExportedPixelsAndOrientationTagAgreeSoViewersDoNotRotateTwice() async throws {
        let photo = try makeSource()
        for format in ExportFormat.allCases {
            for policy in ExportMetadataPolicy.allCases {
                let url = try await export(photo, format: format, policy: policy)
                let props = try properties(of: url)
                let stored = (try XCTUnwrap(props[kCGImagePropertyPixelWidth as String] as? Int),
                              try XCTUnwrap(props[kCGImagePropertyPixelHeight as String] as? Int))
                XCTAssertEqual(stored.0, 20, "orientation was baked into the pixels: \(format) \(policy)")
                let displayed = try displayedSize(of: url)
                XCTAssertTrue(displayed == stored, "tag must not rotate again: \(format) \(policy) displays \(displayed), stored \(stored)")
            }
        }
    }

    // MARK: - Policies

    func testAllKeepsEverythingTheSourceHad() async throws {
        let photo = try makeSource()
        for format in ExportFormat.allCases {
            let props = try properties(of: try await export(photo, format: format, policy: .all))
            XCTAssertNotNil(dictionary(kCGImagePropertyGPSDictionary, in: props), "\(format) keeps GPS")
            XCTAssertEqual(dictionary(kCGImagePropertyTIFFDictionary, in: props)?[kCGImagePropertyTIFFMake as String] as? String, "TestMake")
            XCTAssertEqual(dictionary(kCGImagePropertyExifDictionary, in: props)?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
                           "2024:05:06 07:08:09")
            XCTAssertEqual(dictionary(kCGImagePropertyIPTCDictionary, in: props)?[kCGImagePropertyIPTCCity as String] as? String, "Bangkok")
        }
    }

    func testWithoutLocationDropsOnlyThePlace() async throws {
        let photo = try makeSource()
        for format in ExportFormat.allCases {
            let url = try await export(photo, format: format, policy: .withoutLocation)
            let props = try properties(of: url)
            XCTAssertNil(dictionary(kCGImagePropertyGPSDictionary, in: props), "\(format) GPS")
            XCTAssertNil(dictionary(kCGImagePropertyIPTCDictionary, in: props)?[kCGImagePropertyIPTCCity as String], "\(format) city")
            XCTAssertEqual(dictionary(kCGImagePropertyTIFFDictionary, in: props)?[kCGImagePropertyTIFFMake as String] as? String, "TestMake")
            XCTAssertNotNil(dictionary(kCGImagePropertyExifDictionary, in: props)?[kCGImagePropertyExifDateTimeOriginal as String])
            XCTAssertEqual(dictionary(kCGImagePropertyIPTCDictionary, in: props)?[kCGImagePropertyIPTCCaptionAbstract as String] as? String, "a caption")
            let names = try metadataTagNames(of: url).map { $0.lowercased() }
            XCTAssertFalse(names.contains { $0.contains("gps") || $0 == "city" }, "\(format) metadata view: \(names)")
        }
    }

    func testNoneDropsAllDescriptiveMetadataButKeepsTheProfile() async throws {
        let photo = try makeSource()
        for format in ExportFormat.allCases {
            let url = try await export(photo, format: format, policy: .none)
            let props = try properties(of: url)
            XCTAssertNil(dictionary(kCGImagePropertyGPSDictionary, in: props), "\(format) GPS")
            XCTAssertNil(dictionary(kCGImagePropertyIPTCDictionary, in: props), "\(format) IPTC")
            XCTAssertNil(dictionary(kCGImagePropertyTIFFDictionary, in: props)?[kCGImagePropertyTIFFMake as String], "\(format) make")
            XCTAssertNil(dictionary(kCGImagePropertyTIFFDictionary, in: props)?[kCGImagePropertyTIFFModel as String], "\(format) model")
            XCTAssertNil(dictionary(kCGImagePropertyExifDictionary, in: props)?[kCGImagePropertyExifDateTimeOriginal as String], "\(format) date")
            XCTAssertTrue((props[kCGImagePropertyProfileName as String] as? String ?? "").contains("sRGB"), "\(format) keeps its profile")
            let names = try metadataTagNames(of: url).map { $0.lowercased() }
            XCTAssertFalse(names.contains { $0.contains("gps") || $0 == "city" || $0 == "make" || $0 == "model" }, "\(format): \(names)")
        }
    }

    // MARK: - Pure property filter

    func testNoneIsAnAllowlistSoUnfamiliarDictionariesCannotLeak() {
        let original: [String: Any] = [
            "Depth": 8, "PixelWidth": 20, "{MakerNikon}": ["SerialNumber": "123"], "{ExifAux}": ["SerialNumber": "9"],
            "{Exif}": ["BodySerialNumber": "55"], "{PNG}": ["Gamma": 0.45455],
        ]
        let result = ExportMetadata.properties(from: original, policy: .none)
        XCTAssertNil(result["{MakerNikon}"])
        XCTAssertNil(result["{ExifAux}"])
        XCTAssertNil(result["{Exif}"])
        XCTAssertNil(result["{PNG}"], "PNG text chunks are descriptive, not structural")
        XCTAssertEqual(result["Depth"] as? Int, 8)
        XCTAssertEqual(result["Orientation"] as? Int, 1)
        let kept = ExportMetadata.properties(from: original, policy: .withoutLocation)
        XCTAssertNotNil(kept["{MakerNikon}"], "withoutLocation is a blocklist: it keeps what it does not know")
    }

    func testPNGTextChunksDoNotLeakUnderNoneButSurviveUnderAll() async throws {
        let base = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        let cg = try XCTUnwrap(CIContext().createCGImage(base, from: base.extent))
        let url = dir.appendingPathComponent("author.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGAuthor: "Jane Doe", kCGImagePropertyPNGCopyright: "Jane", kCGImagePropertyPNGDescription: "desc",
        ]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let photo = Photo(id: 2, path: url.path, filename: "author.png", fileSize: nil, importedAt: Date())
        for format in ExportFormat.allCases {
            let none = try properties(of: try await export(photo, format: format, policy: .none))
            let blob = "\(none)"
            XCTAssertFalse(blob.contains("Jane"), "\(format) .none leaked the author/copyright: \(blob)")
            XCTAssertFalse(blob.contains("desc"), "\(format) .none leaked the description")
        }
        let all = try properties(of: try await export(photo, format: .png, policy: .all))
        XCTAssertTrue("\(all)".contains("Jane Doe"), ".all keeps the author")
    }

    func testSourcePNGColourChunksAreDroppedUnderEveryPolicy() {
        let original: [String: Any] = ["{PNG}": ["Gamma": 0.45455, "Chromaticities": [0.3, 0.3], "sRGBIntent": 0, "InterlaceType": 0, "Author": "A"]]
        for policy in [ExportMetadataPolicy.all, .withoutLocation] {
            let png = ExportMetadata.properties(from: original, policy: policy)["{PNG}"] as? [String: Any]
            XCTAssertNil(png?["Gamma"], "\(policy)")
            XCTAssertNil(png?["Chromaticities"], "\(policy)")
            XCTAssertNil(png?["sRGBIntent"], "\(policy)")
            XCTAssertNil(png?["InterlaceType"], "\(policy)")
            XCTAssertEqual(png?["Author"] as? String, "A", "text chunks survive when the policy keeps metadata")
        }
        XCTAssertNil(ExportMetadata.properties(from: original, policy: .none)["{PNG}"])
    }

    func testWithoutLocationDropsIPTCExtensionLocations() {
        let original: [String: Any] = ["{IPTC}": [
            kCGImagePropertyIPTCExtLocationCreated as String: [["City": "X"]], kCGImagePropertyIPTCExtLocationShown as String: [["City": "Y"]],
            kCGImagePropertyIPTCCaptionAbstract as String: "kept",
        ]]
        let iptc = ExportMetadata.properties(from: original, policy: .withoutLocation)["{IPTC}"] as? [String: Any]
        XCTAssertNil(iptc?[kCGImagePropertyIPTCExtLocationCreated as String])
        XCTAssertNil(iptc?[kCGImagePropertyIPTCExtLocationShown as String])
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCCaptionAbstract as String] as? String, "kept")
    }

    func testOrientationIsNeutralisedInTopLevelAndTIFFUnderEveryPolicy() {
        let original: [String: Any] = ["Orientation": 6, "{TIFF}": ["Orientation": 6, "Make": "X"]]
        for policy in ExportMetadataPolicy.allCases {
            let result = ExportMetadata.properties(from: original, policy: policy)
            XCTAssertEqual(result["Orientation"] as? Int, 1, "\(policy)")
            if let tiff = result["{TIFF}"] as? [String: Any] { XCTAssertEqual(tiff["Orientation"] as? Int, 1, "\(policy)") }
        }
    }

    // MARK: - Settings

    func testDefaultKeepsAllAndPolicyIsRememberedTolerantly() throws {
        XCTAssertEqual(ExportSettings().metadata, .all)
        let suite = "ExportMetadataTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ExportSettingsStore(defaults: defaults)
        store.save(ExportSettings(metadata: .none))
        XCTAssertEqual(store.load().metadata, ExportMetadataPolicy.none)
        defaults.set(Data(#"{"metadata":"everything","format":"tiff"}"#.utf8), forKey: ExportSettingsStore.key)
        XCTAssertEqual(store.load().metadata, .all, "unknown policy falls back")
        XCTAssertEqual(store.load().format, .tiff)
    }
}
