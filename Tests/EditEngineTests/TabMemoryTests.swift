import XCTest
@testable import PhotoApp

final class TabMemoryTests: XCTestCase {
    private let a = UUID(), b = UUID()

    func testScrollOffsetsAreRememberedPerTabAndDefaultToTop() {
        var m = TabMemory()
        XCTAssertEqual(m.scrollOffset(for: .adjust), 0)
        m.recordScroll(420, for: .adjust)
        m.recordScroll(90, for: .looks)
        XCTAssertEqual(m.scrollOffset(for: .adjust), 420)
        XCTAssertEqual(m.scrollOffset(for: .looks), 90)
        XCTAssertEqual(m.scrollOffset(for: .masks), 0)
    }

    func testOverscrollIsStoredAsZeroAndNonFiniteIsIgnored() {
        var m = TabMemory()
        m.recordScroll(300, for: .adjust)
        m.recordScroll(-25, for: .adjust)
        XCTAssertEqual(m.scrollOffset(for: .adjust), 0)
        m.recordScroll(300, for: .adjust)
        m.recordScroll(.nan, for: .adjust)
        m.recordScroll(.infinity, for: .adjust)
        XCTAssertEqual(m.scrollOffset(for: .adjust), 300)
    }

    func testOnlyTheOwnerTabWritesItsSelection() {
        var m = TabMemory()
        m.stash(leaving: .retouch, retouchSpotID: a, pointColorID: b)   // a Point Color id offered by a non-owner is ignored
        XCTAssertEqual(m.retouchSpotID, a)
        XCTAssertNil(m.pointColorID)
        m.stash(leaving: .adjust, retouchSpotID: nil, pointColorID: b)  // leaving Adjust must not wipe the retouch entry
        XCTAssertEqual(m.retouchSpotID, a)
        XCTAssertEqual(m.pointColorID, b)
        // Passing through tabs that own neither changes nothing.
        for tab in [EditorTab.looks, .masks, .redEye, .crop] { m.stash(leaving: tab, retouchSpotID: nil, pointColorID: nil) }
        XCTAssertEqual(m.retouchSpotID, a)
        XCTAssertEqual(m.pointColorID, b)
    }

    func testDeselectingOnTheOwnerTabForgetsTheSelection() {
        var m = TabMemory()
        m.stash(leaving: .retouch, retouchSpotID: a, pointColorID: nil)
        m.stash(leaving: .retouch, retouchSpotID: nil, pointColorID: nil)
        XCTAssertNil(m.retouchSpotID)
    }

    func testARetouchSpotIsRestoredOnlyWhenItExistsCompareIsOffAndGeometryIsIdentity() {
        var m = TabMemory()
        m.stash(leaving: .retouch, retouchSpotID: a, pointColorID: nil)
        XCTAssertEqual(m.restoredRetouchSpotID(existing: [a, b], compareIsOff: true, geometryAtIdentity: true), a)
        XCTAssertNil(m.restoredRetouchSpotID(existing: [b], compareIsOff: true, geometryAtIdentity: true), "the spot was deleted meanwhile")
        XCTAssertNil(m.restoredRetouchSpotID(existing: [a], compareIsOff: false, geometryAtIdentity: true), "Compare on: no circles are drawn")
        XCTAssertNil(m.restoredRetouchSpotID(existing: [a], compareIsOff: true, geometryAtIdentity: false), "cropped: spots are not editable")
        XCTAssertNil(TabMemory().restoredRetouchSpotID(existing: [a], compareIsOff: true, geometryAtIdentity: true))
    }

    func testAPointColorIsRestoredOnlyWhenItStillExists() {
        var m = TabMemory()
        m.stash(leaving: .adjust, retouchSpotID: nil, pointColorID: b)
        XCTAssertEqual(m.restoredPointColorID(existing: [a, b]), b)
        XCTAssertNil(m.restoredPointColorID(existing: [a]))
    }

    func testAnotherPhotoForgetsEverything() {
        var m = TabMemory()
        m.recordScroll(200, for: .adjust)
        m.stash(leaving: .retouch, retouchSpotID: a, pointColorID: nil)
        m.stash(leaving: .adjust, retouchSpotID: nil, pointColorID: b)
        m.reset()
        XCTAssertEqual(m, TabMemory())
    }

    /// The mask selection is never remembered: `TabMemory` has no mask entry, and Masks / Looks / Crop stay clearing it.
    func testTheMaskSelectionStaysClearedOnEveryOtherTab() {
        for tab in EditorTab.allCases where tab != .masks {
            XCTAssertTrue(tab.switchEffects(armed: .none).clearsMaskSelection, tab.label)
        }
    }

    /// Live-measured bug: replaying the raw `contentOffset.y` came back one top inset (the 52 pt title bar) too high.
    func testScrollDistanceAddsTheTopInsetToTheGeometryOffset() {
        XCTAssertEqual(TabMemory.scrollDistance(contentOffsetY: -52, topInset: 52), 0, "at rest the geometry offset is -inset")
        XCTAssertEqual(TabMemory.scrollDistance(contentOffsetY: 300, topInset: 52), 352)
        XCTAssertEqual(TabMemory.scrollDistance(contentOffsetY: 120, topInset: 0), 120, "no inset: unchanged")
        XCTAssertEqual(TabMemory.scrollDistance(contentOffsetY: -80, topInset: 52), 0, "overscroll bounce clamps to the top")
        XCTAssertEqual(TabMemory.scrollDistance(contentOffsetY: .nan, topInset: 52), 0)
    }
}

