import XCTest
@testable import PhotoApp

/// Source pins for the Editor's Before / app-key wiring (B4). The behaviour itself is on the by-eye list; these keep the wiring from
/// being edited away silently.
final class EditorBeforeWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func body(of marker: String, in text: String, length: Int = 2500) throws -> String {
        let start = try XCTUnwrap(text.range(of: marker), "missing \(marker)")
        return String(text[start.lowerBound...].prefix(length))
    }

    func testTheImageCallSubstitutesTheOriginalStateForBefore() throws {
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("editState: compareMode == .before ? compareOriginalEditState : displayEditState, compare: compareRenderConfig"))
        let config = try body(of: "private var compareRenderConfig", in: content, length: 600)
        XCTAssertTrue(config.contains("case .off, .before:"))
    }

    func testTheZoomResetKeepsZoomForOffAndBeforeOnly() throws {
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(content.contains("guard CompareViewMode.resetsZoom(from: old, to: new) else { return }"))
    }

    func testAppKeysAreHandledFirstAndGatedOnTextFieldsAndSheets() throws {
        let content = try source("Sources/UI/ContentView.swift")
        let handler = try body(of: "private func handleImagePaneKeyPress", in: content, length: 1800)
        let appKey = try XCTUnwrap(handler.range(of: "handleAppKey(keyPress)"))
        let guardLine = try XCTUnwrap(handler.range(of: "let semanticModifiers"))
        XCTAssertLessThan(appKey.lowerBound, guardLine.lowerBound, "app keys must run before the modifier guard")
        let function = try body(of: "private func handleAppKey", in: content, length: 1500)
        XCTAssertTrue(function.contains("firstResponder is NSTextView"))
        XCTAssertTrue(function.contains("attachedSheet"))
        XCTAssertTrue(function.contains("catalog.editorPopoverOpen || isHistoryPresented"))
        XCTAssertTrue(function.contains("if keyPress.phase != .repeat { performViewCommand(command) }"), "a held key is swallowed, not repeated")
        XCTAssertTrue(function.contains("return .handled"))
        let editor = try body(of: "private var editorContent", in: content, length: 1400)
        XCTAssertTrue(editor.contains(".onKeyPress { keyPress in handleAppKey(keyPress) }"), "root handler for presses that bubble up")
    }

    func testPerformViewCommandRechecksTheRuleAndTheChipIsNotHittable() throws {
        let content = try source("Sources/UI/ContentView.swift")
        let perform = try body(of: "private func performViewCommand", in: content, length: 600)
        XCTAssertTrue(perform.contains("guard ViewCommandRules.isEnabled(command, context: viewCommandContext()) else { return }"))
        let keys = try source("Sources/UI/EditorViewKeys.swift")
        let chip = try body(of: "struct BeforeChip: View", in: keys, length: 500)
        XCTAssertTrue(chip.contains(".solidPanel(") && chip.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(content.contains(".modifier(BeforeChipOverlay(compareMode: compareMode))"))
        XCTAssertTrue(content.contains("armedAny: armedModes.any"))
    }

    func testCullDoesNotKnowTheAppKeys() throws {
        let cull = try source("Sources/UI/CullView.swift")
        XCTAssertFalse(cull.contains("AppKeyCommand") || cull.contains("AppKeyGate") || cull.contains("ViewCommand"))
    }

    func testAnnouncementsNameBothDirections() {
        XCTAssertEqual(EditorBeforeLifecycle.announcement(from: .off, to: .before), "Showing the original")
        XCTAssertEqual(EditorBeforeLifecycle.announcement(from: .sideBySide, to: .before), "Showing the original")
        XCTAssertEqual(EditorBeforeLifecycle.announcement(from: .before, to: .off), "Showing your edits")
        XCTAssertEqual(EditorBeforeLifecycle.announcement(from: .before, to: .sideBySide), "Showing your edits")
        XCTAssertNil(EditorBeforeLifecycle.announcement(from: .off, to: .split))
    }

    func testEnteringTheEditorFocusesThePaneUnlessATextFieldHasFocus() throws {
        let keys = try source("Sources/UI/EditorViewKeys.swift")
        let focus = try body(of: ".onChange(of: showLibrary)", in: keys, length: 500)
        XCTAssertTrue(focus.contains("firstResponder is NSTextView"))
        XCTAssertTrue(focus.contains("focusImagePane()"))
        XCTAssertTrue(focus.contains("if isShowingLibrary, compareMode == .before { compareMode = .off }"), "leaving for the Library ends Before")
        XCTAssertTrue(keys.contains("if armed, compareMode != .off { compareMode = .off }"))
    }
}
