import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoApp

/// PERMANENT probe for the XMP sidecar interop feature (not a throwaway): it pins what ImageIO's
/// `CGImageMetadata` XMP API really does with a standalone `.xmp` packet — the premise the whole
/// merge-never-clobber design rests on. Results are recorded in docs/ROADMAP_HISTORY.md.
final class XMPSidecarProbeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("XMPSidecarProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A packet shaped like what Lightroom / Camera Raw writes next to a RAW file.
    private let lightroomPacket = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
        xmp:Rating="3"
        xmp:Label="Red"
        crs:Exposure2012="+0.50"
        crs:Temperature="5200">
       <crs:ToneCurvePV2012>
        <rdf:Seq>
         <rdf:li>0, 0</rdf:li>
         <rdf:li>255, 255</rdf:li>
        </rdf:Seq>
       </crs:ToneCurvePV2012>
       <dc:subject>
        <rdf:Bag>
         <rdf:li>Sky</rdf:li>
         <rdf:li>caf\u{00E9}</rdf:li>
        </rdf:Bag>
       </dc:subject>
       <lr:hierarchicalSubject>
        <rdf:Bag>
         <rdf:li>Places|Bolivia</rdf:li>
        </rdf:Bag>
       </lr:hierarchicalSubject>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """

    private func parse(_ text: String) -> CGImageMetadata? {
        CGImageMetadataCreateFromXMPData(Data(text.utf8) as CFData)
    }

    private func string(_ md: CGImageMetadata, _ path: String) -> String? {
        guard let tag = CGImageMetadataCopyTagWithPath(md, nil, path as CFString) else { return nil }
        return CGImageMetadataTagCopyValue(tag) as? String
    }

    private func bag(_ md: CGImageMetadata, _ path: String) -> [String]? {
        guard let tag = CGImageMetadataCopyTagWithPath(md, nil, path as CFString),
              let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return nil }
        return values.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    // MARK: parse

    func testParsesALightroomPacketIntoTheThreeFieldsWeOwn() throws {
        let md = try XCTUnwrap(parse(lightroomPacket))
        XCTAssertEqual(string(md, "xmp:Rating"), "3")
        XCTAssertEqual(string(md, "xmp:Label"), "Red")
        XCTAssertEqual(bag(md, "dc:subject"), ["Sky", "caf\u{00E9}"])
    }

    func testGarbageDoesNotParse() {
        XCTAssertNil(parse("this is not xmp"))
        XCTAssertNil(parse("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF"))
    }

    // MARK: merge keeps foreign tags (the premise of "never clobber")

    func testSettingOurPathsKeepsForeignCameraRawAndLightroomTags() throws {
        let md = try XCTUnwrap(parse(lightroomPacket))
        let mutable = try XCTUnwrap(CGImageMetadataCreateMutableCopy(md))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(mutable, nil, "xmp:Rating" as CFString, "5" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(mutable, nil, "xmp:Label" as CFString, "Blue" as CFString))
        let data = try XCTUnwrap(CGImageMetadataCreateXMPData(mutable, nil))
        let reparsed = try XCTUnwrap(CGImageMetadataCreateFromXMPData(data))

        XCTAssertEqual(string(reparsed, "xmp:Rating"), "5")
        XCTAssertEqual(string(reparsed, "xmp:Label"), "Blue")
        XCTAssertEqual(string(reparsed, "crs:Exposure2012"), "+0.50", "a foreign Camera Raw tag must survive the merge")
        XCTAssertEqual(string(reparsed, "crs:Temperature"), "5200")
        XCTAssertEqual(bag(reparsed, "lr:hierarchicalSubject"), ["Places|Bolivia"])
        XCTAssertEqual(bag(reparsed, "crs:ToneCurvePV2012"), ["0, 0", "255, 255"], "a nested Camera Raw sequence must survive too")
        let text = String(decoding: data as Data, as: UTF8.self)
        XCTAssertTrue(text.contains("Exposure2012"), "serialised packet:\n\(text)")
    }

    func testReplacingTheKeywordBagAndRemovingTagsKeepsForeignTags() throws {
        let md = try XCTUnwrap(parse(lightroomPacket))
        let mutable = try XCTUnwrap(CGImageMetadataCreateMutableCopy(md))
        let bagTag = try XCTUnwrap(CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                                           "subject" as CFString, .arrayUnordered,
                                                           ["Beach", "Sky"] as CFArray))
        XCTAssertTrue(CGImageMetadataSetTagWithPath(mutable, nil, "dc:subject" as CFString, bagTag))
        XCTAssertTrue(CGImageMetadataRemoveTagWithPath(mutable, nil, "xmp:Label" as CFString))
        let data = try XCTUnwrap(CGImageMetadataCreateXMPData(mutable, nil))
        let reparsed = try XCTUnwrap(CGImageMetadataCreateFromXMPData(data))

        XCTAssertEqual(Set(bag(reparsed, "dc:subject") ?? []), ["Beach", "Sky"])
        XCTAssertNil(string(reparsed, "xmp:Label"))
        XCTAssertEqual(string(reparsed, "xmp:Rating"), "3")
        XCTAssertEqual(string(reparsed, "crs:Exposure2012"), "+0.50")
    }

    func testAFreshPacketCanBeBuiltFromNothing() throws {
        let mutable = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataSetValueWithPath(mutable, nil, "xmp:Rating" as CFString, "-1" as CFString))
        let data = try XCTUnwrap(CGImageMetadataCreateXMPData(mutable, nil))
        let reparsed = try XCTUnwrap(CGImageMetadataCreateFromXMPData(data))
        XCTAssertEqual(string(reparsed, "xmp:Rating"), "-1")
    }

    // MARK: embedded XMP in a photo

    func testRatingAndKeywordsInsideAJPEGAreReadable() throws {
        let url = dir.appendingPathComponent("embedded.jpg")
        let mutable = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataSetValueWithPath(mutable, nil, "xmp:Rating" as CFString, "4" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(mutable, nil, "xmp:Label" as CFString, "Green" as CFString))
        let kw = try XCTUnwrap(CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                                       "subject" as CFString, .arrayUnordered, ["Alpha"] as CFArray))
        XCTAssertTrue(CGImageMetadataSetTagWithPath(mutable, nil, "dc:subject" as CFString, kw))

        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(ctx.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(dest, image, mutable, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let md = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        XCTAssertEqual(string(md, "xmp:Rating"), "4")
        XCTAssertEqual(string(md, "xmp:Label"), "Green")
        XCTAssertEqual(bag(md, "dc:subject"), ["Alpha"])
    }

    // MARK: language alternatives and ordered arrays (Info panel: dc:title / dc:description / dc:rights / dc:creator)

    private let infoPacket = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Temperature="5200">
    <dc:title><rdf:Alt><rdf:li xml:lang="de">Titel</rdf:li><rdf:li xml:lang="x-default">Title</rdf:li></rdf:Alt></dc:title>
    <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">(c) Old</rdf:li></rdf:Alt></dc:rights>
    <dc:creator><rdf:Seq><rdf:li>Ann</rdf:li><rdf:li>Bob</rdf:li></rdf:Seq></dc:creator>
    </rdf:Description></rdf:RDF></x:xmpmeta>
    """

    /// A one-entry `x-default` language alternative, parsed from a packet (the only route found that writes one: see the next test).
    private func altTag(_ name: String, _ text: String) throws -> CGImageMetadataTag {
        let xml = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:\(name)><rdf:Alt>"
            + "<rdf:li xml:lang=\"x-default\">\(text)</rdf:li></rdf:Alt></dc:\(name)></rdf:Description></rdf:RDF></x:xmpmeta>"
        let parsed = try XCTUnwrap(CGImageMetadataCreateFromXMPData(Data(xml.utf8) as CFData))
        return try XCTUnwrap(CGImageMetadataCopyTagWithPath(parsed, nil, "dc:\(name)" as CFString))
    }

    func testALanguageAlternativeReadsAsTaggedEntriesWithTheirXMLLangQualifier() throws {
        let md = try XCTUnwrap(parse(infoPacket))
        let tag = try XCTUnwrap(CGImageMetadataCopyTagWithPath(md, nil, "dc:title" as CFString))
        XCTAssertEqual(CGImageMetadataTagGetType(tag), .alternateText)
        let entries = try XCTUnwrap(CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag])
        let pairs: [(String, String)] = entries.compactMap { entry in
            let quals = CGImageMetadataTagCopyQualifiers(entry) as? [CGImageMetadataTag]
            guard let lang = quals?.first(where: { CGImageMetadataTagCopyName($0) as String? == "lang" }),
                  let langValue = CGImageMetadataTagCopyValue(lang) as? String,
                  let text = CGImageMetadataTagCopyValue(entry) as? String else { return nil }
            return (langValue, text)
        }
        XCTAssertEqual(pairs.map(\.0).sorted(), ["de", "x-default"])
        XCTAssertEqual(pairs.first { $0.0 == "x-default" }?.1, "Title")
        XCTAssertEqual(pairs.first { $0.0 == "de" }?.1, "Titel")
    }

    func testAPlainStringSetOnALanguageAlternativeEmptiesItAndOnAFreshPacketWritesASimpleProperty() throws {
        // Measured: the obvious route must NOT be used for these tags.
        let existing = try XCTUnwrap(CGImageMetadataCreateMutableCopy(try XCTUnwrap(parse(infoPacket))))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(existing, nil, "dc:title" as CFString, "Plain" as CFString))
        let reparsed = try XCTUnwrap(CGImageMetadataCreateFromXMPData(try XCTUnwrap(CGImageMetadataCreateXMPData(existing, nil))))
        XCTAssertNil(CGImageMetadataCopyStringValueWithPath(reparsed, nil, "dc:title" as CFString) as String?, "the existing rdf:Alt was emptied, not updated")

        let fresh = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataSetValueWithPath(fresh, nil, "dc:title" as CFString, "Plain" as CFString))
        let text = String(decoding: try XCTUnwrap(CGImageMetadataCreateXMPData(fresh, nil)) as Data, as: UTF8.self)
        XCTAssertFalse(text.contains("rdf:Alt"), "a plain set writes a simple property, not a language alternative:\n\(text)")
        // The path-with-qualifier route is refused outright.
        XCTAssertFalse(CGImageMetadataSetValueWithPath(fresh, nil, "dc:title[?xml:lang=\"x-default\"]" as CFString, "X" as CFString))
    }

    func testACopiedAltTagWritesAnXDefaultLanguageAlternativeAndKeepsForeignTagsAndAnOrderedCreator() throws {
        let mutable = try XCTUnwrap(CGImageMetadataCreateMutableCopy(try XCTUnwrap(parse(infoPacket))))
        XCTAssertTrue(CGImageMetadataSetTagWithPath(mutable, nil, "dc:title" as CFString, try altTag("title", "New T\u{00E9}tle")))
        XCTAssertTrue(CGImageMetadataSetTagWithPath(mutable, nil, "dc:rights" as CFString, try altTag("rights", "(c) New")))
        let seq = try XCTUnwrap(CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                                        "creator" as CFString, .arrayOrdered, ["Zed", "Yan"] as CFArray))
        XCTAssertTrue(CGImageMetadataSetTagWithPath(mutable, nil, "dc:creator" as CFString, seq))
        let data = try XCTUnwrap(CGImageMetadataCreateXMPData(mutable, nil))
        let text = String(decoding: data as Data, as: UTF8.self)
        let reparsed = try XCTUnwrap(CGImageMetadataCreateFromXMPData(data))
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(reparsed, nil, "dc:title" as CFString) as String?, "New T\u{00E9}tle")
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(reparsed, nil, "dc:rights" as CFString) as String?, "(c) New")
        XCTAssertEqual(bag(reparsed, "dc:creator"), ["Zed", "Yan"], "an ordered array keeps its order")
        XCTAssertEqual(string(reparsed, "crs:Temperature"), "5200", "a foreign tag survives")
        XCTAssertTrue(text.contains("<rdf:Seq>") && text.contains("xml:lang=\"x-default\""), "serialised packet:\n\(text)")
        XCTAssertFalse(text.contains("Titel"), "a replaced alternative drops the other-language entry unless the caller re-adds it")
    }
}
