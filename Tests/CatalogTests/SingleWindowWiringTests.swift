import XCTest

/// The app has ONE set of models, so a second main window is a blank duplicate. Pins the two lines that keep it single (a Finder / Dock
/// open used to add a window each time; live-checked 2026-10-19).
final class SingleWindowWiringTests: XCTestCase {
    func testMainWindowTakesExternalEventsAndThereIsNoNewWindowItem() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/App/PhotoAppApp.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".handlesExternalEvents(preferring: [\"*\"], allowing: [\"*\"])"))
        XCTAssertTrue(source.contains("CommandGroup(replacing: .newItem) {}"))
    }
}
