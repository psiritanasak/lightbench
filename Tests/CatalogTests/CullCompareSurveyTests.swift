import XCTest
@testable import PhotoApp

/// Compare and Survey in the pure session: which photos are visible, how the arrows step, and that photo keys still act only on `currentID`.
final class CullCompareSurveyTests: XCTestCase {
    private func photo(_ id: Int64, flag: FlagStatus = .none, rating: Int = 0) -> Photo {
        Photo(id: id, path: "/p/\(id).jpg", filename: "\(id).jpg", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
              rating: rating, flagStatus: flag, colorLabel: .none)
    }
    private func session(_ n: Int, at start: Int64? = nil) throws -> CullSession {
        try XCTUnwrap(CullSession(photos: (1...n).map { photo(Int64($0)) }, onlyUnflagged: false, startingAt: start))
    }

    // MARK: Compare

    func testEnteringCompareMakesTheCurrentPhotoTheSelectAndTheNextOneTheCandidate() throws {
        var s = try session(5, at: 2)
        XCTAssertTrue(s.enterCompare())
        XCTAssertEqual(s.mode, .compare)
        XCTAssertEqual(s.selectID, 2)
        XCTAssertEqual(s.currentID, 3)
        XCTAssertEqual(s.visibleIDs, [2, 3])
        XCTAssertEqual(s.positionText, "Candidate 3 of 5")
    }

    func testCompareAtTheEndOfTheListUsesThePreviousPhotoAndANeedsTwoPhotos() throws {
        var s = try session(4, at: 4)
        XCTAssertTrue(s.enterCompare())
        XCTAssertEqual(s.selectID, 4)
        XCTAssertEqual(s.currentID, 3)
        var single = try session(1)
        XCTAssertFalse(single.enterCompare())
        XCTAssertEqual(single.mode, .loupe)
        XCTAssertFalse(single.enterSurvey())
    }

    func testTheCandidateStepsSkipTheSelectAndStopAtTheEdges() throws {
        var s = try session(5, at: 2)
        s.enterCompare()                      // select 2, candidate 3
        XCTAssertTrue(s.previous())           // 1 (2 is the select)
        XCTAssertEqual(s.currentID, 1)
        XCTAssertFalse(s.previous())
        XCTAssertTrue(s.next())               // skips the select: 3
        XCTAssertEqual(s.currentID, 3)
        XCTAssertTrue(s.next()); XCTAssertTrue(s.next())
        XCTAssertEqual(s.currentID, 5)
        XCTAssertFalse(s.next())
        XCTAssertTrue(s.isAtEnd)
    }

    func testSwapExchangesSelectAndCandidateAndMakeSelectPromotesTheCandidate() throws {
        var s = try session(5, at: 2)
        s.enterCompare()                      // select 2, candidate 3
        XCTAssertTrue(s.swapCompare())
        XCTAssertEqual(s.selectID, 3)
        XCTAssertEqual(s.currentID, 2)
        XCTAssertTrue(s.swapCompare())
        XCTAssertEqual([s.selectID, s.currentID], [2, 3])
        XCTAssertTrue(s.makeSelect())         // 3 becomes the select; the candidate moves on to 4
        XCTAssertEqual([s.selectID, s.currentID], [3, 4])
        var loupe = try session(3)
        XCTAssertFalse(loupe.swapCompare())
        XCTAssertFalse(loupe.makeSelect())
    }

    func testMakeSelectWithOnlyTwoPhotosBehavesLikeSwap() throws {
        var s = try session(2, at: 1)
        s.enterCompare()                      // select 1, candidate 2
        XCTAssertTrue(s.makeSelect())
        XCTAssertEqual([s.selectID, s.currentID], [2, 1])
    }

    func testPhotoKeysActOnTheCandidateNeverTheSelect() throws {
        var s = try session(4, at: 1)
        s.enterCompare()                      // select 1, candidate 2
        XCTAssertNil(s.apply(.flag(.picked), to: photo(1)), "the select is not the current photo")
        let change = try XCTUnwrap(s.apply(.flag(.picked), to: photo(2)))
        XCTAssertEqual(change.photoID, 2)
        XCTAssertTrue(change.advanced)
        XCTAssertEqual(s.currentID, 3, "auto-advance moves the candidate, skipping nothing it should not")
        XCTAssertEqual(s.selectID, 1)
    }

    // MARK: Survey

    func testSurveyIsAFullPageContainingTheCurrentPhoto() throws {
        var s = try session(30, at: 10)
        XCTAssertTrue(s.enterSurvey())
        XCTAssertEqual(s.surveyIDs, Array(10...21).map(Int64.init))
        XCTAssertEqual(s.currentID, 10)
        var nearEnd = try session(30, at: 29)
        nearEnd.enterSurvey()
        XCTAssertEqual(nearEnd.surveyIDs, Array(19...30).map(Int64.init), "shifted back so the page is full")
        XCTAssertEqual(nearEnd.currentID, 29)
        var small = try session(3, at: 2)
        small.enterSurvey()
        XCTAssertEqual(small.surveyIDs, [1, 2, 3])
    }

    func testSurveyArrowsMoveWithinThePageOnly() throws {
        var s = try session(30, at: 10)
        s.enterSurvey()
        XCTAssertFalse(s.previous(), "10 is the first on the page, even though 9 exists in the pass")
        for _ in 0..<11 { XCTAssertTrue(s.next()) }
        XCTAssertEqual(s.currentID, 21)
        XCTAssertFalse(s.next(), "22 is not on the page")
        XCTAssertEqual(s.positionText, "Survey 12 of 12")
    }

    func testRemovingFromTheSurveyMovesFocusAndKeepsThePhotoInThePass() throws {
        var s = try session(5, at: 1)
        s.enterSurvey()
        s.next()                              // focus 2
        XCTAssertTrue(s.removeFromSurvey())
        XCTAssertEqual(s.surveyIDs, [1, 3, 4, 5])
        XCTAssertEqual(s.currentID, 3)
        XCTAssertEqual(s.ids, [1, 2, 3, 4, 5], "removed from the page, not from the pass")
        // Removing the last on the page falls back to the previous one.
        while s.next() {}
        XCTAssertTrue(s.removeFromSurvey())
        XCTAssertEqual(s.currentID, 4)
        // The page can never be emptied.
        var two = try session(2)
        two.enterSurvey()
        XCTAssertTrue(two.removeFromSurvey())
        XCTAssertFalse(two.removeFromSurvey())
        XCTAssertEqual(two.surveyIDs.count, 1)
        var loupe = try session(3)
        XCTAssertFalse(loupe.removeFromSurvey())
    }

    func testFlagKeyAutoAdvancesWithinTheSurvey() throws {
        var s = try session(30, at: 1)
        s.enterSurvey()
        let change = try XCTUnwrap(s.apply(.flag(.rejected), to: photo(1)))
        XCTAssertTrue(change.advanced)
        XCTAssertEqual(s.currentID, 2)
        // At the last cell of the page the focus stays (no leaving the page) and the session reports it did not advance.
        while s.next() {}
        let last = try XCTUnwrap(s.apply(.flag(.picked), to: photo(12)))
        XCTAssertFalse(last.advanced)
        XCTAssertEqual(s.currentID, 12)
    }

    // MARK: Mode changes

    func testLoupeIsUntouchedAndBackToLoupeKeepsTheCurrentPhoto() throws {
        var s = try session(5, at: 3)
        XCTAssertEqual(s.visibleIDs, [3])
        XCTAssertEqual(s.neighborIDs(radius: 1), [4, 2])
        s.enterCompare()
        XCTAssertEqual(s.neighborIDs(radius: 2), [], "Compare and Survey load exactly their visible photos")
        s.enterLoupe()
        XCTAssertEqual(s.mode, .loupe)
        XCTAssertEqual(s.currentID, 4)
        XCTAssertNil(s.selectID)
        XCTAssertEqual(s.surveyIDs, [])
        s.enterSurvey(); s.enterCompare()
        XCTAssertEqual(s.mode, .compare)
        XCTAssertEqual(s.surveyIDs, [])
    }

    func testUndoFallsBackToTheLoupeWhenTheUndoneCommandsPhotoIsNotOnScreen() throws {
        var s = try session(30, at: 1)
        _ = s.apply(.rating(3), to: photo(1))
        s.next()                              // move on in the loupe (flag keys would advance; rating does not, so step by hand)
        s.enterSurvey()                       // page 2...13: photo 1 is not on it
        XCTAssertFalse(s.visibleIDs.contains(1))
        let action = try XCTUnwrap(s.undo())
        XCTAssertEqual(action.photoID, 1)
        XCTAssertEqual(s.mode, .loupe)
        XCTAssertEqual(s.currentID, 1)
    }

    func testUndoOfAPhotoThatIsNowTheSelectSwapsInsteadOfDuplicatingIt() throws {
        var s = try session(5, at: 1)
        s.enterCompare()                        // select 1, candidate 2
        _ = s.apply(.rating(4), to: photo(2))   // rate the candidate (a rating does not advance)
        s.makeSelect()                          // 2 becomes the select; the candidate moves on to 3
        XCTAssertEqual([s.selectID, s.currentID], [2, 3])
        let action = try XCTUnwrap(s.undo())
        XCTAssertEqual(action.photoID, 2)
        XCTAssertNotEqual(s.selectID, s.currentID, "both cells would show the same photo and keys would act on the select")
        XCTAssertEqual(s.currentID, 2, "the undone photo is shown as the candidate again, keys act on it")
        XCTAssertEqual(s.selectID, 3)
        XCTAssertEqual(s.mode, .compare)
    }

    func testRebuildReturnsToTheLoupe() throws {
        var s = try session(5, at: 2)
        s.enterCompare()
        XCTAssertTrue(s.rebuild(photos: (1...5).map { photo(Int64($0)) }, onlyUnflagged: false))
        XCTAssertEqual(s.mode, .loupe)
    }
}
