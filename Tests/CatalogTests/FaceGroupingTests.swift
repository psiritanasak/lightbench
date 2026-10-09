import XCTest
@testable import PhotoApp

final class FaceGroupingTests: XCTestCase {
    /// A unit vector at `angle` radians in a 2-D plane of the 768-D space: two such vectors are 2·sin(Δ/2) apart (Euclidean).
    private func vec(_ angle: Double, plane: Int = 0) -> Data {
        var floats = [Float](repeating: 0, count: FeaturePrintVector.elementCount)
        floats[plane * 2] = Float(cos(angle))
        floats[plane * 2 + 1] = Float(sin(angle))
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    /// The angle that puts a unit vector at Euclidean distance `d` from the one at angle 0.
    private func angle(forDistance d: Double) -> Double { 2 * asin(d / 2) }

    private func face(_ id: Int64, _ print: Data, person: Int64? = nil, confirmed: Bool = false, photo: Int64? = nil) -> FaceGroupingInput {
        FaceGroupingInput(id: id, photoId: photo ?? id, personId: person, isConfirmed: confirmed, quality: 0.6, featurePrint: print)
    }

    /// What `applyGroupingPlan` does to the data, in memory: new groups get fresh person ids, assignments set / clear `personId`.
    private func applied(_ plan: FaceGrouping.Plan, to faces: [FaceGroupingInput], nextPerson: inout Int64) -> [FaceGroupingInput] {
        var result = faces
        func set(_ id: Int64, _ person: Int64?) {
            if let index = result.firstIndex(where: { $0.id == id }), !result[index].isConfirmed { result[index].personId = person }
        }
        for assignment in plan.assignments { set(assignment.faceID, assignment.personID) }
        for group in plan.newGroups {
            let id = nextPerson; nextPerson += 1
            for faceID in group { set(faceID, id) }
        }
        return result
    }

    /// The largest pairwise distance inside any automatic person.
    private func diameter(of faces: [FaceGroupingInput]) -> Float {
        var worst: Float = 0
        let byPerson = Dictionary(grouping: faces.filter { $0.personId != nil }, by: { $0.personId! })
        for members in byPerson.values {
            let vectors = members.compactMap { FeaturePrintVector.vector(from: $0.featurePrint) }
            for i in 0..<vectors.count { for j in (i + 1)..<vectors.count { worst = max(worst, FeaturePrintVector.distance(vectors[i], vectors[j])) } }
        }
        return worst
    }

    func testTheDistanceHelperMatchesEuclid() throws {
        let a = try XCTUnwrap(FeaturePrintVector.vector(from: vec(0))), b = try XCTUnwrap(FeaturePrintVector.vector(from: vec(angle(forDistance: 0.3))))
        XCTAssertEqual(FeaturePrintVector.distance(a, b), 0.3, accuracy: 1e-4)
        XCTAssertEqual(FaceGrouping.distance(a, b), FeaturePrintVector.distance(a, b), accuracy: 1e-5, "the Accelerate version agrees with the plain one")
    }

    // MARK: New people

    func testTwoTightGroupsBecomeTwoNewPeopleAndSingletonsStayUnsorted() {
        let faces = [face(1, vec(0)), face(2, vec(angle(forDistance: 0.1))), face(3, vec(angle(forDistance: 0.2))),
                     face(4, vec(2, plane: 0)), face(5, vec(2 + angle(forDistance: 0.1))),
                     face(6, vec(1, plane: 5))]                                 // alone, in another plane
        let plan = FaceGrouping.plan(faces: faces, exclusions: [:])
        XCTAssertEqual(plan.newGroups, [[1, 2, 3], [4, 5]])
        XCTAssertTrue(plan.assignments.isEmpty)
    }

    /// A~B 0.4 and B~C 0.4 but A~C 0.8: complete linkage must NOT chain them into one person.
    func testChainsDoNotMerge() {
        let b = angle(forDistance: 0.4)
        let faces = [face(1, vec(0)), face(2, vec(b)), face(3, vec(2 * b))]
        let plan = FaceGrouping.plan(faces: faces, exclusions: [:])
        XCTAssertEqual(plan.newGroups, [[1, 2]], "1 and 2 group; 3 is within 0.4 of 2 but 0.8 from 1, so it stays out")
    }

    func testTheLimitIsInclusiveAndJustBeyondIsNot() {
        let t = FaceGrouping.Thresholds()
        let inside = FaceGrouping.plan(faces: [face(1, vec(0)), face(2, vec(angle(forDistance: Double(t.cluster) - 0.01)))], exclusions: [:])
        let outside = FaceGrouping.plan(faces: [face(1, vec(0)), face(2, vec(angle(forDistance: Double(t.cluster) + 0.02)))], exclusions: [:])
        XCTAssertEqual(inside.newGroups, [[1, 2]])
        XCTAssertTrue(outside.newGroups.isEmpty)
    }

    // MARK: Existing people

    func testAnUnassignedFaceJoinsTheNearestPersonWithinTheLimitOnly() {
        let faces = [face(1, vec(0), person: 10, confirmed: true), face(2, vec(angle(forDistance: 0.05)), person: 10, confirmed: true),
                     face(3, vec(angle(forDistance: 0.2))),                      // close to person 10
                     face(4, vec(angle(forDistance: 0.9)))]                      // far from everyone
        let plan = FaceGrouping.plan(faces: faces, exclusions: [:])
        XCTAssertEqual(plan.assignments, [FaceAssignment(faceID: 3, personID: 10)])
        XCTAssertTrue(plan.newGroups.isEmpty, "face 4 is a singleton")
    }

    func testConfirmedFacesAreNeverInThePlan() {
        let faces = [face(1, vec(0), person: 10, confirmed: true), face(2, vec(angle(forDistance: 1.0)), person: 10, confirmed: true)]
        let plan = FaceGrouping.plan(faces: faces, exclusions: [:])
        XCTAssertTrue(plan.isEmpty, "the user's choice stands even when the face looks nothing like the rest")
    }

    func testAnExcludedPersonIsSkippedForThatFace() {
        let faces = [face(1, vec(0), person: 10, confirmed: true), face(2, vec(angle(forDistance: 0.3)), person: 20, confirmed: true),
                     face(3, vec(angle(forDistance: 0.05)))]                      // nearest is person 10, but "not person 10"
        let plan = FaceGrouping.plan(faces: faces, exclusions: [3: [10]])
        XCTAssertNotEqual(plan.assignments.first?.personID, 10)
        XCTAssertEqual(plan.assignments.first, FaceAssignment(faceID: 3, personID: 20), "the next-nearest allowed person within the limit (0.25 away) takes it")
    }

    func testAnAutomaticFaceStaysInItsPersonInsideTheHysteresisBandAndLeavesBeyondIt() {
        let anchor = face(1, vec(0), person: 10, confirmed: true)
        let band = FaceGrouping.Thresholds().assign + 0.02              // beyond `assign`, inside assign + margin
        let beyond = FaceGrouping.Thresholds().assign + 0.1
        let staying = FaceGrouping.plan(faces: [anchor, face(2, vec(angle(forDistance: Double(band))), person: 10)], exclusions: [:])
        XCTAssertTrue(staying.assignments.isEmpty, "no flapping near the limit")
        let leaving = FaceGrouping.plan(faces: [anchor, face(2, vec(angle(forDistance: Double(beyond))), person: 10)], exclusions: [:])
        XCTAssertEqual(leaving.assignments, [FaceAssignment(faceID: 2, personID: nil)])
    }

    func testAFaceMovesToAClearlyCloserPersonButNotToASlightlyCloserOne() {
        // Person 10 at angle 0, person 20 at distance 0.3 from it. The face sits at 0.22 from 10 and 0.08 from 20.
        let faces = [face(1, vec(0), person: 10, confirmed: true), face(2, vec(angle(forDistance: 0.3)), person: 20, confirmed: true),
                     face(3, vec(angle(forDistance: 0.22)), person: 10)]
        let moved = FaceGrouping.plan(faces: faces, exclusions: [:])
        XCTAssertEqual(moved.assignments, [FaceAssignment(faceID: 3, personID: 20)], "0.08 + margin < 0.22: clearly closer")
        let closeCall = [faces[0], faces[1], face(3, vec(angle(forDistance: 0.17)), person: 10)]   // 0.17 from 10, 0.13 from 20
        XCTAssertTrue(FaceGrouping.plan(faces: closeCall, exclusions: [:]).assignments.isEmpty, "0.13 + margin is not < 0.17: stays")
    }

    func testAnAnchoredPersonIsJudgedByItsConfirmedFacesNotByAutomaticOnes() {
        // Person 10: a confirmed face at distance 0 and a (wrongly placed) automatic face 0.4 away along the same line. A new face lies
        // a further 0.2 beyond it (0.6 from the confirmed face). Averaging ALL members would put the centroid ~0.2 out, within the limit
        // of the new face (~0.4): it would join. With the CONFIRMED face as the anchor the distance is 0.6 > 0.45: it must not.
        let faces = [face(1, vec(0), person: 10, confirmed: true), face(2, vec(angle(forDistance: 0.4)), person: 10),
                     face(3, vec(angle(forDistance: 0.6)))]
        let plan = FaceGrouping.plan(faces: faces, exclusions: [:])
        XCTAssertFalse(plan.assignments.contains { $0.faceID == 3 && $0.personID == 10 }, "the confirmed face alone anchors the person")
        XCTAssertTrue(plan.newGroups.isEmpty)
    }

    // MARK: Robustness

    func testUnusableFeaturePrintsAreSkippedNotTreatedAsDistanceZero() {
        let faces = [face(1, Data([1, 2, 3])), face(2, Data([1, 2, 3])), face(3, vec(0))]
        let plan = FaceGrouping.plan(faces: faces, exclusions: [:])
        XCTAssertTrue(plan.newGroups.isEmpty, "two broken prints must not group together, and 3 is alone")
    }

    /// (Weak by construction — `plan` sorts by id first — but it pins that nothing else introduces an order dependence.)
    func testTheResultDoesNotDependOnInputOrder() {
        let b = angle(forDistance: 0.1)
        let faces = [face(1, vec(0)), face(2, vec(b)), face(3, vec(3)), face(4, vec(3 + b)), face(5, vec(0.05, plane: 3))]
        XCTAssertEqual(FaceGrouping.plan(faces: faces, exclusions: [:]), FaceGrouping.plan(faces: faces.reversed(), exclusions: [:]))
        XCTAssertEqual(FaceGrouping.plan(faces: faces, exclusions: [:]), FaceGrouping.plan(faces: faces.shuffled(), exclusions: [:]))
    }

    func testLeftoverClusteringIsCappedPerRunNewestFirstAndReportsWhatWasDeferred() {
        var t = FaceGrouping.Thresholds(); t.maximumLeftoverPerRun = 3
        let faces = (1...6).map { face(Int64($0), vec(Double($0) * 0.01)) }     // all mutually close
        let plan = FaceGrouping.plan(faces: faces, exclusions: [:], thresholds: t)
        XCTAssertEqual(plan.newGroups, [[4, 5, 6]], "the NEWEST three were considered")
        XCTAssertEqual(plan.deferred, 3)
    }

    // MARK: Across runs (the reviewer's snowball)

    /// A~B 0.30, B~C 0.25, A~C 0.55: run 1 groups A,B; in run 2 C is within the limit of the person's CENTROID (~0.40) but not of
    /// member A, so complete linkage on admission must refuse it.
    func testAFaceBeyondTheLimitOfAnyMemberIsNotAdmittedInALaterRun() {
        var nextPerson: Int64 = 100
        var faces = [face(1, vec(0)), face(2, vec(angle(forDistance: 0.30)))]
        faces = applied(FaceGrouping.plan(faces: faces, exclusions: [:]), to: faces, nextPerson: &nextPerson)
        XCTAssertEqual(faces.map(\.personId), [100, 100])
        faces.append(face(3, vec(angle(forDistance: 0.55))))
        let plan = FaceGrouping.plan(faces: faces, exclusions: [:])
        XCTAssertTrue(plan.assignments.isEmpty, "face 3 is 0.55 from face 1: refused although ~0.40 from the centroid")
        XCTAssertTrue(plan.newGroups.isEmpty)
    }

    /// Faces arriving one per run along an arc must not stretch an automatic person beyond the limit.
    func testAPersonDoesNotSnowballWhenFacesArriveOnePerRun() {
        var nextPerson: Int64 = 100
        var faces = [face(1, vec(0)), face(2, vec(angle(forDistance: 0.15)))]
        for step in 3...14 {
            faces = applied(FaceGrouping.plan(faces: faces, exclusions: [:]), to: faces, nextPerson: &nextPerson)
            faces.append(face(Int64(step), vec(Double(step - 1) * angle(forDistance: 0.15))))
            XCTAssertLessThanOrEqual(diameter(of: faces), FaceGrouping.Thresholds().assign + 0.001, "after run \(step - 2)")
        }
        faces = applied(FaceGrouping.plan(faces: faces, exclusions: [:]), to: faces, nextPerson: &nextPerson)
        XCTAssertLessThanOrEqual(diameter(of: faces), FaceGrouping.Thresholds().assign + 0.001)
    }

    func testRegroupingTheResultIsStableOnAnArc() {
        var nextPerson: Int64 = 100
        var faces = (1...8).map { face(Int64($0), vec(Double($0 - 1) * angle(forDistance: 0.12))) }
        faces = applied(FaceGrouping.plan(faces: faces, exclusions: [:]), to: faces, nextPerson: &nextPerson)
        var previous = faces.map(\.personId)
        for _ in 0..<4 {
            faces = applied(FaceGrouping.plan(faces: faces, exclusions: [:]), to: faces, nextPerson: &nextPerson)
            XCTAssertEqual(faces.map(\.personId), previous, "no flapping: a second run changes nothing once the grouping has settled")
            previous = faces.map(\.personId)
        }
    }

    func testOldSingletonsDoNotStarveANewCloseCapped() {
        var t = FaceGrouping.Thresholds(); t.maximumLeftoverPerRun = 4
        // Six mutually distant OLD faces (each in its own plane), then a NEW close pair with the highest ids.
        var faces = (1...6).map { face(Int64($0), vec(0, plane: $0)) }
        faces += [face(7, vec(0, plane: 9)), face(8, vec(0.05, plane: 9))]
        let plan = FaceGrouping.plan(faces: faces, exclusions: [:], thresholds: t)
        XCTAssertEqual(plan.newGroups, [[7, 8]], "newest first: the pair is clustered although 6 older singletons exceed the cap")
        XCTAssertEqual(plan.deferred, 4)
    }

    // MARK: Same photo (cannot-link)

    func testTwoFacesOfTheSamePhotoNeverFormOrJoinTheSamePerson() {
        let near = angle(forDistance: 0.05)
        // Look-alikes in ONE frame: very close prints, same photo.
        let together = FaceGrouping.plan(faces: [face(1, vec(0), photo: 7), face(2, vec(near), photo: 7)], exclusions: [:])
        XCTAssertTrue(together.newGroups.isEmpty)
        // Three faces: 1 and 2 are the same photo, 3 elsewhere: 3 may pair with one of them, never both.
        let three = FaceGrouping.plan(faces: [face(1, vec(0), photo: 7), face(2, vec(near), photo: 7), face(3, vec(near * 2), photo: 8)], exclusions: [:])
        XCTAssertEqual(three.newGroups.flatMap { $0 }.filter { $0 != 3 }.count, 1)
        // Admission: person 10 already holds a face from photo 7.
        let joined = FaceGrouping.plan(faces: [face(1, vec(0), person: 10, confirmed: true, photo: 7), face(2, vec(near), photo: 7)], exclusions: [:])
        XCTAssertTrue(joined.assignments.isEmpty)
    }

    // MARK: Hysteresis and moving

    func testInTheBandForItsPersonAndWithinLimitOfAnotherItStaysUnlessClearlyBetter() {
        // Person 10 anchor at 0; person 20 anchor at 0.9 (angle). Face at 0.48 from 10 (in the band) and 0.42 from 20: not better by
        // more than the margin (0.42 + 0.05 > 0.48): it stays.
        let faces = [face(1, vec(0), person: 10, confirmed: true), face(2, vec(angle(forDistance: 0.9)), person: 20, confirmed: true),
                     face(3, vec(angle(forDistance: 0.48)), person: 10)]
        XCTAssertTrue(FaceGrouping.plan(faces: faces, exclusions: [:]).assignments.isEmpty)
    }

    func testAFaceTakenOutOfItsPersonCanJoinANewClusterInTheSameRun() {
        // Person 10 (anchor at 0) holds an automatic face that is far (0.7): it is unassigned and then clusters with another leftover.
        let far = angle(forDistance: 0.7)
        let faces = [face(1, vec(0), person: 10, confirmed: true), face(2, vec(far), person: 10), face(3, vec(far + angle(forDistance: 0.1)))]
        let plan = FaceGrouping.plan(faces: faces, exclusions: [:])
        XCTAssertEqual(plan.assignments, [FaceAssignment(faceID: 2, personID: nil)])
        XCTAssertEqual(plan.newGroups, [[2, 3]])
    }

    // MARK: Sole members and the anchored prefilter

    /// P = {B} is an automatic one-face person (its partner left). B must not be stuck there when a real match exists.
    func testAFaceAloneInAnAutomaticPersonMovesToAPersonItFitsButOtherwiseStays() {
        let near = angle(forDistance: 0.1)
        let faces = [face(1, vec(0), person: 20, confirmed: true),            // Q: anchored
                     face(2, vec(near), person: 10)]                          // P = {B}, 0.1 from Q's confirmed face
        XCTAssertEqual(FaceGrouping.plan(faces: faces, exclusions: [:]).assignments, [FaceAssignment(faceID: 2, personID: 20)])
        let alone = [face(1, vec(angle(forDistance: 0.9)), person: 20, confirmed: true), face(2, vec(0), person: 10)]
        XCTAssertTrue(FaceGrouping.plan(faces: alone, exclusions: [:]).assignments.isEmpty, "no match anywhere: it stays, never dissolved")
    }

    /// The bounding-ball prefilter is exact: an anchored person with a spread of confirmed faces still admits a face near any of them.
    func testAnchoredPeopleStillAdmitAFaceNearAnyConfirmedFaceDespiteThePrefilter() {
        let spread = angle(forDistance: 0.4)
        let faces = [face(1, vec(0), person: 10, confirmed: true), face(2, vec(spread), person: 10, confirmed: true),
                     face(3, vec(2 * spread), person: 10, confirmed: true), face(4, vec(3 * spread - 0.01)),   // ~0.4 from the last one
                     face(5, vec(1.5, plane: 7))]                                                                // nowhere near
        let plan = FaceGrouping.plan(faces: faces, exclusions: [:])
        XCTAssertEqual(plan.assignments, [FaceAssignment(faceID: 4, personID: 10)])
    }

    // MARK: Persistence in one transaction

    private func importedDB(photoCount: Int) async throws -> (CatalogDatabase, [Int64]) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (1...photoCount).map { URL(fileURLWithPath: "/tmp/fg\($0).jpg") })
        return (db, try await db.allPhotos().compactMap(\.id).sorted())
    }

    private func storedFace(_ photo: Int64, print: Data) -> Face {
        Face(id: nil, photoId: photo, x: 0.1, y: 0.1, w: 0.2, h: 0.2, quality: 0.6, detectRevision: 1, printRevision: 2, featurePrint: print, crop: nil, personId: nil, isConfirmed: false)
    }

    private func save(_ db: CatalogDatabase, _ photos: [Int64], prints: [Data]) async throws {
        try await db.saveFaceScans(zip(photos, prints).map { photo, print in
            FaceScanResult(scan: FaceScanRecord(photoId: photo, fileSize: 1, mtime: 1, detectRevision: 1, printRevision: 2, faceCount: 1, scannedAt: Date()),
                           faces: [storedFace(photo, print: print)])
        })
    }

    func testApplyingAPlanCreatesPeopleAssignsFacesAndReportsWhatHappened() async throws {
        let (db, photos) = try await importedDB(photoCount: 3)
        try await save(db, photos, prints: [vec(0.01), vec(0.02), vec(0.03)])
        let inputs = try await db.allFacesForGrouping()
        let plan = FaceGrouping.plan(faces: inputs, exclusions: [:])
        XCTAssertEqual(plan.newGroups.count, 1)
        let result = try await db.applyGroupingPlan(plan)
        XCTAssertEqual(result, CatalogDatabase.GroupingApplied(newPeople: 1, facesChanged: 3))
        // Applying the very same plan again changes nothing (an assignment to the person a face already has is not a change).
        let people0 = try await db.peopleSummaries()
        let repeated = try await db.applyGroupingPlan(FaceGrouping.Plan(assignments: inputs.map { FaceAssignment(faceID: $0.id, personID: people0[0].id) }, newGroups: [], deferred: 0))
        XCTAssertEqual(repeated.facesChanged, 0)
        let people = try await db.peopleSummaries()
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].faceCount, 3)
        let after = try await db.allFacesForGrouping()
        XCTAssertTrue(after.allSatisfy { $0.personId == people[0].id && !$0.isConfirmed })
        XCTAssertTrue(FaceGrouping.plan(faces: after, exclusions: [:]).isEmpty, "idempotent")
    }

    func testOnlyThePeopleAPlanTouchedAreEverPrunedAndOnlyIfUnnamedVisibleAndEmpty() async throws {
        let (db, photos) = try await importedDB(photoCount: 4)
        try await save(db, photos, prints: [vec(0), vec(1, plane: 1), vec(2, plane: 2), vec(3, plane: 3)])
        let faceIDs = try await db.allFacesForGrouping().map(\.id)
        let auto = try await db.createPerson(), hidden = try await db.createPerson(), named = try await db.createPerson(name: "Ann")
        let freshlyCreated = try await db.createPerson()                    // e.g. "New Person" in the UI, no faces yet
        try await db.applyAutomaticAssignments([FaceAssignment(faceID: faceIDs[0], personID: auto.id), FaceAssignment(faceID: faceIDs[1], personID: hidden.id),
                                                FaceAssignment(faceID: faceIDs[2], personID: named.id)])
        try await db.setPersonHidden(id: try XCTUnwrap(hidden.id), hidden: true)
        // A plan that takes all three faces out of their people.
        let plan = FaceGrouping.Plan(assignments: faceIDs.prefix(3).map { FaceAssignment(faceID: $0, personID: nil) }, newGroups: [], deferred: 0)
        let result = try await db.applyGroupingPlan(plan)
        XCTAssertEqual(result.facesChanged, 3)
        let ids = Set(try await db.peopleSummaries().map(\.id))
        XCTAssertFalse(ids.contains(try XCTUnwrap(auto.id)), "unnamed, visible, emptied by this plan: pruned")
        XCTAssertTrue(ids.contains(try XCTUnwrap(hidden.id)), "a person the user hid is kept")
        XCTAssertTrue(ids.contains(try XCTUnwrap(named.id)), "a named person is kept")
        XCTAssertTrue(ids.contains(try XCTUnwrap(freshlyCreated.id)), "a person the plan never touched is kept")
    }

    func testAGroupWhoseFacesWereAllConfirmedMeanwhileIsNotCountedOrLeftBehind() async throws {
        let (db, photos) = try await importedDB(photoCount: 2)
        try await save(db, photos, prints: [vec(0.01), vec(0.02)])
        let plan = FaceGrouping.plan(faces: try await db.allFacesForGrouping(), exclusions: [:])
        XCTAssertEqual(plan.newGroups.count, 1)
        let keeper = try await db.createPerson(name: "Kept")                // the user confirms both faces while grouping "ran"
        let faceIDs = try await db.allFacesForGrouping().map(\.id)
        try await db.assignFaces(faceIDs, to: keeper.id)
        let result = try await db.applyGroupingPlan(plan)
        XCTAssertEqual(result, CatalogDatabase.GroupingApplied(newPeople: 0, facesChanged: 0))
        let people = try await db.peopleSummaries()
        XCTAssertEqual(people.map(\.id), [try XCTUnwrap(keeper.id)], "no empty unnamed person was left behind")
    }
}
