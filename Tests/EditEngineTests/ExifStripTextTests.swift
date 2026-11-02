import XCTest
@testable import PhotoApp

final class ExifStripTextTests: XCTestCase {
    private func fields(iso: Int? = nil, focal: Double? = nil, aperture: Double? = nil, shutter: Double? = nil,
                        make: String? = nil, model: String? = nil, lens: String? = nil) -> PhotoMetadataReader.Fields {
        var f = PhotoMetadataReader.Fields()
        f.iso = iso; f.focalLength = focal; f.aperture = aperture; f.shutter = shutter
        f.cameraMake = make; f.cameraModel = model; f.lens = lens
        return f
    }

    func testShutterTable() {
        let table: [(Double, String)] = [
            (0.004, "1/250 s"), (1.0 / 60, "1/60 s"), (1.0 / 3, "1/3 s"), (0.5, "0.5 s"), (0.4, "0.4 s"),
            (1, "1 s"), (1.3, "1.3 s"), (2.5, "2.5 s"), (30, "30 s"), (0.0002, "1/5000 s")
        ]
        for (value, text) in table { XCTAssertEqual(ExifStripText.shutter(value), text, "\(value)") }
    }

    func testDegenerateNumbersNeverCrash() {
        for bad in [0.0, -1, .nan, .infinity, -.infinity, 1e300] {
            _ = ExifStripText.shutter(bad); _ = ExifStripText.aperture(bad); _ = ExifStripText.focalLength(bad)
        }
        var f = PhotoMetadataReader.Fields()
        f.shutter = 0; f.aperture = .nan; f.focalLength = .infinity
        XCTAssertNil(ExifStripText.exposureLine(f), "unusable numbers are skipped like missing fields")
        f.shutter = 0.004
        XCTAssertEqual(ExifStripText.exposureLine(f), "1/250 s")
    }

    func testApertureAndFocalLengthFormatting() {
        XCTAssertEqual(ExifStripText.aperture(2.8), "f/2.8")
        XCTAssertEqual(ExifStripText.aperture(8), "f/8")
        XCTAssertEqual(ExifStripText.aperture(1.8), "f/1.8")
        XCTAssertEqual(ExifStripText.focalLength(50), "50 mm")
        XCTAssertEqual(ExifStripText.focalLength(24.5), "24.5 mm")
    }

    func testFullExposureLine() {
        let f = fields(iso: 800, focal: 50, aperture: 2.8, shutter: 0.004)
        XCTAssertEqual(ExifStripText.exposureLine(f), "ISO 800 · 50 mm · f/2.8 · 1/250 s")
    }

    func testMissingFieldsAreSkippedAndEmptyIsNil() {
        XCTAssertEqual(ExifStripText.exposureLine(fields(iso: 100, shutter: 0.5)), "ISO 100 · 0.5 s")
        XCTAssertNil(ExifStripText.exposureLine(fields()))
        XCTAssertNil(ExifStripText.exposureLine(.empty))
        XCTAssertNil(ExifStripText.cameraLine(fields()))
        XCTAssertNil(ExifStripText.exposureLine(fields(make: "Nikon", model: "D610"))) // camera is not on the exposure line
    }

    func testCameraLineDeduplicatesMakeAndAppendsLens() {
        XCTAssertEqual(ExifStripText.cameraLine(fields(make: "NIKON CORPORATION", model: "NIKON D610", lens: "50.0 mm f/1.8")),
                       "NIKON D610 · 50.0 mm f/1.8")
        XCTAssertEqual(ExifStripText.cameraLine(fields(make: "Apple", model: "iPhone 15")), "Apple iPhone 15")
        XCTAssertEqual(ExifStripText.cameraLine(fields(lens: "RF 24-70")), "RF 24-70")
        XCTAssertEqual(ExifStripText.cameraLine(fields(make: "Canon")), "Canon")
    }

    func testCameraNameHelperIsTheOneUsedByPhotoMetadata() {
        XCTAssertEqual(PhotoMetadata.cameraName(make: "Canon", model: "Canon EOS R5"), "Canon EOS R5")
        XCTAssertNil(PhotoMetadata.cameraName(make: " ", model: nil))
        XCTAssertEqual(PhotoMetadata.cameraName(make: nil, model: "X100V"), "X100V")
    }

    func testHeaderIsOnlyForTheEditTab() {
        for tab in EditorTab.allCases { XCTAssertEqual(EditorHistogramHeader.isShown(on: tab), tab == .adjust, "\(tab)") }
    }

    /// The header must sit OUTSIDE the sidebar ScrollView (pinned), above it, Edit tab only, and the scroll memory must stay on the ScrollView.
    func testHeaderSitsOutsideTheScrollView() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI/ContentView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private var editControls"))
        let end = try XCTUnwrap(text.range(of: "#Preview", range: start.upperBound..<text.endIndex))
        let body = String(text[start.lowerBound..<end.lowerBound])
        let header = try XCTUnwrap(body.range(of: "EditorHistogramHeader("))
        let scroll = try XCTUnwrap(body.range(of: "ScrollView {"))
        XCTAssertLessThan(header.lowerBound, scroll.lowerBound, "the header comes before the ScrollView")
        let use = try XCTUnwrap(body.range(of: "            editScroll\n"), "the VStack places the scroll view")
        XCTAssertLessThan(header.lowerBound, use.lowerBound, "the header is placed above the scroll view in the VStack")
        XCTAssertEqual(body.components(separatedBy: "EditorHistogramHeader(").count - 1, 1)
        XCTAssertTrue(body.contains("EditorHistogramHeader.isShown(on: selectedTab)"))
        let memory = try XCTUnwrap(body.range(of: ".tabScrollMemory("))
        XCTAssertGreaterThan(memory.lowerBound, scroll.lowerBound)
        let afterScroll = String(body[scroll.lowerBound...])
        XCTAssertFalse(afterScroll.contains("EditorHistogramHeader("), "no header inside the scroll view")
    }
}
