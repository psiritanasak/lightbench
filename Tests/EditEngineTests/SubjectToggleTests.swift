import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoApp

/// `ImageDocumentModel.toggleSubjectInstance` — click-on-image subject picking, end to end through a real loaded photo.
@MainActor
final class SubjectToggleTests: XCTestCase {
    /// Never prompts: a declined folder means the debounced sidecar save is silently skipped (no NSOpenPanel in tests).
    private final class DeclineAccess: SidecarFolderAccessing {
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .declined }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SubjectToggleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func png(value: (Int, Int) -> UInt8) throws -> Data {
        let w = 64
        var bytes = [UInt8](repeating: 0, count: w * w)
        for y in 0..<w { for x in 0..<w { bytes[y * w + x] = value(x, y) } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: w, height: w, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// A model with a loaded 200x200 photo and one subject mask: instance 0 = left half, instance 1 = top-right quadrant.
    private func makeModel(enabled: [Bool] = [], legacyOnly: Bool = false) async throws -> (ImageDocumentModel, UUID) {
        let url = dir.appendingPathComponent("photo.png")
        let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        try CIContext().writePNGRepresentation(of: base, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        await model.load(from: url)
        var mask = Mask()
        mask.kind = .subject
        mask.subjectMaskRevision = 1
        if legacyOnly {
            mask.subjectMaskPNG = try png { x, _ in x < 32 ? 255 : 0 }
        } else {
            mask.subjectInstancePNGs = [try png { x, _ in x < 32 ? 255 : 0 }, try png { x, y in x >= 32 && y < 32 ? 255 : 0 }]
            mask.subjectInstanceEnabled = enabled
        }
        model.editState.masks = [mask]
        // Let the ~350ms edit-coalescing window close, so creating the mask is already its own settled history step.
        try await Task.sleep(nanoseconds: 600_000_000)
        return (model, mask.id)
    }

    private func enabled(_ model: ImageDocumentModel) -> [Bool] { model.editState.masks.first?.subjectInstanceEnabled ?? [] }

    func testClickingASubjectTogglesJustThatInstanceAsOneUndoableStep() async throws {
        let (model, id) = try await makeModel()
        let stepsBefore = model.historyEntries.count
        model.toggleSubjectInstance(maskID: id, normalizedX: 0.25, normalizedY: 0.5)
        XCTAssertEqual(enabled(model), [false, true], "the missing-entries default (all enabled) was materialized, then ONE flipped")
        XCTAssertEqual(model.historyEntries.count, stepsBefore + 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Toggle Subject 1")
        model.toggleSubjectInstance(maskID: id, normalizedX: 0.25, normalizedY: 0.5)
        XCTAssertEqual(enabled(model), [true, true], "a second click turns it back on")
        model.undo()
        XCTAssertEqual(enabled(model), [false, true])
        model.undo()
        XCTAssertEqual(enabled(model), [], "undo restores the original state exactly")
    }

    func testTogglingTheSecondSubjectDoesNotDisableTheFirst() async throws {
        let (model, id) = try await makeModel()
        model.toggleSubjectInstance(maskID: id, normalizedX: 0.75, normalizedY: 0.25)
        XCTAssertEqual(enabled(model), [true, false])
    }

    func testAClickOnNoSubjectChangesNothingAndSaysSo() async throws {
        let (model, id) = try await makeModel()
        let steps = model.historyEntries.count
        model.toggleSubjectInstance(maskID: id, normalizedX: 0.75, normalizedY: 0.75)
        XCTAssertEqual(enabled(model), [])
        XCTAssertEqual(model.historyEntries.count, steps)
        XCTAssertEqual(model.subjectMaskMessage, "No subject at that point.")
    }

    func testALegacyUnionOnlyMaskHasNothingToPick() async throws {
        let (model, id) = try await makeModel(legacyOnly: true)
        let steps = model.historyEntries.count
        model.toggleSubjectInstance(maskID: id, normalizedX: 0.25, normalizedY: 0.5)
        XCTAssertEqual(model.historyEntries.count, steps)
        XCTAssertTrue(model.subjectMaskMessage?.contains("Recompute") == true)
    }

    func testAnUnknownMaskIdIsASilentNoOp() async throws {
        let (model, _) = try await makeModel()
        let steps = model.historyEntries.count
        model.toggleSubjectInstance(maskID: UUID(), normalizedX: 0.25, normalizedY: 0.5)
        XCTAssertEqual(model.historyEntries.count, steps)
        XCTAssertNil(model.subjectMaskMessage)
    }
}
