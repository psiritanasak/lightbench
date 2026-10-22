import GRDB
import XCTest
@testable import PhotoApp

/// The pure text rules (`InfoText`) and the Edit Info sheet's draft logic.
final class PhotoInfoTests: XCTestCase {
    private func n(_ raw: String, _ field: InfoText.Field = .title) -> String { InfoText.normalize(raw, field: field) }

    // MARK: InfoText

    func testControlCharactersAndInvisiblesAreStrippedButZWJAndZWNJAreKept() {
        XCTAssertEqual(n("a\u{0007}b\u{200B}c\u{2060}d\u{FEFF}e"), "abcde")
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(n("x \(family)"), "x \(family)", "ZWJ holds an emoji family together")
        XCTAssertEqual(n("می\u{200C}خواهم"), "می\u{200C}خواهم", "ZWNJ is part of Persian spelling")
    }

    func testTextIsNFCNormalizedAndTrimmed() {
        XCTAssertEqual(n("  e\u{0301}  "), "\u{00E9}")
        XCTAssertEqual(n("   \n\t "), "")
    }

    func testSingleLineFieldsCollapseAllWhitespaceIncludingLineBreaks() {
        XCTAssertEqual(n("a \n\n  b\tc\r\nd"), "a b c d")
        XCTAssertEqual(n("a\nb", .copyright), "a b")
        XCTAssertEqual(n("a\nb", .creator), "a b")
    }

    func testCaptionKeepsLineBreaksCollapsesBlankRunsAndTrimsEnds() {
        XCTAssertEqual(n("  one  two \r\n\r\n\r\n\r\nthree\rfour\n  ", .caption), "one two\n\nthree\nfour")
    }

    func testCharacterCapsPerField() {
        XCTAssertEqual(InfoText.maximumLength(.title), 256)
        XCTAssertEqual(InfoText.maximumLength(.creator), 256)
        XCTAssertEqual(InfoText.maximumLength(.copyright), 512)
        XCTAssertEqual(InfoText.maximumLength(.caption), 2000)
        XCTAssertEqual(n(String(repeating: "a", count: 300), .title).count, 256)
        XCTAssertEqual(n(String(repeating: "a", count: 300), .creator).count, 256)
        XCTAssertEqual(n(String(repeating: "a", count: 600), .copyright).count, 512)
        XCTAssertEqual(n(String(repeating: "a", count: 2100), .caption).count, 2000)
    }

    func testByteCapBoundsAClusterHeavyValue() {
        // One cluster with many combining marks: the character count stays small, the byte size does not.
        let heavy = String(repeating: "a" + String(repeating: "\u{0301}\u{0316}", count: 60), count: 40)
        let cleaned = n(heavy, .title)
        XCTAssertLessThanOrEqual(cleaned.utf8.count, InfoText.maximumBytes(.title))
        XCTAssertFalse(cleaned.isEmpty)
    }

    func testApplyingTouchesOnlyTheNamedFields() {
        let start = PhotoInfo(title: "T", caption: "C", creator: "A", copyright: "R")
        let result = start.applying(PhotoInfo(title: "  New  ", caption: "x", creator: "y", copyright: "z"), fields: [.title, .copyright])
        XCTAssertEqual(result, PhotoInfo(title: "New", caption: "C", creator: "A", copyright: "z"))
    }

    // MARK: InfoSheetDraft

    func testAgreeingValuesAreShownAndDifferingOnesAreMixed() {
        let draft = InfoSheetDraft(infos: [PhotoInfo(title: "Same", creator: "A"), PhotoInfo(title: "Same", creator: "B")])
        XCTAssertEqual(draft.text[.title], "Same")
        XCTAssertFalse(draft.isMixed(.title))
        XCTAssertTrue(draft.isMixed(.creator))
        XCTAssertEqual(draft.text[.creator], "")
        XCTAssertFalse(draft.hasChanges)
    }

    func testOnlyTouchedFieldsAreInTheChange() {
        var draft = InfoSheetDraft(infos: [PhotoInfo(title: "A", caption: "one"), PhotoInfo(title: "B", caption: "one")])
        XCTAssertTrue(draft.change.fields.isEmpty, "an untouched sheet writes nothing, mixed title included")
        draft.edit(.copyright, to: "(c) me")
        let change = draft.change
        XCTAssertEqual(change.fields, [.copyright])
        XCTAssertEqual(change.info.copyright, "(c) me")
    }

    func testTypingBackTheStartingTextUntouchesAField() {
        var draft = InfoSheetDraft(infos: [PhotoInfo(title: "A")])
        draft.edit(.title, to: "AB")
        XCTAssertTrue(draft.hasChanges)
        draft.edit(.title, to: "A")
        XCTAssertFalse(draft.hasChanges)
    }

    func testClearingAMixedFieldWritesAnEmptyValue() {
        var draft = InfoSheetDraft(infos: [PhotoInfo(title: "A"), PhotoInfo(title: "B")])
        draft.clear(.title)
        let change = draft.change
        XCTAssertEqual(change.fields, [.title])
        XCTAssertEqual(change.info.title, "")
    }

    func testClearingASharedFieldByEmptyingTheText() {
        var draft = InfoSheetDraft(infos: [PhotoInfo(title: "A"), PhotoInfo(title: "A")])
        draft.edit(.title, to: "")
        XCTAssertEqual(draft.change.fields, [.title])
    }
}

/// `photo_info`: round trip, cascade, migration, backup, virtual copies.
final class PhotoInfoDatabaseTests: XCTestCase {
    private func makeDB() async throws -> (CatalogDatabase, [Int64]) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: ["/p/a.jpg", "/p/b.jpg", "/p/c.jpg"].map { URL(fileURLWithPath: $0) })
        return (db, try await db.allPhotos().compactMap(\.id))
    }

    func testRoundTripNormalizesAndStoresOnlyTouchedFields() async throws {
        let (db, ids) = try await makeDB()
        try await db.setInfo(PhotoInfo(title: "  Sunset ", caption: "Line1\r\nLine2", creator: "Me", copyright: "(c)"), forPhotoIDs: [ids[0]], fields: .all)
        var all = try await db.allInfo()
        XCTAssertEqual(all[ids[0]], PhotoInfo(title: "Sunset", caption: "Line1\nLine2", creator: "Me", copyright: "(c)"))
        XCTAssertNil(all[ids[1]])
        try await db.setInfo(PhotoInfo(title: "Dusk"), forPhotoIDs: [ids[0], ids[1]], fields: .title)
        all = try await db.allInfo()
        XCTAssertEqual(all[ids[0]]?.title, "Dusk")
        XCTAssertEqual(all[ids[0]]?.creator, "Me", "fields not named keep their value")
        XCTAssertEqual(all[ids[1]], PhotoInfo(title: "Dusk"), "a photo with no row gets one with only the named field")
    }

    func testARowWithAllFieldsEmptyIsDeleted() async throws {
        let (db, ids) = try await makeDB()
        try await db.setInfo(PhotoInfo(title: "T", creator: "C"), forPhotoIDs: [ids[0]], fields: .all)
        try await db.setInfo(PhotoInfo(title: "  "), forPhotoIDs: [ids[0]], fields: .title)
        var all = try await db.allInfo()
        XCTAssertEqual(all[ids[0]], PhotoInfo(creator: "C"))
        try await db.setInfo(PhotoInfo(), forPhotoIDs: [ids[0]], fields: .creator)
        all = try await db.allInfo()
        XCTAssertNil(all[ids[0]])
        let rows = try await db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM photo_info") }
        XCTAssertEqual(rows, 0, "the row itself is gone, not just empty")
        try await db.setInfo(PhotoInfo(), forPhotoIDs: [ids[1]], fields: .all)
        let after = try await db.allInfo()
        XCTAssertTrue(after.isEmpty, "clearing a photo that has no row creates no row")
    }

    func testStaleIdsAreSkippedAndAnEmptyFieldSetWritesNothing() async throws {
        let (db, ids) = try await makeDB()
        try await db.setInfo(PhotoInfo(title: "X"), forPhotoIDs: [9999, ids[2]], fields: .title)
        var all = try await db.allInfo()
        XCTAssertEqual(Set(all.keys), [ids[2]])
        try await db.setInfo(PhotoInfo(title: "Y"), forPhotoIDs: [ids[0]], fields: [])
        all = try await db.allInfo()
        XCTAssertNil(all[ids[0]])
    }

    func testMoreThanOneChunkOfIdsIsWritten() async throws {
        let db = try CatalogDatabase(inMemory: true)
        let urls = (0..<1100).map { URL(fileURLWithPath: "/many/\($0).jpg") }
        _ = try await db.importPhotos(at: urls)
        let ids = try await db.allPhotos().compactMap(\.id)
        try await db.setInfo(PhotoInfo(copyright: "(c)"), forPhotoIDs: ids, fields: .copyright)
        let all = try await db.allInfo()
        XCTAssertEqual(all.count, 1100)
    }

    func testInfoIsRemovedWithItsPhoto() async throws {
        let (db, ids) = try await makeDB()
        try await db.setInfo(PhotoInfo(title: "Gone"), forPhotoIDs: ids, fields: .title)
        try await db.deletePhoto(id: ids[0])
        let all = try await db.allInfo()
        XCTAssertNil(all[ids[0]])
        XCTAssertEqual(all.count, 2)
    }

    func testAVirtualCopyResolvesToItsMasterAndNeverGetsARow() async throws {
        let (db, ids) = try await makeDB()
        let all0 = try await db.allPhotos()
        let master = try XCTUnwrap(all0.first { $0.id == ids[0] })
        let copy = try await db.createVirtualCopy(of: master, versionKey: "aaaaaaaa")
        let copyID = try XCTUnwrap(copy.id)
        try await db.setInfo(PhotoInfo(title: "Shared"), forPhotoIDs: [copyID], fields: .title)
        let all = try await db.allInfo()
        XCTAssertEqual(all[ids[0]]?.title, "Shared", "the master got it")
        XCTAssertNil(all[copyID], "no row for the copy")
        try await db.setInfo(PhotoInfo(creator: "Me"), forPhotoIDs: [copyID, ids[0]], fields: .creator)
        let rows = try await db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM photo_info") }
        XCTAssertEqual(rows, 1, "a copy and its master together are one write")
    }

    func testMigration016AddsTheTableToAPopulatedPre016Catalog() async throws {
        let path = NSTemporaryDirectory() + "catalog-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let queue = try DatabaseQueue(path: path)
            var migrator = DatabaseMigrator()
            Migration001Initial.register(in: &migrator)
            Migration002RatingsAndFlags.register(in: &migrator)
            Migration003Collections.register(in: &migrator)
            Migration004FolderCollections.register(in: &migrator)
            Migration005Presets.register(in: &migrator)
            Migration006CollectionFolderPathIndex.register(in: &migrator)
            Migration007PickRejectFlags.register(in: &migrator)
            Migration008ColorLabels.register(in: &migrator)
            Migration009RenameLog.register(in: &migrator)
            Migration010Keywords.register(in: &migrator)
            Migration011SmartCollections.register(in: &migrator)
            Migration012PhotoFingerprint.register(in: &migrator)
            Migration013Faces.register(in: &migrator)
            Migration014PhotoMetadata.register(in: &migrator)
            Migration015VirtualCopies.register(in: &migrator)
            try migrator.migrate(queue)
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO photo (path, filename, importedAt, rating, flagStatus, colorLabel) VALUES ('/tmp/old.jpg', 'old.jpg', '2026-01-01 00:00:00', 3, 0, 0)")
            }
        }
        let db = try CatalogDatabase(path: path)
        let photos = try await db.allPhotos()
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.rating, 3)
        let empty = try await db.allInfo()
        XCTAssertTrue(empty.isEmpty)
        let id = try XCTUnwrap(photos.first?.id)
        try await db.setInfo(PhotoInfo(title: "Old"), forPhotoIDs: [id], fields: .title)
        let stored = try await db.allInfo()
        XCTAssertEqual(stored[id]?.title, "Old")
    }

    func testABackupKeepsTheInfo() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("info-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("live.sqlite")
        let db = try CatalogDatabase(path: live.path)
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let all0 = try await db.allPhotos()
        let id = try XCTUnwrap(all0.first?.id)
        try await db.setInfo(PhotoInfo(title: "Kept", caption: "line1\nline2", copyright: "(c)"), forPhotoIDs: [id], fields: .all)
        let backup = dir.appendingPathComponent("backup.sqlite")
        _ = try await db.backUp(to: backup)
        let reopened = try CatalogDatabase(path: backup.path)
        let all = try await reopened.allInfo()
        XCTAssertEqual(all[id], PhotoInfo(title: "Kept", caption: "line1\nline2", creator: "", copyright: "(c)"))
    }
}

/// `CatalogModel`'s info state, selection semantics and search wiring.
@MainActor
final class PhotoInfoModelTests: XCTestCase {
    private func makeModel() async throws -> (CatalogModel, CatalogDatabase, [Photo]) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: ["/p/a.jpg", "/p/b.jpg"].map { URL(fileURLWithPath: $0) })
        let a0 = try await db.photo(atPath: "/p/a.jpg")
        let a = try XCTUnwrap(a0)
        _ = try await db.createVirtualCopy(of: a, versionKey: "aaaaaaaa")
        let model = CatalogModel(database: db, defaults: UserDefaults(suiteName: "PhotoInfoModelTests-\(UUID().uuidString)") ?? .standard)
        await model.refresh()
        return (model, db, model.photos)
    }

    private func waitUntil(_ what: String, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    func testBeginEditingInfoSnapshotsTheSelectionIncludingFilterHiddenPhotos() async throws {
        let (model, _, photos) = try await makeModel()
        model.beginEditingInfo()
        XCTAssertNil(model.infoSheetPhotoIDs, "no selection: no sheet")
        let ids = photos.compactMap(\.id)
        for photo in photos { model.toggleSelection(of: photo) }
        model.searchText = "zzz-matches-nothing"
        XCTAssertTrue(model.displayedPhotos.isEmpty)
        model.beginEditingInfo()
        XCTAssertEqual(Set(model.infoSheetPhotoIDs ?? []), Set(ids), "hidden-by-filter photos are edited too")
        XCTAssertTrue(model.toolSheetIsBusy, "an open info sheet blocks batch rename")
    }

    func testSettingInfoOnACopyEditsTheMasterAndTheCopyDisplaysIt() async throws {
        let (model, db, photos) = try await makeModel()
        let copy = try XCTUnwrap(photos.first { $0.isVirtualCopy })
        let master = try XCTUnwrap(photos.first { $0.id == copy.masterId })
        model.setInfo(PhotoInfo(title: "Shared"), fields: .title, for: [copy.id ?? -1])
        XCTAssertEqual(model.info(for: copy).title, "Shared")
        XCTAssertEqual(model.info(for: master).title, "Shared")
        XCTAssertNil(model.infoByPhotoID[copy.id ?? -1], "no entry for the copy")
        try await waitUntil("the master's row is written") { try await db.allInfo()[master.id ?? -1]?.title == "Shared" }
        let stored = try await db.allInfo()
        XCTAssertEqual(stored.count, 1)
    }

    func testInfoSurvivesARefreshAndIsDroppedWithItsPhoto() async throws {
        let (model, db, photos) = try await makeModel()
        let other = try XCTUnwrap(photos.first { $0.filename == "b.jpg" })
        model.setInfo(PhotoInfo(copyright: "(c)"), fields: .copyright, for: [other.id ?? -1])
        try await waitUntil("written") { try await db.allInfo().count == 1 }
        await model.refresh()
        XCTAssertEqual(model.info(for: other).copyright, "(c)")
        model.removePhoto(other)
        XCTAssertNil(model.infoByPhotoID[other.id ?? -1])
    }

    func testSearchFindsTitleCaptionCreatorAndCopyrightIncludingOnACopy() async throws {
        let (model, _, photos) = try await makeModel()
        let copy = try XCTUnwrap(photos.first { $0.isVirtualCopy })
        model.setInfo(PhotoInfo(title: "Golden Hour", caption: "On the pier", creator: "Smith", copyright: "2026 Smith"),
                      fields: .all, for: [copy.id ?? -1])
        model.searchText = "title:golden"
        XCTAssertEqual(model.displayedPhotos.count, 2, "the master and its copy")
        model.searchText = "pier"
        XCTAssertEqual(model.displayedPhotos.count, 2, "plain words match the caption")
        model.searchText = "copyright:2026 creator:smith"
        XCTAssertEqual(model.displayedPhotos.count, 2)
        model.searchText = "title:nothing"
        XCTAssertTrue(model.displayedPhotos.isEmpty)
    }
}

/// The search additions.
final class PhotoInfoSearchTests: XCTestCase {
    private func photo(_ name: String = "p.jpg") -> Photo {
        Photo(id: 1, path: "/tmp/\(name)", filename: name, fileSize: 1, importedAt: Date(timeIntervalSince1970: 0))
    }

    private func matches(_ query: String, _ info: PhotoInfo?) -> Bool {
        SearchQuery(parsing: query).matches(photo(), metadata: nil, keywordNames: [], info: info)
    }

    private let info = PhotoInfo(title: "Golden Hour", caption: "Pier at dusk", creator: "J. Smith", copyright: "(c) 2026 Smith")

    func testEachInfoFieldIsSearchableAndOnlyThatField() {
        XCTAssertTrue(matches("title:golden", info))
        XCTAssertFalse(matches("title:pier", info))
        XCTAssertTrue(matches("caption:\"at dusk\"", info))
        XCTAssertFalse(matches("caption:golden", info))
        XCTAssertTrue(matches("creator:smith", info))
        XCTAssertFalse(matches("creator:2026", info))
        XCTAssertTrue(matches("copyright:2026", info))
        XCTAssertFalse(matches("copyright:golden", info))
    }

    func testInfoFieldsNeverMatchAPhotoWithoutInfo() {
        for field in ["title", "caption", "creator", "copyright"] {
            XCTAssertFalse(matches("\(field):a", nil), field)
            XCTAssertFalse(matches("\(field):a", PhotoInfo()), field)
        }
    }

    func testPlainWordsMatchTitleAndCaptionButNotCreatorOrCopyright() {
        XCTAssertTrue(matches("golden", info))
        XCTAssertTrue(matches("pier", info))
        XCTAssertFalse(matches("smith", info))
        XCTAssertFalse(matches("2026", info))
        XCTAssertFalse(matches("golden", nil))
    }

    func testFieldWithNoValueYetIsIgnored() {
        XCTAssertTrue(matches("title:", nil))
    }

    func testSearchHelpHasAnExampleForEveryInfoField() {
        for field in ["title", "caption", "creator", "copyright"] {
            let row = SearchHelp.rows.first { $0.field == field }
            XCTAssertNotNil(row, field)
            XCTAssertEqual(SearchQuery(parsing: row?.example ?? "").terms.count, 1, field)
            XCTAssertTrue(SearchQuery(parsing: row?.example ?? "").invalidTerms.isEmpty)
        }
    }

    func testTheFilterAndSmartCollectionForwardInfo() {
        let p = photo()
        let kept = LibraryFilterSort.apply(
            to: [p], sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "title:golden",
            infoByPhotoID: [1: info]
        )
        XCTAssertEqual(kept.count, 1)
        XCTAssertTrue(LibraryFilterSort.apply(to: [p], sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "title:golden").isEmpty)
        let criteria = SmartCollectionCriteria(searchQuery: "creator:smith")
        XCTAssertEqual(criteria.apply(to: [p], keywords: [], keywordIDsByPhotoID: [:], infoByPhotoID: [1: info]).count, 1)
        XCTAssertTrue(criteria.apply(to: [p], keywords: [], keywordIDsByPhotoID: [:]).isEmpty)
    }
}

/// Source-scan wiring (the XMP busy-flag test's pattern): menus, sheets and the shortcut catalog.
final class PhotoInfoWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// (The info modifier's own line is exempt: it IS the info sheet.)
    func testEveryKeywordSheetGuardAlsoNamesTheInfoSheet() throws {
        for path in ["Sources/App/PhotoAppApp.swift", "Sources/UI/DuplicatesSheetView.swift"] {
            for line in try source(path).split(separator: "\n") where line.contains("catalog.keywordSheetPhotoIDs != nil") && !line.contains("InfoSheetModifier(") {
                XCTAssertTrue(line.contains("catalog.infoSheetPhotoIDs != nil"), "\(path): \(line)")
            }
        }
    }

    func testTheInfoSheetAndMenuItemsAreWired() throws {
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("Button(\"Edit Info…\")"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"i\", modifiers: [.command])"))
        let sheets = try source("Sources/UI/DuplicatesSheetView.swift")
        XCTAssertTrue(sheets.contains("InfoSheetModifier("))
        XCTAssertTrue(sheets.contains("KeywordSheetModifier(catalog: catalog, blocked: blocked || catalog.infoSheetPhotoIDs != nil"),
                      "the keyword sheet must not open over the info sheet")
        XCTAssertTrue(try source("Sources/UI/ContentView.swift").contains("catalog.infoSheetRequested = true"))
        let catalog = try source("Sources/UI/CatalogModel.swift")
        XCTAssertTrue(catalog.contains("keywordSheetPhotoIDs != nil || infoSheetPhotoIDs != nil"), "batch rename must see an open info sheet")
    }

    func testTheShortcutIsListed() {
        let all = KeyboardShortcutCatalog.sections.flatMap(\.entries)
        XCTAssertTrue(all.contains { $0.keys == "\u{2318}I" })
    }
}
