import XCTest
@testable import PhotoApp

/// Create and rename go through the ordered write chain (D94): a quick create then rename lands in order, the new row is visible at
/// once, and the new collection is never selected.
@MainActor
final class CatalogModelCollectionNamingTests: XCTestCase {
    private var suiteName = ""

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() async throws -> (CatalogModel, CatalogDatabase) {
        let db = try CatalogDatabase(inMemory: true)
        suiteName = "CatalogModelCollectionNamingTests-\(UUID().uuidString)"
        let model = CatalogModel(database: db, defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        await model.refresh()
        return (model, db)
    }

    private func waitUntil(_ what: String, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    func testCreateReturnsTheCollectionShowsItAtOnceAndDoesNotSelectIt() async throws {
        let (model, db) = try await makeModel()
        let created = await model.createCollection(name: "  Trips  ")
        XCTAssertEqual(created?.name, "Trips")
        XCTAssertEqual(model.collections.map(\.name), ["Trips"], "visible before the refresh")
        XCTAssertEqual(model.selectedFilter, .allPhotos, "creating never moves the selection")
        try await waitUntil("the row in the database") { try await db.allCollections().map(\.name) == ["Trips"] }
    }

    func testEmptyNameCreatesNothing() async throws {
        let (model, db) = try await makeModel()
        let created = await model.createCollection(name: "   ")
        XCTAssertNil(created)
        let all = try await db.allCollections()
        XCTAssertTrue(all.isEmpty)
    }

    func testCreateThenQuickRenameLandsInOrder() async throws {
        let (model, db) = try await makeModel()
        let made = await model.createCollection(name: "Trips")
        let created = try XCTUnwrap(made)
        model.renameCollection(created, to: "Vacation")
        XCTAssertEqual(model.collections.map(\.name), ["Vacation"], "local name first")
        try await waitUntil("the stored name") { try await db.allCollections().map(\.name) == ["Vacation"] }
        try await waitUntil("the published list") { model.collections.map(\.name) == ["Vacation"] }
    }

    func testRenameToAnEmptyNameChangesNothing() async throws {
        let (model, _) = try await makeModel()
        let made = await model.createCollection(name: "Trips")
        let created = try XCTUnwrap(made)
        model.renameCollection(created, to: "  ")
        XCTAssertEqual(model.collections.map(\.name), ["Trips"])
    }
}

/// The sidebar keeps no text-field alert and handles Esc.
final class SidebarNamingSourcePinTests: XCTestCase {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI/CollectionSidebarView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testNoNameEntryAlertRemains() throws {
        let text = try source()
        XCTAssertFalse(text.contains("TextField(\"Name\", text: $newCollectionName)"))
        XCTAssertFalse(text.contains("\"New Collection\", isPresented"))
        XCTAssertFalse(text.contains("\"Rename Collection\""))
        XCTAssertFalse(text.contains("\"Rename Smart Collection\""))
    }

    /// Live finding 2026-11-26: after a refused name, Return took keyboard focus off the field, so Esc never reached it. The refocus must
    /// happen on the next run-loop pass, and only while that edit is still the open one.
    func testARefusedNameRefocusesTheFieldAfterTheSubmitReturns() throws {
        let text = try source()
        XCTAssertTrue(text.contains("DispatchQueue.main.async {\n                    guard editing == edit else { return }\n                    focusedEdit = edit"))
    }

    func testEscapeAndReturnArePresent() throws {
        let text = try source()
        XCTAssertTrue(text.contains(".onExitCommand"))
        XCTAssertTrue(text.contains(".onSubmit"))
    }
}
