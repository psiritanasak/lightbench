import XCTest
@testable import PhotoApp

/// `JustifiedScrollTarget` (which scroll target a layout uses) and `ThumbnailAspect` (thumbnail shape vs file shape).
final class JustifiedGridSupportTests: XCTestCase {
    private func rows(width: Double) -> [JustifiedRows.Row] {
        JustifiedRows.layout(aspects: [Double](repeating: 1.5, count: 12), availableWidth: width, targetRowHeight: 150, spacing: 8)
    }

    func testSquareLayoutScrollsToTheCellItself() {
        XCTAssertEqual(JustifiedScrollTarget.target(forCellID: "c5", cellIDs: ["c0", "c5"], justifiedRows: nil), .cell("c5"))
    }

    func testJustifiedLayoutScrollsToTheRowHoldingTheCell() throws {
        let laid = rows(width: 900)
        XCTAssertEqual(laid.map { $0.items.count }, [4, 4, 4])
        let ids = (0..<12).map { "c\($0)" }
        XCTAssertEqual(JustifiedScrollTarget.target(forCellID: "c0", cellIDs: ids, justifiedRows: laid), .row(0))
        XCTAssertEqual(JustifiedScrollTarget.target(forCellID: "c9", cellIDs: ids, justifiedRows: laid), .row(2))
        XCTAssertNil(JustifiedScrollTarget.target(forCellID: "nope", cellIDs: ids, justifiedRows: laid))
    }

    func testTheRowOfACellDependsOnTheWidthTheRowsWereLaidOutWith() {
        let ids = (0..<12).map { "c\($0)" }
        // Before a width is measured (0) every photo sits in its own row: the same cell lands in a different row than at the real width.
        XCTAssertEqual(JustifiedScrollTarget.target(forCellID: "c9", cellIDs: ids, justifiedRows: rows(width: 0)), .row(9))
        XCTAssertEqual(JustifiedScrollTarget.target(forCellID: "c9", cellIDs: ids, justifiedRows: rows(width: 900)), .row(2))
    }

    func testRestoreWaitsForARealWidthOnlyInTheJustifiedLayout() {
        XCTAssertTrue(JustifiedScrollTarget.canRestore(isJustified: false, gridWidth: 0))
        XCTAssertFalse(JustifiedScrollTarget.canRestore(isJustified: true, gridWidth: 0))
        XCTAssertFalse(JustifiedScrollTarget.canRestore(isJustified: true, gridWidth: .nan))
        XCTAssertTrue(JustifiedScrollTarget.canRestore(isJustified: true, gridWidth: 800))
    }

    func testRowViewID() {
        XCTAssertEqual(JustifiedScrollTarget.rowViewID(3), "justified-row-3")
    }

    // MARK: ThumbnailAspect

    func testAnUneditedThumbnailReportsNothing() {
        // 6000x4000 file, 240x160 thumbnail; a rounding-off thumbnail (240x159) is still the file's shape.
        XCTAssertEqual(ThumbnailAspect.update(current: nil, thumbWidth: 240, thumbHeight: 160, metadataAspect: 1.5), .keep)
        XCTAssertEqual(ThumbnailAspect.update(current: nil, thumbWidth: 240, thumbHeight: 159, metadataAspect: 1.5), .keep)
    }

    func testARotatedOrCroppedThumbnailIsRemembered() {
        XCTAssertEqual(ThumbnailAspect.update(current: nil, thumbWidth: 160, thumbHeight: 240, metadataAspect: 1.5), .set(160.0 / 240.0))
        XCTAssertEqual(ThumbnailAspect.update(current: nil, thumbWidth: 160, thumbHeight: 160, metadataAspect: 1.5), .set(1))
    }

    func testTheSameMeasurementTwiceDoesNotRepublish() {
        XCTAssertEqual(ThumbnailAspect.update(current: 1, thumbWidth: 160, thumbHeight: 160, metadataAspect: 1.5), .keep)
        XCTAssertEqual(ThumbnailAspect.update(current: 1, thumbWidth: 160, thumbHeight: 159, metadataAspect: 1.5), .keep, "within tolerance of the remembered shape")
    }

    func testAChangedEditReplacesAndARevertedEditClears() {
        XCTAssertEqual(ThumbnailAspect.update(current: 1, thumbWidth: 160, thumbHeight: 240, metadataAspect: 1.5), .set(160.0 / 240.0))
        XCTAssertEqual(ThumbnailAspect.update(current: 1, thumbWidth: 240, thumbHeight: 160, metadataAspect: 1.5), .clear)
    }

    func testWithoutAFileShapeOrSizeNothingChanges() {
        XCTAssertEqual(ThumbnailAspect.update(current: nil, thumbWidth: 160, thumbHeight: 240, metadataAspect: nil), .keep)
        XCTAssertEqual(ThumbnailAspect.update(current: nil, thumbWidth: 0, thumbHeight: 240, metadataAspect: 1.5), .keep)
        XCTAssertEqual(ThumbnailAspect.update(current: nil, thumbWidth: 160, thumbHeight: 240, metadataAspect: .nan), .keep)
    }

    func testEffectiveAspectPrefersTheMeasuredShape() {
        XCTAssertEqual(ThumbnailAspect.effective(measured: 0.5, metadata: 1.5), 0.5)
        XCTAssertEqual(ThumbnailAspect.effective(measured: nil, metadata: 1.5), 1.5)
        XCTAssertNil(ThumbnailAspect.effective(measured: nil, metadata: nil))
        XCTAssertEqual(ThumbnailAspect.effective(measured: .nan, metadata: 1.5), 1.5)
    }
}
