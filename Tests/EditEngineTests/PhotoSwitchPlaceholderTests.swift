import CoreImage
import XCTest
@testable import PhotoApp

/// IMPROVEMENTS.md D13: an armed, never-painted Brush mask used to be flushed into the OUTGOING photo's sidecar when the user switched photos,
/// because the Editor's cleanup ran after `load(from:)` had already swapped `editState`. `ImageDocumentModel.willSwitchPhoto` now runs first.
@MainActor
final class PhotoSwitchPlaceholderTests: XCTestCase {
    private final class GrantAccess: SidecarFolderAccessing {
        let folder: URL
        init(_ folder: URL) { self.folder = folder }
        func resolvedURL(for folder: URL) -> URL? { self.folder }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .granted(self.folder) }
    }

    private var dir: URL!
    private var photoA: URL!
    private var photoB: URL!
    private var scopedFolder: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoSwitchPlaceholderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        photoA = dir.appendingPathComponent("a.png")
        photoB = dir.appendingPathComponent("b.png")
        for url in [photoA!, photoB!] {
            let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
            try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        // A genuinely security-scoped URL: `startAccessingSecurityScopedResource()` is false for a plain one, and the sidecar save refuses then.
        let bookmark = try dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        scopedFolder = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func emptyBrush() -> Mask { Mask(kind: .brush, feather: 0.3, brushSize: 0.15, brushPoints: []) }

    private func storedMasks() -> [Mask]? {
        guard case .decoded(let state) = SidecarStore.read(forPhotoAt: photoA) else { return nil }
        return state.masks
    }

    func testTheHookRunsBeforeTheOutgoingPhotoIsFlushedSoAPhantomMaskNeverReachesItsSidecar() async throws {
        let model = ImageDocumentModel(folderAccess: GrantAccess(scopedFolder))
        await model.load(from: photoA)
        let phantom = emptyBrush()
        model.editState.exposureEV = 0.5                  // a real edit so a sidecar is written at all
        model.editState.masks.append(phantom)
        model.willSwitchPhoto = { [unowned model] in model.editState.masks.removeAll { $0.id == phantom.id } }

        await model.load(from: photoB)

        XCTAssertEqual(model.currentURL, photoB)
        let masks = try XCTUnwrap(storedMasks(), "A's sidecar must have been written on the switch")
        XCTAssertTrue(masks.isEmpty, "the phantom empty brush mask must not be in A's sidecar")
        guard case .decoded(let state) = SidecarStore.read(forPhotoAt: photoA) else { return XCTFail("A's sidecar must exist") }
        XCTAssertEqual(state.exposureEV, 0.5, "the real edit is still saved")
    }

    func testWithoutTheHookThePhantomWouldHaveBeenSavedWhichIsWhatTheHookPrevents() async throws {
        let model = ImageDocumentModel(folderAccess: GrantAccess(scopedFolder))
        await model.load(from: photoA)
        model.editState.exposureEV = 0.5
        model.editState.masks.append(emptyBrush())
        await model.load(from: photoB)
        XCTAssertEqual(storedMasks()?.count, 1, "the baseline the hook fixes: the empty mask is flushed into A")
    }

    func testTheHookIsCalledOncePerLoadAndBeforeAnythingElseChanges() async throws {
        let model = ImageDocumentModel(folderAccess: GrantAccess(scopedFolder))
        var seenURLs: [URL?] = []
        model.willSwitchPhoto = { [unowned model] in seenURLs.append(model.currentURL) }
        await model.load(from: photoA)
        await model.load(from: photoB)
        XCTAssertEqual(seenURLs.map { $0?.lastPathComponent }, [nil, "a.png"], "each call still sees the OUTGOING photo")
    }

    func testContentViewWiresTheHookToTheThreeDiscards() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/UI/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("document.willSwitchPhoto = { discardUnfinishedPlaceholders() }"))
        for call in ["discardUnpaintedBrushMask(brushPaintingMaskID)", "discardUnpickedColorRangeMask(colorPickingMaskID)", "discardUnpickedPointColor(pointColorPickingID)"] {
            XCTAssertTrue(source.contains(call), call)
        }
    }
}
