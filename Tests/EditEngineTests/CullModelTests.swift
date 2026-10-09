import CoreImage
import XCTest
@testable import PhotoApp

/// The cull model driven through its environment closures: a dictionary stands in for the catalog rows, the setters write to it (as the
/// optimistic `CatalogModel` setters do) and record what was written.
@MainActor
final class CullModelTests: XCTestCase {
    private var tempDir: URL!
    private var rows: [Int64: Photo] = [:]
    private var order: [Int64] = []
    private var writes: [String] = []

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CullModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        rows = [:]; order = []; writes = []
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func addPhotos(_ n: Int, flags: [Int64: FlagStatus] = [:]) throws {
        for i in 1...n {
            let id = Int64(i)
            // A different colour per photo, so a test can tell WHICH photo is on screen.
            let image = CIImage(color: CIColor(red: 0.1 * Double(i), green: 0.7, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 900, height: 600))
            let url = tempDir.appendingPathComponent("p\(i).png")
            try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            rows[id] = Photo(id: id, path: url.path, filename: url.lastPathComponent, fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
                             rating: 0, flagStatus: flags[id] ?? .none, colorLabel: .none)
            order.append(id)
        }
    }

    private var slowThumbnail: UInt64 = 0

    private func makeModel() -> CullModel {
        let model = CullModel()
        model.configure(CullEnvironment(
            photos: { self.order.compactMap { self.rows[$0] } },
            rows: { self.rows },
            setRating: { value, photo in self.rows[photo.id!]?.rating = value; self.writes.append("rating \(photo.id!)=\(value)") },
            setFlag: { value, photo in self.rows[photo.id!]?.flagStatus = value; self.writes.append("flag \(photo.id!)=\(value)") },
            setLabel: { value, photo in self.rows[photo.id!]?.colorLabel = value; self.writes.append("label \(photo.id!)=\(value)") },
            thumbnail: { _ in
                if self.slowThumbnail > 0 { try? await Task.sleep(nanoseconds: self.slowThumbnail) }
                return nil
            }))
        return model
    }

    private func waitForImage(_ model: CullModel) async {
        for _ in 0..<600 {
            if model.showsCurrentPhoto, !model.isPlaceholder { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the preview never loaded")
    }

    /// Photo keys are refused until the picture on screen is the current photo's, so tests wait for it after every move.
    private func settle(_ model: CullModel) async { await waitForImage(model) }

    // MARK: Start / stop

    func testBeginNeedsPhotosAndStartsUnflaggedOnlyWhenAnyAreUnflagged() async throws {
        XCTAssertFalse(makeModel().begin(startingAtPath: nil), "nothing to cull")
        try addPhotos(4, flags: [1: .picked, 2: .rejected])
        let model = makeModel()
        XCTAssertTrue(model.begin(startingAtPath: nil))
        XCTAssertTrue(model.onlyUnflagged)
        XCTAssertEqual(model.session?.ids, [3, 4])
        XCTAssertEqual(model.counts, CullSession.Counts(picked: 0, rejected: 0, unflagged: 2), "counts are over THIS pass's list")
        model.end()
    }

    func testAllFlaggedStartsWithEverythingAndTheStartPathIsHonoured() throws {
        try addPhotos(3, flags: [1: .picked, 2: .picked, 3: .rejected])
        let model = makeModel()
        XCTAssertTrue(model.begin(startingAtPath: rows[2]!.path))
        XCTAssertFalse(model.onlyUnflagged)
        XCTAssertEqual(model.session?.currentID, 2)
        model.end()
    }

    func testEndReturnsTheCurrentPhotoAndDeactivates() async throws {
        try addPhotos(3)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        model.handle(.next)
        XCTAssertEqual(model.end()?.id, 2)
        XCTAssertFalse(model.isActive)
        XCTAssertNil(model.image)
        XCTAssertEqual(model.handle(.next), .done, "keys do nothing once the pass is over")
    }

    // MARK: Keys

    func testNavigationAndTheEndOfListNote() async throws {
        try addPhotos(2)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        model.handle(.next)
        XCTAssertEqual(model.session?.currentID, 2)
        model.handle(.next)
        XCTAssertEqual(model.note, "End of list")
        model.handle(.previous)
        XCTAssertEqual(model.session?.currentID, 1)
        model.end()
    }

    func testExitAndOpenInEditorAreReportedNotPerformed() throws {
        try addPhotos(2)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        XCTAssertEqual(model.handle(.exit), .exit)
        XCTAssertEqual(model.handle(.openInEditor), .openInEditor(rows[1]!))
        XCTAssertTrue(model.isActive, "the view decides what to do")
        model.end()
    }

    func testAFlagKeyWritesAdvancesAndUpdatesTheCounts() async throws {
        try addPhotos(3)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await settle(model)
        model.handle(.command(.flag(.picked)))
        XCTAssertEqual(writes, ["flag 1=picked"])
        XCTAssertEqual(model.session?.currentID, 2, "advanced")
        XCTAssertEqual(model.counts.picked, 1)
        XCTAssertEqual(model.note, "Picked")
        model.end()
    }

    func testRatingAndLabelStayOnThePhoto() async throws {
        try addPhotos(2)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await settle(model)
        model.handle(.command(.rating(4)))
        model.handle(.command(.label(.red)))
        XCTAssertEqual(writes, ["rating 1=4", "label 1=red"])
        XCTAssertEqual(model.session?.currentID, 1)
        model.end()
    }

    func testFlaggingTheLastPhotoSaysEndOfList() async throws {
        try addPhotos(1)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await settle(model)
        model.handle(.command(.flag(.rejected)))
        XCTAssertTrue(model.endReached)
        XCTAssertEqual(model.note, "End of list")
        model.end()
    }

    func testAdvanceCanBeSwitchedOff() async throws {
        try addPhotos(3)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await settle(model)
        model.autoAdvance = false
        model.handle(.command(.flag(.picked)))
        XCTAssertEqual(model.session?.currentID, 1)
        model.end()
    }

    // MARK: Undo

    func testUndoPutsTheValuesBackAndReturnsToThePhoto() async throws {
        try addPhotos(3)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await settle(model)
        model.handle(.command(.rating(2)))
        model.handle(.command(.flag(.picked)))      // advances to 2
        XCTAssertTrue(model.canUndo)
        model.undo()
        await settle(model)
        XCTAssertEqual(rows[1]?.flagStatus, FlagStatus.none)
        XCTAssertEqual(rows[1]?.rating, 2, "undoing the flag leaves the rating alone")
        XCTAssertEqual(model.session?.currentID, 1)
        model.undo()
        XCTAssertEqual(rows[1]?.rating, 0)
        XCTAssertFalse(model.canUndo)
        model.end()
    }

    // MARK: Unflagged toggle

    func testTheUnflaggedToggleRebuildsTheList() async throws {
        try addPhotos(3)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await settle(model)
        model.autoAdvance = false
        model.handle(.command(.flag(.picked)))           // photo 1 now picked, still current
        model.setOnlyUnflagged(false)
        XCTAssertEqual(model.session?.ids, [1, 2, 3])
        XCTAssertEqual(model.session?.currentID, 1)
        model.setOnlyUnflagged(true)
        XCTAssertEqual(model.session?.ids, [2, 3])
        XCTAssertEqual(model.session?.currentID, 2, "the current photo left the list: start at the first")
        model.end()
    }

    // MARK: Loading

    func testThePreviewLoadsAndMovingOnShowsTheNextPhotoNotTheOldOne() async throws {
        try addPhotos(3)
        let model = makeModel()
        model.setViewSize(longEdge: 600, scale: 1)
        model.begin(startingAtPath: nil)
        await waitForImage(model)
        XCTAssertEqual(model.imagePhotoID, 1)
        let first = model.image
        model.handle(.next)
        XCTAssertFalse(model.showsCurrentPhoto, "right after the key the old picture is stale")
        await waitForImage(model)
        XCTAssertEqual(model.imagePhotoID, 2)
        XCTAssertFalse(model.image === first, "a different picture was loaded")
        XCTAssertFalse(model.decodeFailed)
        model.end()
    }

    /// The reviewer's blocker: while the next photo is still loading, the old picture is on screen, so a key must NOT change the new
    /// (hidden) current photo.
    func testPhotoKeysAreRefusedWhileTheNextPhotoIsStillLoading() async throws {
        try addPhotos(3)
        slowThumbnail = 400_000_000
        let model = makeModel()
        model.setViewSize(longEdge: 600, scale: 1)
        model.begin(startingAtPath: nil)
        await waitForImage(model)                   // photo 1 shown (slow thumbnail, then the real preview)
        model.handle(.next)                         // photo 2 starts loading slowly
        XCTAssertFalse(model.showsCurrentPhoto)
        model.handle(.command(.flag(.picked)))
        model.handle(.command(.rating(5)))
        XCTAssertTrue(writes.isEmpty, "nothing may be written while the picture on screen is not the current photo")
        XCTAssertEqual(model.session?.currentID, 2, "and the session did not advance")
        await waitForImage(model)
        model.handle(.command(.flag(.picked)))
        XCTAssertEqual(writes, ["flag 2=picked"], "once photo 2 is on screen the key lands on photo 2")
        model.end()
    }

    func testABrokenPhotoCanStillBeRejected() async throws {
        try addPhotos(2)
        try FileManager.default.removeItem(atPath: rows[1]!.path)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        for _ in 0..<400 where !model.decodeFailed { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.canActOnCurrent)
        model.handle(.command(.flag(.rejected)))
        XCTAssertEqual(writes, ["flag 1=rejected"])
        model.end()
    }

    func testTheStartSkipsAFlaggedFocusToTheNextUnflaggedPhoto() throws {
        try addPhotos(4, flags: [2: .picked])
        let model = makeModel()
        XCTAssertTrue(model.begin(startingAtPath: rows[2]!.path))
        XCTAssertEqual(model.session?.currentID, 3, "focused photo 2 is flagged: start at the next unflagged one")
        model.end()
    }

    func testUndoOfARemovedPhotoSaysSo() async throws {
        try addPhotos(2)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await settle(model)
        model.handle(.command(.rating(3)))
        rows[1] = nil
        model.undo()
        XCTAssertEqual(model.note, "Can't undo — that photo was removed")
        model.end()
    }

    func testAMissingFileShowsFailureWithoutBlockingNavigation() async throws {
        try addPhotos(2)
        try FileManager.default.removeItem(atPath: rows[1]!.path)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        for _ in 0..<400 where !model.decodeFailed { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.decodeFailed)
        model.handle(.next)
        await waitForImage(model)
        XCTAssertFalse(model.decodeFailed, "the next photo is fine")
        model.end()
    }

    /// Round-2 blocker: the broken-photo exception must not outlive the broken photo. After moving off it, a key must not reach the next
    /// (still loading) photo.
    func testTheBrokenPhotoExceptionDoesNotLeakToTheNextPhoto() async throws {
        try addPhotos(2)
        try FileManager.default.removeItem(atPath: rows[1]!.path)
        slowThumbnail = 400_000_000
        let model = makeModel()
        model.begin(startingAtPath: nil)
        for _ in 0..<600 where !model.decodeFailed { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.decodeFailed)
        model.handle(.next)
        XCTAssertFalse(model.decodeFailed, "the failure belongs to photo 1 only")
        XCTAssertFalse(model.canActOnCurrent)
        model.handle(.command(.flag(.rejected)))
        XCTAssertTrue(writes.isEmpty, "nothing may be written for photo 2 before it is on screen")
        model.end()
    }
}

