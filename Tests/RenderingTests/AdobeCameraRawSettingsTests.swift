import XCTest
import ImageIO
@testable import PhotoApp

/// The pure `crs:` parser: both XMP spellings, rdf:Seq curves, and junk tolerance.
final class AdobeCameraRawSettingsTests: XCTestCase {
    private func packet(attributes: String = "", elements: String = "") -> Data {
        Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            \(attributes)>
           \(elements)
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """.utf8)
    }

    // MARK: - Attribute vs element form

    func testAttributeFormScalarsAreRead() throws {
        let s = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(attributes: #"crs:Exposure2012="+0.65" crs:Contrast2012="+28" crs:ConvertToGrayscale="False""#)))
        XCTAssertEqual(s.number("Exposure2012"), 0.65)
        XCTAssertEqual(s.number("Contrast2012"), 28)
        XCTAssertEqual(s.flag("ConvertToGrayscale"), false)
    }

    func testElementFormScalarsAreReadTheSameAsAttributes() throws {
        let attr = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(attributes: #"crs:Exposure2012="+0.65" crs:HasCrop="True""#)))
        let elem = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(elements: "<crs:Exposure2012>+0.65</crs:Exposure2012><crs:HasCrop>True</crs:HasCrop>")))
        XCTAssertEqual(elem.number("Exposure2012"), 0.65)
        XCTAssertEqual(elem.flag("HasCrop"), true)
        XCTAssertEqual(attr, elem)
    }

    func testOtherNamespacesAreIgnored() throws {
        let s = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(attributes: #"xmp:Rating="3" crs:Vibrance="+10""#)))
        XCTAssertNil(s.text("Rating"))
        XCTAssertEqual(s.scalars.keys.sorted(), ["Vibrance"])
    }

    // MARK: - Curves

    func testSeqCurveIsParsedInFileOrder() throws {
        let seq = """
        <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>32, 22</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
        <crs:ToneCurvePV2012Red><rdf:Seq><rdf:li>0,0</rdf:li><rdf:li> 128 , 140 </rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012Red>
        """
        let s = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(elements: seq)))
        XCTAssertEqual(s.curve("ToneCurvePV2012"), [CGPoint(x: 0, y: 0), CGPoint(x: 32, y: 22), CGPoint(x: 255, y: 255)])
        XCTAssertEqual(s.curve("ToneCurvePV2012Red"), [CGPoint(x: 0, y: 0), CGPoint(x: 128, y: 140), CGPoint(x: 255, y: 255)])
        XCTAssertNil(s.curve("ToneCurvePV2012Green"))
    }

    func testMalformedCurvePointsAreDroppedNotFatal() throws {
        let seq = "<crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>nan, 4</rdf:li><rdf:li>1,2,3</rdf:li><rdf:li>x</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>"
        let s = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(elements: seq)))
        XCTAssertEqual(s.curve("ToneCurvePV2012"), [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)])
    }

    func testCurvePointCountIsBounded() throws {
        let items = (0..<500).map { "<rdf:li>\($0 % 256), \($0 % 256)</rdf:li>" }.joined()
        let s = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(elements: "<crs:ToneCurvePV2012><rdf:Seq>\(items)</rdf:Seq></crs:ToneCurvePV2012>")))
        XCTAssertEqual(s.curve("ToneCurvePV2012")?.count, AdobeCameraRawSettings.maximumCurvePoints)
    }

    // MARK: - Junk

    func testGarbageIsNilAndNeverCrashes() {
        XCTAssertNil(AdobeCameraRawSettings.parse(xmp: Data()))
        XCTAssertNil(AdobeCameraRawSettings.parse(xmp: Data("not xml at all".utf8)))
        XCTAssertNil(AdobeCameraRawSettings.parse(xmp: Data([0xFF, 0xFE, 0x00, 0x01])))
        XCTAssertNil(AdobeCameraRawSettings.read(from: URL(fileURLWithPath: "/nonexistent/x.xmp")))
    }

    func testPacketWithoutCrsIsEmptyNotNil() throws {
        let s = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(attributes: #"xmp:Rating="2""#)))
        XCTAssertTrue(s.isEmpty)
    }

    func testJunkValuesAreRejectedByTheTypedAccessors() throws {
        let attrs = #"crs:A="nan" crs:B="inf" crs:C="0x10" crs:D="" crs:E="1e999" crs:F="12abc" crs:G="--3" crs:H="+7""#
        let s = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(attributes: attrs)))
        for name in ["A", "B", "C", "D", "E", "F", "G"] { XCTAssertNil(s.number(name), name) }
        XCTAssertEqual(s.number("H"), 7)
        XCTAssertNil(s.number("Missing"))
        XCTAssertNil(s.flag("H"))
    }

    func testHugeValueIsDropped() throws {
        let huge = String(repeating: "9", count: AdobeCameraRawSettings.maximumValueLength + 1)
        let s = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(attributes: "crs:Big=\"\(huge)\" crs:Ok=\"5\"")))
        XCTAssertNil(s.text("Big"))
        XCTAssertEqual(s.number("Ok"), 5)
    }

    func testScalarCountIsBounded() throws {
        let attrs = (0..<(AdobeCameraRawSettings.maximumScalarCount + 300)).map { "crs:K\($0)=\"1\"" }.joined(separator: " ")
        let s = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(attributes: attrs)))
        XCTAssertEqual(s.scalars.count, AdobeCameraRawSettings.maximumScalarCount)
    }

    func testNumberSpellings() {
        XCTAssertEqual(AdobeCameraRawSettings.parseNumber("+0.65"), 0.65)
        XCTAssertEqual(AdobeCameraRawSettings.parseNumber(" -12 "), -12)
        XCTAssertEqual(AdobeCameraRawSettings.parseNumber("0.00"), 0)
        XCTAssertEqual(AdobeCameraRawSettings.parseNumber("1e2"), 100)
        XCTAssertNil(AdobeCameraRawSettings.parseNumber(""))
        XCTAssertNil(AdobeCameraRawSettings.parseNumber("Infinity"))
    }

    func testFlagSpellings() throws {
        let s = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(attributes: #"crs:A="True" crs:B="false" crs:C="1" crs:D="0" crs:E="maybe""#)))
        XCTAssertEqual(s.flag("A"), true)
        XCTAssertEqual(s.flag("B"), false)
        XCTAssertEqual(s.flag("C"), true)
        XCTAssertEqual(s.flag("D"), false)
        XCTAssertNil(s.flag("E"))
    }

    func testReadFromFileMatchesParse() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crs-\(UUID().uuidString).xmp")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = packet(attributes: #"crs:Exposure2012="+1.00""#)
        try data.write(to: url)
        XCTAssertEqual(AdobeCameraRawSettings.read(from: url), AdobeCameraRawSettings.parse(xmp: data))
        XCTAssertEqual(AdobeCameraRawSettings.read(from: url)?.number("Exposure2012"), 1)
    }

    // MARK: - Namespace matching (by URI, not prefix)

    private func packetBinding(prefix: String, uri: String, attribute: String) -> Data {
        Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:\(prefix)="\(uri)" \(prefix):\(attribute)/>
        </rdf:RDF></x:xmpmeta>
        """.utf8)
    }

    func testADifferentPrefixBoundToTheCrsURIIsAccepted() throws {
        let s = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packetBinding(prefix: "cr", uri: AdobeCameraRawSettings.namespace, attribute: #"Exposure2012="+1.5""#)))
        XCTAssertEqual(s.number("Exposure2012"), 1.5)
    }

    func testTheCrsPrefixBoundToAnotherURIIsRejected() throws {
        let s = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packetBinding(prefix: "crs", uri: "http://example.com/not-adobe/1.0/", attribute: #"Exposure2012="+1.5""#)))
        XCTAssertNil(s.number("Exposure2012"))
        XCTAssertTrue(s.isEmpty)
    }

    // MARK: - Structures

    func testStructuresAndArraysOfStructuresAreNamedNotInterpreted() throws {
        let elements = """
        <crs:MaskGroupBasedCorrections><rdf:Seq>
          <rdf:li rdf:parseType="Resource"><crs:What>Mask/Image</crs:What><crs:CorrectionAmount>1</crs:CorrectionAmount></rdf:li>
        </rdf:Seq></crs:MaskGroupBasedCorrections>
        <crs:RetouchAreas><rdf:Seq>
          <rdf:li><rdf:Description crs:SpotType="clone" crs:SourceX="0.4"/></rdf:li>
        </rdf:Seq></crs:RetouchAreas>
        <crs:Look rdf:parseType="Resource"><crs:Name>Adobe Color</crs:Name><crs:Amount>1</crs:Amount></crs:Look>
        """
        let s = try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(attributes: #"crs:Exposure2012="+1""#, elements: elements)))
        XCTAssertTrue(s.structuredNames.contains("MaskGroupBasedCorrections"), "\(s.structuredNames)")
        XCTAssertTrue(s.structuredNames.contains("RetouchAreas"), "\(s.structuredNames)")
        XCTAssertTrue(s.structuredNames.contains("Look"), "\(s.structuredNames)")
        XCTAssertNil(s.curve("MaskGroupBasedCorrections"))
        XCTAssertEqual(s.number("Exposure2012"), 1)
        XCTAssertNil(s.text("Amount"), "struct fields are not top-level settings")
    }

    // MARK: - File size

    func testAFileOverTheCapIsRefusedUnread() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crs-cap-\(UUID().uuidString).xmp")
        defer { try? FileManager.default.removeItem(at: url) }
        try packet(attributes: #"crs:Exposure2012="+1""#).write(to: url)
        XCTAssertNotNil(AdobeCameraRawSettings.read(from: url))
        XCTAssertNil(AdobeCameraRawSettings.read(from: url, maximumBytes: 10))
        XCTAssertEqual(AdobeCameraRawSettings.maximumFileSize, 4 * 1024 * 1024)
    }

    // MARK: - tiff:Orientation and bounded reads

    func testTheTiffOrientationOfThePacketIsRead() throws {
        let data = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
           tiff:Orientation="8" crs:Exposure2012="+1"/></rdf:RDF></x:xmpmeta>
        """.utf8)
        XCTAssertEqual(try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: data)).tiffOrientation, 8)
        XCTAssertNil(try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: packet(attributes: #"crs:A="1""#))).tiffOrientation)
        let junk = Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:tiff="http://ns.adobe.com/tiff/1.0/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" tiff:Orientation="99" crs:A="1"/></rdf:RDF></x:xmpmeta>"#.utf8)
        XCTAssertNil(try XCTUnwrap(AdobeCameraRawSettings.parse(xmp: junk)).tiffOrientation, "outside 1...8")
    }

    func testReadCappedRefusesNonRegularFilesAndOversizedSymlinkTargetsWithoutBlocking() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crs-capped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifo = dir.appendingPathComponent("pipe.xmp")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertEqual(AdobeCameraRawSettings.readCapped(fifo), .notRegular)
        XCTAssertNil(AdobeCameraRawSettings.read(from: fifo))
        let zero = dir.appendingPathComponent("zero.xmp")
        try FileManager.default.createSymbolicLink(at: zero, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        XCTAssertEqual(AdobeCameraRawSettings.readCapped(zero), .notRegular)
        XCTAssertEqual(AdobeCameraRawSettings.readCapped(dir), .notRegular)
        XCTAssertEqual(AdobeCameraRawSettings.readCapped(dir.appendingPathComponent("nope.xmp")), .notFound)

        let real = dir.appendingPathComponent("real.xmp")
        try Data(repeating: 0x20, count: 300).write(to: real)
        let link = dir.appendingPathComponent("link.xmp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(AdobeCameraRawSettings.readCapped(link, maximumBytes: 299), .tooLarge)
        XCTAssertEqual(AdobeCameraRawSettings.readCapped(link, maximumBytes: 300), .data(Data(repeating: 0x20, count: 300)))
    }
}
