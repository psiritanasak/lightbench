import Foundation

/// One Color Grading-style tint (hue in degrees, saturation 0...1) a style adds. Zero saturation = no tint at all.
struct StyleTint: Equatable, Sendable {
    var hue: Double
    var saturation: Double

    static let none = StyleTint(hue: 0, saturation: 0)
}

/// A named style preset: render-time NUDGES to the tone/colour values the pipeline already uses, plus an optional tint
/// per tonal range. A preset never stores or overwrites any of the user's own slider fields; `StyleMath.nudges` turns
/// (preset, pad, strength) into the amounts the renderer adds.
///
/// Every number below is a CONVENTION chosen by eye (v1, no measurement behind them) — the renderer, not the sidecar,
/// owns them, so retuning a preset restyles photos already carrying that `styleID`.
struct StylePreset: Equatable, Identifiable, Sendable {
    enum Family: String, CaseIterable, Sendable {
        /// Skin-friendly colour casts (a gentle tint, almost no tonal change).
        case undertone
        /// Tonal / colour moods.
        case mood

        var title: String { self == .undertone ? "Undertone" : "Mood" }
    }

    let id: String
    let name: String
    let family: Family
    var contrast: Double = 0
    var shadows: Double = 0
    var highlights: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var shadowTint: StyleTint = .none
    var midTint: StyleTint = .none
    var highlightTint: StyleTint = .none
}

/// The built-in style presets (our own names). Ids are `builtin:<slug>`; the empty id means "no preset" (the pad can still
/// be used on its own, like Apple's Standard style).
enum StyleLibrary {
    static let idPrefix = "builtin:"

    static let all: [StylePreset] = undertone + mood

    static let undertone: [StylePreset] = [
        StylePreset(id: "builtin:frost", name: "Frost", family: .undertone, vibrance: 0.05,
                    midTint: StyleTint(hue: 340, saturation: 0.06), highlightTint: StyleTint(hue: 330, saturation: 0.10)),
        StylePreset(id: "builtin:true", name: "True", family: .undertone, contrast: 0.05, vibrance: 0.05),
        StylePreset(id: "builtin:blush", name: "Blush", family: .undertone,
                    midTint: StyleTint(hue: 355, saturation: 0.08), highlightTint: StyleTint(hue: 350, saturation: 0.10)),
        StylePreset(id: "builtin:honey", name: "Honey", family: .undertone,
                    shadowTint: StyleTint(hue: 28, saturation: 0.05), midTint: StyleTint(hue: 34, saturation: 0.09),
                    highlightTint: StyleTint(hue: 40, saturation: 0.12)),
        StylePreset(id: "builtin:copper", name: "Copper", family: .undertone,
                    shadowTint: StyleTint(hue: 20, saturation: 0.06), midTint: StyleTint(hue: 25, saturation: 0.12),
                    highlightTint: StyleTint(hue: 30, saturation: 0.16)),
    ]

    static let mood: [StylePreset] = [
        StylePreset(id: "builtin:vivid", name: "Vivid", family: .mood, contrast: 0.10, saturation: 0.15, vibrance: 0.30),
        StylePreset(id: "builtin:clean", name: "Clean", family: .mood, contrast: 0.05, highlights: -0.05, vibrance: 0.10),
        StylePreset(id: "builtin:radiant", name: "Radiant", family: .mood, contrast: -0.05, shadows: 0.25, highlights: -0.10, vibrance: 0.10),
        StylePreset(id: "builtin:cinema", name: "Cinema", family: .mood, contrast: 0.22, shadows: -0.12, saturation: -0.10,
                    shadowTint: StyleTint(hue: 200, saturation: 0.12), highlightTint: StyleTint(hue: 35, saturation: 0.08)),
        StylePreset(id: "builtin:hush", name: "Hush", family: .mood, contrast: -0.15, shadows: 0.10, saturation: -0.30),
        StylePreset(id: "builtin:hearth", name: "Hearth", family: .mood, contrast: 0.05, shadows: 0.10, saturation: 0.05,
                    midTint: StyleTint(hue: 35, saturation: 0.12), highlightTint: StyleTint(hue: 40, saturation: 0.10)),
        StylePreset(id: "builtin:haze", name: "Haze", family: .mood, contrast: -0.25, shadows: 0.30, saturation: -0.15,
                    shadowTint: StyleTint(hue: 210, saturation: 0.08)),
        // The two monochrome moods use Saturation -1. A style only ADDS nudges and never writes the user's own fields (so
        // never the B&W toggle). Consequence, by design: they are monochrome only while the user's own Saturation is 0,
        // strength is 1 and the pad's Color is not above 0 — a positive user Saturation or Color pulls colour back in.
        StylePreset(id: "builtin:silver", name: "Silver", family: .mood, contrast: -0.10, shadows: 0.10, saturation: -1),
        StylePreset(id: "builtin:ink", name: "Ink", family: .mood, contrast: 0.35, shadows: -0.20, saturation: -1),
    ]

    // `uniquingKeysWith`, not `uniqueKeysWithValues`: a duplicate id must not crash the app; `StyleLibraryTests` asserts uniqueness.
    private static let byID: [String: StylePreset] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// The preset for `id`, or nil for "" and for an id this build does not know (renders as no preset, like an unresolved Look).
    static func preset(for id: String) -> StylePreset? { byID[id] }

    static func presets(in family: StylePreset.Family) -> [StylePreset] { all.filter { $0.family == family } }
}
