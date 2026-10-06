import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoApp

final class KeywordEmbeddingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("KeywordEmbeddingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let hard = ["Sky", "caf\u{00E9} \u{2615}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} family", "\u{65E5}\u{672C}"]

    // MARK: merged

    func testMergedKeepsCatalogOrderThenSourceExtrasAndDedupesCaseInsensitively() {
        XCTAssertEqual(KeywordEmbedding.merged(catalog: ["Sky", "Beach"], existing: ["beach", "Sunset", "SKY"]), ["Sky", "Beach", "Sunset"])
    }

    func testMergedTreatsCanonicallyEquivalentSpellingsAsOneAndDropsBlanks() {
        XCTAssertEqual(KeywordEmbedding.merged(catalog: ["Cafe\u{0301}"], existing: ["Caf\u{00E9}", "  ", ""]), ["Cafe\u{0301}"])
    }

    // MARK: properties gate

    private func iptcKeywords(_ props: [String: Any]) -> [String]? {
        (props[kCGImagePropertyIPTCDictionary as String] as? [String: Any])?[kCGImagePropertyIPTCKeywords as String] as? [String]
    }

    func testPropertiesAddsKeywordsAndPreservesOtherIPTCFields() {
        let base: [String: Any] = [kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCCaptionAbstract as String: "cap",
                                                                              kCGImagePropertyIPTCKeywords as String: ["Old", "sky"]]]
        let out = KeywordEmbedding.properties(base, addingKeywords: ["Sky"], policy: .all, include: true)
        XCTAssertEqual(iptcKeywords(out), ["Sky", "Old"])
        XCTAssertEqual((out[kCGImagePropertyIPTCDictionary as String] as? [String: Any])?[kCGImagePropertyIPTCCaptionAbstract as String] as? String, "cap")
    }

    func testPropertiesIsUnchangedWhenOffOrPolicyNoneOrNothingToAdd() {
        let base: [String: Any] = [kCGImagePropertyDPIWidth as String: 72]
        for (policy, include, kws) in [(ExportMetadataPolicy.all, false, ["A"]), (.none, true, ["A"])] {
            let out = KeywordEmbedding.properties(base, addingKeywords: kws, policy: policy, include: include)
            XCTAssertNil(out[kCGImagePropertyIPTCDictionary as String], "\(policy) include=\(include) kws=\(kws)")
        }
        // Nothing to add: the source's own keywords are passed through untouched (not re-ordered or trimmed).
        let withSource: [String: Any] = [kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCKeywords as String: [" b ", "A"]]]
        let same = KeywordEmbedding.properties(withSource, addingKeywords: [], policy: .withoutLocation, include: true)
        XCTAssertEqual(iptcKeywords(same), [" b ", "A"])
    }

    func testAnUnrelatedSingleStringSourceKeywordIsKept() {
        let base: [String: Any] = [kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCKeywords as String: "Solo"]]
        XCTAssertEqual(iptcKeywords(KeywordEmbedding.properties(base, addingKeywords: ["A"], policy: .all, include: true)), ["A", "Solo"])
    }

    // MARK: settings

    func testIncludeKeywordsDefaultsOnAndDecodesWhenMissing() throws {
        XCTAssertTrue(ExportSettings().includeKeywords)
        let old = #"{"format":"png","quality":0.8}"#.data(using: .utf8)!
        XCTAssertTrue(try JSONDecoder().decode(ExportSettings.self, from: old).includeKeywords)
        var off = ExportSettings(); off.includeKeywords = false
        XCTAssertFalse(try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(off)).includeKeywords)
    }

    // MARK: end to end (also the permanent record that ImageIO emits IPTC + XMP for every format)

    private func makeSource(keywords: [String]? = nil) throws -> Photo {
        let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        let cg = try XCTUnwrap(CIContext().createCGImage(base, from: base.extent))
        let url = dir.appendingPathComponent("src.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var iptc: [CFString: Any] = [kCGImagePropertyIPTCCaptionAbstract: "a caption"]
        if let keywords { iptc[kCGImagePropertyIPTCKeywords] = keywords }
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyIPTCDictionary: iptc] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return Photo(id: 1, path: url.path, filename: "src.jpg", fileSize: nil, importedAt: Date())
    }

    private func readKeywords(_ url: URL) throws -> (iptc: [String], xmp: [String]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let iptc = iptcKeywords(props) ?? []
        var xmp: [String] = []
        if let md = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tag = CGImageMetadataCopyTagWithPath(md, nil, "dc:subject" as CFString),
           let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] {
            xmp = values.compactMap { CGImageMetadataTagCopyValue($0) as? String }
        }
        return (iptc, xmp)
    }

    func testWritersEmitIPTCAndXMPForEveryFormat() async throws {
        let photo = try makeSource()
        for format in ExportFormat.allCases {
            let url = try await PhotoExporter.export(
                photo, editState: .identity, to: dir,
                settings: ExportSettings(format: format, namingTemplate: "kw-\(format.rawValue)"), keywords: hard
            )
            let read = try readKeywords(url)
            XCTAssertEqual(read.iptc, hard, "\(format) IPTC")
            XCTAssertEqual(read.xmp, hard, "\(format) XMP dc:subject")
        }
    }

    /// The union's completeness depends on ImageIO mirroring a source's XMP-only `dc:subject` into its IPTC keywords.
    func testXMPOnlySourceKeywordsAreUnioned() async throws {
        let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        let cg = try XCTUnwrap(CIContext().createCGImage(base, from: base.extent))
        let url = dir.appendingPathComponent("xmponly.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let md = CGImageMetadataCreateMutable()
        let bag = [CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore, "subject" as CFString,
                                            .arrayUnordered, ["XmpOnly" as CFString] as CFArray)]
        XCTAssertTrue(CGImageMetadataSetTagWithPath(md, nil, "dc:subject" as CFString, try XCTUnwrap(bag[0])))
        CGImageDestinationAddImageAndMetadata(dest, cg, md, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let photo = Photo(id: 2, path: url.path, filename: "xmponly.jpg", fileSize: nil, importedAt: Date())
        let out = try await PhotoExporter.export(
            photo, editState: .identity, to: dir, settings: ExportSettings(namingTemplate: "xmpunion", metadata: .all), keywords: ["Sky"])
        let read = try readKeywords(out)
        XCTAssertEqual(read.iptc, ["Sky", "XmpOnly"])
        XCTAssertEqual(read.xmp, ["Sky", "XmpOnly"])
    }

    func testNonePolicyAndToggleOffEmbedNothingAndSourceKeywordsAreUnionedNotDuplicated() async throws {
        let photo = try makeSource(keywords: ["sky", "Original"])
        let none = try await PhotoExporter.export(
            photo, editState: .identity, to: dir, settings: ExportSettings(namingTemplate: "none", metadata: .none), keywords: hard)
        let noneRead = try readKeywords(none)
        XCTAssertEqual(noneRead.iptc + noneRead.xmp, [], "No metadata means no keywords, even the catalog's")

        var off = ExportSettings(namingTemplate: "off", metadata: .all); off.includeKeywords = false
        let offURL = try await PhotoExporter.export(photo, editState: .identity, to: dir, settings: off, keywords: hard)
        let offRead = try readKeywords(offURL)
        XCTAssertEqual(offRead.iptc, ["sky", "Original"], "toggle off leaves only what the source already had")
        XCTAssertEqual(offRead.xmp, ["sky", "Original"])
        XCTAssertTrue(Set(offRead.iptc + offRead.xmp).isDisjoint(with: hard), "none of the catalog's keywords leak when off")

        let both = try await PhotoExporter.export(
            photo, editState: .identity, to: dir, settings: ExportSettings(namingTemplate: "both", metadata: .all), keywords: ["Sky", "Beach"])
        XCTAssertEqual(try readKeywords(both).iptc, ["Sky", "Beach", "Original"])
    }
}
