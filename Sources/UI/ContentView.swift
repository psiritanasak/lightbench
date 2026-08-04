import SwiftUI

struct ContentView: View {
    @StateObject private var document = ImageDocumentModel()

    /// Which top-level editing tool is active — Apple Photos-style tab bar.
    /// Selecting `.crop` IS entering crop-editing mode (see `isCroppingActive`
    /// below); there's no separate in-sidebar toggle anymore.
    @State private var selectedTab: EditorTab = .adjust

    /// Tracks the image pane's actual on-screen size (from the
    /// `GeometryReader` in `body`), so `fitRect` can be computed from
    /// OUTSIDE that scope too — specifically, the aspect-ratio picker's
    /// action (in the sidebar, a sibling of the image pane in the
    /// `HSplitView`) needs it to snap the crop rect immediately on
    /// selection. `.zero` until the first layout pass.
    @State private var containerSize: CGSize = .zero

    /// Which aspect-ratio preset is locked for the crop rectangle.
    /// Presentation-only, same reasoning as `selectedTab` — a lock only
    /// changes how `CropOverlayView`'s drag handles behave; the final crop
    /// is still just the same four `cropInset*` fields.
    @State private var selectedAspect: CropAspectPreset = .freeform

    /// Captured when `.custom` is selected: the crop rect's ratio AT THAT
    /// MOMENT, then held fixed — see `CropAspectPreset.custom`.
    @State private var customAspectRatio: Double?

    /// Whether the crop overlay is active. Derived from `selectedTab`
    /// rather than its own state — the Crop TAB being selected IS crop
    /// mode now (matching Apple Photos: no separate toggle). Kept as a
    /// named computed property, not inlined at each call site, since it
    /// reads more clearly at each of its several use sites below.
    private var isCroppingActive: Bool { selectedTab == .crop }

    /// The on-screen rect the image currently occupies, fit against the
    /// ACTUAL displayed extent (post-straighten/perspective, crop-zeroed) —
    /// see the historical note on this distinction in the crop-overlay
    /// block below. `nil` until an image is loaded and the pane has been
    /// laid out at least once.
    private var currentFitRect: CGRect? {
        guard let image = document.currentImage, containerSize.width > 0, containerSize.height > 0 else {
            return nil
        }
        return AspectFit.rect(
            fitting: EditPipeline.apply(displayEditState, to: image).extent.size,
            in: containerSize
        )
    }

    /// Resolves `selectedAspect` to an actual width:height ratio, or `nil`
    /// for freeform (no constraint).
    private var effectiveAspectRatio: Double? {
        switch selectedAspect {
        case .freeform: return nil
        case .original: return currentFitRect.map { $0.width / $0.height }
        case .custom: return customAspectRatio
        default: return selectedAspect.fixedRatio
        }
    }

    /// Sets the aspect lock and immediately reshapes the current crop rect
    /// to the largest inscribed, centered rect of that ratio — see
    /// `CropAspectMath.snappedInsets`. `.custom` first captures the
    /// CURRENT crop ratio (so re-selecting it after a freeform resize
    /// re-locks to whatever's currently shown).
    private func selectAspect(_ preset: CropAspectPreset) {
        selectedAspect = preset
        guard let fitRect = currentFitRect else { return }

        if preset == .custom {
            let width = fitRect.width * (1 - document.editState.cropInsetLeft - document.editState.cropInsetRight)
            let height = fitRect.height * (1 - document.editState.cropInsetTop - document.editState.cropInsetBottom)
            customAspectRatio = height > 0 ? width / height : 1
        }

        guard let ratio = effectiveAspectRatio else { return }
        let snapped = CropAspectMath.snappedInsets(
            top: document.editState.cropInsetTop,
            bottom: document.editState.cropInsetBottom,
            left: document.editState.cropInsetLeft,
            right: document.editState.cropInsetRight,
            targetRatio: ratio,
            containerSize: fitRect.size,
            maxInset: 0.45 // mirrors EditPipeline.kMaxCropInset / CropOverlayView.maxInset
        )
        document.editState.cropInsetTop = snapped.top
        document.editState.cropInsetBottom = snapped.bottom
        document.editState.cropInsetLeft = snapped.left
        document.editState.cropInsetRight = snapped.right
    }

    /// Resets everything in the Crop tab back to identity — Straighten,
    /// Vertical/Horizontal perspective, Flip, the crop rectangle, and the
    /// aspect lock. A real, implementable analog to the screenshot's
    /// "Reset" button. ("Auto" is deliberately not implemented — it would
    /// need actual auto-straighten/auto-crop detection, which doesn't
    /// exist in this app; skipped rather than faked.)
    private func resetCropTab() {
        document.editState.straightenAngle = 0
        document.editState.verticalPerspective = 0
        document.editState.horizontalPerspective = 0
        document.editState.flipHorizontal = false
        document.editState.flipVertical = false
        document.editState.cropInsetTop = 0
        document.editState.cropInsetBottom = 0
        document.editState.cropInsetLeft = 0
        document.editState.cropInsetRight = 0
        selectedAspect = .freeform
        customAspectRatio = nil
    }

    /// What's actually rendered on screen. While cropping, the crop insets
    /// are zeroed so the FULL image is visible (with every other edit still
    /// applied) and the user can see what the crop would cut away; the
    /// `CropOverlayView` itself reads the REAL `document.editState.cropInset*`
    /// for the rectangle it draws/drags. `document.editState` remains the
    /// single source of truth — this is a presentation-only substitution,
    /// `EditState`/`EditPipeline` are untouched.
    private var displayEditState: EditState {
        guard isCroppingActive else { return document.editState }
        var state = document.editState
        state.cropInsetTop = 0
        state.cropInsetBottom = 0
        state.cropInsetLeft = 0
        state.cropInsetRight = 0
        return state
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                EditorTabBar(selectedTab: $selectedTab)
                GeometryReader { proxy in
                    ZStack {
                        MetalImageView(image: document.currentImage, editState: displayEditState)
                        // Fit against the ACTUAL displayed extent (post-
                        // straighten/perspective, crop-zeroed), not the raw
                        // `image.extent`. Every feature before Straighten
                        // preserved extent exactly, so those were equal by
                        // coincidence; Straighten grows the extent (measured
                        // +padding from resampling), so this distinction is
                        // load-bearing — using the raw extent here would
                        // misalign the overlay against a straightened photo.
                        // (Perspective correction, added later, was verified to
                        // preserve extent exactly since its corners only move
                        // inward — it doesn't newly exercise this path, but
                        // this computation still correctly reflects whatever
                        // extent the pipeline actually produces.) Building the
                        // filter graph to read `.extent` is cheap (Core Image
                        // doesn't render pixels for it). `currentFitRect` is
                        // shared with the aspect-picker action in the sidebar
                        // (outside this GeometryReader's scope), via
                        // `containerSize`.
                        if isCroppingActive, let fitRect = currentFitRect {
                            CropOverlayView(
                                fitRect: fitRect,
                                cropInsetTop: $document.editState.cropInsetTop,
                                cropInsetBottom: $document.editState.cropInsetBottom,
                                cropInsetLeft: $document.editState.cropInsetLeft,
                                cropInsetRight: $document.editState.cropInsetRight,
                                aspectRatio: effectiveAspectRatio
                            )
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .onAppear { containerSize = proxy.size }
                    .onChange(of: proxy.size) { _, newSize in containerSize = newSize }
                }
            }
            .frame(minWidth: 480, minHeight: 360)
            .layoutPriority(1)

            editControls
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
        }
        .preferredColorScheme(.dark)
        // Opening a new photo resets `editState` (including crop) to
        // identity; return to the Adjust tab too so the crop overlay
        // doesn't linger showing a stale (now-meaningless) full-frame rect
        // over the new photo, and reset the aspect lock (a fresh photo has
        // no meaningful "current" ratio to keep enforcing).
        .onChange(of: document.currentFileName) { _, _ in
            selectedTab = .adjust
            selectedAspect = .freeform
            customAspectRatio = nil
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Open…") {
                    document.openImage()
                }
            }
            if selectedTab == .crop {
                ToolbarItem(placement: .automatic) {
                    Button("Done") { selectedTab = .adjust }
                        .buttonStyle(.borderedProminent)
                        .tint(.yellow)
                }
            }
        }
        .navigationTitle(document.currentFileName ?? "PhotoApp")
        .alert(
            "Couldn't Open Image",
            isPresented: Binding(
                get: { document.loadErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { document.loadErrorMessage = nil }
                }
            ),
            presenting: document.loadErrorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private var editControls: some View {
        ScrollView {
            Group {
                switch selectedTab {
                case .adjust: adjustTabContent
                case .crop: cropTabContent
                case .filters: placeholderTab("Filters aren't available yet.")
                case .cleanUp: placeholderTab("Clean Up isn't available yet.")
                }
            }
            .padding()
        }
        .disabled(document.currentImage == nil)
        .background(Color(white: 0.11))
    }

    private var adjustTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditSliderRow(
                label: "Temperature", value: $document.editState.whiteBalanceTemperature,
                range: 3500...9500, identity: 6500
            ) { String(format: "%.0fK", $0) }
            EditSliderRow(
                label: "Tint", value: $document.editState.whiteBalanceTint,
                range: -100...100, identity: 0
            ) { String(format: "%+.0f", $0) }
            EditSliderRow(
                label: "Exposure", value: $document.editState.exposureEV,
                range: -5...5, identity: 0
            ) { String(format: "%+.2f EV", $0) }
            EditSliderRow(
                label: "Brightness", value: $document.editState.brightness,
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Brilliance", value: $document.editState.brilliance,
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Contrast", value: $document.editState.contrast,
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Highlights", value: $document.editState.curvesHighlights,
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Shadows", value: $document.editState.curvesShadows,
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Black Point", value: $document.editState.blackPoint,
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Hue", value: $document.editState.hslHue,
                range: -180...180, identity: 0
            ) { String(format: "%+.0f°", $0) }
            EditSliderRow(
                label: "Vibrance", value: $document.editState.vibrance,
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Saturation", value: $document.editState.hslSaturation,
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditToggleRow(label: "Black & White", value: $document.editState.blackAndWhite)
            EditSliderRow(
                label: "Vignette", value: $document.editState.vignetteStrength,
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Vignette Radius", value: $document.editState.vignetteRadius,
                range: 0...1, identity: 0.5
            ) { String(format: "%.0f%%", $0 * 100) }
        }
    }

    private var cropTabContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            EditSliderRow(
                label: "Straighten", value: $document.editState.straightenAngle,
                range: -45...45, identity: 0
            ) { String(format: "%+.1f°", $0) }
            EditSliderRow(
                label: "Vertical", value: $document.editState.verticalPerspective,
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Horizontal", value: $document.editState.horizontalPerspective,
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditToggleRow(label: "Flip Horizontal", value: $document.editState.flipHorizontal)
            EditToggleRow(label: "Flip Vertical", value: $document.editState.flipVertical)

            Divider()
            aspectSection
            Divider()

            EditSliderRow(
                label: "Crop Top", value: $document.editState.cropInsetTop,
                range: 0...0.45, identity: 0
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Crop Bottom", value: $document.editState.cropInsetBottom,
                range: 0...0.45, identity: 0
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Crop Left", value: $document.editState.cropInsetLeft,
                range: 0...0.45, identity: 0
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Crop Right", value: $document.editState.cropInsetRight,
                range: 0...0.45, identity: 0
            ) { String(format: "%.0f%%", $0 * 100) }

            Button("Reset") { resetCropTab() }
                .disabled(document.currentImage == nil)
        }
    }

    /// The Aspect preset list — a full always-visible vertical list (not a
    /// compact dropdown), matching Apple Photos' own Crop-panel layout now
    /// that it has a dedicated tab to live in. Each row is tappable; the
    /// selected preset shows a checkmark.
    private var aspectSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Aspect")
                .font(.headline)
                .padding(.bottom, 2)
            ForEach(CropAspectPreset.allCases, id: \.self) { preset in
                Button {
                    selectAspect(preset)
                } label: {
                    HStack {
                        Text(preset.label)
                        Spacer()
                        if preset == selectedAspect {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
        }
    }

    private func placeholderTab(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }
}

/// A single edit-adjustment control: label + live readout on one line, with
/// a Reset button, and a full-width slider below — label-above-slider,
/// matching Lightroom/Photos' sidebar inspector convention (as opposed to a
/// label-beside-slider `HStack`, which gets cramped in a ~300pt-wide panel).
private struct EditSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let identity: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Reset") {
                    value = identity
                }
                .disabled(value == identity)
            }
            Slider(value: $value, in: range)
        }
    }
}

/// A single boolean edit-adjustment control: label + `Toggle` on one line.
/// No Reset button — unlike a continuous slider, a boolean is already
/// trivially reversible with a single click either direction.
private struct EditToggleRow: View {
    let label: String
    @Binding var value: Bool

    var body: some View {
        Toggle(label, isOn: $value)
    }
}

#Preview {
    ContentView()
}
