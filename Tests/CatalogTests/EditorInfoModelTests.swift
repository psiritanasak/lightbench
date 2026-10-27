import XCTest
@testable import PhotoApp

/// The Editor's Info popover model: capture-at-open, touched-only writes, idempotent close paths.
@MainActor
final class EditorInfoModelTests: XCTestCase {
    private struct Write { var info: PhotoInfo; var fields: InfoFields; var photos: [Photo] }
    private final class Log { var writes: [Write] = [] }

    private func photo(_ id: Int64, path: String = "/a.jpg", master: Int64? = nil, key: String? = nil) -> Photo {
        Photo(id: id, path: path, filename: "x", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
              masterId: master, versionKey: key, versionName: key == nil ? nil : "Copy 1")
    }

    private func make(_ log: Log = Log()) -> EditorInfoModel {
        EditorInfoModel(write: { info, fields, photos in log.writes.append(Write(info: info, fields: fields, photos: photos)) })
    }

    func testBeginSeedsTheDraftFromTheCurrentInfoAndCapturesTheTarget() {
        let model = make()
        let a = photo(1)
        model.begin(photo: a, currentInfo: PhotoInfo(title: "T", caption: "C", creator: "Me", copyright: "(c)"))
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(model.target?.id, 1)
        XCTAssertEqual(model.draft.text[.title], "T")
        XCTAssertEqual(model.draft.text[.copyright], "(c)")
        XCTAssertFalse(model.draft.hasChanges)
    }

    func testCommitWritesOnlyTouchedFieldsToTheCapturedPhoto() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(7), currentInfo: PhotoInfo(title: "Keep", caption: "", creator: "", copyright: ""))
        model.edit(.creator, to: "Jane")
        model.commit()
        XCTAssertEqual(log.writes.count, 1)
        XCTAssertEqual(log.writes[0].fields, .creator)
        XCTAssertEqual(log.writes[0].info.creator, "Jane")
        XCTAssertEqual(log.writes[0].photos.map(\.id), [7])
        XCTAssertFalse(model.isOpen)
    }

    func testCommitWithNothingTouchedWritesNothing() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(1), currentInfo: PhotoInfo(title: "T"))
        model.edit(.title, to: "changed")
        model.edit(.title, to: "T") // typed back to the start: untouched
        model.commit()
        XCTAssertTrue(log.writes.isEmpty)
        XCTAssertFalse(model.isOpen)
    }

    func testDiscardWritesNothingAndLaterCommitIsANoOp() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(1), currentInfo: PhotoInfo())
        model.edit(.title, to: "typed")
        model.discard()
        model.commit() // the popover's close binding fires after Escape: must not save what was discarded
        XCTAssertTrue(log.writes.isEmpty)
        XCTAssertFalse(model.isOpen)
    }

    func testDoubleCommitWritesOnce() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(1), currentInfo: PhotoInfo())
        model.edit(.title, to: "x")
        model.commit()
        model.commit()
        XCTAssertEqual(log.writes.count, 1)
    }

    func testEditsWhileClosedAreIgnored() {
        let log = Log()
        let model = make(log)
        model.edit(.title, to: "stray")
        XCTAssertFalse(model.draft.hasChanges, "a closed model keeps no draft")
        model.commit()
        XCTAssertTrue(log.writes.isEmpty)
    }

    func testBeginningAgainSavesTheFirstPhotoToItself() {
        let log = Log()
        let model = make(log)
        model.begin(photo: photo(1), currentInfo: PhotoInfo())
        model.edit(.title, to: "for one")
        model.begin(photo: photo(2, path: "/b.jpg"), currentInfo: PhotoInfo())
        XCTAssertEqual(log.writes.count, 1)
        XCTAssertEqual(log.writes.first?.photos.map(\.id), [1], "typing belongs to the photo it was typed for")
        XCTAssertEqual(model.target?.id, 2)
        XCTAssertFalse(model.draft.hasChanges, "the second session starts clean")
    }

    func testACopyTargetIsReportedAndPassedThrough() {
        let log = Log()
        let model = make(log)
        let copy = photo(9, master: 1, key: "aaaaaaaa")
        model.begin(photo: copy, currentInfo: PhotoInfo())
        XCTAssertTrue(model.targetIsCopy)
        model.edit(.caption, to: "c")
        model.commit()
        XCTAssertEqual(log.writes.first?.photos.first?.masterId, 1)
        XCTAssertFalse(model.targetIsCopy, "closed")
    }

    func testToggleOpensOnThePhotoClosesBySavingAndIgnoresNoPhoto() {
        let log = Log()
        let model = make(log)
        model.toggle(photo: nil, currentInfo: { _ in PhotoInfo() })
        XCTAssertFalse(model.isOpen, "no catalog row: nothing opens")
        model.toggle(photo: photo(3), currentInfo: { _ in PhotoInfo(title: "T") })
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(model.draft.text[.title], "T")
        model.edit(.title, to: "T2")
        model.toggle(photo: photo(3), currentInfo: { _ in PhotoInfo() })
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(log.writes.count, 1, "toggling closed saves")
    }

    func testTheMenuItemIsEnabledInTheEditorOnlyWithAnOpenLoadedPhotoAndNeverDuringCulling() {
        func disabled(lib: Bool, cull: Bool = false, blocked: Bool = false, open: Bool = true, loading: Bool = false) -> Bool {
            EditorInfoMenuRules.isDisabled(showLibrary: lib, cullActive: cull, libraryBlocked: blocked, hasOpenPhoto: open, loadInFlight: loading)
        }
        XCTAssertFalse(disabled(lib: false))
        XCTAssertTrue(disabled(lib: false, open: false))
        XCTAssertTrue(disabled(lib: false, loading: true))
        XCTAssertTrue(disabled(lib: false, cull: true))
        XCTAssertFalse(disabled(lib: false, blocked: true), "the Library's selection rules do not apply in the Editor")
        XCTAssertTrue(disabled(lib: true, blocked: true))
        XCTAssertFalse(disabled(lib: true, open: false), "the Library does not need an open photo")
        XCTAssertTrue(disabled(lib: true, cull: true))
    }
}

/// Catalog side: copy resolution by edit key and writes for photos outside the current collection.
@MainActor
final class EditorInfoCatalogTests: XCTestCase {
    private func makeModel() async throws -> (CatalogModel, CatalogDatabase, master: Photo, copy: Photo) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: ["/p/a.jpg", "/p/b.jpg"].map { URL(fileURLWithPath: $0) })
        let a0 = try await db.photo(atPath: "/p/a.jpg")
        let a = try XCTUnwrap(a0)
        let copy = try await db.createVirtualCopy(of: a, versionKey: "aaaaaaaa")
        let model = CatalogModel(database: db, defaults: UserDefaults(suiteName: "EditorInfoCatalogTests-\(UUID().uuidString)") ?? .standard)
        await model.refresh()
        return (model, db, a, copy)
    }

    private func waitUntil(_ what: String, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    // MARK: Edit key lookup

    func testSplitEditKeyInvertsEditKey() {
        XCTAssertEqual(Photo.splitEditKey("/p/a.jpg").path, "/p/a.jpg")
        XCTAssertNil(Photo.splitEditKey("/p/a.jpg").versionKey)
        let key = Photo.editKey(path: "/p/a.jpg", versionKey: "aaaaaaaa")
        XCTAssertEqual(Photo.splitEditKey(key).path, "/p/a.jpg")
        XCTAssertEqual(Photo.splitEditKey(key).versionKey, "aaaaaaaa")
    }

    func testPhotoByEditKeyFindsAMasterAndItsCopySeparately() async throws {
        let (_, db, master, copy) = try await makeModel()
        let m = try await db.photo(editKey: master.editKey)
        let c = try await db.photo(editKey: copy.editKey)
        XCTAssertEqual(m?.id, master.id)
        XCTAssertNil(m?.versionKey, "a master's key resolves to the master, not its copy")
        XCTAssertEqual(c?.id, copy.id)
        XCTAssertEqual(c?.masterId, master.id)
        let missing = try await db.photo(editKey: Photo.editKey(path: "/p/a.jpg", versionKey: "bbbbbbbb"))
        XCTAssertNil(missing)
        let none = try await db.photo(editKey: "/nowhere.jpg")
        XCTAssertNil(none)
    }

    func testCatalogModelResolvesACopyByEditKey() async throws {
        let (model, _, _, copy) = try await makeModel()
        let found = try await model.catalogedPhoto(editKey: copy.editKey)
        XCTAssertEqual(found?.id, copy.id)
    }

    // MARK: setInfo(forPhotos:)

    func testAPhotoOutsideTheCurrentCollectionStillUpdatesTheInMemoryMap() async throws {
        let (model, db, master, _) = try await makeModel()
        let outsider = Photo(id: 9999, path: "/elsewhere/z.jpg", filename: "z", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(model.photos.contains { $0.id == 9999 })
        model.setInfo(PhotoInfo(title: "Outside"), fields: .title, forPhotos: [outsider])
        XCTAssertEqual(model.infoByPhotoID[9999]?.title, "Outside", "the map follows the caller's photo, not `photos`")
        // The id-based API ignores ids that are not in `photos` (unchanged behaviour).
        model.setInfo(PhotoInfo(title: "Ignored"), fields: .title, for: [8888])
        XCTAssertNil(model.infoByPhotoID[8888])
        _ = (db, master)
    }

    func testACopyEditsItsMasterAndEachMasterIsAppliedOnce() async throws {
        let (model, db, master, copy) = try await makeModel()
        model.setInfo(PhotoInfo(title: "Shared"), fields: .title, forPhotos: [copy, master])
        XCTAssertEqual(model.infoByPhotoID[master.id ?? -1]?.title, "Shared")
        XCTAssertNil(model.infoByPhotoID[copy.id ?? -1], "no entry for the copy")
        try await waitUntil("the master's row is written") { try await db.allInfo()[master.id ?? -1]?.title == "Shared" }
        let stored = try await db.allInfo()
        XCTAssertEqual(stored.count, 1)
    }

    func testOnlyTheNamedFieldsChangeAndAnEmptyFieldSetDoesNothing() async throws {
        let (model, db, master, _) = try await makeModel()
        model.setInfo(PhotoInfo(title: "T", caption: "C"), fields: [.title, .caption], forPhotos: [master])
        model.setInfo(PhotoInfo(title: "T2"), fields: .title, forPhotos: [master])
        XCTAssertEqual(model.infoByPhotoID[master.id ?? -1]?.caption, "C")
        model.setInfo(PhotoInfo(title: "never"), fields: [], forPhotos: [master])
        XCTAssertEqual(model.infoByPhotoID[master.id ?? -1]?.title, "T2")
        try await waitUntil("written") { try await db.allInfo()[master.id ?? -1]?.title == "T2" }
    }

    func testClearingEveryFieldRemovesTheMapEntry() async throws {
        let (model, _, master, _) = try await makeModel()
        model.setInfo(PhotoInfo(title: "T"), fields: .title, forPhotos: [master])
        model.setInfo(PhotoInfo(title: ""), fields: .title, forPhotos: [master])
        XCTAssertNil(model.infoByPhotoID[master.id ?? -1])
    }

    func testTheWholePathFromAPopoverCommitReachesTheDatabaseForACopy() async throws {
        let (model, db, master, copy) = try await makeModel()
        let popover = EditorInfoModel(write: { info, fields, photos in model.setInfo(info, fields: fields, forPhotos: photos) })
        popover.begin(photo: copy, currentInfo: model.info(for: copy))
        popover.edit(.caption, to: "Typed in the Editor")
        popover.commit()
        try await waitUntil("the master's caption is stored") { try await db.allInfo()[master.id ?? -1]?.caption == "Typed in the Editor" }
        XCTAssertEqual(model.info(for: copy).caption, "Typed in the Editor")
    }
}

/// Source pins for the wiring that has no logic of its own to unit test: if one of these lines is removed the feature silently breaks.
final class EditorInfoWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The Photo-menu items that act on the open photo, the selection or the photo's undo history. While the Info popover is open the
    /// user is typing and menu shortcuts still fire (⌘Z, ⌘←, ⌘[ ...), so every one must name `catalog.editorInfoOpen`.
    private let guardedItems = [
        "Button(\"Undo\")", "Button(\"Redo\")", "Button(\"Previous Photo\")", "Button(\"Next Photo\")", "Button(\"Cull Photos\")",
        "Button(\"Copy Settings\")", "Button(\"Paste Settings\")", "Button(\"Import Lightroom Settings…\")", "Button(\"Rotate Left\")",
        "Button(\"Rotate Right\")", "Button(\"Create Virtual Copy\")", "Button(\"Stack Selected\")", "Button(\"Unstack\")"
    ]

    func testEveryItemThatCouldActMidTypingIsDisabledWhileThePopoverIsOpen() throws {
        let app = try source("Sources/App/PhotoAppApp.swift")
        for item in guardedItems {
            let start = try XCTUnwrap(app.range(of: item), item)
            // The item's own block: up to the next Button( / Divider() / closing of its group.
            let rest = app[start.upperBound...]
            let end = rest.range(of: "Button(")?.lowerBound ?? rest.endIndex
            let block = String(rest[..<end])
            XCTAssertTrue(block.contains("catalog.editorInfoOpen"), "\(item) must be disabled while the Info popover is open")
        }
    }

    func testTheEditInfoItemIsContextAware() throws {
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("catalog.editorInfoToggleRequested = true"))
        XCTAssertTrue(app.contains("catalog.infoSheetRequested = true"))
        XCTAssertTrue(app.contains("EditorInfoMenuRules.isDisabled("))
    }

    func testContentViewWiresThePopoverCopyResolutionAndTheWriter() throws {
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("EditorInfoLifecycle(model: editorInfo"))
        XCTAssertTrue(content.contains("catalog.catalogedPhoto(editKey: key)"), "a virtual copy outside the grid must resolve")
        XCTAssertTrue(content.contains("catalog.setInfo(info, fields: fields, forPhotos: photos)"), "the Editor writes through the Photo-holding overload")
        XCTAssertTrue(content.contains("info: editorInfo, onInfo: toggleEditorInfo"))
        let lifecycle = try source("Sources/UI/EditorInfoPopover.swift")
        XCTAssertTrue(lifecycle.contains(".onChange(of: editKey) { _, _ in model.commit() }"), "switching photo saves to the captured photo")
        XCTAssertTrue(lifecycle.contains(".onChange(of: showLibrary) { _, _ in model.commit() }"), "leaving the Editor saves")
        XCTAssertTrue(lifecycle.contains("catalog.editorInfoOpen = open"))
    }

    func testThePopoverIsOnASolidPanelAndEscapeDiscards() throws {
        let popover = try source("Sources/UI/EditorInfoPopover.swift")
        let start = try XCTUnwrap(popover.range(of: "struct EditorInfoPopover: View {"))
        let end = try XCTUnwrap(popover.range(of: "// MARK: - Lifecycle"))
        let body = String(popover[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains(".background(Theme.panel)"))
        XCTAssertTrue(body.contains(".onExitCommand { model.discard() }"))
        XCTAssertTrue(body.contains("Button(\"Cancel\") { model.discard() }.keyboardShortcut(.cancelAction)"))
        XCTAssertTrue(body.contains("Button(\"Done\") { model.commit() }"))
    }

    func testTheSheetAndThePopoverShareOneFieldsViewAndOneCopyNote() throws {
        XCTAssertTrue(try source("Sources/UI/InfoSheetView.swift").contains("InfoFieldsView(draft: draft"))
        XCTAssertTrue(try source("Sources/UI/EditorInfoPopover.swift").contains("InfoFieldsView(draft: model.draft"))
        XCTAssertTrue(try source("Sources/UI/EditorInfoPopover.swift").contains("InfoFieldsView.copyNote(count: 1)"))
        XCTAssertTrue(try source("Sources/UI/InfoSheetView.swift").contains("InfoFieldsView.copyNote(count: copyCount)"))
    }

    func testCaptionTabMovesFocusInsteadOfInsertingATabCharacter() throws {
        let fields = try source("Sources/UI/InfoSheetView.swift")
        XCTAssertTrue(fields.contains(".onKeyPress(keys: [.tab], action: captionTab)"))
        XCTAssertTrue(fields.contains("!press.modifiers.contains(.option), !press.modifiers.contains(.control)"))
    }

    func testTheCopyNoteWording() {
        XCTAssertEqual(InfoFieldsView.copyNote(count: 1), "A virtual copy shares the original's info: changes go to the original.")
        XCTAssertEqual(InfoFieldsView.copyNote(count: 3), "3 virtual copies share the original's info: changes go to the original.")
    }

    func testTheShortcutRowMentionsBothContexts() {
        let row = KeyboardShortcutCatalog.sections.flatMap(\.entries).first { $0.keys == "\u{2318}I" }
        XCTAssertTrue(row?.action.contains("Library") ?? false)
        XCTAssertTrue(row?.action.contains("Editor") ?? false)
    }
}
