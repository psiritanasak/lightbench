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
}
