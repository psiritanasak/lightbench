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
    var isColorSectionExpanded = false
    var isSelectiveColorSectionExpanded = false
    var isBlackAndWhiteSectionExpanded = false
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

    /// Phase 6 slice 2: whether the RAW section is expanded. Same
    /// reasoning as every other section bool above.
    var isRawSectionExpanded = false
}

/// The Editor's Adjust tab: the six collapsible Light/Color/Selective Color/
/// Black & White/Effects/Red-Eye sections plus "Reset Adjustments".
struct AdjustTabView: View {
    @ObservedObject var document: ImageDocumentModel
    /// Phase 5 slice 2 (Presets) — the only reason this view needs
    /// `CatalogModel` at all; every other section only touches `document`.
    @ObservedObject var catalog: CatalogModel
    @Binding var panel: AdjustPanelState
    /// Owned by `ContentView` because the image pane reads them too — they
    /// gate zooming (`canZoom`), drive the tap overlays, and are cleared when
    /// a different photo is loaded.
    @Binding var isPickingWhiteBalance: Bool
    @Binding var isPlacingRedEyeCorrections: Bool
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
                icon: "circle.lefthalf.filled", title: "Black & White", isExpanded: $panel.isBlackAndWhiteSectionExpanded
            ) {
                blackAndWhiteSection
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
            rawSectionContainer
            Divider()
            AdjustSectionContainer(icon: "list.star", title: "Presets", isExpanded: $panel.isPresetsSectionExpanded) {
                presetsSection
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
            HistogramView(data: document.histogramData, showChannels: panel.histogramDisplayMode == .rgb)
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
                isPickingWhiteBalance.toggle()
                if isPickingWhiteBalance {
                    isPlacingRedEyeCorrections = false
                    onEnterPointPickingMode()
                }
            } label: {
                Label("Pick White Balance", systemImage: "eyedropper")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(isPickingWhiteBalance ? .yellow : nil)
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

    /// Vignette/Definition/Sharpen/Noise Reduction — the "finishing"
    /// controls, matching Apple Photos' own Effects/Detail grouping. Just
    /// the rows — see `lightSection`'s comment.
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
                label: "Definition", value: $document.editState.definition,
                range: 0...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Sharpen", value: $document.editState.sharpness,
                range: 0...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Noise Reduction", value: $document.editState.noiseReduction,
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
                isPlacingRedEyeCorrections.toggle()
                if isPlacingRedEyeCorrections {
                    isPickingWhiteBalance = false
                    onEnterPointPickingMode()
                }
            } label: {
                Label("Fix Red-Eye", systemImage: "eye.trianglebadge.exclamationmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(isPlacingRedEyeCorrections ? .yellow : nil)
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
                    }
                }
            }
        }
    }

    /// Resets every Light/Color/Selective Color/B&W/Effects/Red-Eye field
    /// to its own default — the SAME identity value each field's own
    /// `EditSliderRow`/`EditToggleRow` already resets to individually via
    /// its per-row Reset button, just all at once. Deliberately does NOT
    /// touch crop/straighten/perspective/flip (those live in the Crop
    /// tab, out of this button's scope, matching how the reference
    /// screenshot's own "Reset Adjustments" is scoped to the Adjust panel
    /// it's shown in) and does NOT clear placed Red-Eye correction points
    /// (a separate, more destructive action with its own dedicated
    /// "Clear All Red-Eye Corrections" button above) — this only resets
    /// continuous adjustment VALUES.
    /// Reviewer-flagged, deliberate, documented gap: this deliberately
    /// mirrors `comparisonOriginal()`'s field list, which does NOT include
    /// any of the ten RAW-native fields (`boostAmount`, `rawExposureEV`,
    /// `shadowBoostScale`, `rawWhiteBalanceNeutralPoints`,
    /// `rawLuminanceNoiseReductionAdjust`, `rawColorNoiseReductionScale`,
    /// `rawSharpnessScale`, `rawContrastAdjust`, `rawDetailAdjust`,
    /// `rawMoireReductionAdjust` — see that method's own doc comment:
    /// `EditPipeline` can't express any of them, so resetting them here
    /// would trigger an unwanted full RAW re-decode from what should be
    /// an instant, free action). Consequence: a RAW photo with every
    /// OTHER field at identity but a non-default RAW section slider shows
    /// this button (correctly) disabled, even though the RAW section's
    /// own sliders are visibly non-identity — `revertToOriginal()`'s
    /// literal `EditState()` commit is the control that resets all
    /// ten, not this one.
    ///
    /// `rawWhiteBalanceNeutralPoints` specifically is WORSE than the
    /// other nine here — reviewer-caught: it has no slider or any other
    /// visible representation in this section AT ALL, so a RAW-native WB
    /// eyedropper tap is genuinely invisible state once set: neither this
    /// button, nor the RAW section's own sliders, show anything changed.
    /// Only Undo or Revert to Original clears it. Accepted as a known gap
    /// for this slice (see PROGRESS.md) rather than adding a dedicated
    /// affordance — flag if a future session's UI work in this file
    /// touches the RAW section, since a "neutral point set (tap to
    /// clear)" indicator would be the natural fix.
    private var isAdjustTabAtIdentity: Bool {
        let state = document.editState
        return state.exposureEV == 0
            && state.brightness == 0
            && state.brilliance == 0
            && state.contrast == 0
            && state.curvesHighlights == 0
            && state.curvesShadows == 0
            && state.blackPoint == 0
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
            && state.vignetteStrength == 0
            && state.vignetteRadius == 0.5
            && state.definition == 0
            && state.sharpness == 0
            && state.noiseReduction == 0
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
            document.editState.vignetteStrength = 0
            document.editState.vignetteRadius = 0.5
            document.editState.definition = 0
            document.editState.sharpness = 0
            document.editState.noiseReduction = 0
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
