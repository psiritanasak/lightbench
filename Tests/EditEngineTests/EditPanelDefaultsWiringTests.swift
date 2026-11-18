import SwiftUI
import XCTest
@testable import PhotoApp

/// Source pins for wiring that behaviour tests cannot reach (the launch initializer, the persist line, the single panel write).
final class EditPanelDefaultsWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func count(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testContentViewReadsTheStoredSectionsAtLaunch() throws {
        let text = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(text.contains("AdjustSectionExpansion(stored: AppPreferences.shared.editPanelOpenSections)"))
    }

    func testAdjustTabViewPersistsInOnePlace() throws {
        let text = try source("Sources/UI/AdjustTabView.swift")
        XCTAssertEqual(count(of: "AppPreferences.shared.editPanelOpenSections = sections.stored", in: text), 1)
    }

    func testTheEditTabBoolsAreGoneAndTheLooksFlagsRemain() throws {
        let text = try source("Sources/UI/AdjustTabView.swift")
        for name in ["Light", "Curve", "Color", "SelectiveColor", "BlackAndWhite", "ColorGrading", "Effects", "Raw", "PointColor"] {
            XCTAssertFalse(text.contains("is\(name)SectionExpanded"), "is\(name)SectionExpanded is obsolete")
        }
        for kept in ["isPresetsSectionExpanded", "isLooksSectionExpanded", "isStyleSectionExpanded"] {
            XCTAssertTrue(text.contains("var \(kept)"), "\(kept) stays in the struct")
        }
        XCTAssertFalse(text.contains("pointColorSectionExpandedBinding"))
    }

    func testSetSectionsWritesPanelOnce() throws {
        let text = try source("Sources/UI/AdjustTabView.swift")
        let start = try XCTUnwrap(text.range(of: "private func setSections"))
        let end = try XCTUnwrap(text.range(of: "private func expandedBinding", range: start.upperBound..<text.endIndex))
        let body = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertEqual(count(of: "panel = next", in: body), 1)
        XCTAssertTrue(body.contains("interactionMode.disarmPointColorPick()"))
    }

    func testHeaderClickTable() {
        typealias C = AdjustSectionContainer<EmptyView>
        XCTAssertEqual(C.headerClick(optionHeld: false, canSolo: false), .toggle)
        XCTAssertEqual(C.headerClick(optionHeld: false, canSolo: true), .toggle)
        XCTAssertEqual(C.headerClick(optionHeld: true, canSolo: false), .toggle)
        XCTAssertEqual(C.headerClick(optionHeld: true, canSolo: true), .solo)
    }

    func testSoloIsEditTabOnlyAndGoesThroughSetSections() throws {
        XCTAssertFalse(try source("Sources/UI/LooksTabView.swift").contains("onSolo"))
        let text = try source("Sources/UI/AdjustTabView.swift")
        let start = try XCTUnwrap(text.range(of: "private func section<Content: View>("))
        let end = try XCTUnwrap(text.range(of: "private func setSections", range: start.upperBound..<text.endIndex))
        XCTAssertTrue(String(text[start.lowerBound..<end.lowerBound]).contains("onSolo: { setSections { $0.solo(section) } }"))
    }
}
