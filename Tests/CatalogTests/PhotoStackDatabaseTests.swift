import GRDB
import XCTest
@testable import PhotoApp

final class PhotoStackDatabaseTests: XCTestCase {
    /// An in-memory catalog with photos named p1...pN; returns their ids in order.
    private func makeCatalog(_ count: Int) async throws -> (CatalogDatabase, [Int64]) {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (1...count).map { URL(fileURLWithPath: "/p/p\($0).jpg") })
        var ids: [Int64] = []
        for index in 1...count { ids.append(try need(try await db.photo(atPath: "/p/p\(index).jpg")?.id)) }
        return (db, ids)
    }

    private func proposal(_ ids: [Int64]) -> StackProposal { StackProposal(memberIDs: ids) }

    // MARK: Create / read

    func testCreateStackStoresMembersAndCover() async throws {
        let (db, ids) = try await makeCatalog(4)
        let stackID = try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true, cover: ids[1])
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks, [StackSnapshot(id: try XCTUnwrap(stackID), isManual: true, coverPhotoID: ids[1], memberIDs: [ids[0], ids[1], ids[2]])])
    }

    func testCreateNeedsTwoExistingPhotosAndIgnoresStaleIds() async throws {
        let (db, ids) = try await makeCatalog(2)
        let none = try await db.createStack(photoIDs: [ids[0], 9999], manual: true)
        XCTAssertNil(none)
        let alsoNone = try await db.createStack(photoIDs: [ids[0], ids[0]], manual: true)
        XCTAssertNil(alsoNone)
        let stacks = try await db.allStacks()
        XCTAssertTrue(stacks.isEmpty)
    }

    func testCoverThatIsNotAMemberIsIgnored() async throws {
        let (db, ids) = try await makeCatalog(3)
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true, cover: ids[2])
        let stacks = try await db.allStacks()
        XCTAssertNil(stacks.first?.coverPhotoID)
    }

    // MARK: Virtual copies

    func testACopyResolvesToItsMaster() async throws {
        let (db, ids) = try await makeCatalog(3)
        let master = try need(try await db.photo(atPath: "/p/p1.jpg"))
        let copy = try await db.createVirtualCopy(of: master, versionKey: "abcdef12")
        let copyID = try XCTUnwrap(copy.id)
        try await db.createStack(photoIDs: [copyID, ids[1]], manual: true, cover: copyID)
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks.first?.memberIDs, [ids[0], ids[1]])
        XCTAssertEqual(stacks.first?.coverPhotoID, ids[0])
        // The copy is not a second member; adding it again is a no-op.
        let added = try await db.addToStack(stackID: try XCTUnwrap(stacks.first?.id), photoIDs: [copyID])
        XCTAssertEqual(added, 0)
        let removed = try await db.removeFromStack(photoIDs: [copyID, ids[2]])
        XCTAssertEqual(removed, 1) // the copy resolved to its master
        let after = try await db.allStacks()
        XCTAssertTrue(after.isEmpty) // only one member left, so the stack dissolved
    }

    // MARK: Invariants

    func testAPhotoBelongsToAtMostOneStack() async throws {
        let (db, ids) = try await makeCatalog(5)
        let first = try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true)
        let second = try await db.createStack(photoIDs: [ids[2], ids[3]], manual: true)
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks.count, 2)
        XCTAssertEqual(stacks.first { $0.id == first }?.memberIDs, [ids[0], ids[1]])
        XCTAssertEqual(stacks.first { $0.id == second }?.memberIDs, [ids[2], ids[3]])
        let total = stacks.flatMap(\.memberIDs)
        XCTAssertEqual(total.count, Set(total).count)
    }

    func testRemovingBelowTwoMembersDissolvesTheStack() async throws {
        let (db, ids) = try await makeCatalog(3)
        try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true)
        _ = try await db.removeFromStack(photoIDs: [ids[0]])
        var stacks = try await db.allStacks()
        XCTAssertEqual(stacks.first?.memberIDs, [ids[1], ids[2]])
        _ = try await db.removeFromStack(photoIDs: [ids[1]])
        stacks = try await db.allStacks()
        XCTAssertTrue(stacks.isEmpty)
        let members = try await db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM photo_stack_member") }
        XCTAssertEqual(members, 0)
    }

    func testRemovingTheCoverClearsIt() async throws {
        let (db, ids) = try await makeCatalog(3)
        try await db.createStack(photoIDs: ids, manual: true, cover: ids[0])
        _ = try await db.removeFromStack(photoIDs: [ids[0]])
        let stacks = try await db.allStacks()
        XCTAssertNil(stacks.first?.coverPhotoID)
        XCTAssertEqual(stacks.first?.memberIDs.count, 2)
    }

    func testTouchingAnAutomaticStackMakesItManual() async throws {
        let (db, ids) = try await makeCatalog(5)
        try await db.replaceAutomaticStacks(inScope: ids, with: [proposal([ids[0], ids[1], ids[2]])])
        var stacks = try await db.allStacks()
        XCTAssertEqual(stacks.first?.isManual, false)
        let stackID = try XCTUnwrap(stacks.first?.id)
        try await db.setCover(stackID: stackID, photoID: ids[2])
        stacks = try await db.allStacks()
        XCTAssertEqual(stacks.first?.isManual, true)
        XCTAssertEqual(stacks.first?.coverPhotoID, ids[2])

        try await db.dissolveStack(stackID: stackID)
        try await db.clearStackExclusions()
        try await db.replaceAutomaticStacks(inScope: ids, with: [proposal([ids[0], ids[1]])])
        let autoID = try need(try await db.allStacks().first?.id)
        try await db.addToStack(stackID: autoID, photoIDs: [ids[3]])
        let touched = try await db.allStacks()
        XCTAssertEqual(touched.first?.isManual, true)
        XCTAssertEqual(touched.first?.memberIDs, [ids[0], ids[1], ids[3]])

        try await db.dissolveStack(stackID: autoID)
        try await db.clearStackExclusions()
        try await db.replaceAutomaticStacks(inScope: ids, with: [proposal([ids[0], ids[1], ids[2]])])
        let again = try need(try await db.allStacks().first?.id)
        _ = try await db.removeFromStack(photoIDs: [ids[0]])
        let removedFrom = try await db.allStacks()
        XCTAssertEqual(removedFrom.first { $0.id == again }?.isManual, true)
    }

    func testTakingMembersForAManualStackTouchesTheOldOne() async throws {
        let (db, ids) = try await makeCatalog(5)
        try await db.replaceAutomaticStacks(inScope: ids, with: [proposal([ids[0], ids[1], ids[2]])])
        try await db.createStack(photoIDs: [ids[2], ids[3]], manual: true)
        let stacks = try await db.allStacks()
        let old = try XCTUnwrap(stacks.first { $0.memberIDs.contains(ids[0]) })
        XCTAssertEqual(old.memberIDs, [ids[0], ids[1]])
        XCTAssertTrue(old.isManual)
    }

    func testSetCoverRefusesANonMember() async throws {
        let (db, ids) = try await makeCatalog(3)
        let stackID = try need(try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true))
        let ok = try await db.setCover(stackID: stackID, photoID: ids[2])
        XCTAssertFalse(ok)
    }

    // MARK: Cascades

    func testDeletingAPhotoRemovesItsMembershipAndDissolvesNothingElse() async throws {
        let (db, ids) = try await makeCatalog(4)
        try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true, cover: ids[0])
        try await db.deletePhoto(id: ids[0])
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks.first?.memberIDs, [ids[1], ids[2]]) // cascade removed the member row
        XCTAssertNil(stacks.first?.coverPhotoID) // cover FK went to NULL
    }

    func testDeletingBothMembersOfAStackLeavesNoStackRow() async throws {
        let (db, ids) = try await makeCatalog(2)
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true)
        try await db.deletePhoto(id: ids[0]) // the cascade removes one member; the trigger must remove the stack
        var rows = try await db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM photo_stack") }
        XCTAssertEqual(rows, 0)
        try await db.deletePhoto(id: ids[1])
        rows = try await db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM photo_stack") }
        XCTAssertEqual(rows, 0)
        let members = try await db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM photo_stack_member") }
        XCTAssertEqual(members, 0)
    }

    func testBatchDeleteOfAStacksPhotosLeavesNoStack() async throws {
        let (db, ids) = try await makeCatalog(4)
        try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: true)
        _ = try await db.deletePhotos(ids: [ids[0], ids[1]])
        let stacks = try await db.allStacks()
        XCTAssertTrue(stacks.isEmpty)
    }

    func testAOneMemberStackCanNeverExcludeAPhotoFromAnAutomaticRun() async throws {
        let (db, ids) = try await makeCatalog(4)
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true)
        try await db.deletePhoto(id: ids[1]) // the manual stack is gone, not left holding ids[0]
        let created = try await db.replaceAutomaticStacks(inScope: ids, with: [proposal([ids[0], ids[2]])])
        XCTAssertEqual(created, 1)
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks.map(\.memberIDs), [[ids[0], ids[2]]])
    }

    func testDissolveRemovesMembersAndKeepsPhotos() async throws {
        let (db, ids) = try await makeCatalog(3)
        let stackID = try need(try await db.createStack(photoIDs: ids, manual: true))
        try await db.dissolveStack(stackID: stackID)
        let photos = try await db.allPhotos()
        XCTAssertEqual(photos.count, 3)
        let members = try await db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM photo_stack_member") }
        XCTAssertEqual(members, 0)
    }

    // MARK: Automatic runs

    func testAutomaticRunReplacesOnlyAutomaticStacksInScope() async throws {
        let (db, ids) = try await makeCatalog(8)
        try await db.replaceAutomaticStacks(inScope: ids, with: [proposal([ids[0], ids[1]]), proposal([ids[2], ids[3]])])
        var stacks = try await db.allStacks()
        XCTAssertEqual(stacks.count, 2)
        // A second run over the same scope with a different plan replaces both.
        let created = try await db.replaceAutomaticStacks(inScope: ids, with: [proposal([ids[4], ids[5]])])
        XCTAssertEqual(created, 1)
        stacks = try await db.allStacks()
        XCTAssertEqual(stacks.map(\.memberIDs), [[ids[4], ids[5]]])
    }

    func testAutomaticRunLeavesOutOfScopeStacksAlone() async throws {
        let (db, ids) = try await makeCatalog(6)
        try await db.replaceAutomaticStacks(inScope: ids, with: [proposal([ids[0], ids[1]]), proposal([ids[4], ids[5]])])
        try await db.replaceAutomaticStacks(inScope: [ids[0], ids[1], ids[2], ids[3]], with: [proposal([ids[2], ids[3]])])
        let sets = try await db.allStacks().map(\.memberIDs)
        XCTAssertEqual(Set(sets), [[ids[2], ids[3]], [ids[4], ids[5]]])
    }

    func testManualStacksSurviveAnAutomaticRunAndTheirMembersAreExcluded() async throws {
        let (db, ids) = try await makeCatalog(6)
        let manual = try need(try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true, cover: ids[1]))
        let created = try await db.replaceAutomaticStacks(inScope: ids, with: [
            proposal([ids[0], ids[2], ids[3]]), // ids[0] is locked: stack is [2, 3]
            proposal([ids[1], ids[4]]) // 1 is locked and 4 alone is below two
        ])
        XCTAssertEqual(created, 1)
        let stacks = try await db.allStacks()
        let kept = try XCTUnwrap(stacks.first { $0.id == manual })
        XCTAssertEqual(kept, StackSnapshot(id: manual, isManual: true, coverPhotoID: ids[1], memberIDs: [ids[0], ids[1]]))
        XCTAssertEqual(stacks.first { $0.id != manual }?.memberIDs, [ids[2], ids[3]])
    }

    func testAutomaticRunIgnoresOutOfScopeAndStaleMembersAndFirstProposalWinsAPhoto() async throws {
        let (db, ids) = try await makeCatalog(5)
        let created = try await db.replaceAutomaticStacks(inScope: [ids[0], ids[1], ids[2]], with: [
            proposal([ids[0], ids[1], ids[4], 9999]),
            proposal([ids[1], ids[2]]) // 1 already placed, leaves one member: dropped
        ])
        XCTAssertEqual(created, 1)
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks.map(\.memberIDs), [[ids[0], ids[1]]])
        XCTAssertEqual(stacks.first?.coverPhotoID, ids[0])
        XCTAssertEqual(stacks.first?.isManual, false)
    }

    func testAutomaticCoverNotSurvivingFallsBackToTheFirstRemainingMember() async throws {
        let (db, ids) = try await makeCatalog(4)
        try await db.replaceAutomaticStacks(inScope: [ids[1], ids[2]], with: [proposal([ids[0], ids[1], ids[2]])])
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks.first?.memberIDs, [ids[1], ids[2]])
        XCTAssertEqual(stacks.first?.coverPhotoID, ids[1])
    }

    func testAutomaticRunOverCopiesUsesMasters() async throws {
        let (db, ids) = try await makeCatalog(3)
        let master = try need(try await db.photo(atPath: "/p/p1.jpg"))
        let copyID = try need(try await db.createVirtualCopy(of: master, versionKey: "abcdef12").id)
        try await db.replaceAutomaticStacks(inScope: [copyID, ids[1]], with: [proposal([copyID, ids[1]])])
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks.map(\.memberIDs), [[ids[0], ids[1]]])
    }

    func testLargeScopesAreChunked() async throws {
        let db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (1...1200).map { URL(fileURLWithPath: "/p/q\($0).jpg") })
        let ids = try await db.allPhotos().compactMap(\.id)
        XCTAssertEqual(ids.count, 1200)
        let created = try await db.replaceAutomaticStacks(inScope: ids, with: [proposal(ids)])
        XCTAssertEqual(created, 1)
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks.first?.memberIDs.count, 1200)
        let removed = try await db.removeFromStack(photoIDs: ids)
        XCTAssertEqual(removed, 1200)
        let after = try await db.allStacks()
        XCTAssertTrue(after.isEmpty)
    }

    func testPlannerCreateSkipsPhotosInManualStacks() async throws {
        let (db, ids) = try await makeCatalog(4)
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true)
        let none = try await db.createStack(photoIDs: [ids[1], ids[2]], manual: false)
        XCTAssertNil(none)
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks.count, 1)
    }

    func testDeferredPhotosKeepTheirOldAutomaticStacksWhenScopeIsPlannedIDs() async throws {
        let (db, ids) = try await makeCatalog(8)
        // An earlier run stacked 1+2 (old photos).
        try await db.replaceAutomaticStacks(inScope: ids, with: [proposal([ids[0], ids[1]])])
        // This run is capped to the newest 4 candidates (ids 5...8 here), so 1 and 2 are deferred.
        var candidates: [StackCandidate] = []
        for (index, id) in ids.enumerated() { candidates.append(StackCandidate(id: id, captureDate: Double(index) * 0.5, featurePrint: nil)) }
        var params = StackPlanner.Params()
        params.maximumCandidatesPerRun = 4
        params.maxGapWithoutPrintSeconds = 1
        let plan = StackPlanner.plan(candidates, params: params)
        XCTAssertEqual(plan.deferred, 4)
        XCTAssertEqual(plan.plannedIDs, Array(ids.suffix(4)))
        try await db.replaceAutomaticStacks(inScope: plan.plannedIDs, with: plan.proposals)
        let stacks = try await db.allStacks()
        XCTAssertTrue(stacks.contains { $0.memberIDs == [ids[0], ids[1]] }, "deferred photos lost their stack")
        XCTAssertTrue(stacks.contains { $0.memberIDs == Array(ids.suffix(4)) })
    }

    func testMissingPlannedCoverFallsBackToTheNextBestMember() async throws {
        let (db, ids) = try await makeCatalog(4)
        try await db.createStack(photoIDs: [ids[0], ids[3]], manual: true) // ids[0] is locked
        try await db.replaceAutomaticStacks(inScope: ids, with: [proposal([ids[0], ids[2], ids[1]])])
        let auto = try await db.allStacks().first { !$0.isManual }
        XCTAssertEqual(auto?.memberIDs, [ids[1], ids[2]])
        XCTAssertEqual(auto?.coverPhotoID, ids[2]) // the next best in proposal order, not nil
    }

    // MARK: Remembered unstack

    func testDissolvedStackIsNotRebuiltByTheNextAutomaticRun() async throws {
        let (db, ids) = try await makeCatalog(4)
        try await db.replaceAutomaticStacks(inScope: ids, with: [proposal([ids[0], ids[1]])])
        let stackID = try need(try await db.allStacks().first?.id)
        try await db.dissolveStack(stackID: stackID)
        let exclusions = try await db.stackExclusions()
        XCTAssertEqual(exclusions, [ids[0], ids[1]])
        let created = try await db.replaceAutomaticStacks(inScope: ids, with: [proposal([ids[0], ids[1]]), proposal([ids[2], ids[3]])])
        XCTAssertEqual(created, 1)
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks.map(\.memberIDs), [[ids[2], ids[3]]])
    }

    func testRemovingAPhotoFromAStackIsRememberedAndOnlyForThosePhotos() async throws {
        let (db, ids) = try await makeCatalog(4)
        try await db.replaceAutomaticStacks(inScope: ids, with: [proposal([ids[0], ids[1], ids[2]])])
        _ = try await db.removeFromStack(photoIDs: [ids[1], ids[3]]) // ids[3] was in no stack: not recorded
        let exclusions = try await db.stackExclusions()
        XCTAssertEqual(exclusions, [ids[1]])
        let none = try await db.createStack(photoIDs: [ids[1], ids[3]], manual: false) // a planner may not take an excluded photo
        XCTAssertNil(none)
    }

    func testManualStackingClearsTheExclusion() async throws {
        let (db, ids) = try await makeCatalog(4)
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true)
        _ = try await db.removeFromStack(photoIDs: [ids[0]])
        var exclusions = try await db.stackExclusions()
        XCTAssertEqual(exclusions, [ids[0]])
        try await db.createStack(photoIDs: [ids[0], ids[2], ids[3]], manual: true)
        exclusions = try await db.stackExclusions()
        XCTAssertTrue(exclusions.isEmpty)
        // addToStack clears too.
        let stackID = try need(try await db.allStacks().first?.id)
        _ = try await db.removeFromStack(photoIDs: [ids[2]])
        _ = try await db.addToStack(stackID: stackID, photoIDs: [ids[2]])
        exclusions = try await db.stackExclusions()
        XCTAssertTrue(exclusions.isEmpty)
    }

    func testExclusionsCascadeWithThePhotoAndCanBeCleared() async throws {
        let (db, ids) = try await makeCatalog(3)
        try await db.createStack(photoIDs: ids, manual: true)
        _ = try await db.removeFromStack(photoIDs: [ids[0], ids[1]])
        try await db.deletePhoto(id: ids[0])
        var exclusions = try await db.stackExclusions()
        XCTAssertEqual(exclusions, [ids[1]])
        try await db.clearStackExclusions()
        exclusions = try await db.stackExclusions()
        XCTAssertTrue(exclusions.isEmpty)
    }

    // MARK: Migration and backup

    func testMigration017AddsTheTablesToAPopulatedPre017Catalog() async throws {
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
            Migration016PhotoInfo.register(in: &migrator)
            try migrator.migrate(queue)
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO photo (path, filename, importedAt, rating, flagStatus, colorLabel) VALUES ('/tmp/old.jpg', 'old.jpg', '2026-01-01 00:00:00', 3, 0, 0)")
                try db.execute(sql: "INSERT INTO photo (path, filename, importedAt, rating, flagStatus, colorLabel) VALUES ('/tmp/old2.jpg', 'old2.jpg', '2026-01-02 00:00:00', 1, 0, 0)")
            }
        }
        let db = try CatalogDatabase(path: path)
        let photos = try await db.allPhotos()
        XCTAssertEqual(photos.count, 2)
        XCTAssertEqual(photos.first?.rating, 3)
        let empty = try await db.allStacks()
        XCTAssertTrue(empty.isEmpty)
        let ids = photos.compactMap(\.id)
        try await db.createStack(photoIDs: ids, manual: true)
        let stored = try await db.allStacks()
        XCTAssertEqual(stored.first?.memberIDs, ids.sorted())
    }

    func testABackupKeepsTheStacks() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stack-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("live.sqlite")
        let db = try CatalogDatabase(path: live.path)
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/a.jpg"), URL(fileURLWithPath: "/tmp/b.jpg")])
        let ids = try await db.allPhotos().compactMap(\.id)
        let stackID = try need(try await db.createStack(photoIDs: ids, manual: true, cover: ids[1]))
        let backup = dir.appendingPathComponent("backup.sqlite")
        _ = try await db.backUp(to: backup)
        let reopened = try CatalogDatabase(path: backup.path)
        let stacks = try await reopened.allStacks()
        XCTAssertEqual(stacks, [StackSnapshot(id: stackID, isManual: true, coverPhotoID: ids[1], memberIDs: ids.sorted())])
    }
}

/// XCTUnwrap takes an autoclosure, which cannot contain await.
private func need<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
