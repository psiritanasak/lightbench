import XCTest
@testable import PhotoApp

final class FaceDatabaseTests: XCTestCase {
    private var db: CatalogDatabase!
    private var photoIDs: [Int64] = []

    override func setUp() async throws {
        db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (1...3).map { URL(fileURLWithPath: "/tmp/facetest\($0).jpg") })
        photoIDs = try await db.allPhotos().compactMap(\.id).sorted()
        XCTAssertEqual(photoIDs.count, 3)
    }

    private func face(_ photoID: Int64, x: Double = 0.1, y: Double = 0.1, w: Double = 0.2, h: Double = 0.2, quality: Double = 0.6) -> Face {
        Face(id: nil, photoId: photoID, x: x, y: y, w: w, h: h, quality: quality, detectRevision: 3, printRevision: 2,
             featurePrint: Data(repeating: 1, count: 12), crop: Data([9, 9]), personId: nil, isConfirmed: false)
    }

    private func scan(_ photoID: Int64, faces: [Face]) -> FaceScanResult {
        FaceScanResult(scan: FaceScanRecord(photoId: photoID, fileSize: 100, mtime: 5, detectRevision: 3, printRevision: 2,
                                            faceCount: faces.count, scannedAt: Date()), faces: faces)
    }

    // MARK: Scans

    func testSavingAScanStoresTheFacesAndTheScanRecordEvenWithZeroFaces() async throws {
        try await db.saveFaceScans([scan(photoIDs[0], faces: [face(photoIDs[0]), face(photoIDs[0], x: 0.6)]), scan(photoIDs[1], faces: [])])
        let faces = try await db.faces(forPhotoID: photoIDs[0])
        XCTAssertEqual(faces.count, 2)
        let scans = try await db.faceScans(forPhotoIDs: photoIDs)
        XCTAssertEqual(scans[photoIDs[0]]?.faceCount, 2)
        XCTAssertEqual(scans[photoIDs[1]]?.faceCount, 0, "a photo with no faces is recorded so it is not rescanned")
        XCTAssertNil(scans[photoIDs[2]])
    }

    func testScansForPhotosThatNoLongerExistAreSkippedNotFatal() async throws {
        try await db.saveFaceScans([scan(9999, faces: [face(9999)]), scan(photoIDs[0], faces: [face(photoIDs[0])])])
        let faces = try await db.faces(forPhotoID: photoIDs[0])
        XCTAssertEqual(faces.count, 1)
    }

    func testARescanKeepsMatchedFacesTheirPersonAndConfirmationAndDropsVanishedOnes() async throws {
        try await db.saveFaceScans([scan(photoIDs[0], faces: [face(photoIDs[0]), face(photoIDs[0], x: 0.6)])])
        let person = try await db.createPerson(name: "Ann")
        let before = try await db.faces(forPhotoID: photoIDs[0])
        let keptID = try XCTUnwrap(before[0].id), goneID = try XCTUnwrap(before[1].id)
        let other = try await db.createPerson(name: "Other")
        try await db.assignFaces([keptID], to: person.id)
        try await db.excludeFace(keptID, fromPerson: try XCTUnwrap(other.id))      // a mark on the face that survives
        try await db.excludeFace(goneID, fromPerson: try XCTUnwrap(person.id))     // a mark on the face that vanishes
        // Rescan: the first face moved slightly (still overlaps), the second vanished, a new one appeared elsewhere.
        try await db.saveFaceScans([scan(photoIDs[0], faces: [face(photoIDs[0], x: 0.11, y: 0.11, quality: 0.9), face(photoIDs[0], x: 0.5, y: 0.6, w: 0.1, h: 0.1)])])
        let after = try await db.faces(forPhotoID: photoIDs[0])
        XCTAssertEqual(after.count, 2)
        let kept = try XCTUnwrap(after.first { $0.id == keptID })
        XCTAssertEqual(kept.personId, person.id, "the person survives a rescan")
        XCTAssertTrue(kept.isConfirmed)
        XCTAssertEqual(kept.quality, 0.9, accuracy: 0.001, "but the data is refreshed")
        XCTAssertFalse(after.contains { $0.id == goneID }, "the vanished face is gone")
        let exclusions = try await db.faceExclusions()
        XCTAssertEqual(exclusions[keptID], [try XCTUnwrap(other.id)], "a matched face keeps its own 'not this person' mark: that is why rows are updated in place")
        XCTAssertNil(exclusions[goneID], "a vanished face's marks go with it")
        let newFace = try XCTUnwrap(after.first { $0.id != keptID })
        XCTAssertNil(newFace.personId)
        XCTAssertFalse(newFace.isConfirmed)
    }

    func testDeletingAPhotoRemovesItsFacesScanAndExclusions() async throws {
        try await db.saveFaceScans([scan(photoIDs[0], faces: [face(photoIDs[0])])])
        let person = try await db.createPerson(name: "Ann")
        let firstFaces = try await db.faces(forPhotoID: photoIDs[0])
        let faceID = try XCTUnwrap(firstFaces.first?.id)
        try await db.excludeFace(faceID, fromPerson: try XCTUnwrap(person.id))
        try await db.deletePhoto(id: photoIDs[0])
        let faces = try await db.faces(forPhotoID: photoIDs[0])
        XCTAssertTrue(faces.isEmpty)
        let scans = try await db.faceScans(forPhotoIDs: photoIDs)
        XCTAssertNil(scans[photoIDs[0]])
        let exclusions = try await db.faceExclusions()
        XCTAssertTrue(exclusions.isEmpty)
    }

    func testAScanRecordIsCurrentOnlyWhileFileAndRevisionsMatch() {
        let r = FaceScanRecord(photoId: 1, fileSize: 100, mtime: 5, detectRevision: 3, printRevision: 2, faceCount: 0, scannedAt: Date())
        XCTAssertTrue(r.isCurrent(fileSize: 100, mtime: 5, detectRevision: 3, printRevision: 2))
        XCTAssertFalse(r.isCurrent(fileSize: 101, mtime: 5, detectRevision: 3, printRevision: 2))
        XCTAssertFalse(r.isCurrent(fileSize: 100, mtime: 6, detectRevision: 3, printRevision: 2))
        XCTAssertFalse(r.isCurrent(fileSize: 100, mtime: 5, detectRevision: 4, printRevision: 2))
        XCTAssertFalse(r.isCurrent(fileSize: 100, mtime: 5, detectRevision: 3, printRevision: 3))
    }

    func testGroupingReadsFaceDataThroughItsOwnTypeWithoutCrops() async throws {
        try await db.saveFaceScans([scan(photoIDs[0], faces: [face(photoIDs[0])])])
        let all = try await db.allFacesForGrouping()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].featurePrint, Data(repeating: 1, count: 12))
        XCTAssertEqual(all[0].isConfirmed, false)
        XCTAssertNil(all[0].personId)
    }

    // MARK: People

    func testRenamingNormalisesDetectsDuplicatesAndClears() async throws {
        let a = try await db.createPerson(), b = try await db.createPerson()
        let aID = try XCTUnwrap(a.id), bID = try XCTUnwrap(b.id)
        let r1 = try await db.renamePerson(id: aID, to: "  Ann   Lee ")
        XCTAssertEqual(r1, .renamed)
        let r2 = try await db.renamePerson(id: bID, to: "ann lee")
        XCTAssertEqual(r2, .duplicate(existingID: aID), "the same name in another case is the same person")
        let r3 = try await db.renamePerson(id: aID, to: "ANN LEE")
        XCTAssertEqual(r3, .renamed, "renaming a person to its own name (any case) is fine")
        let r4 = try await db.renamePerson(id: aID, to: "  ")
        XCTAssertEqual(r4, .cleared)
        let r5 = try await db.renamePerson(id: 12345, to: "x")
        XCTAssertEqual(r5, .notFound)
        let c = try await db.createPerson(), d = try await db.createPerson()
        XCTAssertNotNil(c.id); XCTAssertNotNil(d.id, "any number of unnamed people")
    }

    func testDeletingAPersonUnassignsAndUnconfirmsItsFaces() async throws {
        try await db.saveFaceScans([scan(photoIDs[0], faces: [face(photoIDs[0])])])
        let person = try await db.createPerson(name: "Ann")
        let firstFaces = try await db.faces(forPhotoID: photoIDs[0])
        let faceID = try XCTUnwrap(firstFaces.first?.id)
        try await db.assignFaces([faceID], to: person.id)
        try await db.deletePerson(id: try XCTUnwrap(person.id))
        let faces = try await db.faces(forPhotoID: photoIDs[0])
        XCTAssertNil(faces[0].personId)
        XCTAssertFalse(faces[0].isConfirmed)
    }

    func testMergeMovesFacesConfirmsThemKeepsTheNameAndExclusions() async throws {
        try await db.saveFaceScans([scan(photoIDs[0], faces: [face(photoIDs[0]), face(photoIDs[0], x: 0.5)]), scan(photoIDs[1], faces: [face(photoIDs[1])])])
        let faceIDs = try await db.faces(forPhotoID: photoIDs[0]).compactMap(\.id) + db.faces(forPhotoID: photoIDs[1]).compactMap(\.id)
        let source = try await db.createPerson(name: "Ann"), target = try await db.createPerson()
        let sID = try XCTUnwrap(source.id), tID = try XCTUnwrap(target.id)
        try await db.applyAutomaticAssignments([FaceAssignment(faceID: faceIDs[0], personID: sID), FaceAssignment(faceID: faceIDs[1], personID: sID)])
        try await db.assignFaces([faceIDs[2]], to: tID)
        try await db.excludeFace(faceIDs[2], fromPerson: sID)   // face 3 is "not Ann"
        let moved = try await db.mergePeople(source: sID, into: tID)
        XCTAssertEqual(moved, 2)
        let people = try await db.peopleSummaries()
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].name, "Ann", "the unnamed target takes the source's name")
        XCTAssertEqual(people[0].faceCount, 3)
        let all = try await db.allFacesForGrouping()
        XCTAssertTrue(all.allSatisfy { $0.personId == tID && $0.isConfirmed })
        let exclusions = try await db.faceExclusions()
        XCTAssertNil(exclusions[faceIDs[2]], "a face that is IN the target keeps no exclusion for it")
    }

    func testMergeCarriesTheSourcesExclusionsOverToTheTarget() async throws {
        try await db.saveFaceScans([scan(photoIDs[0], faces: [face(photoIDs[0])])])
        let mergeFaces = try await db.faces(forPhotoID: photoIDs[0])
        let faceID = try XCTUnwrap(mergeFaces.first?.id)
        let source = try await db.createPerson(name: "Ann"), target = try await db.createPerson(name: "Bob")
        let sID = try XCTUnwrap(source.id), tID = try XCTUnwrap(target.id)
        try await db.excludeFace(faceID, fromPerson: sID)         // an UNASSIGNED face that is "not Ann"
        _ = try await db.mergePeople(source: sID, into: tID)
        let exclusions = try await db.faceExclusions()
        XCTAssertEqual(exclusions[faceID], [tID], "Ann became Bob, so the face is now 'not Bob'")
    }

    func testMergingTwoNamedPeopleKeepsTheTargetsNameAndFreesTheSourcesKey() async throws {
        let source = try await db.createPerson(name: "Ann"), target = try await db.createPerson(name: "Bob")
        let sID = try XCTUnwrap(source.id), tID = try XCTUnwrap(target.id)
        _ = try await db.mergePeople(source: sID, into: tID)
        var people = try await db.peopleSummaries()
        XCTAssertEqual(people.map(\.name), ["Bob"])
        let fresh = try await db.createPerson()
        let renamed = try await db.renamePerson(id: try XCTUnwrap(fresh.id), to: "ann")
        XCTAssertEqual(renamed, .renamed, "the merged-away person's name is free again")
        people = try await db.peopleSummaries()
        XCTAssertEqual(people.count, 2)
    }

    func testMergingAPersonIntoItselfOrAMissingOneDoesNothing() async throws {
        let p = try await db.createPerson(name: "Ann")
        let id = try XCTUnwrap(p.id)
        let a = try await db.mergePeople(source: id, into: id)
        let b = try await db.mergePeople(source: id, into: 777)
        let c = try await db.mergePeople(source: 777, into: id)
        XCTAssertEqual(a, 0); XCTAssertEqual(b, 0); XCTAssertEqual(c, 0)
        let people = try await db.peopleSummaries()
        XCTAssertEqual(people.count, 1)
    }

    // MARK: Assignments

    func testAutomaticAssignmentsNeverTouchConfirmedFaces() async throws {
        try await db.saveFaceScans([scan(photoIDs[0], faces: [face(photoIDs[0]), face(photoIDs[0], x: 0.5)])])
        let ids = try await db.faces(forPhotoID: photoIDs[0]).compactMap(\.id)
        let ann = try await db.createPerson(name: "Ann"), bob = try await db.createPerson(name: "Bob")
        try await db.assignFaces([ids[0]], to: ann.id)                        // the user's choice
        let bobID = try XCTUnwrap(bob.id)
        try await db.applyAutomaticAssignments([FaceAssignment(faceID: ids[0], personID: bobID), FaceAssignment(faceID: ids[1], personID: bobID)])
        let faces = try await db.faces(forPhotoID: photoIDs[0])
        XCTAssertEqual(faces.first { $0.id == ids[0] }?.personId, ann.id, "confirmed stays")
        XCTAssertEqual(faces.first { $0.id == ids[1] }?.personId, bob.id)
        XCTAssertEqual(faces.first { $0.id == ids[1] }?.isConfirmed, false, "automatic is not a confirmation")
    }

    /// Things the user does while grouping runs must win: an exclusion added after grouping read its input, and a person deleted
    /// meanwhile (which must not fail the whole batch either).
    func testAutomaticAssignmentsRespectLateExclusionsAndSkipDeletedPeople() async throws {
        try await db.saveFaceScans([scan(photoIDs[0], faces: [face(photoIDs[0]), face(photoIDs[0], x: 0.5), face(photoIDs[0], x: 0.8)])])
        let ids = try await db.faces(forPhotoID: photoIDs[0]).compactMap(\.id)
        let ann = try await db.createPerson(name: "Ann"), gone = try await db.createPerson(name: "Gone")
        let annID = try XCTUnwrap(ann.id), goneID = try XCTUnwrap(gone.id)
        try await db.excludeFace(ids[0], fromPerson: annID)                  // "not Ann", added after grouping "read" its input
        try await db.deletePerson(id: goneID)                                 // deleted meanwhile
        try await db.applyAutomaticAssignments([
            FaceAssignment(faceID: ids[0], personID: annID),                  // excluded: must stay unassigned
            FaceAssignment(faceID: ids[1], personID: goneID),                 // person gone: skipped, not an error
            FaceAssignment(faceID: ids[2], personID: annID),                  // fine: still applied in the same batch
        ])
        let faces = try await db.faces(forPhotoID: photoIDs[0])
        XCTAssertNil(faces.first { $0.id == ids[0] }?.personId)
        XCTAssertNil(faces.first { $0.id == ids[1] }?.personId)
        XCTAssertEqual(faces.first { $0.id == ids[2] }?.personId, annID, "the rest of the batch still went through")
    }

    func testAutomaticGroupingCanTakeAnUnconfirmedFaceOutButNeverAConfirmedOne() async throws {
        try await db.saveFaceScans([scan(photoIDs[0], faces: [face(photoIDs[0]), face(photoIDs[0], x: 0.5)])])
        let ids = try await db.faces(forPhotoID: photoIDs[0]).compactMap(\.id)
        let ann = try await db.createPerson(name: "Ann")
        let annID = try XCTUnwrap(ann.id)
        try await db.applyAutomaticAssignments([FaceAssignment(faceID: ids[0], personID: annID)])
        try await db.assignFaces([ids[1]], to: annID)
        try await db.applyAutomaticAssignments([FaceAssignment(faceID: ids[0], personID: nil), FaceAssignment(faceID: ids[1], personID: nil)])
        let faces = try await db.faces(forPhotoID: photoIDs[0])
        XCTAssertNil(faces.first { $0.id == ids[0] }?.personId)
        XCTAssertEqual(faces.first { $0.id == ids[1] }?.personId, annID)
    }

    func testNotThisPersonUnassignsAndRemembersAndAssigningLiftsIt() async throws {
        try await db.saveFaceScans([scan(photoIDs[0], faces: [face(photoIDs[0])])])
        let firstFaces = try await db.faces(forPhotoID: photoIDs[0])
        let id = try XCTUnwrap(firstFaces.first?.id)
        let ann = try await db.createPerson(name: "Ann")
        let aID = try XCTUnwrap(ann.id)
        try await db.assignFaces([id], to: aID)
        try await db.excludeFace(id, fromPerson: aID)
        var face = try await db.faces(forPhotoID: photoIDs[0])[0]
        XCTAssertNil(face.personId); XCTAssertFalse(face.isConfirmed)
        var exclusions = try await db.faceExclusions()
        XCTAssertEqual(exclusions[id], [aID])
        try await db.assignFaces([id], to: aID)
        face = try await db.faces(forPhotoID: photoIDs[0])[0]
        XCTAssertEqual(face.personId, aID)
        exclusions = try await db.faceExclusions()
        XCTAssertNil(exclusions[id], "the user changed their mind: the mark is lifted")
    }

    // MARK: Lookups

    func testSummariesPhotoMapAndPruning() async throws {
        try await db.saveFaceScans([scan(photoIDs[0], faces: [face(photoIDs[0]), face(photoIDs[0], x: 0.5)]), scan(photoIDs[1], faces: [face(photoIDs[1])])])
        let ids = try await db.faces(forPhotoID: photoIDs[0]).compactMap(\.id) + db.faces(forPhotoID: photoIDs[1]).compactMap(\.id)
        let ann = try await db.createPerson(name: "Ann"), empty = try await db.createPerson(), named = try await db.createPerson(name: "Kept")
        try await db.assignFaces(ids, to: ann.id)
        var people = try await db.peopleSummaries()
        XCTAssertEqual(people.first?.id, ann.id)
        XCTAssertEqual(people.first?.faceCount, 3)
        XCTAssertEqual(people.first?.photoCount, 2, "two photos, one of them with two faces")
        let map = try await db.personIDsByPhotoID()
        XCTAssertEqual(map[photoIDs[0]], [try XCTUnwrap(ann.id)])
        XCTAssertNil(map[photoIDs[2]])
        try await db.pruneEmptyPeople()
        people = try await db.peopleSummaries()
        XCTAssertFalse(people.contains { $0.id == empty.id }, "unnamed and empty: pruned")
        XCTAssertTrue(people.contains { $0.id == named.id }, "a named person stays even with no faces")
        let unassigned = try await db.unassignedFaceCount()
        XCTAssertEqual(unassigned, 0)
        let crop = try await db.representativeCrop(forPersonID: try XCTUnwrap(ann.id))
        XCTAssertEqual(crop, Data([9, 9]))
    }

    // MARK: Box matching (pure)

    func testIOUAndGreedyMatching() {
        let a = FaceMatching.Box(x: 0, y: 0, w: 0.2, h: 0.2)
        XCTAssertEqual(FaceMatching.iou(a, a), 1, accuracy: 1e-9)
        XCTAssertEqual(FaceMatching.iou(a, FaceMatching.Box(x: 0.5, y: 0.5, w: 0.1, h: 0.1)), 0)
        let old = [a, FaceMatching.Box(x: 0.5, y: 0.5, w: 0.2, h: 0.2)]
        let new = [FaceMatching.Box(x: 0.51, y: 0.5, w: 0.2, h: 0.2), FaceMatching.Box(x: 0.9, y: 0.9, w: 0.05, h: 0.05), FaceMatching.Box(x: 0.01, y: 0, w: 0.2, h: 0.2)]
        XCTAssertEqual(FaceMatching.match(old: old, new: new), [1, nil, 0])
    }

    func testAnOldBoxIsMatchedAtMostOnce() {
        let old = [FaceMatching.Box(x: 0, y: 0, w: 0.2, h: 0.2)]
        let new = [FaceMatching.Box(x: 0.01, y: 0, w: 0.2, h: 0.2), FaceMatching.Box(x: 0.03, y: 0, w: 0.2, h: 0.2)]
        let m = FaceMatching.match(old: old, new: new)
        XCTAssertEqual(m.compactMap { $0 }.count, 1)
        XCTAssertEqual(m[0], 0, "the better overlap wins")
    }
}
