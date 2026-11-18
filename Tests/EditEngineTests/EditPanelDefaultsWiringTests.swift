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

    // MARK: One histogram

    private func codeOnly(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            guard let range = line.range(of: "//") else { return line }
            return String(line[..<range.lowerBound])
        }.joined(separator: "\n")
    }

    func testHistogramViewIsDrawnOnlyByThePinnedHeader() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = codeOnly(try String(contentsOf: file, encoding: .utf8))
            let n = count(of: "HistogramView(", in: text)
            if file.lastPathComponent == "EditorHistogramHeader.swift" {
                XCTAssertEqual(n, 1)
            } else {
                XCTAssertEqual(n, 0, "\(file.lastPathComponent) must not draw its own HistogramView")
            }
        }
    }

    func testAdjustTabViewDoesNotReadTheHistogramModeAndContentViewBindsIt() throws {
        // The mode value itself still lives in `AdjustPanelState` (declared in AdjustTabView.swift); only its use as a control is gone.
        let adjust = codeOnly(try source("Sources/UI/AdjustTabView.swift"))
        XCTAssertFalse(adjust.contains("panel.histogramDisplayMode"))
        XCTAssertFalse(adjust.contains("HistogramDisplayMode.allCases"))
        XCTAssertTrue(try source("Sources/UI/ContentView.swift").contains("mode: $adjustPanel.histogramDisplayMode"))
    }

    /// B2: the Edit sidebar shows its scroll bar (user decision 2026-11-17), set right before the tab scroll memory.
    func testTheEditSidebarShowsItsScrollBar() throws {
        let content = try source("Sources/UI/ContentView.swift")
        XCTAssertEqual(count(of: ".scrollIndicators(.hidden)", in: content), 0)
        XCTAssertTrue(content.contains(".scrollIndicators(.visible)\n        .tabScrollMemory(tab: selectedTab, memory: $tabMemory)"))
    }
}
