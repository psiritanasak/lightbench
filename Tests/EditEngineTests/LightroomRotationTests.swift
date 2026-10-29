import CoreImage
import ImageIO
import XCTest
@testable import PhotoApp

/// Lightroom `tiff:Orientation` -> the rotation edit: the pure plan / merge / changes, then the whole import through
/// `LightroomImportModel` on a real loaded photo.
@MainActor
final class LightroomRotationTests: XCTestCase {
    private final class DeclineAccess: SidecarFolderAccessing {
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .declined }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LightroomRotationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func settings(orientation: Int?, extra: [String: String] = [:]) -> AdobeCameraRawSettings {
        AdobeCameraRawSettings(scalars: ["Exposure2012": "0.5"].merging(extra) { $1 }, tiffOrientation: orientation)
    }

    // MARK: - Plan

    func testPacketOrientationRelativeToThePhotoSetsTheTurns() {
        XCTAssertEqual(LightroomMapping.plan(from: settings(orientation: 8), photoOrientation: 1).rotationQuarterTurns, 3)
        XCTAssertEqual(LightroomMapping.plan(from: settings(orientation: 6), photoOrientation: 1).rotationQuarterTurns, 1)
        XCTAssertEqual(LightroomMapping.plan(from: settings(orientation: 3), photoOrientation: 1).rotationQuarterTurns, 2)
        XCTAssertEqual(LightroomMapping.plan(from: settings(orientation: 8), photoOrientation: 6).rotationQuarterTurns, 2)
        XCTAssertTrue(LightroomMapping.plan(from: settings(orientation: 8), photoOrientation: 1).mapped.contains("Orientation"))
    }

    func testAgreeingMissingOrUnknownOrientationsAskForNoRotation() {
        XCTAssertNil(LightroomMapping.plan(from: settings(orientation: 8), photoOrientation: 8).rotationQuarterTurns)
        XCTAssertNil(LightroomMapping.plan(from: settings(orientation: 1), photoOrientation: 1).rotationQuarterTurns)
        XCTAssertNil(LightroomMapping.plan(from: settings(orientation: nil), photoOrientation: 1).rotationQuarterTurns)
        XCTAssertNil(LightroomMapping.plan(from: settings(orientation: 8)).rotationQuarterTurns, "photo orientation unreadable")
        XCTAssertFalse(LightroomMapping.plan(from: settings(orientation: 8), photoOrientation: 8).mapped.contains("Orientation"))
    }

    func testMirroredOrientationsAreNotImportedAndAreNamed() {
        for mirrored in [2, 4, 5, 7] {
            let plan = LightroomMapping.plan(from: settings(orientation: mirrored), photoOrientation: 1)
            XCTAssertNil(plan.rotationQuarterTurns, "packet \(mirrored)")
            XCTAssertTrue(plan.ignored.contains("Orientation (mirrored)"), "packet \(mirrored)")
        }
        let photoMirrored = LightroomMapping.plan(from: settings(orientation: 1), photoOrientation: 5)
        XCTAssertNil(photoMirrored.rotationQuarterTurns)
        XCTAssertTrue(photoMirrored.ignored.contains("Orientation (mirrored)"))
        XCTAssertFalse(LightroomMapping.plan(from: settings(orientation: 5), photoOrientation: 5).ignored.contains("Orientation (mirrored)"),
                       "identical values need nothing")
    }

    func testCropIsRefusedWhenTheImportRotates() {
        let crop = ["HasCrop": "True", "CropLeft": "0.1"]
        let plan = LightroomMapping.plan(from: settings(orientation: 8, extra: crop), includeCrop: true, cropAllowed: true, photoOrientation: 1)
        XCTAssertNotNil(plan.cropRefusal)
        XCTAssertTrue(plan.cropRefusal?.contains("rotates") == true)
        XCTAssertFalse(plan.includesCrop)
        XCTAssertEqual(plan.rotationQuarterTurns, 3, "the rest still imports")
    }

    // MARK: - Merge and changes

    func testMergeSetsTheTurnsAndMovesTheExistingCropWithThePicture() {
        var target = EditState.identity
        target.cropInsetTop = 0.2
        let plan = LightroomMapping.plan(from: settings(orientation: 6), photoOrientation: 1)
        let merged = LightroomMapping.merge(plan, onto: target)
        XCTAssertEqual(merged.rotationQuarterTurns, 1)
        XCTAssertEqual(merged.cropInsetRight, 0.2)
        XCTAssertEqual(merged.cropInsetTop, 0)
        XCTAssertEqual(merged.exposureEV, 0.5)
    }

    /// The import's rotation moves existing masks and red-eye points with the picture, by the SCREEN turn (one flip on:
    /// the stored count the file asks for is a screen turn the other way).
    func testMergeTurnsExistingMasksAndRedEyeWithThePicture() {
        var target = EditState.identity
        target.masks = [Mask(kind: .radial, centerX: 0.25, centerY: 0.3, radiusX: 0.2, radiusY: 0.35)]
        target.redEyePoints = [RedEyePoint(x: 0.2, y: 0.7)]
        let plan = LightroomMapping.plan(from: settings(orientation: 6), photoOrientation: 1)
        let merged = LightroomMapping.merge(plan, onto: target)
        XCTAssertEqual(merged.masks[0], target.masks[0].rotatedOnScreen(byQuarterTurns: 1))
        XCTAssertEqual(merged.redEyePoints[0], target.redEyePoints[0].rotatedOnScreen(byQuarterTurns: 1))
        target.flipHorizontal = true
        let flipped = LightroomMapping.merge(plan, onto: target)
        XCTAssertEqual(flipped.rotationQuarterTurns, 1)
        XCTAssertEqual(flipped.masks[0], target.masks[0].rotatedOnScreen(byQuarterTurns: 3), "one flip: stored +1 is a screen turn left")
        XCTAssertEqual(LightroomMapping.merge(plan, onto: merged).masks, merged.masks, "idempotent: a second merge turns nothing")
    }

    func testAnAgreeingFileNeverResetsAHandMadeRotation() {
        var target = EditState.identity
        target.rotationQuarterTurns = 2
        let plan = LightroomMapping.plan(from: settings(orientation: 1), photoOrientation: 1)
        XCTAssertEqual(LightroomMapping.merge(plan, onto: target).rotationQuarterTurns, 2)
    }

    func testMergeIsIdempotentForTheSameFile() {
        let plan = LightroomMapping.plan(from: settings(orientation: 8), photoOrientation: 1)
        let once = LightroomMapping.merge(plan, onto: .identity)
        XCTAssertEqual(LightroomMapping.merge(plan, onto: once), once)
    }

    func testChangesReportTheRotationOnlyWhenItDiffers() {
        let plan = LightroomMapping.plan(from: settings(orientation: 8), photoOrientation: 1)
        XCTAssertEqual(LightroomMapping.changes(of: plan, onto: .identity).rotationScreenTurns, 3)
        var already = EditState.identity
        already.rotationQuarterTurns = 3
        XCTAssertNil(LightroomMapping.changes(of: plan, onto: already).rotationScreenTurns)
        let onlyRotation = LightroomMapping.plan(from: AdobeCameraRawSettings(scalars: [:], tiffOrientation: 6), photoOrientation: 1)
        XCTAssertFalse(LightroomMapping.changes(of: onlyRotation, onto: .identity).isEmpty, "a rotation alone is a change")
    }

    // MARK: - On-screen wording (relative to the current edit)

    /// Case A: the edit already has a hand rotation of 1; the file asks for 3, so the picture turns 180 degrees on screen.
    func testWordingCaseAExistingRotationMakesAHalfTurn() {
        let plan = LightroomMapping.plan(from: settings(orientation: 8), photoOrientation: 1)
        var target = EditState.identity
        target.rotationQuarterTurns = 1
        XCTAssertEqual(LightroomMapping.changes(of: plan, onto: target).rotationScreenTurns, 2)
        XCTAssertEqual(LightroomMapping.merge(plan, onto: target).rotationQuarterTurns, 3)
    }

    /// Case B: with exactly one flip on, stored 0 -> 3 is a clockwise turn on screen.
    func testWordingCaseBOneFlipInvertsTheScreenDirection() {
        let plan = LightroomMapping.plan(from: settings(orientation: 8), photoOrientation: 1)
        for flip in [(true, false), (false, true)] {
            var target = EditState.identity
            target.flipHorizontal = flip.0
            target.flipVertical = flip.1
            XCTAssertEqual(LightroomMapping.changes(of: plan, onto: target).rotationScreenTurns, 1)
        }
        var both = EditState.identity
        both.flipHorizontal = true
        both.flipVertical = true
        XCTAssertEqual(LightroomMapping.changes(of: plan, onto: both).rotationScreenTurns, 3)
    }

    func testScreenTurnsMatchWhatMergeDoesToTheCrop() {
        let plan = LightroomMapping.plan(from: settings(orientation: 8), photoOrientation: 1)
        var target = EditState.identity
        target.flipHorizontal = true
        target.cropInsetTop = 0.2
        let screen = LightroomMapping.changes(of: plan, onto: target).rotationScreenTurns ?? 0
        let merged = LightroomMapping.merge(plan, onto: target)
        var expected = target.rotated(byQuarterTurns: screen)
        expected.exposureEV = 0.5   // the other setting the file carries
        XCTAssertEqual(merged, expected)
    }

    /// Case C: the edit already has the file's rotation: nothing to promise.
    func testWordingCaseCAlreadyRotatedPromisesNothing() async throws {
        let (doc, model) = try await openPhoto(xmpText: xmp)
        doc.editState.rotationQuarterTurns = 3
        try await Task.sleep(nanoseconds: 600_000_000)
        model.request(for: doc)
        let request = try XCTUnwrap(model.pending)
        XCTAssertNotNil(request.rotationQuarterTurns)
        XCTAssertNil(request.rotationScreenTurns)
        XCTAssertFalse(LightroomImportModel.confirmationMessage(request).contains("turns the picture"))
        XCTAssertFalse(LightroomImportModel.confirmationMessage(request).contains("Geometry, masks"))
    }

    func testAnUnreadablePhotoOrientationIsNamedWhenThePacketAsksForOne() {
        XCTAssertTrue(LightroomMapping.plan(from: settings(orientation: 8)).ignored.contains("Orientation (photo's unreadable)"))
        XCTAssertFalse(LightroomMapping.plan(from: settings(orientation: 1)).ignored.contains("Orientation (photo's unreadable)"))
        XCTAssertFalse(LightroomMapping.plan(from: settings(orientation: 8), photoOrientation: 1).ignored.contains("Orientation (photo's unreadable)"))
    }

    // MARK: - Whole import

    private let xmp = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
     <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
       tiff:Orientation="8" crs:Exposure2012="+0.65" crs:HasCrop="True" crs:CropLeft="0.1" crs:CropRight="0.9" crs:CropTop="0" crs:CropBottom="1"/>
    </rdf:RDF></x:xmpmeta>
    """

    private func openPhoto(xmpText: String) async throws -> (ImageDocumentModel, LightroomImportModel) {
        let url = dir.appendingPathComponent("photo.png")
        let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        try CIContext().writePNGRepresentation(of: base, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        try Data(xmpText.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let doc = ImageDocumentModel(folderAccess: DeclineAccess())
        await doc.load(from: url)
        let model = LightroomImportModel(folderAccess: DeclineAccess(), chooseFile: { _ in nil },
                                         reader: { LightroomImportModel.readOutcome($0) }, orientation: { _ in .up })
        return (doc, model)
    }

    func testImportRotatesInTheSameSingleUndoStepAndSaysSo() async throws {
        let (doc, model) = try await openPhoto(xmpText: xmp)
        model.request(for: doc)
        let request = try XCTUnwrap(model.pending)
        XCTAssertEqual(request.rotationQuarterTurns, 3)
        XCTAssertTrue(LightroomImportModel.confirmationMessage(request).contains("turns the picture 90° left on screen"))
        XCTAssertTrue(LightroomImportModel.confirmationMessage(request).contains("a rotation turns your crop, masks and red-eye points with the picture"))
        XCTAssertNotNil(request.cropRefusal, "the file has a crop; it is refused while the import rotates")
        let before = doc.editState
        let steps = doc.historyEntries.count
        model.confirm(request, includeCrop: false, document: doc)
        XCTAssertEqual(doc.editState.rotationQuarterTurns, 3)
        XCTAssertEqual(doc.editState.exposureEV, 0.65, accuracy: 1e-12)
        XCTAssertEqual(doc.historyEntries.count, steps + 1)
        XCTAssertEqual(doc.historyEntries.last?.summary, "Lightroom Settings")
        XCTAssertTrue(try XCTUnwrap(model.resultMessage).contains("turned the picture 90° left on screen"))
        doc.undo()
        XCTAssertEqual(doc.editState, before, "one undo removes the rotation and the sliders together")
    }

    func testMirroredPacketIsNamedInTheDialogAndImportsNoRotation() async throws {
        let (doc, model) = try await openPhoto(xmpText: xmp.replacingOccurrences(of: "tiff:Orientation=\"8\"", with: "tiff:Orientation=\"2\""))
        model.request(for: doc)
        let request = try XCTUnwrap(model.pending)
        XCTAssertNil(request.rotationQuarterTurns)
        XCTAssertTrue(request.ignoredNames.contains("Orientation (mirrored)"))
        model.confirm(request, includeCrop: false, document: doc)
        XCTAssertEqual(doc.editState.rotationQuarterTurns, 0)
    }

    func testAnAlreadyRotatedPhotoIsNotRotatedTwice() async throws {
        let (doc, model) = try await openPhoto(xmpText: xmp)
        model.request(for: doc)
        model.confirm(try XCTUnwrap(model.pending), includeCrop: false, document: doc)
        model.resultMessage = nil
        model.request(for: doc)
        model.confirm(try XCTUnwrap(model.pending), includeCrop: false, document: doc)
        XCTAssertEqual(doc.editState.rotationQuarterTurns, 3, "importing again sets the same absolute turn count")
    }
}
