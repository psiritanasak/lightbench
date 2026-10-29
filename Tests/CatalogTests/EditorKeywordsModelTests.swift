import XCTest
@testable import PhotoApp

/// The Editor's Keywords popover model: capture-at-open, one write of only what changed, idempotent close paths.
@MainActor
final class EditorKeywordsModelTests: XCTestCase {
    private struct Write { var adding: [String]; var removing: Set<Int64>; var photo: Photo }
    private final class Log { var writes: [Write] = [] }

    private func photo(_ id: Int64, master: Int64? = nil, key: String? = nil) -> Photo {
        Photo(id: id, path: "/a.jpg", filename: "x", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
              masterId: master, versionKey: key, versionName: key == nil ? nil : "Copy 1")
    }

    private func kw(_ id: Int64, _ name: String) -> Keyword {
        Keyword(id: id, name: name, nameKey: KeywordName.key(for: name), createdAt: Date(timeIntervalSince1970: 0))
    }

    private func make(_ log: Log = Log()) -> EditorKeywordsModel {
        EditorKeywordsModel(write: { adding, removing, photo in log.writes.append(Write(adding: adding, removing: removing, photo: photo)) })
    }

    func testBeginCapturesTheTargetAndSeedsTheDraft() {
        let model = make()
        model.begin(photo: photo(3), current: [kw(1, "Sky")])
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(model.target?.id, 3)
        XCTAssertEqual(model.draft.chips.map(\.name), ["Sky"])
        XCTAssertFalse(model.draft.hasChanges)
    }

    func testCommitWritesTheChangeToTheCapturedVersionItself() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(8, master: 2, key: "aaaaaaaa"), current: [kw(1, "Old")])
        model.add(text: "New")
        model.remove(id: 1)
        model.commit()
        XCTAssertEqual(log.writes.count, 1)
        XCTAssertEqual(log.writes[0].photo.id, 8, "the version's own id, never its master's")
        XCTAssertEqual(log.writes[0].adding, ["New"])
        XCTAssertEqual(log.writes[0].removing, [1])
        XCTAssertFalse(model.isOpen)
        XCTAssertNil(model.target)
    }

    func testCommitWithNoChangeWritesNothing() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(1), current: [kw(1, "Sky")])
        model.add(text: "sky")
        model.remove(id: 1)
        model.add(text: "Sky") // removed and put back: unchanged
        model.commit()
        XCTAssertTrue(log.writes.isEmpty)
        XCTAssertFalse(model.isOpen)
    }

    func testTextStillTypedInTheFieldIsSavedOnCommit() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(1), current: [])
        model.input = "Typed, but never Return"
        model.commit()
        XCTAssertEqual(log.writes.first?.adding, ["Typed", "but never Return"], "closing by any route must not lose typed text")
    }

    func testSubmitAddsTheTypedTextAsChipsAndClearsTheField() {
        let model = make()
        model.begin(photo: photo(1), current: [])
        model.input = "A, B"
        model.submitInput()
        XCTAssertEqual(model.input, "")
        XCTAssertEqual(model.draft.change.adding, ["A", "B"])
    }

    func testDiscardWritesNothingAndALaterCommitIsANoOp() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(1), current: [])
        model.input = "left in the field"
        model.add(text: "typed")
        model.discard()
        model.commit() // the popover's close binding fires after Escape
        XCTAssertTrue(log.writes.isEmpty)
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(model.input, "")
    }

    func testCommitIsIdempotent() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(1), current: [])
        model.add(text: "X")
        model.commit()
        model.commit()
        XCTAssertEqual(log.writes.count, 1)
    }

    func testBeginningAgainWhileOpenSavesTheFirstSessionToItsOwnPhoto() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(1), current: [])
        model.add(text: "First")
        model.begin(photo: photo(2), current: [kw(5, "Other")])
        XCTAssertEqual(log.writes.count, 1)
        XCTAssertEqual(log.writes[0].photo.id, 1)
        XCTAssertEqual(model.target?.id, 2)
        XCTAssertEqual(model.draft.chips.map(\.name), ["Other"], "a fresh draft")
    }

    func testCommitAfterThePhotoSwitchStillGoesToTheCapturedPhoto() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(1), current: [])
        model.add(text: "Mine")
        // The Editor now shows photo 2; nothing about the model follows it.
        model.commit()
        XCTAssertEqual(log.writes[0].photo.id, 1)
    }

    func testToggleClosesWithSavingWhenOpenAndOpensOnlyWithAPhoto() {
        let log = Log()
        let model = make(log)
        model.toggle(photo: nil, current: { _ in [] })
        XCTAssertFalse(model.isOpen, "no catalog row: nothing happens")
        model.toggle(photo: photo(4), current: { _ in [self.kw(1, "Sky")] })
        XCTAssertTrue(model.isOpen)
        model.add(text: "Sea")
        model.toggle(photo: photo(4), current: { _ in [] })
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(log.writes.first?.adding, ["Sea"])
    }

    func testEditsWhileClosedAreIgnored() {
        let model = make()
        model.add(text: "X")
        model.remove(id: 1)
        model.begin(photo: photo(1), current: [])
        XCTAssertFalse(model.draft.hasChanges)
    }

    func testTargetIsCopyIsTrueOnlyForAVirtualCopy() {
        let model = make()
        model.begin(photo: photo(1), current: [])
        XCTAssertFalse(model.targetIsCopy)
        model.begin(photo: photo(2, master: 1, key: "bbbbbbbb"), current: [])
        XCTAssertTrue(model.targetIsCopy)
    }

    func testAcceptingASuggestionReplacesTheHalfTypedPieceInsteadOfLeavingItToBeSaved() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(1), current: [])
        model.input = "fo"
        model.acceptSuggestion(kw(3, "food"))
        XCTAssertEqual(model.input, "")
        model.commit()
        XCTAssertEqual(log.writes.first?.adding, ["food"], "no extra 'fo' keyword")
    }

    func testAcceptingASuggestionKeepsTextBeforeAnEarlierSeparator() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(1), current: [])
        model.input = "sunset, fo"
        model.acceptSuggestion(kw(3, "food"))
        XCTAssertEqual(model.input, "sunset, ")
        model.commit()
        XCTAssertEqual(log.writes.first?.adding, ["food", "sunset"])
    }

    func testAcceptingAfterASemicolonOrNewlineAlsoKeepsThePrefix() {
        let model = make()
        model.begin(photo: photo(1), current: [])
        model.input = "a;b\nfo"
        model.acceptSuggestion(kw(3, "food"))
        XCTAssertEqual(model.input, "a;b\n")
    }

    func testAcceptingWithAnEmptyFieldJustAdds() {
        let model = make()
        model.begin(photo: photo(1), current: [])
        model.acceptSuggestion(kw(3, "food"))
        XCTAssertEqual(model.input, "")
        XCTAssertEqual(model.draft.change.adding, ["food"])
    }

    func testTypedNamesUseTheSpellingOfAKeywordTheLibraryAlreadyHas() {
        let model = make()
        model.begin(photo: photo(1), current: [], known: [kw(7, "Sunset")])
        model.input = "SUNSET"
        model.submitInput()
        XCTAssertEqual(model.draft.chips.map(\.name), ["Sunset"])
    }

    func testSuggestionsFollowTheTypedInput() {
        let model = make()
        model.begin(photo: photo(1), current: [kw(1, "Sky")])
        model.input = "s"
        XCTAssertEqual(model.suggestions(among: [kw(1, "Sky"), kw(2, "Sea"), kw(3, "Beach")]).map(\.name), ["Sea"])
    }
}

// MARK: - Menu rules

final class EditorKeywordsMenuRulesTests: XCTestCase {
    private func disabled(lib: Bool, cull: Bool = false, blocked: Bool = false, open: Bool = true, loading: Bool = false,
                          row: Bool = true, own: Bool = false, info: Bool = false) -> Bool {
        EditorKeywordsMenuRules.isDisabled(showLibrary: lib, cullActive: cull, libraryBlocked: blocked, hasOpenPhoto: open, loadInFlight: loading,
                                           hasCatalogRow: row, popoverOpen: own, infoOpen: info)
    }

    func testEditorNeedsAnOpenLoadedPhotoWithACatalogRow() {
        XCTAssertFalse(disabled(lib: false))
        XCTAssertTrue(disabled(lib: false, open: false))
        XCTAssertTrue(disabled(lib: false, loading: true))
        XCTAssertTrue(disabled(lib: false, row: false))
        XCTAssertFalse(disabled(lib: false, blocked: true), "the Library's selection rules do not apply in the Editor")
    }

    func testItsOwnPopoverStaysClosableWithTheKey() {
        XCTAssertFalse(disabled(lib: false, row: false, own: true))
        XCTAssertFalse(disabled(lib: false, loading: true, own: true))
        XCTAssertTrue(disabled(lib: false, cull: true, own: true))
    }

    func testItIsOffWhileTheInfoPopoverIsOpen() {
        XCTAssertTrue(disabled(lib: false, info: true), "never two popovers at once")
    }

    func testTheLibraryUsesItsOwnBlockedFlagAndCullingAlwaysBlocks() {
        XCTAssertTrue(disabled(lib: true, blocked: true))
        XCTAssertFalse(disabled(lib: true, open: false, row: false))
        XCTAssertTrue(disabled(lib: true, cull: true))
    }

    func testInfoIsOffWhileKeywordsIsOpenButItsOwnPopoverStaysClosable() {
        func info(keywords: Bool, own: Bool = false) -> Bool {
            EditorInfoMenuRules.isDisabled(showLibrary: false, cullActive: false, libraryBlocked: false, hasOpenPhoto: true, loadInFlight: false,
                                           hasCatalogRow: true, popoverOpen: own, keywordsOpen: keywords)
        }
        XCTAssertTrue(info(keywords: true))
        XCTAssertFalse(info(keywords: false))
        XCTAssertFalse(info(keywords: true, own: true), "its own popover can close")
    }
}

// MARK: - Catalog side

@MainActor
final class EditorKeywordsCatalogTests: XCTestCase {
    private func makeModel() async throws -> (CatalogModel, CatalogDatabase, master: Photo, copy: Photo) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: ["/p/a.jpg", "/p/b.jpg"].map { URL(fileURLWithPath: $0) })
        let a0 = try await db.photo(atPath: "/p/a.jpg")
        let a = try XCTUnwrap(a0)
        let copy = try await db.createVirtualCopy(of: a, versionKey: "aaaaaaaa")
        let model = CatalogModel(database: db, defaults: UserDefaults(suiteName: "EditorKeywordsCatalogTests-\(UUID().uuidString)") ?? .standard)
        await model.refresh()
        return (model, db, a, copy)
    }

    private func waitUntil(_ what: String, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    func testKeywordsForAPhotoResolvesItsOwnIds() async throws {
        let (model, db, master, copy) = try await makeModel()
        try await db.addKeywords(["Sky", "Sea"], to: [try XCTUnwrap(master.id)])
        await model.refresh()
        XCTAssertEqual(model.keywords(for: master).map(\.name), ["Sea", "Sky"])
        XCTAssertTrue(model.keywords(for: copy).isEmpty, "a version has its own keywords")
    }

    func testApplyKeywordEditsOnACopyWritesTheCopyAndUpdatesTheMaps() async throws {
        let (model, db, master, copy) = try await makeModel()
        let copyID = try XCTUnwrap(copy.id)
        model.applyKeywordEdits(adding: ["Copy Only"], removing: [], for: copy)
        try await waitUntil("the link is stored") { try await db.allKeywordLinks().contains { $0.photoId == copyID } }
        try await waitUntil("state follows") { model.keywordIDsByPhotoID[copyID]?.count == 1 }
        XCTAssertNil(model.keywordIDsByPhotoID[master.id ?? -1])
        XCTAssertEqual(model.keywords.map(\.name), ["Copy Only"])
    }

    func testApplyKeywordEditsWorksForAPhotoTheCallerHolds() async throws {
        let (model, db, _, _) = try await makeModel()
        let found = try await db.photo(atPath: "/p/b.jpg")
        let b = try XCTUnwrap(found)
        // The write must not depend on `model.photos` (the Editor's photo may be outside the current collection).
        model.applyKeywordEdits(adding: ["Outside"], removing: [], for: b)
        try await waitUntil("stored") { try await db.allKeywordLinks().contains { $0.photoId == b.id } }
    }

    func testApplyKeywordEditsAddsAndRemovesTogether() async throws {
        let (model, db, master, _) = try await makeModel()
        let id = try XCTUnwrap(master.id)
        try await db.addKeywords(["Old"], to: [id])
        await model.refresh()
        let oldID = try XCTUnwrap(model.keywords.first?.id)
        model.applyKeywordEdits(adding: ["New"], removing: [oldID], for: master)
        try await waitUntil("swapped") {
            let linked = Set(try await db.allKeywordLinks().filter { $0.photoId == id }.map(\.keywordId))
            let all = try await db.allKeywords()
            return linked.count == 1 && all.first { $0.id == linked.first }?.name == "New"
        }
    }

    func testAFailedWriteIsReportedAndLeavesTheCatalogUnchanged() async throws {
        let (model, db, _, _) = try await makeModel()
        let ghost = Photo(id: 424_242, path: "/ghost.jpg", filename: "g", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0))
        model.applyKeywordEdits(adding: ["Never"], removing: [], for: ghost)
        try await waitUntil("a message") { model.importStatusMessage?.contains("Couldn't save keywords") == true }
        let all = try await db.allKeywords()
        XCTAssertTrue(all.isEmpty)
    }

    func testThePopoverCommitReachesTheDatabaseThroughTheCatalog() async throws {
        let (model, db, _, copy) = try await makeModel()
        let popover = EditorKeywordsModel(write: { adding, removing, photo in model.applyKeywordEdits(adding: adding, removing: removing, for: photo) })
        popover.begin(photo: copy, current: model.keywords(for: copy))
        popover.input = "Typed"
        popover.commit()
        try await waitUntil("written") { try await db.allKeywordLinks().contains { $0.photoId == copy.id } }
    }

    func testEditorPopoverOpenIsTrueForEitherPopover() throws {
        let model = CatalogModel(database: try CatalogDatabase(inMemory: true), defaults: UserDefaults(suiteName: "EKC-\(UUID().uuidString)") ?? .standard)
        XCTAssertFalse(model.editorPopoverOpen)
        model.editorInfoOpen = true
        XCTAssertTrue(model.editorPopoverOpen)
        model.editorInfoOpen = false
        model.editorKeywordsOpen = true
        XCTAssertTrue(model.editorPopoverOpen)
    }
}

// MARK: - Wiring pins

final class EditorKeywordsWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheKeywordsItemIsContextAware() throws {
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("catalog.keywordSheetRequested = true"))
        XCTAssertTrue(app.contains("catalog.editorKeywordsToggleRequested = true"))
        XCTAssertTrue(app.contains("EditorKeywordsMenuRules.isDisabled("))
        XCTAssertTrue(app.contains("popoverOpen: catalog.editorKeywordsOpen, infoOpen: catalog.editorInfoOpen"))
        XCTAssertTrue(app.contains("keywordsOpen: catalog.editorKeywordsOpen"), "Info is off while Keywords is open")
    }

    func testContentViewWiresTheKeywordsPopover() throws {
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("EditorKeywordsLifecycle(model: editorKeywords"))
        XCTAssertTrue(content.contains("catalog.applyKeywordEdits(adding: adding, removing: removing, for: photo)"))
        XCTAssertTrue(content.contains("keywords: editorKeywords, onKeywords: toggleEditorKeywords"))
        XCTAssertTrue(content.contains("!editorKeywords.isOpen"), "Info refuses to open over Keywords")
        XCTAssertTrue(content.contains("!editorInfo.isOpen"), "Keywords refuses to open over Info")
        let lifecycle = try source("Sources/UI/EditorKeywordsPopover.swift")
        XCTAssertTrue(lifecycle.contains(".onChange(of: editKey) { _, _ in model.commit() }"))
        XCTAssertTrue(lifecycle.contains(".onChange(of: showLibrary) { _, _ in model.commit() }"))
        XCTAssertTrue(lifecycle.contains("catalog.editorKeywordsOpen = open"))
    }

    func testThePopoverIsOnASolidPanelAndEscapeDiscards() throws {
        let popover = try source("Sources/UI/EditorKeywordsPopover.swift")
        let start = try XCTUnwrap(popover.range(of: "struct EditorKeywordsPopover: View {"))
        let end = try XCTUnwrap(popover.range(of: "// MARK: - Lifecycle"))
        let body = String(popover[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains(".background(Theme.panel)"))
        XCTAssertTrue(body.contains(".onExitCommand { model.discard() }"))
        XCTAssertTrue(body.contains("Button(\"Cancel\") { model.discard() }.keyboardShortcut(.cancelAction)"))
        XCTAssertTrue(body.contains("Button(\"Done\") { model.commit() }"))
        XCTAssertTrue(body.contains("Keywords are this version"), "the virtual-copy note")
    }

    func testEachBarButtonIsDimWhileTheOtherPopoverIsOpen() throws {
        let bar = try source("Sources/UI/EditorRatingBar.swift")
        XCTAssertTrue(bar.contains("let enabled = (meta.photo != nil || info.isOpen) && !otherOpen"))
        XCTAssertTrue(bar.contains("let enabled = (meta.photo != nil || keywords.isOpen) && !otherOpen"))
        XCTAssertTrue(bar.contains("infoButton(info, otherOpen: keywords?.isOpen ?? false)"))
        XCTAssertTrue(bar.contains("keywordsButton(keywords, otherOpen: info?.isOpen ?? false)"))
    }

    func testTheSuggestionButtonUsesAcceptSuggestionAndOpeningPassesTheKnownKeywords() throws {
        XCTAssertTrue(try source("Sources/UI/EditorKeywordsPopover.swift").contains("model.acceptSuggestion(keyword)"))
        XCTAssertTrue(try source("Sources/UI/ContentView.swift").contains("known: catalog.keywords)"))
    }

    func testFlowRowIsSharedNotDuplicated() throws {
        XCTAssertFalse(try source("Sources/UI/KeywordSheetView.swift").contains("struct FlowRow"))
        XCTAssertTrue(try source("Sources/UI/FlowRow.swift").contains("struct FlowRow: Layout"))
        XCTAssertTrue(try source("Sources/UI/EditorKeywordsPopover.swift").contains("FlowRow("))
    }

    func testTheShortcutRowNamesBothContexts() {
        let row = KeyboardShortcutCatalog.sections.flatMap(\.entries).first { $0.keys == "\u{2318}K" }
        XCTAssertTrue(row?.action.contains("Library") ?? false)
        XCTAssertTrue(row?.action.contains("Editor") ?? false)
    }
}
