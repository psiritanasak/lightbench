import XCTest
@testable import PhotoApp

// MARK: - TrashPlan (pure rules)

final class TrashPlanTests: XCTestCase {
    private func photo(_ path: String, id: Int64, flag: FlagStatus = .none) -> Photo {
        Photo(id: id, path: path, filename: URL(fileURLWithPath: path).lastPathComponent, fileSize: nil,
              importedAt: Date(timeIntervalSince1970: 0), rating: 0, flagStatus: flag, colorLabel: .none)
    }

    /// A fake file system: `files` are regular files, `dirs` are folders, `unlistable` folders cannot be listed.
    private func plan(
        _ photos: [Photo], open: String? = nil, catalogued: [String]? = nil, files: Set<String>, dirs: Set<String> = [], unlistable: Set<String> = []
    ) -> TrashPlan {
        TrashPlan.make(
            photos: photos, openPhotoPath: open, cataloguedPaths: catalogued ?? photos.map(\.path),
            fileKind: { url in
                let path = url.standardizedFileURL.path
                return files.contains(path) ? .file : (dirs.contains(path) ? .directory : .missing)
            },
            folderListing: { folder in
                let folderPath = folder.standardizedFileURL.path
                if unlistable.contains(folderPath) { return nil }
                return (files.union(dirs)).map { URL(fileURLWithPath: $0) }.filter { $0.deletingLastPathComponent().standardizedFileURL.path == folderPath }
            })
    }

    func testAPhotoTravelsWithItsEditFileItsDarktableXMPAndItsOwnSharedXMP() {
        let result = plan([photo("/pics/IMG_1.jpg", id: 1)], files: ["/pics/IMG_1.jpg", "/pics/IMG_1.jpg.photoapp.json", "/pics/IMG_1.jpg.xmp", "/pics/IMG_1.xmp"])
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(Set(result.items[0].companions.map(\.kind)), [.editSidecar, .alternateXMP, .sharedXMP])
        XCTAssertEqual(result.items[0].companions.first { $0.kind == .editSidecar }?.url.lastPathComponent, "IMG_1.jpg.photoapp.json")
    }

    func testCompanionsThatDoNotExistAreNotPlanned() {
        let result = plan([photo("/pics/IMG_1.jpg", id: 1)], files: ["/pics/IMG_1.jpg"])
        XCTAssertEqual(result.items.map(\.photoURL.lastPathComponent), ["IMG_1.jpg"])
        XCTAssertTrue(result.items[0].companions.isEmpty)
    }

    func testAFolderNamedLikeACompanionIsNotMovedAsOne() {
        let result = plan([photo("/pics/IMG_1.jpg", id: 1)], files: ["/pics/IMG_1.jpg"], dirs: ["/pics/IMG_1.jpg.xmp", "/pics/IMG_1.jpg.photoapp.json"])
        XCTAssertTrue(result.items[0].companions.isEmpty)
    }

    // MARK: the shared .xmp

    func testTheSharedXMPStaysWhenTheRAWSiblingStaysOnDisk() {
        let result = plan([photo("/pics/IMG_1.jpg", id: 1)], files: ["/pics/IMG_1.jpg", "/pics/IMG_1.CR2", "/pics/IMG_1.xmp"])
        XCTAssertFalse(result.items[0].companions.contains { $0.kind == .sharedXMP })
    }

    func testTheSharedXMPStaysWhenTheJPEGSiblingStaysInTheCatalog() {
        let raw = photo("/pics/IMG_1.CR2", id: 1)
        let result = plan([raw], catalogued: [raw.path, "/pics/IMG_1.jpg"], files: ["/pics/IMG_1.CR2", "/pics/IMG_1.xmp"])
        XCTAssertFalse(result.items[0].companions.contains { $0.kind == .sharedXMP }, "the JPG is still in the catalog (even though its file is not listed)")
    }

    func testAVideoOrAnyOtherFileWithTheSameBaseNameKeepsTheSharedXMP() {
        for sibling in ["/pics/IMG_1.MOV", "/pics/IMG_1.psd", "/pics/IMG_1.unknownraw", "/pics/IMG_1.txt"] {
            let result = plan([photo("/pics/IMG_1.jpg", id: 1)], files: ["/pics/IMG_1.jpg", sibling, "/pics/IMG_1.xmp"])
            XCTAssertFalse(result.items[0].companions.contains { $0.kind == .sharedXMP }, "\(sibling) shares the base name, so it may own the .xmp")
        }
    }

    func testAFolderThatCannotBeListedNeverLosesItsSharedOrAlternateXMP() {
        let result = plan([photo("/pics/IMG_1.jpg", id: 1)], files: ["/pics/IMG_1.jpg", "/pics/IMG_1.xmp", "/pics/IMG_1.jpg.xmp"], unlistable: ["/pics"])
        XCTAssertEqual(result.items.count, 1, "the photo itself is still planned")
        XCTAssertFalse(result.items[0].companions.contains { $0.kind == .sharedXMP || $0.kind == .alternateXMP }, "what stays behind is unknown, so nothing shared is claimed")
    }

    func testTheDarktableXMPStaysWhenItIsAlsoTheSharedSidecarOfASiblingWithAnExtraExtension() {
        // a.jpg.xmp is darktable's file for a.jpg, but also the Adobe sidecar of a.jpg.dng.
        let result = plan([photo("/pics/a.jpg", id: 1)], files: ["/pics/a.jpg", "/pics/a.jpg.dng", "/pics/a.jpg.xmp"])
        XCTAssertFalse(result.items[0].companions.contains { $0.kind == .alternateXMP })
        let alone = plan([photo("/pics/a.jpg", id: 1)], files: ["/pics/a.jpg", "/pics/a.jpg.xmp"])
        XCTAssertTrue(alone.items[0].companions.contains { $0.kind == .alternateXMP })
    }

    func testAXMPThatIsBothADarktableAndASharedSidecarIsPlannedOnce() {
        // a.jpg.xmp is a.jpg's darktable file AND a.jpg.dng's Adobe sidecar; both photos are targets.
        let jpg = photo("/pics/a.jpg", id: 1), dng = photo("/pics/a.jpg.dng", id: 2)
        let result = plan([jpg, dng], files: ["/pics/a.jpg", "/pics/a.jpg.dng", "/pics/a.jpg.xmp"])
        let claims = result.items.flatMap(\.companions).filter { $0.url.lastPathComponent == "a.jpg.xmp" }
        XCTAssertEqual(claims.count, 1, "claimed once, so it can never be moved twice (and be reported as a failure)")
    }

    func testTheSharedSidecarOfADoubleExtensionPhotoStaysWhileThePhotoWhoseDarktableFileItIsStays() {
        // Trashing only a.jpg.dng: a.jpg.xmp is its Adobe sidecar but ALSO darktable's file for the staying a.jpg.
        let dng = photo("/pics/a.jpg.dng", id: 1)
        let staysCatalogued = plan([dng], catalogued: [dng.path, "/pics/a.jpg"], files: ["/pics/a.jpg.dng", "/pics/a.jpg", "/pics/a.jpg.xmp"])
        XCTAssertFalse(staysCatalogued.items[0].companions.contains { $0.kind == .sharedXMP })
        let staysOnDisk = plan([dng], files: ["/pics/a.jpg.dng", "/pics/a.jpg", "/pics/a.jpg.xmp"])
        XCTAssertFalse(staysOnDisk.items[0].companions.contains { $0.kind == .sharedXMP })
        let alone = plan([dng], files: ["/pics/a.jpg.dng", "/pics/a.jpg.xmp"])
        XCTAssertTrue(alone.items[0].companions.contains { $0.kind == .sharedXMP }, "with nothing else around it goes")
    }

    func testAnExtensionlessPhotoClaimsItsXMPOnlyOnce() {
        let result = plan([photo("/pics/README", id: 1)], files: ["/pics/README", "/pics/README.xmp"])
        XCTAssertEqual(result.items[0].companions.filter { $0.url.lastPathComponent == "README.xmp" }.count, 1, "sidecarURL and alternateSidecarURL are the same file here")
    }

    func testADuplicateRowOfTheOpenPhotoIsSkippedNotPlannedAndDoesNotCrash() {
        let a = photo("/pics/a.jpg", id: 1), alias = photo("/pics/./a.jpg", id: 2)
        let result = plan([a, alias], open: "/pics/a.jpg", files: ["/pics/a.jpg"])
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped.map(\.photoID), [1], "the first row is reported, the duplicate is silently covered by it")
    }

    func testTheSharedXMPIsClaimedOnceWhenBothPhotosOfAPairAreTrashed() {
        let raw = photo("/pics/IMG_1.CR2", id: 1), jpg = photo("/pics/IMG_1.jpg", id: 2)
        let result = plan([raw, jpg], files: ["/pics/IMG_1.CR2", "/pics/IMG_1.jpg", "/pics/IMG_1.xmp"])
        XCTAssertEqual(result.items.flatMap(\.companions).filter { $0.kind == .sharedXMP }.count, 1)
        XCTAssertEqual(result.items.count, 2)
    }

    func testAPhotoThatStaysBecauseItIsTheOpenOneKeepsTheSharedXMPAlive() {
        let raw = photo("/pics/IMG_1.CR2", id: 1), jpg = photo("/pics/IMG_1.jpg", id: 2)
        let result = plan([raw, jpg], open: jpg.path, files: ["/pics/IMG_1.CR2", "/pics/IMG_1.jpg", "/pics/IMG_1.xmp"])
        XCTAssertEqual(result.items.map(\.photoURL.lastPathComponent), ["IMG_1.CR2"])
        XCTAssertFalse(result.items[0].companions.contains { $0.kind == .sharedXMP }, "the open JPG stays and shares that file")
    }

    func testTheSharedBaseNameRuleIsPerFolderAndIgnoresCase() {
        let other = plan([photo("/a/IMG_1.jpg", id: 1)], catalogued: ["/a/IMG_1.jpg", "/b/IMG_1.CR2"], files: ["/a/IMG_1.jpg", "/a/IMG_1.xmp"])
        XCTAssertTrue(other.items[0].companions.contains { $0.kind == .sharedXMP }, "a RAW with the same name in ANOTHER folder is unrelated")
        let cased = plan([photo("/a/IMG_1.jpg", id: 1)], catalogued: ["/a/IMG_1.jpg", "/a/img_1.cr2"], files: ["/a/IMG_1.jpg", "/a/IMG_1.xmp"])
        XCTAssertFalse(cased.items[0].companions.contains { $0.kind == .sharedXMP }, "img_1.cr2 shares the base name on a case-insensitive disk")
    }

    // MARK: which photos move

    func testTheOpenPhotoIsNeverPlannedNorItsFiles() {
        let a = photo("/pics/a.jpg", id: 1), b = photo("/pics/b.jpg", id: 2)
        let result = plan([a, b], open: "/pics/a.jpg", files: ["/pics/a.jpg", "/pics/a.jpg.photoapp.json", "/pics/b.jpg"])
        XCTAssertEqual(result.items.map(\.photoURL.lastPathComponent), ["b.jpg"])
        XCTAssertEqual(result.skipped, [TrashPlan.Skipped(photoID: 1, name: "a.jpg", reason: .openInEditor)])
        XCTAssertFalse(result.items.flatMap(\.companions).contains { $0.url.lastPathComponent == "a.jpg.photoapp.json" })
    }

    func testTheOpenPhotoIsRecognisedThroughSymlinksAndCase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TrashPlanTests-\(UUID().uuidString)", isDirectory: true)
        let real = dir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: real)
        try Data("x".utf8).write(to: real.appendingPathComponent("a.jpg"))
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(TrashPlan.samePhoto(real.appendingPathComponent("a.jpg").path, dir.appendingPathComponent("link/a.jpg").path), "same file through a symlinked folder")
        XCTAssertTrue(TrashPlan.samePhoto("/Pics/IMG_1.JPG", "/pics/img_1.jpg"), "case differences count as the same photo")
        XCTAssertFalse(TrashPlan.samePhoto("/pics/a.jpg", "/pics/b.jpg"))
    }

    func testAPhotoWhoseFileIsNotOnDiskIsReportedNotPlanned() {
        let result = plan([photo("/pics/gone.jpg", id: 1)], files: [])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.skipped.map(\.reason), [.missingOnDisk])
    }

    func testAFolderCataloguedAsAPhotoIsNeverMoved() {
        let result = plan([photo("/pics/Edits.jpg", id: 1)], files: [], dirs: ["/pics/Edits.jpg"])
        XCTAssertTrue(result.isEmpty, "trashItem would take the whole folder")
        XCTAssertEqual(result.skipped, [TrashPlan.Skipped(photoID: 1, name: "Edits.jpg", reason: .notAFile)])
    }

    func testTwoCatalogRowsForOneFileMoveTogetherAndBothRowsGo() {
        let first = photo("/pics/a.jpg", id: 1), second = photo("/pics/a.jpg", id: 2)
        let result = plan([first, second], files: ["/pics/a.jpg"])
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].photoID, 1)
        XCTAssertEqual(result.items[0].alsoIDs, [2], "the duplicate row's file is gone too, so its row goes with it")
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testTheSameRowTwiceAndRowsWithoutAnIDAreIgnored() {
        let a = photo("/pics/a.jpg", id: 1)
        let noID = Photo(id: nil, path: "/pics/n.jpg", filename: "n.jpg", fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
                         rating: 0, flagStatus: .none, colorLabel: .none)
        let result = plan([a, a, noID], files: ["/pics/a.jpg", "/pics/n.jpg"])
        XCTAssertEqual(result.items.count, 1)
        XCTAssertTrue(result.items[0].alsoIDs.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testThePlanWorksOnRealFilesToo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TrashPlanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["IMG_7.jpg", "IMG_7.jpg.photoapp.json", "IMG_7.xmp", "IMG_7.CR2"] { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Edits.jpg"), withIntermediateDirectories: true)
        let p = Photo(id: 1, path: dir.appendingPathComponent("IMG_7.jpg").path, filename: "IMG_7.jpg", fileSize: nil,
                      importedAt: Date(timeIntervalSince1970: 0), rating: 0, flagStatus: .rejected, colorLabel: .none)
        let folder = Photo(id: 2, path: dir.appendingPathComponent("Edits.jpg").path, filename: "Edits.jpg", fileSize: nil,
                           importedAt: Date(timeIntervalSince1970: 0), rating: 0, flagStatus: .rejected, colorLabel: .none)
        let result = TrashPlan.make(photos: [p, folder], openPhotoPath: nil, cataloguedPaths: [p.path, folder.path])
        XCTAssertEqual(Set(result.items[0].companions.map(\.kind)), [.editSidecar], "the RAW on disk (a real folder listing) keeps the shared .xmp alive")
        XCTAssertEqual(result.skipped.map(\.reason), [.notAFile], "a real directory named Edits.jpg is never planned")
    }
}

// MARK: - TrashEngine (the moves)

final class TrashEngineTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var urls: [String] = []
        func record(_ url: URL) { lock.lock(); urls.append(url.lastPathComponent); lock.unlock() }
    }

    private func item(_ id: Int64, _ name: String, companions: [(String, TrashPlan.CompanionKind)] = [], also: [Int64] = []) -> TrashPlan.Item {
        TrashPlan.Item(photoID: id, photoURL: URL(fileURLWithPath: "/pics/\(name)"), alsoIDs: also, companions: companions.map {
            TrashPlan.Companion(url: URL(fileURLWithPath: "/pics/\($0.0)"), kind: $0.1)
        })
    }

    private struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

    func testEachPhotoMovesBeforeItsCompanionsAndNothingElseIsTouched() async {
        let recorder = Recorder()
        let plan = TrashPlan(items: [item(1, "a.jpg", companions: [("a.json", .editSidecar), ("a.xmp", .alternateXMP)]), item(2, "b.jpg")],
                             skipped: [.init(photoID: 3, name: "open.jpg", reason: .openInEditor)])
        let outcome = await TrashEngine.apply(plan, mover: { url in recorder.record(url); return nil })
        XCTAssertEqual(recorder.urls, ["a.jpg", "a.json", "b.jpg", "a.xmp"], "exactly the planned files; photos and edit files first, every .xmp last; the skipped one is never touched")
        XCTAssertEqual(outcome.trashedIDs, [1, 2])
        XCTAssertEqual(outcome.companionsTrashed, 2)
        XCTAssertTrue(outcome.failures.isEmpty)
    }

    func testAPhotoThatFailsToMoveKeepsItsCompanionsAndItsRow() async {
        let recorder = Recorder()
        let plan = TrashPlan(items: [item(1, "a.jpg", companions: [("a.json", .editSidecar)]), item(2, "b.jpg", companions: [("b.json", .editSidecar)])])
        let outcome = await TrashEngine.apply(plan, mover: { url in
            recorder.record(url)
            if url.lastPathComponent == "a.jpg" { throw Boom() }
            return nil
        })
        XCTAssertEqual(recorder.urls, ["a.jpg", "b.jpg", "b.json"], "a.json is not moved after a.jpg failed")
        XCTAssertEqual(outcome.trashedIDs, [2], "only the photo whose file reached the Trash loses its row")
        XCTAssertEqual(outcome.failures, [TrashEngine.Failure(photoID: 1, name: "a.jpg", message: "boom")])
    }

    func testACompanionFailureIsCountedAndTheMovedPhotoStillCounts() async {
        let plan = TrashPlan(items: [item(1, "a.jpg", companions: [("a.json", .editSidecar), ("a.xmp", .alternateXMP)])])
        let outcome = await TrashEngine.apply(plan, mover: { url in
            if url.lastPathComponent == "a.json" { throw Boom() }
            return nil
        })
        XCTAssertEqual(outcome.trashedIDs, [1])
        XCTAssertEqual(outcome.companionsTrashed, 1)
        XCTAssertEqual(outcome.companionsFailed, 1)
    }

    func testAnEmptyPlanMovesNothing() async {
        let recorder = Recorder()
        let outcome = await TrashEngine.apply(TrashPlan(), mover: { url in recorder.record(url); return nil })
        XCTAssertTrue(recorder.urls.isEmpty)
        XCTAssertEqual(outcome, TrashEngine.Outcome())
    }

    func testADuplicateRowsIdGoesWithItsPhoto() async {
        let outcome = await TrashEngine.apply(TrashPlan(items: [item(1, "a.jpg", also: [7, 8])]), mover: { _ in nil })
        XCTAssertEqual(outcome.trashedIDs, [1, 7, 8])
    }

    // MARK: the shared .xmp is moved last, and only when every photo sharing it went

    private func pair() -> TrashPlan {
        TrashPlan(items: [item(1, "IMG_1.NEF", companions: [("IMG_1.xmp", .sharedXMP), ("IMG_1.NEF.json", .editSidecar)]), item(2, "IMG_1.JPG")])
    }

    func testTheSharedXMPMovesLastWhenBothPhotosOfThePairWent() async {
        let recorder = Recorder()
        let outcome = await TrashEngine.apply(pair(), mover: { url in recorder.record(url); return nil })
        XCTAssertEqual(recorder.urls, ["IMG_1.NEF", "IMG_1.NEF.json", "IMG_1.JPG", "IMG_1.xmp"], "after every photo, never between them")
        XCTAssertEqual(outcome.companionsTrashed, 2)
    }

    func testTheSharedXMPStaysWhenOnePhotoOfThePairFailedToMove() async {
        let recorder = Recorder()
        _ = await TrashEngine.apply(pair(), mover: { url in
            recorder.record(url)
            if url.lastPathComponent == "IMG_1.JPG" { throw Boom() }
            return nil
        })
        XCTAssertFalse(recorder.urls.contains("IMG_1.xmp"), "IMG_1.JPG stays in the folder and shares that file")
    }

    func testTheSharedXMPStaysWhenAPhotoOfThePairBecameTheOpenOneAtTheLastMoment() async {
        let recorder = Recorder()
        let outcome = await TrashEngine.apply(pair(), mover: { url in recorder.record(url); return nil }, gate: { item in
            item.photoURL.lastPathComponent == "IMG_1.JPG" ? .skipOpen : .proceed
        })
        XCTAssertEqual(recorder.urls, ["IMG_1.NEF", "IMG_1.NEF.json"], "the NEF moved, the open JPG and the .xmp it shares did not")
        XCTAssertEqual(outcome.lateSkippedOpen, ["IMG_1.JPG"])
        XCTAssertEqual(outcome.trashedIDs, [1])
    }

    func testAStoppedRunLeavesEverythingNotYetMovedAndTheSharedXMP() async {
        let recorder = Recorder()
        let outcome = await TrashEngine.apply(pair(), mover: { url in recorder.record(url); return nil }, gate: { item in
            item.photoID == 2 ? .stop("An export is running") : .proceed
        })
        XCTAssertEqual(recorder.urls, ["IMG_1.NEF", "IMG_1.NEF.json"])
        XCTAssertEqual(outcome.stoppedBecause, "An export is running")
        XCTAssertEqual(outcome.notAttempted, 1)
        XCTAssertEqual(outcome.trashedIDs, [1])
    }

    func testTheGateIsAskedBeforeEveryPhotoAndNeverForAnEmptyPlan() async {
        let asked = Recorder()
        _ = await TrashEngine.apply(TrashPlan(items: [item(1, "a.jpg"), item(2, "b.jpg")]), mover: { _ in nil }, gate: { item in
            asked.record(item.photoURL); return .proceed
        })
        XCTAssertEqual(asked.urls, ["a.jpg", "b.jpg"])
    }

    // MARK: the darktable .xmp that a sibling may share

    private func jpgAndDNG() -> TrashPlan {
        TrashPlan(items: [
            item(1, "a.jpg", companions: [("a.jpg.xmp", .alternateXMP)]),
            item(2, "a.jpg.dng")
        ])
    }

    func testTheDarktableXMPMovesLastAndOnlyOnceWhenBothPhotosWent() async {
        let recorder = Recorder()
        let outcome = await TrashEngine.apply(jpgAndDNG(), mover: { url in recorder.record(url); return nil })
        XCTAssertEqual(recorder.urls, ["a.jpg", "a.jpg.dng", "a.jpg.xmp"])
        XCTAssertEqual(outcome.companionsTrashed, 1)
        XCTAssertEqual(outcome.companionsFailed, 0)
    }

    func testTheDarktableXMPStaysWhenTheSiblingThatMayShareItFailedOrWasSkipped() async {
        for failure in ["fails", "open"] {
            let recorder = Recorder()
            _ = await TrashEngine.apply(jpgAndDNG(), mover: { url in
                recorder.record(url)
                if failure == "fails", url.lastPathComponent == "a.jpg.dng" { throw Boom() }
                return nil
            }, gate: { item in failure == "open" && item.photoURL.lastPathComponent == "a.jpg.dng" ? .skipOpen : .proceed })
            XCTAssertFalse(recorder.urls.contains("a.jpg.xmp"), "a.jpg.dng stays (\(failure)) and a.jpg.xmp is ITS Adobe sidecar")
        }
    }

    func testTheDngFirstOrderKeepsTheSharedSidecarWhenTheJpgFailsOrIsSkipped() async {
        // Grid order [a.jpg.dng, a.jpg]: the dng owns a.jpg.xmp as its shared sidecar, which is also a.jpg's darktable file.
        for failure in ["fails", "open"] {
            let recorder = Recorder()
            let plan = TrashPlan(items: [item(1, "a.jpg.dng", companions: [("a.jpg.xmp", .sharedXMP)]), item(2, "a.jpg")])
            _ = await TrashEngine.apply(plan, mover: { url in
                recorder.record(url)
                if failure == "fails", url.lastPathComponent == "a.jpg" { throw Boom() }
                return nil
            }, gate: { item in failure == "open" && item.photoURL.lastPathComponent == "a.jpg" ? .skipOpen : .proceed })
            XCTAssertFalse(recorder.urls.contains("a.jpg.xmp"), "a.jpg stays (\(failure)) and a.jpg.xmp is ITS darktable file")
        }
        let recorder = Recorder()
        _ = await TrashEngine.apply(TrashPlan(items: [item(1, "a.jpg.dng", companions: [("a.jpg.xmp", .sharedXMP)]), item(2, "a.jpg")]),
                                    mover: { url in recorder.record(url); return nil })
        XCTAssertEqual(recorder.urls, ["a.jpg.dng", "a.jpg", "a.jpg.xmp"], "both went, so it goes — last")
    }

    func testAStoppedRunMovesNoXMPAtAll() async {
        let recorder = Recorder()
        let plan = TrashPlan(items: [
            item(1, "IMG_1.NEF", companions: [("IMG_1.xmp", .sharedXMP)]),
            item(2, "IMG_1.JPG"),
            item(3, "other.jpg")
        ])
        let outcome = await TrashEngine.apply(plan, mover: { url in recorder.record(url); return nil }, gate: { item in
            item.photoID == 3 ? .stop("A tool started") : .proceed
        })
        XCTAssertEqual(recorder.urls, ["IMG_1.NEF", "IMG_1.JPG"], "both sharers went, yet the .xmp waits: a stopped run touches nothing more")
        XCTAssertEqual(outcome.stoppedBecause, "A tool started")
    }

    // MARK: the real mover

    func testTheSystemMoverRefusesInTheTestHostAndLeavesTheFileAlone() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("TrashEngineTests-\(UUID().uuidString).jpg")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try TrashEngine.systemTrash(file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a test can never put a file in a real Trash")
    }

    func testTheFileOperationsAreTheTrashAndNothingElse() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Rendering/TrashPlan.swift"), encoding: .utf8)
        // Strip comments: the doc text legitimately mentions "removeItem".
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }.joined(separator: "\n")
        XCTAssertTrue(code.contains("FileManager.default.trashItem(at: url, resultingItemURL: &result)"))
        for forbidden in ["removeItem", "removeItems", "unlink(", "moveItem", "copyItem", "replaceItemAt"] {
            XCTAssertFalse(code.contains(forbidden), "TrashPlan.swift must never use \(forbidden): the Trash is the only way a file leaves its folder")
        }
        let model = try String(contentsOf: root.appendingPathComponent("Sources/UI/TrashModel.swift"), encoding: .utf8)
        for forbidden in ["removeItem", "unlink(", "moveItem", "trashItem"] {
            XCTAssertFalse(model.contains(forbidden), "TrashModel must go through TrashEngine.systemTrash, not call \(forbidden) itself")
        }
    }
}

// MARK: - Catalog + model flow

@MainActor
private final class StubAccess: SidecarFolderAccessing {
    var grant: Bool = true
    /// When set, a granted URL for the wrong folder (it does not cover the photo's folder).
    var grantsUnrelatedFolder = false
    var failure: Error?
    var duringPrompt: (() -> Void)?
    private(set) var requests = 0
    func resolvedURL(for folder: URL) -> URL? { nil }
    func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome {
        requests += 1
        duringPrompt?()
        if let failure { return .failed(failure) }
        if grantsUnrelatedFolder { return .granted(URL(fileURLWithPath: "/tmp/not-the-photos-folder")) }
        return grant ? .granted(folder) : .declined
    }
}

private final class MoveLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var names: [String] = []
    var failing: Set<String> = []
    func mover() -> TrashEngine.Mover {
        { [self] url in
            lock.lock(); defer { lock.unlock() }
            names.append(url.lastPathComponent)
            if failing.contains(url.lastPathComponent) { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no luck"]) }
            return nil
        }
    }
}

@MainActor
final class TrashModelTests: XCTestCase {
    private var dir: URL!
    private var db: CatalogDatabase!
    private var catalog: CatalogModel!
    private var access: StubAccess!
    private var log: MoveLog!
    private var model: TrashModel!
    private var suiteName = ""
    private var busy: String?
    private var open: String?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TrashModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try CatalogDatabase(inMemory: true)
        suiteName = "TrashModelTests-\(UUID().uuidString)"
        catalog = CatalogModel(database: db, defaults: UserDefaults(suiteName: suiteName)!)
        access = StubAccess()
        log = MoveLog()
        model = TrashModel(folderAccess: access, mover: log.mover())
        busy = nil
        open = nil
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private var providers: RenameProviders { RenameProviders(openPhotoPath: { self.open }, busyReason: { self.busy }) }

    /// Imports files named `names` (real files in the temp folder); `rejected` get the Rejected flag.
    private func makePhotos(_ names: [String], rejected: Set<String> = []) async throws -> [Photo] {
        for name in names { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }
        _ = try await db.importPhotos(at: names.map { dir.appendingPathComponent($0) })
        for photo in try await db.allPhotos() where rejected.contains(photo.filename) { try await db.setFlagStatus(.rejected, for: photo.id!) }
        await catalog.refresh()
        return try await db.allPhotos().filter { names.contains($0.filename) }.sorted { $0.filename < $1.filename }
    }

    private func run(_ kind: TrashModel.Kind, shown: [Photo]) async throws {
        model.request(kind, shown: shown, scope: "All Photos", providers: providers, catalog: catalog)
        let request = try XCTUnwrap(model.pending)
        model.confirm(request, providers: providers, catalog: catalog)
        for _ in 0..<2000 where model.isWorking { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(model.isWorking)
    }

    private func remaining() async throws -> [String] { try await db.allPhotos().map(\.filename).sorted() }

    // MARK: request

    func testRejectedActsOnlyOnRejectedPhotosAmongThoseShown() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg", "c.jpg"], rejected: ["a.jpg", "c.jpg"])
        let shown = try await db.allPhotos().filter { $0.filename != "c.jpg" } // c.jpg is rejected but hidden by a filter
        model.request(.rejected, shown: shown, scope: "All Photos", providers: providers, catalog: catalog)
        XCTAssertEqual(model.pending?.photos.map(\.filename), ["a.jpg"], "b is not rejected, c is not shown")
        _ = photos
    }

    func testNothingRejectedOrSelectedExplainsInsteadOfOpeningADialog() async throws {
        let photos = try await makePhotos(["a.jpg"])
        model.request(.rejected, shown: photos, scope: "All Photos", providers: providers, catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.statusMessage, "There are no rejected photos in what the Library is showing.")
        model.statusMessage = nil
        model.request(.selected, shown: [], scope: "All Photos", providers: providers, catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.statusMessage, "Select at least one photo first.")
    }

    func testARequestIsRefusedWhileSomethingElseIsBusyOrARenameRuns() async throws {
        let photos = try await makePhotos(["a.jpg"], rejected: ["a.jpg"])
        busy = "An export is running or being set up — finish or cancel it first."
        model.request(.rejected, shown: photos, scope: "x", providers: providers, catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.statusMessage, busy)
        busy = nil
        catalog.isRenameInProgress = true
        model.request(.rejected, shown: photos, scope: "x", providers: providers, catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.statusMessage, CatalogModel.renameInProgressMessage)
    }

    func testNothingMovesWithoutAConfirmation() async throws {
        let photos = try await makePhotos(["a.jpg"], rejected: ["a.jpg"])
        model.request(.rejected, shown: photos, scope: "All Photos", providers: providers, catalog: catalog)
        XCTAssertNotNil(model.pending)
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(catalog.trashBusy, "a pending confirmation blocks the other file tools")
        XCTAssertTrue(log.names.isEmpty)
        model.cancel()
        XCTAssertFalse(catalog.trashBusy)
        XCTAssertTrue(log.names.isEmpty)
        let names = try await remaining()
        XCTAssertEqual(names, ["a.jpg"])
    }

    // MARK: the run

    func testConfirmMovesTheRejectedPhotosWithTheirFilesAndDropsOnlyTheirRows() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg", "keep.jpg"], rejected: ["a.jpg", "b.jpg"])
        try Data("{}".utf8).write(to: dir.appendingPathComponent("a.jpg.photoapp.json"))
        try await run(.rejected, shown: photos)
        XCTAssertEqual(Set(log.names), ["a.jpg", "a.jpg.photoapp.json", "b.jpg"])
        let names = try await remaining()
        XCTAssertEqual(names, ["keep.jpg"])
        XCTAssertEqual(catalog.photoCount, 1, "the library was re-read")
        XCTAssertEqual(model.statusMessage, "Moved 2 photos to the Trash with 1 edit / XMP file.")
        XCTAssertFalse(catalog.trashBusy)
    }

    func testThePhotoOpenInTheEditorIsSkippedAndKeepsItsRowAndFiles() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"], rejected: ["a.jpg", "b.jpg"])
        open = dir.appendingPathComponent("a.jpg").path
        try await run(.rejected, shown: photos)
        XCTAssertEqual(log.names, ["b.jpg"])
        let names = try await remaining()
        XCTAssertEqual(names, ["a.jpg"])
        XCTAssertTrue(try XCTUnwrap(model.statusMessage).contains("skipped a.jpg because it is open in the Editor"))
    }

    func testAPhotoThatBecomesTheOpenOneMidRunIsStillSkipped() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"], rejected: ["a.jpg", "b.jpg"])
        // Not open while planning; b.jpg becomes the open photo once a.jpg has moved (tied to the run itself, not to how often it is asked).
        let sneaky = RenameProviders(openPhotoPath: { self.log.names.isEmpty ? nil : self.dir.appendingPathComponent("b.jpg").path }, busyReason: { nil })
        model.request(.rejected, shown: photos, scope: "x", providers: sneaky, catalog: catalog)
        model.confirm(try XCTUnwrap(model.pending), providers: sneaky, catalog: catalog)
        for _ in 0..<2000 where model.isWorking { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(log.names, ["a.jpg"], "b.jpg became the open photo before its turn and was left alone")
        let names = try await remaining()
        XCTAssertEqual(names, ["b.jpg"])
        XCTAssertTrue(try XCTUnwrap(model.statusMessage).contains("skipped b.jpg because it is open in the Editor"))
    }

    func testAFlagChangedAfterTheDialogOpenedIsRespected() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"], rejected: ["a.jpg", "b.jpg"])
        let id = try XCTUnwrap(photos.first { $0.filename == "a.jpg" }?.id)
        model.request(.rejected, shown: photos, scope: "All Photos", providers: providers, catalog: catalog)
        let request = try XCTUnwrap(model.pending)
        // While the dialog (and the folder prompts after it) are up the grid stays interactive: a.jpg is un-rejected meanwhile.
        try await db.setFlagStatus(.picked, for: id)
        model.confirm(request, providers: providers, catalog: catalog)
        for _ in 0..<2000 where model.isWorking { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(log.names, ["b.jpg"], "a.jpg is no longer rejected and must not be trashed")
        let names = try await remaining()
        XCTAssertEqual(names, ["a.jpg"])
        XCTAssertTrue(try XCTUnwrap(model.statusMessage).contains("no longer rejected"))
    }

    func testSomethingBecomingBusyDuringThePromptAbortsBeforeAnyMove() async throws {
        let photos = try await makePhotos(["a.jpg"], rejected: ["a.jpg"])
        access.duringPrompt = { self.busy = "A photo is still loading — try again in a moment." }
        try await run(.rejected, shown: photos)
        XCTAssertTrue(log.names.isEmpty)
        XCTAssertEqual(model.statusMessage, "A photo is still loading — try again in a moment.")
        let names = try await remaining()
        XCTAssertEqual(names, ["a.jpg"])
    }

    func testSomethingBecomingBusyMidRunStopsTheRestAndLeavesThemInPlace() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg", "c.jpg"], rejected: ["a.jpg", "b.jpg", "c.jpg"])
        // Busy as soon as one photo has moved (an export started, say): checked before EVERY photo, not once.
        let midRun = RenameProviders(openPhotoPath: { nil }, busyReason: { self.log.names.isEmpty ? nil : "An export is running or being set up — finish or cancel it first." })
        model.request(.rejected, shown: photos, scope: "x", providers: midRun, catalog: catalog)
        model.confirm(try XCTUnwrap(model.pending), providers: midRun, catalog: catalog)
        for _ in 0..<2000 where model.isWorking { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(log.names, ["a.jpg"], "the run stopped after the first photo")
        let names = try await remaining()
        XCTAssertEqual(names, ["b.jpg", "c.jpg"])
        let message = try XCTUnwrap(model.statusMessage)
        XCTAssertTrue(message.contains("stopped early") && message.contains("2 photos left untouched"), message)
    }

    func testARAWAndJPEGPairKeepsTheSharedXMPWhenTheRAWBecomesTheOpenPhotoMidRun() async throws {
        let photos = try await makePhotos(["IMG_1.NEF", "IMG_1.JPG"], rejected: ["IMG_1.NEF", "IMG_1.JPG"])
        try Data("<x/>".utf8).write(to: dir.appendingPathComponent("IMG_1.xmp"))
        let nef = dir.appendingPathComponent("IMG_1.NEF").path
        // Planned in name order (the JPG first, which claims the shared .xmp). Not open while planning; the NEF becomes the open photo once
        // the JPG has moved, before its own turn.
        let providers = RenameProviders(openPhotoPath: { self.log.names.isEmpty ? nil : nef }, busyReason: { nil })
        model.request(.rejected, shown: photos, scope: "x", providers: providers, catalog: catalog)
        model.confirm(try XCTUnwrap(model.pending), providers: providers, catalog: catalog)
        for _ in 0..<2000 where model.isWorking { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(log.names, ["IMG_1.JPG"], "the open NEF and the .xmp it shares were never touched")
        let names = try await remaining()
        XCTAssertEqual(names, ["IMG_1.NEF"])
    }

    func testAFailedAccessPromptMovesNothingAndShowsTheError() async throws {
        let photos = try await makePhotos(["a.jpg"], rejected: ["a.jpg"])
        access.failure = NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "bookmark broke"])
        try await run(.rejected, shown: photos)
        XCTAssertTrue(log.names.isEmpty)
        XCTAssertEqual(model.statusMessage, "bookmark broke")
        let names = try await remaining()
        XCTAssertEqual(names, ["a.jpg"])
    }

    func testAGrantThatDoesNotCoverThePhotosFolderCountsAsNoAccess() async throws {
        let photos = try await makePhotos(["a.jpg"], rejected: ["a.jpg"])
        access.grantsUnrelatedFolder = true
        try await run(.rejected, shown: photos)
        XCTAssertTrue(log.names.isEmpty)
        XCTAssertTrue(try XCTUnwrap(model.statusMessage).contains("folder access not granted"))
    }

    func testARenameStartingDuringThePromptAbortsBeforeAnyMove() async throws {
        let photos = try await makePhotos(["a.jpg"], rejected: ["a.jpg"])
        access.duringPrompt = { self.catalog.isRenameInProgress = true }
        try await run(.rejected, shown: photos)
        XCTAssertTrue(log.names.isEmpty)
        XCTAssertEqual(model.statusMessage, CatalogModel.renameInProgressMessage)
    }

    func testADeclinedFolderMovesNothingAndSaysSo() async throws {
        let photos = try await makePhotos(["a.jpg"], rejected: ["a.jpg"])
        access.grant = false
        try await run(.rejected, shown: photos)
        XCTAssertTrue(log.names.isEmpty)
        XCTAssertEqual(model.statusMessage, "Nothing was moved to the Trash; 1 photo skipped (folder access not granted).")
        let names = try await remaining()
        XCTAssertEqual(names, ["a.jpg"])
    }

    func testAPhotoThatCannotBeMovedKeepsItsRowAndIsReported() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"], rejected: ["a.jpg", "b.jpg"])
        log.failing = ["a.jpg"]
        try await run(.rejected, shown: photos)
        let names = try await remaining()
        XCTAssertEqual(names, ["a.jpg"], "only b.jpg left the library")
        let message = try XCTUnwrap(model.statusMessage)
        XCTAssertTrue(message.contains("Moved 1 photo to the Trash"))
        XCTAssertTrue(message.contains("1 photo could not be moved and stay in the Library (no luck)"), message)
    }

    func testAPhotoAlreadyMissingFromDiskIsReportedAndKeepsItsRow() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"], rejected: ["a.jpg", "b.jpg"])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("a.jpg"))
        try await run(.rejected, shown: photos)
        XCTAssertEqual(log.names, ["b.jpg"])
        let names = try await remaining()
        XCTAssertEqual(names, ["a.jpg"])
        XCTAssertTrue(try XCTUnwrap(model.statusMessage).contains("not on disk"))
    }

    func testSelectedPhotosAreMovedWhateverTheirFlag() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"])
        try await run(.selected, shown: [photos[0]])
        XCTAssertEqual(log.names, ["a.jpg"])
        let names = try await remaining()
        XCTAssertEqual(names, ["b.jpg"])
    }

    func testRemovingTheLastPhotosLeavesAnEmptyLibraryState() async throws {
        let photos = try await makePhotos(["a.jpg"], rejected: ["a.jpg"])
        try await run(.rejected, shown: photos)
        XCTAssertEqual(catalog.photoCount, 0)
        XCTAssertTrue(catalog.photos.isEmpty)
        XCTAssertEqual(LibraryEmptyKind.of(isLoaded: catalog.isLoaded, photoCount: catalog.photoCount, shownCount: catalog.photos.count, isCollectionSelected: false), .emptyLibrary)
    }

    func testTrashedPhotosAreForgottenInTheSelectionAndFocus() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg"], rejected: ["a.jpg"])
        photos.forEach { catalog.toggleSelection(of: $0) }
        catalog.focusedPhotoPath = dir.appendingPathComponent("a.jpg").path
        try await run(.rejected, shown: photos)
        XCTAssertEqual(catalog.selectedPhotoIDs, [photos[1].id!])
        XCTAssertNil(catalog.focusedPhotoPath)
    }

    // MARK: database + text + wiring

    func testDeletePhotosRemovesOnlyTheGivenRowsAndTheirCascades() async throws {
        let photos = try await makePhotos(["a.jpg", "b.jpg", "c.jpg"])
        _ = try await db.addKeywords(["Sky"], to: photos.compactMap(\.id))
        let removed = try await db.deletePhotos(ids: [photos[0].id!, photos[2].id!, 9999])
        XCTAssertEqual(removed, 2, "an unknown id is ignored")
        let names = try await remaining()
        XCTAssertEqual(names, ["b.jpg"])
        let links = try await db.allKeywordLinks()
        XCTAssertEqual(links.map(\.photoId), [photos[1].id!], "keyword links of the removed photos cascaded away")
        let none = try await db.deletePhotos(ids: [])
        XCTAssertEqual(none, 0)
    }

    func testTheConfirmationNamesTheScopeAndPromisesTheTrashNotADelete() {
        let request = TrashModel.Request(kind: .rejected, photos: [], scope: "“Holiday”")
        XCTAssertTrue(TrashModel.confirmationMessage(request).contains("“Holiday”"))
        XCTAssertTrue(TrashModel.confirmationMessage(request).contains("Nothing is permanently deleted"))
        XCTAssertTrue(TrashModel.confirmationMessage(request).contains("Put Back"))
        XCTAssertEqual(TrashModel.confirmationTitle(.init(kind: .selected, photos: [Photo](), scope: "x")), "Move 0 photos to the Trash?")
    }

    func testTheSummaryReadsWellForEveryOutcome() {
        var r = TrashModel.Result()
        XCTAssertEqual(TrashModel.summary(r), "Nothing was moved to the Trash.")
        r.trashed = 1; r.companions = 3
        XCTAssertEqual(TrashModel.summary(r), "Moved 1 photo to the Trash with 3 edit / XMP files.")
        r.catalogError = "disk full"
        XCTAssertTrue(TrashModel.summary(r).contains("the photos are in the Trash but the Library could not be updated (disk full)"))
    }

    func testWiringConfirmationIsDestructiveWithNoDefaultButtonAndTheGatesAreInPlace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let dialog = try source("Sources/UI/TrashDialogModifier.swift")
        XCTAssertTrue(dialog.contains("Button(\"Move to Trash\", role: .destructive)"))
        XCTAssertFalse(dialog.contains("defaultAction"), "Return must not confirm a destructive dialog")
        XCTAssertTrue(dialog.contains("catalog.displayedPhotos"), "Rejected acts on what the Library shows")
        XCTAssertTrue(dialog.contains("catalog.selectedPhotosInDisplayedGrid"))
        let app = try source("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("Button(\"Move Rejected to Trash…\") { catalog.trashRequested = .rejected }"))
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("isTrashBusy: includingTrash && catalog.trashBusy"), "the Trash's own providers must not count its own flag")
        XCTAssertTrue(content.contains("trashProviders: trashProviders"))
        XCTAssertTrue(try source("Sources/UI/CatalogModel.swift").contains("mergeBusy || xmpBusy || trashBusy || importCopyBusy || backupBusy"))
        XCTAssertTrue(RenameBusyState(isTrashBusy: true).reason != nil, "a rename waits for a Trash run")
    }
}
