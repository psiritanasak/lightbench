import XCTest
@testable import PhotoApp

final class AdjustSectionExpansionTests: XCTestCase {
    func testNeverStoredOpensLightAndColor() {
        XCTAssertEqual(AdjustSectionExpansion(stored: nil).open, [.light, .color])
        XCTAssertEqual(AdjustSectionExpansion().open, [.light, .color])
    }

    func testEmptyStoredMeansAllClosed() {
        XCTAssertEqual(AdjustSectionExpansion(stored: []).open, [])
    }

    func testUnknownNamesAreDropped() {
        XCTAssertEqual(AdjustSectionExpansion(stored: ["curve", "bogus"]).open, [.curve])
    }

    func testStoredIsInAllCasesOrderAndRoundTrips() {
        let sections = AdjustSectionExpansion(open: [.raw, .light, .effects, .curve])
        let expected = AdjustSection.allCases.filter { sections.isOpen($0) }.map(\.rawValue)
        XCTAssertEqual(sections.stored, expected)
        XCTAssertEqual(sections.stored, ["light", "curve", "effects", "raw"])
        XCTAssertEqual(AdjustSectionExpansion(stored: sections.stored), sections)
        XCTAssertEqual(AdjustSectionExpansion(stored: AdjustSectionExpansion(open: []).stored).open, [])
    }

    func testSetOpensAndCloses() {
        var sections = AdjustSectionExpansion(open: [])
        sections.set(.effects, open: true)
        XCTAssertTrue(sections.isOpen(.effects))
        sections.set(.effects, open: true)
        XCTAssertEqual(sections.open, [.effects])
        sections.set(.effects, open: false)
        XCTAssertFalse(sections.isOpen(.effects))
    }

    func testSoloLeavesExactlyThatSection() {
        var all = AdjustSectionExpansion(open: Set(AdjustSection.allCases))
        all.solo(.curve)
        XCTAssertEqual(all.open, [.curve])
        var none = AdjustSectionExpansion(open: [])
        none.solo(.effects)
        XCTAssertEqual(none.open, [.effects])
        none.solo(.effects)
        XCTAssertEqual(none.open, [.effects], "idempotent: never toggles")
    }

    func testSoloClosesRawEvenWhenItIsNotShown() {
        var sections = AdjustSectionExpansion(open: [.raw, .light])
        sections.solo(.light)
        XCTAssertFalse(sections.isOpen(.raw))
    }

    // MARK: AdjustPanelState.applyExpansion

    func testClosingPointColorClearsItsSelectionAndReportsIt() {
        var panel = AdjustPanelState(editSections: AdjustSectionExpansion(open: [.pointColor, .effects]))
        panel.selectedPointColorID = UUID()
        var next = panel.editSections
        next.solo(.light)
        XCTAssertTrue(panel.applyExpansion(next))
        XCTAssertNil(panel.selectedPointColorID)
        XCTAssertEqual(panel.editSections.open, [.light])
    }

    func testClosingOtherSectionKeepsPointColorSelection() {
        var panel = AdjustPanelState(editSections: AdjustSectionExpansion(open: [.light]))
        let id = UUID()
        panel.selectedPointColorID = id
        var next = panel.editSections
        next.set(.light, open: false)
        XCTAssertFalse(panel.applyExpansion(next))
        XCTAssertEqual(panel.selectedPointColorID, id)
    }

    func testOpeningPointColorReportsNothingToDisarm() {
        var panel = AdjustPanelState(editSections: AdjustSectionExpansion(open: []))
        var next = panel.editSections
        next.set(.pointColor, open: true)
        XCTAssertFalse(panel.applyExpansion(next))
        XCTAssertTrue(panel.editSections.isOpen(.pointColor))
    }
}
