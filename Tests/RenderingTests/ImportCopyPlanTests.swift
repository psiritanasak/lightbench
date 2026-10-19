import XCTest
@testable import PhotoApp

final class ImportCopyPlanTests: XCTestCase {
    private let dest = URL(fileURLWithPath: "/Dest", isDirectory: true)

    /// 2026-10-19 08:30:00 as UTC digits (the capture wall clock convention).
    private func date(_ day: Int = 19, hour: Int = 8) -> Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = day; parts.hour = hour; parts.minute = 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: parts) ?? Date()
    }

    private func src(_ path: String, day: Int = 19, size: Int64 = 10) -> ImportCopySource {
        ImportCopySource(url: URL(fileURLWithPath: path), fileSize: size, captureDate: date(day))
    }

    private func env(files: Set<String> = [], existing: Set<String> = []) -> ImportCopyPlan.Environment {
        ImportCopyPlan.Environment(
            isRegularFile: { files.isEmpty ? true : files.contains($0.path) },
            exists: { existing.contains($0.path) }
        )
    }

    private func plan(_ sources: [ImportCopySource], _ options: ImportCopyOptions = ImportCopyOptions(),
                      environment: ImportCopyPlan.Environment? = nil) -> ImportCopyPlan {
        ImportCopyPlan.make(sources: sources, destination: dest, options: options, environment: environment ?? env())
    }

    // MARK: folders and names

    func testDefaultsKeepTheNameInTheDestinationFolder() {
        let result = plan([src("/Card/DCIM/IMG_1.JPG")])
        XCTAssertEqual(result.items.map(\.destination.path), ["/Dest/IMG_1.JPG"])
        XCTAssertNil(result.templateError)
    }

    func testYearMonthDaySubfolders() {
        var options = ImportCopyOptions()
        options.subfolders = .yearMonthDay
        let result = plan([src("/Card/a.jpg", day: 19), src("/Card/b.jpg", day: 3)], options)
        XCTAssertEqual(result.items.map(\.destination.path), ["/Dest/2026/10-19/a.jpg", "/Dest/2026/10-03/b.jpg"])
    }

    func testIsoDateSubfolders() {
        var options = ImportCopyOptions()
        options.subfolders = .isoDate
        XCTAssertEqual(plan([src("/Card/a.jpg")], options).items.first?.destination.path, "/Dest/2026-10-19/a.jpg")
    }

    func testTemplateWithDateAndSequenceKeepsTheExtensionCase() {
        var options = ImportCopyOptions()
        options.renameTemplate = "{date}_{seq:3}"
        let result = plan([src("/Card/DSC_1.NEF"), src("/Card/DSC_2.NEF")], options)
        XCTAssertEqual(result.items.map(\.destination.lastPathComponent), ["2026-10-19_001.NEF", "2026-10-19_002.NEF"])
    }

    func testAnInvalidTemplateYieldsNoItems() {
        var options = ImportCopyOptions()
        options.renameTemplate = "{bogus}"
        let result = plan([src("/Card/a.jpg")], options)
        XCTAssertNotNil(result.templateError)
        XCTAssertTrue(result.items.isEmpty)
    }

    // MARK: collisions

    func testTwoPhotosWithTheSameNameGetASuffixInsteadOfOverwritingEachOther() {
        let result = plan([src("/Card/A/IMG_1.jpg"), src("/Card/B/IMG_1.jpg"), src("/Card/C/img_1.JPG")])
        XCTAssertEqual(result.items.map(\.destination.lastPathComponent), ["IMG_1.jpg", "IMG_1 (2).jpg", "img_1 (3).JPG"])
    }

    func testCollisionsAreOnlyAgainstTheSameFolder() {
        var options = ImportCopyOptions()
        options.subfolders = .isoDate
        let result = plan([src("/Card/A/x.jpg", day: 19), src("/Card/B/x.jpg", day: 20)], options)
        XCTAssertEqual(result.items.map(\.destination.path), ["/Dest/2026-10-19/x.jpg", "/Dest/2026-10-20/x.jpg"])
    }

    func testExistingDestinationFileIsFlaggedForTheEngine() {
        let result = plan([src("/Card/a.jpg")], environment: env(existing: ["/Dest/a.jpg"]))
        XCTAssertEqual(result.items.first?.kind, .copy(destinationExists: true))
    }

    func testUnrelatedPhotosSharingABaseNameAreNotAPair() {
        let result = plan([src("/Card/100NIKON/DSC_0001.JPG"), src("/Card/101NIKON/DSC_0001.NEF")])
        XCTAssertEqual(result.items.map(\.destination.lastPathComponent), ["DSC_0001.JPG", "DSC_0001 (2).NEF"])
    }

    func testARawJpegPairFromOneFolderKeepsOneBaseName() {
        let result = plan([src("/Card/100NIKON/DSC_0001.NEF"), src("/Card/100NIKON/DSC_0001.JPG")])
        XCTAssertEqual(result.items.map(\.destination.lastPathComponent), ["DSC_0001.NEF", "DSC_0001.JPG"])
    }

    func testABlockedPhotoDoesNotUseUpASequenceNumber() {
        var options = ImportCopyOptions()
        options.renameTemplate = "{seq:3}"
        let result = plan([src("/Card/a.jpg"), src("/Card/dir.jpg"), src("/Card/b.jpg")], options,
                          environment: env(files: ["/Card/a.jpg", "/Card/b.jpg"]))
        XCTAssertEqual(result.copyItems.map(\.destination.lastPathComponent), ["001.jpg", "002.jpg"])
    }

    // MARK: blocked

    func testANonRegularFileIsBlockedAndNotCounted() {
        let result = plan([src("/Card/Edits.jpg"), src("/Card/ok.jpg")], environment: env(files: ["/Card/ok.jpg"]))
        XCTAssertEqual(result.copyItems.map(\.source.lastPathComponent), ["ok.jpg"])
        XCTAssertEqual(result.blockedItems.map(\.source.lastPathComponent), ["Edits.jpg"])
    }

    func testTotalBytesCountsOnlyCopies() {
        let result = plan([src("/Card/a.jpg", size: 5), src("/Card/b.jpg", size: 7), src("/Card/dir.jpg", size: 100)],
                          environment: env(files: ["/Card/a.jpg", "/Card/b.jpg"]))
        XCTAssertEqual(result.totalBytes, 12)
    }

    // MARK: companions

    func testEditFileAndDarktableXMPTravelRenamed() {
        var options = ImportCopyOptions()
        options.renameTemplate = "new_{seq}"
        let files: Set<String> = ["/Card/a.jpg", "/Card/a.jpg.photoapp.json", "/Card/a.jpg.xmp"]
        let item = plan([src("/Card/a.jpg")], options, environment: env(files: files)).items[0]
        XCTAssertEqual(Set(item.companions.map(\.destination.path)), ["/Dest/new_001.jpg.photoapp.json", "/Dest/new_001.jpg.xmp"])
    }

    func testARawOwnsTheSharedXMPAndTheJpegBesideItDoesNot() {
        let files: Set<String> = ["/Card/a.NEF", "/Card/a.jpg", "/Card/a.xmp"]
        let result = plan([src("/Card/a.NEF"), src("/Card/a.jpg")], environment: env(files: files))
        let raw = result.items.first { $0.source.lastPathComponent == "a.NEF" }
        let jpg = result.items.first { $0.source.lastPathComponent == "a.jpg" }
        XCTAssertEqual(raw?.companions.map(\.destination.path), ["/Dest/a.xmp"])
        XCTAssertEqual(jpg?.companions.map(\.destination.path), [])
    }

    func testALoneJpegOwnsItsSharedXMP() {
        let files: Set<String> = ["/Card/a.jpg", "/Card/a.xmp"]
        let item = plan([src("/Card/a.jpg")], environment: env(files: files)).items[0]
        XCTAssertEqual(item.companions.map(\.destination.path), ["/Dest/a.xmp"])
    }

    func testNoCompanionsWhenNoneExist() {
        let item = plan([src("/Card/a.jpg")], environment: env(files: ["/Card/a.jpg"])).items[0]
        XCTAssertTrue(item.companions.isEmpty)
    }
}
