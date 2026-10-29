import ImageIO
import XCTest
@testable import PhotoApp

/// Grants a fixed folder (the tests' own temp folder, which has no real security scope: pair with `startAccess: { _ in true }`).
@MainActor
private final class GrantingAccess: SidecarFolderAccessing {
    let folder: URL
    init(_ folder: URL) { self.folder = folder }
    func resolvedURL(for folder: URL) -> URL? { self.folder }
    func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .granted(self.folder) }
}

/// Hands out a scripted list of results, one per call (the last repeats).
private final class ScriptedResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [MergeModel.OrientationCheck]
    private(set) var calls = 0
    init(_ results: [MergeModel.OrientationCheck]) { self.results = results }
    func next() -> MergeModel.OrientationCheck {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return results.count > 1 ? results.removeFirst() : results[0]
    }
}

/// Folder access that always declines, so no test can open a real file panel (a hung modal panel stalled the suite once).
@MainActor
private final class DecliningAccess: SidecarFolderAccessing {
    private(set) var requests = 0
    func resolvedURL(for folder: URL) -> URL? { nil }
    func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { requests += 1; return .declined }
}

@MainActor
final class MergeModelTests: XCTestCase {
    private var catalog: CatalogModel!
    private var access: DecliningAccess!
    private var model: MergeModel!

    override func setUp() async throws {
        catalog = CatalogModel(database: try CatalogDatabase(inMemory: true), defaults: UserDefaults(suiteName: "MergeModelTests-\(UUID().uuidString)")!)
        access = DecliningAccess()
        model = MergeModel(folderAccess: access)
    }

    private func photo(_ name: String, id: Int64) -> Photo {
        Photo(id: id, path: "/tmp/does-not-exist/\(name)", filename: name, fileSize: nil, importedAt: Date())
    }

    // MARK: Request guards

    func testRequestNeedsTwoToNinePhotosAndExplainsWhy() {
        model.request(.hdr, photos: [photo("a.jpg", id: 1)], catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.statusMessage, MergeModel.selectionProblem(.hdr, count: 1))
        XCTAssertFalse(catalog.mergeBusy)

        model.statusMessage = nil
        model.request(.hdr, photos: (1...10).map { photo("p\($0).jpg", id: Int64($0)) }, catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertTrue(model.statusMessage?.contains("at most 9") ?? false)
    }

    func testAValidRequestOpensTheConfirmationAndMarksTheCatalogBusyUntilCancelled() {
        model.request(.hdr, photos: [photo("a.jpg", id: 1), photo("b.jpg", id: 2)], catalog: catalog)
        XCTAssertEqual(model.pending?.photos.count, 2)
        XCTAssertTrue(catalog.mergeBusy, "other sheets and menu items must see the pending merge")
        XCTAssertTrue(catalog.toolSheetIsBusy, "batch rename must not start under a pending merge")
        model.cancel()
        XCTAssertNil(model.pending)
        XCTAssertFalse(catalog.mergeBusy)
        XCTAssertFalse(catalog.toolSheetIsBusy)
    }

    func testPanoramaRequestsFollowTheirOwnLimitsAndText() {
        model.request(.panorama, photos: [photo("a.jpg", id: 1)], catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.statusMessage, "Select at least two overlapping photos to make a panorama.")
        model.statusMessage = nil
        model.request(.panorama, photos: (1...13).map { photo("p\($0).jpg", id: Int64($0)) }, catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertTrue(model.statusMessage?.contains("at most 12") ?? false)
        model.statusMessage = nil
        // Ten photos are fine for a panorama but too many for an HDR bracket.
        let ten = (1...10).map { photo("p\($0).jpg", id: Int64($0)) }
        XCTAssertNil(MergeModel.selectionProblem(.panorama, count: 10))
        XCTAssertNotNil(MergeModel.selectionProblem(.hdr, count: 10))
        model.request(.panorama, photos: ten, catalog: catalog)
        XCTAssertEqual(model.pending?.kind, .panorama)
        let request = try! XCTUnwrap(model.pending)
        XCTAssertEqual(MergeModel.confirmationTitle(request), "Stitch 10 photos into a panorama?")
        let message = MergeModel.confirmationMessage(.init(kind: .panorama, photos: ten, estimatedBytes: 1_000_000))
        XCTAssertTrue(message.contains("overlap by about half"))
        XCTAssertTrue(message.contains("order they were taken"))
        XCTAssertTrue(message.contains("roughly") && !message.contains("up to"), "an estimate, not a bound: a diagonal sweep can exceed it")
        XCTAssertTrue(message.contains("5.5 MB") || message.contains("6 MB") || message.contains("5,5 MB"), "about (10 + 1) / 2 frames of 1 MB: \(message)")
        XCTAssertFalse(message.contains("Tripod"), "tripod is an HDR concept")
    }

    func testPanoramaSummaryReportsSizeCroppingAndAWeakJoin() {
        let url = URL(fileURLWithPath: "/tmp/a-Pano.tiff")
        var outcome = MergeOutcome(url: url, frameCount: 3, referenceName: "b.jpg",
                                   alignment: [.init(name: "b.jpg", inlierCount: 90, matchCount: 100), .init(name: "c.jpg", inlierCount: 14, matchCount: 50)])
        outcome.mode = .panorama
        outcome.size = CGSize(width: 5200, height: 3100)
        outcome.cropped = true
        let text = MergeModel.summary(outcome)
        XCTAssertTrue(text.hasPrefix("Created “a-Pano.tiff” (5200 × 3100) from 3 photos, edges cropped."))
        XCTAssertTrue(text.contains("The join at “c.jpg” was uncertain"))
        outcome.cropped = false
        XCTAssertTrue(MergeModel.summary(outcome).contains("edges kept."))
    }

    func testASecondRequestWhileOneIsPendingIsIgnored() {
        model.request(.hdr, photos: [photo("a.jpg", id: 1), photo("b.jpg", id: 2)], catalog: catalog)
        let first = model.pending
        model.request(.hdr, photos: [photo("c.jpg", id: 3), photo("d.jpg", id: 4), photo("e.jpg", id: 5)], catalog: catalog)
        XCTAssertEqual(model.pending, first)
    }

    func testRequestIsRefusedWhileARenameRuns() {
        catalog.isRenameInProgress = true
        model.request(.hdr, photos: [photo("a.jpg", id: 1), photo("b.jpg", id: 2)], catalog: catalog)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.statusMessage, CatalogModel.renameInProgressMessage)
    }

    /// The dialog's button hands `confirm` the request it was presented with; `pending` may already be nil by then. The merge must still start
    /// (it fails fast here on the unreadable fake paths, which is fine — what matters is that it was NOT silently dropped).
    func testConfirmRunsTheRequestItIsGivenEvenWhenPendingWasAlreadyCleared() async throws {
        let request = MergeModel.Request(kind: .hdr, photos: [photo("a.jpg", id: 1), photo("b.jpg", id: 2)], estimatedBytes: nil)
        XCTAssertNil(model.pending)
        model.confirm(request, option: .hdr(align: true), catalog: catalog)
        XCTAssertTrue(model.isMerging, "confirm must start the merge from the request it was handed")
        XCTAssertTrue(catalog.mergeBusy)
        for _ in 0..<500 where model.isMerging { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isMerging, "isMerging is released on every exit path")
        XCTAssertEqual(access.requests, 1, "the merge reached the folder-access step with the request it was handed")
        XCTAssertFalse(catalog.mergeBusy)
    }

    func testConfirmIsIgnoredWhileAMergeIsAlreadyRunning() async throws {
        let request = MergeModel.Request(kind: .hdr, photos: [photo("a.jpg", id: 1), photo("b.jpg", id: 2)], estimatedBytes: nil)
        model.confirm(request, option: .hdr(align: true), catalog: catalog)
        XCTAssertTrue(model.isMerging)
        model.confirm(request, option: .hdr(align: false), catalog: catalog) // a double click must not start a second merge
        for _ in 0..<500 where model.isMerging { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isMerging)
        XCTAssertEqual(access.requests, 1, "only ONE merge started")
    }

    /// Batch rename must refuse while a merge is pending or running — checked at the point rename/undo re-check (`RenameBusyState`).
    func testRenameBusyStateRefusesDuringAMerge() {
        XCTAssertNotNil(RenameBusyState(isMerging: true).reason)
        XCTAssertTrue(RenameBusyState(isMerging: true).reason?.contains("Merge") ?? false)
        XCTAssertNil(RenameBusyState(isMerging: false).reason)
    }

    // MARK: Orientation (turn / flip edits)

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mergemodel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A small landscape JPEG with a gradient and an exposure time, so an HDR plan accepts it.
    private func writeJPEG(_ name: String, in dir: URL, exposureTime: Double, brightness: Double) throws -> URL {
        let w = 64, h = 48
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let v = UInt8(min(255, max(0, (Double(x + y) / Double(w + h)) * 255 * brightness)))
            for c in 0..<3 { rgba[(y * w + x) * 4 + c] = v }
        } }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(rgba) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: exposureTime, kCGImagePropertyExifFNumber: 8.0,
                                                                                 kCGImagePropertyExifISOSpeedRatings: [100]]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func writeEdit(turns: Int = 0, flipH: Bool = false, flipV: Bool = false, for url: URL) throws {
        var state = EditState.identity
        state.rotationQuarterTurns = turns
        state.flipHorizontal = flipH
        state.flipVertical = flipV
        state.exposureEV = 1.5 // another edit: must be ignored by the merge
        try SidecarStore.write(state, forPhotoAt: url)
    }

    func testNoEditFilesMeanNoOrientation() throws {
        let dir = try makeTempDir()
        let urls = ["a.jpg", "b.jpg"].map { dir.appendingPathComponent($0) }
        XCTAssertEqual(MergeModel.resolveOrientations(for: urls), .ok([.identity, .identity]))
    }

    func testEachPhotosTurnAndFlipsAreReadAndOtherEditsIgnored() throws {
        let dir = try makeTempDir()
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.jpg")
        try writeEdit(turns: 1, flipH: true, for: a)
        try writeEdit(turns: 1, flipH: true, for: b)
        XCTAssertEqual(MergeModel.resolveOrientations(for: [a, b]),
                       .ok([PhotoOrientation(quarterTurns: 1, flipHorizontal: true), PhotoOrientation(quarterTurns: 1, flipHorizontal: true)]))
    }

    func testAnUnreadableEditFileIsRefusedNamingThePhoto() throws {
        let dir = try makeTempDir()
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.jpg")
        try writeEdit(turns: 1, for: a)
        try Data("not json".utf8).write(to: SidecarStore.sidecarURL(for: b))
        XCTAssertEqual(MergeModel.resolveOrientations(for: [a, b]), .undecodable("b.jpg"))
    }

    func testPhotosTurnedOrFlippedDifferentlyAreRefusedNamingTheFirstOddOne() throws {
        let dir = try makeTempDir()
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.jpg"), c = dir.appendingPathComponent("c.jpg")
        try writeEdit(turns: 1, for: a)
        try writeEdit(turns: 1, for: b)
        try writeEdit(turns: 1, flipV: true, for: c)
        XCTAssertEqual(MergeModel.resolveOrientations(for: [a, b, c]), .mixed("c.jpg"))
        // an untouched photo among turned ones counts as different too
        XCTAssertEqual(MergeModel.resolveOrientations(for: [a, dir.appendingPathComponent("none.jpg")]), .mixed("none.jpg"))
    }

    func testTheRefusalTextsAreClear() {
        XCTAssertTrue(MergeModel.orientationProblemMessage(.mixed("c.jpg"))?.contains("“c.jpg” is rotated or flipped differently from the others") ?? false)
        XCTAssertTrue(MergeModel.orientationProblemMessage(.undecodable("b.jpg"))?.contains("b.jpg") ?? false)
        XCTAssertNil(MergeModel.orientationProblemMessage(.ok([])))
    }

    /// A refused orientation stops the merge BEFORE any folder prompt or write.
    func testConfirmRefusesMixedAndUndecodableEditsBeforeAskingForFolderAccess() async throws {
        let dir = try makeTempDir()
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.jpg")
        try writeEdit(turns: 1, for: a)
        let photos = [Photo(id: 1, path: a.path, filename: "a.jpg", fileSize: nil, importedAt: Date()), Photo(id: 2, path: b.path, filename: "b.jpg", fileSize: nil, importedAt: Date())]
        model.confirm(.init(kind: .hdr, photos: photos, estimatedBytes: nil), option: .hdr(align: true), catalog: catalog)
        for _ in 0..<500 where model.isMerging { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.statusMessage?.contains("rotated or flipped differently from the others") ?? false, "\(model.statusMessage ?? "nil")")
        XCTAssertEqual(access.requests, 0)

        try Data("junk".utf8).write(to: SidecarStore.sidecarURL(for: b))
        model.statusMessage = nil
        model.confirm(.init(kind: .panorama, photos: photos, estimatedBytes: nil), option: .panorama(crop: true), catalog: catalog)
        for _ in 0..<500 where model.isMerging { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.statusMessage?.contains("b.jpg") ?? false)
        XCTAssertEqual(access.requests, 0)
    }

    /// The whole path minus the folder prompt: real edit files in, a baked-in upright picture out — no Orientation tag, no edit file of its own.
    func testMergeOfTurnedPhotosWritesUprightPixelsWithNoOrientationTagAndNoSidecar() async throws {
        let dir = try makeTempDir()
        let urls = [try writeJPEG("bright.jpg", in: dir, exposureTime: 1.0 / 25, brightness: 1.0),
                    try writeJPEG("mid.jpg", in: dir, exposureTime: 1.0 / 100, brightness: 0.5),
                    try writeJPEG("dark.jpg", in: dir, exposureTime: 1.0 / 400, brightness: 0.25)]
        for url in urls { try writeEdit(turns: 1, for: url) }
        guard case .ok(let orientations) = MergeModel.resolveOrientations(for: urls) else { return XCTFail("orientations") }
        let outcome = try await MergeModel.performMerge(.hdr(align: false), urls: urls, orientations: orientations, into: dir)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, 48, "a landscape 64 x 48 photo turned once is 48 wide")
        XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, 64)
        XCTAssertEqual((props[kCGImagePropertyOrientation as String] as? Int) ?? 1, 1, "no turning Orientation tag: the turn is baked into the pixels")
        XCTAssertFalse(FileManager.default.fileExists(atPath: SidecarStore.sidecarURL(for: outcome.url).path), "the new file has no edit file of its own")
    }

    private func bracketPhotos(in dir: URL) throws -> [Photo] {
        let urls = [try writeJPEG("bright.jpg", in: dir, exposureTime: 1.0 / 25, brightness: 1.0),
                    try writeJPEG("mid.jpg", in: dir, exposureTime: 1.0 / 100, brightness: 0.5),
                    try writeJPEG("dark.jpg", in: dir, exposureTime: 1.0 / 400, brightness: 0.25)]
        return urls.enumerated().map { Photo(id: Int64($0.offset + 1), path: $0.element.path, filename: $0.element.lastPathComponent, fileSize: nil, importedAt: Date()) }
    }

    private func mergeNames(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tiff") }
    }

    private func runConfirm(_ model: MergeModel, photos: [Photo]) async throws {
        model.confirm(.init(kind: .hdr, photos: photos, estimatedBytes: nil), option: .hdr(align: false), catalog: catalog)
        for _ in 0..<1500 where model.isMerging { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isMerging)
    }

    /// The orientation read BEFORE the folder grant must be confirmed by a second read with the grant active; a difference merges nothing.
    func testAnOrientationThatDiffersAfterTheFolderGrantIsRefusedAndNothingIsMerged() async throws {
        let dir = try makeTempDir()
        let photos = try bracketPhotos(in: dir)
        let turned = PhotoOrientation(quarterTurns: 1)
        let resolver = ScriptedResolver([.ok([turned, turned, turned]), .ok([.identity, .identity, .identity])])
        let model = MergeModel(folderAccess: GrantingAccess(dir), orientationResolver: { _ in resolver.next() }, startAccess: { _ in true })
        try await runConfirm(model, photos: photos)
        XCTAssertEqual(resolver.calls, 2, "read at confirm time and again inside run")
        XCTAssertTrue(model.statusMessage?.contains("nothing was merged") ?? false, "\(model.statusMessage ?? "nil")")
        XCTAssertEqual(try mergeNames(dir), [], "nothing written")
    }

    func testAnUnreadableSecondReadIsRefusedWithItsOwnMessage() async throws {
        let dir = try makeTempDir()
        let photos = try bracketPhotos(in: dir)
        let resolver = ScriptedResolver([.ok([.identity, .identity, .identity]), .undecodable("mid.jpg")])
        let model = MergeModel(folderAccess: GrantingAccess(dir), orientationResolver: { _ in resolver.next() }, startAccess: { _ in true })
        try await runConfirm(model, photos: photos)
        XCTAssertTrue(model.statusMessage?.contains("mid.jpg") ?? false)
        XCTAssertEqual(try mergeNames(dir), [])
    }

    /// Two identical reads: the merge runs, and the confirmed orientations (not identity) are what reach the engine.
    func testConfirmedOrientationsReachTheEngineWhenTheSecondReadAgrees() async throws {
        let dir = try makeTempDir()
        let photos = try bracketPhotos(in: dir)
        let turned = PhotoOrientation(quarterTurns: 1)
        let resolver = ScriptedResolver([.ok([turned, turned, turned])])
        let model = MergeModel(folderAccess: GrantingAccess(dir), orientationResolver: { _ in resolver.next() }, startAccess: { _ in true })
        try await runConfirm(model, photos: photos)
        XCTAssertEqual(resolver.calls, 2)
        let out = try XCTUnwrap(try mergeNames(dir).first, "merged: \(model.statusMessage ?? "nil")")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(dir.appendingPathComponent(out) as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, 48, "the turned (portrait) shape reached the engine")
        XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, 64)
    }

    // MARK: Text

    func testTheConfirmationSaysEachPhotoIsUsedAsTurnedAndFlipped() {
        let sentence = "Each photo is used as turned and flipped in the Library; other edits are not applied."
        for kind in [MergeModel.Kind.hdr, .panorama] {
            let message = MergeModel.confirmationMessage(.init(kind: kind, photos: [photo("a.jpg", id: 1), photo("b.jpg", id: 2)], estimatedBytes: nil))
            XCTAssertTrue(message.contains(sentence), "\(kind): \(message)")
        }
    }

    func testConfirmationTextNamesTheCountTheFirstPhotoTheSizeAndTheTripodChoice() {
        let request = MergeModel.Request(kind: .hdr, photos: [photo("first.jpg", id: 1), photo("second.jpg", id: 2), photo("third.jpg", id: 3)], estimatedBytes: 192_000_000)
        XCTAssertEqual(MergeModel.confirmationTitle(request), "Merge 3 photos to HDR?")
        let message = MergeModel.confirmationMessage(request)
        XCTAssertTrue(message.contains("first.jpg"))
        XCTAssertTrue(message.contains("MB"), "a size estimate is shown")
        XCTAssertTrue(message.contains("not changed"))
        XCTAssertTrue(message.contains("Tripod"))
        let unknown = MergeModel.confirmationMessage(.init(kind: .hdr, photos: request.photos, estimatedBytes: nil))
        XCTAssertFalse(unknown.contains("roughly"))
    }

    func testSummaryReportsAlignmentAndWarnsAboutAWeakFrame() {
        let url = URL(fileURLWithPath: "/tmp/mid-HDR.tiff")
        let good = MergeOutcome(url: url, frameCount: 3, referenceName: "mid.jpg",
                                alignment: [.init(name: "a.jpg", inlierCount: 80, matchCount: 100), .init(name: "b.jpg", inlierCount: 60, matchCount: 100)])
        XCTAssertEqual(MergeModel.summary(good), "Created “mid-HDR.tiff” from 3 photos (exposure reference: mid.jpg), aligned.")
        let weak = MergeOutcome(url: url, frameCount: 3, referenceName: "mid.jpg",
                                alignment: [.init(name: "a.jpg", inlierCount: 80, matchCount: 100), .init(name: "b.jpg", inlierCount: 13, matchCount: 40)])
        XCTAssertTrue(MergeModel.summary(weak).contains("“b.jpg” was uncertain"))
        let corrected = MergeOutcome(url: url, frameCount: 2, referenceName: "mid.jpg", alignment: [],
                                    gains: [.init(name: "b.jpg", exifGain: 2.0, usedGain: 2.24)])
        XCTAssertTrue(MergeModel.summary(corrected).contains("“b.jpg” was measured 12% brighter than its camera data implied and was corrected"))
        let negligible = MergeOutcome(url: url, frameCount: 2, referenceName: "mid.jpg", alignment: [],
                                      gains: [.init(name: "b.jpg", exifGain: 2.0, usedGain: 2.05)])
        XCTAssertFalse(MergeModel.summary(negligible).contains("corrected"), "a 2.5% difference is not worth mentioning")
        let tripod = MergeOutcome(url: url, frameCount: 2, referenceName: "mid.jpg", alignment: [])
        XCTAssertTrue(MergeModel.summary(tripod).hasSuffix("without alignment."))
    }

    func testEstimatedBytesIsEightBytesPerPixelAndNilForAnUnreadableFile() throws {
        XCTAssertNil(MergeModel.estimatedOutputBytes(forFileAt: URL(fileURLWithPath: "/tmp/definitely-not-here.jpg")))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merge-est-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.png")
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 30))
        try PhotoExporter.write(image, format: .png, quality: 1, to: url)
        XCTAssertEqual(MergeModel.estimatedOutputBytes(forFileAt: url), 40 * 30 * 8)
    }

    // MARK: Selection used by the merge

    func testMergeActsOnlyOnSelectedPhotosTheGridActuallyShows() async throws {
        let db = try CatalogDatabase(inMemory: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merge-vis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.png", "b.png", "c.png"] {
            try PhotoExporter.write(CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)), format: .png, quality: 1, to: dir.appendingPathComponent(name))
        }
        _ = try await db.importPhotos(at: ["a.png", "b.png", "c.png"].map { dir.appendingPathComponent($0) })
        let model = CatalogModel(database: db, defaults: UserDefaults(suiteName: "MergeModelTests-\(UUID().uuidString)")!)
        await model.refresh()
        let mine = model.photos.filter { $0.path.hasPrefix(dir.path) }
        XCTAssertEqual(mine.count, 3)
        for p in mine { model.toggleSelection(of: p) }
        XCTAssertEqual(model.selectedPhotosInDisplayedGrid.count, 3)
        model.searchText = "a.png" // hides b and c from the grid; they stay selected
        XCTAssertEqual(model.selectedPhotos.count, 3, "selection itself is untouched by a filter")
        XCTAssertEqual(model.selectedPhotosInDisplayedGrid.map(\.filename), ["a.png"], "a merge must not silently include photos the grid hides")
    }
}

/// Pins the wiring that cannot be driven by clicks here: the menu items exist, are Library-only, and every other tool is blocked meanwhile.
final class MergeWiringTests: XCTestCase {
    private func text(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8).components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? "" }.joined(separator: "\n")
    }

    func testThePhotoMenuItemIsLibraryOnlyNeedsTwoVisiblePhotosAndRespectsBusyState() throws {
        let app = try text("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("Button(\"Merge Photos to HDR…\") { catalog.mergeRequested = .hdr }"))
        XCTAssertTrue(app.contains("Button(\"Merge Photos to Panorama…\") { catalog.mergeRequested = .panorama }"))
        XCTAssertEqual(app.components(separatedBy: "catalog.selectedPhotosInDisplayedGrid.count < 2 || catalog.mergeBusy").count - 1, 2, "both merge items need 2+ visible photos")
        XCTAssertTrue(app.contains("cull.isActive || !showLibrary || catalog.selectedPhotosInDisplayedGrid.count < 2 || catalog.mergeBusy"))
    }

    func testOtherToolsAreBlockedWhileAMergeIsPendingOrRunning() throws {
        let app = try text("Sources/App/PhotoAppApp.swift")
        XCTAssertTrue(app.contains("catalog.selectedPhotos.isEmpty || document.isLoadInFlight || catalog.mergeBusy"), "Paste Settings")
        XCTAssertTrue(app.contains("renameModel.isWorking || document.isLoadInFlight || catalog.mergeBusy"), "Rename Files")
        XCTAssertTrue(app.contains("renameModel.isPresentingSheet || catalog.mergeBusy"), "Undo Rename")
        let sheets = try text("Sources/UI/DuplicatesSheetView.swift")
        XCTAssertEqual(sheets.components(separatedBy: "catalog.mergeBusy").count - 1, 8, "keyword, info, duplicates, people and Auto Stack sheets block on a merge, and so do the XMP, Trash and Copy Photos dialogs")
        XCTAssertTrue(sheets.contains("MergeDialogModifier(") && sheets.contains("model: catalog.merge,"))
        let model = try text("Sources/UI/CatalogModel.swift")
        XCTAssertTrue(model.contains("faces.isWorking || mergeBusy"), "batch rename must not start under a merge")
    }

    func testTheSelectionMenuHasAMergeItemThatNeedsTwoVisiblePhotos() throws {
        let content = try text("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("catalog.mergeRequested = .hdr"))
        XCTAssertTrue(content.contains("catalog.mergeRequested = .panorama"))
        XCTAssertTrue(content.contains("Merge to Panorama (\\(catalog.selectedPhotosInDisplayedGrid.count))…"))
        XCTAssertTrue(content.contains("catalog.selectedPhotosInDisplayedGrid.count < 2 || otherSheetIsPresented || catalog.mergeBusy"),
                      "the enabled state uses the SAME set the merge acts on")
        XCTAssertTrue(content.contains("Merge to HDR (\\(catalog.selectedPhotosInDisplayedGrid.count))…"), "so does the label")
        XCTAssertTrue(content.contains("isMerging: catalog.mergeBusy"), "rename/undo re-check the merge flag")
        XCTAssertTrue(content.contains("|| document.isLoadInFlight || catalog.mergeBusy || catalog.fileToolBusy\n                        )"), "selection-menu Rename Files")
        XCTAssertTrue(content.contains("renameModel.isWorking || document.isLoadInFlight || catalog.mergeBusy || catalog.fileToolBusy)"), "selection-menu Undo Rename")
        XCTAssertTrue(content.contains("pasteModel.pendingTargets != nil || catalog.mergeBusy"), "otherSheetIsPresented includes a merge")
    }
}
