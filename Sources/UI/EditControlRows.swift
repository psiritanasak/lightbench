import SwiftUI

/// A single edit-adjustment control: label + live readout on one line, with
/// a Reset button, and a full-width slider below — label-above-slider,
/// matching Lightroom/Photos' sidebar inspector convention (as opposed to a
/// label-beside-slider `HStack`, which gets cramped in a ~300pt-wide panel).
///
/// The readout doubles as a click-to-edit numeric field: tapping it swaps
/// in a `TextField` for typing an exact value, since dragging `ThinSlider`
/// alone can't reliably hit one.
struct EditSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let identity: Double
    /// Multiplier between `value`'s own units and what's typed/displayed
    /// while editing — e.g. `100` for a row whose `format` closure shows
    /// `value * 100` as a percent, so typing stays in the SAME units
    /// already on screen rather than the underlying `0...1`-shaped value.
    /// Defaults to `1`, which is already correct for every EV/Kelvin/
    /// degree/plain-decimal row — only percent-formatted rows need to
    /// pass `100` explicitly.
    var displayMultiplier: Double = 1
    let format: (Double) -> String

    @State private var isEditingText = false
    @State private var editingText = ""
    /// The text `editingText` was SEEDED with when editing began — lets
    /// `commitEditingText()` tell "nothing was typed" apart from "typed
    /// back the exact same value," so a plain tap-then-click-away (no
    /// actual edit) is a true no-op rather than writing `value` from a
    /// lossy `"%g"`-formatted round-trip (reviewer-caught: e.g. a raw
    /// `1/3` reformats to `0.333333`, a small but real drift, and any
    /// write here fires `editState`'s `didSet` — a phantom undo-history
    /// entry and sidecar save for an interaction where nothing changed).
    @State private var seedText = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                if isEditingText {
                    TextField("", text: $editingText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .monospacedDigit()
                        .focused($isTextFieldFocused)
                        .accessibilityLabel("\(label) value")
                        .onSubmit { commitEditingText() }
                        .onExitCommand {
                            // Escape cancels. Reviewer-caught: flipping
                            // `isEditingText` alone isn't reliably a
                            // cancel — whether the later `onChange` focus-
                            // loss commit fires before or after this
                            // branch flips is unverified SwiftUI teardown
                            // ordering. Clearing `editingText` to match
                            // `seedText` makes commit a no-op regardless
                            // of ordering, and resigning focus directly
                            // (not relying on the view disappearing) means
                            // the next `beginEditingText()`'s
                            // `isTextFieldFocused = true` is a real
                            // false→true transition, not a no-op.
                            editingText = seedText
                            isTextFieldFocused = false
                            isEditingText = false
                        }
                        .onChange(of: isTextFieldFocused) { _, focused in
                            if !focused { commitEditingText() }
                        }
                } else {
                    Text(format(value))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { beginEditingText() }
                }
                Button {
                    value = identity
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(value == identity)
                .accessibilityLabel("Reset \(label)")
            }
            ThinSlider(value: $value, range: range)
                .accessibilityLabel(label)
        }
    }

    private func beginEditingText() {
        seedText = String(format: "%g", value * displayMultiplier)
        editingText = seedText
        isEditingText = true
        isTextFieldFocused = true
    }

    /// Parses `editingText` and commits, or silently leaves `value`
    /// unchanged on unparseable/non-finite input — no error UI, matching
    /// this file's existing light touch on validation. Always clamped to
    /// `range`, so a typed out-of-range number (e.g. `500` for a
    /// `0...100%` row) is pulled back in range rather than handed to
    /// `ThinSlider` raw. A no-op if `editingText` still matches the seed
    /// — see `seedText`'s own doc comment.
    private func commitEditingText() {
        defer { isEditingText = false }
        guard editingText != seedText else { return }
        guard let typed = Double(editingText.trimmingCharacters(in: .whitespaces)), typed.isFinite else { return }
        value = min(range.upperBound, max(range.lowerBound, typed / displayMultiplier))
    }
}

/// A single boolean edit-adjustment control: label + `Toggle` on one line.
/// No Reset button — unlike a continuous slider, a boolean is already
/// trivially reversible with a single click either direction.
struct EditToggleRow: View {
    let label: String
    @Binding var value: Bool

    var body: some View {
        Toggle(label, isOn: $value)
    }
}
