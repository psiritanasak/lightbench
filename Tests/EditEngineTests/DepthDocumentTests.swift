import CoreImage
import XCTest
@testable import PhotoApp

/// `ImageDocumentModel.generateDepth` end to end through a real loaded photo: the embedded path on a synthetic HEIC (no model needed), the failure
/// messages, and — when the optional bundled model is installed — the model path, regeneration and single-flight.
@MainActor
final class DepthDocumentTests: XCTestCase {
    /// Never prompts: a declined folder means the debounced sidecar save is silently skipped (no NSOpenPanel in tests).
    private final class DeclineAccess: SidecarFolderAccessing {
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .declined }
    }

    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DepthDocumentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func loadedModel(heic: Bool) async throws -> ImageDocumentModel {
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        if heic {
            let url = dir.appendingPathComponent("depth.heic")
            try SyntheticDepthFixtures.writeHEIC(to: url, width: 80, height: 60, depthWidth: 40, depthHeight: 30)
            await model.load(from: url)
        } else {
            let url = dir.appendingPathComponent("plain.png")
            let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 60))
            try CIContext().writePNGRepresentation(of: base, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            await model.load(from: url)
        }
        // Wait for the availability refresh (it lands after the load): poll for the expected answer instead of sleeping a fixed time.
        let expectEmbedded = heic
        for _ in 0..<200 where model.depthAvailability.embedded != expectEmbedded || model.isLoadInFlight { try await Task.sleep(nanoseconds: 25_000_000) }
        return model
    }

    private func generate(_ model: ImageDocumentModel, replacing id: UUID? = nil, preference: DepthSourceResolver.Preference? = nil) async -> UUID? {
        await withCheckedContinuation { continuation in
            model.generateDepth(replacing: id, preference: preference) { continuation.resume(returning: $0) }
        }
    }

    // MARK: Availability

    func testAvailabilityFollowsTheOpenPhoto() async throws {
        let plain = try await loadedModel(heic: false)
        XCTAssertFalse(plain.depthAvailability.embedded)
        XCTAssertEqual(plain.depthAvailability.model, DepthModelRunner.isInstalled)
        let withDepth = try await loadedModel(heic: true)
        XCTAssertTrue(withDepth.depthAvailability.embedded, "the HEIC carries an auxiliary disparity map")
    }

    // MARK: Embedded path (no model required)

    func testGeneratingFromEmbeddedDepthAddsAMaskAsOneUndoableStep() async throws {
        let model = try await loadedModel(heic: true)
        let stepsBefore = model.historyEntries.count
        let id = await generate(model, preference: .embedded)
        let mask = try XCTUnwrap(model.editState.masks.first { $0.id == id })
        XCTAssertEqual(mask.kind, .depthRange)
        XCTAssertEqual(mask.depthSource, DepthSourceTag.embedded)
        XCTAssertNotNil(mask.depthRasterPNG)
        XCTAssertTrue(mask.isIdentity, "a new mask adjusts nothing: the user dials the effect in")
        XCTAssertEqual(model.historyEntries.count, stepsBefore + 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Generate Depth")
        XCTAssertFalse(model.isGeneratingDepth)
        model.undo()
        XCTAssertTrue(model.editState.masks.isEmpty, "one Undo removes the generated mask")
    }

    func testRegeneratingKeepsTheWindowAndAdjustmentsAndReplacesOnlyTheRaster() async throws {
        let model = try await loadedModel(heic: true)
        let generated = await generate(model, preference: .embedded)
        let id = try XCTUnwrap(generated)
        var tweaked = model.editState
        let i = try XCTUnwrap(tweaked.masks.firstIndex { $0.id == id })
        tweaked.masks[i].depthFarLimit = 0.2; tweaked.masks[i].depthNearLimit = 0.7; tweaked.masks[i].depthFeather = 0.6
        tweaked.masks[i].invertSelection = true; tweaked.masks[i].exposureEV = 1.5
        model.editState = tweaked
        try await Task.sleep(nanoseconds: 600_000_000)
        let again = await generate(model, replacing: id)
        XCTAssertEqual(again, id)
        let mask = try XCTUnwrap(model.editState.masks.first { $0.id == id })
        XCTAssertEqual(mask.depthFarLimit, 0.2); XCTAssertEqual(mask.depthNearLimit, 0.7); XCTAssertEqual(mask.depthFeather, 0.6)
        XCTAssertTrue(mask.invertSelection); XCTAssertEqual(mask.exposureEV, 1.5)
        XCTAssertEqual(mask.depthSource, DepthSourceTag.embedded, "regenerating keeps the mask's current source")
        XCTAssertEqual(model.editState.masks.count, 1, "replaced in place, not appended")
    }

    /// A late message about the previous photo must not pop up over the next one.
    func testOpeningAnotherPhotoClearsAPendingDepthMessage() async throws {
        let model = try await loadedModel(heic: false)
        _ = await generate(model, preference: .embedded)
        XCTAssertNotNil(model.depthMaskMessage)
        let other = dir.appendingPathComponent("next.png")
        try CIContext().writePNGRepresentation(of: CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 60)), to: other, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        await model.load(from: other)
        XCTAssertNil(model.depthMaskMessage)
    }

    // MARK: Failures

    func testAnExplicitSourceThatDoesNotExistIsRefusedWithAMessageAndNoHistoryStep() async throws {
        let model = try await loadedModel(heic: false)
        let before = model.historyEntries.count
        let id = await generate(model, preference: .embedded)
        XCTAssertNil(id)
        XCTAssertEqual(model.depthMaskMessage, DepthSourceResolver.noEmbedded)
        XCTAssertEqual(model.historyEntries.count, before)
        XCTAssertTrue(model.editState.masks.isEmpty)
        XCTAssertFalse(model.isGeneratingDepth, "single-flight state is released on every failure")
    }

    func testAutomaticOnAPlainPhotoNeedsTheModelAndSaysSoWhenItIsMissing() async throws {
        let model = try await loadedModel(heic: false)
        let id = await generate(model, preference: .automatic)
        if DepthModelRunner.isInstalled {
            let mask = try XCTUnwrap(model.editState.masks.first { $0.id == id })
            XCTAssertEqual(mask.depthSource, DepthModelRunner.sourceTag)
            XCTAssertNotNil(mask.depthRasterPNG)
        } else {
            XCTAssertNil(id)
            XCTAssertEqual(model.depthMaskMessage, DepthSourceResolver.noDepthAnywhere)
        }
    }

    func testRegeneratingAMaskThatWasDeletedMeanwhileSaysSoAndChangesNothing() async throws {
        let model = try await loadedModel(heic: true)
        let gone = UUID()
        let id = await generate(model, replacing: gone, preference: .embedded)
        XCTAssertNil(id)
        XCTAssertEqual(model.depthMaskMessage, "That mask was deleted before its depth was ready.")
        XCTAssertTrue(model.editState.masks.isEmpty)
    }

    // MARK: Single flight and staleness

    func testASecondRequestWhileOneRunsIsIgnored() async throws {
        let model = try await loadedModel(heic: true)
        var results: [UUID?] = []
        let done = expectation(description: "both completions")
        done.expectedFulfillmentCount = 2
        model.generateDepth(preference: .embedded) { results.append($0); done.fulfill() }
        model.generateDepth(preference: .embedded) { results.append($0); done.fulfill() } // the double click
        await fulfillment(of: [done], timeout: 20)
        XCTAssertEqual(results.compactMap { $0 }.count, 1, "exactly one mask came out of two requests")
        XCTAssertEqual(model.editState.masks.count, 1)
    }

    func testAResultForAPhotoThatIsNoLongerOpenIsDropped() async throws {
        let model = try await loadedModel(heic: true)
        var completion: UUID?? = .none
        let done = expectation(description: "completion")
        model.generateDepth(preference: .embedded) { completion = .some($0); done.fulfill() }
        // Switch photos immediately, before the detached work returns.
        let other = dir.appendingPathComponent("other.png")
        try CIContext().writePNGRepresentation(of: CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 60)), to: other, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        await model.load(from: other)
        await fulfillment(of: [done], timeout: 20)
        XCTAssertEqual(completion, .some(nil), "the stale result is reported as failed")
        XCTAssertTrue(model.editState.masks.isEmpty, "and never lands on the other photo")
    }
}
