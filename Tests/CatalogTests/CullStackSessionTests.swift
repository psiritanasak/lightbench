import XCTest
@testable import PhotoApp

/// Stack-aware Cull (`CullSession` with stacks): the pass is over the grid's CELLS, a collapsed stack is one cell (its cover), `toggleStack`
/// opens / closes it in place, keys act on the current cell only, and counts still cover every photo of the pass.
final class CullStackSessionTests: XCTestCase {
    private func photo(_ id: Int64, flag: FlagStatus = .none, master: Int64? = nil) -> Photo {
        Photo(id: id, path: "/p/\(master ?? id).jpg", filename: "\(id).jpg", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
              flagStatus: flag, masterId: master, versionKey: master == nil ? nil : "k\(id)", versionName: master == nil ? nil : "Copy 1")
    }
    private func stack(_ id: Int64, _ members: [Int64], cover: Int64? = nil) -> StackSnapshot {
        StackSnapshot(id: id, isManual: true, coverPhotoID: cover, memberIDs: members.sorted())
    }
    private func plain(_ n: Int) -> [Photo] { (1...n).map { photo(Int64($0)) } }

    // MARK: Cells

    func testACollapsedStackIsOneCellShowingItsCover() throws {
        let s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, stacks: [stack(10, [2, 3, 4], cover: 3)]))
        XCTAssertEqual(s.ids, [1, 3, 5, 6])
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.passIDs, [1, 2, 3, 4, 5, 6], "the pass still holds every photo")
        XCTAssertEqual(s.stackMembers[10], [2, 3, 4])
    }

    func testNoStacksBehavesExactlyAsBefore() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(4), onlyUnflagged: false))
        XCTAssertEqual(s.ids, [1, 2, 3, 4])
        XCTAssertEqual(s.positionText, "1 of 4")
        XCTAssertNil(s.stackInfo(for: 1))
        XCTAssertEqual(s.toggleStack(), .notInStack)
    }

    func testUnflaggedIsAppliedBeforeStacking() throws {
        // 3 is the stack cover but flagged: only 2 and 4 remain visible, the cell shows the first visible member.
        let list = [photo(1), photo(2), photo(3, flag: .picked), photo(4), photo(5)]
        let s = try XCTUnwrap(CullSession(photos: list, onlyUnflagged: true, stacks: [stack(10, [2, 3, 4], cover: 3)]))
        XCTAssertEqual(s.ids, [1, 2, 5])
        XCTAssertEqual(s.stackMembers[10], [2, 4])
        XCTAssertEqual(s.passIDs, [1, 2, 4, 5])
    }

    func testAStackWithOneVisibleMemberAfterFilteringIsPlain() throws {
        let list = [photo(1), photo(2, flag: .picked), photo(3)]
        let s = try XCTUnwrap(CullSession(photos: list, onlyUnflagged: true, stacks: [stack(10, [1, 2])]))
        XCTAssertEqual(s.ids, [1, 3])
        XCTAssertNil(s.stackInfo(for: 1))
    }

    func testAnExpandedStackInTheGridStartsExpandedInThePass() throws {
        let s = try XCTUnwrap(CullSession(photos: plain(5), onlyUnflagged: false, stacks: [stack(10, [2, 3])], expandedStackIDs: [10]))
        XCTAssertEqual(s.ids, [1, 2, 3, 4, 5])
        XCTAssertEqual(s.expandedInPass, [10])
    }

    // MARK: toggleStack

    func testToggleExpandsInPlaceAndStaysOnTheCover() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, startingAt: 3, stacks: [stack(10, [2, 3, 4], cover: 3)]))
        XCTAssertEqual(s.currentID, 3)
        XCTAssertEqual(s.toggleStack(), .expanded)
        XCTAssertEqual(s.ids, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(s.currentID, 3)
        XCTAssertEqual(s.expandedInPass, [10])
        XCTAssertEqual(s.stackInfo(for: 3)?.isExpanded, true)
        XCTAssertEqual(s.stackInfo(for: 3)?.position, 2)
    }

    func testCollapsingFromAMemberReturnsToTheCover() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, startingAt: 3, stacks: [stack(10, [2, 3, 4], cover: 3)]))
        s.toggleStack()
        XCTAssertTrue(s.jump(toID: 4))
        XCTAssertEqual(s.toggleStack(), .collapsed)
        XCTAssertEqual(s.ids, [1, 3, 5, 6])
        XCTAssertEqual(s.currentID, 3, "collapse lands on the cover")
        XCTAssertEqual(s.expandedInPass, [])
    }

    func testExpandThenCollapseRestoresTheOriginalCells() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(7), onlyUnflagged: false, startingAt: 4,
                                          stacks: [stack(10, [3, 4, 5], cover: 4), stack(11, [6, 7])]))
        let before = s.ids
        s.toggleStack(); s.toggleStack()
        XCTAssertEqual(s.ids, before)
        XCTAssertEqual(s.currentID, 4)
    }

    func testTogglingOneStackLeavesOthersAlone() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, stacks: [stack(10, [1, 2]), stack(11, [4, 5])]))
        XCTAssertEqual(s.ids, [1, 3, 4, 6])
        s.toggleStack()
        XCTAssertEqual(s.ids, [1, 2, 3, 4, 6])
        XCTAssertEqual(s.expandedInPass, [10])
    }

    func testToggleOnAPlainPhotoSaysNotInStackAndChangesNothing() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(4), onlyUnflagged: false, stacks: [stack(10, [2, 3])]))
        let before = s
        XCTAssertEqual(s.toggleStack(), .notInStack)
        XCTAssertEqual(s, before)
    }

    func testToggleIsRefusedInCompareAndSurvey() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, stacks: [stack(10, [1, 2])]))
        XCTAssertTrue(s.enterCompare())
        var before = s
        XCTAssertEqual(s.toggleStack(), .notLoupe)
        XCTAssertEqual(s, before)
        s.enterLoupe()
        XCTAssertTrue(s.enterSurvey())
        before = s
        XCTAssertEqual(s.toggleStack(), .notLoupe)
        XCTAssertEqual(s, before)
    }

    // MARK: Start photo

    func testAHiddenStartPhotoExpandsItsStack() throws {
        let s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, startingAt: 3, stacks: [stack(10, [2, 3, 4], cover: 2)]))
        XCTAssertEqual(s.currentID, 3)
        XCTAssertEqual(s.expandedInPass, [10])
        XCTAssertEqual(s.ids, [1, 2, 3, 4, 5, 6])
    }

    func testAStartPhotoThatIsACellDoesNotExpandAnything() throws {
        let s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, startingAt: 2, stacks: [stack(10, [2, 3, 4], cover: 2)]))
        XCTAssertEqual(s.expandedInPass, [])
        XCTAssertEqual(s.ids, [1, 2, 5, 6])
    }

    // MARK: Navigation, keys, text

    func testNavigationSkipsHiddenMembersAndPositionCountsCells() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, stacks: [stack(10, [2, 3, 4], cover: 2)]))
        XCTAssertEqual(s.positionText, "1 of 4")
        s.next()
        XCTAssertEqual(s.currentID, 2)
        XCTAssertEqual(s.positionText, "2 of 4 · Stack of 3 (S expands)")
        s.next()
        XCTAssertEqual(s.currentID, 5)
        XCTAssertEqual(s.neighborIDs(radius: 1), [6, 2])
    }

    func testPositionTextOfAnExpandedMember() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, startingAt: 2, stacks: [stack(10, [2, 3, 4], cover: 2)]))
        s.toggleStack()
        s.next()
        XCTAssertEqual(s.currentID, 3)
        XCTAssertEqual(s.positionText, "3 of 6 · Stack 2 of 3 (S collapses)")
    }

    func testStackBadgeText() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(5), onlyUnflagged: false, startingAt: 2, stacks: [stack(10, [2, 3, 4], cover: 2)]))
        XCTAssertEqual(s.stackBadgeText(for: 2), "Stack of 3")
        XCTAssertNil(s.stackBadgeText(for: 1))
        s.toggleStack()
        XCTAssertEqual(s.stackBadgeText(for: 3), "Stack 2 of 3")
    }

    func testFlagKeysActOnTheCoverOnlyAndReportTheOthersUnchanged() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, startingAt: 2, stacks: [stack(10, [2, 3, 4], cover: 2)]))
        XCTAssertEqual(s.hiddenMemberCount(of: 2), 2)
        let change = try XCTUnwrap(s.apply(.flag(.picked), to: photo(2)))
        XCTAssertEqual(change.photoID, 2)
        XCTAssertEqual(change.flag, .picked)
        XCTAssertEqual(s.currentID, 5, "auto-advance skips the hidden members")
        XCTAssertEqual(s.hiddenMemberCount(of: 5), 0)
    }

    func testAnExpandedMemberHasNoHiddenOthers() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, startingAt: 2, stacks: [stack(10, [2, 3, 4], cover: 2)]))
        s.toggleStack()
        XCTAssertEqual(s.hiddenMemberCount(of: 2), 0)
    }

    // MARK: Counts and undo

    func testCountsCoverEveryPhotoOfThePassIncludingHiddenMembers() throws {
        let list = [photo(1), photo(2), photo(3, flag: .picked), photo(4), photo(5, flag: .rejected)]
        let s = try XCTUnwrap(CullSession(photos: list, onlyUnflagged: false, stacks: [stack(10, [2, 3, 4, 5], cover: 2)]))
        XCTAssertEqual(s.ids, [1, 2])
        let rows = Dictionary(uniqueKeysWithValues: list.map { ($0.id!, $0) })
        XCTAssertEqual(s.counts(rows: rows), CullSession.Counts(picked: 1, rejected: 1, unflagged: 3))
    }

    /// The bug the review found: flag member B of an opened stack, collapse, undo. The undone photo must be the one on screen.
    func testUndoOfAHiddenMembersFlagOpensItsStackAndShowsThatPhoto() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, startingAt: 2, stacks: [stack(10, [2, 3, 4], cover: 2)]))
        s.toggleStack()
        XCTAssertTrue(s.jump(toID: 3))
        s.autoAdvance = false
        XCTAssertNotNil(s.apply(.flag(.picked), to: photo(3)))
        XCTAssertEqual(s.toggleStack(), .collapsed)
        XCTAssertEqual(s.currentID, 2)
        let action = try XCTUnwrap(s.undo())
        XCTAssertEqual(action.photoID, 3)
        XCTAssertEqual(s.currentID, 3, "the photo whose flag is being restored is current")
        XCTAssertEqual(s.expandedInPass, [10], "its stack was opened in the pass")
        XCTAssertTrue(s.ids.contains(3))
        XCTAssertEqual(s.stackInfo(for: 3)?.isExpanded, true)
    }

    func testUndoAfterCollapseToleratesAMissingCellAndOpensTheStack() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, startingAt: 3, stacks: [stack(10, [2, 3, 4], cover: 2)]))
        XCTAssertNotNil(s.apply(.flag(.picked), to: photo(3))) // 3 is expanded (hidden start), flagged, auto-advanced to member 4
        XCTAssertEqual(s.currentID, 4)
        XCTAssertEqual(s.toggleStack(), .collapsed) // current becomes the cover 2; 3 is no longer a cell
        XCTAssertEqual(s.currentID, 2)
        XCTAssertFalse(s.ids.contains(3))
        s.next() // somewhere else, so undo has to travel
        XCTAssertEqual(s.currentID, 5)
        let action = try XCTUnwrap(s.undo())
        XCTAssertEqual(action.photoID, 3)
        XCTAssertEqual(s.currentID, 3, "undo shows the photo it changed, opening its stack")
    }

    func testRebuildCarriesExpansionAndUsesFreshStacks() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, startingAt: 3, stacks: [stack(10, [2, 3], cover: 2)]))
        XCTAssertEqual(s.ids, [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(s.rebuild(photos: plain(6), onlyUnflagged: false, stacks: [stack(10, [2, 3], cover: 2)]))
        XCTAssertEqual(s.ids, [1, 2, 3, 4, 5, 6], "still expanded")
        XCTAssertEqual(s.currentID, 3)
        XCTAssertTrue(s.rebuild(photos: plain(6), onlyUnflagged: false, stacks: []))
        XCTAssertEqual(s.ids, [1, 2, 3, 4, 5, 6])
        XCTAssertNil(s.stackInfo(for: 2))
    }

    func testRebuildKeepsAStackOpenedWithSEvenOnACell() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, startingAt: 2, stacks: [stack(10, [2, 3], cover: 2)]))
        XCTAssertEqual(s.toggleStack(), .expanded)
        XCTAssertEqual(s.currentID, 2, "on a cell, not a hidden member")
        XCTAssertTrue(s.rebuild(photos: plain(6), onlyUnflagged: false, stacks: [stack(10, [2, 3], cover: 2)]))
        XCTAssertEqual(s.ids, [1, 2, 3, 4, 5, 6], "the stack opened in this pass stays open")
    }

    func testRebuildKeepsACollapsedStackCollapsed() throws {
        var s = try XCTUnwrap(CullSession(photos: plain(6), onlyUnflagged: false, startingAt: 2, stacks: [stack(10, [2, 3], cover: 2)]))
        XCTAssertTrue(s.rebuild(photos: plain(6), onlyUnflagged: false, stacks: [stack(10, [2, 3], cover: 2)]))
        XCTAssertEqual(s.ids, [1, 2, 4, 5, 6])
    }

    func testAVirtualCopyTravelsWithItsMastersStack() throws {
        let list = [photo(1), photo(2), photo(7, master: 2), photo(3)]
        let s = try XCTUnwrap(CullSession(photos: list, onlyUnflagged: false, stacks: [stack(10, [1, 2])]))
        XCTAssertEqual(s.ids, [1, 3])
        XCTAssertEqual(s.stackMembers[10], [1, 2, 7])
    }
}
