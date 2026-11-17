import XCTest
import SwiftUI
@testable import PhotoApp

/// `AdjustSection`'s field lists against `EditState` itself: every stored field is in exactly one section or in the explicit
/// "outside the Edit tab" list below, so a new `EditState` field fails here until it is placed.
final class AdjustSectionTests: XCTestCase {
    /// Fields that no Edit-tab section shows (their own tabs, or not user-edited at all).
    static let outsideTheEditTab: Set<String> = [
        // geometry (Crop tab)
        "straightenAngle", "verticalPerspective", "horizontalPerspective", "transformScale", "transformAspect",
        "rotationQuarterTurns", "flipHorizontal", "flipVertical",
        "cropInsetTop", "cropInsetBottom", "cropInsetLeft", "cropInsetRight",
        // red-eye, retouch, masks (own tabs)
        "redEyePoints", "redEyeSize", "redEyeStrength", "retouchSpots", "masks",
        // Looks tab
        "lookID", "lookIntensity", "styleID", "styleTone", "styleColor", "styleStrength", "styleTexture",
        "styleTextureAmount", "styleGrain", "styleProtectSkin", "styleProtectAmount", "styleSkinMaskPNG",
        "styleSkinMaskRevision",
        // determinism pin, not an edit
        "rawDecoderVersionPin"
    ]

    private var allFieldNames: [String] { Mirror(reflecting: EditState()).children.compactMap(\.label) }

    /// Changes one field by key path and returns the new state; fails the test on a type this probe does not know.
    private func nudged(_ keyPath: PartialKeyPath<EditState>, from state: EditState = EditState()) -> EditState {
        var s = state
        if let kp = keyPath as? WritableKeyPath<EditState, Double> {
            s[keyPath: kp] += 0.25
        } else if let kp = keyPath as? WritableKeyPath<EditState, Bool> {
            s[keyPath: kp].toggle()
        } else if let kp = keyPath as? WritableKeyPath<EditState, [ToneCurvePoint]> {
            s[keyPath: kp].append(ToneCurvePoint(x: 0.5, y: 0.6))
        } else if let kp = keyPath as? WritableKeyPath<EditState, [PointColor]> {
            s[keyPath: kp].append(PointColor())
        } else if let kp = keyPath as? WritableKeyPath<EditState, [RawNeutralPoint]> {
            s[keyPath: kp].append(RawNeutralPoint(x: 0.5, y: 0.5))
        } else {
            XCTFail("add a probe for \(keyPath)")
        }
        return s
    }

    /// Each section field's key path names exactly one `EditState` field.
    private func fieldName(_ keyPath: PartialKeyPath<EditState>) -> String {
        let changed = EditStateDiff.changedFieldNames(from: EditState(), to: nudged(keyPath))
        XCTAssertEqual(changed.count, 1, "\(keyPath) must map to exactly one field: \(changed)")
        return changed.first ?? "?"
    }

    func testEveryEditStateFieldIsInExactlyOneSectionOrTheOutsideList() {
        var counts: [String: Int] = [:]
        for section in AdjustSection.allCases {
            for field in section.fields { counts[fieldName(field.keyPath), default: 0] += 1 }
        }
        for name in Self.outsideTheEditTab { counts[name, default: 0] += 1 }
        for name in allFieldNames {
            XCTAssertEqual(counts[name], 1, "EditState.\(name) must be in exactly one AdjustSection or in outsideTheEditTab")
        }
        XCTAssertEqual(Set(counts.keys), Set(allFieldNames), "unknown names in a section or the outside list")
    }

    func testTheCountsMatchThePlan() {
        let inSections = AdjustSection.allCases.reduce(0) { $0 + $1.fields.count }
        XCTAssertEqual(allFieldNames.count, inSections + Self.outsideTheEditTab.count)
        XCTAssertEqual(inSections, 94)
        XCTAssertEqual(Self.outsideTheEditTab.count, 31)
    }

    func testEachFieldMakesOnlyItsOwnSectionEditedAndItsResetRestoresDefaults() {
        for section in AdjustSection.allCases {
            for field in section.fields {
                let s = nudged(field.keyPath)
                for other in AdjustSection.allCases {
                    XCTAssertEqual(other.isEdited(s), other == section, "\(fieldName(field.keyPath)) in \(section) vs \(other)")
                }
                XCTAssertEqual(section.resetting(s), EditState(), "\(fieldName(field.keyPath))")
                XCTAssertEqual(AdjustSection.section(for: field.keyPath), section)
            }
        }
    }

    func testResettingASectionLeavesEverythingElseAlone() {
        var s = EditState()
        s.straightenAngle = 3; s.cropInsetTop = 0.1; s.redEyeSize = 0.9; s.redEyeStrength = 0.2
        s.lookID = "x"; s.styleID = "y"; s.rawDecoderVersionPin = "pin-1"
        s.exposureEV = 1; s.vibrance = 0.4
        let next = AdjustSection.light.resetting(s)
        XCTAssertEqual(next.exposureEV, 0)
        XCTAssertEqual(next.vibrance, 0.4)
        var expected = s
        expected.exposureEV = 0
        XCTAssertEqual(next, expected)
    }

    func testARawPhotoCarryingOnlyThePinHasNoSectionEdited() {
        var s = EditState()
        s.rawDecoderVersionPin = "pin-1"
        XCTAssertFalse(AdjustSection.allCases.contains { $0.isEdited(s) })
    }

    func testResetAdjustmentsCoversEverySectionButRawAndIncludesPointColor() {
        XCTAssertFalse(AdjustSection.resetAdjustmentsSections.contains(.raw))
        XCTAssertTrue(AdjustSection.resetAdjustmentsSections.contains(.pointColor))
        XCTAssertEqual(Set(AdjustSection.resetAdjustmentsSections), Set(AdjustSection.allCases).subtracting([.raw]))
    }

    // MARK: header accessibility

    func testHeaderAccessibilityValueCoversAllFourCombinations() {
        XCTAssertEqual(AdjustSectionContainer<Text>.accessibilityValue(isExpanded: true, isEdited: false), "Expanded")
        XCTAssertEqual(AdjustSectionContainer<Text>.accessibilityValue(isExpanded: false, isEdited: false), "Collapsed")
        XCTAssertEqual(AdjustSectionContainer<Text>.accessibilityValue(isExpanded: true, isEdited: true), "Expanded, Edited")
        XCTAssertEqual(AdjustSectionContainer<Text>.accessibilityValue(isExpanded: false, isEdited: true), "Collapsed, Edited")
    }

    func testHeaderUsesTheAccessibilityValueFunctionAndDisablesTheResetWhenItCannotAct() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/UI/AdjustTabView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains(".accessibilityValue(Self.accessibilityValue(isExpanded: isExpanded, isEdited: isEdited))"))
        XCTAssertTrue(src.contains(".disabled(!showsReset || !isResetEnabled)"))
    }
}
