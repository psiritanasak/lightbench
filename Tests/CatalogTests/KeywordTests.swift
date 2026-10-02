import GRDB
import XCTest
@testable import PhotoApp

final class KeywordNameTests: XCTestCase {
    func testNormalizeTrimsCollapsesAndRejectsEmpty() {
        XCTAssertEqual(KeywordName.normalize("  Blue   Sky \t"), "Blue Sky")
        XCTAssertEqual(KeywordName.normalize("a\nb"), "a b")
        XCTAssertNil(KeywordName.normalize("   \t\n"))
        XCTAssertNil(KeywordName.normalize(""))
        XCTAssertNil(KeywordName.normalize("\u{0007}\u{0000}"), "control characters alone leave nothing")
        XCTAssertEqual(KeywordName.normalize("ab\u{0007}c"), "abc")
    }

    func testNormalizeProducesNFCAndKeepsUnicode() {
        let decomposed = "Cafe\u{0301}"
        XCTAssertEqual(KeywordName.normalize(decomposed), "Caf\u{00E9}")
        XCTAssertEqual(KeywordName.normalize("日本 旅行"), "日本 旅行")
        XCTAssertEqual(KeywordName.normalize("🌅 sunrise"), "🌅 sunrise")
    }

    /// Format characters (Cf) carry meaning and must survive; only true controls and the meaningless invisibles go.
    func testNormalizeKeepsMeaningfulFormatCharacters() throws {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"            // ZWJ family emoji
        XCTAssertEqual(KeywordName.normalize(family)?.unicodeScalars.count, 5)
        let england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        let scotland = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
        let e = try XCTUnwrap(KeywordName.normalize(england)), s = try XCTUnwrap(KeywordName.normalize(scotland))
        XCTAssertNotEqual(Array(KeywordName.key(for: e).unicodeScalars), Array(KeywordName.key(for: s).unicodeScalars),
                          "different subdivision flags must not merge")
        XCTAssertTrue(try XCTUnwrap(KeywordName.normalize("\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}")).unicodeScalars.contains("\u{200C}"), "Persian ZWNJ kept")
        XCTAssertEqual(KeywordName.normalize("s\u{200B}k\u{2060}y\u{FEFF}"), "sky", "zero-width space/word joiner/BOM carry no meaning")
    }

    func testNormalizeIsNFCAfterFilteringAndBoundsTheByteSize() {
        let beforeFilter = "e\u{0007}\u{0301}"                   // control char between a base and its combining mark
        let out = KeywordName.normalize(beforeFilter)
        XCTAssertEqual(Array(out?.unicodeScalars ?? "".unicodeScalars), [UnicodeScalar(0x00E9)!], "composed AFTER the control char is dropped")
        let heavy = "a" + String(repeating: "\u{0301}", count: 5000)
        // One grapheme cluster far over the byte cap is dropped whole, leaving nothing.
        XCTAssertNil(KeywordName.normalize(heavy))
        let words = String(repeating: "ab ", count: 200)
        XCTAssertLessThanOrEqual(KeywordName.normalize(words)?.utf8.count ?? .max, KeywordName.maximumBytes)
    }

    func testNormalizeCapsLengthWithoutLeavingTrailingSpace() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(KeywordName.normalize(long)?.count, KeywordName.maximumLength)
        let spaced = String(repeating: "a", count: KeywordName.maximumLength - 1) + " " + String(repeating: "b", count: 10)
        XCTAssertFalse(KeywordName.normalize(spaced)?.hasSuffix(" ") ?? true)
    }

    func testKeyIsCaseAndNormalizationInsensitiveButNotDiacriticInsensitive() {
        XCTAssertEqual(KeywordName.key(for: "Sky"), KeywordName.key(for: "sKY"))
        XCTAssertEqual(KeywordName.key(for: "Éclair"), KeywordName.key(for: "éclair"), "SQLite NOCASE would miss this")
        // Swift `==` treats canonically equivalent strings as equal, so compare the BYTES the database would unique on.
        XCTAssertEqual(Array(KeywordName.key(for: "Cafe\u{0301}").utf8), Array(KeywordName.key(for: "Caf\u{00E9}").utf8))
        XCTAssertNotEqual(KeywordName.key(for: "resume"), KeywordName.key(for: "résumé"))
    }

    func testParseSplitsOnCommasSemicolonsAndNewlinesDedupesAndCaps() {
        XCTAssertEqual(KeywordName.parse("Sky, Test Trip ;; sky\nBeach,,  "), ["Sky", "Test Trip", "Beach"])
        XCTAssertEqual(KeywordName.parse(" , ; "), [])
        let many = (0..<50).map { "k\($0)" }.joined(separator: ",")
        XCTAssertEqual(KeywordName.parse(many).count, KeywordName.maximumPerEntry)
        XCTAssertEqual(KeywordName.parse("A,a,A"), ["A"], "first spelling wins")
    }
}

final class KeywordDatabaseTests: XCTestCase {
    private func makeDatabase(photos count: Int = 3) async throws -> (CatalogDatabase, [Int64]) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (0..<count).map { URL(fileURLWithPath: "/tmp/k\($0).jpg") })
        let ids = try await db.allPhotos().compactMap(\.id).sorted()
        return (db, ids)
    }

    func testAddCreatesKeywordsAndLinksEveryPhoto() async throws {
        let (db, ids) = try await makeDatabase()
        let result = try await db.addKeywords(["Sky", "Test Trip"], to: Array(ids.prefix(2)))
        XCTAssertEqual(result.map(\.name), ["Sky", "Test Trip"])
        let keywords = try await db.allKeywords()
        let links = try await db.allKeywordLinks()
        XCTAssertEqual(Set(keywords.map(\.name)), ["Sky", "Test Trip"])
        XCTAssertEqual(links.count, 4)
        XCTAssertEqual(Set(links.map(\.photoId)), Set(ids.prefix(2)))
    }

    func testAddIsIdempotentAndReusesTheExistingSpellingAcrossCases() async throws {
        let (db, ids) = try await makeDatabase()
        try await db.addKeywords(["Éclair"], to: [ids[0]])
        try await db.addKeywords(["éclair", "ÉCLAIR", "Éclair"], to: [ids[0], ids[1]])
        let keywords = try await db.allKeywords()
        XCTAssertEqual(keywords.map(\.name), ["Éclair"], "one keyword, the first spelling kept (NOCASE alone would have made two)")
        let links = try await db.allKeywordLinks()
        XCTAssertEqual(links.count, 2)
    }

    func testAddNormalizesAndIgnoresBlankNames() async throws {
        let (db, ids) = try await makeDatabase()
        let result = try await db.addKeywords(["  Blue   Sky ", "   ", "blue sky"], to: [ids[0]])
        XCTAssertEqual(result.map(\.name), ["Blue Sky"])
        let count = try await db.allKeywords().count
        XCTAssertEqual(count, 1)
    }

    func testAddSkipsStalePhotoIDsInsteadOfAbortingTheBatch() async throws {
        let (db, ids) = try await makeDatabase(photos: 2)
        try await db.addKeywords(["Sky"], to: [ids[0], 9_999, ids[1]])
        let links = try await db.allKeywordLinks()
        XCTAssertEqual(Set(links.map(\.photoId)), Set(ids), "the two real photos were tagged; the stale id was skipped")
    }

    func testRemoveDetachesOnlyTheGivenPhotosAndKeepsTheKeyword() async throws {
        let (db, ids) = try await makeDatabase()
        let sky = try await db.addKeywords(["Sky"], to: ids)[0]
        try await db.removeKeyword(id: try XCTUnwrap(sky.id), from: [ids[0]])
        let links = try await db.allKeywordLinks()
        XCTAssertEqual(Set(links.map(\.photoId)), Set(ids.dropFirst()))
        try await db.removeKeyword(id: try XCTUnwrap(sky.id), from: Array(ids.dropFirst()))
        let afterAll = try await db.allKeywordLinks().count
        let keywordsLeft = try await db.allKeywords().count
        XCTAssertEqual(afterAll, 0)
        XCTAssertEqual(keywordsLeft, 1, "an unused keyword stays until it is deleted explicitly")
    }

    func testAddAndRemoveWorkAcrossTheIDChunkBoundary() async throws {
        let (db, ids) = try await makeDatabase(photos: 1203)
        let sky = try await db.addKeywords(["Sky"], to: ids)[0]
        let linked = try await db.allKeywordLinks().count
        XCTAssertEqual(linked, 1203)
        try await db.removeKeyword(id: try XCTUnwrap(sky.id), from: ids)
        let left = try await db.allKeywordLinks().count
        XCTAssertEqual(left, 0)
    }

    func testDeleteKeywordCascadesItsLinksOnly() async throws {
        let (db, ids) = try await makeDatabase()
        let made = try await db.addKeywords(["Sky", "Sea"], to: ids)
        try await db.deleteKeyword(id: try XCTUnwrap(made[0].id))
        let keywords = try await db.allKeywords()
        let links = try await db.allKeywordLinks()
        XCTAssertEqual(keywords.map(\.name), ["Sea"])
        XCTAssertEqual(links.count, ids.count)
        XCTAssertTrue(links.allSatisfy { $0.keywordId == made[1].id })
    }

    func testDeletingAPhotoRemovesItsLinksButNotTheKeyword() async throws {
        let (db, ids) = try await makeDatabase()
        try await db.addKeywords(["Sky"], to: ids)
        try await db.deletePhoto(id: ids[0])
        let links = try await db.allKeywordLinks()
        let keywords = try await db.allKeywords()
        XCTAssertEqual(Set(links.map(\.photoId)), Set(ids.dropFirst()))
        XCTAssertEqual(keywords.count, 1)
    }

    /// A catalog created before Migration 010 (through 009, with an existing photo) upgrades in place and gains
    /// the empty keyword tables.
    func testMigration010AddsKeywordTablesToAnExistingCatalog() async throws {
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
            try migrator.migrate(queue)
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO photo (path, filename, importedAt, rating, flagStatus, colorLabel) VALUES ('/tmp/old.jpg', 'old.jpg', '2026-01-01 00:00:00', 3, 0, 0)")
            }
        }
        let db = try CatalogDatabase(path: path)
        let photos = try await db.allPhotos()
        let photoID = try XCTUnwrap(photos.first?.id)
        let emptyKeywords = try await db.allKeywords().count
        XCTAssertEqual(emptyKeywords, 0)
        try await db.addKeywords(["Old"], to: [photoID])
        let links = try await db.allKeywordLinks().count
        XCTAssertEqual(links, 1)
    }
}
