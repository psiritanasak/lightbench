import CoreImage
import XCTest
@testable import PhotoApp

/// `ImageDocumentModel.addRetouchSpot(atNormalized:radius:)` / `deleteRetouchSpot(id:)` / the button's `addRetouchSpot()`:
/// every add or delete is its own labelled undo step, even when several happen inside the 350 ms coalescing window.
@MainActor
final class RetouchPlacementModelTests: XCTestCase {
    private final class DeclineAccess: SidecarFolderAccessing {
        func resolvedURL(for folder: URL) -> URL? { nil }
        func resolveOrRequest(for folder: URL, message: String) -> SidecarFolderAccess.Outcome { .declined }
    }

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RetouchPlacementModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeModel() async throws -> ImageDocumentModel {
        let url = dir.appendingPathComponent("photo.png")
        let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        try CIContext().writePNGRepresentation(of: base, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        await model.load(from: url)
        return model
    }

    func testAClickAddsOneSpotAsOneLabelledStep() async throws {
        let model = try await makeModel()
        let before = model.historyEntries.count
        let id = try XCTUnwrap(model.addRetouchSpot(atNormalized: (0.3, 0.7), radius: 0.03))
        let spot = try XCTUnwrap(model.editState.retouchSpots.first)
        XCTAssertEqual(model.editState.retouchSpots.count, 1)
        XCTAssertEqual(spot.id, id)
        XCTAssertEqual(spot.x, 0.3); XCTAssertEqual(spot.y, 0.7); XCTAssertEqual(spot.radius, 0.03)
        XCTAssertEqual(model.historyEntries.count, before + 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Add Spot")
    }

    /// The point of the feature: several clicks in quick succession are several spots AND several undo steps.
    func testRapidClicksAreSeparateUndoSteps() async throws {
        let model = try await makeModel()
        let before = model.historyEntries.count
        for i in 0..<4 { model.addRetouchSpot(atNormalized: (0.1 + 0.2 * Double(i), 0.5), radius: 0.02) }
        XCTAssertEqual(model.editState.retouchSpots.count, 4)
        XCTAssertEqual(model.historyEntries.count, before + 4, "no merging into one step inside the coalescing window")
        XCTAssertEqual(model.historyEntries.suffix(4).map(\.summary), Array(repeating: "Add Spot", count: 4))
        model.undo()
        XCTAssertEqual(model.editState.retouchSpots.count, 3, "undo removes only the last spot")
        model.undo()
        XCTAssertEqual(model.editState.retouchSpots.count, 2)
        model.redo()
        XCTAssertEqual(model.editState.retouchSpots.count, 3)
    }

    func testTheButtonAddIsAlsoOneLabelledStepAndSpotsKeepTheirOrder() async throws {
        let model = try await makeModel()
        let before = model.historyEntries.count
        let first = try XCTUnwrap(model.addRetouchSpot())
        let second = try XCTUnwrap(model.addRetouchSpot())
        XCTAssertEqual(model.editState.retouchSpots.map(\.id), [first, second], "append order = apply order")
        XCTAssertEqual(model.historyEntries.count, before + 2)
        XCTAssertEqual(model.historyEntries.last?.summary, "Add Spot")
        XCTAssertNotEqual(model.editState.retouchSpots[0].x, model.editState.retouchSpots[1].x, "the second one spirals away from the first")
    }

    func testValuesAreClampedToTheirLegalRanges() async throws {
        let model = try await makeModel()
        model.addRetouchSpot(atNormalized: (-2, 7), radius: 5)
        model.addRetouchSpot(atNormalized: (0.5, 0.5), radius: 0)
        let s = model.editState.retouchSpots
        XCTAssertEqual(s[0].x, 0); XCTAssertEqual(s[0].y, 1); XCTAssertEqual(s[0].radius, RetouchSpot.radiusRange.upperBound)
        XCTAssertEqual(s[1].radius, RetouchSpot.radiusRange.lowerBound)
    }

    func testNonFiniteInputIsRefusedWithoutAStep() async throws {
        let model = try await makeModel()
        let before = model.historyEntries.count
        XCTAssertNil(model.addRetouchSpot(atNormalized: (Double.nan, 0.5), radius: 0.02))
        XCTAssertNil(model.addRetouchSpot(atNormalized: (0.5, Double.infinity), radius: 0.02))
        XCTAssertNil(model.addRetouchSpot(atNormalized: (0.5, 0.5), radius: Double.nan))
        XCTAssertTrue(model.editState.retouchSpots.isEmpty)
        XCTAssertEqual(model.historyEntries.count, before)
    }

    func testRefusedWithAMessageWhenTheGeometryIsNotAtIdentity() async throws {
        let model = try await makeModel()
        model.editState.cropInsetLeft = 0.2
        let before = model.historyEntries.count
        XCTAssertNil(model.addRetouchSpot(atNormalized: (0.5, 0.5), radius: 0.02))
        XCTAssertNil(model.addRetouchSpot())
        XCTAssertNotNil(model.retouchMessage)
        XCTAssertTrue(model.editState.retouchSpots.isEmpty)
        XCTAssertTrue(model.historyEntries.count <= before + 1, "at most the crop edit's own burst, never a spot step")
        XCTAssertFalse(model.historyEntries.contains { $0.summary == "Add Spot" })
    }

    func testRefusedAtTheFiftySpotCap() async throws {
        let model = try await makeModel()
        model.editState.retouchSpots = (0..<EditState.maxRetouchSpots).map { i in
            var s = RetouchSpot(); s.x = 0.01 + 0.019 * Double(i); return s
        }
        XCTAssertNil(model.addRetouchSpot(atNormalized: (0.5, 0.5), radius: 0.02))
        XCTAssertNil(model.addRetouchSpot())
        XCTAssertEqual(model.editState.retouchSpots.count, EditState.maxRetouchSpots)
        XCTAssertNotNil(model.retouchMessage)
        XCTAssertFalse(model.historyEntries.contains { $0.summary == "Add Spot" })
    }

    func testNoImageNoSpot() {
        let model = ImageDocumentModel(folderAccess: DeclineAccess())
        XCTAssertNil(model.addRetouchSpot(atNormalized: (0.5, 0.5), radius: 0.02))
        XCTAssertNil(model.addRetouchSpot())
        XCTAssertTrue(model.editState.retouchSpots.isEmpty)
    }

    func testDeleteIsOneLabelledUndoableStep() async throws {
        let model = try await makeModel()
        let a = try XCTUnwrap(model.addRetouchSpot(atNormalized: (0.2, 0.2), radius: 0.02))
        let b = try XCTUnwrap(model.addRetouchSpot(atNormalized: (0.8, 0.8), radius: 0.02))
        let before = model.historyEntries.count
        model.deleteRetouchSpot(id: a)
        XCTAssertEqual(model.editState.retouchSpots.map(\.id), [b])
        XCTAssertEqual(model.historyEntries.count, before + 1)
        XCTAssertEqual(model.historyEntries.last?.summary, "Delete Spot")
        model.undo()
        XCTAssertEqual(model.editState.retouchSpots.map(\.id), [a, b], "undo restores the spot at its old position in the order")
    }

    func testDeletingAnUnknownSpotIsANoOpWithoutAStep() async throws {
        let model = try await makeModel()
        model.addRetouchSpot(atNormalized: (0.5, 0.5), radius: 0.02)
        let before = model.historyEntries.count
        model.deleteRetouchSpot(id: UUID())
        XCTAssertEqual(model.editState.retouchSpots.count, 1)
        XCTAssertEqual(model.historyEntries.count, before)
    }

    // MARK: - The auto-source result is its own labelled step

    private func waitForStep(_ model: ImageDocumentModel, _ summary: String) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.historyEntries.contains(where: { $0.summary == summary }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func testTheSourceSearchResultLandsAsItsOwnFindSourceStep() async throws {
        let model = try await makeModel()
        let id = try XCTUnwrap(model.addRetouchSpot(atNormalized: (0.5, 0.5), radius: 0.02))
        let found = await waitForStep(model, "Find Source")
        // Deterministic on this fixture (the search finds a source on flat gray — observed, 0.04 s), so a missing step is a FAILURE,
        // not a skip: a skip here would let a regression to the coalescing path pass silently.
        guard found else { return XCTFail("no 'Find Source' step appeared — the search result is not committed as its own step") }
        let entries = model.historyEntries
        XCTAssertEqual(entries.last?.summary, "Find Source")
        XCTAssertEqual(entries.dropLast().last?.summary, "Add Spot", "the click and its source are two steps")
        let spotAfter = try XCTUnwrap(model.editState.retouchSpots.first { $0.id == id })
        let spotBefore = try XCTUnwrap(entries.dropLast().last?.state.retouchSpots.first { $0.id == id })
        XCTAssertNotEqual(spotAfter.sourceDX == spotBefore.sourceDX && spotAfter.sourceDY == spotBefore.sourceDY, true)
        // A coalesced edit right after is a SEPARATE step, never merged into the source write.
        model.editState.retouchSpots[0].feather = 0.9
        model.undo()   // flushes the pending feather burst as its own step, then undoes it
        XCTAssertEqual(model.editState.retouchSpots.first?.feather, spotAfter.feather)
        XCTAssertEqual(model.editState.retouchSpots.first?.sourceDX, spotAfter.sourceDX, "undo reverted only the feather edit")
        model.undo()
        XCTAssertEqual(model.editState.retouchSpots.first?.sourceDX, spotBefore.sourceDX, "the next undo reverts only the source")
        XCTAssertEqual(model.editState.retouchSpots.count, 1, "the spot is still there")
    }

    /// click A, click B, undo (B is on the redo stack): A's late source result must not wipe the redo of B.
    func testALateSourceResultNeverWipesTheRedoStack() async throws {
        let model = try await makeModel()
        model.addRetouchSpot(atNormalized: (0.2, 0.2), radius: 0.02)
        let b = try XCTUnwrap(model.addRetouchSpot(atNormalized: (0.8, 0.8), radius: 0.02))
        model.undo()
        XCTAssertTrue(model.canRedo)
        try await Task.sleep(nanoseconds: 600_000_000)   // both searches land (A's real, B's dropped: B no longer exists)
        XCTAssertTrue(model.canRedo, "the background result must not truncate the redo branch")
        XCTAssertFalse(model.historyEntries.contains { $0.summary == "Find Source" })
        model.redo()
        XCTAssertTrue(model.editState.retouchSpots.contains { $0.id == b }, "redo still brings the second spot back")
    }

    func testAClickWhileAPhotoIsLoadingIsRefused() async throws {
        let model = try await makeModel()
        let url = dir.appendingPathComponent("second.png")
        let base = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        try CIContext().writePNGRepresentation(of: base, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let load = Task { await model.load(from: url) }
        var sawLoading = false
        for _ in 0..<200 where !sawLoading {
            await Task.yield()
            sawLoading = model.isLoadInFlight
        }
        try XCTSkipUnless(sawLoading, "the load finished before it could be observed in flight")
        XCTAssertNil(model.addRetouchSpot(atNormalized: (0.5, 0.5), radius: 0.02))
        XCTAssertNotNil(model.retouchMessage)
        await load.value
        XCTAssertTrue(model.editState.retouchSpots.isEmpty)
    }
}

