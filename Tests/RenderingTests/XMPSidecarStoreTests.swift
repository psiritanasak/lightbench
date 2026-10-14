import XCTest
@testable import PhotoApp

final class XMPSidecarStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("XMPSidecarStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func photo(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private let foreign = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
     <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
       xmp:Rating="2" xmp:Label="Second" crs:Exposure2012="+1.25"/>
    </rdf:RDF></x:xmpmeta>
    """

    // MARK: names

    func testSidecarNamesFollowAdobeAndTheAlternateConvention() {
        let url = photo("IMG_1.CR2")
        XCTAssertEqual(XMPSidecarStore.sidecarURL(for: url).lastPathComponent, "IMG_1.xmp")
        XCTAssertEqual(XMPSidecarStore.alternateSidecarURL(for: url).lastPathComponent, "IMG_1.CR2.xmp")
    }

    func testWriteTargetUsesTheAlternateOnlyWhenItAloneExists() {
        let url = photo("a.jpg")
        let primary = XMPSidecarStore.sidecarURL(for: url), alt = XMPSidecarStore.alternateSidecarURL(for: url)
        XCTAssertEqual(XMPSidecarStore.writeTarget(for: url, fileExists: { _ in false }), primary)
        XCTAssertEqual(XMPSidecarStore.writeTarget(for: url, fileExists: { $0 == alt }), alt)
        XCTAssertEqual(XMPSidecarStore.writeTarget(for: url, fileExists: { _ in true }), primary)
    }

    // MARK: field mapping

    func testLabelNamesRoundTripAndBridgeNamesAreAccepted() {
        for label in ColorLabel.allCases {
            guard let name = XMPLibraryFields.labelName(label) else { XCTAssertEqual(label, .none); continue }
            XCTAssertEqual(XMPLibraryFields.label(fromName: name.uppercased()), label)
        }
        XCTAssertEqual(XMPLibraryFields.label(fromName: "Approved"), .green)
        XCTAssertEqual(XMPLibraryFields.label(fromName: ""), ColorLabel.none)
        XCTAssertNil(XMPLibraryFields.label(fromName: "Mauve"))
    }

    func testRatingParsingRejectsOutOfRangeAndMapsMinusOneToReject() {
        XCTAssertEqual(XMPLibraryFields.parseRating("-1")?.isRejected, true)
        XCTAssertEqual(XMPLibraryFields.parseRating("4")?.rating, 4)
        XCTAssertEqual(XMPLibraryFields.parseRating("4")?.isRejected, false)
        XCTAssertNil(XMPLibraryFields.parseRating("6"))
        XCTAssertNil(XMPLibraryFields.parseRating("-2"))
        XCTAssertNil(XMPLibraryFields.parseRating("x"))
        XCTAssertEqual(XMPLibraryFields.parseRating("4.0")?.rating, 4, "xmp:Rating is a Real")
        XCTAssertNil(XMPLibraryFields.parseRating("4.5"))
        XCTAssertEqual(XMPLibraryFields.ratingText(rating: 3, isRejected: true), "-1")
        XCTAssertEqual(XMPLibraryFields.ratingText(rating: 9, isRejected: false), "5")
    }

    // MARK: read

    func testMissingAndGarbageAreDistinct() throws {
        let url = photo("a.jpg")
        XCTAssertEqual(XMPSidecarStore.read(forPhotoAt: url), .missing)
        try Data("not xmp".utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        XCTAssertEqual(XMPSidecarStore.read(forPhotoAt: url), .undecodable)
    }

    func testReadsAForeignPacketAndFallsBackToTheAlternateName() throws {
        let url = photo("a.nef")
        try Data(foreign.utf8).write(to: XMPSidecarStore.alternateSidecarURL(for: url))
        guard case .decoded(let f) = XMPSidecarStore.read(forPhotoAt: url) else { return XCTFail("not decoded") }
        XCTAssertEqual(f.rating, 2)
        XCTAssertEqual(f.isRejected, false)
        XCTAssertEqual(f.label, .yellow)
        XCTAssertNil(f.keywords)
    }

    // MARK: write = merge

    func testWriteKeepsForeignTagsAndRoundTripsOurFields() throws {
        let url = photo("a.nef")
        let xmp = XMPSidecarStore.sidecarURL(for: url)
        try Data(foreign.utf8).write(to: xmp)
        try XMPSidecarStore.write(XMPLibraryFields(rating: 5, isRejected: false, label: .blue, keywords: ["Sky", "caf\u{00E9}"]), forPhotoAt: url)

        let text = try String(contentsOf: xmp, encoding: .utf8)
        XCTAssertTrue(text.contains("Exposure2012"), "foreign crs tag lost:\n\(text)")
        guard case .decoded(let f) = XMPSidecarStore.read(forPhotoAt: url) else { return XCTFail("not decoded") }
        XCTAssertEqual(f, XMPLibraryFields(rating: 5, isRejected: false, label: .blue, keywords: ["Sky", "caf\u{00E9}"]))
    }

    func testRejectedPhotoWritesMinusOneAndNoLabelRemovesTheTag() throws {
        let url = photo("a.nef")
        try Data(foreign.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        try XMPSidecarStore.write(XMPLibraryFields(rating: 3, isRejected: true, label: ColorLabel.none, keywords: []), forPhotoAt: url)
        guard case .decoded(let f) = XMPSidecarStore.read(forPhotoAt: url) else { return XCTFail("not decoded") }
        XCTAssertEqual(f.isRejected, true)
        XCTAssertNil(f.label)
        XCTAssertNil(f.keywords)
        XCTAssertTrue(try String(contentsOf: XMPSidecarStore.sidecarURL(for: url), encoding: .utf8).contains("Exposure2012"))
    }

    func testNoLabelNeverDeletesALabelWeDoNotUnderstand() throws {
        let url = photo("a.nef")
        let packet = foreign.replacingOccurrences(of: "xmp:Label=\"Second\"", with: "xmp:Label=\"Rot\"")
        try Data(packet.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        try XMPSidecarStore.write(XMPLibraryFields(label: ColorLabel.none), forPhotoAt: url)
        XCTAssertTrue(try String(contentsOf: XMPSidecarStore.sidecarURL(for: url), encoding: .utf8).contains("Rot"))
        // ...but a label we DO understand is removed.
        try Data(foreign.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        try XMPSidecarStore.write(XMPLibraryFields(label: ColorLabel.none), forPhotoAt: url)
        guard case .decoded(let f) = XMPSidecarStore.read(forPhotoAt: url) else { return XCTFail("not decoded") }
        XCTAssertNil(f.label)
    }

    func testRemovingATagThatIsNotThereIsNotAnError() throws {
        let url = photo("fresh.jpg")
        XCTAssertNil(try XMPSidecarStore.write(XMPLibraryFields(label: ColorLabel.none, keywords: []), forPhotoAt: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: XMPSidecarStore.sidecarURL(for: url).path), "no empty sidecar is created")
    }

    func testThePrimarySidecarNameWinsWhenBothExist() throws {
        let url = photo("a.nef")
        try Data(foreign.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        try Data(foreign.replacingOccurrences(of: "xmp:Rating=\"2\"", with: "xmp:Rating=\"5\"").utf8).write(to: XMPSidecarStore.alternateSidecarURL(for: url))
        guard case .decoded(let f) = XMPSidecarStore.read(forPhotoAt: url) else { return XCTFail("not decoded") }
        XCTAssertEqual(f.rating, 2)
    }

    func testANormalRatingUnRejectsAnExistingMinusOne() throws {
        let url = photo("a.nef")
        try XMPSidecarStore.write(XMPLibraryFields(rating: 0, isRejected: true), forPhotoAt: url)
        try XMPSidecarStore.write(XMPLibraryFields(rating: 3, isRejected: false), forPhotoAt: url)
        guard case .decoded(let f) = XMPSidecarStore.read(forPhotoAt: url) else { return XCTFail("not decoded") }
        XCTAssertEqual(f.isRejected, false)
        XCTAssertEqual(f.rating, 3)
    }

    func testAnUnparseableExistingSidecarIsNeverOverwritten() throws {
        let url = photo("a.jpg")
        let xmp = XMPSidecarStore.sidecarURL(for: url)
        let junk = Data("<<< hand edited, broken".utf8)
        try junk.write(to: xmp)
        XCTAssertThrowsError(try XMPSidecarStore.write(XMPLibraryFields(rating: 1), forPhotoAt: url)) {
            XCTAssertEqual($0 as? XMPSidecarStore.WriteError, .unreadableExisting)
        }
        XCTAssertEqual(try Data(contentsOf: xmp), junk)
    }

    func testWritingWithNothingExistingCreatesAFreshSidecar() throws {
        let url = photo("fresh.jpg")
        let written = try XMPSidecarStore.write(XMPLibraryFields(rating: 4, isRejected: false), forPhotoAt: url)
        XCTAssertEqual(written?.lastPathComponent, "fresh.xmp")
        guard case .decoded(let f) = XMPSidecarStore.read(forPhotoAt: url) else { return XCTFail("not decoded") }
        XCTAssertEqual(f.rating, 4)
    }

    func testNilFieldsLeaveTheExistingTagsAlone() throws {
        let url = photo("a.nef")
        try Data(foreign.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        try XMPSidecarStore.write(XMPLibraryFields(keywords: ["Only"]), forPhotoAt: url)
        guard case .decoded(let f) = XMPSidecarStore.read(forPhotoAt: url) else { return XCTFail("not decoded") }
        XCTAssertEqual(f.rating, 2)
        XCTAssertEqual(f.label, .yellow)
        XCTAssertEqual(f.keywords, ["Only"])
    }
}

final class XMPSidecarOwnershipTests: XCTestCase {
    private let d = URL(fileURLWithPath: "/tmp/x")
    private func u(_ n: String) -> URL { d.appendingPathComponent(n) }
    private let isRaw: (URL) -> Bool = { $0.pathExtension.lowercased() == "cr2" }

    func testARawFileOwnsTheSharedSidecar() {
        let all = [u("IMG_1.JPG"), u("IMG_1.CR2"), u("IMG_2.JPG")]
        XCTAssertEqual(XMPSidecarOwnership.owner(of: u("IMG_1.JPG"), among: all, isRaw: isRaw), u("IMG_1.CR2"))
        XCTAssertEqual(XMPSidecarOwnership.owner(of: u("IMG_2.JPG"), among: all, isRaw: isRaw), u("IMG_2.JPG"))
    }

    func testNoRawMeansFirstByNameOwnsAndCaseIsIgnored() {
        let all = [u("a.png"), u("A.jpg")]
        XCTAssertEqual(XMPSidecarOwnership.owner(of: u("a.png"), among: all, isRaw: isRaw), u("A.jpg"))
    }

    func testPartitionSkipsAJpegWhoseRawSiblingIsNotEvenSelected() {
        let all = [u("IMG_1.JPG"), u("IMG_1.CR2"), u("IMG_3.JPG")]
        let result = XMPSidecarOwnership.partition(selected: [u("IMG_1.JPG"), u("IMG_3.JPG")], allPhotos: all, isRaw: isRaw)
        XCTAssertEqual(result.writers, [u("IMG_3.JPG")])
        XCTAssertEqual(result.skipped.map(\.photo), [u("IMG_1.JPG")])
        XCTAssertEqual(result.skipped.map(\.owner), [u("IMG_1.CR2")])
    }

    func testDifferentFoldersDoNotCollide() {
        let other = URL(fileURLWithPath: "/tmp/y/IMG_1.CR2")
        XCTAssertEqual(XMPSidecarOwnership.owner(of: u("IMG_1.JPG"), among: [other], isRaw: isRaw), u("IMG_1.JPG"))
    }
}
