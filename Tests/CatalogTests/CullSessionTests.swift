import XCTest
@testable import PhotoApp

final class CullSessionTests: XCTestCase {
    private func photo(_ id: Int64, rating: Int = 0, flag: FlagStatus = .none, label: ColorLabel = .none) -> Photo {
        Photo(id: id, path: "/p/\(id).jpg", filename: "\(id).jpg", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
              rating: rating, flagStatus: flag, colorLabel: label)
    }
    private func photos(_ n: Int) -> [Photo] { (1...n).map { photo(Int64($0)) } }

    // MARK: Snapshot

    func testAnEmptyListMakesNoSession() {
        XCTAssertNil(CullSession(photos: [], onlyUnflagged: false))
        XCTAssertNil(CullSession(photos: [photo(1, flag: .picked)], onlyUnflagged: true), "nothing unflagged left")
    }

    func testOnlyUnflaggedKeepsJustUnflaggedPhotosInOrder() throws {
        let list = [photo(1), photo(2, flag: .picked), photo(3), photo(4, flag: .rejected), photo(5)]
        let s = try XCTUnwrap(CullSession(photos: list, onlyUnflagged: true))
        XCTAssertEqual(s.ids, [1, 3, 5])
        XCTAssertEqual(try XCTUnwrap(CullSession(photos: list, onlyUnflagged: false)).ids, [1, 2, 3, 4, 5])
    }

    func testStartingAtAPhotoInTheListAndFallingBackToTheFirst() throws {
        let list = photos(5)
        XCTAssertEqual(try XCTUnwrap(CullSession(photos: list, onlyUnflagged: false, startingAt: 4)).currentID, 4)
        XCTAssertEqual(try XCTUnwrap(CullSession(photos: list, onlyUnflagged: false, startingAt: 99)).currentID, 1)
        let flagged = [photo(1), photo(2, flag: .picked)]
        XCTAssertEqual(try XCTUnwrap(CullSession(photos: flagged, onlyUnflagged: true, startingAt: 2)).currentID, 1, "start not in the unflagged list")
    }

    // MARK: Navigation

    func testNavigationIsClampedAndReportsWhetherItMoved() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(3), onlyUnflagged: false))
        XCTAssertFalse(s.previous())
        XCTAssertTrue(s.next()); XCTAssertTrue(s.next())
        XCTAssertFalse(s.next(), "no wrap past the end")
        XCTAssertEqual(s.currentID, 3)
        XCTAssertTrue(s.isAtEnd)
        XCTAssertEqual(s.positionText, "3 of 3")
        XCTAssertTrue(s.jump(toID: 1)); XCTAssertEqual(s.positionText, "1 of 3")
        XCTAssertFalse(s.jump(toID: 42))
    }

    func testNeighborIDsAreNearestFirstNextBeforePreviousAndStayInRange() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(10), onlyUnflagged: false))
        s.jump(toID: 5)
        XCTAssertEqual(s.neighborIDs(radius: 2), [6, 4, 7, 3])
        s.jump(toID: 1)
        XCTAssertEqual(s.neighborIDs(radius: 2), [2, 3])
        s.jump(toID: 10)
        XCTAssertEqual(s.neighborIDs(radius: 2), [9, 8])
        XCTAssertEqual(s.neighborIDs(radius: 0), [])
    }

    // MARK: Snapshot stability

    /// The survey's key risk: flagging a photo in the Unflagged list must not change the list, so next / previous keep working.
    func testFlaggingDoesNotChangeTheSnapshot() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(4), onlyUnflagged: true))
        let before = s.ids
        XCTAssertNotNil(s.apply(.flag(.picked), to: photo(1)))
        XCTAssertEqual(s.ids, before)
        XCTAssertTrue(s.previous(), "can go back to the photo just flagged")
        XCTAssertEqual(s.currentID, 1)
    }

    // MARK: Auto-advance

    func testFlagCommandsAdvanceWhenAutoAdvanceIsOn() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(3), onlyUnflagged: false))
        let c = try XCTUnwrap(s.apply(.flag(.picked), to: photo(1)))
        XCTAssertEqual(c.flag, .picked)
        XCTAssertTrue(c.advanced)
        XCTAssertEqual(s.currentID, 2)
    }

    func testRatingAndLabelNeverAdvance() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(3), onlyUnflagged: false))
        XCTAssertEqual(s.apply(.rating(4), to: photo(1))?.rating, 4)
        XCTAssertEqual(s.currentID, 1)
        XCTAssertEqual(s.apply(.label(.red), to: photo(1))?.label, .red)
        XCTAssertEqual(s.currentID, 1)
    }

    func testAutoAdvanceOffStaysPut() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(3), onlyUnflagged: false))
        s.autoAdvance = false
        let c = try XCTUnwrap(s.apply(.flag(.rejected), to: photo(1)))
        XCTAssertEqual(c.flag, .rejected)
        XCTAssertFalse(c.advanced)
        XCTAssertEqual(s.currentID, 1)
    }

    func testAtTheEndAFlagStaysPutAndDoesNotAdvance() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(2), onlyUnflagged: false, startingAt: 2))
        let c = try XCTUnwrap(s.apply(.flag(.picked), to: photo(2)))
        XCTAssertFalse(c.advanced)
        XCTAssertEqual(s.currentID, 2)
        XCTAssertTrue(s.isAtEnd)
    }

    func testAnUnchangedFlagStillAdvancesButRecordsNoUndo() throws {
        var s = try XCTUnwrap(CullSession(photos: [photo(1, flag: .picked), photo(2)], onlyUnflagged: false))
        let c = try XCTUnwrap(s.apply(.flag(.picked), to: photo(1, flag: .picked)))
        XCTAssertNil(c.flag, "already picked: nothing to write")
        XCTAssertTrue(c.advanced, "the user decided this photo")
        XCTAssertFalse(s.canUndo)
    }

    func testTheToggleKeyUsesTheCurrentFlag() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(3), onlyUnflagged: false))
        s.autoAdvance = false
        XCTAssertEqual(s.apply(.flag(nil), to: photo(1))?.flag, .picked)
        XCTAssertEqual(s.apply(.flag(nil), to: photo(1, flag: .picked))?.flag, FlagStatus.none)
        XCTAssertEqual(s.apply(.flag(nil), to: photo(1, flag: .rejected))?.flag, FlagStatus.none)
    }

    func testACommandForAPhotoThatIsNotCurrentIsRefused() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(3), onlyUnflagged: false))
        XCTAssertNil(s.apply(.flag(.picked), to: photo(2)))
        XCTAssertEqual(s.currentID, 1)
        XCTAssertFalse(s.canUndo)
    }

    // MARK: Undo

    func testUndoRestoresThePreviousValuesAndReturnsToThePhoto() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(4), onlyUnflagged: false))
        _ = s.apply(.rating(3), to: photo(1))
        _ = s.apply(.flag(.picked), to: photo(1, rating: 3))   // advances to 2
        XCTAssertEqual(s.currentID, 2)
        let undone = try XCTUnwrap(s.undo())
        XCTAssertEqual(undone.photoID, 1)
        XCTAssertEqual(undone.previousFlag, FlagStatus.none)
        XCTAssertNil(undone.previousRating, "undoing the flag must not touch the rating set before it")
        XCTAssertEqual(s.currentID, 1, "back on the photo the action was for")
        let older = try XCTUnwrap(s.undo())
        XCTAssertEqual(older.previousRating, 0)
        XCTAssertNil(older.previousFlag)
        XCTAssertNil(s.undo())
        XCTAssertFalse(s.canUndo)
    }

    func testTheUndoStackIsCapped() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(2), onlyUnflagged: false))
        s.autoAdvance = false
        for i in 0..<(CullSession.undoLimit + 10) { _ = s.apply(.rating(i % 2 == 0 ? 1 : 2), to: photo(1, rating: i % 2 == 0 ? 0 : 1)) }
        XCTAssertEqual(s.undoStack.count, CullSession.undoLimit)
    }

    // MARK: Progress + rebuild

    func testCountsComeFromTheLiveRowsAndSkipMissingOnes() throws {
        let s = try XCTUnwrap(CullSession(photos: photos(4), onlyUnflagged: false))
        let rows: [Int64: Photo] = [1: photo(1, flag: .picked), 2: photo(2, flag: .rejected), 3: photo(3)]   // 4 was removed
        XCTAssertEqual(s.counts(rows: rows), CullSession.Counts(picked: 1, rejected: 1, unflagged: 1))
    }

    func testRebuildKeepsTheCurrentPhotoAutoAdvanceAndUndo() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(4), onlyUnflagged: false))
        s.autoAdvance = false
        _ = s.apply(.rating(5), to: photo(1))
        s.jump(toID: 3)
        let list = [photo(1), photo(2, flag: .picked), photo(3), photo(4)]
        XCTAssertTrue(s.rebuild(photos: list, onlyUnflagged: true))
        XCTAssertEqual(s.ids, [1, 3, 4])
        XCTAssertEqual(s.currentID, 3)
        XCTAssertFalse(s.autoAdvance)
        XCTAssertTrue(s.canUndo)
        XCTAssertFalse(s.rebuild(photos: [photo(1, flag: .picked)], onlyUnflagged: true), "an empty list leaves the session unchanged")
        XCTAssertEqual(s.ids, [1, 3, 4])
    }

    /// `apply` has already moved on when it returns, so the change names the photo it belongs to.
    func testTheChangeNamesThePhotoEvenAfterAutoAdvance() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(3), onlyUnflagged: false))
        let c = try XCTUnwrap(s.apply(.flag(.picked), to: photo(1)))
        XCTAssertEqual(c.photoID, 1)
        XCTAssertEqual(s.currentID, 2)
    }

    func testUndoRecordsOnlyTheFieldsThatChanged() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(2), onlyUnflagged: false))
        s.autoAdvance = false
        _ = s.apply(.label(.red), to: photo(1, rating: 4))
        let a = try XCTUnwrap(s.undo())
        XCTAssertEqual(a.previousLabel, ColorLabel.none)
        XCTAssertNil(a.previousRating)
        XCTAssertNil(a.previousFlag)
    }

    /// After an Unflagged-only rebuild the flagged photo is gone: undo still returns the action, but the position must not jump
    /// to some unrelated photo.
    func testUndoAfterARebuildThatDroppedThePhotoLeavesThePositionAlone() throws {
        var s = try XCTUnwrap(CullSession(photos: photos(4), onlyUnflagged: false))
        s.autoAdvance = false
        _ = s.apply(.flag(.picked), to: photo(1))
        s.jump(toID: 3)
        XCTAssertTrue(s.rebuild(photos: [photo(1, flag: .picked), photo(2), photo(3), photo(4)], onlyUnflagged: true))
        XCTAssertEqual(s.ids, [2, 3, 4])
        let undone = try XCTUnwrap(s.undo())
        XCTAssertEqual(undone.photoID, 1, "the action is for the photo that left the list")
        XCTAssertEqual(s.currentID, 3, "the position did not move")
    }
}

