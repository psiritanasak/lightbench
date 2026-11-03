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
        let slow = model.effectiveScannerEnvironment
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

    func testSmallFacesAreCountedSeparatelyNotGroupedAndOfferedUnderTheirOwnSelection() async throws {
        try await setUpModel()
        // One small face in EACH of the five photos, all with the same print: if grouping could see them they would form a person (faces
        // of one photo are never merged, so they must come from different photos for this to bite).
        model.scannerEnvironment = FaceScanner.Environment(
            stat: { _ in (1000, 1) },
            detect: { _ in
                [FaceDetector.DetectedFace(x: 0.5, y: 0.8, w: 0.02, h: 0.02, quality: 0.4, featurePrint: Self.print(plane: 0, angle: 0), crop: Data([3]), isSmall: true)]
            }, includeSmall: true)
        try await scanAndWait()
        XCTAssertEqual(model.smallFaceCount, 5)
        XCTAssertEqual(model.unsortedCount, 0, "small faces are not 'unsorted'")
        XCTAssertTrue(model.people.isEmpty, "and are never grouped into people, although five identical prints from five photos would otherwise form one")
        model.selection = .smallFaces
        for _ in 0..<200 where model.selectedFaces.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(model.selectedFaces.count, 5)
        XCTAssertTrue(model.selectedFaces.allSatisfy(\.isSmall))
    }

    func testTheSmallFaceOptionIsWrittenThroughToPreferencesAndSelectsTheRealScannerMode() {
        let model = FacesModel()
        let saved = AppPreferences.shared.findSmallFaces
        defer { AppPreferences.shared.findSmallFaces = saved }
        model.findSmallFaces = true
        XCTAssertTrue(AppPreferences.shared.findSmallFaces)
        XCTAssertTrue(model.effectiveScannerEnvironment.includeSmall)
        model.findSmallFaces = false
        XCTAssertFalse(AppPreferences.shared.findSmallFaces)
        XCTAssertFalse(model.effectiveScannerEnvironment.includeSmall)
    }

    // MARK: Marking several faces and acting on them at once

    /// Five photos, one small face each (all unassigned: small faces are never grouped), the Small faces list selected and loaded.
    private func setUpFiveSmallFaces() async throws {
        try await setUpModel()
        model.scannerEnvironment = FaceScanner.Environment(
            stat: { _ in (1000, 1) },
            detect: { _ in [FaceDetector.DetectedFace(x: 0.5, y: 0.8, w: 0.02, h: 0.02, quality: 0.4, featurePrint: Data(), crop: Data([3]), isSmall: true)] },
            includeSmall: true)
        try await scanAndWait()
        model.selection = .smallFaces
        try await waitForShownFaces(5)
    }

    private func waitForShownFaces(_ count: Int) async throws {
        for _ in 0..<200 where model.selectedFaces.count != count { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(model.selectedFaces.count, count)
    }

    func testMarksToggleAreClearedWhenTheSelectionChangesAndPrunedWhenAFaceLeavesTheList() async throws {
        try await setUpFiveSmallFaces()
        let ids = model.selectedFaces.compactMap(\.id)
        model.toggleMark(ids[0]); model.toggleMark(ids[1]); model.toggleMark(ids[1])
        XCTAssertEqual(model.markedFaceIDs, [ids[0]], "a second click unmarks")
        model.toggleMark(9_999_999)
        XCTAssertEqual(model.markedFaceIDs, [ids[0]], "a face that is not shown cannot be marked")
        model.markAllShown()
        XCTAssertEqual(model.markedFaceIDs.count, 5)
        // A face leaves the list (someone else gives it to a person): its mark must go with it.
        try await db.assignFaces([ids[2]], to: try await db.createPerson().id)
        await model.reload()
        try await waitForShownFaces(4)
        XCTAssertFalse(model.markedFaceIDs.contains(ids[2]))
        XCTAssertEqual(model.markedFaceIDs.count, 4)
        model.selection = .unsorted
        XCTAssertTrue(model.markedFaceIDs.isEmpty, "a new selection starts with nothing marked")
    }

    func testAnActionOnAMarkedFaceActsOnAllMarkedAndOnAnUnmarkedFaceOnlyOnThatFace() async throws {
        try await setUpFiveSmallFaces()
        let ids = model.selectedFaces.compactMap(\.id)
        model.toggleMark(ids[3]); model.toggleMark(ids[1])
        XCTAssertEqual(model.targets(for: ids[1]), [ids[1], ids[3]], "in the order shown")
        XCTAssertEqual(model.targets(for: ids[0]), [ids[0]], "an unmarked face is acted on alone")
        XCTAssertEqual(FaceMarking.targets(clicked: 7, marked: [7, 8, 99], shownOrder: [8, 7, 6]), [8, 7], "a stale mark (99) is never a target")
    }

    func testBulkAssignGivesAllMarkedFacesToOnePersonConfirmedAndClearsTheMarks() async throws {
        try await setUpFiveSmallFaces()
        let ids = model.selectedFaces.compactMap(\.id)
        for id in ids.prefix(3) { model.toggleMark(id) }
        await model.assignToNewPerson(model.markedInShownOrder)
        XCTAssertEqual(model.smallFaceCount, 2)
        XCTAssertEqual(model.people.count, 1)
        XCTAssertEqual(model.people.first?.faceCount, 3)
        XCTAssertTrue(model.markedFaceIDs.isEmpty)
        let assigned = try await db.faces(forPersonID: try XCTUnwrap(model.people.first?.id))
        XCTAssertEqual(Set(assigned.compactMap(\.id)), Set(ids.prefix(3)))
        XCTAssertTrue(assigned.allSatisfy(\.isConfirmed), "the user's choice is confirmed")
        XCTAssertTrue(model.canUndoAssignment)
    }

    func testUndoPutsTheFacesBackAndRemovesThePersonTheAssignmentCreated() async throws {
        try await setUpFiveSmallFaces()
        let ids = model.selectedFaces.compactMap(\.id)
        await model.assignToNewPerson(Array(ids.prefix(3)))
        XCTAssertEqual(model.people.count, 1)
        await model.undoLastAssignment()
        XCTAssertEqual(model.smallFaceCount, 5, "all five are unassigned again")
        XCTAssertTrue(model.people.isEmpty, "the empty unnamed person is gone")
        XCTAssertFalse(model.canUndoAssignment)
        let after = try await db.faces(forPhotoID: try XCTUnwrap(photos[0].id))
        XCTAssertTrue(after.allSatisfy { !$0.isConfirmed && $0.personId == nil })
    }

    func testUndoOnlyRevertsTheLastAssignmentAndANewAssignmentReplacesIt() async throws {
        try await setUpFiveSmallFaces()
        let ids = model.selectedFaces.compactMap(\.id)
        await model.assignToNewPerson([ids[0], ids[1]])
        model.selection = .smallFaces
        try await waitForShownFaces(3)
        let rest = model.selectedFaces.compactMap(\.id)
        await model.assignToNewPerson([rest[0]])
        await model.undoLastAssignment()
        XCTAssertEqual(model.people.count, 1, "the first person survives: only the last assignment was undone")
        XCTAssertEqual(model.people.first?.faceCount, 2)
        XCTAssertFalse(model.canUndoAssignment, "one level only")
    }

    func testUndoSurvivesAPersonDeletedInTheMeantime() async throws {
        try await setUpFiveSmallFaces()
        let ids = model.selectedFaces.compactMap(\.id)
        let ann = try await db.createPerson(name: "Ann"), bob = try await db.createPerson(name: "Bob")
        try await db.assignFaces([ids[0], ids[1]], to: ann.id)                  // the faces start in Ann, confirmed
        await model.assign([ids[0], ids[1]], to: bob.id)                          // the user moves them to Bob
        try await db.deletePerson(id: try XCTUnwrap(ann.id))                      // Ann is deleted before the undo
        await model.undoLastAssignment()
        let faces = try await db.faces(forPhotoID: try XCTUnwrap(photos[0].id)) + db.faces(forPhotoID: try XCTUnwrap(photos[1].id))
        XCTAssertTrue(faces.allSatisfy { $0.personId == nil && !$0.isConfirmed },
                      "they are back with nobody, and no longer in Bob (this fails if undo does nothing)")
    }

    func testUndoBringsBackTheNotThisPersonMarkTheAssignmentRemoved() async throws {
        try await setUpFiveSmallFaces()
        let ids = model.selectedFaces.compactMap(\.id)
        let bob = try await db.createPerson(name: "Bob")
        let bobID = try XCTUnwrap(bob.id)
        try await db.excludeFace(ids[0], fromPerson: bobID)
        await model.assign([ids[0]], to: bobID)                                   // a mistake
        let during = try await db.faceExclusions()
        XCTAssertNil(during[ids[0]])
        await model.undoLastAssignment()
        let after = try await db.faceExclusions()
        XCTAssertEqual(after[ids[0]], [bobID], "undo must not silently erase an earlier correction")
    }

    func testNotThisPersonMakesAnEarlierAssignmentNoLongerUndoable() async throws {
        try await setUpFiveSmallFaces()
        let ids = model.selectedFaces.compactMap(\.id)
        let bob = try await db.createPerson(name: "Bob")
        await model.assign([ids[0], ids[1]], to: bob.id)
        XCTAssertTrue(model.canUndoAssignment)
        await model.notThisPerson(ids[0], from: try XCTUnwrap(bob.id))
        XCTAssertFalse(model.canUndoAssignment, "undo would otherwise move the face back over the newer correction")
    }

    func testAnAssignmentMadeWhileAScanRunsCannotBeUndoneOverTheGrouping() async throws {
        try await setUpFiveSmallFaces()
        let ids = model.selectedFaces.compactMap(\.id)
        // A second scan that re-reads every photo (new mtime), slowly.
        model.scannerEnvironment = FaceScanner.Environment(
            stat: { _ in (1000, 2) },
            detect: { _ in Thread.sleep(forTimeInterval: 0.2); return [FaceDetector.DetectedFace(x: 0.5, y: 0.8, w: 0.02, h: 0.02, quality: 0.4, featurePrint: Data(), crop: Data([3]), isSmall: true)] },
            includeSmall: true)
        model.scanAndGroup(photos: photos, database: db)
        for _ in 0..<100 where model.progress == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        await model.assignToNewPerson([ids[0]])
        XCTAssertTrue(model.isWorking, "the scan is still running")
        for _ in 0..<400 where model.isWorking { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.canUndoAssignment, "the grouping was applied after the assignment: its snapshot is no longer trustworthy")
    }

    func testAScanForgetsTheUndo() async throws {
        try await setUpFiveSmallFaces()
        let ids = model.selectedFaces.compactMap(\.id)
        await model.assignToNewPerson([ids[0]])
        XCTAssertTrue(model.canUndoAssignment)
        try await scanAndWait()
        XCTAssertFalse(model.canUndoAssignment, "a scan regroups faces: an old snapshot must not be undone over it")
    }

    func testBulkNotThisPersonMovesEveryMarkedFaceOutOfThePerson() async throws {
        try await setUpModel()
        try await scanAndWait()
        let personA = try XCTUnwrap(model.people.first)
        model.selection = .person(personA.id)
        try await waitForShownFaces(2)
        model.markAllShown()
        await model.notThisPerson(model.markedInShownOrder, from: personA.id)
        XCTAssertEqual(model.unsortedCount, 2, "both faces left the person")
        XCTAssertTrue(model.markedFaceIDs.isEmpty)
        XCTAssertFalse(model.canUndoAssignment, "not-this-person is not undoable")
    }

    func testTheFaceAccessibilityLabelNamesSelectionAndConfirmation() {
        XCTAssertEqual(PeopleSheetView.faceAccessibilityLabel(isConfirmed: false, isMarked: false), "Face")
        XCTAssertEqual(PeopleSheetView.faceAccessibilityLabel(isConfirmed: true, isMarked: true), "Face, confirmed, selected")
    }

    func testAnAssignmentStillRunningWhenSomethingForgetsCannotBringTheUndoBack() async throws {
        try await setUpFiveSmallFaces()
        let ids = model.selectedFaces.compactMap(\.id)
        let bob = try await db.createPerson(name: "Bob")
        let running = Task { await model.assign([ids[0]], to: bob.id) }
        await Task.yield()                                            // the assignment is now suspended at its database write
        await model.notThisPerson(ids[1], from: try XCTUnwrap(bob.id))   // a newer action forgets the undo...
        await running.value                                           // ...and the older assignment finishes afterwards
        XCTAssertFalse(model.canUndoAssignment, "it must not store an undo that a later action already cleared")
    }

    func testUndoRemovesOnlyThePersonTheAssignmentCreatedNotOtherEmptyOnes() async throws {
        try await setUpFiveSmallFaces()
        let ids = model.selectedFaces.compactMap(\.id)
        let strayEmpty = try await db.createPerson()                    // an unnamed, empty person that has nothing to do with the undo
        await model.assignToNewPerson([ids[0]])
        await model.undoLastAssignment()
        let ids2 = try await db.peopleSummaries().map(\.id)
        XCTAssertEqual(ids2, [try XCTUnwrap(strayEmpty.id)], "the created person is gone, the unrelated one is not touched")
    }
}
