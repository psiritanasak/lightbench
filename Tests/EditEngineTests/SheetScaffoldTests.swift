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
}
