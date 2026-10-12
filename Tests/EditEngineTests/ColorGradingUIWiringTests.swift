import XCTest
@testable import PhotoApp

/// The Color Grading Blending/Balance rows live in `AdjustTabView` (private view code), so their wiring is pinned in the
/// source, the same approach as `MergeWiringTests`: the section shows both sliders, and the section-wide "is the Adjust tab
/// at identity" check and the Reset Adjustments action both include both fields (a miss would leave a hidden non-default
/// value behind, or make Reset look disabled while a slider is still moved).
final class ColorGradingUIWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func body(of marker: String, in text: String, length: Int = 6000) throws -> String {
        let start = try XCTUnwrap(text.range(of: marker), marker)
        return String(text[start.upperBound...].prefix(length))
    }

    func testTheSectionShowsBothGlobalSliders() throws {
        let view = try source("Sources/UI/AdjustTabView.swift")
        let section = try body(of: "private var colorGradingSection: some View {", in: view, length: 4500)
        XCTAssertTrue(section.contains("$document.editState.colorGradingBlending"))
        XCTAssertTrue(section.contains("$document.editState.colorGradingBalance"))
        XCTAssertTrue(section.contains("label: \"Blending\""))
        XCTAssertTrue(section.contains("label: \"Balance\""))
    }

    func testTheIdentityCheckAndTheResetActionIncludeBothFields() throws {
        let view = try source("Sources/UI/AdjustTabView.swift")
        let identity = try body(of: "private var isAdjustTabAtIdentity: Bool {", in: view)
        XCTAssertTrue(identity.contains("state.colorGradingBlending == 0"))
        XCTAssertTrue(identity.contains("state.colorGradingBalance == 0"))
        let reset = try body(of: "private var resetAdjustmentsButton: some View {", in: view)
        XCTAssertTrue(reset.contains("document.editState.colorGradingBlending = 0"))
        XCTAssertTrue(reset.contains("document.editState.colorGradingBalance = 0"))
    }

    func testThePerRangeResetLeavesTheGlobalSlidersAlone() throws {
        let view = try source("Sources/UI/AdjustTabView.swift")
        let section = try body(of: "private var colorGradingSection: some View {", in: view, length: 4500)
        let perRange = try XCTUnwrap(section.range(of: "Button(\"Reset \\(panel.selectedColorGradingRange.rawValue)\")"))
        let buttonBody = String(section[perRange.upperBound...].prefix(500).prefix { _ in true })
        let closing = try XCTUnwrap(buttonBody.range(of: ".buttonStyle("))
        XCTAssertFalse(String(buttonBody[..<closing.lowerBound]).contains("colorGradingBlending"), "the per-range Reset must not touch Blending")
        XCTAssertFalse(String(buttonBody[..<closing.lowerBound]).contains("colorGradingBalance"))
    }
}

/// Vignette Softness wiring (same source-pinning approach).
final class VignetteSoftnessWiringTests: XCTestCase {
    func testTheRowTheIdentityCheckAndResetAllKnowTheField() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI/AdjustTabView.swift")
        let view = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(view.contains("label: \"Vignette Softness\", value: $document.editState.vignetteSoftness"))
        XCTAssertTrue(view.contains("state.vignetteSoftness == 0"))
        XCTAssertTrue(view.contains("document.editState.vignetteSoftness = 0"))
    }
}

/// The Global wheel's UI wiring: the 4th segment, its three bindings, the identity check and Reset Adjustments.
final class GlobalWheelWiringTests: XCTestCase {
    private func view() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI/AdjustTabView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheSegmentedControlHasFourRangesInOrder() {
        XCTAssertEqual(ColorGradingRange.allCases.map(\.rawValue), ["Shadows", "Midtones", "Highlights", "Global"])
    }

    func testEveryBindingDispatchAndTheResetKnowTheGlobalWheel() throws {
        let text = try view()
        for binding in ["$document.editState.globalHue", "$document.editState.globalSaturation", "$document.editState.globalLuminance"] {
            XCTAssertTrue(text.contains("case .global: return \(binding)"), binding)
        }
        XCTAssertTrue(text.contains("state.globalHue == 0"))
        XCTAssertTrue(text.contains("state.globalSaturation == 0"))
        XCTAssertTrue(text.contains("state.globalLuminance == 0"))
        XCTAssertTrue(text.contains("document.editState.globalHue = 0"))
        XCTAssertTrue(text.contains("document.editState.globalSaturation = 0"))
        XCTAssertTrue(text.contains("document.editState.globalLuminance = 0"))
    }

    func testThePerRangeResetStillTouchesOnlyTheSelectedRangeNotBlendingOrBalance() throws {
        let text = try view()
        let start = try XCTUnwrap(text.range(of: "Button(\"Reset \\(panel.selectedColorGradingRange.rawValue)\")"))
        let body = String(text[start.upperBound...].prefix(600))
        let end = try XCTUnwrap(body.range(of: ".buttonStyle("))
        let button = String(body[..<end.lowerBound])
        XCTAssertFalse(button.contains("colorGradingBlending") || button.contains("colorGradingBalance"))
        XCTAssertTrue(button.contains("colorGradingHueBinding(for: panel.selectedColorGradingRange)"), "it resets through the shared dispatch, so Global resets itself")
    }
}

/// Per-mask Whites/Blacks rows (same source-pinning approach).
final class MaskWhitesBlacksWiringTests: XCTestCase {
    func testTheMaskDetailViewHasBothRowsAfterShadows() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI/MaskDetailView.swift")
        let view = try String(contentsOf: url, encoding: .utf8)
        let shadows = try XCTUnwrap(view.range(of: "label: \"Shadows\", value: $mask.shadows"))
        let whites = try XCTUnwrap(view.range(of: "label: \"Whites\", value: $mask.whites"))
        let blacks = try XCTUnwrap(view.range(of: "label: \"Blacks\", value: $mask.blacks"))
        XCTAssertTrue(shadows.lowerBound < whites.lowerBound && whites.lowerBound < blacks.lowerBound)
    }
}
