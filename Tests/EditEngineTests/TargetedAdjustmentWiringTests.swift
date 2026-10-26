import XCTest
@testable import PhotoApp

/// The Targeted button's availability rules, and source pins for the view wiring that no unit can reach (a SwiftUI body).
final class TargetedAdjustmentWiringTests: XCTestCase {
    // MARK: - Rules

    func testEnabledWithAnImageAtIdentityGeometry() {
        let a = TargetedAdjustmentRules.availability(tool: .curve, hasImage: true, geometryAtIdentity: true, isArmed: false)
        XCTAssertTrue(a.isEnabled)
        XCTAssertEqual(a.help, TargetedAdjustmentRules.instruction(for: .curve))
    }

    func testDisabledWithoutAnImage() {
        let a = TargetedAdjustmentRules.availability(tool: .curve, hasImage: false, geometryAtIdentity: true, isArmed: false)
        XCTAssertFalse(a.isEnabled)
        XCTAssertFalse(a.help.isEmpty)
    }

    func testDisabledAwayFromIdentityGeometryWithAnExplanation() {
        let a = TargetedAdjustmentRules.availability(tool: .grayMix, hasImage: true, geometryAtIdentity: false, isArmed: false)
        XCTAssertFalse(a.isEnabled)
        XCTAssertEqual(a.help, TargetedAdjustmentRules.geometryHelp)
        XCTAssertTrue(a.help.contains("crop"))
    }

    func testStaysEnabledWhileArmedSoItCanAlwaysBeStopped() {
        let a = TargetedAdjustmentRules.availability(tool: .curve, hasImage: true, geometryAtIdentity: false, isArmed: true)
        XCTAssertTrue(a.isEnabled)
        let none = TargetedAdjustmentRules.availability(tool: .curve, hasImage: false, geometryAtIdentity: false, isArmed: true)
        XCTAssertTrue(none.isEnabled)
    }

    func testEachToolHasItsOwnInstruction() {
        let texts = Set([TargetedTool.curve, .selectiveColor(.hue), .selectiveColor(.saturation), .selectiveColor(.luminance), .grayMix]
            .map(TargetedAdjustmentRules.instruction(for:)))
        XCTAssertEqual(texts.count, 5)
    }

    // MARK: - Source pins

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The layer's gate (one computed property) must exclude every other armed mode, Compare, crop and non-identity geometry, and
    /// the layer must be built from it.
    func testCaptureLayerIsGatedOnEveryOtherModeAndIdentityGeometry() throws {
        let text = try source("Sources/UI/ContentView.swift")
        let start = try XCTUnwrap(text.range(of: "private var targetedLayerActive: Bool {"))
        // Only this property's own body (up to its closing brace), not the doc comment of the one after it.
        let tail = String(text[start.lowerBound...])
        let gate = String(tail[..<(try XCTUnwrap(tail.range(of: "\n    }\n")).lowerBound)])
        for term in ["isTargetedArmed", "targetedSectionOpen", "!isCroppingActive", "!isPickingWhiteBalance",
                     "!isPlacingRedEyeCorrections", "!isPaintingBrush", "!isPickingColorRange", "!isPickingPointColor",
                     "!isPickingSubject", "compareMode == .off", "isGeometryAtIdentity"] {
            XCTAssertTrue(gate.contains(term), "capture layer gate lost \(term)")
        }
        XCTAssertTrue(text.contains("if targetedLayerActive, let tool = targetedTool, let fitRect = currentFitRect {"))
    }

    /// `onEnded` is not delivered when a gesture is cancelled or its view removed: the drag must end on the GestureState's
    /// falling edge and when the layer's gate turns false, and the cursor push must be paired with a pop.
    func testDragEndsWithoutOnEndedAndCursorIsReleased() throws {
        let text = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(text.contains(".updating($targetedPressing)"))
        XCTAssertTrue(text.contains(".onChange(of: targetedPressing)"))
        let gateEdge = try XCTUnwrap(text.range(of: ".onChange(of: targetedLayerActive)"))
        let body = String(text[gateEdge.lowerBound...].prefix(400))
        XCTAssertTrue(body.contains("document.endTargetedDrag()"))
        XCTAssertTrue(body.contains("setTargetedCursor(false)"))
        XCTAssertTrue(text.contains(".onDisappear { setTargetedCursor(false) }"))
        XCTAssertTrue(text.contains("if inside, !targetedCursorPushed"))
        XCTAssertTrue(text.contains("} else if !inside, targetedCursorPushed {"))
    }

    /// At most one begin per press: the flag is set BEFORE the begin attempt (success or refusal) and cleared only when the press
    /// ends, never when the layer's gate closes.
    func testABeginIsAttemptedAtMostOncePerPress() throws {
        let text = try source("Sources/UI/ContentView.swift")
        let guardAt = try XCTUnwrap(text.range(of: "guard !targetedBeginSpent else { return }"))
        let setAt = try XCTUnwrap(text.range(of: "targetedBeginSpent = true"))
        let beginAt = try XCTUnwrap(text.range(of: "document.beginTargetedDrag("))
        XCTAssertLessThan(guardAt.lowerBound, setAt.lowerBound)
        XCTAssertLessThan(setAt.lowerBound, beginAt.lowerBound)
        let gateEdge = try XCTUnwrap(text.range(of: ".onChange(of: targetedLayerActive)"))
        XCTAssertFalse(String(text[gateEdge.lowerBound...].prefix(300)).contains("targetedBeginSpent = false"))
        let pressEdge = try XCTUnwrap(text.range(of: ".onChange(of: targetedPressing)"))
        XCTAssertTrue(String(text[pressEdge.lowerBound...].prefix(200)).contains("targetedBeginSpent = false"))
    }

    func testCollapsingTheSectionDisarms() throws {
        let text = try source("Sources/UI/ContentView.swift")
        let edge = try XCTUnwrap(text.range(of: ".onChange(of: targetedSectionOpen)"))
        XCTAssertTrue(String(text[edge.lowerBound...].prefix(200)).contains("interactionMode = .none"))
    }

    func testSectionOpenRule() {
        func open(_ tool: TargetedTool?, _ c: Bool, _ s: Bool, _ b: Bool) -> Bool {
            TargetedAdjustmentRules.sectionIsOpen(tool: tool, curveExpanded: c, selectiveColorExpanded: s, blackAndWhiteExpanded: b)
        }
        XCTAssertTrue(open(nil, false, false, false))
        XCTAssertTrue(open(.curve, true, false, false)); XCTAssertFalse(open(.curve, false, true, true))
        XCTAssertTrue(open(.selectiveColor(.hue), false, true, false)); XCTAssertFalse(open(.selectiveColor(.hue), true, false, true))
        XCTAssertTrue(open(.grayMix, false, false, true)); XCTAssertFalse(open(.grayMix, true, true, false))
    }

    func testZoomIsDisabledWhileArmed() throws {
        let text = try source("Sources/UI/ContentView.swift")
        XCTAssertTrue(text.contains("!isPickingPointColor && !isPickingSubject && !isTargetedArmed"))
    }

    func testRailCompareGetsTheTargetedFlag() throws {
        XCTAssertTrue(try source("Sources/UI/ContentView.swift").contains("targeted: isTargetedArmed"))
    }

    func testEscapeCommitsTheDragAndDisarmsInOneHandler() throws {
        let text = try source("Sources/UI/ContentView.swift")
        let start = try XCTUnwrap(text.range(of: "isTargetedArmed, keyPress.key == .escape"))
        let body = String(text[start.lowerBound...].prefix(260))
        XCTAssertTrue(body.contains("document.endTargetedDrag()"))
        XCTAssertFalse(body.contains("cancelTargetedDrag"))
        let end = try XCTUnwrap(body.range(of: "document.endTargetedDrag()"))
        let disarm = try XCTUnwrap(body.range(of: "interactionMode = .none"))
        XCTAssertLessThan(end.lowerBound, disarm.lowerBound, "end the drag first, then disarm")
    }

    func testEveryDisarmRouteCommitsAFlightDragAndBWOffDisarmsTheMix() throws {
        let text = try source("Sources/UI/ContentView.swift")
        let start = try XCTUnwrap(text.range(of: ".onChange(of: targetedTool) { _, tool in"))
        let handler = String(text[start.lowerBound...].prefix(260))
        XCTAssertTrue(handler.contains("document.endTargetedDrag()"), "EVERY tool change (disarm or re-arm for another property) commits a drag in flight")
        XCTAssertFalse(handler.contains("if tool == nil { document.endTargetedDrag() }"), "not only the disarm route")
        XCTAssertFalse(text.contains("document.cancelTargetedDrag()"), "no route abandons the drag any more")
        XCTAssertTrue(text.contains("if !isOn, targetedTool == .grayMix { interactionMode = .none }"))
    }

    /// The three buttons exist, and the B&W one only inside the B&W-on branch.
    func testButtonsArePlacedInTheThreeSections() throws {
        let text = try source("Sources/UI/AdjustTabView.swift")
        XCTAssertTrue(text.contains("targetedButton(.curve)"))
        XCTAssertTrue(text.contains("targetedButton(.selectiveColor(panel.targetedSelectiveProperty))"))
        let bw = try XCTUnwrap(text.range(of: "if document.editState.blackAndWhite {\n                targetedButton(.grayMix)"))
        XCTAssertNotNil(bw)
    }
}
