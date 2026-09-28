import SwiftUI

/// The Adjust panel's presentation-only state, grouped so `ContentView` can
/// own it as ONE `@State` and pass it down.
///
/// It must stay owned by `ContentView`, NOT by `AdjustTabView`: `editControls`
/// picks the tab body with a `switch`, so the Adjust subtree is torn down when
/// the user switches to Crop. Child-owned `@State` would therefore re-collapse
/// every section, reset the histogram picker to Luminance and the selective-
/// color band to Red on every tab round-trip. Hoisting it here keeps the
/// previous (correct) behavior, where these lived on `ContentView` directly.
struct AdjustPanelState {
    /// Which Adjust-tab sections are expanded — Apple-Photos-style
    /// collapsible sections. Defaults `false` (all collapsed) per user
    /// request; one bool each rather than a `Set`, matching this file's
    /// existing convention of separate named fields per presentation-only
    /// concern.
    var isLightSectionExpanded = false
    /// Curves v2 slice 2B: whether the "Curve" section is expanded.
    /// Collapsed by default, same reasoning as every other section bool —
    /// also means the ScrollView vertical-drag risk documented on
    /// `ToneCurveEditorView` is inert for anyone who never opens it.
    var isCurveSectionExpanded = false
    var isColorSectionExpanded = false
    var isSelectiveColorSectionExpanded = false
    var isBlackAndWhiteSectionExpanded = false
    /// Color Grading Slice B: whether the "Color Grading" section is
    /// expanded. Collapsed by default, same reasoning as every other
    /// section bool — also means the wheel's own drag interaction is inert
    /// for anyone who never opens it.
    var isColorGradingSectionExpanded = false
    var isEffectsSectionExpanded = false
    var isRedEyeSectionExpanded = false

    /// Whether the Levels histogram shows luminance only or luminance +
    /// per-channel RGB overlays. Presentation-only — `HistogramData` always
    /// carries all four; this just controls what `HistogramView` draws.
    /// Defaults to `.luminance` to match this histogram's original look.
    var histogramDisplayMode: HistogramDisplayMode = .luminance

    /// Which Selective Color band's Hue/Saturation/Luminance sliders are
    /// currently shown. Presentation-only, same reasoning as `selectedTab`/
    /// `selectedAspect` — `EditState` holds all 8 bands' values at once
    /// (24 flat fields), this just tracks which band's trio the panel
    /// displays right now.
    var selectedSelectiveColorBand: SelectiveColorBand = .red

    /// Phase 5 slice 2: whether the Presets section is expanded. Same
    /// reasoning as the six section bools above — must survive a Crop tab
    /// round-trip.
    var isPresetsSectionExpanded = false

    /// History panel: whether the "History" section is expanded. Same
    /// reasoning as every other section bool above — also means the row
    /// list only materializes (and its `ForEach` only does work) once the
    /// user actually opens it.
    var isHistorySectionExpanded = false

    /// Phase 6 slice 2: whether the RAW section is expanded. Same
    /// reasoning as every other section bool above.
    var isRawSectionExpanded = false

    /// Phase 7 slice 2: whether the Masks section is expanded. Same
    /// reasoning as every other section bool above.
    var isMasksSectionExpanded = false

    /// Which mask's sliders + on-image overlay are shown.
    /// Presentation-only, exactly like `selectedSelectiveColorBand` —
    /// `EditState.masks` holds every mask at once, this only tracks which
    /// one the panel is currently editing. Stored as the mask's own
    /// `UUID`, NOT an array index: deleting an earlier mask shifts every
    /// later index, so a stored index would silently retarget a different
    /// mask. `ContentView` also reads this directly (for overlay gating
    /// and `canZoom`), so unlike the purely-internal fields above, this
    /// one is not "the panel's private business."
    var selectedMaskID: UUID?

    /// Point Color Slice B: whether the "Point Color" section is expanded.
    /// Same reasoning as every other section bool above.
    var isPointColorSectionExpanded = false

    /// Which point color instance's sliders + eyedropper are shown.
    /// Presentation-only, exactly like `selectedMaskID` above — stored as
    /// the instance's own `UUID`, NOT an array index, same reasoning
    /// (deleting an earlier instance shifts every later index).
    var selectedPointColorID: UUID?

    /// Curves v2 slice 2B: which point curve control point (if any) is
    /// currently selected, driving `ToneCurveEditorView`'s detail readout
    /// and the "Delete Point" button. A plain `Int`, NOT an id — points
    /// carry no id at all (see `EditState.toneCurvePoints`'s own doc
    /// comment for why), so every read of this must go through
    /// `ToneCurveEditing.validated(_:in:)` rather than trust it directly:
    /// Undo/Redo/Revert/a preset apply can all shrink the array underneath
    /// a stale index. Curves v2 slice 3 adds one more such reason: this
    /// index is only meaningful relative to `selectedToneCurveChannel`'s
    /// OWN array — an index valid on Red is not meaningful applied to
    /// Blue — so `curveSection`'s channel picker explicitly resets this to
    /// `nil` on every channel change rather than leaving it to
    /// coincidentally still validate against the new array.
    var selectedToneCurvePointIndex: Int?

    /// Curves v2 slice 3: which of the four tone curves the Curve section
    /// currently shows/edits. Presentation-only, exactly like
    /// `selectedSelectiveColorBand` above — `EditState` holds all four
    /// point arrays (`toneCurvePoints`/`toneCurvePointsRed/Green/Blue`) at
    /// once; this only tracks which one the panel is currently editing.
    var selectedToneCurveChannel: ToneCurveChannel = .composite

    /// Color Grading Slice B: which of the 3 tonal ranges the section's
    /// single shared `ColorGradingWheelView` currently shows/edits.
    /// Presentation-only, exactly like `selectedSelectiveColorBand`/
    /// `selectedToneCurveChannel` above — `EditState` holds all 3 ranges'
    /// Hue/Saturation/Luminance at once; this only tracks which one the
    /// panel is currently editing.
    var selectedColorGradingRange: ColorGradingRange = .shadow
}

/// The Editor's Adjust tab: the six collapsible Light/Color/Selective Color/
/// Black & White/Effects/Red-Eye sections plus "Reset Adjustments".
struct AdjustTabView: View {
    @ObservedObject var document: ImageDocumentModel
    /// Phase 5 slice 2 (Presets) — the only reason this view needs
    /// `CatalogModel` at all; every other section only touches `document`.
    @ObservedObject var catalog: CatalogModel
    @Binding var panel: AdjustPanelState
    /// The Editor's single armed-interaction-mode value — owned by
    /// `ContentView` because the image pane reads it too (it gates
    /// `canZoom`, drives every tap-capture overlay, and is cleared when a
    /// different photo is loaded). Replaces 5 separate bindings (a bool
    /// each for WB/Red-Eye, a `UUID?` each for brush-painting/Color-Range-
    /// picking/Point-Color-picking) that this file's own arm/disarm sites
    /// used to keep mutually exclusive by hand — see `EditorInteractionMode`'s
    /// own doc comment for the full history (IMPROVEMENTS.md D14).
    @Binding var interactionMode: EditorInteractionMode
    /// Called when EITHER point-picking mode is entered. `ContentView` exits
    /// Compare and resets zoom/pan in response — passed as a callback so this
    /// view doesn't take bindings to three unrelated viewport states.
    let onEnterPointPickingMode: () -> Void

    /// "Save Preset" alert state. Local `@State`, NOT lifted into
    /// `AdjustPanelState` — safe because a presented `.alert` is modal on
    /// macOS, so the user structurally cannot switch to the Crop tab (the
    /// thing `AdjustPanelState` exists to survive) while it's up. Unlike
    /// the persistent section-expansion bools, there's no round-trip to
    /// preserve here.
    @State private var isPresentingSaveAlert = false
    @State private var newPresetName = ""

    /// Routes to the currently-selected Selective Color band's Hue field —
    /// `EditState` has 24 flat named fields (no array/dictionary, matching
    /// this codebase's established per-slider convention), so the panel
    /// needs this small dispatch to show just one band's trio at a time
    /// rather than 24 simultaneous rows.
    private func selectiveColorHueBinding(for band: SelectiveColorBand) -> Binding<Double> {
        switch band {
        case .red: return $document.editState.redHue
        case .orange: return $document.editState.orangeHue
        case .yellow: return $document.editState.yellowHue
        case .green: return $document.editState.greenHue
        case .aqua: return $document.editState.aquaHue
        case .blue: return $document.editState.blueHue
        case .purple: return $document.editState.purpleHue
        case .magenta: return $document.editState.magentaHue
        }
    }

    private func selectiveColorSaturationBinding(for band: SelectiveColorBand) -> Binding<Double> {
        switch band {
        case .red: return $document.editState.redSaturation
        case .orange: return $document.editState.orangeSaturation
        case .yellow: return $document.editState.yellowSaturation
        case .green: return $document.editState.greenSaturation
        case .aqua: return $document.editState.aquaSaturation
        case .blue: return $document.editState.blueSaturation
        case .purple: return $document.editState.purpleSaturation
        case .magenta: return $document.editState.magentaSaturation
        }
    }

    private func selectiveColorLuminanceBinding(for band: SelectiveColorBand) -> Binding<Double> {
        switch band {
        case .red: return $document.editState.redLuminance
        case .orange: return $document.editState.orangeLuminance
        case .yellow: return $document.editState.yellowLuminance
        case .green: return $document.editState.greenLuminance
        case .aqua: return $document.editState.aquaLuminance
        case .blue: return $document.editState.blueLuminance
        case .purple: return $document.editState.purpleLuminance
        case .magenta: return $document.editState.magentaLuminance
        }
    }

    /// Curves v2 slice 3: routes to whichever of the four tone-curve point
    /// arrays `channel` names — structurally identical to
    /// `selectiveColorHueBinding(for:)` above and for the same reason:
    /// `EditState` has four flat named array fields (matching this
    /// codebase's established per-field convention, not one array-of-
    /// arrays), so the panel needs this small dispatch to edit one curve
    /// at a time.
    private func toneCurvePointsBinding(for channel: ToneCurveChannel) -> Binding<[ToneCurvePoint]> {
        switch channel {
        case .composite: return $document.editState.toneCurvePoints
        case .red: return $document.editState.toneCurvePointsRed
        case .green: return $document.editState.toneCurvePointsGreen
        case .blue: return $document.editState.toneCurvePointsBlue
        }
    }

    /// Color Grading Slice B: routes to whichever of the 3 tonal ranges
    /// `range` names — structurally identical to
    /// `selectiveColorHueBinding(for:)` above and for the same reason:
    /// `EditState` has 9 flat named fields (matching this codebase's
    /// established per-field convention), so the panel needs this small
    /// dispatch to edit one range's trio at a time.
    private func colorGradingHueBinding(for range: ColorGradingRange) -> Binding<Double> {
        switch range {
        case .shadow: return $document.editState.shadowHue
        case .midtone: return $document.editState.midtoneHue
        case .highlight: return $document.editState.highlightHue
        }
    }

    private func colorGradingSaturationBinding(for range: ColorGradingRange) -> Binding<Double> {
        switch range {
        case .shadow: return $document.editState.shadowSaturation
        case .midtone: return $document.editState.midtoneSaturation
        case .highlight: return $document.editState.highlightSaturation
        }
    }

    private func colorGradingLuminanceBinding(for range: ColorGradingRange) -> Binding<Double> {
        switch range {
        case .shadow: return $document.editState.shadowLuminance
        case .midtone: return $document.editState.midtoneLuminance
        case .highlight: return $document.editState.highlightLuminance
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adjust")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            AdjustSectionContainer(icon: "sun.max", title: "Light", isExpanded: $panel.isLightSectionExpanded) {
                lightSection
            }
            Divider()
            AdjustSectionContainer(icon: "chart.xyaxis.line", title: "Curve", isExpanded: $panel.isCurveSectionExpanded) {
                curveSection
            }
            Divider()
            AdjustSectionContainer(icon: "paintpalette", title: "Color", isExpanded: $panel.isColorSectionExpanded) {
                colorSection
            }
            Divider()
            AdjustSectionContainer(
                icon: "square.grid.3x3", title: "Selective Color", isExpanded: $panel.isSelectiveColorSectionExpanded
            ) {
                selectiveColorSection
            }
            Divider()
            AdjustSectionContainer(
                icon: "eyedropper", title: "Point Color", isExpanded: pointColorSectionExpandedBinding
            ) {
                pointColorSection
            }
            Divider()
            AdjustSectionContainer(
                icon: "circle.lefthalf.filled", title: "Black & White", isExpanded: $panel.isBlackAndWhiteSectionExpanded
            ) {
                blackAndWhiteSection
            }
            Divider()
            AdjustSectionContainer(
                icon: "circle.hexagongrid", title: "Color Grading", isExpanded: $panel.isColorGradingSectionExpanded
            ) {
                colorGradingSection
            }
            Divider()
            AdjustSectionContainer(icon: "sparkles", title: "Effects", isExpanded: $panel.isEffectsSectionExpanded) {
                effectsSection
            }
            Divider()
            AdjustSectionContainer(
                icon: "eye.trianglebadge.exclamationmark", title: "Red-Eye", isExpanded: $panel.isRedEyeSectionExpanded
            ) {
                redEyeSection
            }
            Divider()
            AdjustSectionContainer(icon: "circle.dashed", title: "Masks", isExpanded: masksSectionExpandedBinding) {
                masksSection
            }
            rawSectionContainer
            Divider()
            AdjustSectionContainer(icon: "list.star", title: "Presets", isExpanded: $panel.isPresetsSectionExpanded) {
                presetsSection
            }
            Divider()
            AdjustSectionContainer(
                icon: "clock.arrow.circlepath", title: "History", isExpanded: $panel.isHistorySectionExpanded
            ) {
                historySection
            }
            Divider()
            resetAdjustmentsButton
        }
        .alert("Save Preset", isPresented: $isPresentingSaveAlert) {
            TextField("Name", text: $newPresetName)
            Button("Save") {
                // `applyingPreset(onto: .identity)` strips OUT this photo's
                // own geometry/redEyePoints before saving, reusing the same
                // field partition `applyPreset` later reads FROM — so a
                // saved preset is genuinely just "a look", never carrying
                // one photo's crop/straighten/flip/red-eye-point positions
                // as dead data alongside it.
                let reusableState = document.editState.applyingPreset(onto: .identity)
                catalog.createPreset(name: newPresetName, editState: reusableState)
                newPresetName = ""
            }
            Button("Cancel", role: .cancel) { newPresetName = "" }
        }
    }

    /// Tone/exposure-family controls, matching Apple Photos' own "Light"
    /// group — everything here operates on brightness/contrast/tonal
    /// range, not color. Just the rows — `AdjustSectionContainer` (see
    /// this view's `body`) supplies the section's own header/icon/
    /// disclosure chrome and its own `VStack(spacing: 14)` wrapper.
    private var lightSection: some View {
        Group {
            Button {
                document.autoTone()
            } label: {
                Label("Auto", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(document.currentImage == nil)
            .help("Automatically set Exposure, Contrast, Highlights, Shadows, Black Point and Vibrance")
            EditSliderRow(
                label: "Exposure", value: $document.editState.exposureEV,
                range: -5...5, identity: 0
            ) { String(format: "%+.2f EV", $0) }
            EditSliderRow(
                label: "Brightness", value: $document.editState.brightness,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Brilliance", value: $document.editState.brilliance,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Contrast", value: $document.editState.contrast,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Highlights", value: $document.editState.curvesHighlights,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Shadows", value: $document.editState.curvesShadows,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Black Point", value: $document.editState.blackPoint,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            Text("Levels").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $panel.histogramDisplayMode) {
                ForEach(HistogramDisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HistogramView(
                data: document.histogramData,
                channels: panel.histogramDisplayMode == .rgb ? .allChannels : .luminanceOnly
            )
            EditSliderRow(
                label: "Levels Black", value: $document.editState.levelsBlackPoint,
                range: 0...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Levels White", value: $document.editState.levelsWhitePoint,
                range: 0...1, identity: 1, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Levels Gamma", value: $document.editState.levelsGamma,
                range: 0.3...3.0, identity: 1.0
            ) { String(format: "%.2f", $0) }
        }
    }

    /// Curves v2 slice 2B: the interactive point-curve editor. Its own
    /// section, separate from `lightSection`'s Shadows/Highlights/Black
    /// Point sliders — those are the PARAMETRIC layer; this is the
    /// user's free-form ADDITIVE curve on top (`EditState.toneCurvePoints`'
    /// own doc comment). A 10-slider-plus-histogram Light section is
    /// already this sidebar's longest; a ~220pt canvas alongside it would
    /// make Light unmanageably long, and every other tool here already
    /// gets its own section.
    private var curveSection: some View {
        Group {
            Text("Applies on top of the Light sliders.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Curves v2 slice 3: which of the four curves the canvas below
            // shows/edits. A segmented `Picker`, matching `lightSection`'s
            // own `histogramDisplayMode` picker one section above — NOT
            // `SelectiveColorBand`'s row-of-tappable-swatch-circles pattern,
            // whose selection ring is drawn in `Color.white` (see that
            // section below): a selected white RGB swatch ringed in white
            // would be invisible, and this picker gets keyboard/VoiceOver
            // handling for free where the swatch row needed hand-written
            // accessibility traits.
            Picker("", selection: $panel.selectedToneCurveChannel) {
                ForEach(ToneCurveChannel.allCases) { channel in
                    Text(channelSegmentLabel(for: channel)).tag(channel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // An index into one channel's array is meaningless applied to
            // another's (see `selectedToneCurvePointIndex`'s own doc
            // comment) — cleared explicitly here rather than left to
            // coincidentally still validate against the new array.
            .onChange(of: panel.selectedToneCurveChannel) { _, _ in
                panel.selectedToneCurvePointIndex = nil
            }
            // `.id(channel)` is LOAD-BEARING, not decoration — the same
            // reasoning as `maskDetail`'s `.id(id)` below. `ToneCurveEditorView`
            // owns view-identity-scoped `@State`
            // (`draggedPointIndex`/`dragStartLocation`/
            // `didConsumeGestureAsDiscreteAction`) and `@FocusState`, two of
            // them array indices. That file's own `dragStartLocation` doc
            // comment already acknowledges its self-heal is "not an
            // unconditional guarantee" — a dropped `onEnded` (the enclosing
            // `ScrollView` can cancel a gesture) followed by a same-pixel
            // restart keeps stale state. Today that can only misfire within
            // ONE array; without a distinct identity per channel here, it
            // could misapply an index from one channel's array to a
            // completely different one after a channel switch. Cost is
            // zero: clicking this picker already moves key focus off the
            // canvas, so nothing is lost that the switch didn't already
            // destroy. Note this resets only the view's OWN internal
            // state — `selectedToneCurvePointIndex` lives in
            // `AdjustPanelState` outside this identity and still needs the
            // explicit `.onChange` reset above; neither mechanism
            // substitutes for the other.
            ToneCurveEditorView(
                points: toneCurvePointsBinding(for: panel.selectedToneCurveChannel),
                selectedIndex: $panel.selectedToneCurvePointIndex,
                histogramData: document.histogramData,
                channel: panel.selectedToneCurveChannel
            )
            .id(panel.selectedToneCurveChannel)
            Text(curvePointReadoutText)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Add Point") {
                    let binding = toneCurvePointsBinding(for: panel.selectedToneCurveChannel)
                    binding.wrappedValue = ToneCurveEditing.addingAtWidestGap(of: binding.wrappedValue)
                }
                .disabled(!ToneCurveEditing.canAddAtWidestGap(to: activeToneCurvePoints))
                Button("Delete Point") {
                    let binding = toneCurvePointsBinding(for: panel.selectedToneCurveChannel)
                    guard let index = ToneCurveEditing.validated(panel.selectedToneCurvePointIndex, in: binding.wrappedValue)
                    else { return }
                    binding.wrappedValue = ToneCurveEditing.removing(pointAt: index, in: binding.wrappedValue)
                    panel.selectedToneCurvePointIndex = nil
                }
                .disabled(!canDeleteSelectedCurvePoint)
            }
            .frame(maxWidth: .infinity)
            Button("Reset \(panel.selectedToneCurveChannel == .composite ? "Curve" : "\(panel.selectedToneCurveChannel.rawValue) Curve")") {
                document.resetToneCurve(panel.selectedToneCurveChannel)
                panel.selectedToneCurvePointIndex = nil
            }
            .frame(maxWidth: .infinity)
            .disabled(activeToneCurvePoints.isEmpty)
        }
    }

    /// The segmented picker's label for `channel` — its plain name, plus a
    /// trailing dot when that channel's curve is non-empty. Without this,
    /// an edited channel other than the one currently shown is invisible
    /// state: exactly the failure class this slice's own backend half was
    /// reviewer-caught shipping once already (`isAdjustTabAtIdentity` not
    /// accounting for the three new fields).
    private func channelSegmentLabel(for channel: ToneCurveChannel) -> String {
        toneCurvePointsBinding(for: channel).wrappedValue.isEmpty ? channel.rawValue : "\(channel.rawValue) •"
    }

    /// The currently-shown channel's own point array — a read-only
    /// convenience so `canDeleteSelectedCurvePoint`/`curvePointReadoutText`/
    /// the button `.disabled` checks above don't each re-derive
    /// `toneCurvePointsBinding(for:).wrappedValue` separately.
    private var activeToneCurvePoints: [ToneCurvePoint] {
        toneCurvePointsBinding(for: panel.selectedToneCurveChannel).wrappedValue
    }

    /// "Delete Point" is disabled with no selection AND for a selected
    /// endpoint (index 0 or the last index) — `ToneCurveEditing.removing`
    /// itself already refuses an endpoint, but disabling the button too
    /// means it doesn't sit there enabled and silently do nothing when
    /// pressed, the same UI-honesty reasoning `resetAdjustmentsButton`'s
    /// own disabled-state follows.
    private var canDeleteSelectedCurvePoint: Bool {
        let points = activeToneCurvePoints
        guard let index = ToneCurveEditing.validated(panel.selectedToneCurvePointIndex, in: points) else { return false }
        return index != 0 && index != points.count - 1
    }

    /// `String(format: "%.0f", ...)` doesn't trap on a non-finite value the
    /// way `Int(round(...))` does (it prints "nan"/"inf") — but a guard is
    /// added anyway, for the same reason `ToneCurveEditorView`'s own
    /// `accessibilityValueText` needs one: a hand-edited sidecar's `NaN`
    /// shouldn't read as legitimate-looking readout text either.
    private var curvePointReadoutText: String {
        let points = activeToneCurvePoints
        guard let index = ToneCurveEditing.validated(panel.selectedToneCurvePointIndex, in: points) else {
            return points.isEmpty ? "No curve" : "No point selected"
        }
        let point = points[index]
        guard point.x.isFinite, point.y.isFinite else { return "Value unavailable" }
        return String(format: "In %.0f  Out %.0f", point.x * 100, point.y * 100)
    }

    /// Color/white-balance-family controls, matching Apple Photos' own
    /// "Color" group. Just the rows — see `lightSection`'s comment.
    private var colorSection: some View {
        Group {
            EditSliderRow(
                label: "Temperature", value: $document.editState.whiteBalanceTemperature,
                range: 3500...9500, identity: 6500
            ) { String(format: "%.0fK", $0) }
            EditSliderRow(
                label: "Tint", value: $document.editState.whiteBalanceTint,
                range: -100...100, identity: 0
            ) { String(format: "%+.0f", $0) }
            Button {
                // `toggle` alone already replaces whatever else was armed
                // (brush/Color-Range/Point-Color) with `.pickingWhiteBalance`
                // or `.none` — only the two SELECTIONS (a separate concern
                // from armed-mode) still need clearing by hand here.
                interactionMode.toggle(.pickingWhiteBalance)
                if interactionMode.isPickingWhiteBalance {
                    panel.selectedMaskID = nil
                    panel.selectedPointColorID = nil
                    onEnterPointPickingMode()
                }
            } label: {
                Label("Pick White Balance", systemImage: "eyedropper")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(interactionMode.isPickingWhiteBalance ? .yellow : nil)
            .accessibilityAddTraits(interactionMode.isPickingWhiteBalance ? [.isSelected] : [])
            Button {
                document.fixColorCast()
            } label: {
                Label("Fix Color Cast", systemImage: "wand.and.rays")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(document.currentImage == nil)
            EditSliderRow(
                label: "Hue", value: $document.editState.hslHue,
                range: -180...180, identity: 0
            ) { String(format: "%+.0f°", $0) }
            EditSliderRow(
                label: "Vibrance", value: $document.editState.vibrance,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Saturation", value: $document.editState.hslSaturation,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
        }
    }

    /// Just the monochrome-mode toggle, given its own small section —
    /// matches Apple Photos giving Black & White its own distinct panel
    /// entry rather than lumping a mode toggle in with continuous sliders.
    /// Just the row — see `lightSection`'s comment.
    private var blackAndWhiteSection: some View {
        EditToggleRow(label: "Black & White", value: $document.editState.blackAndWhite)
    }

    /// Color Grading Slice B — 3-way Shadows/Midtones/Highlights color
    /// wheels. Mirrors `curveSection`'s exact structure (segmented picker
    /// -> single shared editor -> per-target Reset button), the same
    /// "one control, several bindable targets" shape, for the same reason:
    /// `EditState` has 9 flat named fields (3 ranges x Hue/Saturation/
    /// Luminance), so the panel needs this dispatch to show one range's
    /// trio at a time rather than 3 simultaneous wheels (a layout that
    /// would need its own, unproven compact-wheel sizing — see the Slice B
    /// plan's own layout decision).
    private var colorGradingSection: some View {
        Group {
            Text("Applies after Black & White — a colored tint here survives forced desaturation.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("", selection: $panel.selectedColorGradingRange) {
                ForEach(ColorGradingRange.allCases) { range in
                    // Plain, CONSTANT text — see `colorGradingEditedRangesSummary`'s
                    // own doc comment for why the edited-indicator moved
                    // OUT of this label entirely (a live-verified failure
                    // of the previous approach, not a style preference).
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            colorGradingEditedRangesSummary
            // `.id(range)` is PRECAUTIONARY, not load-bearing today —
            // unlike `curveSection`'s own `.id(channel)`, which closes a
            // real stale-per-gesture-index hazard in `ToneCurveEditorView`.
            // `ColorGradingWheelView` holds no `@State`/`@FocusState` at
            // all (see that view's own doc comment: every `onChanged`
            // callback writes `hue`/`saturation` directly, with no
            // per-gesture index to go stale), so this `.id` is currently a
            // no-op. Kept anyway, matching `curveSection`'s established
            // "one control, several bindable targets" shape, so that if
            // this view ever grows its own view-identity-scoped state it
            // already has the safe default rather than needing this call
            // site revisited.
            ColorGradingWheelView(
                hue: colorGradingHueBinding(for: panel.selectedColorGradingRange),
                saturation: colorGradingSaturationBinding(for: panel.selectedColorGradingRange)
            )
            .id(panel.selectedColorGradingRange)
            EditSliderRow(
                label: "Luminance",
                value: colorGradingLuminanceBinding(for: panel.selectedColorGradingRange),
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            Button("Reset \(panel.selectedColorGradingRange.rawValue)") {
                colorGradingHueBinding(for: panel.selectedColorGradingRange).wrappedValue = 0
                colorGradingSaturationBinding(for: panel.selectedColorGradingRange).wrappedValue = 0
                colorGradingLuminanceBinding(for: panel.selectedColorGradingRange).wrappedValue = 0
            }
            .frame(maxWidth: .infinity)
            .disabled(isSelectedColorGradingRangeAtIdentity)
        }
    }

    /// Single source of truth for "is `range` at identity" — shared by the
    /// edited-ranges summary caption and the per-range Reset button's
    /// disabled state, so the two can't disagree (an earlier draft checked
    /// Saturation/Luminance for the edited indicator (then a per-segment
    /// dot) but Hue+Saturation+Luminance for Reset, which — combined with
    /// a puck that could land at a non-zero Hue with near-zero Saturation
    /// — could show Reset enabled with that range absent from the
    /// indicator, the same "invisible edited state" failure class
    /// `channelSegmentLabel` above documents being reviewer-caught for the
    /// Curve section once already). `ColorWheelGeometry.polarValue`'s
    /// center snap keeps a puck dragged back to dead-center at exactly
    /// Hue 0/Saturation 0, so this trio reads as identity exactly when the
    /// wheel visually looks centered.
    private func isColorGradingRangeAtIdentity(_ range: ColorGradingRange) -> Bool {
        colorGradingHueBinding(for: range).wrappedValue == 0
            && colorGradingSaturationBinding(for: range).wrappedValue == 0
            && colorGradingLuminanceBinding(for: range).wrappedValue == 0
    }

    /// A plain caption summarizing which Shadows/Midtones/Highlights
    /// ranges are edited, so an edited range other than the one currently
    /// shown isn't invisible state (the same failure class
    /// `channelSegmentLabel` above already documents being
    /// reviewer-caught for the Curve section once). Hidden entirely
    /// (`Group` renders nothing) when no range is edited, matching this
    /// section's other identity-driven visibility precedents.
    ///
    /// Lives OUTSIDE the `Picker`'s own segment labels — attempt 4 (see
    /// IMPROVEMENTS.md's D21 for the numbering), and this time
    /// live-verified, design for this indicator. TWO PRIOR approaches
    /// were tried and DISPROVED live, both worth recording so neither
    /// gets rediscovered:
    /// 1. A trailing `" •"` appended to a segment's own label STRING when
    ///    that range left identity. `.pickerStyle(.segmented)` is backed
    ///    by a real `NSSegmentedControl`, which auto-sizes each segment to
    ///    its own label content — the string-length change visibly
    ///    shifted every segment after the one that grew. This is the bug
    ///    that started this whole fix.
    /// 2. Keeping that dot glyph always present and varying only its
    ///    color (`.clear` vs. inherited), reasoning a constant-length
    ///    string would keep widths fixed. A user screenshot disproved
    ///    this too: `NSSegmentedControl` takes each segment's PLAIN STRING
    ///    title and ignores `Text` styling entirely when drawing it, so
    ///    the dot rendered solid on every segment regardless of color,
    ///    silently making the indicator meaningless.
    ///
    /// A per-segment dot ALIGNED under each variably-sized native segment
    /// (a third design, also considered) has no reliable way to know each
    /// segment's actual rendered width from SwiftUI (`NSSegmentedControl`
    /// auto-sizes them to their own text, so "Highlights" is wider than
    /// "Shadows") — a plain summary sentence sidesteps needing that
    /// measurement at all, at the cost of being slightly less compact.
    /// This is ordinary SwiftUI `Text`, with no AppKit control bridging
    /// segment-by-segment, so it needs no special accessibility handling
    /// (or `.clear`-based visibility trick) at all — VoiceOver reads it
    /// exactly as it reads any other `Text` in this file. Live-verified
    /// with 3 progressive user screenshots — editing Shadows, then also
    /// Midtones, then also Highlights — confirming the caption read
    /// exactly "Edited: Shadows", then "Edited: Shadows, Midtones", then
    /// "Edited: Shadows, Midtones, Highlights" at each step, in that
    /// order.
    /// `channelSegmentLabel`'s identical STRING-length-based dot (not
    /// touched here) still has approach 1's original layout-shift risk —
    /// see its own IMPROVEMENTS.md entry (D21).
    private var colorGradingEditedRangesSummary: some View {
        let edited = ColorGradingRange.allCases.filter { !isColorGradingRangeAtIdentity($0) }
        return Group {
            if !edited.isEmpty {
                Text("Edited: \(edited.map(\.rawValue).joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isSelectedColorGradingRangeAtIdentity: Bool {
        isColorGradingRangeAtIdentity(panel.selectedColorGradingRange)
    }

    /// Vignette/Texture/Clarity/Dehaze/Sharpen/Noise Reduction/Defringe
    /// Purple/Defringe Green/Grain — the "finishing" controls, matching
    /// Apple Photos' own Effects/Detail grouping. Defringe sits right after
    /// Noise Reduction, matching its own pipeline position (after Sharpen,
    /// before Grain — see `EditState.defringePurple`'s own doc comment).
    /// Grain is last, matching its pipeline position (the true final
    /// stage). Just the rows — see `lightSection`'s comment.
    private var effectsSection: some View {
        Group {
            EditSliderRow(
                label: "Vignette", value: $document.editState.vignetteStrength,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Vignette Radius", value: $document.editState.vignetteRadius,
                range: 0...1, identity: 0.5, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Texture", value: $document.editState.texture,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Clarity", value: $document.editState.clarity,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Dehaze", value: $document.editState.dehaze,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Sharpen", value: $document.editState.sharpness,
                range: 0...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Noise Reduction", value: $document.editState.noiseReduction,
                range: 0...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Defringe Purple", value: $document.editState.defringePurple,
                range: 0...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Defringe Green", value: $document.editState.defringeGreen,
                range: 0...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Grain", value: $document.editState.grain,
                range: 0...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
        }
    }

    /// Red-Eye: a "Fix Red-Eye" toggle button (arms the tap-to-place/tap-
    /// to-remove overlay), shared Size/Strength sliders (apply to every
    /// placed point at once — this app has no per-point sliders, matching
    /// its established scope-cut pattern), and a "Clear All" button. Just
    /// the rows — see `lightSection`'s comment.
    private var redEyeSection: some View {
        Group {
            Button {
                // Mirrors the WB button above exactly — `toggle` alone
                // already replaces whatever else was armed.
                interactionMode.toggle(.placingRedEye)
                if interactionMode.isPlacingRedEyeCorrections {
                    panel.selectedMaskID = nil
                    panel.selectedPointColorID = nil
                    onEnterPointPickingMode()
                }
            } label: {
                Label("Fix Red-Eye", systemImage: "eye.trianglebadge.exclamationmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(interactionMode.isPlacingRedEyeCorrections ? .yellow : nil)
            .accessibilityAddTraits(interactionMode.isPlacingRedEyeCorrections ? [.isSelected] : [])
            EditSliderRow(
                label: "Red-Eye Size", value: $document.editState.redEyeSize,
                range: 0...1, identity: 0.5, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Red-Eye Strength", value: $document.editState.redEyeStrength,
                range: 0...1, identity: 0.7, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            Button("Clear All Red-Eye Corrections") {
                document.editState.redEyePoints.removeAll()
            }
            .disabled(document.editState.redEyePoints.isEmpty)
        }
    }

    /// Phase 7 slices 2-3: local (radial/ellipse and linear/graduated)
    /// adjustments. Add/select/delete chrome only — mirrors
    /// `presetsSection`'s shape (the only other existing dynamic
    /// add/delete list in this codebase): the row list itself
    /// (`maskListRows`) is a plain value `ForEach` over
    /// `document.editState.masks`, identical in spirit to
    /// `presetsSection`'s own `ForEach(catalog.presets)` — a row only
    /// reads `mask.id`/its position, it never writes. The write-back
    /// path lives one level down, in `maskDetail`: only the SELECTED
    /// mask's `EditSliderRow`s need a live `Binding<Mask>`, obtained via
    /// `$document.editState.mask(id:)` (`MaskBinding.swift`) rather than
    /// a plain value. The slider detail view for that mask is
    /// `MaskDetailView`, a separate top-level file — see that file's own
    /// doc comment for why it isn't inlined here.
    /// Reviewer-caught: collapsing the section while a mask is selected
    /// would otherwise hide the list/detail panel but leave mask-editing
    /// mode fully armed underneath (the on-image overlay stays, `canZoom`
    /// stays blocked) — with no visible way back in except Escape or
    /// re-expanding. Clearing the selection on collapse closes that gap;
    /// expanding never needs to touch it.
    private var masksSectionExpandedBinding: Binding<Bool> {
        Binding(
            get: { panel.isMasksSectionExpanded },
            set: { newValue in
                // Reviewer-caught: ONE write through `panel`, not two
                // sequential ones — `panel` is itself a `@Binding`, and two
                // separate read-modify-writes through it risk the second
                // clobbering the first if either ever observes a stale
                // snapshot instead of the live value.
                var next = panel
                next.isMasksSectionExpanded = newValue
                if !newValue { next.selectedMaskID = nil }
                panel = next
                if !newValue {
                    interactionMode.disarmMaskModes()
                }
            }
        )
    }

    private var masksSection: some View {
        Group {
            // Phase 7 slices 3-5: a 2x2 grid, not a single row or a Menu --
            // introducing a new mask KIND is exactly the moment
            // discoverability matters more than a compact control; a menu
            // click would bury the new option right when it most needs to
            // be seen. Live-verified (slice 4): the ORIGINAL "Add Radial"/
            // "Add Linear" labels, extended to a third "Add Brush" button
            // in one row, truncated to "Add Ra…"/"Add Lin…"/"Add Bru…" at
            // the sidebar's default width -- the SIDEBAR itself didn't
            // need to grow, but the labels did need to shrink; dropping
            // the shared "Add" prefix (kept in each button's own
            // accessibility label instead) fit all three. Adding a FOURTH
            // kind this slice (`.luminanceRange`) switched from that
            // single row to a 2x2 grid rather than a lone full-width
            // fourth button: at the sidebar's 260-380pt width a half-width
            // cell is ~115-180pt, comfortably more room per label than the
            // row of three already proved sufficient, and a lone full-width
            // button under three narrow ones would read as a different
            // CLASS of action, which it isn't. Plain nested `HStack`s, not
            // `LazyVGrid` -- this file has a documented Swift type-checker
            // blow-up history with over-packed `@ViewBuilder` closures.
            VStack(spacing: 8) {
                HStack {
                    Button("Radial") {
                        addMask(kind: .radial)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Add Radial Mask")
                    Button("Linear") {
                        addMask(kind: .linear)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Add Linear Mask")
                }
                HStack {
                    Button("Brush") {
                        addMask(kind: .brush)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Add Brush Mask")
                    Button("Luminance") {
                        addMask(kind: .luminanceRange)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Add Luminance Range Mask")
                }
                // Phase 7 slice 5 second half: a third row, one new
                // half-width "Color" button plus an explicit empty cell —
                // NOT a bare full-width button, which "would read as a
                // different CLASS of action" per this section's own
                // comment above; NOT re-gridding to 3+2 either, which
                // would move four already live-verified buttons for the
                // sake of one new one.
                HStack {
                    Button("Color") {
                        addMask(kind: .colorRange)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Add Color Range Mask")
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                }
            }
            .disabled(document.currentImage == nil)
            if document.editState.masks.isEmpty {
                Text("No masks yet").font(.caption).foregroundStyle(.secondary)
            } else {
                maskListRows
            }
            maskDetail
        }
    }

    /// Re-checked per `Mask.deterministicFallbackID`'s own doc comment,
    /// which asked this UI slice to confirm its collision reasoning still
    /// holds: it does — this section NEVER creates an id-less mask
    /// (`addMask()` below always goes through `Mask()`'s fresh `UUID()`
    /// default), so the only way two masks could ever share an id here is
    /// a hand-edited/corrupted sidecar with two id-less, field-identical
    /// masks in it — already the documented, accepted edge case, not
    /// something this `ForEach`/`delete(_:)` need to additionally guard
    /// against.
    private var maskListRows: some View {
        ForEach(Array(document.editState.masks.enumerated()), id: \.element.id) { index, mask in
            maskRow(number: index + 1, mask: mask)
        }
    }

    /// Label "Mask N" comes from ARRAY POSITION, not a persisted name field
    /// — v1 simplification matching CLAUDE.md's own "Mask 1, Mask 2…"
    /// wording; deleting an earlier mask renumbers later ones, an accepted
    /// tradeoff, not a bug. Numbering stays GLOBAL across both kinds
    /// (Phase 7 slice 3) rather than per-kind — masks composite
    /// SEQUENTIALLY in array order (`EditPipeline.applyMasks`), so a
    /// per-kind counter would visibly disagree with compositing order the
    /// moment a Radial and a Linear mask overlap.
    /// Exhaustive `switch`, not a ternary (Phase 7 slice 4 fix): the
    /// pre-slice-4 `mask.kind == .radial ? X : Y` ternaries compiled fine
    /// against a third case and would have silently mislabeled every Brush
    /// mask as Linear — closing that hazard is part of this feature, not
    /// an afterthought.
    private func maskKindIcon(_ kind: MaskKind) -> String {
        switch kind {
        case .radial: return "circle.dashed"
        case .linear: return "line.diagonal"
        case .brush: return "paintbrush.pointed"
        case .luminanceRange: return "circle.lefthalf.filled"
        case .colorRange: return "eyedropper"
        }
    }

    /// `static`, not `private` (Phase 7 slice 6, Session B): also called
    /// from `MaskCombineTarget.targets(excluding:in:)` in
    /// `MaskDetailView.swift`, so the combine-target picker's labels can
    /// never drift from `maskRow`'s own `Mask \(number)` text below —
    /// same purpose the doc comment above already states for this
    /// function's exhaustive-switch shape.
    static func maskKindLabel(_ kind: MaskKind) -> String {
        switch kind {
        case .radial: return "Radial"
        case .linear: return "Linear"
        case .brush: return "Brush"
        case .luminanceRange: return "Luminance Range"
        case .colorRange: return "Color Range"
        }
    }

    /// Whether `kind` draws an on-image overlay positioned against
    /// `currentFitRect`. Exhaustive on purpose — a future kind must fail
    /// to COMPILE here rather than silently inherit either answer (the
    /// same hazard `maskKindIcon`/`maskKindLabel`'s own history already
    /// records for a pre-slice-4 ternary). UI knowledge, not `EditEngine`
    /// knowledge — deliberately duplicated in `ContentView.swift` rather
    /// than shared, since `EditEngine` stays UI/rendering-API-free.
    private func hasOnImageOverlay(_ kind: MaskKind) -> Bool {
        switch kind {
        case .radial, .linear, .brush: return true
        case .luminanceRange, .colorRange: return false
        }
    }

    private func maskRow(number: Int, mask: Mask) -> some View {
        let isSelected = panel.selectedMaskID == mask.id
        return HStack {
            Button {
                select(mask)
            } label: {
                Label("Mask \(number)", systemImage: maskKindIcon(mask.kind))
            }
            .buttonStyle(.plain)
            .fontWeight(isSelected ? .semibold : .regular)
            .accessibilityLabel("Mask \(number), \(Self.maskKindLabel(mask.kind))")
            Spacer()
            Button {
                delete(mask)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel("Delete Mask \(number)")
        }
    }

    @ViewBuilder private var maskDetail: some View {
        if let id = panel.selectedMaskID, let binding = $document.editState.mask(id: id) {
            // `.id(id)` is LOAD-BEARING, not decoration: `EditSliderRow`
            // holds click-to-type `@State` (`isEditingText`/`editingText`/
            // `seedText`). Without a per-mask view identity here, switching
            // from Mask 1 to Mask 2 while a click-to-type field is open
            // would reuse the same view identity and could commit the
            // typed value into Mask 2's field instead of Mask 1's.
            MaskDetailView(
                mask: binding,
                onBeginBrushStroke: binding.wrappedValue.kind == .brush ? { beginBrushStroke(for: id) } : nil,
                onBeginColorPick: binding.wrappedValue.kind == .colorRange ? { beginColorPick(for: id) } : nil,
                // Recomputed on every body evaluation from the live
                // masks array (Phase 7 slice 6, Session B) — adding or
                // deleting a mask refreshes the combine-target picker for
                // free, no new observation machinery needed.
                combineTargets: MaskCombineTarget.targets(excluding: id, in: document.editState.masks)
            ).id(id)
        }
    }

    /// No armed "placement mode" needed, unlike Red-Eye/WB — a mask (either
    /// kind) has AREA, so a sensible default center/geometry is immediately
    /// visible and adjustable via `MaskDetailView`'s sliders (and, for
    /// `.radial`, the on-image overlay too) without a separate placement
    /// step. Holds for `.linear` just as much as `.radial`: a graduated
    /// band covering roughly half the frame at its default width is
    /// exactly as immediately visible as a default-sized ellipse.
    /// `.brush` arms paint mode immediately after creating + selecting the
    /// mask (WB's "arm then auto-disarm after one interaction" shape, NOT
    /// Red-Eye's "stays armed" shape — see `beginBrushStroke`'s own doc
    /// comment) — a brush stroke has no useful default shape the way a
    /// radial/linear mask's default geometry does, so there's nothing to
    /// show until the user paints. `.luminanceRange` (slice 5) ALSO needs
    /// no armed mode: its default `luminanceTarget 0.5`/`luminanceRange
    /// 0.3`/`feather 0.5` selects a soft midtone band that exists on
    /// essentially any photograph, immediately visible/adjustable the
    /// moment an adjustment slider moves — the same "has a sensible
    /// default" reasoning `.radial`/`.linear` already rely on, and
    /// structurally the closest thing in this section to the existing
    /// "Fix Color Cast" button: a plain click, zero overlay, zero armed
    /// mode, immediately usable.
    private func addMask(kind: MaskKind) {
        var mask = Mask()
        mask.kind = kind
        document.editState.masks.append(mask)
        select(mask)
        switch kind {
        case .brush:
            beginBrushStroke(for: mask.id)
        case .colorRange:
            beginColorPick(for: mask.id)
        case .radial, .linear, .luminanceRange:
            break
        }
    }

    /// Resets `interactionMode` to `.none` — selecting a mask (or another
    /// mask) disarms whatever else was armed, matching the WB/Red-Eye
    /// buttons' own disarm-on-arm shape.
    ///
    /// Reviewer-caught during slice 5's own design (not a live bug, a
    /// design correction before it could become one): `onEnterPointPickingMode()`
    /// resets `compareMode`/`zoomScale`/`panOffset` and grabs keyboard
    /// focus — all of which exist ONLY because an on-image overlay is
    /// positioned against an UN-ZOOMED `currentFitRect`. Calling it
    /// unconditionally would silently reset a user's zoom the moment they
    /// select a `.luminanceRange` mask, defeating `ContentView`'s own
    /// kind-aware `canZoom` fix (`isEditingOverlayMask`) for that exact
    /// kind. A mask kind with no overlay has nothing to protect.
    private func select(_ mask: Mask) {
        panel.selectedMaskID = mask.id
        interactionMode = .none
        if hasOnImageOverlay(mask.kind) {
            onEnterPointPickingMode()
        }
    }

    private func delete(_ mask: Mask) {
        document.editState.masks.removeAll { $0.id == mask.id }
        if panel.selectedMaskID == mask.id {
            panel.selectedMaskID = nil
        }
        interactionMode.disarm(.paintingBrush(maskID: mask.id))
        interactionMode.disarm(.pickingColorRange(maskID: mask.id))
    }

    /// Arms live brush-paint mode for `id` — called both by `addMask` (a
    /// freshly-created, unpainted mask) and by `MaskDetailView`'s "Paint
    /// Stroke"/"Redraw Stroke" button (a previously-painted mask, re-armed
    /// to replace its stroke). Deliberately does NOT clear `brushPoints`
    /// (F5): `BrushMaskOverlayView`'s own `onChanged` replaces the array
    /// wholesale on the new gesture's FIRST point, so pressing Escape
    /// right after arming (before drawing) leaves an existing stroke
    /// intact rather than discarding it early.
    private func beginBrushStroke(for id: UUID) {
        interactionMode = .paintingBrush(maskID: id)
        onEnterPointPickingMode()
    }

    /// Arms the Color Range eyedropper for `id` — assigning `interactionMode`
    /// directly already disarms WB/Red-Eye/brush, but this ALSO calls
    /// `onEnterPointPickingMode()` UNCONDITIONALLY, independent of
    /// `hasOnImageOverlay(.colorRange)` (which is `false` — see that
    /// function's own doc comment): that gate answers "does merely
    /// SELECTING this mask need an overlay reset," but ARMING a tap
    /// genuinely needs the zoom/pan reset regardless of overlay ownership —
    /// the eyedropper's own tap-capture layer is positioned against an
    /// un-zoomed `currentFitRect`, same as WB's.
    private func beginColorPick(for id: UUID) {
        interactionMode = .pickingColorRange(maskID: id)
        onEnterPointPickingMode()
    }

    // MARK: - Point Color

    /// Mirrors `masksSectionExpandedBinding` exactly: ONE write through
    /// `panel`, not two sequential ones, and disarms the eyedropper on
    /// collapse.
    private var pointColorSectionExpandedBinding: Binding<Bool> {
        Binding(
            get: { panel.isPointColorSectionExpanded },
            set: { newValue in
                var next = panel
                next.isPointColorSectionExpanded = newValue
                if !newValue { next.selectedPointColorID = nil }
                panel = next
                if !newValue {
                    interactionMode.disarmPointColorPick()
                }
            }
        )
    }

    /// No add-then-pick-a-kind step, unlike `masksSection` — there is only
    /// one kind, so "Add Point Color" immediately selects the new instance
    /// AND arms its eyedropper in one action (mirroring `addMask(kind:
    /// .colorRange)`'s own shape exactly).
    private var pointColorSection: some View {
        Group {
            Button("Add Point Color") {
                addPointColor()
            }
            .frame(maxWidth: .infinity)
            .disabled(document.currentImage == nil)
            if document.editState.pointColors.isEmpty {
                Text("No point colors yet").font(.caption).foregroundStyle(.secondary)
            } else {
                pointColorListRows
            }
            pointColorDetail
        }
    }

    /// Label "Point Color N" comes from ARRAY POSITION, same tradeoff
    /// `maskRow`'s own doc comment already accepts for masks — deleting an
    /// earlier instance renumbers later ones.
    private var pointColorListRows: some View {
        ForEach(Array(document.editState.pointColors.enumerated()), id: \.element.id) { index, pointColor in
            pointColorRow(number: index + 1, pointColor: pointColor)
        }
    }

    private func pointColorRow(number: Int, pointColor: PointColor) -> some View {
        let isSelected = panel.selectedPointColorID == pointColor.id
        return HStack {
            Button {
                selectPointColor(pointColor)
            } label: {
                Label("Point Color \(number)", systemImage: "eyedropper")
            }
            .buttonStyle(.plain)
            .fontWeight(isSelected ? .semibold : .regular)
            .accessibilityLabel("Point Color \(number)")
            Spacer()
            Button {
                deletePointColor(pointColor)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel("Delete Point Color \(number)")
        }
    }

    @ViewBuilder private var pointColorDetail: some View {
        if let id = panel.selectedPointColorID, let binding = $document.editState.pointColor(id: id) {
            // `.id(id)` is LOAD-BEARING, same reasoning as `maskDetail`'s
            // own comment: `EditSliderRow` holds click-to-type `@State`,
            // and without per-instance view identity a typed value could
            // commit into the wrong instance after switching selection.
            PointColorDetailView(
                pointColor: binding,
                onBeginColorPick: { beginPointColorPick(for: id) }
            ).id(id)
        }
    }

    private func addPointColor() {
        let pointColor = PointColor()
        document.editState.pointColors.append(pointColor)
        selectPointColor(pointColor)
        beginPointColorPick(for: pointColor.id)
    }

    /// No on-image overlay to protect (this kind has none, matching
    /// `.colorRange`'s own `hasOnImageOverlay` == false) — selecting an
    /// ALREADY-picked instance should not reset the viewport the way
    /// arming a NEW pick does; only `beginPointColorPick` below calls
    /// `onEnterPointPickingMode()`.
    private func selectPointColor(_ pointColor: PointColor) {
        panel.selectedPointColorID = pointColor.id
        // Reviewer-caught: without this, arming instance 1's eyedropper
        // then clicking instance 2's row left the eyedropper armed on 1
        // while the detail panel showed 2 — the next tap wrote into the
        // WRONG instance, and the orphaned unpicked instance 1 never got
        // discarded (`isPointColorSelected` stays true, since instance 2
        // still exists).
        interactionMode = .none
    }

    private func deletePointColor(_ pointColor: PointColor) {
        document.editState.pointColors.removeAll { $0.id == pointColor.id }
        if panel.selectedPointColorID == pointColor.id {
            panel.selectedPointColorID = nil
        }
        interactionMode.disarm(.pickingPointColor(pointColorID: pointColor.id))
    }

    /// Arms this instance's eyedropper — assigning `interactionMode` directly
    /// already disarms WB/Red-Eye/brush/Color-Range, but this ALSO calls
    /// `onEnterPointPickingMode()` UNCONDITIONALLY, independent of any
    /// on-image overlay, since the tap-capture layer itself needs the
    /// un-zoomed `currentFitRect` regardless.
    private func beginPointColorPick(for id: UUID) {
        interactionMode = .pickingPointColor(pointColorID: id)
        onEnterPointPickingMode()
    }

    /// Phase 6 slice 2: true if the currently-open photo is a RAW file.
    /// `document.currentURL` is `@Published`, so this tracks Library-grid/
    /// filmstrip/⌘←⌘→ navigation on its own without any extra wiring.
    /// `RawDecoder.isRaw` is a cheap synchronous UTType check, safe to call
    /// from a view body.
    private var isCurrentPhotoRaw: Bool {
        guard let url = document.currentURL else { return false }
        return RawDecoder.isRaw(url)
    }

    /// The Adjust panel's first RAW-conditional section — hidden entirely
    /// for non-RAW photos rather than shown-and-disabled, because
    /// `CIRAWFilter`'s RAW-native controls structurally cannot apply to a
    /// JPEG and a greyed-out row would imply otherwise. Bundled with its
    /// own `Divider` into ONE `@ViewBuilder` property so `body`'s `VStack`
    /// gains exactly one child either way — this file has a documented
    /// type-checker blow-up from over-packed `@ViewBuilder` closures (see
    /// `presetsSection`'s own comment); don't repeat that.
    @ViewBuilder private var rawSectionContainer: some View {
        if isCurrentPhotoRaw {
            Divider()
            AdjustSectionContainer(icon: "camera.aperture", title: "RAW", isExpanded: $panel.isRawSectionExpanded) {
                rawSection
            }
        }
    }

    /// Nine controls now (slice 2 shipped `boostAmount`; slice 3 added RAW
    /// Exposure/Shadow Boost; slice 5 added the RAW NR/Sharpness rows;
    /// slice 6 added RAW Contrast/Detail/Moiré Reduction below — the WB
    /// eyedropper's own `rawWhiteBalanceNeutralPoints`, added in slice 4,
    /// deliberately has NO row here at all, see below).
    /// `lensCorrectionEnabled` (the original slice-2 candidate) was
    /// measured unsupported on this app's own test camera before any code
    /// was written, and the rest of `CIRAWFilter`'s controls are deferred
    /// to a future slice — see CLAUDE.md/PROGRESS.md. RAW Exposure is an
    /// ABSOLUTE decoder-level EV (`0` is the SDK's own fixed default,
    /// independent of camera profile). Shadow Boost, RAW Color NR, and
    /// RAW Sharpness are RELATIVE (multiplicative) to the file's own
    /// native decoder value, not absolute — see
    /// `EditState.shadowBoostScale`'s doc comment for why (measured
    /// per-file camera-profile default, not the API's declared default)
    /// — so `100%` genuinely means "untouched." RAW Luminance NR, RAW
    /// Contrast, RAW Detail, and RAW Moiré Reduction are DIFFERENT — all
    /// ADDITIVE offsets (`+0%` is untouched, not `100%`) — reviewer-caught
    /// in slice 5, then applied proactively in slice 6: this camera's own
    /// native value for ALL FOUR underlying properties measures `0.0`, so
    /// a multiplicative scale would have been a provably dead control
    /// across its entire range (`0 * anything == 0`) for every one of
    /// them; see each field's own `EditState` doc comment. RAW Moiré
    /// Reduction's range is additionally capped narrower (`-1...1`) than
    /// what `CIRAWFilter` itself accepts, since the measured effect
    /// saturates hard above that — see
    /// `EditState.rawMoireReductionAdjust`'s own doc comment. Shadow
    /// Boost is additionally disabled whenever Boost Amount is `0` — the
    /// SDK header states it "has no effect if the boostAmount is 0," so
    /// it would otherwise be a dead control with no visible feedback, the
    /// exact trap `lensCorrectionEnabled` was deferred to avoid. All six
    /// NR/Sharpness/Contrast/Detail/Moiré rows are EACH disabled
    /// individually via `document.currentRawAdjustmentSupport` — every
    /// one of the underlying `isXSupported` flags is the same class of
    /// per-camera-profile capability flag as `isLensCorrectionSupported`
    /// (measured `true` on this app's test camera for all six, but not
    /// guaranteed on every camera). Disabled while a decode is in flight:
    /// unlike every other row in this panel, releasing any of these
    /// sliders costs a full RAW re-decode (see
    /// `ImageDocumentModel.redecodeForRawNativeChange`), so none may be
    /// draggable again mid-decode.
    ///
    /// `rawWhiteBalanceNeutralPoints` (slice 4) has no row in this
    /// section — it's written only by the WB eyedropper tool, not
    /// dragged like the others, and this is a known, accepted gap: it
    /// has NO visible representation anywhere (see
    /// `isAdjustTabAtIdentity`'s own doc comment below for the fuller
    /// note on this).
    private var rawSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditSliderRow(
                label: "Boost Amount", value: $document.editState.boostAmount,
                range: 0...1, identity: 1.0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "RAW Exposure", value: $document.editState.rawExposureEV,
                range: -2...2, identity: 0
            ) { String(format: "%+.2f EV", $0) }
            EditSliderRow(
                label: "Shadow Boost", value: $document.editState.shadowBoostScale,
                range: 0...1, identity: 1.0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
                .disabled(document.editState.boostAmount == 0)
            EditSliderRow(
                label: "RAW Luminance NR", value: $document.editState.rawLuminanceNoiseReductionAdjust,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
                .disabled(!document.currentRawAdjustmentSupport.luminanceNoiseReduction)
            EditSliderRow(
                label: "RAW Color NR", value: $document.editState.rawColorNoiseReductionScale,
                range: 0...1, identity: 1.0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
                .disabled(!document.currentRawAdjustmentSupport.colorNoiseReduction)
            EditSliderRow(
                label: "RAW Sharpness", value: $document.editState.rawSharpnessScale,
                range: 0...1, identity: 1.0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
                .disabled(!document.currentRawAdjustmentSupport.sharpness)
            EditSliderRow(
                label: "RAW Contrast", value: $document.editState.rawContrastAdjust,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
                .disabled(!document.currentRawAdjustmentSupport.contrast)
            EditSliderRow(
                label: "RAW Detail", value: $document.editState.rawDetailAdjust,
                range: -3...3, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
                .disabled(!document.currentRawAdjustmentSupport.detail)
            EditSliderRow(
                label: "RAW Moiré Reduction", value: $document.editState.rawMoireReductionAdjust,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
                .disabled(!document.currentRawAdjustmentSupport.moireReduction)
        }
        .disabled(document.isLoadingImage)
    }

    /// Phase 5 slice 2: save the current photo's color/tone adjustments as
    /// a named, reusable preset, or apply/delete an already-saved one.
    /// Deliberately no nested `Menu` here (unlike the Library grid's
    /// collections picker) — this session already hit a real Swift
    /// type-checker failure from packing too much into one `@ViewBuilder`
    /// closure (the toolbar's `.toolbar {}`), so this stays a flat list of
    /// plain rows.
    private var presetsSection: some View {
        Group {
            Button("Save Preset…") {
                isPresentingSaveAlert = true
            }
            .frame(maxWidth: .infinity)
            if catalog.presets.isEmpty {
                Text("No saved presets yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(catalog.presets) { preset in
                    HStack {
                        Button(preset.name) {
                            document.applyPreset(preset)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            catalog.deletePreset(preset)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Delete preset \(preset.name)")
                    }
                }
            }
        }
    }

    /// History panel: a flat, browsable/scrubbable list of every committed
    /// `EditHistory` checkpoint for the current photo — the whole point,
    /// per this feature's own roadmap line, being that it's "not just
    /// linear undo": any row is directly tappable, not just one step at a
    /// time like the toolbar's Undo/Redo buttons.
    ///
    /// Deliberately a plain `ForEach` appended straight into this section's
    /// own `VStack` — matching `presetsSection`/`masksSection` exactly, NOT
    /// a nested `ScrollView`. The whole Adjust sidebar is already one big
    /// `ScrollView`; nesting a second scrolling list inside it risks the
    /// same class of gesture conflict Curves v2 slice 2B's own
    /// vertical-drag-inside-a-vertically-scrolling-sidebar issue already
    /// documents in this codebase (see `ToneCurveEditorView`). Deliberately
    /// uncapped (up to `EditHistory`'s own `limit + 1` = 101 rows): a fixed
    /// "last N" window was considered and rejected, since after N+ undos or
    /// jumps the current row would scroll out of the visible window
    /// entirely, with no highlighted row left to orient by. If row count
    /// ever proves to be a real problem in practice, the fix is lowering
    /// `EditHistory`'s own `limit`, not truncating what's displayed out of
    /// it.
    ///
    /// Rows are shown NEWEST FIRST (`.enumerated().reversed()`), matching
    /// Lightroom's own History panel convention — the opposite order from
    /// `EditHistory.entries`' own oldest-first storage order.
    private var historySection: some View {
        Group {
            if document.historyEntries.isEmpty {
                Text("No history yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(document.historyEntries.enumerated()).reversed(), id: \.element.id) { index, entry in
                    let isCurrent = index == document.currentHistoryIndex
                    // Rows AFTER the cursor are the "redo" branch the next
                    // edit would abandon — secondary-styled so the list
                    // visually communicates that before it happens, not
                    // just after.
                    let isAbandonedOnNextEdit = index > document.currentHistoryIndex

                    Button {
                        document.jumpToHistory(id: entry.id)
                    } label: {
                        HStack {
                            Text(entry.summary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .fontWeight(isCurrent ? .semibold : .regular)
                                .foregroundStyle(isAbandonedOnNextEdit ? .secondary : .primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(entry.summary)\(isCurrent ? ", current" : isAbandonedOnNextEdit ? ", undone" : "")"
                    )
                }
            }
        }
    }

    /// Resets every Light/Color/Selective Color/B&W/Effects/Red-Eye field
    /// to its own default — the SAME identity value each field's own
    /// `EditSliderRow`/`EditToggleRow` already resets to individually via
    /// its per-row Reset button, just all at once. Deliberately does NOT
    /// touch crop/straighten/perspective/transformScale/transformAspect/
    /// flip (those live in the Crop tab, out of this button's scope,
    /// matching how the reference
    /// screenshot's own "Reset Adjustments" is scoped to the Adjust panel
    /// it's shown in) and does NOT clear placed Red-Eye correction points
    /// (a separate, more destructive action with its own dedicated
    /// "Clear All Red-Eye Corrections" button above) — this only resets
    /// continuous adjustment VALUES. `masks` (Phase 7 slice 2) follows the
    /// identical pattern: deleting a mask is a list operation with its own
    /// per-row trash button in `masksSection`, not something this button
    /// touches — the omission is deliberate, mirroring `redEyePoints`, not
    /// an oversight.
    /// Reviewer-flagged, deliberate, documented gap: this deliberately
    /// mirrors `comparisonOriginal()`'s field list, which does NOT include
    /// any of the ELEVEN RAW-native fields (`boostAmount`, `rawExposureEV`,
    /// `shadowBoostScale`, `rawWhiteBalanceNeutralPoints`,
    /// `rawLuminanceNoiseReductionAdjust`, `rawColorNoiseReductionScale`,
    /// `rawSharpnessScale`, `rawContrastAdjust`, `rawDetailAdjust`,
    /// `rawMoireReductionAdjust`, `rawDecoderVersionPin` — see that
    /// method's own doc comment: `EditPipeline` can't express any of them,
    /// so resetting them here would trigger an unwanted full RAW re-decode
    /// from what should be an instant, free action). Consequence: a RAW
    /// photo with every OTHER field at identity but a non-default RAW
    /// section slider shows this button (correctly) disabled, even though
    /// the RAW section's own sliders are visibly non-identity —
    /// `revertToOriginal()`'s literal `EditState()` commit is the control
    /// that resets the other ten, not this one (`rawDecoderVersionPin` is
    /// the one exception — see its own paragraph below).
    ///
    /// `rawWhiteBalanceNeutralPoints` specifically is WORSE than the
    /// other RAW-native fields here — reviewer-caught: it has no slider or
    /// any other visible representation in this section AT ALL, so a
    /// RAW-native WB eyedropper tap is genuinely invisible state once set:
    /// neither this button, nor the RAW section's own sliders, show
    /// anything changed. Only Undo or Revert to Original clears it.
    /// Accepted as a known gap for this slice (see PROGRESS.md) rather
    /// than adding a dedicated affordance — flag if a future session's UI
    /// work in this file touches the RAW section, since a "neutral point
    /// set (tap to clear)" indicator would be the natural fix.
    ///
    /// `rawDecoderVersionPin` (Phase 6 slice 7) has NO row here, and never
    /// will — unlike the other ten RAW-native fields, it isn't a
    /// creative/tunable control at all, so there's nothing to draw a
    /// slider for. It exists purely so replaying a photo's saved edits
    /// decodes identically after a future macOS/Core Image update, and is
    /// set exactly once, automatically, the first time a RAW photo is
    /// opened (see `EditState.rawDecoderVersionPin`'s and
    /// `ImageDocumentModel.load(from:)`'s own doc comments). It's also the
    /// one RAW-native field `revertToOriginal()` deliberately does NOT
    /// reset — clearing a photo's determinism pin on revert would silently
    /// let a later re-decode use a different decoder algorithm than the
    /// rest of that photo's history did. If a future session is tempted to
    /// "fix" the apparent missing UI row for this field, don't — the
    /// omission is intentional, not an oversight.
    private var isAdjustTabAtIdentity: Bool {
        let state = document.editState
        return state.exposureEV == 0
            && state.brightness == 0
            && state.brilliance == 0
            && state.contrast == 0
            && state.curvesHighlights == 0
            && state.curvesShadows == 0
            && state.blackPoint == 0
            // A non-empty but identity-SHAPED curve reads as non-identity
            // here, so Reset Adjustments stays enabled and clicking it
            // deletes the points — consistent with how this button treats
            // every other field. Same reasoning for the three per-channel
            // curves (Curves v2 slice 3) — set via the Curve section's
            // channel picker (`curveSection`), `applyingPreset(onto:)`, or
            // sidecar decode, so this check and the reset button below must
            // account for them.
            && state.toneCurvePoints.isEmpty
            && state.toneCurvePointsRed.isEmpty
            && state.toneCurvePointsGreen.isEmpty
            && state.toneCurvePointsBlue.isEmpty
            && state.levelsBlackPoint == 0
            && state.levelsWhitePoint == 1
            && state.levelsGamma == 1.0
            && state.whiteBalanceTemperature == 6500
            && state.whiteBalanceTint == 0
            && state.hslHue == 0
            && state.vibrance == 0
            && state.hslSaturation == 0
            && state.selectiveColorRange == 0.5
            && SelectiveColorBand.allCases.allSatisfy { band in
                selectiveColorHueBinding(for: band).wrappedValue == 0
                    && selectiveColorSaturationBinding(for: band).wrappedValue == 0
                    && selectiveColorLuminanceBinding(for: band).wrappedValue == 0
            }
            && !state.blackAndWhite
            // Color Grading's Hue fields are rendering-irrelevant at
            // Saturation 0 (see `EditState.shadowHue`'s own doc comment),
            // but are still checked/reset here for the same reason
            // `vignetteRadius`/`selectiveColorRange` are just above: this
            // button and check's own established convention is "every
            // field is at its literal declared default," not "rendering is
            // currently identical to identity."
            && state.shadowHue == 0
            && state.shadowSaturation == 0
            && state.shadowLuminance == 0
            && state.midtoneHue == 0
            && state.midtoneSaturation == 0
            && state.midtoneLuminance == 0
            && state.highlightHue == 0
            && state.highlightSaturation == 0
            && state.highlightLuminance == 0
            && state.vignetteStrength == 0
            && state.vignetteRadius == 0.5
            && state.texture == 0
            && state.clarity == 0
            && state.dehaze == 0
            && state.sharpness == 0
            && state.noiseReduction == 0
            && state.defringePurple == 0
            && state.defringeGreen == 0
            && state.grain == 0
            && state.redEyeSize == 0.5
            && state.redEyeStrength == 0.7
    }

    private var resetAdjustmentsButton: some View {
        Button {
            document.editState.exposureEV = 0
            document.editState.brightness = 0
            document.editState.brilliance = 0
            document.editState.contrast = 0
            document.editState.curvesHighlights = 0
            document.editState.curvesShadows = 0
            document.editState.blackPoint = 0
            document.editState.toneCurvePoints = []
            document.editState.toneCurvePointsRed = []
            document.editState.toneCurvePointsGreen = []
            document.editState.toneCurvePointsBlue = []
            document.editState.levelsBlackPoint = 0
            document.editState.levelsWhitePoint = 1
            document.editState.levelsGamma = 1.0
            document.editState.whiteBalanceTemperature = 6500
            document.editState.whiteBalanceTint = 0
            document.editState.hslHue = 0
            document.editState.vibrance = 0
            document.editState.hslSaturation = 0
            document.editState.selectiveColorRange = 0.5
            for band in SelectiveColorBand.allCases {
                selectiveColorHueBinding(for: band).wrappedValue = 0
                selectiveColorSaturationBinding(for: band).wrappedValue = 0
                selectiveColorLuminanceBinding(for: band).wrappedValue = 0
            }
            document.editState.blackAndWhite = false
            document.editState.shadowHue = 0
            document.editState.shadowSaturation = 0
            document.editState.shadowLuminance = 0
            document.editState.midtoneHue = 0
            document.editState.midtoneSaturation = 0
            document.editState.midtoneLuminance = 0
            document.editState.highlightHue = 0
            document.editState.highlightSaturation = 0
            document.editState.highlightLuminance = 0
            document.editState.vignetteStrength = 0
            document.editState.vignetteRadius = 0.5
            document.editState.texture = 0
            document.editState.clarity = 0
            document.editState.dehaze = 0
            document.editState.sharpness = 0
            document.editState.noiseReduction = 0
            document.editState.defringePurple = 0
            document.editState.defringeGreen = 0
            document.editState.grain = 0
            document.editState.redEyeSize = 0.5
            document.editState.redEyeStrength = 0.7
        } label: {
            Text("Reset Adjustments")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isAdjustTabAtIdentity)
    }

    /// Selective Color (HSL v2): a row of 8 tappable band swatches (the
    /// selected one ringed), one shared Range slider, then the 3 sliders
    /// for whichever band is currently selected — NOT a top-level
    /// `EditorTab` (that's fixed to mirror Apple Photos' own tab bar, see
    /// `EditorTab`'s doc comment; Photos itself doesn't give this a
    /// separate top-level tab either), and NOT 24 simultaneous rows, which
    /// wouldn't fit this panel's scale. Just the rows — see
    /// `lightSection`'s comment (spacing is now 14, from
    /// `AdjustSectionContainer`, not this section's own former 8).
    private var selectiveColorSection: some View {
        Group {
            // 22pt circles + 6pt spacing = 8*22 + 7*6 = 218pt — fits the
            // sidebar's own MINIMUM width (260pt, ~228pt usable after
            // horizontal padding) with ~10pt to spare. The original
            // regression was 22pt circles at 10pt spacing (246pt, didn't
            // fit); keeping the 22pt diameter the user asked for but at
            // the tighter 6pt spacing recovers that size without
            // reintroducing the overflow.
            HStack(spacing: 6) {
                ForEach(SelectiveColorBand.allCases, id: \.self) { band in
                    Button {
                        panel.selectedSelectiveColorBand = band
                    } label: {
                        Circle()
                            .fill(band.swatchColor)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: panel.selectedSelectiveColorBand == band ? 2 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(band.label)
                    .accessibilityAddTraits(panel.selectedSelectiveColorBand == band ? [.isSelected] : [])
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            EditSliderRow(
                label: "Range", value: $document.editState.selectiveColorRange,
                range: 0...1, identity: 0.5, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "\(panel.selectedSelectiveColorBand.label) Hue",
                value: selectiveColorHueBinding(for: panel.selectedSelectiveColorBand),
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "\(panel.selectedSelectiveColorBand.label) Saturation",
                value: selectiveColorSaturationBinding(for: panel.selectedSelectiveColorBand),
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "\(panel.selectedSelectiveColorBand.label) Luminance",
                value: selectiveColorLuminanceBinding(for: panel.selectedSelectiveColorBand),
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
        }
    }
}

/// A collapsible Adjust-tab section — an icon + title + native disclosure
/// chevron (`DisclosureGroup`'s own, not hand-drawn) that expands to a
/// `VStack(spacing: 14)` of whatever rows `content` provides. Every
/// section's own computed property (`lightSection`, `colorSection`, etc.)
/// supplies only its rows; this supplies the shared header/collapse
/// chrome — matches Apple Photos' own per-section header treatment.
/// Plain SwiftUI (`DisclosureGroup` is a built-in view, no custom
/// gesture/AppKit-interop code), unrelated to this sidebar's documented
/// `NSScrollView`-probing history (see the "StableScrollInsets saga" in
/// `PROGRESS.md`) — that was a hand-written `NSViewRepresentable`, this
/// is not.
private struct AdjustSectionContainer<Content: View>: View {
    let icon: String
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(.top, 8)
        } label: {
            Label(title, systemImage: icon).font(.headline)
        }
    }
}
