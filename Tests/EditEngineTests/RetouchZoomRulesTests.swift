import XCTest
@testable import PhotoApp

final class RetouchZoomRulesTests: XCTestCase {
    typealias R = RetouchZoomRules

    func testTheToolIsActiveWhenArmedOrASpotIsSelectedInTheOpenSectionOutsideCropAtIdentityGeometry() {
        func active(section: Bool = true, crop: Bool = false, identity: Bool = true, armed: Bool = false, selected: Bool = false) -> Bool {
            R.isToolActive(sectionExpanded: section, isCropping: crop, geometryAtIdentity: identity, isArmed: armed, hasSelectedSpot: selected)
        }
        XCTAssertTrue(active(armed: true))
        XCTAssertTrue(active(selected: true))
        XCTAssertFalse(active())
        XCTAssertFalse(active(section: false, armed: true, selected: true))
        XCTAssertFalse(active(crop: true, armed: true, selected: true))
        XCTAssertFalse(active(identity: false, armed: true, selected: true),
                       "armed through an Undo that restored non-identity geometry: the layer is hidden, so a plain drag must pan")
    }

    func testSpaceIsTheHandToolOnlyWhileTheToolIsActive() {
        XCTAssertTrue(R.spaceIsHandTool(toolActive: true))
        XCTAssertFalse(R.spaceIsHandTool(toolActive: false))
    }

    func testAHeldSpaceCannotOutliveTheToolOrKeyboardFocus() {
        XCTAssertTrue(R.spaceHeldAfterChange(spaceHeld: true, toolActive: true, paneFocused: true))
        XCTAssertFalse(R.spaceHeldAfterChange(spaceHeld: true, toolActive: false, paneFocused: true), "tool ended: key-up may never arrive")
        XCTAssertFalse(R.spaceHeldAfterChange(spaceHeld: true, toolActive: true, paneFocused: false), "focus moved away")
        XCTAssertFalse(R.spaceHeldAfterChange(spaceHeld: false, toolActive: true, paneFocused: true), "never turns itself on")
    }

    func testThePanLayerNeverStealsDragsFromTheToolUnlessSpaceIsHeld() {
        // Tool inactive: the old rule (zoomed, not Split, canZoom).
        XCTAssertTrue(R.mountsPanLayer(canZoom: true, zoomScale: 2, compareIsSplit: false, toolActive: false, spaceHeld: false))
        XCTAssertFalse(R.mountsPanLayer(canZoom: true, zoomScale: 1, compareIsSplit: false, toolActive: false, spaceHeld: false), "not zoomed")
        XCTAssertFalse(R.mountsPanLayer(canZoom: true, zoomScale: 2, compareIsSplit: true, toolActive: false, spaceHeld: false), "Split owns drags")
        XCTAssertFalse(R.mountsPanLayer(canZoom: false, zoomScale: 2, compareIsSplit: false, toolActive: false, spaceHeld: false))
        // Tool active: only with Space held.
        XCTAssertFalse(R.mountsPanLayer(canZoom: true, zoomScale: 2, compareIsSplit: false, toolActive: true, spaceHeld: false))
        XCTAssertTrue(R.mountsPanLayer(canZoom: true, zoomScale: 2, compareIsSplit: false, toolActive: true, spaceHeld: true))
        XCTAssertFalse(R.mountsPanLayer(canZoom: true, zoomScale: 1, compareIsSplit: false, toolActive: true, spaceHeld: true), "nothing to pan at fit size")
    }
}
