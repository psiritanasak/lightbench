import XCTest
@testable import PhotoApp

/// `AutoStackModel` end to end with injected collaborators: no Vision, no files, no real planner clock. Photos s1...s4 are shot one
/// second apart; the injected "feature prints" put s1-s3 in one plane (alike) and s4 in another.
@MainActor
final class AutoStackModelTests: XCTestCase {
    private var db: CatalogDatabase!
    private var photos: [Photo] = []
    private var metadata: [Int64: PhotoMetadata] = [:]
    private var model: AutoStackModel!

    nonisolated private static func print(plane: Int, angle: Double = 0) -> Data {
        var floats = [Float](repeating: 0, count: FeaturePrintVector.elementCount)
        floats[plane * 2] = Float(cos(angle))
        floats[plane * 2 + 1] = Float(sin(angle))
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    override func setUp() async throws {
        db = try CatalogDatabase(inMemory: true)
        _ = try await db.importPhotos(at: (1...4).map { URL(fileURLWithPath: "/tmp/as/s\($0).jpg") })
        photos = try await db.allPhotos()
        metadata = [:]
        for (offset, photo) in photos.enumerated() {
            let id = try XCTUnwrap(photo.id)
            metadata[id] = PhotoMetadata(photoId: id, fileSize: 1000, mtime: 1, readerRevision: PhotoMetadata.currentReaderRevision, captureDate: 1_000_000 + Double(offset), scannedAt: Date())
        }
        model = AutoStackModel()
        model.seams = AutoStackModel.Seams(
            environment: DuplicateScanner.Environment(
                stat: { _ in (1000, 1) },
                hash: { _ in nil },
                featurePrint: { path in path.hasSuffix("s4.jpg") ? Self.print(plane: 1) : Self.print(plane: 0, angle: 0.01) }
            ),
            plan: { StackPlanner.plan($0, params: $1) },
            persist: { _ in },
            apply: { database, plan in try await database.replaceAutomaticStacks(inScope: plan.plannedIDs, with: plan.proposals) }
        )
    }

    override func tearDown() async throws { model = nil; db = nil }

    private func scan() async throws {
        model.begin(photos: photos, metadata: metadata, database: db)
        for _ in 0..<400 where model.isScanning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isScanning, "the scan finished")
    }

    private var ids: [Int64] { photos.compactMap(\.id) }

    // MARK: Preview and apply

    func testScanPlansAPreviewAndWritesNothingUntilApply() async throws {
        try await scan()
        XCTAssertEqual(model.preview, AutoStackModel.Preview(stackCount: 1, photoCount: 3, deferred: 0, replacedStacks: 0), "s1-s3 look alike; s4 does not")
        XCTAssertEqual(model.scopeCount, 4)
        let before = try await db.allStacks()
        XCTAssertTrue(before.isEmpty, "a preview writes nothing")
        var refreshed = false
        let created = await model.apply(database: db) { refreshed = true }
        XCTAssertEqual(created, 1)
        XCTAssertTrue(refreshed, "the Library is re-read after Apply")
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks.count, 1)
        XCTAssertEqual(Set(stacks[0].memberIDs), Set(ids.prefix(3)))
        XCTAssertFalse(stacks[0].isManual, "an automatic run makes automatic stacks")
        XCTAssertNil(model.preview, "applied: nothing left to apply twice")
    }

    func testApplyWithoutAPreviewDoesNothing() async throws {
        let created = await model.apply(database: db)
        XCTAssertNil(created)
        let stacks = try await db.allStacks()
        XCTAssertTrue(stacks.isEmpty)
    }

    func testPlanningRunsOffTheMainThread() async throws {
        let ran = AutoStackBox<[Bool]>([])
        model.seams.plan = { candidates, params in
            ran.mutate { $0.append(Thread.isMainThread) }
            return StackPlanner.plan(candidates, params: params)
        }
        try await scan()
        XCTAssertEqual(ran.value, [false], "the planner ran once, off the main thread")
        model.maxGapSeconds = 5
        for _ in 0..<200 where ran.value.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(ran.value, [false, false], "a gap change re-plans, also off the main thread")
    }

    func testChangingTheGapReplansTheScannedPhotosWithoutRescanning() async throws {
        // s1, s2 one second apart; s3 five seconds after s2.
        metadata[ids[2]]?.captureDate = 1_000_001 + 5
        metadata[ids[3]]?.captureDate = 1_000_100 // far from the rest, so only s3's gap matters
        let seen = AutoStackBox<[Double]>([])
        model.seams.plan = { candidates, params in
            seen.mutate { $0.append(params.maxGapSeconds) }
            return StackPlanner.plan(candidates, params: params)
        }
        try await scan()
        XCTAssertEqual(model.preview?.photoCount, 2, "3 s default: s3 is five seconds away")
        model.maxGapSeconds = 6
        for _ in 0..<200 where model.preview?.photoCount != 3 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.preview?.photoCount, 3, "6 s joins s3 without scanning again")
        XCTAssertEqual(seen.value, [3, 6])
    }

    func testTheLiveSeamNeverHashesAFile() {
        XCTAssertNil(AutoStackModel.Seams.live.environment.hash("/tmp/anything.jpg"), "stacking needs prints only; the scanner's hash step is a no-op")
    }

    func testTheGapIsClampedToOneThroughTen() {
        model.maxGapSeconds = 99
        XCTAssertEqual(model.maxGapSeconds, 10)
        model.maxGapSeconds = -4
        XCTAssertEqual(model.maxGapSeconds, 1)
    }

    // MARK: Cancel, clear, refusals

    func testCancelKeepsTheLibraryUntouchedAndShowsNoPreview() async throws {
        let started = AutoStackBox(false)
        model.seams.environment.featurePrint = { _ in
            started.set(true)
            Thread.sleep(forTimeInterval: 0.05)
            return Self.print(plane: 0)
        }
        model.begin(photos: photos, metadata: metadata, database: db)
        for _ in 0..<200 where !started.value { try await Task.sleep(nanoseconds: 5_000_000) }
        model.cancel()
        for _ in 0..<400 where model.isScanning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isScanning)
        XCTAssertNil(model.preview, "a cancelled scan proposes nothing")
        XCTAssertEqual(model.statusMessage, "Cancelled. Nothing was changed.")
        let stacks = try await db.allStacks()
        XCTAssertTrue(stacks.isEmpty)
    }

    func testNoPhotosSaysSoAndStartsNothing() async throws {
        model.begin(photos: [], metadata: [:], database: db)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.statusMessage, "There are no photos to stack.")
    }

    func testVirtualCopiesAreNotCandidates() async throws {
        let master = try XCTUnwrap(photos.first)
        let copy = try await db.createVirtualCopy(of: master, versionKey: "abcdef12")
        model.begin(photos: photos + [copy], metadata: metadata, database: db)
        for _ in 0..<400 where model.isScanning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.scopeCount, 4, "the copy is not counted: it follows its master")
        XCTAssertEqual(model.preview?.photoCount, 3)
    }

    func testClearDropsASettlingScanAndTheOldPreview() async throws {
        try await scan()
        XCTAssertNotNil(model.preview)
        model.clear()
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.scopeCount, 0)
        XCTAssertEqual(model.maxGapSeconds, AutoStackModel.defaultGap)
        let created = await model.apply(database: db)
        XCTAssertNil(created, "a cleared session has nothing to apply")
    }

    // MARK: What an automatic run may not touch

    func testManualStacksAndUnstackedPhotosAreLeftOutOfThePreview() async throws {
        try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true)
        try await scan()
        XCTAssertEqual(model.skippedManual, 2)
        XCTAssertEqual(model.preview?.stackCount, 0, "s3 alone cannot form a stack once s1/s2 are held by a manual one")
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks.count, 1, "the manual stack is unchanged")
    }

    func testUnstackedPhotosAreSkippedUntilTheyAreForgotten() async throws {
        let stackID = try need(try await db.createStack(photoIDs: [ids[0], ids[1]], manual: true))
        try await db.dissolveStack(stackID: stackID)
        try await scan()
        XCTAssertEqual(model.skippedUnstacked, 2)
        XCTAssertEqual(model.preview?.stackCount, 0, "s1 and s2 were unstacked by the user; s3 alone is no burst")

        await model.forgetUnstacked(database: db)
        XCTAssertEqual(model.skippedUnstacked, 0)
        try await scan()
        XCTAssertEqual(model.preview, AutoStackModel.Preview(stackCount: 1, photoCount: 3, deferred: 0, replacedStacks: 0))
    }

    func testAnApplyReplacesTheEarlierAutomaticStackButNeverAManualOne() async throws {
        // Two more photos, far from the burst, held by a MANUAL stack.
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/as/m1.jpg"), URL(fileURLWithPath: "/tmp/as/m2.jpg")])
        photos = try await db.allPhotos()
        let manualIDs = try photos.filter { $0.path.contains("/m") }.map { try XCTUnwrap($0.id) }
        XCTAssertEqual(manualIDs.count, 2)
        for (offset, id) in manualIDs.enumerated() {
            metadata[id] = PhotoMetadata(photoId: id, fileSize: 1000, mtime: 1, readerRevision: PhotoMetadata.currentReaderRevision, captureDate: 2_000_000 + Double(offset), scannedAt: Date())
        }
        let manualID = try need(try await db.createStack(photoIDs: manualIDs, manual: true))

        try await scan()
        _ = await model.apply(database: db)
        let first = try await db.allStacks()
        XCTAssertEqual(first.count, 2)
        let automaticFirst = try XCTUnwrap(first.first { !$0.isManual })
        try await scan()
        _ = await model.apply(database: db)
        let second = try await db.allStacks()
        XCTAssertEqual(second.count, 2, "re-running replaces the automatic stack instead of adding a second one")
        let automaticSecond = try XCTUnwrap(second.first { !$0.isManual })
        XCTAssertNotEqual(automaticSecond.id, automaticFirst.id, "the automatic stack was REPLACED, not left alone")
        XCTAssertEqual(Set(automaticSecond.memberIDs), Set(automaticFirst.memberIDs))
        let manual = try XCTUnwrap(second.first { $0.id == manualID })
        XCTAssertTrue(manual.isManual, "the manual stack survived untouched")
        XCTAssertEqual(Set(manual.memberIDs), Set(manualIDs))
    }

    // MARK: Apply only writes the previewed plan

    func testAGapChangedDuringTheScanIsPlannedAgainNotDropped() async throws {
        metadata[ids[2]]?.captureDate = 1_000_001 + 5
        metadata[ids[3]]?.captureDate = 1_000_100
        let started = AutoStackBox(false)
        model.seams.environment.featurePrint = { _ in
            started.set(true)
            Thread.sleep(forTimeInterval: 0.05)
            return Self.print(plane: 0, angle: 0.01)
        }
        model.begin(photos: photos, metadata: metadata, database: db)
        for _ in 0..<200 where !started.value { try await Task.sleep(nanoseconds: 5_000_000) }
        model.maxGapSeconds = 6 // moved while the scan runs
        for _ in 0..<400 where model.isScanning || model.isReplanning || model.plannedGap != 6 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.plannedGap, 6, "the plan on screen is for the gap on screen")
        XCTAssertEqual(model.preview?.photoCount, 3)
        XCTAssertTrue(model.canApply)
    }

    func testApplyIsOfferedOnlyForThePlanOnScreen() async throws {
        let gate = AutoStackBox(true) // true = hold the re-plan
        defer { gate.set(false) } // a failing assertion must not leave the detached planner spinning
        model.seams.plan = { candidates, params in
            while gate.value && params.maxGapSeconds != AutoStackModel.defaultGap { Thread.sleep(forTimeInterval: 0.01) }
            return StackPlanner.plan(candidates, params: params)
        }
        try await scan()
        XCTAssertTrue(model.canApply)
        model.maxGapSeconds = 5
        XCTAssertFalse(model.canApply, "the gap on screen differs from the plan's gap while the re-plan runs")
        let refused = await model.apply(database: db)
        XCTAssertNil(refused, "an Apply for a stale plan writes nothing")
        let stacks = try await db.allStacks()
        XCTAssertTrue(stacks.isEmpty)
        gate.set(false)
        for _ in 0..<400 where !model.canApply { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.canApply, "offered again once the new plan landed")
    }

    // MARK: What a run may not dissolve

    func testAnOfflinePhotoKeepsItsAutomaticStack() async throws {
        // An automatic stack of two photos whose files cannot be read (offline volume): the run never looked at them.
        let old = try need(try await db.createStack(photoIDs: [ids[2], ids[3]], manual: false))
        model.seams.environment.stat = { path in (path.hasSuffix("s3.jpg") || path.hasSuffix("s4.jpg")) ? nil : (1000, 1) }
        try await scan()
        XCTAssertEqual(model.unreadableCount, 2)
        _ = await model.apply(database: db)
        let stacks = try await db.allStacks()
        XCTAssertTrue(stacks.contains { $0.id == old && Set($0.memberIDs) == Set([ids[2], ids[3]]) },
                      "photos that could not be examined keep their automatic stack")
        XCTAssertEqual(stacks.count, 2, "s1 and s2 were examined and stacked")
    }

    func testAnUndatedPhotoKeepsItsAutomaticStack() async throws {
        _ = try await db.importPhotos(at: [URL(fileURLWithPath: "/tmp/as/u1.jpg"), URL(fileURLWithPath: "/tmp/as/u2.jpg")])
        photos = try await db.allPhotos()
        let undated = try photos.filter { $0.path.contains("/u") }.map { try XCTUnwrap($0.id) }
        let old = try need(try await db.createStack(photoIDs: undated, manual: false))
        try await scan()
        XCTAssertEqual(model.undatedCount, 2)
        _ = await model.apply(database: db)
        let stacks = try await db.allStacks()
        XCTAssertTrue(stacks.contains { $0.id == old }, "photos without a capture date were not examined: their stack is kept")
    }

    func testThePreviewSaysHowManyAutomaticStacksItReplaces() async throws {
        _ = try await db.createStack(photoIDs: [ids[0], ids[1]], manual: false)
        try await scan()
        XCTAssertEqual(model.preview?.replacedStacks, 1)
    }

    // MARK: Apply, dismiss, reopen

    func testAnApplyInFlightCannotBeClearedAndAlwaysRefreshesTheLibrary() async throws {
        try await scan()
        let release = AutoStackBox(false)
        model.seams.apply = { database, plan in
            while !release.value { try await Task.sleep(nanoseconds: 5_000_000) }
            return try await database.replaceAutomaticStacks(inScope: plan.plannedIDs, with: plan.proposals)
        }
        let refreshed = AutoStackBox(0)
        let task = Task { await self.model.apply(database: self.db) { refreshed.mutate { $0 += 1 } } }
        for _ in 0..<200 where !model.isApplying { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(model.isApplying)
        XCTAssertTrue(model.isWorking, "every busy flag holds during the write")
        model.clear() // the sheet was dismissed and reopened
        XCTAssertTrue(model.isApplying, "clear() refuses while a write is running")
        XCTAssertFalse(model.canApply)
        XCTAssertNotNil(model.preview, "the reopened sheet did not wipe the session the running Apply belongs to")
        XCTAssertEqual(model.scopeCount, 4)
        release.set(true)
        let created = await task.value
        XCTAssertEqual(created, 1)
        XCTAssertEqual(refreshed.value, 1, "the refresh after a started Apply always runs")
        XCTAssertFalse(model.isWorking)
    }

    func testTheRefreshStillRunsWhenTheWriteFails() async throws {
        try await scan()
        model.seams.apply = { _, _ in throw NSError(domain: "t", code: 1) }
        let refreshed = AutoStackBox(0)
        let created = await model.apply(database: db) { refreshed.mutate { $0 += 1 } }
        XCTAssertNil(created)
        XCTAssertEqual(refreshed.value, 1)
        XCTAssertFalse(model.isApplying)
    }

    func testForgettingUnstackedPhotosSaysItIsTheWholeLibrary() async throws {
        await model.forgetUnstacked(database: db)
        XCTAssertTrue(try XCTUnwrap(model.statusMessage).contains("whole library"))
    }

    // MARK: A run never dissolves a stack it did not fully examine

    private func scan(of shown: [Photo]) async throws {
        model.begin(photos: shown, metadata: metadata, database: db)
        for _ in 0..<400 where model.isScanning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isScanning)
    }

    func testAStackWithAMemberTheViewHidesIsLeftIntact() async throws {
        let old = try need(try await db.createStack(photoIDs: [ids[0], ids[1]], manual: false))
        try await scan(of: photos.filter { $0.id != ids[1] }) // s2 is filtered out of the shown photos
        XCTAssertEqual(model.preview?.keptStacks, 1)
        XCTAssertEqual(model.preview?.replacedStacks, 0)
        _ = await model.apply(database: db)
        let stacks = try await db.allStacks()
        XCTAssertTrue(stacks.contains { $0.id == old && Set($0.memberIDs) == Set([ids[0], ids[1]]) }, "s1 was examined but its partner was not: the stack stays whole")
        XCTAssertFalse(stacks.contains { $0.id != old && $0.memberIDs.contains(ids[0]) }, "s1 is not re-stacked elsewhere either")
    }

    func testAStackStraddlingTheShownFolderIsLeftIntactWhileTheRestIsStacked() async throws {
        let straddling = try need(try await db.createStack(photoIDs: [ids[1], ids[3]], manual: false)) // s4 is in another collection
        try await scan(of: photos.filter { $0.id != ids[3] })
        XCTAssertEqual(model.preview?.keptStacks, 1)
        _ = await model.apply(database: db)
        let stacks = try await db.allStacks()
        XCTAssertTrue(stacks.contains { $0.id == straddling && Set($0.memberIDs) == Set([ids[1], ids[3]]) })
        XCTAssertTrue(stacks.contains { $0.id != straddling && Set($0.memberIDs) == Set([ids[0], ids[2]]) }, "s1 and s3 still make a stack")
    }

    func testAStackEntirelyOutsideTheViewIsNotReportedAsKept() async throws {
        let far = try need(try await db.createStack(photoIDs: [ids[2], ids[3]], manual: false))
        try await scan(of: photos.filter { $0.id == ids[0] || $0.id == ids[1] })
        XCTAssertEqual(model.preview?.keptStacks, 0, "it is not part of what the user is looking at")
        _ = await model.apply(database: db)
        let stacks = try await db.allStacks()
        XCTAssertTrue(stacks.contains { $0.id == far }, "and it is untouched")
    }

    func testTheCapLeavesAStackWithACappedMemberAlone() async throws {
        let old = try need(try await db.createStack(photoIDs: [ids[0], ids[1], ids[2]], manual: false))
        model.candidateCap = 2 // the newest two (s3, s4) are examined
        try await scan()
        XCTAssertEqual(model.preview?.deferred, 2, "the cap is reported by the model")
        XCTAssertEqual(model.preview?.keptStacks, 1)
        _ = await model.apply(database: db)
        let stacks = try await db.allStacks()
        XCTAssertEqual(stacks.map(\.id), [old], "s3 was examined but s1 and s2 were not: the stack is whole and nothing else was made")
        XCTAssertEqual(Set(try XCTUnwrap(stacks.first).memberIDs), Set([ids[0], ids[1], ids[2]]))
    }

    func testAPhotoWithoutAPrintInAnAutomaticStackCountsAsNotExamined() async throws {
        try await scan()
        _ = await model.apply(database: db) // an automatic stack of s1-s3 built with prints
        let built = try await db.allStacks()
        XCTAssertEqual(built.count, 1)
        model.seams.environment.featurePrint = { _ in nil } // the prints can no longer be read
        try await scan()
        XCTAssertEqual(model.preview?.keptStacks, 1)
        _ = await model.apply(database: db)
        let after = try await db.allStacks()
        XCTAssertEqual(after, built, "the stack is exactly as it was: same id, members and cover")
    }

    func testAPhotoWithoutAPrintInNoStackStaysATimeOnlyCandidate() async throws {
        model.seams.environment.featurePrint = { _ in nil }
        metadata[ids[1]]?.captureDate = 1_000_000 // same second as s1
        metadata[ids[2]]?.captureDate = 1_000_500 // s3 and s4 far away from everything
        metadata[ids[3]]?.captureDate = 1_000_900
        try await scan()
        XCTAssertEqual(model.preview?.stackCount, 1, "s1 and s2 within a second, no prints: time alone")
    }

    // MARK: Cancel and counts

    func testCancelWhileThePlanIsBeingBuiltShowsNoPreview() async throws {
        let entered = AutoStackBox(false)
        let release = AutoStackBox(false)
        defer { release.set(true) }
        model.seams.plan = { candidates, params in
            entered.set(true)
            while !release.value { Thread.sleep(forTimeInterval: 0.01) }
            return StackPlanner.plan(candidates, params: params)
        }
        model.begin(photos: photos, metadata: metadata, database: db)
        for _ in 0..<400 where !entered.value { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(entered.value)
        model.cancel()
        release.set(true)
        for _ in 0..<400 where model.isScanning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.preview, "cancelled while planning: nothing to apply")
        XCTAssertEqual(model.statusMessage, "Cancelled. Nothing was changed.")
        XCTAssertFalse(model.canApply)
    }

    func testTheShownCountIsTakenOnceAtScanStart() async throws {
        XCTAssertEqual(model.shownCount, 0)
        try await scan()
        XCTAssertEqual(model.shownCount, 4)
    }

    func testTheApplyMessageSaysExpandedStacksCollapse() async throws {
        try await scan()
        _ = await model.apply(database: db)
        XCTAssertTrue(try need(model.statusMessage).contains("Expanded stacks collapse"))
    }

    func testExaminedScopeIsPureAndOrderIndependent() {
        func cand(_ id: Int64, print: Bool = true) -> StackCandidate { StackCandidate(id: id, captureDate: Double(id), featurePrint: print ? [1] : nil) }
        let input = [cand(3), cand(1), cand(2), cand(4, print: false)]
        let automatic: [Set<Int64>] = [[1, 9], [3, 4]]
        let result = AutoStackModel.examinedScope(candidates: input, automatic: automatic, shownIDs: [1, 2, 3, 4], cap: 10)
        XCTAssertEqual(result.candidates.map(\.id), [2], "1 has an unexamined partner (9); 3's partner 4 has no print and is in a stack")
        XCTAssertEqual(result.keptStacks, 2)
        XCTAssertEqual(AutoStackModel.examinedScope(candidates: input.reversed(), automatic: automatic, shownIDs: [1, 2, 3, 4], cap: 10).candidates.map(\.id), [2])
        let capped = AutoStackModel.examinedScope(candidates: input, automatic: [], shownIDs: [1, 2, 3, 4], cap: 2)
        XCTAssertEqual(capped.candidates.map(\.id), [3, 4])
        XCTAssertEqual(capped.capped, 2)
    }
}

/// A tiny lock-protected box for values written from background closures.
private final class AutoStackBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

private func need<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
