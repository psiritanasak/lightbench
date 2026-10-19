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

    // MARK: the source is read-only

    func testTheEngineNeverRemovesOrMovesAnythingExceptItsOwnTempFiles() throws {
        let rootDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/Rendering/ImportCopyEngine.swift", "Sources/Rendering/ImportCopyPlan.swift"] {
            let source = try String(contentsOf: rootDir.appendingPathComponent(file), encoding: .utf8)
            for line in source.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if line.contains("removeItem(") { XCTAssertTrue(line.contains("tempURL"), "\(file): \(line)") }
                XCTAssertNil(line.range(of: "\\bmoveItem\\(", options: .regularExpression), "\(file): \(line)")
                XCTAssertFalse(line.contains("trashItem("), "\(file): \(line)")
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
