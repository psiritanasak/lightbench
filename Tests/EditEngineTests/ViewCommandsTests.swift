import XCTest
@testable import PhotoApp

final class ViewCommandsTests: XCTestCase {
    private let allCommands: [ViewCommand] = [
        .showLibrary, .showEditor, .toggleBefore, .toggleSideBySide, .setCompare(.split), .selectTab(.looks),
        .toggleFilmstrip, .revertToOriginal, .export
    ]

    private func context(_ mode: PhotoActionContext.Mode) -> ViewCommandContext {
        var c = ViewCommandContext()
        c.mode = mode
        c.hasOpenImage = true
        c.canCompare = true
        c.canRevert = true
        c.canExport = true
        return c
    }

    private func enabled(_ command: ViewCommand, _ c: ViewCommandContext) -> Bool { ViewCommandRules.isEnabled(command, context: c) }

    // MARK: rules per mode

    func testRulesTablePerMode() {
        let library = context(.library)
        let editor = context(.editor)
        XCTAssertEqual(allCommands.map { enabled($0, library) }, [true, true, false, false, false, false, false, false, true])
        XCTAssertEqual(allCommands.map { enabled($0, editor) }, [true, true, true, true, true, true, true, true, false])
    }

    func testEverythingIsOffWhileCulling() {
        var c = context(.cull)
        for command in allCommands { XCTAssertFalse(enabled(command, c), "\(command)") }
        c.modalUp = false
        for tab in EditorTab.railTabs { XCTAssertFalse(enabled(.selectTab(tab), c)) }
    }

    func testModalOrPopoverDisablesTheModeSwitch() {
        for mode in [PhotoActionContext.Mode.library, .editor] {
            var c = context(mode)
            c.modalUp = true
            XCTAssertFalse(enabled(.showLibrary, c))
            XCTAssertFalse(enabled(.showEditor, c))
            c = context(mode)
            c.editorPopoverOpen = true
            XCTAssertFalse(enabled(.showLibrary, c))
            XCTAssertFalse(enabled(.showEditor, c))
        }
        var c = context(.editor)
        c.modalUp = true
        for command in allCommands { XCTAssertFalse(enabled(command, c), "\(command)") }
    }

    func testBeforeAndSideBySideFollowCanCompare() {
        var c = context(.editor)
        c.canCompare = false
        XCTAssertFalse(enabled(.toggleBefore, c))
        XCTAssertFalse(enabled(.toggleSideBySide, c))
        XCTAssertFalse(enabled(.setCompare(.sideBySide), c))
        XCTAssertTrue(enabled(.selectTab(.crop), c))
        c.canCompare = true
        XCTAssertTrue(enabled(.toggleBefore, c))
        XCTAssertTrue(enabled(.toggleSideBySide, c))
    }

    func testTabCommandsOnlyInTheEditorAndOnlyForRailTabs() {
        for tab in EditorTab.railTabs {
            XCTAssertTrue(enabled(.selectTab(tab), context(.editor)))
            XCTAssertFalse(enabled(.selectTab(tab), context(.library)))
        }
        XCTAssertFalse(enabled(.selectTab(.cleanUp), context(.editor)))
    }

    func testRevertNeedsEverythingQuiet() {
        var c = context(.editor)
        XCTAssertTrue(enabled(.revertToOriginal, c))
        c.canRevert = false
        XCTAssertFalse(enabled(.revertToOriginal, c))
        c = context(.editor); c.loadInFlight = true
        XCTAssertFalse(enabled(.revertToOriginal, c))
        c = context(.editor); c.renameWorking = true
        XCTAssertFalse(enabled(.revertToOriginal, c))
        c = context(.editor); c.editorPopoverOpen = true
        XCTAssertFalse(enabled(.revertToOriginal, c))
        XCTAssertFalse(enabled(.revertToOriginal, context(.library)))
    }

    func testExportIsLibraryOnlyAndFollowsCanExport() {
        var c = context(.library)
        XCTAssertTrue(enabled(.export, c))
        c.canExport = false
        XCTAssertFalse(enabled(.export, c))
        c = context(.library); c.renameWorking = true
        XCTAssertFalse(enabled(.export, c))
    }

    func testChecks() {
        var c = context(.editor)
        c.compareMode = .before
        XCTAssertTrue(ViewCommandRules.isChecked(.toggleBefore, context: c))
        XCTAssertFalse(ViewCommandRules.isChecked(.toggleSideBySide, context: c))
        XCTAssertFalse(ViewCommandRules.isChecked(.setCompare(.off), context: c))
        XCTAssertTrue(ViewCommandRules.isChecked(.setCompare(.before), context: c))
        c.selectedTab = .masks
        XCTAssertTrue(ViewCommandRules.isChecked(.selectTab(.masks), context: c))
        XCTAssertFalse(ViewCommandRules.isChecked(.selectTab(.looks), context: c))
        c.filmstripVisible = true
        XCTAssertTrue(ViewCommandRules.isChecked(.toggleFilmstrip, context: c))
    }

    // MARK: Compare transitions

    func testTransitionTable() {
        let all: [CompareViewMode] = [.off, .sideBySide, .split, .before]
        XCTAssertEqual(all.map { $0.toggledBefore() }, [.before, .before, .before, .off])
        XCTAssertEqual(all.map { $0.toggledSideBySide() }, [.sideBySide, .off, .sideBySide, .sideBySide])
        XCTAssertEqual(all.map(\.isComparing), [false, true, true, false])
        XCTAssertEqual(ViewCommandRules.compareMode(after: .toggleBefore, from: .split), .before)
        XCTAssertEqual(ViewCommandRules.compareMode(after: .setCompare(.off), from: .before), .off)
        XCTAssertNil(ViewCommandRules.compareMode(after: .showEditor, from: .off))
    }

    func testResetsZoomIsFalseOnlyForOffAndBefore() {
        let all: [CompareViewMode] = [.off, .sideBySide, .split, .before]
        for from in all {
            for to in all {
                let keeps = (from == .off && to == .before) || (from == .before && to == .off)
                XCTAssertEqual(CompareViewMode.resetsZoom(from: from, to: to), !keeps, "\(from) -> \(to)")
            }
        }
    }

    // MARK: App keys

    private var ascii: [Character] { (32...126).compactMap { UnicodeScalar($0).map(Character.init) } }

    func testAppKeysAreNilInCullAndNeverCollideWithPhotoKeys() {
        for ch in ascii {
            XCTAssertNil(AppKeyCommand.command(for: ch, mode: .cull), "\(ch)")
            for mode in [PhotoActionContext.Mode.library, .editor] {
                guard AppKeyCommand.command(for: ch, mode: mode) != nil else { continue }
                XCTAssertNil(PhotoKeyCommand.command(for: ch, allowsZero: true), "\(ch) is also a photo key")
                XCTAssertNotEqual(ch, "0")
                XCTAssertNotEqual(ch, " ")
            }
        }
    }

    func testTheAppKeyTable() {
        XCTAssertEqual(AppKeyCommand.command(for: "Y", mode: .editor), .toggleSideBySide)
        XCTAssertEqual(AppKeyCommand.command(for: "\\", mode: .editor), .toggleBefore)
        XCTAssertEqual(AppKeyCommand.command(for: "g", mode: .editor), .showLibrary)
        XCTAssertEqual(AppKeyCommand.command(for: "E", mode: .editor), .selectTab(.adjust))
        XCTAssertEqual(AppKeyCommand.command(for: "e", mode: .library), .showEditor)
        XCTAssertNil(AppKeyCommand.command(for: "g", mode: .library))
        XCTAssertNil(AppKeyCommand.command(for: "\\", mode: .library))
        let editorKeys = ascii.filter { AppKeyCommand.command(for: $0, mode: .editor) != nil }
        XCTAssertEqual(Set(editorKeys.map { Character($0.lowercased()) }), Set("geqlmry\\"))
    }

    func testTheGate() {
        func gate(command: Bool = false, control: Bool = false, option: Bool = false, shift: Bool = false,
                  text: Bool = false, modal: Bool = false, rep: Bool = false) -> ViewCommand? {
            AppKeyGate.resolve(character: "\\", mode: .editor, command: command, control: control, option: option, shift: shift,
                               textFieldFocused: text, modalUp: modal, isRepeat: rep)
        }
        XCTAssertEqual(gate(), .toggleBefore)
        XCTAssertEqual(gate(option: true), .toggleBefore, "German / French layouts type backslash with Option")
        XCTAssertEqual(gate(option: true, shift: true), .toggleBefore)
        XCTAssertNil(gate(command: true))
        XCTAssertNil(gate(control: true))
        XCTAssertNil(gate(text: true))
        XCTAssertNil(gate(modal: true))
        XCTAssertNil(gate(rep: true))
    }
}
