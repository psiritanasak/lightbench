import AppKit
import XCTest
@testable import PhotoApp

/// A symbol name that does not exist on the running macOS renders as nothing — and the rail's action entries are icon-only, so a
/// wrong name is a blank button (this happened with `square.grid.3x1`, which is not a real symbol).
final class EditorRailActionsSymbolTests: XCTestCase {
    func testEveryActionSymbolIsARealSystemSymbol() {
        for name in EditorRailActions.Symbol.all {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "\(name) is not a system symbol")
        }
    }

    func testTheSevenActionsHaveSevenDistinctSymbols() {
        XCTAssertEqual(EditorRailActions.Symbol.all.count, 7)
        XCTAssertEqual(Set(EditorRailActions.Symbol.all).count, 7)
    }
}
