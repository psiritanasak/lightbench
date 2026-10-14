import CoreImage
import XCTest
@testable import PhotoApp

/// Compare / Survey through the model: per-photo slots, the key gate that generalises `imagePhotoID`, Esc ordering and the key table.
@MainActor
final class CullModesModelTests: XCTestCase {
    private var tempDir: URL!
    private var rows: [Int64: Photo] = [:]
    private var order: [Int64] = []
    private var writes: [String] = []

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CullModesModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        rows = [:]; order = []; writes = []
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func addPhotos(_ n: Int) throws {
        for i in 1...n {
            let id = Int64(i)
            let image = CIImage(color: CIColor(red: 0.05 * Double(i), green: 0.6, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 900, height: 600))
            let url = tempDir.appendingPathComponent("p\(i).png")
            try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            rows[id] = Photo(id: id, path: url.path, filename: url.lastPathComponent, fileSize: nil, importedAt: Date(timeIntervalSince1970: 0))
            order.append(id)
        }
    }

    private func makeModel() -> CullModel {
        let model = CullModel()
        model.configure(CullEnvironment(
            photos: { self.order.compactMap { self.rows[$0] } },
            rows: { self.rows },
            setRating: { value, photo in self.rows[photo.id!]?.rating = value; self.writes.append("rating \(photo.id!)=\(value)") },
            setFlag: { value, photo in self.rows[photo.id!]?.flagStatus = value; self.writes.append("flag \(photo.id!)=\(value)") },
            setLabel: { value, photo in self.rows[photo.id!]?.colorLabel = value; self.writes.append("label \(photo.id!)=\(value)") },
            thumbnail: { _ in nil }))
        return model
    }

    private func waitForLoupe(_ model: CullModel) async {
        for _ in 0..<600 { if model.showsCurrentPhoto, !model.isPlaceholder { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("the loupe preview never loaded")
    }

    /// Waits until every visible photo has its picture.
    private func waitForSlots(_ model: CullModel) async {
        for _ in 0..<800 {
            let ids = model.session?.visibleIDs ?? []
            if !ids.isEmpty, ids.allSatisfy({ model.slots[$0]?.image != nil && model.slots[$0]?.isPlaceholder == false }) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the Compare / Survey previews never loaded")
    }

    // MARK: Key table

    func testTheNewKeysMapToTheirActionsAndOldOnesAreUnchanged() {
        XCTAssertEqual(CullKeyAction.action(for: .character("c")), .toggleCompare)
        XCTAssertEqual(CullKeyAction.action(for: .character("N")), .toggleSurvey)
        XCTAssertEqual(CullKeyAction.action(for: .character("/")), .removeFromSurvey)
        XCTAssertEqual(CullKeyAction.action(for: .upArrow), .swapCompare)
        XCTAssertEqual(CullKeyAction.action(for: .downArrow), .makeSelect)
        XCTAssertEqual(CullKeyAction.action(for: .leftArrow), .previous)
        XCTAssertEqual(CullKeyAction.action(for: .character("p")), .command(.flag(.picked)))
        XCTAssertEqual(CullKeyAction.action(for: .character("0")), .command(.rating(0)))
        XCTAssertEqual(CullKeyAction.action(for: .escape), .exit)
    }

    // MARK: Compare

    func testCompareLoadsBothPicturesAndKeysActOnTheCandidateOnlyOnceItsPictureIsThere() async throws {
        try addPhotos(5)
        let model = makeModel()
        model.begin(startingAtPath: rows[2]!.path)
        await waitForLoupe(model)

        model.handle(.toggleCompare)
        XCTAssertEqual(model.session?.mode, .compare)
        XCTAssertEqual(model.session?.visibleIDs, [2, 3])
        XCTAssertNil(model.slots[3]?.image, "the candidate's picture is not there yet")
        XCTAssertFalse(model.canActOnCurrent)
        model.handle(.command(.flag(.picked)))
        XCTAssertTrue(writes.isEmpty, "a key pressed before the candidate's picture is on screen must not change any photo")

        await waitForSlots(model)
        XCTAssertTrue(model.canActOnCurrent)
        model.handle(.command(.rating(4)))
        XCTAssertEqual(writes, ["rating 3=4"], "the candidate (3), never the select (2)")
        model.end()
    }

    func testSwapAndMakeSelectReloadAndStayGated() async throws {
        try addPhotos(5)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await waitForLoupe(model)
        model.handle(.toggleCompare)             // select 1, candidate 2
        await waitForSlots(model)
        model.handle(.swapCompare)               // select 2, candidate 1
        XCTAssertEqual([model.session?.selectID, model.session?.currentID], [2, 1])
        await waitForSlots(model)
        model.handle(.makeSelect)                // the candidate (1) becomes the select; the new candidate is the next photo not on the select (2)
        XCTAssertEqual(model.session?.selectID, 1)
        XCTAssertEqual(model.session?.currentID, 2)
        await waitForSlots(model)
        XCTAssertEqual(Set(model.slots.keys), [1, 2], "slots of photos that left the screen are dropped")
        model.end()
    }

    func testTheSurveyGateRefusesKeysUntilTheFocusedCellsPictureIsThereAndTheLoupeGateFollowsOnReturn() async throws {
        try addPhotos(5)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await waitForLoupe(model)
        model.handle(.toggleSurvey)
        XCTAssertNil(model.slots[1]?.image)
        model.handle(.command(.rating(3)))
        XCTAssertTrue(writes.isEmpty, "the focused cell has no picture yet")
        await waitForSlots(model)
        model.handle(.next)                      // focus 2, then back to the loupe on a photo whose loupe picture is not loaded
        model.handle(.exit)
        XCTAssertEqual(model.session?.mode, .loupe)
        XCTAssertTrue(model.slots.isEmpty, "the cells' pictures are released in the loupe")
        model.handle(.command(.rating(5)))
        XCTAssertTrue(writes.isEmpty, "the loupe gate refuses keys until the current photo's picture is on screen (imagePhotoID follows)")
        await waitForLoupe(model)
        model.handle(.command(.rating(5)))
        XCTAssertEqual(writes, ["rating 2=5"])
        model.end()
    }

    func testTheUnflaggedOnlyToggleWhileInAModeReturnsToTheLoupeAndReloads() async throws {
        try addPhotos(4)
        rows[3]?.flagStatus = .picked
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await waitForLoupe(model)
        model.handle(.toggleCompare)
        await waitForSlots(model)
        model.setOnlyUnflagged(false)
        XCTAssertEqual(model.session?.mode, .loupe)
        XCTAssertTrue(model.slots.isEmpty)
        await waitForLoupe(model)
        XCTAssertTrue(model.canActOnCurrent)
        model.end()
    }

    func testSurveyEndOfPageSaysPageNotList() async throws {
        try addPhotos(14)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await waitForLoupe(model)
        model.handle(.toggleSurvey)              // page = photos 1...12 of 14
        for _ in 0..<11 { model.handle(.next) }
        model.handle(.next)
        XCTAssertEqual(model.note, "End of page")
        model.handle(.exit)
        await waitForLoupe(model)
        model.end()
    }

    func testEscapeLeavesCompareThenSurveyThenThePass() async throws {
        try addPhotos(4)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await waitForLoupe(model)
        model.handle(.toggleCompare)
        XCTAssertEqual(model.handle(.exit), .done)
        XCTAssertEqual(model.session?.mode, .loupe)
        model.handle(.toggleSurvey)
        XCTAssertEqual(model.handle(.exit), .done)
        XCTAssertEqual(model.session?.mode, .loupe)
        XCTAssertEqual(model.handle(.exit), .exit)
        model.end()
    }

    func testToggleKeysTogglePressingCTwiceReturnsToTheLoupe() async throws {
        try addPhotos(3)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await waitForLoupe(model)
        model.handle(.toggleCompare); model.handle(.toggleCompare)
        XCTAssertEqual(model.session?.mode, .loupe)
        model.handle(.toggleSurvey); model.handle(.toggleSurvey)
        XCTAssertEqual(model.session?.mode, .loupe)
        await waitForLoupe(model)
        model.end()
    }

    func testOnePhotoCannotCompareOrSurveyAndSaysSo() async throws {
        try addPhotos(1)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await waitForLoupe(model)
        model.handle(.toggleCompare)
        XCTAssertEqual(model.session?.mode, .loupe)
        XCTAssertEqual(model.note, "Needs at least two photos")
        model.end()
    }

    // MARK: Survey

    func testSurveyShowsTheWholePageAndKeysActOnTheFocusedCell() async throws {
        try addPhotos(6)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await waitForLoupe(model)
        model.handle(.toggleSurvey)
        await waitForSlots(model)
        XCTAssertEqual(Set(model.slots.keys), [1, 2, 3, 4, 5, 6])
        model.handle(.next)
        model.handle(.next)                      // focus 3
        model.handle(.command(.flag(.rejected))) // acts on 3, then auto-advances the focus to 4
        XCTAssertEqual(writes, ["flag 3=rejected"])
        XCTAssertEqual(model.session?.currentID, 4)
        model.handle(.removeFromSurvey)
        XCTAssertEqual(model.session?.surveyIDs, [1, 2, 3, 5, 6])
        await waitForSlots(model)
        XCTAssertNil(model.slots[4], "a removed photo's slot is dropped")
        model.end()
    }

    func testClickingACellFocusesItInSurveyAndTheSelectSwapsInCompare() async throws {
        try addPhotos(5)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await waitForLoupe(model)
        model.handle(.toggleSurvey)
        await waitForSlots(model)
        model.focus(on: 4)
        XCTAssertEqual(model.session?.currentID, 4)
        model.focus(on: 99)
        XCTAssertEqual(model.session?.currentID, 4, "an id that is not on the page is ignored")
        model.setMode(.compare)                  // select 4, candidate 5
        await waitForSlots(model)
        model.focus(on: 4)                       // clicking the select swaps
        XCTAssertEqual([model.session?.selectID, model.session?.currentID], [5, 4])
        model.end()
    }

    func testEndClearsTheSlotsAndAFreshPassStartsInTheLoupe() async throws {
        try addPhotos(3)
        let model = makeModel()
        model.begin(startingAtPath: nil)
        await waitForLoupe(model)
        model.handle(.toggleSurvey)
        await waitForSlots(model)
        model.end()
        XCTAssertTrue(model.slots.isEmpty)
        model.begin(startingAtPath: nil)
        XCTAssertEqual(model.session?.mode, .loupe)
        model.end()
    }

    // MARK: Layout maths

    func testTheSurveyGridFitsEveryPhotoWithAtMostFourColumns() {
        for count in 1...12 {
            for area in [CGSize(width: 1600, height: 900), CGSize(width: 700, height: 1000), CGSize(width: 1000, height: 1000)] {
                let grid = CullLayout.grid(count: count, area: area)
                XCTAssertGreaterThanOrEqual(grid.columns * grid.rows, count, "count \(count) in \(area)")
                XCTAssertLessThanOrEqual(grid.columns, 4)
                XCTAssertLessThan((grid.rows - 1) * grid.columns, count, "no entirely empty row")
            }
        }
        XCTAssertEqual(CullLayout.grid(count: 1, area: CGSize(width: 800, height: 600)).columns, 1)
        XCTAssertGreaterThan(CullLayout.grid(count: 12, area: CGSize(width: 1600, height: 900)).columns,
                             CullLayout.grid(count: 12, area: CGSize(width: 600, height: 1200)).columns, "a wide window gets more columns than a tall one")
        XCTAssertGreaterThan(CullLayout.cellLongEdge(area: CGSize(width: 1600, height: 900), count: 2), CullLayout.cellLongEdge(area: CGSize(width: 1600, height: 900), count: 12))
    }

    // MARK: Wiring

    func testTheViewHasTheModePickerAndKeepsItsKeySafetyPins() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/UI/CullView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("CullViewMode.compare") && view.contains("CullViewMode.survey"))
        XCTAssertTrue(view.contains("press.phase == .repeat"))
        XCTAssertTrue(view.contains("case .previous, .next: break"))
        XCTAssertTrue(view.contains("model.setViewArea("))
    }
}
