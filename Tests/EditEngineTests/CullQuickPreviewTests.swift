import CoreImage
import XCTest
@testable import PhotoApp

/// Cull's quick stand-in (the camera's embedded preview of an unedited RAW, shown as a placeholder until the real preview lands).
/// The repo has no RAW fixture, so a JPEG written under a `.nef` name stands in (`RawDecoder.isRaw` goes by extension).
@MainActor
final class CullQuickPreviewTests: XCTestCase {
    private var tempDir: URL!
    private var rows: [Int64: Photo] = [:]
    private var order: [Int64] = []
    private var writes: [String] = []

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CullQuickPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        rows = [:]; order = []; writes = []
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func writeJPEG(named name: String, size: Int = 800) throws -> URL {
        let image = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let url = tempDir.appendingPathComponent(name)
        try CIContext().writeJPEGRepresentation(of: image, to: url, colorSpace: CGColorSpaceCreateDeviceRGB())
        return url
    }

    private func photo(at url: URL) -> Photo {
        Photo(id: nil, path: url.path, filename: url.lastPathComponent, fileSize: nil, importedAt: Date())
    }

    private func addPhotos(_ n: Int) throws {
        for i in 1...n {
            let url = try writeJPEG(named: "p\(i).jpg")
            let id = Int64(i)
            rows[id] = Photo(id: id, path: url.path, filename: url.lastPathComponent, fileSize: nil, importedAt: Date(timeIntervalSince1970: 0),
                             rating: 0, flagStatus: .none, colorLabel: .none)
            order.append(id)
        }
    }

    private func marker(_ side: Int) -> CGImage {
        CIContext().createCGImage(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: side, height: side)), from: CGRect(x: 0, y: 0, width: side, height: side))!
    }

    private func makeModel(standIn: CGImage?, thumbnail: CGImage? = nil, slowThumbnail: UInt64 = 0) -> CullModel {
        let model = CullModel()
        model.configure(CullEnvironment(
            photos: { self.order.compactMap { self.rows[$0] } },
            rows: { self.rows },
            setRating: { value, photo in self.rows[photo.id!]?.rating = value; self.writes.append("rating \(photo.id!)=\(value)") },
            setFlag: { value, photo in self.rows[photo.id!]?.flagStatus = value; self.writes.append("flag \(photo.id!)=\(value)") },
            setLabel: { value, photo in self.rows[photo.id!]?.colorLabel = value; self.writes.append("label \(photo.id!)=\(value)") },
            thumbnail: { _ in
                if slowThumbnail > 0 { try? await Task.sleep(nanoseconds: slowThumbnail) }
                return thumbnail
            },
            quickPreview: { _, _ in standIn }))
        return model
    }

    // MARK: CullPreviewCache.quickPreview

    func testTheStandInIsOnlyForAnUneditedRawAndNeverLargerThanAsked() async throws {
        let raw = try writeJPEG(named: "a.nef")
        let jpg = try writeJPEG(named: "a.jpg")
        let standIn = await CullPreviewCache.quickPreview(for: photo(at: raw), pixelSize: 512)
        XCTAssertLessThanOrEqual(max(try XCTUnwrap(standIn).width, standIn!.height), 512)
        let none = await CullPreviewCache.quickPreview(for: photo(at: jpg), pixelSize: 512)
        XCTAssertNil(none, "a non-RAW photo is already fast")
    }

    func testAnEditedRawGetsNoStandIn() async throws {
        let raw = try writeJPEG(named: "b.nef")
        var state = EditState()
        state.exposureEV = 1
        try JSONEncoder().encode(state).write(to: ImageDocumentModel.sidecarURL(for: raw))
        let none = await CullPreviewCache.quickPreview(for: photo(at: raw), pixelSize: 512)
        XCTAssertNil(none, "cull shows edits, so an unedited stand-in would be the wrong picture")
    }

    func testAPinnedButUneditedRawStillGetsAStandIn() async throws {
        let raw = try writeJPEG(named: "c.nef")
        var state = EditState()
        state.rawDecoderVersionPin = "test-pin"
        try JSONEncoder().encode(state).write(to: ImageDocumentModel.sidecarURL(for: raw))
        let standIn = await CullPreviewCache.quickPreview(for: photo(at: raw), pixelSize: 512)
        XCTAssertNotNil(standIn)
    }

    // MARK: CullModel

    func testTheStandInShowsAsAPlaceholderForTheCurrentPhotoBeforeTheRealPreview() async throws {
        try addPhotos(2)
        let model = makeModel(standIn: marker(64), thumbnail: marker(16), slowThumbnail: 600_000_000)
        model.setViewSize(longEdge: 600, scale: 1)
        model.begin(startingAtPath: nil)
        for _ in 0..<200 where model.image == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(model.image?.width, 64, "the stand-in, not the 16 px thumbnail")
        XCTAssertTrue(model.isPlaceholder)
        XCTAssertTrue(model.showsCurrentPhoto, "it IS the current photo, so the key gate treats it as on screen")
        for _ in 0..<600 where model.isPlaceholder { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isPlaceholder, "the real preview replaced it")
        XCTAssertNotEqual(model.image?.width, 64)
        model.end()
    }

    /// The model with a stand-in/thumbnail that each take their own time, and a photo whose REAL decode fails (the file is gone), so the stand-in or the
    /// thumbnail is the only picture and the test can observe which one is on screen.
    private func makeModelWithDelays(standIn: CGImage?, standInDelay: UInt64, thumbnail: CGImage?, thumbnailDelay: UInt64) -> CullModel {
        let model = CullModel()
        model.configure(CullEnvironment(
            photos: { self.order.compactMap { self.rows[$0] } },
            rows: { self.rows },
            setRating: { value, photo in self.rows[photo.id!]?.rating = value; self.writes.append("rating \(photo.id!)=\(value)") },
            setFlag: { value, photo in self.rows[photo.id!]?.flagStatus = value; self.writes.append("flag \(photo.id!)=\(value)") },
            setLabel: { value, photo in self.rows[photo.id!]?.colorLabel = value; self.writes.append("label \(photo.id!)=\(value)") },
            thumbnail: { _ in
                if thumbnailDelay > 0 { try? await Task.sleep(nanoseconds: thumbnailDelay) }
                return thumbnail
            },
            quickPreview: { _, _ in
                if standInDelay > 0 { try? await Task.sleep(nanoseconds: standInDelay) }
                return standIn
            }))
        return model
    }

    private func settled(_ model: CullModel, timeout: Int = 600, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<timeout {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func testASlowThumbnailThatLandsAfterTheStandInNeverReplacesIt() async throws {
        try addPhotos(1)
        try FileManager.default.removeItem(atPath: rows[1]!.path) // the real decode fails: the stand-in is the only real picture
        let model = makeModelWithDelays(standIn: marker(64), standInDelay: 0, thumbnail: marker(16), thumbnailDelay: 400_000_000)
        model.setViewSize(longEdge: 600, scale: 1)
        model.begin(startingAtPath: nil)
        let landed = await settled(model) { model.cameraPreviewOnlyID == 1 }
        XCTAssertTrue(landed)
        XCTAssertEqual(model.image?.width, 64, "the 16 px thumbnail arrived after the stand-in and was dropped")
        model.end()
    }

    func testTheCachedThumbnailIsNotHeldUpByASlowStandIn() async throws {
        try addPhotos(1)
        try FileManager.default.removeItem(atPath: rows[1]!.path)
        let model = makeModelWithDelays(standIn: marker(64), standInDelay: 2_000_000_000, thumbnail: marker(16), thumbnailDelay: 0)
        model.setViewSize(longEdge: 600, scale: 1)
        model.begin(startingAtPath: nil)
        let thumbFirst = await settled(model, timeout: 150) { model.image?.width == 16 }
        XCTAssertTrue(thumbFirst, "the thumbnail shows at once, without waiting for the stand-in")
        XCTAssertTrue(model.isPlaceholder)
        let standInLater = await settled(model, timeout: 900) { model.image?.width == 64 }
        XCTAssertTrue(standInLater, "and the stand-in REPLACES it when it lands")
        model.end()
    }

    /// A stand-in that lands after the user has moved on must never be written: photo 1's stand-in is slow, the user presses next, and photo 2's
    /// (different-sized) stand-in is what stays on screen when photo 1's late one resolves.
    func testALateStandInForAPhotoTheUserLeftIsNeverWritten() async throws {
        try addPhotos(2)
        try FileManager.default.removeItem(atPath: rows[1]!.path)
        try FileManager.default.removeItem(atPath: rows[2]!.path)
        let slow = marker(64), fast = marker(32)
        var slowStarted = false
        let model = CullModel()
        model.configure(CullEnvironment(
            photos: { self.order.compactMap { self.rows[$0] } },
            rows: { self.rows },
            thumbnail: { _ in nil },
            quickPreview: { photo, _ in
                if photo.id == 1 { slowStarted = true; try? await Task.sleep(nanoseconds: 600_000_000); return slow }
                return fast
            }))
        model.setViewSize(longEdge: 600, scale: 1)
        model.begin(startingAtPath: nil)
        let started = await settled(model) { slowStarted }   // photo 1's stand-in must really be in flight, or this test proves nothing
        XCTAssertTrue(started)
        model.handle(.next)                         // photo 2 becomes current while photo 1's stand-in is still pending
        let two = await settled(model) { model.imagePhotoID == 2 && model.image?.width == 32 }
        XCTAssertTrue(two)
        try await Task.sleep(nanoseconds: 900_000_000)   // photo 1's stand-in resolves now
        XCTAssertEqual(model.imagePhotoID, 2)
        XCTAssertEqual(model.image?.width, 32, "the late stand-in of the photo the user left must not land")
        model.end()
    }

    func testALateStandInForASurveyCellOfAnOldLayoutIsNeverWritten() async throws {
        try addPhotos(3)
        for id in 1...3 { try FileManager.default.removeItem(atPath: rows[Int64(id)]!.path) }
        var surveyStarted = false
        let model = CullModel()
        model.configure(CullEnvironment(
            photos: { self.order.compactMap { self.rows[$0] } },
            rows: { self.rows },
            thumbnail: { _ in nil },
            quickPreview: { _, _ in
                surveyStarted = true
                try? await Task.sleep(nanoseconds: 500_000_000)
                return self.marker(48)
            }))
        model.setViewSize(longEdge: 600, scale: 1)
        model.begin(startingAtPath: nil)
        model.setMode(.survey)
        let started = await settled(model) { surveyStarted && model.slots.isEmpty }   // a survey cell's stand-in is really in flight
        XCTAssertTrue(started)
        model.setMode(.loupe)                        // the layout changes while the survey cells' stand-ins are pending
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertTrue(model.slots.isEmpty, "a stand-in from the survey layout must not write slots after the loupe is back")
        model.end()
    }

    func testAKeyActsOnTheRightPhotoWhileOnlyTheStandInIsUp() async throws {
        try addPhotos(3)
        try FileManager.default.removeItem(atPath: rows[2]!.path) // photo 2 never gets a real preview
        let model = makeModelWithDelays(standIn: marker(64), standInDelay: 0, thumbnail: nil, thumbnailDelay: 0)
        model.setViewSize(longEdge: 600, scale: 1)
        model.begin(startingAtPath: nil)
        let first = await settled(model) { model.showsCurrentPhoto && !model.isPlaceholder && model.image != nil }
        XCTAssertTrue(first)
        model.handle(.next)
        let up = await settled(model) { model.session?.currentID == 2 && model.cameraPreviewOnlyID == 2 && model.showsCurrentPhoto }
        XCTAssertTrue(up)
        XCTAssertEqual(model.image?.width, 64, "only the stand-in is on screen for photo 2")
        model.handle(.command(.flag(.picked)))
        XCTAssertEqual(writes, ["flag 2=picked"])
        model.end()
    }

    func testAFailedFullDecodeKeepsTheStandInStopsTheSpinnerAndSaysSo() async throws {
        try addPhotos(1)
        try FileManager.default.removeItem(atPath: rows[1]!.path)
        let model = makeModel(standIn: marker(64))
        model.setViewSize(longEdge: 600, scale: 1)
        model.begin(startingAtPath: nil)
        let done = await settled(model) { model.cameraPreviewOnlyID == 1 }
        XCTAssertTrue(done)
        XCTAssertEqual(model.image?.width, 64)
        XCTAssertFalse(model.isPlaceholder, "nothing more is coming: no endless spinner")
        XCTAssertFalse(model.decodeFailed)
        model.handle(.command(.flag(.rejected)))
        XCTAssertEqual(writes, ["flag 1=rejected"])
        model.end()
    }

    func testWithoutAStandInAFailedDecodeIsStillAFailureNotACameraPreview() async throws {
        try addPhotos(1)
        try FileManager.default.removeItem(atPath: rows[1]!.path)
        let model = makeModel(standIn: nil)
        model.setViewSize(longEdge: 600, scale: 1)
        model.begin(startingAtPath: nil)
        let failed = await settled(model) { model.decodeFailed }
        XCTAssertTrue(failed)
        XCTAssertNil(model.cameraPreviewOnlyID)
        model.end()
    }

    func testSurveyCellsGetTheStandInAndAFailedCellKeepsItWithoutASpinner() async throws {
        try addPhotos(3)
        try FileManager.default.removeItem(atPath: rows[2]!.path)
        let model = makeModel(standIn: marker(64), thumbnail: marker(16))
        model.setViewSize(longEdge: 600, scale: 1)
        model.begin(startingAtPath: nil)
        model.setMode(.survey)
        let ok = await settled(model) { model.slots.count >= 2 && model.slots.values.allSatisfy { !$0.isPlaceholder } }
        XCTAssertTrue(ok)
        XCTAssertEqual(model.slots[2]?.image?.width, 64, "the cell whose real preview failed keeps the stand-in, not the 16 px thumbnail")
        XCTAssertEqual(model.slots[2]?.cameraPreviewOnly, true)
        XCTAssertEqual(model.slots[2]?.failed, false)
        XCTAssertEqual(model.slots[1]?.cameraPreviewOnly, false, "a cell with a real preview is the real thing")
        model.end()
    }

    func testWithoutAStandInNothingChanges() async throws {
        try addPhotos(1)
        let model = makeModel(standIn: nil, thumbnail: marker(16))
        model.setViewSize(longEdge: 600, scale: 1)
        model.begin(startingAtPath: nil)
        for _ in 0..<600 where model.isPlaceholder || model.image == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isPlaceholder)
        XCTAssertNotNil(model.image)
        model.end()
    }

    // MARK: Wiring

    func testTheFilmstripAndTheCullWiringAreInPlace() throws {
        func text(_ relative: String) throws -> String {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }
        XCTAssertTrue(try text("Sources/UI/EditorFilmstripView.swift").contains("if image == nil, let quick = await catalog.quickThumbnailPreview(for: photo), !Task.isCancelled, image == nil"))
        let content = try text("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("guard catalog.preferences.quickRawPreviews else { return nil }"))
        XCTAssertTrue(content.contains("CullPreviewCache.quickPreview(for: photo, pixelSize: size)"))
    }
}
