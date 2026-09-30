import XCTest
@testable import PhotoApp

final class ExportNamePreviewTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_772_719_629) // 2026-03-05 14:07:09 (UTC digits)

    private func photo(_ filename: String = "IMG_0001.JPG", label: ColorLabel = .none) -> Photo {
        Photo(id: 1, path: "/tmp/\(filename)", filename: filename, fileSize: nil,
              importedAt: Date(timeIntervalSince1970: 0), colorLabel: label)
    }

    private func evaluate(_ template: String, photo: Photo? = nil, date: Date? = nil,
                          format: ExportFormat = .jpeg) -> ExportNamePreview? {
        ExportNamePreview.evaluate(template: template, photo: photo ?? self.photo(), format: format, captureDate: date)
    }

    func testAValidTemplateShowsAnExampleWithTheExportExtension() {
        XCTAssertEqual(evaluate("Trip_{seq}"), .example("Trip_001.jpg"))
        XCTAssertEqual(evaluate("Trip_{seq}", format: .png), .example("Trip_001.png"))
        XCTAssertEqual(evaluate("{name}"), .example("IMG_0001.jpg"))
    }

    func testAnInvalidTemplateIsATemplateErrorThatBlocksExport() {
        for bad in ["", "{bogus}", "{oops", "x}", "{seq:0}"] {
            guard case .templateError = evaluate(bad) else { return XCTFail("\(bad) should be a template error") }
            XCTAssertTrue(evaluate(bad)!.blocksExport, bad)
        }
        XCTAssertEqual(evaluate("{bogus}"), .templateError(.unknownToken("bogus")))
    }

    func testATemplateErrorShowsEvenWithoutAPhoto() {
        XCTAssertEqual(ExportNamePreview.evaluate(template: "{oops", photo: nil, format: .jpeg, captureDate: nil),
                       .templateError(.unterminatedBrace))
    }

    func testAValidTemplateWithNoPhotoShowsNothing() {
        XCTAssertNil(ExportNamePreview.evaluate(template: "{name}", photo: nil, format: .jpeg, captureDate: nil))
    }

    /// The first photo can't render (empty `{label}`) but other photos may: warn, don't block.
    func testAPerPhotoFailureIsAWarningThatDoesNotBlockExport() {
        let result = evaluate("{label}", photo: photo(label: .none))
        XCTAssertEqual(result, .photoError(.emptyResult))
        XCTAssertFalse(result!.blocksExport)
        XCTAssertEqual(evaluate("{label}", photo: photo(label: .red)), .example("red.jpg"))
    }

    func testATooLongResultIsAPhotoErrorNotABlock() {
        let result = evaluate(String(repeating: "a", count: 300))
        XCTAssertEqual(result, .photoError(.tooLong))
        XCTAssertFalse(result!.blocksExport)
    }

    /// While the capture date is still loading, a date template shows nothing rather than an
    /// example built from the (possibly different-day) import-date fallback.
    func testADateTemplateWaitsForTheCaptureDate() {
        XCTAssertEqual(evaluate("{date}_{seq}", date: nil), .waitingForDate)
        XCTAssertFalse(evaluate("{date}", date: nil)!.blocksExport)
        XCTAssertEqual(evaluate("{date}_{seq}", date: date), .example("2026-03-05_001.jpg"))
        // A template that doesn't use the date never waits.
        XCTAssertEqual(evaluate("{seq}", date: nil), .example("001.jpg"))
    }

    func testOnlyATemplateErrorBlocksExport() {
        XCTAssertFalse(ExportNamePreview.example("x.jpg").blocksExport)
        XCTAssertFalse(ExportNamePreview.photoError(.emptyResult).blocksExport)
        XCTAssertFalse(ExportNamePreview.waitingForDate.blocksExport)
        XCTAssertTrue(ExportNamePreview.templateError(.emptyTemplate).blocksExport)
    }
}
