import XCTest
@testable import PhotoApp

/// The pure draft behind the Editor's Keywords popover: what is on the photo, what is typed in, what is taken off.
final class KeywordDraftTests: XCTestCase {
    private func kw(_ id: Int64, _ name: String) -> Keyword {
        Keyword(id: id, name: name, nameKey: KeywordName.key(for: name), createdAt: Date(timeIntervalSince1970: 0))
    }

    func testAFreshDraftHasNoChangeAndShowsTheCurrentKeywordsSorted() {
        let draft = KeywordDraft(initial: [kw(2, "sky"), kw(1, "Beach")])
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.chips.map(\.name), ["Beach", "sky"])
        XCTAssertTrue(draft.chips.allSatisfy { !$0.isPending })
        XCTAssertTrue(draft.change.adding.isEmpty)
        XCTAssertTrue(draft.change.removing.isEmpty)
    }

    func testAddParsesCommaSeparatedTextAndMarksTheChipsPending() {
        var draft = KeywordDraft(initial: [])
        XCTAssertEqual(draft.add(text: "  Sunset ,  Test  Trip; sunset"), 2)
        XCTAssertEqual(draft.change.adding, ["Sunset", "Test Trip"])
        XCTAssertEqual(draft.chips.filter(\.isPending).map(\.name), ["Sunset", "Test Trip"])
        XCTAssertTrue(draft.hasChanges)
    }

    func testAddingAKeywordTheCurrentPhotoHasIsAnUnchangedNoOp() {
        var draft = KeywordDraft(initial: [kw(1, "Sky")])
        XCTAssertEqual(draft.add(text: "SKY"), 0, "the same keyword under another case is already there")
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.chips.count, 1)
    }

    func testAddingAPendingKeywordAgainDoesNotDuplicateIt() {
        var draft = KeywordDraft(initial: [])
        draft.add(text: "Dawn")
        XCTAssertEqual(draft.add(text: "dawn"), 0)
        XCTAssertEqual(draft.change.adding, ["Dawn"])
    }

    func testRemoveTakesAnExistingKeywordOffAndReportsItsId() {
        var draft = KeywordDraft(initial: [kw(1, "Sky"), kw(2, "Sea")])
        draft.remove(id: 1)
        XCTAssertEqual(draft.change.removing, [1])
        XCTAssertEqual(draft.chips.map(\.name), ["Sea"])
        XCTAssertTrue(draft.hasChanges)
    }

    func testReAddingARemovedKeywordCancelsTheRemovalInsteadOfAddingIt() {
        var draft = KeywordDraft(initial: [kw(1, "Sky")])
        draft.remove(id: 1)
        XCTAssertEqual(draft.add(text: "sky"), 1)
        XCTAssertTrue(draft.change.removing.isEmpty)
        XCTAssertTrue(draft.change.adding.isEmpty, "it is still the existing keyword, not a new one")
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.chips.map(\.name), ["Sky"])
    }

    func testRemovingAnUnknownIdChangesNothing() {
        var draft = KeywordDraft(initial: [kw(1, "Sky")])
        draft.remove(id: 99)
        XCTAssertFalse(draft.hasChanges)
    }

    func testUndoAddDropsAPendingKeywordByNameKey() {
        var draft = KeywordDraft(initial: [])
        draft.add(text: "A, B")
        draft.undoAdd(name: "a")
        XCTAssertEqual(draft.change.adding, ["B"])
        draft.undoAdd(name: "B")
        XCTAssertFalse(draft.hasChanges)
    }

    func testAnAddAndARemoveTogether() {
        var draft = KeywordDraft(initial: [kw(1, "Old")])
        draft.add(text: "New")
        draft.remove(id: 1)
        XCTAssertEqual(draft.change.adding, ["New"])
        XCTAssertEqual(draft.change.removing, [1])
        XCTAssertEqual(draft.chips.map(\.name), ["New"])
    }

    func testBlankAndControlOnlyTextAddsNothing() {
        var draft = KeywordDraft(initial: [])
        XCTAssertEqual(draft.add(text: "  ,;\n\u{0007} "), 0)
        XCTAssertFalse(draft.hasChanges)
    }

    func testAPendingNameTakesTheSpellingTheCatalogAlreadyHas() {
        var draft = KeywordDraft(initial: [])
        draft.add(text: "SUNSET, New One", known: [kw(7, "Sunset")])
        XCTAssertEqual(draft.change.adding, ["Sunset", "New One"], "the chip shows what the database will keep")
        XCTAssertEqual(draft.chips.map(\.name), ["Sunset", "New One"])
    }

    // MARK: Suggestions

    func testSuggestionsMatchByPrefixOfTheLastTypedWordAndSkipWhatTheDraftHas() {
        var draft = KeywordDraft(initial: [kw(1, "Sky")])
        draft.add(text: "Sunrise")
        let pool = [kw(1, "Sky"), kw(2, "Sunset"), kw(3, "Sunrise"), kw(4, "Beach"), kw(5, "sunday")]
        XCTAssertEqual(draft.suggestions(forInput: "su", among: pool).map(\.name), ["sunday", "Sunset"])
        XCTAssertEqual(draft.suggestions(forInput: "Dawn, SUNS", among: pool).map(\.name), ["Sunset"], "only the piece being typed counts")
        XCTAssertEqual(draft.suggestions(forInput: "", among: pool).map(\.name), ["Beach", "sunday", "Sunset"], "no input: everything not on the photo")
        XCTAssertEqual(draft.suggestions(forInput: "su", among: pool, limit: 1).map(\.name), ["sunday"])
    }

    func testARemovedKeywordIsSuggestedAgain() {
        var draft = KeywordDraft(initial: [kw(1, "Sky")])
        draft.remove(id: 1)
        XCTAssertEqual(draft.suggestions(forInput: "s", among: [kw(1, "Sky")]).map(\.name), ["Sky"])
    }
}
