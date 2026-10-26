import XCTest
import CoreImage
import ImageIO
@testable import PhotoApp

/// `LightroomImportModel`: finding the `.xmp`, size / access outcomes, the confirm / stale-photo guard, crop refusal, the honest result
/// text, and the menu wiring in the source.
@MainActor
final class LightroomImportModelTests: XCTestCase {
    private final class DeclineAccess: SidecarFolderAccessing {
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .declined }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("LightroomImportModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let xmp = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
     <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
       crs:Exposure2012="+0.65" crs:Contrast2012="+28" crs:Vibrance="+10" crs:Temperature="2400" crs:WhiteBalance="Custom" crs:ColorGradeMidtoneHue="120"
       crs:HasCrop="True" crs:CropLeft="0.1" crs:CropRight="0.9" crs:CropTop="0" crs:CropBottom="1"/>
    </rdf:RDF></x:xmpmeta>
    """

    private func photo(_ name: String = "photo") async throws -> (ImageDocumentModel, URL) {
        let url = dir.appendingPathComponent("\(name).png")
        let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        try CIContext().writePNGRepresentation(of: base, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        await model.load(from: url)
        return (model, url)
    }

    private final class Counter { var count = 0 }

    private func model(panelPick: URL? = nil, panels: Counter = Counter(),
                       reader: @escaping (URL) -> LightroomImportModel.ReadOutcome = { LightroomImportModel.readOutcome($0) },
                       orientation: @escaping (URL) -> CGImagePropertyOrientation? = { _ in .up }) -> LightroomImportModel {
        LightroomImportModel(folderAccess: DeclineAccess(), chooseFile: { _ in panels.count += 1; return panelPick }, reader: reader, orientation: orientation)
    }

    // MARK: - Finding the file

    func testReadsTheBaseXmpNextToThePhotoWithoutAskingForAFile() async throws {
        let (doc, url) = try await photo()
        try Data(xmp.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let panels = Counter()
        let m = model(panels: panels)
        m.request(for: doc)
        XCTAssertEqual(m.pending?.sourceName, "photo.xmp")
        XCTAssertEqual(m.pending?.hasCrop, true)
        XCTAssertEqual(panels.count, 0)
        XCTAssertTrue(m.isBusy)
    }

    func testFallsBackToTheFileDotXmpSpelling() async throws {
        let (doc, url) = try await photo()
        try Data(xmp.utf8).write(to: XMPSidecarStore.alternateSidecarURL(for: url))
        let m = model()
        m.request(for: doc)
        XCTAssertEqual(m.pending?.sourceName, "photo.png.xmp")
    }

    func testNoSidecarOpensThePanelAndUsesThePickedFile() async throws {
        let (doc, _) = try await photo()
        let other = dir.appendingPathComponent("other.xmp")
        try Data(xmp.utf8).write(to: other)
        let panels = Counter()
        let m = model(panelPick: other, panels: panels)
        m.request(for: doc)
        XCTAssertEqual(panels.count, 1)
        XCTAssertEqual(m.pending?.sourceName, "other.xmp")
    }

    func testCancellingThePanelWhenNothingWasFoundIsSilent() async throws {
        let (doc, _) = try await photo()
        let m = model(panelPick: nil)
        m.request(for: doc)
        XCTAssertNil(m.pending)
        XCTAssertNil(m.resultMessage, "not found + cancel: no alert")
    }

    func testAccessDeniedIsReportedDifferentlyFromNotFound() async throws {
        let (doc, _) = try await photo()
        let denied = model(panelPick: nil, reader: { _ in .denied })
        denied.request(for: doc)
        XCTAssertTrue(denied.resultMessage?.contains("access") == true, denied.resultMessage ?? "nil")
        XCTAssertTrue(denied.resultMessage?.contains("photo.xmp") == true)
        let missing = model(panelPick: nil, reader: { _ in .notFound })
        missing.request(for: doc)
        XCTAssertNil(missing.resultMessage)
        // A picked file that is denied / missing says so too.
        let picked = dir.appendingPathComponent("picked.xmp")
        let pickedDenied = model(panelPick: picked, reader: { $0 == picked ? .denied : .notFound })
        pickedDenied.request(for: doc)
        XCTAssertTrue(pickedDenied.resultMessage?.contains("access was denied") == true)
        let pickedMissing = model(panelPick: picked, reader: { _ in .notFound })
        pickedMissing.request(for: doc)
        XCTAssertTrue(pickedMissing.resultMessage?.contains("was not found") == true)
    }

    func testAnOversizedFileIsRefusedWithAMessage() async throws {
        let (doc, _) = try await photo()
        let m = model(reader: { _ in .tooLarge })
        m.request(for: doc)
        XCTAssertNil(m.pending)
        XCTAssertEqual(m.resultMessage, "\"photo.xmp\" is larger than 4 MB, so it was not read.")
        let picked = model(panelPick: dir.appendingPathComponent("big.xmp"), reader: { $0.lastPathComponent == "big.xmp" ? .tooLarge : .notFound })
        picked.request(for: doc)
        XCTAssertEqual(picked.resultMessage, "\"big.xmp\" is larger than 4 MB, so it was not read.")
    }

    func testTheDefaultReaderChecksSizeBeforeReadingAndClassifiesErrors() throws {
        let url = dir.appendingPathComponent("size.xmp")
        try Data(xmp.utf8).write(to: url)
        if case .data = LightroomImportModel.readOutcome(url) {} else { XCTFail("a small file is read") }
        XCTAssertEqual(LightroomImportModel.readOutcome(url, maximumBytes: 10), .tooLarge)
        XCTAssertEqual(LightroomImportModel.readOutcome(dir.appendingPathComponent("missing.xmp")), .notFound)
    }

    func testGarbageAndEmptyFilesGiveAMessageNotAConfirmation() async throws {
        let (doc, url) = try await photo()
        try Data("not xml".utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let m = model()
        m.request(for: doc)
        XCTAssertNil(m.pending)
        XCTAssertTrue(m.resultMessage?.contains("not a readable XMP") == true)

        m.resultMessage = nil
        try Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="2"/></rdf:RDF></x:xmpmeta>"#.utf8)
            .write(to: XMPSidecarStore.sidecarURL(for: url))
        m.request(for: doc)
        XCTAssertNil(m.pending)
        XCTAssertTrue(m.resultMessage?.contains("no Lightroom") == true)
    }

    func testAnOlderProcessVersionFileIsRefusedClearly() async throws {
        let (doc, url) = try await photo()
        try Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           crs:ProcessVersion="3.7" crs:Exposure="+0.50" crs:Brightness="+30" crs:Contrast="+25"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let m = model()
        m.request(for: doc)
        XCTAssertNil(m.pending)
        XCTAssertEqual(m.resultMessage, "This file uses an older Camera Raw process version (3.7); nothing was imported.")
        XCTAssertEqual(doc.editState.exposureEV, 0)
    }

    func testNothingHappensWithoutAnOpenPhoto() {
        let m = model()
        m.request(for: ImageDocumentModel(folderAccess: DeclineAccess()))
        XCTAssertNil(m.pending)
        XCTAssertNil(m.resultMessage)
    }

    // MARK: - Confirm

    func testConfirmAppliesOneStepAndReportsCountsHonestly() async throws {
        let (doc, url) = try await photo()
        try Data(xmp.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let m = model()
        m.request(for: doc)
        let request = try XCTUnwrap(m.pending)
        XCTAssertEqual(request.nominalApplied, ["Vibrance"])
        let dialog = LightroomImportModel.confirmationMessage(request)
        XCTAssertTrue(dialog.contains(LightroomImportModel.honestyNote), "the dialog states the honesty note")
        XCTAssertTrue(dialog.contains(LightroomImportModel.replaceNote), "the dialog says a full file replaces what it lists, zeros included")
        XCTAssertFalse(dialog.contains(LightroomImportModel.curvesNote), "no curve in this file")
        XCTAssertTrue(dialog.contains(LightroomImportModel.notImportedNote), "said BEFORE confirming")
        XCTAssertTrue(LightroomImportModel.notImportedNote.contains("Contrast") && LightroomImportModel.notImportedNote.contains("White Balance")
                        && LightroomImportModel.notImportedNote.contains("Sharpness"))
        XCTAssertTrue(dialog.contains("In this file: ") && dialog.contains("Temperature") && dialog.contains("ColorGradeMidtoneHue"), dialog)
        XCTAssertTrue(LightroomImportModel.replaceNote.contains("every slider it imports"))
        XCTAssertTrue(dialog.contains("Nominal fields: Vibrance."))
        let steps = doc.historyEntries.count
        m.confirm(request, includeCrop: false, document: doc)
        XCTAssertNil(m.pending)
        XCTAssertEqual(doc.editState.exposureEV, 0.65, accuracy: 1e-12)
        XCTAssertEqual(doc.editState.contrast, 0, "Contrast is not imported")
        XCTAssertEqual(doc.editState.cropInsetLeft, 0, "crop not included")
        XCTAssertEqual(doc.historyEntries.count, steps + 1)
        let message = try XCTUnwrap(m.resultMessage)
        // set: Exposure2012, Vibrance. ignored: Contrast2012 (note), ColorGradeMidtoneHue, Temperature, Crop (not included)
        XCTAssertTrue(message.hasPrefix("Set 2 settings. Ignored 4."), message)
        XCTAssertTrue(message.contains("Contrast2012 (not calibrated: made the match worse on the test photo)"), message)
        XCTAssertTrue(message.contains("Only Exposure has been checked against Lightroom; the other sliders use a nominal scale and may look different."))
        XCTAssertTrue(message.contains("Nominal fields applied: Vibrance."))
        XCTAssertTrue(message.contains("Approximate: Lightbench renders differently from Adobe."))
    }

    func testConfirmWithCropAppliesTheCrop() async throws {
        let (doc, url) = try await photo()
        try Data(xmp.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let m = model()
        m.request(for: doc)
        m.confirm(try XCTUnwrap(m.pending), includeCrop: true, document: doc)
        XCTAssertEqual(doc.editState.cropInsetLeft, 0.1, accuracy: 1e-12)
        XCTAssertEqual(doc.editState.cropInsetRight, 0.1, accuracy: 1e-12)
    }

    func testCropIsRefusedForARotatedPhotoButTheRestImports() async throws {
        let (doc, url) = try await photo()
        try Data(xmp.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let m = model(orientation: { _ in .right })
        m.request(for: doc)
        let request = try XCTUnwrap(m.pending)
        XCTAssertFalse(request.cropAllowed)
        XCTAssertTrue(LightroomImportModel.confirmationMessage(request).contains("rotated by its own orientation"))
        XCTAssertNotNil(request.cropRefusal)
        m.confirm(request, includeCrop: true, document: doc)
        XCTAssertEqual(doc.editState.cropInsetLeft, 0)
        XCTAssertEqual(doc.editState.exposureEV, 0.65, accuracy: 1e-12, "the rest still imports")
        XCTAssertTrue(m.resultMessage?.contains("The crop was not imported") == true, m.resultMessage ?? "nil")
    }

    func testConfirmIsRefusedWhenAnotherPhotoIsOpenByThen() async throws {
        let (doc, url) = try await photo("first")
        try Data(xmp.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let m = model()
        m.request(for: doc)
        let request = try XCTUnwrap(m.pending)
        let second = dir.appendingPathComponent("second.png")
        try CIContext().writePNGRepresentation(of: CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32)), to: second,
                                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        await doc.load(from: second)
        m.confirm(request, includeCrop: false, document: doc)
        XCTAssertEqual(doc.editState.exposureEV, 0, "nothing was applied to the new photo")
        XCTAssertTrue(m.resultMessage?.contains("photo changed") == true)
    }

    func testCancelClearsThePendingRequest() async throws {
        let (doc, url) = try await photo()
        try Data(xmp.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let m = model()
        m.request(for: doc)
        m.cancel()
        XCTAssertNil(m.pending)
        XCTAssertFalse(m.isBusy)
    }

    func testASecondRequestWhileOneIsPendingIsIgnored() async throws {
        let (doc, url) = try await photo()
        try Data(xmp.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let panels = Counter()
        let m = model(panels: panels)
        m.request(for: doc)
        let first = m.pending
        m.request(for: doc)
        XCTAssertEqual(m.pending, first)
        XCTAssertEqual(panels.count, 0)
    }

    // MARK: - Text

    func testSummaryWording() {
        let one = LightroomMapping.plan(from: AdobeCameraRawSettings(scalars: ["Exposure2012": "+1"]))
        let oneChange = LightroomMapping.changes(of: one, onto: .identity)
        XCTAssertEqual(LightroomImportModel.summary(plan: one, changes: oneChange, applied: true),
                       "Set 1 setting. Ignored 0. \(LightroomImportModel.honestyNote) \(LightroomImportModel.approximateNote)")
        var many = LightroomMapping.Plan()
        many.ignored = (1...9).map { "N\($0)" }
        XCTAssertTrue(LightroomImportModel.summary(plan: many, changes: .init(), applied: true).contains("N6, and 3 more"))
        XCTAssertTrue(LightroomImportModel.summary(plan: many, changes: .init(), applied: false).contains("nothing changed"))
        let resets = LightroomMapping.Changes(setNames: ["A"], resetSliders: ["x", "y"], resetCurves: ["c1", "c2"], resetBlackAndWhite: true)
        XCTAssertTrue(LightroomImportModel.summary(plan: many, changes: resets, applied: true)
            .hasPrefix("Set 1 setting; also reset 2 sliders to 0, 2 point curves and Black & White. Ignored 9."))
        let single = LightroomMapping.Changes(resetSliders: ["x"])
        XCTAssertTrue(LightroomImportModel.summary(plan: many, changes: single, applied: true).hasPrefix("Set 0 settings; also reset 1 slider to 0. "))
    }

    // MARK: - Menu wiring

    private func appSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/App/PhotoAppApp.swift"), encoding: .utf8)
    }

    func testPhotoMenuItemIsEditorOnlyUnbusyAndHasNoShortcut() throws {
        let lines = try appSource().components(separatedBy: "\n")
        let index = try XCTUnwrap(lines.firstIndex { $0.contains(#"Button("Import Lightroom Settings…")"#) })
        let block = lines[index...(index + 6)].joined(separator: "\n")
        XCTAssertTrue(block.contains("lightroomImport.request(for: document)"))
        for guardText in ["cull.isActive", "showLibrary", "document.currentImage == nil", "document.isLoadInFlight", "lightroomImport.isBusy", "catalog.fileToolBusy"] {
            XCTAssertTrue(block.contains(guardText), "the menu item must be disabled by \(guardText)")
        }
        XCTAssertFalse(block.contains("keyboardShortcut"), "no shortcut")
    }

    func testTheModifierIsAttachedToTheWindowContent() throws {
        XCTAssertTrue(try appSource().contains(".modifier(LightroomImportModifier(model: lightroomImport, document: document))"))
    }

    func testTheFeatureNeverWritesCrsAnywhere() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/Rendering/AdobeCameraRawSettings.swift", "Sources/EditEngine/LightroomMapping.swift", "Sources/UI/LightroomImportModel.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for forbidden in [".write(to", "CGImageMetadataSetValue", "CGImageMetadataSetTag", "CGImageDestination", "removeItem", "moveItem"] {
                XCTAssertFalse(text.contains(forbidden), "\(file) is read-only but contains \(forbidden)")
            }
        }
    }

    // MARK: - Reading regular files only

    func testASpecialFileIsRefusedWithoutBlocking() async throws {
        let (doc, _) = try await photo()
        let m = model(panelPick: nil, reader: { _ in .notRegular })
        m.request(for: doc)
        XCTAssertEqual(m.resultMessage, "\"photo.xmp\" is not a regular file, so it was not read.")
    }

    func testTheDefaultReaderRefusesFifosDevicesDirectoriesAndOversizedSymlinkTargets() throws {
        let fifo = dir.appendingPathComponent("pipe.xmp")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertEqual(LightroomImportModel.readOutcome(fifo), .notRegular, "a FIFO is never opened (opening it would block)")
        let link = dir.appendingPathComponent("link-to-fifo.xmp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)
        XCTAssertEqual(LightroomImportModel.readOutcome(link), .notRegular, "a symlink to a FIFO too")
        let device = dir.appendingPathComponent("zero.xmp")
        try FileManager.default.createSymbolicLink(at: device, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        XCTAssertEqual(LightroomImportModel.readOutcome(device), .notRegular, "an endless device behind a symlink")
        XCTAssertEqual(LightroomImportModel.readOutcome(dir), .notRegular)

        let big = dir.appendingPathComponent("big.xmp")
        try Data(repeating: 0x20, count: 200).write(to: big)
        let bigLink = dir.appendingPathComponent("link-to-big.xmp")
        try FileManager.default.createSymbolicLink(at: bigLink, withDestinationURL: big)
        XCTAssertEqual(LightroomImportModel.readOutcome(bigLink, maximumBytes: 100), .tooLarge, "an oversized symlink target")
        if case .data(let data) = LightroomImportModel.readOutcome(bigLink, maximumBytes: 200) { XCTAssertEqual(data.count, 200) } else { XCTFail("exactly at the cap is read") }
    }

    // MARK: - Disclosure, curves, crop against the current edit

    func testACurveInTheFileAddsTheToneSpaceNoteToDialogAndAlert() async throws {
        let (doc, url) = try await photo()
        try Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:ProcessVersion="6.7" crs:Exposure2012="+0.5">
          <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>128, 150</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
         </rdf:Description>
        </rdf:RDF></x:xmpmeta>
        """.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let m = model()
        m.request(for: doc)
        let request = try XCTUnwrap(m.pending)
        XCTAssertTrue(LightroomImportModel.confirmationMessage(request).contains(LightroomImportModel.curvesNote))
        m.confirm(request, includeCrop: false, document: doc)
        let message = try XCTUnwrap(m.resultMessage)
        XCTAssertTrue(message.contains(LightroomImportModel.curvesNote), message)
        XCTAssertTrue(message.contains("Nominal fields applied: ToneCurvePV2012."), message)
        XCTAssertEqual(doc.editState.toneCurvePoints.count, 3)
    }

    func testTheCropIsRefusedWhenTheCurrentEditHasAFlipButTheRestImports() async throws {
        let (doc, url) = try await photo()
        try Data(xmp.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        doc.editState.flipHorizontal = true
        try await Task.sleep(nanoseconds: 600_000_000)
        let m = model()
        m.request(for: doc)
        let request = try XCTUnwrap(m.pending)
        XCTAssertNotNil(request.cropRefusal, "the dialog will not offer Import with Crop")
        m.confirm(request, includeCrop: true, document: doc)
        XCTAssertEqual(doc.editState.cropInsetLeft, 0)
        XCTAssertTrue(doc.editState.flipHorizontal)
        XCTAssertEqual(doc.editState.exposureEV, 0.65, accuracy: 1e-12)
        XCTAssertTrue(m.resultMessage?.contains("flip, straighten, perspective or scale") == true, m.resultMessage ?? "nil")
    }

    func testAPacketOrientationThatDiffersFromThePhotoRefusesTheCrop() async throws {
        let (doc, url) = try await photo()
        try Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
           tiff:Orientation="6" crs:Exposure2012="+0.5" crs:HasCrop="True" crs:CropLeft="0.1" crs:CropRight="0.9"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let m = model()
        m.request(for: doc)
        let request = try XCTUnwrap(m.pending)
        XCTAssertEqual(request.settings.tiffOrientation, 6)
        XCTAssertNotNil(request.cropRefusal)
        m.confirm(request, includeCrop: true, document: doc)
        XCTAssertEqual(doc.editState.cropInsetLeft, 0)
        XCTAssertEqual(doc.editState.exposureEV, 0.5, accuracy: 1e-12)
    }

    func testAnUnreadableOrientationIsNotAssumedUprightSoTheCropIsRefused() async throws {
        let (doc, url) = try await photo()
        try Data(xmp.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let m = model(orientation: { _ in nil })
        m.request(for: doc)
        let request = try XCTUnwrap(m.pending)
        XCTAssertFalse(request.cropAllowed)
        XCTAssertNil(request.photoOrientation)
        XCTAssertNotNil(request.cropRefusal)
        m.confirm(request, includeCrop: true, document: doc)
        XCTAssertEqual(doc.editState.cropInsetLeft, 0)
        XCTAssertEqual(doc.editState.exposureEV, 0.65, accuracy: 1e-12)
    }

    func testAFullFrameCropThatClearsAnExistingCropIsReportedAsClearedNotSet() async throws {
        let (doc, url) = try await photo()
        doc.editState.cropInsetLeft = 0.2
        try await Task.sleep(nanoseconds: 600_000_000)
        try Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           crs:Exposure2012="+0.5" crs:HasCrop="True" crs:CropLeft="0" crs:CropTop="0" crs:CropRight="1" crs:CropBottom="1"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8).write(to: XMPSidecarStore.sidecarURL(for: url))
        let m = model()
        m.request(for: doc)
        m.confirm(try XCTUnwrap(m.pending), includeCrop: true, document: doc)
        XCTAssertEqual(doc.editState.cropInsetLeft, 0)
        let message = try XCTUnwrap(m.resultMessage)
        XCTAssertTrue(message.hasPrefix("Set 1 setting; cleared the crop. Ignored"), message)
    }
}
