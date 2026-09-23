import Foundation

/// Backs `EditStateDiff.changedFieldNames`' own field-by-field comparison —
/// opens each `Mirror` child's existential `any Equatable` back into its
/// concrete type so it can compare against the OTHER state's child with the
/// type's own real `==`, not `String(describing:)`. The latter was
/// considered and rejected: it treats `-0.0` and `0.0` as different (they
/// print differently but are `==`) and can't reliably detect `NaN` at all —
/// see `EditStateDiffTests.testNegativeZeroIsNotADifference` for the
/// concrete case that motivated this.
private extension Equatable {
    func isEqual(toAny other: Any) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}

/// Describes what changed between two `EditState` values, for the History
/// panel's own row labels (`HistoryEntry.summary`). Pure Foundation, no UI
/// import — `EditHistory`/`EditState`'s own module boundary.
///
/// Deliberately `Mirror`-based rather than a hand-maintained field list:
/// this codebase's own CLAUDE.md documents several past incidents of a
/// hand-maintained field enumeration silently going stale as new
/// `EditState` fields were added (e.g. `isAdjustTabAtIdentity`,
/// `pickColorRangeTarget`'s own post-mask-stage field list, twice).
/// Walking `Mirror(reflecting:)` means a new stored property is included
/// automatically, with nothing to remember to update here.
enum EditStateDiff {
    /// Every `EditState` field whose value differs between `old` and `new`,
    /// in DECLARATION order (the order `Mirror` itself walks stored
    /// properties in), as the property's own Swift name (e.g.
    /// `"exposureEV"`, not a display label — see `displayName(forField:)`
    /// for that).
    ///
    /// Compares each field with ITS OWN `==`, not a generic string
    /// comparison — see the `Equatable` extension above for why, and note
    /// this makes the comparison provably agree, field-for-field, with
    /// `EditState`'s own compiler-synthesized `==` (which `EditHistory
    /// .commit`'s own no-op guard already uses): a commit only ever
    /// happens when this function's own result is non-empty.
    static func changedFieldNames(from old: EditState, to new: EditState) -> [String] {
        let oldChildren = Mirror(reflecting: old).children
        let newChildren = Mirror(reflecting: new).children
        var changed: [String] = []
        for (oldChild, newChild) in zip(oldChildren, newChildren) {
            guard let label = oldChild.label else { continue }
            let isSame: Bool
            if let oldEquatable = oldChild.value as? any Equatable {
                isSame = oldEquatable.isEqual(toAny: newChild.value)
            } else {
                // Structurally unreachable: every `EditState` stored
                // property is a type that itself conforms to `Equatable`
                // (required for `EditState`'s own synthesized `Equatable`
                // conformance to compile at all), so this branch can only
                // be reached by a future change that breaks that
                // invariant — fail loudly in debug builds rather than
                // silently mis-report "unchanged".
                assertionFailure("EditStateDiff: field \"\(label)\" is not Equatable")
                isSame = String(describing: oldChild.value) == String(describing: newChild.value)
            }
            if !isSame {
                changed.append(label)
            }
        }
        return changed
    }

    /// A generic camelCase → "Title Case" prettifier for a field's own
    /// Swift property name — e.g. `"exposureEV"` → `"Exposure EV"`,
    /// `"blackPoint"` → `"Black Point"`, `"rawEVBias"` → `"Raw EV Bias"`.
    /// A word boundary is inserted before any uppercase letter that either
    /// (a) immediately follows a lowercase letter/digit (`"blackP" →
    /// "black" | "Point"`), or (b) is immediately followed by a lowercase
    /// letter AND itself follows another uppercase letter — the standard
    /// "acronym-then-new-word" rule, e.g. the `B` in `"rawEVBias"`: it
    /// follows uppercase `V` but precedes lowercase `i`, so `"EV"` and
    /// `"Bias"` split apart instead of staying fused into `"EVBias"`. A
    /// run of capitals with nothing lowercase after it (`"exposureEV"`'s
    /// trailing `"EV"`) stays together as one word either way.
    ///
    /// ACCEPTED, DOCUMENTED v1 gap: this won't always match a slider's own
    /// hand-styled label — `"curvesHighlights"` becomes `"Curves
    /// Highlights"` here, not the slider's own plain `"Highlights"`. Not
    /// worth a second hand-maintained name → label table for a result
    /// that's already meaningfully informative; see CLAUDE.md's own Auto
    /// Tone precedent for the same trade-off made the same way.
    static func displayName(forField name: String) -> String {
        guard !name.isEmpty else { return name }
        let characters = Array(name)
        var result = ""
        for (index, character) in characters.enumerated() {
            if index == 0 {
                // Appending the uppercased STRING, not casting back to a
                // single `Character` — a few Unicode letters (e.g. "ß")
                // uppercase to more than one character, which would crash
                // an unconditional `Character(...)` cast. Every actual
                // `EditState` field name is ASCII, but this avoids relying
                // on that staying true.
                result.append(contentsOf: String(character).uppercased())
                continue
            }
            let previous = characters[index - 1]
            let isBoundary: Bool
            if character.isUppercase {
                let previousIsLower = previous.isLowercase || previous.isNumber
                let startsNewWordAfterAcronym = previous.isUppercase
                    && index + 1 < characters.count
                    && characters[index + 1].isLowercase
                isBoundary = previousIsLower || startsNewWordAfterAcronym
            } else {
                isBoundary = false
            }
            if isBoundary {
                result.append(" ")
            }
            result.append(character)
        }
        return result
    }

    /// The History panel's own row label: up to `maxNames` changed fields'
    /// own display names, joined with commas; `"and N more"` appended if
    /// more changed than that (a Preset apply, a Revert, or a multi-corner
    /// Crop drag can easily touch more than 3 fields in one commit, and an
    /// unbounded list would make that row unreadable). `"No Change"` is a
    /// defensive fallback only — `EditHistory.commit`'s own guard means
    /// this is never actually reached from a real commit.
    static func summary(from old: EditState, to new: EditState, maxNames: Int = 3) -> String {
        let changed = changedFieldNames(from: old, to: new)
        guard !changed.isEmpty else { return "No Change" }
        let names = changed.map(displayName(forField:))
        guard names.count > maxNames else {
            return names.joined(separator: ", ")
        }
        let shown = names.prefix(maxNames).joined(separator: ", ")
        return "\(shown) and \(names.count - maxNames) more"
    }
}
