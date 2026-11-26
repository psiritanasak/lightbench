import SwiftUI

/// Pure rules for `EditSliderRow`'s quiet chrome and its reset path (kept SwiftUI-free so they are unit-tested as truth tables).
enum EditSliderRowChrome {
    /// A reset writes only when the value is not already the default (no phantom history step or sidecar save).
    static func shouldReset(value: Double, identity: Double) -> Bool { value != identity }
    /// The reset icon is drawn while the row is edited, or while the pointer is anywhere over the row.
    static func showsResetIcon(isDefault: Bool, isRowHovered: Bool) -> Bool { !isDefault || isRowHovered }
    /// The readout's hairline outline appears on hover and while typing.
    static func showsReadoutOutline(isHovered: Bool, isEditing: Bool) -> Bool { isHovered || isEditing }
    /// The labelled undo-step name for a reset of the slider called `label`.
    static func historySummary(label: String) -> String { "Reset \(label)" }
}

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
    /// D58-2: optional colour stops for the slider's gradient track (`SliderTrackPalette`). `nil` = the plain track.
    var track: [Color]? = nil
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
    @State private var isRowHovered = false
    @State private var isReadoutHovered = false
    @Environment(\.sliderResetAction) private var resetAction

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(label)
                    .contentShape(Rectangle())
                    // A1's pattern: the click count is read inside ONE tap gesture (a two-tap recogniser would delay the
                    // first click); the label has no single-click action.
                    .onTapGesture { if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { requestReset() } }
                    .help("Double-click to reset")
                Spacer()
                HStack(spacing: 0) {
                    if isEditingText {
                        TextField("", text: $editingText)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                            .monospacedDigit()
                            .focused($isTextFieldFocused)
                            .padding(.horizontal, Theme.Space.px3)
                            .overlay(readoutOutline)
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
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, Theme.Space.px3)
                            .overlay(readoutOutline)
                            .contentShape(Rectangle())
                            .help("Click to type a value")
                            .onTapGesture { beginEditingText() }
                            // D6 (IMPROVEMENTS.md): this is a plain `Text` with
                            // a tap gesture, so it's the most invisible
                            // interactive affordance in the app — VoiceOver
                            // sees static text with no indication it can be
                            // activated. `.isButton` + an explicit action makes
                            // "type an exact value" reachable the same way a
                            // real button would be. Reviewer-caught: labeling
                            // this "\(label) value" with its own
                            // `accessibilityValue` duplicates the `ThinSlider`
                            // below almost word-for-word — phrased as an ACTION
                            // instead ("type a value"), since the slider already
                            // owns announcing the current value.
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Type \(label) value")
                            .accessibilityAction { beginEditingText() }
                    }
                }
                .onHover { isReadoutHovered = $0 }
                Button {
                    requestReset()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .disabled(isDefault)
                .opacity(showsResetIcon ? 1 : 0)
                .allowsHitTesting(showsResetIcon)
                .accessibilityLabel("Reset \(label)")
                .accessibilityHidden(isDefault)
            }
            ThinSlider(value: $value, range: range, valueDescription: format, track: track, onDoubleClick: requestReset)
                .accessibilityLabel(label)
                // ONE view identity for the slider: the action is offered through `accessibilityActions`, never by switching
                // between modified and unmodified content (that rebuilds the slider mid-drag when the value leaves the default).
                .accessibilityActions {
                    if value != identity { Button("Reset \(label)") { requestReset() } }
                }
        }
        .onHover { isRowHovered = $0 }
    }

    private var isDefault: Bool { !EditSliderRowChrome.shouldReset(value: value, identity: identity) }

    private var showsResetIcon: Bool {
        EditSliderRowChrome.showsResetIcon(isDefault: isDefault, isRowHovered: isRowHovered)
    }

    private var readoutOutline: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.px3)
            .strokeBorder(Theme.hairline, lineWidth: 1)
            .opacity(EditSliderRowChrome.showsReadoutOutline(isHovered: isReadoutHovered, isEditing: isEditingText) ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// The one reset path (icon, label double-click, track double-click, VoiceOver): ONE labelled undo step, nothing written at
    /// the default (no phantom sidecar save), and any half-typed readout is cancelled first so its later focus-loss commit
    /// cannot overwrite the reset.
    private func requestReset() {
        if isEditingText {
            editingText = seedText
            isTextFieldFocused = false
            isEditingText = false
        }
        guard EditSliderRowChrome.shouldReset(value: value, identity: identity) else { return }
        let target = identity
        resetAction.perform(EditSliderRowChrome.historySummary(label: label)) { value = target }
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
