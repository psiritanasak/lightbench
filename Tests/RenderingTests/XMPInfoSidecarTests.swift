import XCTest
import ImageIO
@testable import PhotoApp

/// The Info panel values (title, caption, creator, copyright) in standard `.xmp` sidecars.
final class XMPInfoSidecarTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("XMPInfoSidecarTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func photo(_ name: String = "a.jpg") -> URL { dir.appendingPathComponent(name) }

    private func sidecarText(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: XMPSidecarStore.sidecarURL(for: url)), as: UTF8.self)
    }

    private func readFields(_ url: URL) throws -> XMPLibraryFields {
        guard case .decoded(let fields) = XMPSidecarStore.read(forPhotoAt: url) else { throw XCTSkip("no sidecar") }
        return fields
    }

    /// Lightroom-shaped packet: foreign tags, a German title next to the default, two creators, a rating.
    private let foreign = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"
      xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" xmp:Rating="2" crs:Exposure2012="+1.25">
    <dc:title><rdf:Alt><rdf:li xml:lang="de">Titel</rdf:li><rdf:li xml:lang="x-default">Old title</rdf:li></rdf:Alt></dc:title>
    <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">(c) Old</rdf:li></rdf:Alt></dc:rights>
    <dc:creator><rdf:Seq><rdf:li>Ann</rdf:li><rdf:li>Bob</rdf:li></rdf:Seq></dc:creator>
    </rdf:Description></rdf:RDF></x:xmpmeta>
    """

    private func plantForeign(for url: URL) throws {
        try Data(foreign.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
    }

    // MARK: round trip

    func testInfoRoundTripsThroughAFreshSidecarIncludingMarkupAndUnicode() throws {
        let url = photo()
        let info = PhotoInfo(title: "Caf\u{00E9} & <\"Co\">'s \u{65E5}\u{672C}", caption: "Line1\nLine2 \u{1F468}\u{200D}\u{1F469}", creator: "Jane Doe", copyright: "\u{00A9} 2026 Jane")
        XCTAssertNotNil(try XMPSidecarStore.write(XMPLibraryFields(info: info), forPhotoAt: url))
        let read = try readFields(url)
        XCTAssertEqual(read.info, info)
        XCTAssertEqual(read.title, info.title)
        let text = try sidecarText(url)
        XCTAssertTrue(text.contains("xml:lang=\"x-default\""), "title is a language alternative:\n\(text)")
        XCTAssertTrue(text.contains("<rdf:Seq>"), "creator is an ordered array:\n\(text)")
    }

    func testWritingInfoKeepsForeignTagsAndOtherLanguageEntries() throws {
        let url = photo()
        try plantForeign(for: url)
        try XMPSidecarStore.write(XMPLibraryFields(title: "New title", copyright: "(c) New"), forPhotoAt: url)
        let text = try sidecarText(url)
        XCTAssertTrue(text.contains("Exposure2012"), "foreign tag kept:\n\(text)")
        XCTAssertTrue(text.contains("Titel"), "the German entry is kept")
        XCTAssertFalse(text.contains("Old title"))
        let read = try readFields(url)
        XCTAssertEqual(read.title, "New title")
        XCTAssertEqual(read.copyright, "(c) New")
        XCTAssertEqual(read.rating, 2)
    }

    func testEmptyOrNilInfoNeverErasesWhatTheFileHolds() throws {
        let url = photo()
        try plantForeign(for: url)
        try XMPSidecarStore.write(XMPLibraryFields(rating: 4, isRejected: false, title: "", caption: "", creator: "", copyright: nil), forPhotoAt: url)
        let read = try readFields(url)
        XCTAssertEqual(read.title, "Old title")
        XCTAssertEqual(read.copyright, "(c) Old")
        XCTAssertEqual(read.creator, "Ann, Bob")
        XCTAssertNil(read.caption)
        XCTAssertEqual(read.rating, 4)
    }

    func testAnEmptyInfoAloneNeverCreatesASidecar() throws {
        let url = photo()
        XCTAssertNil(try XMPSidecarStore.write(XMPLibraryFields(info: PhotoInfo()), forPhotoAt: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: XMPSidecarStore.sidecarURL(for: url).path))
    }

    func testCreatorEqualToTheFilesJoinedCreatorsLeavesTheArrayAlone() throws {
        let url = photo()
        try plantForeign(for: url)
        try XMPSidecarStore.write(XMPLibraryFields(creator: "Ann, Bob"), forPhotoAt: url)
        XCTAssertTrue(try sidecarText(url).contains("Bob"), "a two-author array must not collapse when nothing changed")
        try XMPSidecarStore.write(XMPLibraryFields(creator: "Cy"), forPhotoAt: url)
        let text = try sidecarText(url)
        XCTAssertFalse(text.contains("Bob"))
        XCTAssertEqual(try readFields(url).creator, "Cy")
    }

    // MARK: reading

    func testReadPrefersXDefaultThenFirstEntryAndTreatsBlankAsAbsent() throws {
        let packet = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title><rdf:Alt><rdf:li xml:lang="fr">Titre</rdf:li><rdf:li xml:lang="de">Titel</rdf:li></rdf:Alt></dc:title>
        <dc:description><rdf:Alt><rdf:li xml:lang="de">Beschr</rdf:li><rdf:li xml:lang="x-default">Descr</rdf:li></rdf:Alt></dc:description>
        <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">   </rdf:li></rdf:Alt></dc:rights>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let fields = try XCTUnwrap(XMPSidecarStore.fields(fromXMP: Data(packet.utf8)))
        XCTAssertEqual(fields.title, "Titre")
        XCTAssertEqual(fields.caption, "Descr")
        XCTAssertNil(fields.copyright)
        XCTAssertNil(fields.creator)
        XCTAssertNil(XMPLibraryFields().info)
        XCTAssertEqual(fields.info, PhotoInfo(title: "Titre", caption: "Descr", creator: "", copyright: ""))
    }

    func testIsEmptyCountsInfoFields() {
        XCTAssertTrue(XMPLibraryFields().isEmpty)
        for fields in [XMPLibraryFields(title: "t"), XMPLibraryFields(caption: "c"), XMPLibraryFields(creator: "a"), XMPLibraryFields(copyright: "r")] {
            XCTAssertFalse(fields.isEmpty)
        }
    }
}
