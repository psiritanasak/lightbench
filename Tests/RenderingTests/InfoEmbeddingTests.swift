import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoApp

final class InfoEmbeddingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("InfoEmbeddingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let info = PhotoInfo(title: "T\u{00E9}tle \u{65E5}\u{672C}", caption: "Line1\nLine2 \u{1F468}\u{200D}\u{1F469}", creator: "Jane Doe", copyright: "\u{00A9} 2026 Jane Doe")

    private let iptcKey = kCGImagePropertyIPTCDictionary as String
    private let tiffKey = kCGImagePropertyTIFFDictionary as String
    private let pngKey = kCGImagePropertyPNGDictionary as String

    // MARK: reading back

    private struct Written {
        var iptcTitle: String?, iptcCaption: String?, iptcCreator: [String]?, iptcCopyright: String?
        var tiffArtist: String?, tiffCopyright: String?, tiffDescription: String?
        var xmpTitle: String?, xmpDescription: String?, xmpCreator: String?, xmpRights: String?
        /// Every string anywhere in the file's properties and XMP (for the "nothing leaks" checks).
        var everything = ""
    }

    private func xmpString(_ md: CGImageMetadata, _ path: String) -> String? {
        guard let tag = CGImageMetadataCopyTagWithPath(md, nil, path as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else { return nil }
        if let text = value as? String { return text }
        // A language alternative or an array comes back as tags; the first element carries the text.
        guard let tags = value as? [CGImageMetadataTag], let first = tags.first else { return nil }
        return CGImageMetadataTagCopyValue(first) as? String
    }

    private func read(_ url: URL) throws -> Written {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        var out = Written()
        let iptc = props[iptcKey] as? [String: Any]
        out.iptcTitle = iptc?[kCGImagePropertyIPTCObjectName as String] as? String
        out.iptcCaption = iptc?[kCGImagePropertyIPTCCaptionAbstract as String] as? String
        out.iptcCreator = iptc?[kCGImagePropertyIPTCByline as String] as? [String]
        out.iptcCopyright = iptc?[kCGImagePropertyIPTCCopyrightNotice as String] as? String
        let tiff = props[tiffKey] as? [String: Any]
        out.tiffArtist = tiff?[kCGImagePropertyTIFFArtist as String] as? String
        out.tiffCopyright = tiff?[kCGImagePropertyTIFFCopyright as String] as? String
        out.tiffDescription = tiff?[kCGImagePropertyTIFFImageDescription as String] as? String
        out.everything = "\(props)"
        if let md = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            out.xmpTitle = xmpString(md, "dc:title")
            out.xmpDescription = xmpString(md, "dc:description")
            out.xmpCreator = xmpString(md, "dc:creator")
            out.xmpRights = xmpString(md, "dc:rights")
            out.everything += "\(CGImageMetadataCopyTags(md) ?? [] as CFArray)"
        }
        return out
    }

    private func makeSource(
        format: UTType = .jpeg, name: String = "src", iptc: [CFString: Any] = [:], tiff: [CFString: Any] = [:], png: [CFString: Any] = [:]
    ) throws -> Photo {
        let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        let cg = try XCTUnwrap(CIContext().createCGImage(base, from: base.extent))
        let url = dir.appendingPathComponent("\(name).\(format.preferredFilenameExtension ?? "jpg")")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, format.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if !iptc.isEmpty { props[kCGImagePropertyIPTCDictionary] = iptc }
        if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary] = tiff }
        if !png.isEmpty { props[kCGImagePropertyPNGDictionary] = png }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return Photo(id: 1, path: url.path, filename: url.lastPathComponent, fileSize: nil, importedAt: Date())
    }

    private func settings(_ format: ExportFormat = .jpeg, _ name: String, metadata: ExportMetadataPolicy = .all, includeInfo: Bool = true) -> ExportSettings {
        var s = ExportSettings(format: format, namingTemplate: name, metadata: metadata)
        s.includeInfo = includeInfo
        return s
    }

    // MARK: measurement (permanent record of what the writers emit)

    func testWritersEmitIPTCTIFFAndXMPForEveryFormat() async throws {
        let photo = try makeSource()
        for format in ExportFormat.allCases {
            let url = try await PhotoExporter.export(photo, editState: .identity, to: dir, settings: settings(format, "i-\(format.rawValue)"), info: info)
            let w = try read(url)
            XCTAssertEqual(w.iptcTitle, info.title, "\(format) IPTC ObjectName")
            XCTAssertEqual(w.iptcCaption, info.caption, "\(format) IPTC Caption/Abstract")
            XCTAssertEqual(w.iptcCreator, [info.creator], "\(format) IPTC By-line")
            XCTAssertEqual(w.iptcCopyright, info.copyright, "\(format) IPTC CopyrightNotice")
            XCTAssertEqual(w.xmpTitle, info.title, "\(format) XMP dc:title")
            XCTAssertEqual(w.xmpDescription, info.caption, "\(format) XMP dc:description")
            XCTAssertEqual(w.xmpCreator, info.creator, "\(format) XMP dc:creator")
            XCTAssertEqual(w.xmpRights, info.copyright, "\(format) XMP dc:rights")
            // ImageIO also mirrors them into TIFF; a PNG carries only Copyright there.
            XCTAssertEqual(w.tiffCopyright, info.copyright, "\(format) TIFF Copyright")
            if format != .png {
                XCTAssertEqual(w.tiffArtist, info.creator, "\(format) TIFF Artist")
                XCTAssertEqual(w.tiffDescription, info.caption, "\(format) TIFF ImageDescription")
            }
        }
    }

    // MARK: gate

    func testPropertiesIsUnchangedWhenOffOrPolicyNoneOrEmpty() {
        let base: [String: Any] = [kCGImagePropertyDPIWidth as String: 72]
        for (policy, include, value) in [(ExportMetadataPolicy.all, false, info), (.none, true, info), (.all, true, PhotoInfo())] {
            let out = InfoEmbedding.properties(base, adding: value, policy: policy, include: include)
            XCTAssertNil(out[iptcKey], "\(policy) include=\(include) empty=\(value.isEmpty)")
            XCTAssertEqual(out.count, 1)
        }
    }

    func testPropertiesReplacesOnlyNonEmptyFieldsAndKeepsOtherIPTC() {
        let base: [String: Any] = [iptcKey: [
            kCGImagePropertyIPTCObjectName as String: "Old title", kCGImagePropertyIPTCCaptionAbstract as String: "Old caption",
            kCGImagePropertyIPTCByline as String: ["Old creator"], kCGImagePropertyIPTCCopyrightNotice as String: "Old (c)",
            kCGImagePropertyIPTCKeywords as String: ["kw"],
        ]]
        let out = InfoEmbedding.properties(base, adding: PhotoInfo(title: "New", caption: "", creator: "", copyright: "New (c)"), policy: .withoutLocation, include: true)
        let iptc = out[iptcKey] as? [String: Any]
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCObjectName as String] as? String, "New")
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCCaptionAbstract as String] as? String, "Old caption")
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCByline as String] as? [String], ["Old creator"])
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCCopyrightNotice as String] as? String, "New (c)")
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCKeywords as String] as? [String], ["kw"])
    }

    func testPropertiesOverwritesStaleTIFFAndPNGValuesButAddsNoNewKeys() {
        let base: [String: Any] = [
            tiffKey: [kCGImagePropertyTIFFArtist as String: "Old", kCGImagePropertyTIFFModel as String: "Cam"],
            pngKey: [kCGImagePropertyPNGAuthor as String: "Old", kCGImagePropertyPNGTitle as String: "Old"],
        ]
        let out = InfoEmbedding.properties(base, adding: PhotoInfo(title: "T", caption: "C", creator: "Me", copyright: "R"), policy: .all, include: true)
        let tiff = out[tiffKey] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFArtist as String] as? String, "Me")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel as String] as? String, "Cam")
        XCTAssertNil(tiff?[kCGImagePropertyTIFFCopyright as String], "no TIFF key is added where the source had none")
        XCTAssertNil(tiff?[kCGImagePropertyTIFFImageDescription as String])
        let png = out[pngKey] as? [String: Any]
        XCTAssertEqual(png?[kCGImagePropertyPNGAuthor as String] as? String, "Me")
        XCTAssertEqual(png?[kCGImagePropertyPNGTitle as String] as? String, "T")
        XCTAssertNil(png?[kCGImagePropertyPNGCopyright as String])
    }

    // MARK: end to end

    func testEmptyLibraryFieldsKeepTheSourcesOwnValuesEndToEnd() async throws {
        let photo = try makeSource(iptc: [kCGImagePropertyIPTCCopyrightNotice: "Source (c)", kCGImagePropertyIPTCObjectName: "Source title"])
        let url = try await PhotoExporter.export(photo, editState: .identity, to: dir, settings: settings(.jpeg, "keep"), info: PhotoInfo(title: "", caption: "Mine", creator: "", copyright: ""))
        let w = try read(url)
        XCTAssertEqual(w.iptcCopyright, "Source (c)")
        XCTAssertEqual(w.iptcTitle, "Source title")
        XCTAssertEqual(w.iptcCaption, "Mine")
    }

    func testSourceTIFFArtistIsReplacedNotLeftToOutvoteTheLibraryCreator() async throws {
        let photo = try makeSource(format: .tiff, name: "tiffsrc", tiff: [kCGImagePropertyTIFFArtist: "Camera Owner"])
        let url = try await PhotoExporter.export(photo, editState: .identity, to: dir, settings: settings(.tiff, "artist"), info: PhotoInfo(creator: "Jane Doe"))
        let w = try read(url)
        XCTAssertEqual(w.tiffArtist, "Jane Doe")
        XCTAssertEqual(w.xmpCreator, "Jane Doe")
        XCTAssertEqual(w.iptcCreator, ["Jane Doe"])
    }

    func testNonePolicyAndToggleOffEmbedNoneOfTheInfo() async throws {
        let photo = try makeSource(format: .png, name: "pngsrc", png: [kCGImagePropertyPNGDescription: "Source note"])
        let markers = ["T\u{00E9}tle", "Line1", "Jane Doe", "2026 Jane"]
        for format in ExportFormat.allCases {
            let none = try await PhotoExporter.export(photo, editState: .identity, to: dir, settings: settings(format, "n-\(format.rawValue)", metadata: .none), info: info)
            let noneRead = try read(none)
            for marker in markers { XCTAssertFalse(noneRead.everything.contains(marker), "\(format) none leaked \(marker)") }
            XCTAssertFalse(noneRead.everything.contains("Source note"), "\(format) none kept the PNG text chunk")

            let off = try await PhotoExporter.export(photo, editState: .identity, to: dir, settings: settings(format, "o-\(format.rawValue)", includeInfo: false), info: info)
            let offRead = try read(off)
            for marker in markers { XCTAssertFalse(offRead.everything.contains(marker), "\(format) toggle off leaked \(marker)") }
        }
    }

    // MARK: settings

    func testIncludeInfoDefaultsOffAndDecodesWhenMissingAndRoundTrips() throws {
        XCTAssertFalse(ExportSettings().includeInfo)
        let old = Data(#"{"format":"png","quality":0.8,"includeKeywords":false}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ExportSettings.self, from: old).includeInfo)
        let garbage = Data(#"{"includeInfo":"yes"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ExportSettings.self, from: garbage).includeInfo)
        var on = ExportSettings(); on.includeInfo = true
        XCTAssertTrue(try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(on)).includeInfo)
    }
}
