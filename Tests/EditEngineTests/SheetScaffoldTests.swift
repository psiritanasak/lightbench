import SwiftUI
import XCTest
@testable import PhotoApp

/// C2: the shared sheet layout. The footer rules are pure (order and key bindings), the sizes and colours are tokens, and one offscreen
/// render shows the title, the footer buttons and that nothing but the primary button is blue.
@MainActor
final class SheetScaffoldTests: XCTestCase {
    func testSizesAreTheThreeTokenWidthsInOrder() {
        XCTAssertEqual(SheetSize.small.width, 460)
        XCTAssertEqual(SheetSize.medium.width, 580)
        XCTAssertEqual(SheetSize.large.width, 780)
        XCTAssertLessThan(SheetSize.small.width, SheetSize.medium.width)
        XCTAssertLessThan(SheetSize.medium.width, SheetSize.large.width)
    }

    func testDoneAloneIsFlatAndAnswersToReturnWithAHiddenEscape() {
        let buttons = SheetFooterRules.buttons(for: .done())
        XCTAssertEqual(buttons, [SheetButtonSpec(title: "Done", prominent: false, shortcut: .defaultAction, enabled: true, isPrimary: false)])
        XCTAssertTrue(SheetFooterRules.needsHiddenEscape(for: .done()))
    }

    func testDoneWithoutReturnIsTheEscapeButtonItself() {
        let buttons = SheetFooterRules.buttons(for: .done(returnKey: false))
        XCTAssertEqual(buttons.map(\.shortcut), [.cancelAction])
        XCTAssertFalse(SheetFooterRules.needsHiddenEscape(for: .done(returnKey: false)))
    }

    func testCommitIsCancelThenTheProminentVerb() {
        let buttons = SheetFooterRules.buttons(for: .commit(verb: "Save"))
        XCTAssertEqual(buttons.map(\.title), ["Cancel", "Save"], "macOS order: the primary action last")
        XCTAssertEqual(buttons.map(\.prominent), [false, true])
        XCTAssertEqual(buttons.map(\.shortcut), [.cancelAction, .defaultAction])
        XCTAssertEqual(buttons.map(\.isPrimary), [false, true])
        XCTAssertFalse(SheetFooterRules.needsHiddenEscape(for: .commit(verb: "Save")))
    }

    func testACommitCanOptOutOfReturnForADestructiveVerb() {
        let buttons = SheetFooterRules.buttons(for: .commit(verb: "Copy and Trash Originals", primaryIsDefault: false))
        XCTAssertEqual(buttons.map(\.shortcut), [.cancelAction, .none], "no default button: one stray Return must not trash anything")
    }

    func testDoneAndApplyIsFlatDoneThenProminentVerbWithNoReturn() {
        let actions = SheetActions.doneAndApply(verb: "Apply", enabled: false, doneEnabled: false)
        let buttons = SheetFooterRules.buttons(for: actions)
        XCTAssertEqual(buttons.map(\.title), ["Done", "Apply"])
        XCTAssertEqual(buttons.map(\.prominent), [false, true])
        XCTAssertEqual(buttons.map(\.shortcut), [.cancelAction, .none], "the body owns Return; Apply is never the default")
        XCTAssertEqual(buttons.map(\.enabled), [false, false])
        XCTAssertEqual(buttons.map(\.isPrimary), [false, true])
        XCTAssertFalse(SheetFooterRules.needsHiddenEscape(for: actions))
        XCTAssertEqual(SheetFooterRules.buttons(for: .doneAndApply(verb: "Apply")).map(\.enabled), [true, true])
    }

    func testStatusClassificationOfModelMessages() {
        XCTAssertNil(SheetStatus.classifying(nil))
        XCTAssertEqual(SheetStatus.classifying("Rejected 3 photos.")?.tone, .info)
        XCTAssertEqual(SheetStatus.classifying("The scan failed: x")?.tone, .error)
        XCTAssertEqual(SheetStatus.classifying("Couldn't apply the stacks: x")?.tone, .error)
        XCTAssertEqual(SheetStatus.classifying("Nothing to reject.")?.tone, .caution)
        XCTAssertEqual(SheetStatus.classifying("Cancelled. Nothing was changed.")?.tone, .caution)
        XCTAssertEqual(SheetStatus.classifying("The photos aren't ready")?.tone, .info, "different wording stays plain info")
        XCTAssertEqual(SheetStatus.classifying("Photo isn't ready yet")?.tone, .error)
        XCTAssertEqual(SheetStatus.classifying("There are no photos to compare.")?.tone, .caution)
        XCTAssertEqual(SheetStatus.classifying("2 could not be compared (no face print).")?.tone, .caution)
        XCTAssertEqual(SheetStatus.classifying("The gap changed; scan again.")?.tone, .caution)
        XCTAssertEqual(SheetStatus.classifying("Scan in progress")?.tone, .caution)
        XCTAssertEqual(SheetStatus.classifying("Created 3 stacks.")?.tone, .info, "a success must stay info")
        XCTAssertEqual(SheetStatus.classifying("Selected 5 similar faces.")?.tone, .info)
    }

    func testEveryRecentlyDeletedOutcomeHasADeliberateTone() {
        typealias M = RecentlyDeletedModel
        XCTAssertEqual(M.tone(for: .restored(DeletedPhotoRestoreReport())), .info)
        XCTAssertEqual(M.tone(for: .restored(DeletedPhotoRestoreReport(missingCollections: ["Trips"]))), .caution, "a partial restore")
        for refusal in [DeletedPhotoRestoreOutcome.notFound, .fileMissing, .editFileMissing] {
            XCTAssertEqual(M.tone(for: refusal), .caution, "\(refusal): the user has something to do first")
        }
        for failure in [DeletedPhotoRestoreOutcome.pathInUse, .masterMissing, .idInUse] {
            XCTAssertEqual(M.tone(for: failure), .error, "\(failure): it cannot be restored")
        }
    }

    func testEnabledFlagsReachTheButtons() {
        let buttons = SheetFooterRules.buttons(for: .commit(verb: "Rename", enabled: false, cancelEnabled: false))
        XCTAssertEqual(buttons.map(\.enabled), [false, false])
    }

    func testStatusToneColoursAreThreeDifferentTokens() {
        XCTAssertEqual(SheetFooterRules.color(for: .info), Theme.textSecondary)
        XCTAssertEqual(SheetFooterRules.color(for: .caution), Theme.warning)
        XCTAssertEqual(SheetFooterRules.color(for: .error), Theme.error)
        XCTAssertNotEqual(Theme.error, Theme.warning)
        XCTAssertNotEqual(Theme.error, Theme.textSecondary)
    }

    func testErrorIsARedReadableOnThePanel() throws {
        let c = try XCTUnwrap(NSColor(Theme.error).usingColorSpace(.sRGB))
        XCTAssertGreaterThan(c.redComponent, c.greenComponent + 0.3)
        XCTAssertGreaterThan(c.redComponent, c.blueComponent + 0.3)
        XCTAssertGreaterThan(c.redComponent, 0.8, "bright enough on the 0.11 grey panel")
    }

    // MARK: rendering

    private func render<V: View>(_ view: V, size: CGSize) -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.background(Theme.panel).environment(\.colorScheme, .dark).tint(Theme.controlTint)
            .frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private func count(_ rep: NSBitmapImageRep, _ predicate: (NSColor) -> Bool) -> Int {
        var n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), predicate(c) { n += 1 }
            }
        }
        return n
    }

    private func isBlue(_ c: NSColor) -> Bool { c.blueComponent > c.redComponent + 0.25 && c.blueComponent > 0.5 }
    private func isLight(_ c: NSColor) -> Bool { c.redComponent > 0.6 && c.greenComponent > 0.6 && c.blueComponent > 0.6 }
    private func isError(_ c: NSColor) -> Bool { c.redComponent > 0.75 && c.greenComponent < 0.55 && c.blueComponent < 0.5 }

    func testACommitSheetDrawsATitleAFooterAndOnePrimaryButton() {
        let sheet = SheetScaffold(title: "Rename 3 Photos", size: .small, actions: .commit(verb: "Rename"), onDismiss: {}) {
            Text("Body text").frame(height: 60)
        }
        let rep = render(sheet, size: CGSize(width: 520, height: 200))
        XCTAssertGreaterThan(count(rep) { self.isLight($0) }, 300, "title, body and button labels are drawn")
        XCTAssertGreaterThan(count(rep) { self.isBlue($0) }, 200, "the prominent verb is the one blue thing")
    }

    func testADoneOnlySheetHasNoBlue() {
        let sheet = SheetScaffold(title: "Keywords", size: .small, actions: .done(), onDismiss: {}) { Text("Body").frame(height: 60) }
        let rep = render(sheet, size: CGSize(width: 520, height: 200))
        XCTAssertEqual(count(rep) { self.isBlue($0) }, 0)
    }

    func testAnErrorStatusIsDrawnInTheErrorColour() {
        let sheet = SheetScaffold(title: "Rename", size: .small, status: SheetStatus(text: "The template is not valid", tone: .error),
                                  actions: .commit(verb: "Rename", enabled: false), onDismiss: {}) { Text("Body").frame(height: 60) }
        let rep = render(sheet, size: CGSize(width: 520, height: 200))
        XCTAssertGreaterThan(count(rep) { self.isError($0) }, 40)
    }

    // MARK: Source lint (C2): every sheet uses the scaffold

    /// The nine sheet views (one per `.sheet(` site; `AlertSitesTests` pins that count). A new sheet must use `SheetScaffold` and be added here.
    private static let sheetFiles = [
        "KeywordSheetView", "InfoSheetView", "RecentlyDeletedSheetView", "DuplicatesSheetView", "AutoStackSheetView", "PeopleSheetView",
        "RenameSheetView", "ImportCopyDialogModifier", "ExportOptionsView",
    ]

    private func uiSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/UI/\(name).swift"), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }.joined(separator: "\n")
    }

    func testEverySheetViewUsesTheScaffold() throws {
        for name in Self.sheetFiles {
            XCTAssertTrue(try uiSource(name).contains("SheetScaffold("), "\(name) must lay itself out with SheetScaffold")
        }
    }

    func testNoSheetUsesARawRedForText() throws {
        for name in Self.sheetFiles {
            let text = try uiSource(name)
            XCTAssertFalse(text.contains(".foregroundStyle(.red"), "\(name): errors use Theme.error")
            XCTAssertFalse(text.contains("Color.red"), "\(name): errors use Theme.error")
        }
    }

    func testTheScaffoldItselfPresentsNothingAndNamesNoAccent() throws {
        let text = try uiSource("SheetScaffold")
        XCTAssertFalse(text.contains(".sheet("))
        XCTAssertFalse(text.contains(".alert("))
        XCTAssertFalse(text.contains("Theme.accent"))
    }
}
