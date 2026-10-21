import XCTest
@testable import PhotoApp

/// `ImportCopyEngine` copies REAL files, so these run against real temp folders.
final class ImportCopyEngineTests: XCTestCase {
    private var root: URL!
    private var card: URL!
    private var dest: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ImportCopyEngineTests-\(UUID().uuidString)", isDirectory: true)
        card = root.appendingPathComponent("card", isDirectory: true)
        dest = root.appendingPathComponent("dest", isDirectory: true)
        try fm.createDirectory(at: card, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    @discardableResult
    private func write(_ name: String, _ text: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? card).appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } }

    private func source(_ url: URL) -> ImportCopySource {
        ImportCopySource(url: url, fileSize: Int64((try? Data(contentsOf: url).count) ?? 0), captureDate: Date(timeIntervalSince1970: 1_760_000_000))
    }

    private func plan(_ urls: [URL], options: ImportCopyOptions = ImportCopyOptions()) -> ImportCopyPlan {
        ImportCopyPlan.make(sources: urls.map(source), destination: dest, options: options)
    }

    private func leftoverTemps() -> [String] {
        let all = (fm.enumerator(atPath: dest.path)?.allObjects as? [String]) ?? []
        return all.filter { $0.hasSuffix(".importcopy.tmp") }
    }

    // MARK: happy path

    func testCopiesPhotosAndLeavesTheSourceUntouched() async throws {
        let a = try write("a.jpg", "AAA")
        let b = try write("b.jpg", "BBBB")
        let before = [read(a), read(b)]
        let outcome = await ImportCopyEngine.apply(plan: plan([a, b]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["a.jpg", "b.jpg"])
        XCTAssertEqual(read(dest.appendingPathComponent("a.jpg")), "AAA")
        XCTAssertEqual(read(dest.appendingPathComponent("b.jpg")), "BBBB")
        XCTAssertEqual([read(a), read(b)], before)
        XCTAssertTrue(fm.fileExists(atPath: a.path) && fm.fileExists(atPath: b.path))
        XCTAssertTrue(leftoverTemps().isEmpty)
    }

    func testDateSubfoldersAreCreated() async throws {
        let a = try write("a.jpg", "AAA")
        var options = ImportCopyOptions()
        options.subfolders = .isoDate
        let outcome = await ImportCopyEngine.apply(plan: plan([a], options: options), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.copied.count, 1)
        XCTAssertEqual(outcome.copied.first?.deletingLastPathComponent().lastPathComponent, "2025-10-09")
    }

    func testProgressCountsEveryPlannedCopy() async throws {
        let urls = [try write("a.jpg", "1"), try write("b.jpg", "2")]
        let seen = LockedBox<[Int]>([])
        _ = await ImportCopyEngine.apply(plan: plan(urls), skipAlreadyCopied: true, progress: { done, total in
            seen.mutate { $0.append(done * 10 + total) }
        })
        XCTAssertEqual(seen.value, [12, 22])
    }

    // MARK: collisions and re-runs

    func testAnIdenticalExistingFileIsSkippedNotDuplicated() async throws {
        let a = try write("a.jpg", "SAME")
        try write("a.jpg", "SAME", in: dest)
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.skippedIdentical, [a])
        XCTAssertTrue(outcome.copied.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("a (2).jpg").path))
    }

    func testADifferentFileAtTheSameNameIsNeverOverwritten() async throws {
        let a = try write("a.jpg", "NEW CONTENT")
        try write("a.jpg", "OLD", in: dest)
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["a (2).jpg"])
        XCTAssertEqual(read(dest.appendingPathComponent("a.jpg")), "OLD")
        XCTAssertEqual(read(dest.appendingPathComponent("a (2).jpg")), "NEW CONTENT")
    }

    func testWithSkipOffAnIdenticalFileIsCopiedUnderANewName() async throws {
        let a = try write("a.jpg", "SAME")
        try write("a.jpg", "SAME", in: dest)
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: false)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["a (2).jpg"])
    }

    func testAnOrphanEditFileAtTheDestinationIsNotAdopted() async throws {
        let a = try write("a.jpg", "AAA")
        try write("a.jpg.photoapp.json", "{\"exposure\": 9}", in: dest)
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["a (2).jpg"])
        XCTAssertEqual(read(dest.appendingPathComponent("a.jpg.photoapp.json")), "{\"exposure\": 9}")
    }

    // MARK: verification and failure

    func testACorruptCopyIsDiscardedAndNothingAppearsAtTheFinalName() async throws {
        let a = try write("a.jpg", "AAA")
        let b = try write("b.jpg", "BBB")
        var environment = ImportCopyEngine.Environment.live
        environment.copy = { source, temp in
            try FileManager.default.copyItem(at: source, to: temp)
            if source.lastPathComponent == "a.jpg" { try Data("XXX".utf8).write(to: temp) } // same size, different bytes
        }
        let outcome = await ImportCopyEngine.apply(plan: plan([a, b]), skipAlreadyCopied: true, environment: environment)
        XCTAssertEqual(outcome.failed.map(\.source.lastPathComponent), ["a.jpg"])
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["b.jpg"])
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("a.jpg").path))
        XCTAssertTrue(leftoverTemps().isEmpty)
    }

    func testACopyErrorIsReportedAndTheRunContinues() async throws {
        let a = try write("a.jpg", "AAA")
        let b = try write("b.jpg", "BBB")
        var environment = ImportCopyEngine.Environment.live
        environment.copy = { source, temp in
            if source.lastPathComponent == "a.jpg" { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.copyItem(at: source, to: temp)
        }
        let outcome = await ImportCopyEngine.apply(plan: plan([a, b]), skipAlreadyCopied: true, environment: environment)
        XCTAssertEqual(outcome.failed.count, 1)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["b.jpg"])
        XCTAssertTrue(leftoverTemps().isEmpty)
    }

    func testAnUnreadableSourceFails() async throws {
        let a = try write("a.jpg", "AAA")
        var environment = ImportCopyEngine.Environment.live
        environment.hash = { _ in nil }
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true, environment: environment)
        XCTAssertEqual(outcome.failed.count, 1)
        XCTAssertTrue(outcome.copied.isEmpty)
    }

    func testGateStopLeavesTheRestUntouched() async throws {
        let a = try write("a.jpg", "AAA")
        let b = try write("b.jpg", "BBB")
        let calls = LockedBox(0)
        let outcome = await ImportCopyEngine.apply(plan: plan([a, b]), skipAlreadyCopied: true, gate: {
            calls.mutate { $0 += 1 }
            return calls.value < 2
        })
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["a.jpg"])
        XCTAssertTrue(outcome.stoppedEarly)
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("b.jpg").path))
    }

    func testBlockedPlanItemsAreReportedNotCopied() async throws {
        let folderNamedLikeAPhoto = card.appendingPathComponent("Edits.jpg", isDirectory: true)
        try fm.createDirectory(at: folderNamedLikeAPhoto, withIntermediateDirectories: true)
        let outcome = await ImportCopyEngine.apply(plan: plan([folderNamedLikeAPhoto]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.blocked.count, 1)
        XCTAssertTrue(outcome.copied.isEmpty)
    }

    // MARK: companions

    func testCompanionsFollowTheCopyAndKeepItsName() async throws {
        let a = try write("a.jpg", "AAA")
        try write("a.jpg.photoapp.json", "{\"e\":1}")
        try write("a.xmp", "<x/>")
        try write("a.jpg", "OLD", in: dest) // forces the copy to " (2)"
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["a (2).jpg"])
        XCTAssertEqual(read(dest.appendingPathComponent("a (2).jpg.photoapp.json")), "{\"e\":1}")
        XCTAssertEqual(read(dest.appendingPathComponent("a (2).xmp")), "<x/>")
        XCTAssertTrue(outcome.companionFailures.isEmpty)
    }

    func testACompanionThatAppearsAtTheLastMomentIsNeverOverwritten() async throws {
        let a = try write("a.jpg", "AAA")
        try write("a.jpg.photoapp.json", "{\"e\":1}")
        var environment = ImportCopyEngine.Environment.live
        let target = dest.appendingPathComponent("a.jpg.photoapp.json")
        // Someone else's edit file appears between the name check and the companion's commit.
        environment.copy = { source, temp in
            try FileManager.default.copyItem(at: source, to: temp)
            if source.lastPathComponent == "a.jpg.photoapp.json" { try Data("{\"theirs\":true}".utf8).write(to: target) }
        }
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true, environment: environment)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["a.jpg"])
        XCTAssertEqual(outcome.companionFailures.count, 1)
        XCTAssertEqual(read(target), "{\"theirs\":true}")
        XCTAssertTrue(leftoverTemps().isEmpty)
    }

    func testAStaleDarktableXMPAtTheDestinationIsNotAdopted() async throws {
        let a = try write("a.jpg", "AAA")
        try write("a.jpg.xmp", "<theirs/>", in: dest)
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["a (2).jpg"])
        XCTAssertEqual(read(dest.appendingPathComponent("a.jpg.xmp")), "<theirs/>")
    }

    func testARawNextToAnExistingJpegDoesNotTakeOverItsSharedXMP() async throws {
        let raw = try write("IMG.NEF", "RAWBYTES")
        try write("IMG.jpg", "JPG", in: dest)
        try write("IMG.xmp", "<jpegs/>", in: dest) // the JPEG owns this one
        let outcome = await ImportCopyEngine.apply(plan: plan([raw]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["IMG (2).NEF"])
        XCTAssertEqual(read(dest.appendingPathComponent("IMG.xmp")), "<jpegs/>")
    }

    func testARawJpegPairFromOneFolderKeepsItsNamesAndItsOneSharedXMP() async throws {
        let raw = try write("IMG.NEF", "RAWBYTES")
        let jpg = try write("IMG.jpg", "JPG")
        try write("IMG.xmp", "<pair/>")
        let outcome = await ImportCopyEngine.apply(plan: plan([raw, jpg]), skipAlreadyCopied: true)
        XCTAssertEqual(Set(outcome.copied.map(\.lastPathComponent)), ["IMG.NEF", "IMG.jpg"])
        XCTAssertEqual(read(dest.appendingPathComponent("IMG.xmp")), "<pair/>")
        XCTAssertTrue(outcome.companionFailures.isEmpty)
    }

    func testTwoUnrelatedPhotosWithOneBaseNameAreNotTreatedAsAPair() async throws {
        let folderA = card.appendingPathComponent("100NIKON", isDirectory: true)
        let folderB = card.appendingPathComponent("101NIKON", isDirectory: true)
        try fm.createDirectory(at: folderA, withIntermediateDirectories: true)
        try fm.createDirectory(at: folderB, withIntermediateDirectories: true)
        let jpg = try write("DSC_0001.JPG", "JPG", in: folderA)
        try write("DSC_0001.xmp", "<jpgs/>", in: folderA)
        let raw = try write("DSC_0001.NEF", "RAWBYTES", in: folderB)
        try write("DSC_0001.xmp", "<raws/>", in: folderB)
        let outcome = await ImportCopyEngine.apply(plan: plan([jpg, raw]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["DSC_0001.JPG", "DSC_0001 (2).NEF"])
        XCTAssertEqual(read(dest.appendingPathComponent("DSC_0001.xmp")), "<jpgs/>")
        XCTAssertEqual(read(dest.appendingPathComponent("DSC_0001 (2).xmp")), "<raws/>")
    }

    func testARenamedRawDoesNotBecomeAFakePairWithAnUnrelatedJpegAtRunTime() async throws {
        // Counter rollover on the card, and last month's unrelated DSC_0001.NEF already in the destination.
        try write("DSC_0001.NEF", "OLD RAW", in: dest)
        let folderA = card.appendingPathComponent("100NIKON", isDirectory: true)
        let folderB = card.appendingPathComponent("101NIKON", isDirectory: true)
        try fm.createDirectory(at: folderA, withIntermediateDirectories: true)
        try fm.createDirectory(at: folderB, withIntermediateDirectories: true)
        let raw = try write("DSC_0001.NEF", "NEW RAW", in: folderA)
        try write("DSC_0001.xmp", "<raws/>", in: folderA)
        let jpg = try write("DSC_0001.JPG", "JPG", in: folderB)
        let outcome = await ImportCopyEngine.apply(plan: plan([raw, jpg]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.copied.count, 2)
        XCTAssertEqual(outcome.copied.first?.lastPathComponent, "DSC_0001 (2).NEF")
        // The JPG must NOT share the renamed RAW's base name (that would make the two a pair sharing one xmp).
        let jpgBase = outcome.copied.last?.deletingPathExtension().lastPathComponent
        XCTAssertNotEqual(jpgBase, "DSC_0001 (2)")
        XCTAssertNotEqual(jpgBase, "DSC_0001")
        XCTAssertEqual(read(dest.appendingPathComponent("DSC_0001 (2).xmp")), "<raws/>")
    }

    func testANewJpegNextToAnOldUnrelatedRawWithoutAnXMPGetsItsOwnBaseName() async throws {
        try write("DSC_0001.NEF", "OLD RAW", in: dest)
        let jpg = try write("DSC_0001.JPG", "JPG")
        let outcome = await ImportCopyEngine.apply(plan: plan([jpg]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["DSC_0001 (2).JPG"])
    }

    func testARealPairWhoseFirstMemberWasRenamedStaysTogether() async throws {
        try write("DSC_0001.NEF", "OLD RAW", in: dest)
        let raw = try write("DSC_0001.NEF", "NEW RAW")
        let jpg = try write("DSC_0001.JPG", "JPG")
        try write("DSC_0001.xmp", "<pair/>")
        let outcome = await ImportCopyEngine.apply(plan: plan([raw, jpg]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["DSC_0001 (2).NEF", "DSC_0001 (2).JPG"])
        XCTAssertEqual(read(dest.appendingPathComponent("DSC_0001 (2).xmp")), "<pair/>")
        XCTAssertTrue(outcome.companionFailures.isEmpty)
    }

    // MARK: repeat imports

    func testARepeatImportDoesNotAddAnotherCopyOfAPhotoThatWasRenamedToAvoidAClash() async throws {
        let a = try write("a.jpg", "NEW CONTENT")
        try write("a.jpg", "OLD", in: dest)
        let first = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true)
        XCTAssertEqual(first.copied.map(\.lastPathComponent), ["a (2).jpg"])
        let second = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true)
        XCTAssertTrue(second.copied.isEmpty)
        XCTAssertEqual(second.skippedIdentical, [a])
        XCTAssertEqual(second.skippedDestinations.map(\.lastPathComponent), ["a (2).jpg"])
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("a (3).jpg").path))
    }

    func testARepeatImportAcrossANameGapBlockedBySomeonesSidecarStillSkips() async throws {
        // The destination's DSC_0001.xmp belongs to an old RAW, so the card's JPG cannot take the plain name.
        try write("DSC_0001.NEF", "OLD RAW", in: dest)
        try write("DSC_0001.xmp", "<old/>", in: dest)
        let jpg = try write("DSC_0001.JPG", "JPG")
        let first = await ImportCopyEngine.apply(plan: plan([jpg]), skipAlreadyCopied: true)
        XCTAssertEqual(first.copied.map(\.lastPathComponent), ["DSC_0001 (2).JPG"])
        let second = await ImportCopyEngine.apply(plan: plan([jpg]), skipAlreadyCopied: true)
        XCTAssertTrue(second.copied.isEmpty)
        XCTAssertEqual(second.skippedDestinations.map(\.lastPathComponent), ["DSC_0001 (2).JPG"])
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("DSC_0001 (3).JPG").path))
    }

    func testARunInterruptedBetweenAPairsMembersResumesWithoutSplittingThePair() async throws {
        let raw = try write("DSC.NEF", "RAWBYTES")
        let jpg = try write("DSC.JPG", "JPG")
        try write("DSC.xmp", "<pair/>")
        // The first run copied only the RAW (and its xmp) before it was stopped.
        try write("DSC.NEF", "RAWBYTES", in: dest)
        try write("DSC.xmp", "<pair/>", in: dest)
        let outcome = await ImportCopyEngine.apply(plan: plan([raw, jpg]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.skippedIdentical, [raw])
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["DSC.JPG"], "the JPG stays with its RAW, not 'DSC (2).JPG'")
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("DSC (2).xmp").path))
        XCTAssertTrue(outcome.companionFailures.isEmpty)
    }

    func testASkippedPhotoGetsTheCompanionAnInterruptedRunNeverWrote() async throws {
        let a = try write("a.jpg", "SAME")
        try write("a.jpg.photoapp.json", "{\"e\":1}")
        try write("a.jpg", "SAME", in: dest) // copied before the run died, edit file not yet
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.skippedIdentical, [a])
        XCTAssertEqual(read(dest.appendingPathComponent("a.jpg.photoapp.json")), "{\"e\":1}")
    }

    func testASkippedPhotosExistingCompanionIsLeftAlone() async throws {
        let a = try write("a.jpg", "SAME")
        try write("a.jpg.photoapp.json", "{\"new\":1}")
        try write("a.jpg", "SAME", in: dest)
        try write("a.jpg.photoapp.json", "{\"mine\":1}", in: dest)
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true)
        XCTAssertEqual(read(dest.appendingPathComponent("a.jpg.photoapp.json")), "{\"mine\":1}")
        XCTAssertTrue(outcome.companionFailures.isEmpty)
    }

    func testSkippedFilesReportWhereTheyAreSoTheLibraryCanRegisterThem() async throws {
        let a = try write("a.jpg", "SAME")
        try write("a.jpg", "SAME", in: dest)
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true)
        XCTAssertEqual(outcome.skippedDestinations, [dest.appendingPathComponent("a.jpg")])
    }

    // MARK: move (originals to the Trash)

    /// A mover that puts the file into a scratch "Trash" folder (so a test can see what is left on the card) and records every call.
    private final class FakeTrash: @unchecked Sendable {
        private let lock = NSLock()
        let folder: URL
        private var urls: [URL] = []
        var failing: Set<String> = []
        init(folder: URL) { self.folder = folder; try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var calls: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
        func mover() -> TrashEngine.Mover {
            { [self] url in
                lock.lock(); urls.append(url); lock.unlock()
                if failing.contains(url.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
                let target = folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: target)
                return target
            }
        }
    }

    private func applyMove(
        _ plan: ImportCopyPlan, trash: FakeTrash, environment: ImportCopyEngine.Environment = .live, skip: Bool = true,
        isProtected: @escaping @MainActor @Sendable (URL) -> Bool = { _ in false },
        gate: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async -> ImportCopyEngine.Outcome {
        await ImportCopyEngine.apply(
            plan: plan, skipAlreadyCopied: skip, mode: .move, environment: environment, mover: trash.mover(), isProtected: isProtected, gate: gate
        )
    }

    private func onCard(_ name: String) -> Bool { fm.fileExists(atPath: card.appendingPathComponent(name).path) }

    func testMoveTrashesTheOriginalOnlyAfterTheCopyIsVerified() async throws {
        let a = try write("a.jpg", "AAA")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let outcome = await applyMove(plan([a]), trash: trash)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["a.jpg"])
        XCTAssertEqual(outcome.movedToTrash, [a])
        XCTAssertFalse(onCard("a.jpg"))
        XCTAssertEqual(read(dest.appendingPathComponent("a.jpg")), "AAA")
        XCTAssertTrue(outcome.notMoved.isEmpty)
    }

    func testCopyModeNeverCallsTheMover() async throws {
        let a = try write("a.jpg", "AAA")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true, mode: .copy, mover: trash.mover())
        XCTAssertTrue(trash.calls.isEmpty)
        XCTAssertTrue(onCard("a.jpg"))
        XCTAssertTrue(outcome.movedToTrash.isEmpty)
    }

    func testACorruptCopyKeepsTheOriginalAndNeverCallsTheMover() async throws {
        let a = try write("a.jpg", "AAA")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        var environment = ImportCopyEngine.Environment.live
        environment.copy = { source, temp in
            try FileManager.default.copyItem(at: source, to: temp)
            try Data("XXX".utf8).write(to: temp)
        }
        let outcome = await applyMove(plan([a]), trash: trash, environment: environment)
        XCTAssertEqual(outcome.failed.count, 1)
        XCTAssertTrue(trash.calls.isEmpty)
        XCTAssertTrue(onCard("a.jpg"))
    }

    func testACopyThatCannotBeReadBackFromTheDiskKeepsTheOriginal() async throws {
        let a = try write("a.jpg", "AAA")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        var environment = ImportCopyEngine.Environment.live
        environment.hashUncached = { _ in "not-the-digest" }
        let outcome = await applyMove(plan([a]), trash: trash, environment: environment)
        XCTAssertEqual(outcome.copied.count, 1, "the copy exists")
        XCTAssertEqual(outcome.notMoved.map(\.source), [a])
        XCTAssertTrue(trash.calls.isEmpty)
        XCTAssertTrue(onCard("a.jpg"))
    }

    func testAnOriginalThatChangedWhileItWasBeingCopiedIsLeftOnTheCard() async throws {
        let a = try write("a.jpg", "AAA")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        var environment = ImportCopyEngine.Environment.live
        environment.copy = { source, temp in
            try FileManager.default.copyItem(at: source, to: temp)
            try Data("AAA plus more from the camera".utf8).write(to: source) // the original changes after it was copied
        }
        let outcome = await applyMove(plan([a]), trash: trash, environment: environment)
        XCTAssertEqual(outcome.notMoved.count, 1)
        XCTAssertTrue(trash.calls.isEmpty)
        XCTAssertEqual(read(a), "AAA plus more from the camera")
    }

    func testATrashErrorKeepsTheCopyAndReportsTheOriginalAsNotMoved() async throws {
        let a = try write("a.jpg", "AAA")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        trash.failing = ["a.jpg"]
        let outcome = await applyMove(plan([a]), trash: trash)
        XCTAssertEqual(outcome.copied.count, 1)
        XCTAssertEqual(outcome.notMoved.map(\.source), [a])
        XCTAssertTrue(onCard("a.jpg"))
        XCTAssertEqual(read(dest.appendingPathComponent("a.jpg")), "AAA")
    }

    func testAnIdenticalCopyAlreadyInTheDestinationLetsTheMoveTrashTheOriginal() async throws {
        let a = try write("a.jpg", "SAME")
        _ = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true) // an earlier plain Copy
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let outcome = await applyMove(plan([a]), trash: trash)
        XCTAssertEqual(outcome.skippedIdentical, [a])
        XCTAssertEqual(outcome.movedToTrash, [a])
        XCTAssertFalse(onCard("a.jpg"))
    }

    func testCompanionsFollowTheirPhotoToTheTrashWhenAllOfThemLanded() async throws {
        let a = try write("a.jpg", "AAA")
        try write("a.jpg.photoapp.json", "{\"e\":1}")
        try write("a.jpg.xmp", "<x/>")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let outcome = await applyMove(plan([a]), trash: trash)
        XCTAssertFalse(onCard("a.jpg") || onCard("a.jpg.photoapp.json") || onCard("a.jpg.xmp"))
        XCTAssertEqual(outcome.companionsTrashed, 2)
    }

    func testAPhotoWhoseCompanionDidNotLandStaysOnTheCardWithItsEdits() async throws {
        let a = try write("a.jpg", "AAA")
        try write("a.jpg.photoapp.json", "{\"e\":1}")
        try write("a.jpg.xmp", "<x/>")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        var environment = ImportCopyEngine.Environment.live
        environment.copy = { source, temp in
            if source.lastPathComponent == "a.jpg.xmp" { throw CocoaError(.fileWriteOutOfSpace) } // this companion fails to copy
            try FileManager.default.copyItem(at: source, to: temp)
        }
        let outcome = await applyMove(plan([a]), trash: trash, environment: environment)
        XCTAssertEqual(outcome.copied.count, 1, "the photo itself was copied")
        XCTAssertEqual(outcome.notMoved.map(\.source), [a])
        XCTAssertTrue(onCard("a.jpg") && onCard("a.jpg.photoapp.json") && onCard("a.jpg.xmp"), "nothing leaves the card")
        XCTAssertTrue(trash.calls.isEmpty)
    }

    func testACorruptEditFileCopyKeepsThePhotoAndItsEditsOnTheCard() async throws {
        let a = try write("a.jpg", "AAA")
        try write("a.jpg.photoapp.json", "{\"edits\":\"all of them\"}")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        var environment = ImportCopyEngine.Environment.live
        environment.copy = { source, temp in
            try FileManager.default.copyItem(at: source, to: temp)
            if source.lastPathComponent.hasSuffix(".photoapp.json") { try Data("{\"edits\":\"trunc".utf8).write(to: temp) } // a damaged companion copy
        }
        let outcome = await applyMove(plan([a]), trash: trash, environment: environment)
        XCTAssertEqual(outcome.notMoved.map(\.source), [a])
        XCTAssertTrue(onCard("a.jpg") && onCard("a.jpg.photoapp.json"), "the edits are not trashed on the strength of an unverified copy")
        XCTAssertTrue(trash.calls.isEmpty)
    }

    func testAnEditFileCopyThatCannotBeFlushedKeepsThePhotoOnTheCard() async throws {
        let a = try write("a.jpg", "AAA")
        try write("a.jpg.photoapp.json", "{\"e\":1}")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        var environment = ImportCopyEngine.Environment.live
        environment.flush = { url in !url.lastPathComponent.hasSuffix(".photoapp.json") } // the photo flushes, its edit file does not
        let outcome = await applyMove(plan([a]), trash: trash, environment: environment)
        XCTAssertEqual(outcome.notMoved.map(\.source), [a])
        XCTAssertTrue(onCard("a.jpg") && onCard("a.jpg.photoapp.json"))
    }

    func testTwoUnreadableEditFilesAreNotTreatedAsIdentical() async throws {
        let a = try write("a.jpg", "SAME")
        try write("a.jpg.photoapp.json", "{\"e\":1}")
        try write("a.jpg", "SAME", in: dest)
        try write("a.jpg.photoapp.json", "{\"e\":1}", in: dest)
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        var environment = ImportCopyEngine.Environment.live
        environment.hash = { url in url.lastPathComponent.hasSuffix(".photoapp.json") ? nil : FileHasher.sha256Hex(ofFileAt: url) } // nil == nil
        let outcome = await applyMove(plan([a]), trash: trash, environment: environment)
        XCTAssertEqual(outcome.notMoved.map(\.source), [a])
        XCTAssertTrue(onCard("a.jpg") && onCard("a.jpg.photoapp.json"))
    }

    func testAPhotoOpenedWhileItsOwnCopyWasRunningIsStillNotTrashed() async throws {
        let a = try write("a.jpg", "AAA")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let asked = LockedBox(0)
        // Not open when the run starts, open by the time the original would leave.
        let outcome = await applyMove(plan([a]), trash: trash, isProtected: { _ in
            asked.mutate { $0 += 1 }
            return asked.value >= 1
        })
        XCTAssertEqual(outcome.notMoved.map(\.source), [a])
        XCTAssertTrue(onCard("a.jpg"))
    }

    func testACompanionTheTrashDidNotTakeIsNotCountedAsTrashed() async throws {
        let a = try write("a.jpg", "AAA")
        try write("a.jpg.photoapp.json", "{\"e\":1}")
        let aside = root.appendingPathComponent("trashed-a.jpg")
        let movedPhotoOnly: TrashEngine.Mover = { url in
            if url.lastPathComponent == "a.jpg" {
                try FileManager.default.moveItem(at: url, to: aside)
            }
            return nil // reports success for the edit file without moving it
        }
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true, mode: .move, mover: movedPhotoOnly)
        XCTAssertEqual(outcome.movedToTrash, [a])
        XCTAssertEqual(outcome.companionsTrashed, 0)
        XCTAssertEqual(outcome.companionsNotTrashed, 1)
        XCTAssertTrue(onCard("a.jpg.photoapp.json"))
    }

    func testADifferentEditFileAlreadyAtTheDestinationKeepsTheOriginalOnTheCard() async throws {
        let a = try write("a.jpg", "SAME")
        try write("a.jpg.photoapp.json", "{\"newer\":true}")
        try write("a.jpg", "SAME", in: dest)
        try write("a.jpg.photoapp.json", "{\"older\":true}", in: dest)
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let outcome = await applyMove(plan([a]), trash: trash)
        XCTAssertEqual(outcome.notMoved.map(\.source), [a])
        XCTAssertTrue(onCard("a.jpg") && onCard("a.jpg.photoapp.json"))
        XCTAssertEqual(read(dest.appendingPathComponent("a.jpg.photoapp.json")), "{\"older\":true}", "the destination's is never overwritten")
    }

    func testAnIdenticalEditFileAlreadyAtTheDestinationLetsTheWholeSetMove() async throws {
        let a = try write("a.jpg", "SAME")
        try write("a.jpg.photoapp.json", "{\"e\":1}")
        try write("a.jpg", "SAME", in: dest)
        try write("a.jpg.photoapp.json", "{\"e\":1}", in: dest)
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let outcome = await applyMove(plan([a]), trash: trash)
        XCTAssertEqual(outcome.movedToTrash, [a])
        XCTAssertFalse(onCard("a.jpg") || onCard("a.jpg.photoapp.json"))
    }

    func testADestinationThatIsTheSourceFolderNeverTreatsTheOriginalAsItsOwnCopy() async throws {
        let a = try write("a.jpg", "AAA")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let selfPlan = ImportCopyPlan.make(sources: [source(a)], destination: card, options: ImportCopyOptions())
        let outcome = await applyMove(selfPlan, trash: trash)
        XCTAssertTrue(outcome.skippedIdentical.isEmpty, "the original is not 'an identical copy' of itself")
        // The data must survive: a separate verified copy exists next to the original before the original may go.
        XCTAssertEqual(read(card.appendingPathComponent("a (2).jpg")), "AAA")
        XCTAssertTrue(outcome.skippedDestinations.isEmpty)
    }

    func testASymlinkAtTheDestinationNameIsNotACopy() async throws {
        let a = try write("a.jpg", "AAA")
        try fm.createSymbolicLink(at: dest.appendingPathComponent("a.jpg"), withDestinationURL: a)
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let outcome = await applyMove(plan([a]), trash: trash)
        XCTAssertTrue(outcome.skippedIdentical.isEmpty)
        XCTAssertTrue(outcome.skippedDestinations.isEmpty, "a dangling link must never be registered in the Library")
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["a (2).jpg"])
        XCTAssertEqual(read(dest.appendingPathComponent("a (2).jpg")), "AAA", "the real copy exists before the original went")
    }

    func testASymlinkToAnIdenticalFileElsewhereIsNotACopyEither() async throws {
        let a = try write("a.jpg", "AAA")
        let elsewhere = try write("elsewhere.jpg", "AAA", in: root) // identical bytes, but not in the destination
        try fm.createSymbolicLink(at: dest.appendingPathComponent("a.jpg"), withDestinationURL: elsewhere)
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let outcome = await applyMove(plan([a]), trash: trash)
        XCTAssertTrue(outcome.skippedIdentical.isEmpty, "a link is not a copy: deleting its target would leave the original gone")
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["a (2).jpg"])
    }

    func testAnIdenticalCopyUnderASuffixedNameLetsTheMoveTrashTheOriginal() async throws {
        let a = try write("a.jpg", "NEW")
        try write("a.jpg", "OLD", in: dest)
        try write("a (2).jpg", "NEW", in: dest)
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let outcome = await applyMove(plan([a]), trash: trash)
        XCTAssertEqual(outcome.skippedDestinations.map(\.lastPathComponent), ["a (2).jpg"])
        XCTAssertEqual(outcome.movedToTrash, [a])
    }

    func testMoveWithSkipTurnedOffCopiesUnderANewNameThenTrashesTheOriginal() async throws {
        let a = try write("a.jpg", "SAME")
        try write("a.jpg", "SAME", in: dest)
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let outcome = await applyMove(plan([a]), trash: trash, skip: false)
        XCTAssertEqual(outcome.copied.map(\.lastPathComponent), ["a (2).jpg"])
        XCTAssertEqual(outcome.movedToTrash, [a])
    }

    func testACopyThatCannotBeFlushedToTheDiskKeepsTheOriginal() async throws {
        let a = try write("a.jpg", "AAA")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        var environment = ImportCopyEngine.Environment.live
        environment.flush = { _ in false }
        let outcome = await applyMove(plan([a]), trash: trash, environment: environment)
        XCTAssertEqual(outcome.notMoved.map(\.source), [a])
        XCTAssertTrue(trash.calls.isEmpty)
        XCTAssertTrue(onCard("a.jpg"))
    }

    func testAMoverThatReportsSuccessWithoutMovingNothingIsCountedAsMoved() async throws {
        let a = try write("a.jpg", "AAA")
        try write("a.xmp", "<x/>")
        let outcome = await ImportCopyEngine.apply(plan: plan([a]), skipAlreadyCopied: true, mode: .move, mover: { _ in nil })
        XCTAssertTrue(outcome.movedToTrash.isEmpty)
        XCTAssertEqual(outcome.notMoved.map(\.source), [a])
        XCTAssertTrue(onCard("a.jpg") && onCard("a.xmp"), "the shared xmp does not go while its photo is still there")
    }

    func testThePhotoOpenInTheEditorIsCopiedButItsOriginalStays() async throws {
        let a = try write("a.jpg", "AAA")
        let b = try write("b.jpg", "BBB")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let openPath = a.path
        let outcome = await applyMove(plan([a, b]), trash: trash, isProtected: { $0.path == openPath })
        XCTAssertEqual(outcome.copied.count, 2)
        XCTAssertEqual(outcome.movedToTrash, [b])
        XCTAssertEqual(outcome.notMoved.map(\.source), [a])
        XCTAssertTrue(onCard("a.jpg"))
        XCTAssertFalse(onCard("b.jpg"))
    }

    func testAStoppedRunCountsTheDeferredSharedXMPAsStayingBehind() async throws {
        let a = try write("a.jpg", "AAA")
        let b = try write("b.jpg", "BBB")
        try write("a.xmp", "<a/>")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let calls = LockedBox(0)
        let outcome = await applyMove(plan([a, b]), trash: trash, gate: {
            calls.mutate { $0 += 1 }
            return calls.value < 2
        })
        XCTAssertEqual(outcome.companionsNotTrashed, 1)
    }

    func testHashingUncachedGivesTheSameDigestAndAFlushSucceedsOnARealFile() throws {
        let a = try write("a.jpg", "some bytes to hash")
        XCTAssertEqual(FileHasher.sha256Hex(ofFileAt: a, uncached: true), FileHasher.sha256Hex(ofFileAt: a))
        XCTAssertTrue(FileHasher.flushToDisk(a))
        XCTAssertFalse(FileHasher.flushToDisk(card.appendingPathComponent("missing.jpg")))
    }

    func testAPhotoThatCannotMoveKeepsItsCompanions() async throws {
        let a = try write("a.jpg", "AAA")
        try write("a.jpg.photoapp.json", "{\"e\":1}")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        trash.failing = ["a.jpg"]
        _ = await applyMove(plan([a]), trash: trash)
        XCTAssertTrue(onCard("a.jpg.photoapp.json"))
    }

    func testTheSharedXMPGoesOnlyWhenTheWholePairMoved() async throws {
        let raw = try write("IMG.NEF", "RAWBYTES")
        let jpg = try write("IMG.jpg", "JPG")
        try write("IMG.xmp", "<pair/>")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let outcome = await applyMove(plan([raw, jpg]), trash: trash)
        XCTAssertEqual(Set(outcome.movedToTrash.map(\.lastPathComponent)), ["IMG.NEF", "IMG.jpg"])
        XCTAssertFalse(onCard("IMG.xmp"))
        XCTAssertEqual(read(dest.appendingPathComponent("IMG.xmp")), "<pair/>")
    }

    func testTheSharedXMPStaysWhenOneMemberOfThePairCouldNotBeMoved() async throws {
        let raw = try write("IMG.NEF", "RAWBYTES")
        let jpg = try write("IMG.jpg", "JPG")
        try write("IMG.xmp", "<pair/>")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        trash.failing = ["IMG.jpg"]
        let outcome = await applyMove(plan([raw, jpg]), trash: trash)
        XCTAssertFalse(onCard("IMG.NEF"))
        XCTAssertTrue(onCard("IMG.jpg"))
        XCTAssertTrue(onCard("IMG.xmp"), "the JPEG still on the card still needs it")
        XCTAssertGreaterThan(outcome.companionsNotTrashed, 0)
    }

    func testTheGroupRuleAloneKeepsTheSharedXMPEvenIfTheFolderListingMissesTheStayingMember() async throws {
        // Isolates "every photo of the pair must have moved" from the staying-sibling check: the listing is made to report nothing.
        let raw = try write("IMG.NEF", "RAWBYTES")
        let jpg = try write("IMG.jpg", "JPG")
        try write("IMG.xmp", "<pair/>")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        trash.failing = ["IMG.jpg"]
        var environment = ImportCopyEngine.Environment.live
        environment.folderListing = { _ in [] }
        _ = await applyMove(plan([raw, jpg]), trash: trash, environment: environment)
        XCTAssertTrue(onCard("IMG.xmp"))
    }

    func testTheSharedXMPStaysWhileANonPhotoFileWithTheSameBaseNameStaysOnTheCard() async throws {
        let a = try write("IMG.jpg", "JPG")
        try write("IMG.xmp", "<x/>")
        try write("IMG.MOV", "VIDEO") // not a photo: never copied, never moved
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        _ = await applyMove(plan([a]), trash: trash)
        XCTAssertFalse(onCard("IMG.jpg"))
        XCTAssertTrue(onCard("IMG.xmp"))
        XCTAssertTrue(onCard("IMG.MOV"))
    }

    func testAFolderThatCannotBeListedKeepsTheSharedXMP() async throws {
        let a = try write("IMG.jpg", "JPG")
        try write("IMG.xmp", "<x/>")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        var environment = ImportCopyEngine.Environment.live
        environment.folderListing = { _ in nil }
        _ = await applyMove(plan([a]), trash: trash, environment: environment)
        XCTAssertTrue(onCard("IMG.xmp"))
    }

    func testAGateStopLeavesTheRemainingOriginalsAndTheSharedXMPUntouched() async throws {
        let a = try write("a.jpg", "AAA")
        let b = try write("b.jpg", "BBB")
        try write("a.xmp", "<a/>")
        let trash = FakeTrash(folder: root.appendingPathComponent("trash"))
        let calls = LockedBox(0)
        let outcome = await applyMove(plan([a, b]), trash: trash, gate: {
            calls.mutate { $0 += 1 }
            return calls.value < 2
        })
        XCTAssertTrue(outcome.stoppedEarly)
        XCTAssertFalse(onCard("a.jpg"))
        XCTAssertTrue(onCard("b.jpg"))
        XCTAssertTrue(onCard("a.xmp"), "a stopped run moves no shared xmp")
    }

    // MARK: space

    func testSpaceProblemWhenTheDestinationIsTooSmall() throws {
        let a = try write("a.jpg", String(repeating: "x", count: 1000))
        var environment = ImportCopyEngine.Environment.live
        environment.availableBytes = { _ in 5_000 }
        XCTAssertNotNil(ImportCopyEngine.spaceProblem(plan: plan([a]), destination: dest, environment: environment))
        environment.availableBytes = { _ in 10_000_000_000 }
        XCTAssertNil(ImportCopyEngine.spaceProblem(plan: plan([a]), destination: dest, environment: environment))
        environment.availableBytes = { _ in nil }
        XCTAssertNil(ImportCopyEngine.spaceProblem(plan: plan([a]), destination: dest, environment: environment))
    }

    func testFreeSpaceTakesTheLargestFigureAnySourceReports() {
        // The "important usage" key read 0 on an empty exFAT volume: the other sources must win.
        XCTAssertEqual(ImportCopyEngine.bestAvailable(important: 0, plain: 0, posix: 60_000_000), 60_000_000)
        XCTAssertEqual(ImportCopyEngine.bestAvailable(important: 5, plain: 9, posix: nil), 9)
        XCTAssertEqual(ImportCopyEngine.bestAvailable(important: 0, plain: 0, posix: 0), 0, "a genuinely full volume reports 0 everywhere")
        XCTAssertNil(ImportCopyEngine.bestAvailable(important: nil, plain: nil, posix: nil))
    }

    func testTheLiveFreeSpaceReadingIsNonZeroForARealFolder() {
        XCTAssertGreaterThan(ImportCopyEngine.Environment.live.availableBytes(fm.temporaryDirectory) ?? 0, 0)
    }

    // MARK: the source is read-only

    func testTheEngineNeverRemovesOrMovesAnythingExceptItsOwnTempFiles() throws {
        let rootDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/Rendering/ImportCopyEngine.swift", "Sources/Rendering/ImportCopyPlan.swift"] {
            let source = try String(contentsOf: rootDir.appendingPathComponent(file), encoding: .utf8)
            for line in source.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if line.contains("removeItem(") { XCTAssertTrue(line.contains("tempURL"), "\(file): \(line)") }
                XCTAssertNil(line.range(of: "\\bmoveItem\\(", options: .regularExpression), "\(file): \(line)")
                XCTAssertFalse(line.contains("trashItem("), "\(file): \(line)")
                XCTAssertFalse(line.contains("removeItem(at: item.source") || line.contains("removeItem(at: companion.source"), "\(file): \(line)")
            }
        }
    }
}

/// A tiny thread-safe box for values the `@Sendable` closures mutate.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout T) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
