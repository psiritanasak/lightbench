import SwiftUI
import XCTest
@testable import PhotoApp

/// `FacesModel` end to end with an injected detector (no Vision, no files): scan -> grouping -> people, then the corrections the People
/// sheet offers. Prints are unit vectors in separate planes so "same person" / "different person" is exact.
@MainActor
final class FacesModelTests: XCTestCase {
    private var db: CatalogDatabase!
    private var photos: [Photo] = []
    private var model: FacesModel!
    private var peopleChangedCount = 0

    nonisolated private static func print(plane: Int, angle: Double = 0) -> Data {
        var floats = [Float](repeating: 0, count: FeaturePrintVector.elementCount)
        floats[plane * 2] = Float(cos(angle))
        floats[plane * 2 + 1] = Float(sin(angle))
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Photos 0,1 -> person A (plane 0); photos 2,3 -> person B (plane 1); photo 4 has no face.
    private func setUpModel() async throws {
        db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (0..<5).map { URL(fileURLWithPath: "/tmp/fm\($0).jpg") })
        photos = try await db.allPhotos()
        let planes: [String: (Int, Double)] = ["/tmp/fm0.jpg": (0, 0), "/tmp/fm1.jpg": (0, 0.05), "/tmp/fm2.jpg": (1, 0), "/tmp/fm3.jpg": (1, 0.05)]
        model = FacesModel()
        model.database = db
        peopleChangedCount = 0
        model.onPeopleChanged = { [unowned self] in peopleChangedCount += 1 }
        model.scannerEnvironment = FaceScanner.Environment(
            stat: { _ in (1000, 1) },
            detect: { path in
                guard let (plane, angle) = planes[path] else { return [] }
                return [FaceDetector.DetectedFace(x: 0.1, y: 0.1, w: 0.3, h: 0.3, quality: 0.6, featurePrint: Self.print(plane: plane, angle: angle), crop: Data([1, 2]))]
            })
    }

    private func scanAndWait() async throws {
        model.scanAndGroup(photos: photos, database: db)
        for _ in 0..<400 where model.isWorking { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertFalse(model.isWorking, "the scan finished")
    }

    func testScanGroupsTheFacesIntoTwoPeopleAndReports() async throws {
        try await setUpModel()
        try await scanAndWait()
        XCTAssertEqual(model.people.count, 2)
        XCTAssertEqual(model.people.map(\.faceCount).sorted(), [2, 2])
        XCTAssertEqual(model.unsortedCount, 0)
        XCTAssertNotNil(model.summary)
        XCTAssertGreaterThan(peopleChangedCount, 0, "the catalog is told to refresh its people")
    }

    func testAScanOfNoPhotosSaysSoAndStartsNothing() async throws {
        try await setUpModel()
        model.scanAndGroup(photos: [], database: db)
        XCTAssertFalse(model.isWorking)
        XCTAssertNotNil(model.statusMessage)
    }

    func testRenameThenDuplicateNameIsOfferedAsMergeAndMergeCombinesThePeople() async throws {
        try await setUpModel()
        try await scanAndWait()
        let ids = model.people.map(\.id)
        let first = await model.rename(ids[0], to: "Ann")
        XCTAssertEqual(first, .renamed)
        let second = await model.rename(ids[1], to: "ann")
        XCTAssertEqual(second, .duplicate(existingID: ids[0]), "names are unique case-insensitively")
        await model.merge(ids[1], into: ids[0])
        XCTAssertEqual(model.people.count, 1)
        XCTAssertEqual(model.people.first?.faceCount, 4)
        XCTAssertEqual(model.people.first?.name, "Ann")
    }

    func testHideKeepsThePersonButMarksIt() async throws {
        try await setUpModel()
        try await scanAndWait()
        let id = try XCTUnwrap(model.people.first?.id)
        await model.setHidden(id, true)
        XCTAssertEqual(model.people.first { $0.id == id }?.isHidden, true)
        await model.setHidden(id, false)
        XCTAssertEqual(model.people.first { $0.id == id }?.isHidden, false)
    }

    func testDeleteReleasesTheFacesAsUnsortedAndClearsASelectionOnIt() async throws {
        try await setUpModel()
        try await scanAndWait()
        let id = try XCTUnwrap(model.people.first?.id)
        model.selection = .person(id)
        await model.delete(id)
        XCTAssertEqual(model.people.count, 1)
        XCTAssertEqual(model.unsortedCount, 2)
        XCTAssertNil(model.selection, "the selection on a deleted person is dropped")
    }

    func testNotThisPersonMovesTheFaceOutAndAnAssignConfirmsItElsewhere() async throws {
        try await setUpModel()
        try await scanAndWait()
        let a = try XCTUnwrap(model.people.first)
        let b = try XCTUnwrap(model.people.last)
        model.selection = .person(a.id)
        await model.reload()
        let face = try XCTUnwrap(model.selectedFaces.first?.id)
        await model.notThisPerson(face, from: a.id)
        XCTAssertEqual(model.people.first { $0.id == a.id }?.faceCount, 1)
        XCTAssertEqual(model.unsortedCount, 1)
        await model.assign([face], to: b.id)
        XCTAssertEqual(model.people.first { $0.id == b.id }?.faceCount, 3)
        model.selection = .person(b.id)
        await model.reload()
        XCTAssertTrue(model.selectedFaces.contains { $0.id == face && $0.isConfirmed }, "an explicit assignment is confirmed")
    }

    func testPersonFilterKeepsOnlyPhotosWithThatPerson() async throws {
        try await setUpModel()
        try await scanAndWait()
        let map = try await db.personIDsByPhotoID()
        let a = try XCTUnwrap(model.people.first?.id)
        let shown = LibraryFilterSort.apply(to: photos, sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "",
                                            personFilter: a, personIDsByPhotoID: map)
        XCTAssertEqual(shown.count, 2)
        XCTAssertTrue(shown.allSatisfy { map[$0.id ?? -1]?.contains(a) == true })
        let none = LibraryFilterSort.apply(to: photos, sort: .dateOldest, minimumRating: 0, flagFilter: .all, searchText: "",
                                           personFilter: 9999, personIDsByPhotoID: map)
        XCTAssertTrue(none.isEmpty, "a person nobody is assigned to matches nothing, never everything")
    }

    func testPersonFilterCountsAsAnActiveFilter() {
        var state = LibraryFilterState()
        XCTAssertFalse(state.isPersonActive)
        state.personFilterID = 4
        XCTAssertTrue(state.isPersonActive)
        XCTAssertEqual(state.activeCount, 1)
        XCTAssertTrue(state.isActive)
    }

    // MARK: Reopening while a scan runs

    func testClearWhileAScanRunsKeepsItRunningAndItStillTellsTheLibrary() async throws {
        try await setUpModel()
        let slow = model.scannerEnvironment
        model.scannerEnvironment = FaceScanner.Environment(stat: slow.stat, detect: { path in Thread.sleep(forTimeInterval: 0.15); return slow.detect(path) })
        model.scanAndGroup(photos: photos, database: db)
        XCTAssertTrue(model.isWorking)
        model.clear()
        XCTAssertTrue(model.isWorking, "reopening the sheet does not forget a running scan")
        model.scanAndGroup(photos: photos, database: db)   // would overlap if isWorking had been reset
        for _ in 0..<400 where model.isWorking { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertFalse(model.isWorking)
        XCTAssertGreaterThan(peopleChangedCount, 0, "the finished scan still refreshed the Library")
        XCTAssertEqual(model.people.count, 2, "one scan's worth of people, not two overlapping ones")
    }

    func testClearWhenIdleResetsTheReviewState() async throws {
        try await setUpModel()
        try await scanAndWait()
        model.selection = .person(try XCTUnwrap(model.people.first?.id))
        model.clear()
        XCTAssertNil(model.selection)
        XCTAssertNil(model.summary)
        XCTAssertTrue(model.selectedFaces.isEmpty)
    }

    func testAnOlderSelectionLoadNeverLandsUnderANewerSelection() async throws {
        try await setUpModel()
        try await scanAndWait()
        let a = try XCTUnwrap(model.people.first?.id), b = try XCTUnwrap(model.people.last?.id)
        model.selection = .person(a)
        model.selection = .person(b)
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
        let bFaces = try await db.faces(forPersonID: b).compactMap(\.id).sorted()
        XCTAssertEqual(model.selectedFaces.compactMap(\.id).sorted(), bFaces)
    }

    func testMergeMovesTheSelectionToTheTarget() async throws {
        try await setUpModel()
        try await scanAndWait()
        let a = try XCTUnwrap(model.people.first?.id), b = try XCTUnwrap(model.people.last?.id)
        model.selection = .person(a)
        await model.merge(a, into: b)
        XCTAssertEqual(model.selection, .person(b))
    }

    func testToolSheetBusyCoversPeopleAndRenameBusyCoversScans() async throws {
        try await setUpModel()
        let catalog = CatalogModel(database: db)
        XCTAssertFalse(catalog.toolSheetIsBusy)
        catalog.peopleSheetPresented = true
        XCTAssertTrue(catalog.toolSheetIsBusy)
        XCTAssertNotNil(RenameBusyState(isToolScanRunning: true).reason)
    }

    func testRefreshDropsAPersonFilterWhosePersonIsGone() async throws {
        try await setUpModel()
        try await scanAndWait()
        let catalog = CatalogModel(database: db)
        await catalog.refresh()
        let id = try XCTUnwrap(catalog.people.first?.id)
        catalog.personFilterID = id
        await catalog.faces.delete(id)
        await catalog.refresh()
        XCTAssertNil(catalog.personFilterID)
    }

    func testNameFieldKeepsWhatTheUserTypedButFollowsAStoredRename() {
        // Typing "Bob" over the stored "Ann": a people-list change leaves it alone.
        XCTAssertEqual(PeopleSheetView.refreshedNameText(current: "Bob", lastStored: "Ann", stored: "Ann"), "Bob")
        // Typing into an unnamed person's field likewise.
        XCTAssertEqual(PeopleSheetView.refreshedNameText(current: "Bo", lastStored: nil, stored: nil), "Bo")
        // Untouched field, the stored name changed (merge / rename elsewhere): follow it.
        XCTAssertEqual(PeopleSheetView.refreshedNameText(current: "Ann", lastStored: "Ann", stored: "Anna"), "Anna")
        XCTAssertEqual(PeopleSheetView.refreshedNameText(current: "", lastStored: nil, stored: "Zed"), "Zed")
    }

    // MARK: Sheet render

    func testThePeopleSheetRendersWithPeopleAndHasNoBlue() async throws {
        try await setUpModel()
        try await scanAndWait()
        model.selection = .person(try XCTUnwrap(model.people.first?.id))
        await model.reload()
        let catalog = CatalogModel(database: db)
        let view = PeopleSheetView(catalog: catalog, model: model) {}
            .environment(\.colorScheme, .dark).environment(\.controlActiveState, .key).tint(Theme.controlTint)
        let rep = Self.render(view, size: CGSize(width: 780, height: 600))
        var blue = 0, nonBackground = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.blueComponent - c.redComponent > 0.25 { blue += 1 }
                if abs(c.redComponent - 0.11) > 0.1 { nonBackground += 1 }
            }
        }
        XCTAssertGreaterThan(nonBackground, 2000, "the sheet drew content")
        // The prominent buttons are the app's only blue: one or two small ones, well under 3% of the sheet (a blue selection chip
        // across a list row would exceed it).
        XCTAssertLessThan(blue, rep.pixelsWide * rep.pixelsHigh * 3 / 100, "blue is limited to prominent buttons")
    }

    private static func render<V: View>(_ content: V, size: CGSize) -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height).background(Theme.panel))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return NSBitmapImageRep() }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }
}
