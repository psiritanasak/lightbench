import CoreImage
import XCTest
@testable import PhotoApp

/// Stack-aware Cull through the model: the `S` key, the environment's stacks, notes, refusals and the wiring in the views.
@MainActor
final class CullStackModelTests: XCTestCase {
    private var tempDir: URL!
    private var rows: [Int64: Photo] = [:]
    private var order: [Int64] = []
    private var writes: [String] = []
    private var stacks: [StackSnapshot] = []
    private var expanded: Set<Int64> = []

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CullStackModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        rows = [:]; order = []; writes = []; stacks = []; expanded = []
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func addPhotos(_ n: Int) throws {
        for i in 1...n {
            let id = Int64(i)
            let image = CIImage(color: CIColor(red: 0.05 * Double(i), green: 0.6, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
            let url = tempDir.appendingPathComponent("p\(i).png")
            try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            rows[id] = Photo(id: id, path: url.path, filename: url.lastPathComponent, fileSize: nil, importedAt: Date(timeIntervalSince1970: 0))
            order.append(id)
        }
    }

    private func makeModel() -> CullModel {
        let model = CullModel()
        model.preferences = AppPreferences(defaults: UserDefaults(suiteName: "CullStackModelTests-\(UUID().uuidString)")!)
        model.configure(CullEnvironment(
            photos: { self.order.compactMap { self.rows[$0] } },
            rows: { self.rows },
            setRating: { value, photo in self.rows[photo.id!]?.rating = value; self.writes.append("rating \(photo.id!)=\(value)") },
            setFlag: { value, photo in self.rows[photo.id!]?.flagStatus = value; self.writes.append("flag \(photo.id!)=\(value)") },
            setLabel: { value, photo in self.rows[photo.id!]?.colorLabel = value; self.writes.append("label \(photo.id!)=\(value)") },
            thumbnail: { _ in nil },
            stacks: { self.stacks },
            expandedStackIDs: { self.expanded }))
        return model
    }

    private func waitForLoupe(_ model: CullModel) async {
        for _ in 0..<600 { if model.showsCurrentPhoto, !model.isPlaceholder { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("the loupe preview never loaded")
    }

    // MARK: Keys

    func testSMapsToToggleStackAndNothingElseChanged() {
        XCTAssertEqual(CullKeyAction.action(for: .character("s")), .toggleStack)
        XCTAssertEqual(CullKeyAction.action(for: .character("S")), .toggleStack)
        XCTAssertEqual(CullKeyAction.action(for: .character("p")), .command(.flag(.picked)))
        XCTAssertEqual(CullKeyAction.action(for: .character("n")), .toggleSurvey)
    }

    // MARK: Pass

    func testThePassStartsOverTheCellsOfTheEnvironmentsStacks() throws {
        try addPhotos(6)
        stacks = [StackSnapshot(id: 10, isManual: true, coverPhotoID: 2, memberIDs: [2, 3, 4])]
        let model = makeModel()
        model.preferences.cullStartUnflaggedOnly = false
        XCTAssertTrue(model.begin(startingAtPath: nil))
        XCTAssertEqual(model.session?.ids, [1, 2, 5, 6])
        XCTAssertEqual(model.counts.unflagged, 6, "counts cover the hidden members")
    }

    func testStartingFromAHiddenMemberExpandsItsStack() throws {
        try addPhotos(6)
        stacks = [StackSnapshot(id: 10, isManual: true, coverPhotoID: 2, memberIDs: [2, 3, 4])]
        let model = makeModel()
        XCTAssertTrue(model.begin(startingAtPath: rows[3]!.path))
        XCTAssertEqual(model.session?.currentID, 3)
        XCTAssertEqual(model.session?.expandedInPass, [10])
        XCTAssertTrue(expanded.isEmpty, "the grid's own expansion is never written")
    }

    func testSExpandsAndCollapsesAndSaysSo() async throws {
        try addPhotos(5)
        stacks = [StackSnapshot(id: 10, isManual: true, coverPhotoID: 2, memberIDs: [2, 3])]
        let model = makeModel()
        model.begin(startingAtPath: rows[2]!.path)
        await waitForLoupe(model)
        model.handle(.toggleStack)
        XCTAssertEqual(model.session?.ids, [1, 2, 3, 4, 5])
        XCTAssertEqual(model.note, "Stack expanded")
        model.handle(.toggleStack)
        XCTAssertEqual(model.session?.ids, [1, 2, 4, 5])
        XCTAssertEqual(model.note, "Stack collapsed")
        XCTAssertTrue(expanded.isEmpty)
    }

    func testSOnAPlainPhotoSaysItIsNotInAStack() async throws {
        try addPhotos(4)
        stacks = [StackSnapshot(id: 10, isManual: true, coverPhotoID: 2, memberIDs: [2, 3])]
        let model = makeModel()
        model.begin(startingAtPath: rows[1]!.path)
        await waitForLoupe(model)
        model.handle(.toggleStack)
        XCTAssertEqual(model.note, "Not in a stack")
        XCTAssertEqual(model.session?.ids, [1, 2, 4])
    }

    func testSIsRefusedInCompareWithANote() async throws {
        try addPhotos(5)
        stacks = [StackSnapshot(id: 10, isManual: true, coverPhotoID: 2, memberIDs: [2, 3])]
        let model = makeModel()
        model.begin(startingAtPath: rows[2]!.path)
        await waitForLoupe(model)
        model.setMode(.compare)
        let before = model.session
        model.handle(.toggleStack)
        XCTAssertEqual(model.session, before)
        XCTAssertEqual(model.note, "Stacks open in the loupe")
    }

    func testAFlagOnACollapsedCoverWritesOnlyTheCoverAndNamesTheOthers() async throws {
        try addPhotos(6)
        stacks = [StackSnapshot(id: 10, isManual: true, coverPhotoID: 2, memberIDs: [2, 3, 4])]
        let model = makeModel()
        model.begin(startingAtPath: rows[2]!.path)
        await waitForLoupe(model)
        model.handle(.command(.flag(.picked)))
        XCTAssertEqual(writes, ["flag 2=picked"])
        XCTAssertEqual(model.note, "Picked · 2 others in this stack unchanged")
        XCTAssertEqual(rows[3]?.flagStatus, FlagStatus.none)
    }

    func testARatingNoteNamesTheOthersToo() async throws {
        try addPhotos(5)
        stacks = [StackSnapshot(id: 10, isManual: true, coverPhotoID: 2, memberIDs: [2, 3])]
        let model = makeModel()
        model.begin(startingAtPath: rows[2]!.path)
        await waitForLoupe(model)
        model.handle(.command(.rating(3)))
        XCTAssertEqual(model.note, "★★★ · 1 other in this stack unchanged")
    }

    func testUnflaggedToggleKeepsStacksFromTheEnvironment() async throws {
        try addPhotos(6)
        stacks = [StackSnapshot(id: 10, isManual: true, coverPhotoID: 2, memberIDs: [2, 3])]
        let model = makeModel()
        model.begin(startingAtPath: rows[1]!.path)
        await waitForLoupe(model)
        model.setOnlyUnflagged(false)
        XCTAssertEqual(model.session?.ids, [1, 2, 4, 5, 6])
    }

    // MARK: Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheViewsAndContentViewAreWired() throws {
        let view = try source("Sources/UI/CullView.swift")
        XCTAssertTrue(view.contains("S stack"), "the hint names the S key")
        XCTAssertTrue(view.contains("stackBadgeText(for:"), "the cell caption and loupe show the stack badge")
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("stacks: { catalog.stacks }"))
        XCTAssertTrue(content.contains("expandedStackIDs: { catalog.expandedStackIDs }"))
        XCTAssertTrue(try source("Sources/UI/CullModel.swift").contains("case .toggleStack"))
    }

    func testOnlyPreviousAndNextRepeat() throws {
        let view = try source("Sources/UI/CullView.swift")
        XCTAssertTrue(view.contains("case .previous, .next: break"), "S must not auto-repeat")
    }
}
