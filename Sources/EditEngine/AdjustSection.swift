import Foundation

/// One `EditState` field as a section sees it: whether it sits at its declared default, and how to put it back. The default is
/// read from `EditState()` (never copied by hand), so a changed default cannot leave a section's "edited" dot or reset stale.
struct EditStateField {
    let keyPath: PartialKeyPath<EditState>
    let isAtDefault: (EditState) -> Bool
    let reset: (inout EditState) -> Void

    static func of<V: Equatable>(_ keyPath: WritableKeyPath<EditState, V>) -> EditStateField {
        let defaultValue = EditState()[keyPath: keyPath]
        return EditStateField(
            keyPath: keyPath,
            isAtDefault: { $0[keyPath: keyPath] == defaultValue },
            reset: { $0[keyPath: keyPath] = defaultValue }
        )
    }
}

/// The Edit tab's collapsible sections and the `EditState` fields each one shows. Drives the header's "edited" dot, the
/// per-section reset and "Reset Adjustments". Fields that belong to no section (geometry, red-eye, retouch, masks, look/style,
/// the RAW determinism pin) are listed in `AdjustSectionTests`, whose Mirror check fails when a new `EditState` field is in
/// neither place. Pure: no UI.
enum AdjustSection: String, CaseIterable {
    case light, curve, color, selectiveColor, pointColor, blackAndWhite, colorGrading, effects, raw

    var title: String {
        switch self {
        case .light: return "Light"
        case .curve: return "Curve"
        case .color: return "Color"
        case .selectiveColor: return "Selective Color"
        case .pointColor: return "Point Color"
        case .blackAndWhite: return "Black & White"
        case .colorGrading: return "Color Grading"
        case .effects: return "Effects"
        case .raw: return "RAW"
        }
    }

    /// Computed (not a stored static): key paths in closures are not `Sendable` under Swift 6.
    var fields: [EditStateField] {
        switch self {
        case .light:
            return [.of(\.exposureEV), .of(\.brightness), .of(\.brilliance), .of(\.contrast),
                    .of(\.curvesHighlights), .of(\.curvesShadows), .of(\.blackPoint), .of(\.whites),
                    .of(\.levelsBlackPoint), .of(\.levelsWhitePoint), .of(\.levelsGamma)]
        case .curve:
            return [.of(\.toneCurvePoints), .of(\.toneCurvePointsRed), .of(\.toneCurvePointsGreen), .of(\.toneCurvePointsBlue)]
        case .color:
            return [.of(\.whiteBalanceTemperature), .of(\.whiteBalanceTint), .of(\.hslHue), .of(\.vibrance), .of(\.hslSaturation)]
        case .selectiveColor:
            var all: [EditStateField] = [.of(\.selectiveColorRange)]
            for property in SelectiveColorProperty.allCases {
                all += SelectiveColorBandWeights.selectiveColorKeyPaths(for: property).map { .of($0) }
            }
            return all
        case .pointColor:
            return [.of(\.pointColors)]
        case .blackAndWhite:
            return [.of(\.blackAndWhite)]
                + SelectiveColorBandWeights.grayMixKeyPaths.map { .of($0) }
                + [.of(\.bwIntensity), .of(\.bwNeutrals), .of(\.bwTone), .of(\.bwGrain)]
        case .colorGrading:
            return [.of(\.shadowHue), .of(\.shadowSaturation), .of(\.shadowLuminance),
                    .of(\.midtoneHue), .of(\.midtoneSaturation), .of(\.midtoneLuminance),
                    .of(\.highlightHue), .of(\.highlightSaturation), .of(\.highlightLuminance),
                    .of(\.globalHue), .of(\.globalSaturation), .of(\.globalLuminance),
                    .of(\.colorGradingBlending), .of(\.colorGradingBalance)]
        case .effects:
            return [.of(\.vignetteStrength), .of(\.vignetteRadius), .of(\.vignetteSoftness),
                    .of(\.texture), .of(\.clarity), .of(\.dehaze), .of(\.sharpness), .of(\.noiseReduction),
                    .of(\.defringePurple), .of(\.defringeGreen), .of(\.grain)]
        case .raw:
            // NOT rawDecoderVersionPin: it is a determinism pin, not an edit.
            // rawWhiteBalanceNeutralPoints lives here deliberately: the RAW fast-path eyedropper is pressed from the Color
            // section but writes this field and resets Temperature/Tint, so afterwards Color shows no dot and Reset Color does
            // nothing, while the RAW header shows the dot and Reset RAW clears it. Matches the old Reset Adjustments, which never
            // cleared it.
            return [.of(\.boostAmount), .of(\.rawExposureEV), .of(\.shadowBoostScale), .of(\.rawWhiteBalanceNeutralPoints),
                    .of(\.rawLuminanceNoiseReductionAdjust), .of(\.rawColorNoiseReductionScale), .of(\.rawSharpnessScale),
                    .of(\.rawContrastAdjust), .of(\.rawDetailAdjust), .of(\.rawMoireReductionAdjust)]
        }
    }

    /// True when any of the section's fields differs from its declared default ("every field at its literal default", not
    /// "renders like identity").
    func isEdited(_ state: EditState) -> Bool {
        fields.contains { !$0.isAtDefault(state) }
    }

    func resetting(_ state: EditState) -> EditState {
        var next = state
        for field in fields { field.reset(&next) }
        return next
    }

    /// What "Reset Adjustments" clears: every Edit-tab section except RAW (RAW fields are decoder inputs with their own tab-less
    /// section; the button never touched them).
    static let resetAdjustmentsSections: [AdjustSection] = allCases.filter { $0 != .raw }

    static func resetting(_ sections: [AdjustSection], in state: EditState) -> EditState {
        sections.reduce(state) { $1.resetting($0) }
    }

    /// The section that shows `keyPath`, or nil for a field outside the Edit tab.
    static func section(for keyPath: PartialKeyPath<EditState>) -> AdjustSection? {
        allCases.first { section in section.fields.contains { $0.keyPath == keyPath } }
    }
}
