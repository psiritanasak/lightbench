import SwiftUI

/// One other mask `MaskDetailView`'s combine-target picker can offer,
/// pre-labeled by `AdjustTabView.targets(excluding:in:)` so the label
/// shown here can never disagree with `maskListRows`' own "Mask N"
/// numbering (Phase 7 slice 6, Session B).
struct MaskCombineTarget: Identifiable, Hashable {
    let id: UUID
    let label: String
}

/// `Mask.combineWithMaskID`'s own doc comment names this exact fix: a
/// SwiftUI `Picker`/`List` bound directly to an `Optional`-typed selection
/// was measured LIVE, elsewhere in this codebase, to make the `nil`-tagged
/// row silently unselectable once a real value had been chosen
/// (`LibraryFilter`, `Sources/UI/CatalogModel.swift`). A concrete,
/// non-optional selection type sidesteps that quirk entirely — every row
/// here tags a real `CombineTargetSelection` value, never `nil` itself.
enum CombineTargetSelection: Hashable {
    case none
    case mask(UUID)
}

extension MaskCombineTarget {
    /// Numbering here MUST match `AdjustTabView.maskListRows`' own
    /// `index + 1` — both are computed from the SAME `masks` array in the
    /// SAME order, so this deliberately does NOT filter `masks` down
    /// before numbering (a `filter`-then-`enumerate` would renumber
    /// everything after the excluded mask). `id` is excluded from the
    /// RESULT only, after numbering every mask exactly as the sidebar
    /// list does.
    static func targets(excluding id: UUID, in masks: [Mask]) -> [MaskCombineTarget] {
        masks.enumerated().compactMap { index, mask in
            guard mask.id != id else { return nil }
            return MaskCombineTarget(id: mask.id, label: "Mask \(index + 1) — \(AdjustTabView.maskKindLabel(mask.kind))")
        }
    }
}

/// The selected mask's slider rows (14 for `.radial`, 12 for `.linear`,
/// 11 for `.luminanceRange`) — a top-level `struct`, deliberately
/// NOT a computed property inside `AdjustTabView` (that file's `body`
/// `VStack` already has 15 children, and two of its own doc comments warn
/// of a real, already-hit Swift type-checker blow-up from over-packed
/// `@ViewBuilder` closures; 14 more rows plus the list/add/delete chrome
/// would repeat exactly that mistake).
///
/// One `@Binding var mask: Mask` (not `Binding<EditState>` narrowed
/// elsewhere, not 14 separate scalar bindings) is the right granularity —
/// it already structurally cannot touch any other mask or any global field,
/// and it resolves the by-ID lookup (`Binding<EditState>.mask(id:)`,
/// `MaskBinding.swift`) exactly once per view build, not 14 times.
///
/// These rows ARE the accessibility answer for the on-image mask overlays
/// (`MaskOverlayView` for `.radial`, `LinearMaskOverlayView` for `.linear`)
/// — they're what lets both overlays be `.accessibilityHidden(true)` the
/// same way `CropOverlayView` already is — justified there, and here, ONLY
/// because the same values are independently AT-adjustable via labeled
/// sliders. Without these rows, mask geometry would be the only
/// `EditState`-backed value in the app reachable solely by mouse.
///
/// This claim does NOT extend to `.brush` (Phase 7 slice 4): a stroke's
/// SHAPE (its path) has no slider equivalent the way an ellipse's/band's
/// geometry does — `brushShapeRows` below covers Size/Feather, but painting
/// or redrawing the stroke itself is mouse-only. This is a real, named
/// accessibility gap (see `BrushMaskOverlayView`'s own doc comment and
/// IMPROVEMENTS.md), not covered by the same justification the other two
/// kinds rely on.
///
/// `.luminanceRange` (Phase 7 slice 5, first half) needs NO such carve-out
/// — it is MORE accessible than the three overlay-owning kinds, not less:
/// every one of its parameters (Luminance, Range, Feather) is a labeled
/// `EditSliderRow` and there is no gesture at all (no drag, no paint, no
/// on-image overlay to excuse). Nothing to log in IMPROVEMENTS.md for it.
///
/// `.colorRange` (Phase 7 slice 5, second half) sits BETWEEN those two
/// extremes: Tolerance and Feather are labeled, AT-adjustable
/// `EditSliderRow`s exactly like `.luminanceRange`'s own params, and
/// PICKING the color itself (`ContentView.pointAndZoomOverlays`'s capture
/// layer) now ALSO has a keyboard/AT path (D14, IMPROVEMENTS.md — closed):
/// arrow keys move the shared crosshair, Return commits, Escape disarms,
/// routed through the exact same `crosshairPosition`/
/// `handlePointPlacementKeyPress`/`commitPointPlacement`/
/// `EditorCrosshairOverlay` machinery the WB eyedropper already used —
/// confirming that entry's own prediction this would be "mostly a routing
/// change, not new machinery."
struct MaskDetailView: View {
    @Binding var mask: Mask
    /// `.brush` only — called when "Paint Stroke"/"Redraw Stroke" is
    /// tapped. `nil` for every other kind (mirrors
    /// `RedEyeOverlayView.onTap`'s optional-closure shape for an
    /// additive, kind-gated callback).
    var onBeginBrushStroke: (() -> Void)?
    /// `.colorRange` only — called when "Pick Color"/"Re-pick Color" is
    /// tapped. `nil` for every other kind, same shape as `onBeginBrushStroke`.
    var onBeginColorPick: (() -> Void)?
    /// `.subject` only — re-runs Vision and replaces this mask's raster. `nil` for every other kind.
    var onRecomputeSubject: (() -> Void)?
    /// A Vision pass is in flight (any mask): the recompute button waits.
    var isRecomputingSubject = false
    /// Phase 7 slice 6, Session B — every OTHER mask on this photo,
    /// pre-labeled, that `mask` could combine against. Empty (the
    /// default) on a photo with only this one mask, which is what makes
    /// `combineRows` hide itself entirely rather than show a picker with
    /// nothing in it. `AdjustTabView.maskDetail` recomputes this on every
    /// body evaluation from `document.editState.masks`, so add/delete
    /// refreshes it for free — no new observation machinery needed here.
    var combineTargets: [MaskCombineTarget] = []

    /// Kind-aware: calling a tone window a "Shape" would be wrong — this
    /// kind has no shape at all, only a tonal selection.
    private var shapeSectionTitle: String {
        switch mask.kind {
        case .radial, .linear, .brush: return "Shape"
        case .luminanceRange: return "Luminance Range"
        case .colorRange: return "Color Range"
        case .subject: return "Subject"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adjustments").font(.caption).foregroundStyle(.secondary)
            toneRows
            colorRows
            Text(shapeSectionTitle).font(.caption).foregroundStyle(.secondary)
            shapeRows
            if !combineTargets.isEmpty {
                Text("Combine").font(.caption).foregroundStyle(.secondary)
                combineRows
            }
        }
    }

    private var toneRows: some View {
        Group {
            EditSliderRow(
                label: "Exposure", value: $mask.exposureEV,
                range: -5...5, identity: 0
            ) { String(format: "%+.2f EV", $0) }
            EditSliderRow(
                label: "Contrast", value: $mask.contrast,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Highlights", value: $mask.highlights,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Shadows", value: $mask.shadows,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
        }
    }

    private var colorRows: some View {
        Group {
            // Clarity is -1...1, BIPOLAR, matching the global Clarity
            // slider. It was one-directional until the Texture/Clarity
            // split: CIUnsharpMask's measured negative-intensity no-op
            // made the negative half dead, and EditPipeline.localContrast
            // now routes that half through a blur blend instead.
            EditSliderRow(
                label: "Clarity", value: $mask.clarity,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Saturation", value: $mask.saturation,
                range: -1...1, identity: 0, displayMultiplier: 100
            ) { String(format: "%+.0f%%", $0 * 100) }
            // A Kelvin OFFSET from wherever white balance already left the
            // image, NOT an absolute value like the global Temperature row
            // -- see Mask.temperature's own doc comment.
            EditSliderRow(
                label: "Temperature", value: $mask.temperature,
                range: -2000...2000, identity: 0
            ) { String(format: "%+.0fK", $0) }
            EditSliderRow(
                label: "Tint", value: $mask.tint,
                range: -100...100, identity: 0
            ) { String(format: "%+.0f", $0) }
        }
    }

    /// Kind-switched (Phase 7 slice 3) — the shape params genuinely differ
    /// per kind (an ellipse's radii/feather vs. a graduated band's width),
    /// while `centerX`/`centerY` and the rotation convention are shared
    /// (see `Mask.rotationDegrees`'s own doc comment for why there's only
    /// ONE rotation field/sign rule across both kinds).
    @ViewBuilder private var shapeRows: some View {
        switch mask.kind {
        case .radial: radialShapeRows
        case .linear: linearShapeRows
        case .brush: brushShapeRows
        case .luminanceRange: luminanceRangeShapeRows
        case .colorRange: colorRangeShapeRows
        case .subject: subjectShapeRows
        }
    }

    /// Everything the subject kind has: Invert (select the background instead) and Recompute. The
    /// selection itself is a persisted Vision raster, so there is no geometry to adjust (v1: no feather,
    /// no per-person choice — see IMPROVEMENTS.md).
    private var subjectShapeRows: some View {
        Group {
            Toggle("Invert (select background)", isOn: $mask.invertSelection)
                .accessibilityLabel("Invert Subject Selection")
            Button(isRecomputingSubject ? "Finding…" : "Recompute Subject") {
                onRecomputeSubject?()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .disabled(isRecomputingSubject)
            if !mask.hasStoredSubject {
                Text("No subject stored for this mask.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var radialShapeRows: some View {
        Group {
            centerRows
            EditSliderRow(
                label: "Radius X", value: $mask.radiusX,
                range: MaskGeometry.minRadius...MaskGeometry.maxRadius, identity: 0.25, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Radius Y", value: $mask.radiusY,
                range: MaskGeometry.minRadius...MaskGeometry.maxRadius, identity: 0.25, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            // -90...90, not -180...180: an ellipse has 180-degree symmetry,
            // so the wider range would be duplicate travel -- the same
            // "don't expose measured-dead travel" discipline CLAUDE.md
            // documents for rawMoireReductionAdjust.
            EditSliderRow(
                label: "Rotation", value: $mask.rotationDegrees,
                range: -90...90, identity: 0
            ) { String(format: "%+.0f°", $0) }
            featherRow
        }
    }

    private var linearShapeRows: some View {
        Group {
            centerRows
            // -180...180, NOT the ellipse's -90...90: a LINE has no
            // 180-degree symmetry -- flipping it 180 degrees swaps WHICH
            // SIDE of the frame gets the effect (Mask.rotationDegrees'
            // own doc comment), so the full range is real travel here,
            // not duplicate travel.
            EditSliderRow(
                label: "Angle", value: $mask.rotationDegrees,
                range: -180...180, identity: 0
            ) { String(format: "%+.0f°", $0) }
            // The FULL guide-to-guide distance, not a half-width; 0 is a
            // legitimate hard edge (clamped to LinearMaskGeometry
            // .minimumWidth in the render), unlike a zero-radius ellipse,
            // which is a no-op -- see Mask.width's own doc comment. Range
            // cites MaskGeometry.minWidth/maxWidth (Phase 7 slice 3
            // Session B), the same "keep the two in sync, or a drag could
            // produce a value the slider then silently clamps away"
            // discipline that file's own doc comment already states for
            // minRadius/maxRadius -- a plain 0...1 literal here would be
            // a second, driftable source of truth for the same bounds
            // LinearMaskOverlayView's own drag math already clamps to.
            EditSliderRow(
                label: "Width", value: $mask.width,
                range: MaskGeometry.minWidth...MaskGeometry.maxWidth, identity: 0.3, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
        }
    }

    /// `.brush` only — no `centerRows`: unlike an ellipse or a band, a
    /// stroke has no single anchor point, only its own ordered
    /// `brushPoints`. "Paint Stroke"/"Redraw Stroke" is the ONLY way to
    /// set/replace the stroke's shape — Size and Feather are the two
    /// values that stay adjustable afterward without repainting.
    private var brushShapeRows: some View {
        Group {
            Button(mask.brushPoints.isEmpty ? "Paint Stroke" : "Redraw Stroke") {
                onBeginBrushStroke?()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            Text(mask.brushPoints.isEmpty ? "No stroke painted yet" : "\(mask.brushPoints.count) points painted")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Range cites `BrushMaskGeometry` directly, never a literal —
            // the same "keep the two in sync" discipline `MaskGeometry`'s
            // own doc comments already state for Radial/Linear's ranges.
            EditSliderRow(
                label: "Brush Size", value: $mask.brushSize,
                range: BrushMaskGeometry.minimumSize...BrushMaskGeometry.maximumSize, identity: 0.05,
                displayMultiplier: 100
            ) { String(format: "%.1f%%", $0 * 100) }
            featherRow
        }
    }

    /// `.luminanceRange` only (Phase 7 slice 5) — no `centerRows` and no
    /// geometry rows at all: this kind selects by TONE, not position, so
    /// it has no anchor point, no size, and no rotation. Ranges cite
    /// `LuminanceRangeSelection` directly, never literals — the same
    /// single-source-of-truth discipline every other kind's ranges
    /// already follow. Labels are "Luminance"/"Range", not "Target
    /// Luminance"/"Range Width" — under the "Luminance Range" section
    /// header both are unambiguous, and the longer forms would be an
    /// avoidable truncation risk for zero clarity gain (this sidebar's
    /// longest existing label, "Temperature", is 11 characters).
    private var luminanceRangeShapeRows: some View {
        Group {
            EditSliderRow(
                label: "Luminance", value: $mask.luminanceTarget,
                range: LuminanceRangeSelection.minimumTarget...LuminanceRangeSelection.maximumTarget,
                identity: 0.5, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            // The FULL width of the tone window, not a half-width -- see
            // Mask.luminanceRange's own doc comment.
            EditSliderRow(
                label: "Range", value: $mask.luminanceRange,
                range: LuminanceRangeSelection.minimumRange...LuminanceRangeSelection.maximumRange,
                identity: 0.3, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            featherRow
        }
    }

    /// `.colorRange` only (Phase 7 slice 5, second half) — no `centerRows`
    /// and no geometry rows, same reasoning as `.luminanceRange` above:
    /// this kind selects by the image's own pixel values, not position.
    /// "Pick Color"/"Re-pick Color" mirrors `.brush`'s "Paint Stroke"/
    /// "Redraw Stroke" exactly, keyed off `mask.colorRangeHasTarget`
    /// (mirrors `brushPoints.isEmpty`'s "added but not yet used"
    /// convention). The swatch is reconstructed from the 3 stored scalars
    /// via `ColorRangeSelection.displaySRGB` — never a 4th/5th/6th
    /// redundant RGB field that could drift from what the kernel uses —
    /// and is `.accessibilityHidden(true)`: the adjacent text readout,
    /// using the PERCEPTUAL tone (`ColorRangeSelection.tone(forLinearLuminance:)`
    /// — every other tone readout in this app is perceptual, matching
    /// `luminanceRangeShapeRows`' own "Luminance"/"Range" percent labels
    /// above), is the accessible answer.
    private var colorRangeShapeRows: some View {
        Group {
            Button(mask.colorRangeHasTarget ? "Re-pick Color" : "Pick Color") {
                onBeginColorPick?()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            if mask.colorRangeHasTarget {
                let swatch = ColorRangeSelection.displaySRGB(
                    hue: mask.colorRangeTargetHue, saturation: mask.colorRangeTargetSaturation,
                    luminance: mask.colorRangeTargetLuminance
                )
                // Reviewer-caught: `tone(forLinearLuminance:)` is
                // deliberately unclamped (see its own doc comment) — a
                // hand-edited/corrupt sidecar's `.nan` or astronomically
                // large `colorRangeTargetLuminance` would otherwise trap
                // `Int(_:)` the moment this mask is merely SELECTED, not
                // just misrender. Clamped to a range no legitimate value
                // (scene-linear luminance, realistically 0...a few) could
                // ever approach, closing the same non-finite-input gap
                // `displaySRGB` was reviewer-caught on just above.
                let rawTonePercent = ColorRangeSelection.tone(forLinearLuminance: mask.colorRangeTargetLuminance) * 100
                let tonePercent = rawTonePercent.isFinite
                    ? Int(min(max(rawTonePercent, -1_000_000), 1_000_000).rounded())
                    : 0
                HStack {
                    Circle()
                        .fill(Color(red: swatch.r, green: swatch.g, blue: swatch.b))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
                        .accessibilityHidden(true)
                    Text(String(
                        format: "Hue %.0f°  Sat %.0f%%  Lum %ld%%",
                        mask.colorRangeTargetHue, mask.colorRangeTargetSaturation * 100, tonePercent
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("No color picked yet").font(.caption).foregroundStyle(.secondary)
            }
            // Cites `ColorRangeSelection.minimumTolerance/maximumTolerance`
            // directly, never literals — the same single-source-of-truth
            // discipline every other kind's ranges already follow.
            EditSliderRow(
                label: "Tolerance", value: $mask.colorRangeTolerance,
                range: ColorRangeSelection.minimumTolerance...ColorRangeSelection.maximumTolerance,
                identity: 0.3, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            featherRow
        }
    }

    /// Shared by four of the five kinds (`.radial`, `.brush`,
    /// `.luminanceRange`, `.colorRange` — see `Mask.feather`'s own doc
    /// comment for why the same field/formula is reused a fourth time
    /// here), extracted once so the shared-field decision is visible in
    /// the view code, not re-typed per kind.
    private var featherRow: some View {
        EditSliderRow(
            label: "Feather", value: $mask.feather,
            range: 0...1, identity: 0.5, displayMultiplier: 100
        ) { String(format: "%.0f%%", $0 * 100) }
    }

    /// Phase 7 slice 6, Session B — narrows (`.intersect`) or punches a
    /// hole in (`.subtract`) `mask`'s own selection using another mask's
    /// shape. See `EditPipeline.applyMasks`'s own doc comment for the
    /// full render semantics — this is purely the UI for
    /// `Mask.combineMode`/`Mask.combineWithMaskID`, already documented
    /// there. `body` above hides this whole group when `combineTargets`
    /// is empty, so it's never shown with nothing to combine against.
    private var combineRows: some View {
        Group {
            Picker("Mode", selection: combineModeSelection) {
                ForEach(MaskCombineMode.allCases, id: \.self) { mode in
                    Text(combineModeLabel(mode)).tag(mode)
                }
            }
            .accessibilityLabel("Combine Mode")
            Picker("With", selection: combineTargetSelection) {
                Text("None").tag(CombineTargetSelection.none)
                ForEach(combineTargets) { target in
                    Text(target.label).tag(CombineTargetSelection.mask(target.id))
                }
            }
            .disabled(mask.combineMode == .none)
            .accessibilityLabel("Combine With")
        }
    }

    /// Labels come from an exhaustive `switch`, not `rawValue` —
    /// `MaskCombineMode`'s own doc comment reserves `CaseIterable`/
    /// `.allCases` for ENUMERATION only, so a future case fails to
    /// COMPILE here instead of silently showing a raw identifier.
    private func combineModeLabel(_ mode: MaskCombineMode) -> String {
        switch mode {
        case .none: return "None"
        case .intersect: return "Intersect"
        case .subtract: return "Subtract"
        }
    }

    /// Setting a non-`.none` mode auto-fills the FIRST available target
    /// when none is already chosen (or the stored one no longer
    /// resolves) — without this, picking "Intersect" on a mask with
    /// `combineWithMaskID == nil` fails open to `.none` at render time
    /// (correct, see `Mask.combineWithMaskID`'s own doc comment) but
    /// would read to the user as a broken control, since nothing visible
    /// would happen. Switching BACK to `.none` deliberately does NOT
    /// clear the stored target, so a None -> Intersect round-trip
    /// restores the same operand rather than losing it.
    private var combineModeSelection: Binding<MaskCombineMode> {
        Binding(
            get: { mask.combineMode },
            set: { newMode in
                mask.combineMode = newMode
                guard newMode != .none else { return }
                let resolvedTargetExists = mask.combineWithMaskID.map { id in
                    combineTargets.contains { $0.id == id }
                } ?? false
                if !resolvedTargetExists {
                    mask.combineWithMaskID = combineTargets.first?.id
                }
            }
        )
    }

    /// The `LibraryFilter`-style coercing binding (see this file's own
    /// `CombineTargetSelection` doc comment for the bug it avoids). The
    /// GETTER maps an unresolvable stored id (the operand was deleted, or
    /// this sidecar belongs to a different photo) back to `.none`, so
    /// this picker can never display a value outside its own list — and
    /// can never disagree with `EditPipeline.applyMasks`'s own fail-open
    /// render, which degrades a dangling reference to `.none` the exact
    /// same way. The SETTER writes a concrete id or `nil` back to
    /// `mask.combineWithMaskID` — and, reviewer-caught: picking "None"
    /// here ALSO resets `mask.combineMode` to `.none`. Without this,
    /// `combineModeSelection`'s own auto-fill only guards the
    /// mode-change direction — a user could still reach a live, silently
    /// INERT combine (`combineMode == .intersect`/`.subtract` with
    /// `combineWithMaskID == nil`) by picking "None" from THIS picker
    /// without touching Mode. Render-wise both states already fail open
    /// identically (see `EditPipeline.applyMasks`), so this is a UI
    /// clarity fix, not a correctness fix — but "None" should always
    /// mean genuinely uncombined from either picker, not just from the
    /// mode one.
    private var combineTargetSelection: Binding<CombineTargetSelection> {
        Binding(
            get: {
                guard let id = mask.combineWithMaskID, combineTargets.contains(where: { $0.id == id }) else {
                    return .none
                }
                return .mask(id)
            },
            set: { selection in
                switch selection {
                case .none:
                    mask.combineWithMaskID = nil
                    mask.combineMode = .none
                case .mask(let id):
                    mask.combineWithMaskID = id
                }
            }
        )
    }

    /// Shared between both kinds — the mask's anchor point, same
    /// semantics regardless of `kind` (see `Mask.centerX`/`centerY`'s own
    /// doc comment).
    private var centerRows: some View {
        Group {
            EditSliderRow(
                label: "Center X", value: $mask.centerX,
                range: 0...1, identity: 0.5, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Center Y", value: $mask.centerY,
                range: 0...1, identity: 0.5, displayMultiplier: 100
            ) { String(format: "%.0f%%", $0 * 100) }
        }
    }
}
