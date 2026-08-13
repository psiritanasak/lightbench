import AppKit
import SwiftUI

struct ContentView: View {
    /// Owned by `PhotoAppApp`, not this view — lifted there so the Edit
    /// menu's `.commands { CommandGroup(replacing: .undoRedo) }` (a
    /// Scene-level construct) can act on the SAME document instance the
    /// toolbar's Undo/Redo buttons already do.
    @ObservedObject var document: ImageDocumentModel

    /// Phase 4 slice 1: catalog DB + basic folder import. Owned by
    /// `PhotoAppApp` for the same reason `document` is — a single shared
    /// instance, ready for later Phase 4 slices (thumbnail grid, etc.) to
    /// also observe.
    @ObservedObject var catalog: CatalogModel

    /// Phase 5 slice 1: batch export. Scoped to this view (not lifted to
    /// `PhotoAppApp`) — unlike `document`/`catalog`, nothing outside this
    /// view (no Scene-level command, no other view) needs to observe it.
    @StateObject private var exportModel = ExportModel()

    /// What "Export…" actually exports. A pure refinement on top of the
    /// existing filtered set: if 1+ photos are checked in the grid,
    /// export ONLY those (overriding whatever Collection/Folder is
    /// active in the sidebar); with nothing checked, behaves exactly as
    /// before this feature existed — the current filtered set.
    private var photosToExport: [Photo] {
        guard !catalog.selectedPhotoIDs.isEmpty else { return catalog.photos }
        return catalog.photos.filter { catalog.isSelected($0) }
    }

    /// Phase 4 slice 2: toggles the main window between the single-photo
    /// Editor (the existing `HSplitView`, unchanged) and the Library
    /// thumbnail grid. Presentation-only — switching back to the Editor
    /// leaves whatever photo was already loaded exactly as it was.
    @State private var showLibrary = false

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

    /// Whether a tap on the image should be captured as a WB eyedropper
    /// sample. Its own overlay only exists while this is true AND cropping
    /// is not active (see `body`), so the two point-interactions are
    /// mutually exclusive by construction, not by a shared runtime check.
    @State private var isPickingWhiteBalance = false

    /// Whether taps on the image should place/remove Red-Eye correction
    /// points. UNLIKE `isPickingWhiteBalance`, placing a point does NOT
    /// auto-disarm this mode — the user will often place several
    /// corrections (both eyes) in one sitting, so it stays armed until
    /// toggled off or the user leaves the Adjust tab.
    @State private var isPlacingRedEyeCorrections = false

    /// Which Selective Color band's Hue/Saturation/Luminance sliders are
    /// currently shown. Presentation-only, same reasoning as `selectedTab`/
    /// `selectedAspect` — `EditState` holds all 8 bands' values at once
    /// (24 flat fields), this just tracks which band's trio the panel
    /// displays right now.
    @State private var selectedSelectiveColorBand: SelectiveColorBand = .red

    /// Whether the Levels histogram shows luminance only or luminance +
    /// per-channel RGB overlays. Presentation-only — `HistogramData` always
    /// carries all four; this just controls what `HistogramView` draws.
    /// Defaults to `.luminance` to match this histogram's original look.
    @State private var histogramDisplayMode: HistogramDisplayMode = .luminance

    /// Which Adjust-tab sections are expanded — Apple-Photos-style
    /// collapsible sections. Defaults `false` (all collapsed) per user
    /// request; one bool each rather than a `Set`, matching this file's
    /// existing convention of separate named `@State` per
    /// presentation-only concern.
    @State private var isLightSectionExpanded = false
    @State private var isColorSectionExpanded = false
    @State private var isSelectiveColorSectionExpanded = false
    @State private var isBlackAndWhiteSectionExpanded = false
    @State private var isEffectsSectionExpanded = false
    @State private var isRedEyeSectionExpanded = false

    /// The image pane's `EditorTabBar` row's actual rendered height,
    /// measured live (not guessed) — see `editControls`'s top padding,
    /// which uses this to match the sidebar's top clearance to it exactly.
    /// Both `HSplitView` panes start at the SAME native y-offset below the
    /// window's toolbar chrome (that chrome is outside the SwiftUI view
    /// hierarchy entirely, applied uniformly to the whole window); the
    /// image pane's real content only LOOKS lower because `EditorTabBar` is
    /// prepended above it. A fixed guessed padding constant (tried twice)
    /// undershot both times; measuring the real value is the actual fix.
    @State private var tabBarHeight: CGFloat = 44

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
        // Split out of `body` (into `mainContent` below) so the type
        // checker only has to solve the alert chain against ONE already-
        // opaque `some View` type, not the whole `HSplitView` tree AND
        // every alert simultaneously — adding the `importStatusMessage`
        // alert pushed the previously-single expression past what the
        // compiler could type-check in reasonable time (measured: this
        // split is what fixed it).
        mainContent
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
            .alert(
                "White Balance",
                isPresented: Binding(
                    get: { document.whiteBalanceSampleMessage != nil },
                    set: { isPresented in
                        if !isPresented { document.whiteBalanceSampleMessage = nil }
                    }
                ),
                presenting: document.whiteBalanceSampleMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            .alert(
                "Couldn't Save Edits",
                isPresented: Binding(
                    get: { document.sidecarSaveErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented { document.sidecarSaveErrorMessage = nil }
                    }
                ),
                presenting: document.sidecarSaveErrorMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            .alert(
                "Import Folder",
                isPresented: Binding(
                    get: { catalog.importStatusMessage != nil },
                    set: { isPresented in
                        if !isPresented { catalog.importStatusMessage = nil }
                    }
                ),
                presenting: catalog.importStatusMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            .alert(
                "Export",
                isPresented: Binding(
                    get: { exportModel.statusMessage != nil },
                    set: { isPresented in
                        if !isPresented { exportModel.statusMessage = nil }
                    }
                ),
                presenting: exportModel.statusMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            .sheet(isPresented: $exportModel.isPresentingOptions) {
                ExportOptionsView(exportModel: exportModel, photoCount: photosToExport.count) {
                    exportModel.runExport(photos: photosToExport)
                }
            }
            .overlay(alignment: .bottom) {
                if let progress = exportModel.progress {
                    exportProgressView(progress)
                }
            }
    }

    private func exportProgressView(_ progress: ExportProgress) -> some View {
        VStack(spacing: 6) {
            Text("Exporting \(progress.completed) of \(progress.total)…")
                .font(.caption)
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                .frame(width: 220)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 16)
    }

    private var mainContent: some View {
        Group {
            if showLibrary {
                libraryContent
            } else {
                editorContent
            }
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
            isPickingWhiteBalance = false
            isPlacingRedEyeCorrections = false
        }
        // Leaving the Adjust tab disarms both point-interaction modes —
        // neither has meaning while cropping (their overlays are gated on
        // `!isCroppingActive` anyway) or in the other, not-yet-built tabs.
        .onChange(of: selectedTab) { _, newTab in
            if newTab != .adjust {
                isPickingWhiteBalance = false
                isPlacingRedEyeCorrections = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(showLibrary ? "Editor" : "Library") {
                    showLibrary.toggle()
                }
            }
            ToolbarItem(placement: .automatic) {
                Button("Open…") {
                    document.openImage()
                }
            }
            ToolbarItem(placement: .automatic) {
                Button("Import Folder…") {
                    catalog.importFolder()
                }
            }
            ToolbarItem(placement: .automatic) {
                Button("Import Folder Tree…") {
                    catalog.importFolderTree()
                }
            }
            if showLibrary {
                ToolbarItem(placement: .automatic) {
                    Button(
                        catalog.selectedPhotoIDs.isEmpty
                            ? "Export…"
                            : "Export Selected (\(catalog.selectedPhotoIDs.count))…"
                    ) {
                        exportModel.beginExport()
                    }
                    .disabled(photosToExport.isEmpty || exportModel.isExporting)
                }
                if !catalog.selectedPhotoIDs.isEmpty {
                    ToolbarItem(placement: .automatic) {
                        Button("Clear Selection") {
                            catalog.clearSelection()
                        }
                    }
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    document.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                // No .keyboardShortcut here — the Edit menu
                // (`PhotoAppApp`'s `.commands { CommandGroup(replacing:
                // .undoRedo) }`) is the canonical ⌘Z/⇧⌘Z owner now, so two
                // separate views don't both claim the same key combo.
                .disabled(!document.canUndo)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    document.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!document.canRedo)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    document.revertToOriginal()
                } label: {
                    Label("Revert to Original", systemImage: "arrow.counterclockwise")
                }
                .disabled(document.currentImage == nil || document.editState == .identity)
            }
            if selectedTab == .crop {
                ToolbarItem(placement: .automatic) {
                    Button("Done") { selectedTab = .adjust }
                        .buttonStyle(.borderedProminent)
                        .tint(.yellow)
                }
            }
        }
        .navigationTitle(showLibrary ? "Library" : (document.currentFileName ?? "PhotoApp"))
    }

    /// The Library, in an `HSplitView` alongside `editorContent` (Phase 4
    /// slice 4) — a collections sidebar on the left, the thumbnail grid
    /// on the right. Selecting a thumbnail loads it into the editor and
    /// switches back out of Library mode.
    private var libraryContent: some View {
        HSplitView {
            CollectionSidebarView(catalog: catalog)
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
            LibraryGridView(catalog: catalog) { photo in
                document.load(from: URL(fileURLWithPath: photo.path))
                showLibrary = false
            }
        }
    }

    /// The single-photo editor — unchanged from before the Library grid
    /// was added, just extracted out of `mainContent` so `mainContent` can
    /// switch between this and `LibraryGridView`.
    private var editorContent: some View {
        HSplitView {
            VStack(spacing: 0) {
                EditorTabBar(selectedTab: $selectedTab)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { newHeight in
                        tabBarHeight = newHeight
                    }
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
                        // WB eyedropper tap-capture. Gated on `!isCroppingActive`
                        // (on top of `isPickingWhiteBalance` itself only ever
                        // being armable from the Adjust tab — see the
                        // `.onChange(of: selectedTab)` below) so this and
                        // `CropOverlayView`'s own drag gestures above can never
                        // both be live at once.
                        if isPickingWhiteBalance, !isCroppingActive, let fitRect = currentFitRect {
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: fitRect.width, height: fitRect.height)
                                .position(x: fitRect.midX, y: fitRect.midY)
                                .onHover { inside in
                                    if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                                }
                                .gesture(
                                    SpatialTapGesture(coordinateSpace: .local).onEnded { tap in
                                        document.pickWhiteBalance(
                                            normalizedX: tap.location.x / fitRect.width,
                                            normalizedY: tap.location.y / fitRect.height
                                        )
                                        isPickingWhiteBalance = false
                                    }
                                )
                        }
                        // Red-Eye correction markers/tap-capture. Gated on
                        // `!isCroppingActive` and `!isPickingWhiteBalance`
                        // (on top of `isPlacingRedEyeCorrections` itself only
                        // ever being armable from the Adjust tab) so only
                        // one of the three point-interaction modes can ever
                        // be live at once. UNLIKE the WB eyedropper, a tap
                        // does NOT disarm this mode — see
                        // `isPlacingRedEyeCorrections`'s own doc comment.
                        if isPlacingRedEyeCorrections, !isCroppingActive, !isPickingWhiteBalance,
                           let fitRect = currentFitRect {
                            RedEyeOverlayView(fitRect: fitRect, points: $document.editState.redEyePoints)
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
            .padding(.horizontal)
            .padding(.bottom)
            // Both `HSplitView` panes start at the SAME native y-offset
            // below the window's toolbar chrome — the image pane's content
            // only sits lower because `EditorTabBar` is prepended above it.
            // Match that exactly via the MEASURED `tabBarHeight` (see its
            // own doc comment) rather than a guessed constant — a guessed
            // constant (20) undershot in practice, since what's actually
            // needed is the tab bar's own real height, not an arbitrary
            // buffer.
            .padding(.top, tabBarHeight)
            // Belt-and-suspenders: guarantees this content block always
            // fills the full width the ScrollView offers.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The REAL bug (confirmed live, not guessed): this ScrollView was
        // starting scrolled a row past the top on appear — "Temperature"
        // existed and was correctly laid out, just not visible until
        // scrolled up manually. Not a padding/spacing problem at all (the
        // `tabBarHeight`-matched top padding above is a real, separate,
        // correct visual-alignment choice, but it wasn't THIS bug's fix).
        // `.defaultScrollAnchor(.top)` pins the initial/default scroll
        // position to the top explicitly, overriding whatever implicit
        // macOS focus-driven auto-scroll was otherwise moving it.
        .defaultScrollAnchor(.top)
        .disabled(document.currentImage == nil)
        .background(Color(white: 0.11))
    }

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

    private var adjustTabContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adjust")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            AdjustSectionContainer(icon: "sun.max", title: "Light", isExpanded: $isLightSectionExpanded) {
                lightSection
            }
            Divider()
            AdjustSectionContainer(icon: "paintpalette", title: "Color", isExpanded: $isColorSectionExpanded) {
                colorSection
            }
            Divider()
            AdjustSectionContainer(
                icon: "square.grid.3x3", title: "Selective Color", isExpanded: $isSelectiveColorSectionExpanded
            ) {
                selectiveColorSection
            }
            Divider()
            AdjustSectionContainer(
                icon: "circle.lefthalf.filled", title: "Black & White", isExpanded: $isBlackAndWhiteSectionExpanded
            ) {
                blackAndWhiteSection
            }
            Divider()
            AdjustSectionContainer(icon: "sparkles", title: "Effects", isExpanded: $isEffectsSectionExpanded) {
                effectsSection
            }
            Divider()
            AdjustSectionContainer(
                icon: "eye.trianglebadge.exclamationmark", title: "Red-Eye", isExpanded: $isRedEyeSectionExpanded
            ) {
                redEyeSection
            }
            Divider()
            resetAdjustmentsButton
        }
    }

    /// Tone/exposure-family controls, matching Apple Photos' own "Light"
    /// group — everything here operates on brightness/contrast/tonal
    /// range, not color. Just the rows — `AdjustSectionContainer` (see
    /// `adjustTabContent`) supplies the section's own header/icon/
    /// disclosure chrome and its own `VStack(spacing: 14)` wrapper.
    private var lightSection: some View {
        Group {
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
            Text("Levels").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $histogramDisplayMode) {
                ForEach(HistogramDisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HistogramView(data: document.histogramData, showChannels: histogramDisplayMode == .rgb)
            EditSliderRow(
                label: "Levels Black", value: $document.editState.levelsBlackPoint,
                range: 0...1, identity: 0
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Levels White", value: $document.editState.levelsWhitePoint,
                range: 0...1, identity: 1
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
                if isPickingWhiteBalance { isPlacingRedEyeCorrections = false }
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
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Saturation", value: $document.editState.hslSaturation,
                range: -1...1, identity: 0
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
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Vignette Radius", value: $document.editState.vignetteRadius,
                range: 0...1, identity: 0.5
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Definition", value: $document.editState.definition,
                range: 0...1, identity: 0
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Sharpen", value: $document.editState.sharpness,
                range: 0...1, identity: 0
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Noise Reduction", value: $document.editState.noiseReduction,
                range: 0...1, identity: 0
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
                if isPlacingRedEyeCorrections { isPickingWhiteBalance = false }
            } label: {
                Label("Fix Red-Eye", systemImage: "eye.trianglebadge.exclamationmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(isPlacingRedEyeCorrections ? .yellow : nil)
            EditSliderRow(
                label: "Red-Eye Size", value: $document.editState.redEyeSize,
                range: 0...1, identity: 0.5
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "Red-Eye Strength", value: $document.editState.redEyeStrength,
                range: 0...1, identity: 0.7
            ) { String(format: "%.0f%%", $0 * 100) }
            Button("Clear All Red-Eye Corrections") {
                document.editState.redEyePoints.removeAll()
            }
            .disabled(document.editState.redEyePoints.isEmpty)
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
                        selectedSelectiveColorBand = band
                    } label: {
                        Circle()
                            .fill(band.swatchColor)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: selectedSelectiveColorBand == band ? 2 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            EditSliderRow(
                label: "Range", value: $document.editState.selectiveColorRange,
                range: 0...1, identity: 0.5
            ) { String(format: "%.0f%%", $0 * 100) }
            EditSliderRow(
                label: "\(selectedSelectiveColorBand.label) Hue",
                value: selectiveColorHueBinding(for: selectedSelectiveColorBand),
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "\(selectedSelectiveColorBand.label) Saturation",
                value: selectiveColorSaturationBinding(for: selectedSelectiveColorBand),
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
            EditSliderRow(
                label: "\(selectedSelectiveColorBand.label) Luminance",
                value: selectiveColorLuminanceBinding(for: selectedSelectiveColorBand),
                range: -1...1, identity: 0
            ) { String(format: "%+.0f%%", $0 * 100) }
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
    ContentView(document: ImageDocumentModel(), catalog: CatalogModel())
}
