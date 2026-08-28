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

    /// Whether scroll-to-zoom/click-drag-to-pan are currently armable.
    /// Compare being active does NOT block zoom (the whole point is being
    /// able to zoom in while comparing) — only the three overlay-owning
    /// point-interaction/crop modes do, since their overlays are
    /// positioned against `currentFitRect` assuming no zoom/pan is active.
    private var canZoom: Bool {
        document.currentImage != nil && !isCroppingActive && !isPickingWhiteBalance && !isPlacingRedEyeCorrections
    }

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

    /// Compare feature state — Off / Side by Side / Split (before/after).
    /// Presentation-only, same reasoning as `selectedTab`/`selectedAspect`:
    /// `EditState`/`EditPipeline` are untouched, this only controls what
    /// `MetalImageView` is asked to render (see `compareOriginalEditState`
    /// and the `compare:` argument at its call site below). Mutually
    /// exclusive with crop-editing/WB-picking/red-eye-placement — see the
    /// toolbar `Menu`'s `.disabled(...)` and the `.onChange` handlers below.
    @State private var compareMode: CompareViewMode = .off
    /// Only meaningful while `compareMode == .split`.
    @State private var splitOrientation: SplitOrientation = .vertical
    /// The Split divider's position, 0...1, driven by `CompareDividerOverlay`.
    @State private var splitPosition: Double = 0.5

    /// Zoom/pan feature state — 1 = fit (no zoom); presentation-only, same
    /// reasoning as `compareMode` above: `EditState`/`EditPipeline` are
    /// untouched, this only controls the on-screen render via
    /// `MetalImageView`'s `zoomScale`/`panOffset`/`onScrollZoom`.
    /// Available in the normal Adjust view AND Compare (both modes); NOT
    /// available in Crop/WB-picking/red-eye-placement — see `canZoom` and
    /// the `.onChange`/arm-action resets below, mirroring `compareMode`'s
    /// own established mutual-exclusion pattern.
    @State private var zoomScale: CGFloat = 1
    /// Fit-rect-normalized, SwiftUI y-DOWN — see `ImageRenderer.
    /// fitted(_:into:zoomScale:panOffsetNorm:)`'s own doc comment for
    /// where this gets converted to the renderer's y-UP space.
    @State private var panOffset: CGSize = .zero

    /// The Adjust panel's own presentation-only state (section expansion,
    /// histogram mode, selected Selective Color band). Owned HERE rather than
    /// inside `AdjustTabView` because `editControls` swaps tab bodies with a
    /// `switch`, which would destroy child-owned `@State` on every switch to
    /// Crop and back — see `AdjustPanelState`'s own doc comment.
    @State private var adjustPanel = AdjustPanelState()

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

    /// Side by Side's left/right fit rects, in the SAME `containerSize`
    /// (points) space `currentFitRect` uses — reused by both the scroll
    /// handler (to decide which half the cursor is zooming) and the
    /// `PanOverlay`s rendered in `editorContent`'s `ZStack`. `nil` until
    /// laid out, matching `currentFitRect`'s own contract.
    private var sideBySideFitRects: (left: CGRect, right: CGRect)? {
        guard let image = document.currentImage, containerSize.width > 0, containerSize.height > 0 else {
            return nil
        }
        let edited = EditPipeline.apply(displayEditState, to: image)
        return CompareLayout.sideBySideFitRects(imageSize: edited.extent.size, drawableSize: containerSize)
    }

    /// Turns a raw scroll-wheel event (from `MetalImageView.onScrollZoom`,
    /// reported as a y-DOWN fraction of the WHOLE image pane) into a new
    /// zoom level + cursor-centered pan. Re-expresses the pane-relative
    /// cursor fraction against whichever fit rect is actually being
    /// zoomed (the single `currentFitRect`, or — in Side by Side — the
    /// specific half the cursor is over) before handing off to
    /// `ZoomPanGeometry`, which only ever reasons in fit-rect-normalized
    /// terms.
    private func handleScrollZoom(paneFraction: CGPoint, delta: CGFloat) {
        guard canZoom else { return }
        let cursorPoint = CGPoint(x: paneFraction.x * containerSize.width, y: paneFraction.y * containerSize.height)
        let targetFitRect: CGRect
        if compareMode == .sideBySide, let (leftRect, rightRect) = sideBySideFitRects {
            targetFitRect = cursorPoint.x < containerSize.width / 2 ? leftRect : rightRect
        } else if let fitRect = currentFitRect {
            targetFitRect = fitRect
        } else {
            return
        }
        let cursorFraction = ZoomPanGeometry.cursorFractionInFitRect(cursor: cursorPoint, fitRect: targetFitRect)
        let newZoom = ZoomPanGeometry.steppedZoom(current: zoomScale, scrollDelta: delta)
        let newPan = ZoomPanGeometry.panForZoomAboutCursor(
            oldZoom: zoomScale, newZoom: newZoom, cursorFraction: cursorFraction, oldPan: panOffset
        )
        zoomScale = newZoom
        panOffset = ZoomPanGeometry.clampedPan(newPan, zoom: newZoom)
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

    /// The Compare feature's "original" side — same presentation-only-
    /// substitution pattern as `displayEditState` above, `document.editState`
    /// remains the single source of truth. See `EditState.comparisonOriginal()`
    /// for exactly what it resets vs. keeps.
    private var compareOriginalEditState: EditState { document.editState.comparisonOriginal() }

    /// `nil` when Compare is off (the default, unchanged single-image
    /// render path); otherwise bundles everything `ImageRenderer` needs.
    /// Compare only ever runs on the Adjust tab (see the toolbar `Menu`'s
    /// `.disabled(...)` and the tab-change reset below), so
    /// `compareOriginalEditState`/`displayEditState` are never substituting
    /// for crop-editing mode at the same time.
    private var compareRenderConfig: CompareRenderConfig? {
        switch compareMode {
        case .off:
            return nil
        case .sideBySide:
            return CompareRenderConfig(originalState: compareOriginalEditState, mode: .sideBySide)
        case .split:
            return CompareRenderConfig(
                originalState: compareOriginalEditState,
                mode: .split(orientation: splitOrientation, position: splitPosition)
            )
        }
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
                    ExportProgressHUD(progress: progress)
                }
            }
            // Bridges these two otherwise fully-decoupled models (same
            // direction of composition as `LibraryGridView`'s own
            // `document.load(from:)` callback below) so editing a photo
            // invalidates its stale Library thumbnail instead of leaving
            // it showing the original forever.
            .onAppear {
                document.onSidecarSaved = { url in catalog.invalidateThumbnail(for: url) }
            }
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
        // Leaving the Editor for the Library: flush any still-debounced
        // sidecar save NOW, not up to ~1s later. `LibraryGridView` is torn
        // down/recreated on every visit (see `showLibrary`'s `if/else`
        // above), so its thumbnails re-fetch immediately on appearing —
        // without this flush, a just-undone/edited photo could still be
        // mid-debounce, so its sidecar (and therefore `onSidecarSaved`'s
        // cache invalidation) wouldn't have happened yet, showing a stale
        // thumbnail until some LATER action (e.g. opening another photo)
        // happened to flush it — a real bug caught live.
        .onChange(of: showLibrary) { _, isNowShowingLibrary in
            if isNowShowingLibrary { document.flushPendingSidecarSave() }
        }
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
            compareMode = .off
            splitOrientation = .vertical
            splitPosition = 0.5
            zoomScale = 1
            panOffset = .zero
        }
        // Leaving the Adjust tab disarms both point-interaction modes —
        // neither has meaning while cropping (their overlays are gated on
        // `!isCroppingActive` anyway) or in the other, not-yet-built tabs —
        // and Compare/zoom, which only ever run on the Adjust tab (see the
        // toolbar Menu's `.disabled(...)` and `canZoom`).
        .onChange(of: selectedTab) { _, newTab in
            if newTab != .adjust {
                isPickingWhiteBalance = false
                isPlacingRedEyeCorrections = false
                compareMode = .off
                zoomScale = 1
                panOffset = .zero
            }
        }
        // A Compare-mode switch gets a fresh zoom/pan — the fit rect
        // differs between single-image, Side by Side's halves, and Split,
        // so a pan/zoom computed for one doesn't map cleanly onto another.
        .onChange(of: compareMode) { _, _ in
            zoomScale = 1
            panOffset = .zero
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
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker("Compare", selection: $compareMode) {
                        Text("Off").tag(CompareViewMode.off)
                        Text("Side by Side").tag(CompareViewMode.sideBySide)
                        Text("Split (Before/After)").tag(CompareViewMode.split)
                    }
                    if compareMode == .split {
                        Divider()
                        Picker("Orientation", selection: $splitOrientation) {
                            Text("Vertical").tag(SplitOrientation.vertical)
                            Text("Horizontal").tag(SplitOrientation.horizontal)
                        }
                    }
                } label: {
                    Label("Compare", systemImage: "rectangle.split.2x1")
                }
                // Only meaningful on the Adjust tab with no other
                // point-interaction mode armed — same one-at-a-time
                // invariant the WB/red-eye buttons already keep (see their
                // own `.disabled`/mutual-disarm below).
                .disabled(
                    document.currentImage == nil || isCroppingActive
                        || isPickingWhiteBalance || isPlacingRedEyeCorrections
                )
                .tint(compareMode != .off ? .yellow : nil)
                .onChange(of: compareMode) { _, newMode in
                    if newMode != .off {
                        isPickingWhiteBalance = false
                        isPlacingRedEyeCorrections = false
                    }
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
                        MetalImageView(
                            image: document.currentImage, editState: displayEditState, compare: compareRenderConfig,
                            zoomScale: zoomScale, panOffset: panOffset, zoomEnabled: canZoom,
                            onScrollZoom: { fraction, delta in handleScrollZoom(paneFraction: fraction, delta: delta) }
                        )
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
                        // Compare Split's draggable divider. `compareMode`
                        // can only be non-`.off` on the Adjust tab with no
                        // other point-interaction mode armed (see the
                        // toolbar Menu's `.disabled(...)`), so this can
                        // never overlap the three overlays above.
                        if compareMode == .split, let fitRect = currentFitRect {
                            CompareDividerOverlay(fitRect: fitRect, orientation: splitOrientation, position: $splitPosition)
                        }
                        // Click-drag-to-pan, once zoomed past fit. Not
                        // shown in Split — the divider above already owns
                        // click-drag there; scroll-to-zoom still works in
                        // Split (the `NSEvent` monitor doesn't depend on
                        // this overlay), you just can't ALSO drag to
                        // reposition without changing zoom. In Side by
                        // Side, TWO overlays (one per half, both bound to
                        // the same `$zoomScale`/`$panOffset`) so dragging
                        // either photo pans both in sync.
                        if canZoom, zoomScale > 1 {
                            if compareMode == .sideBySide, let (leftRect, rightRect) = sideBySideFitRects {
                                PanOverlay(fitRect: leftRect, zoomScale: $zoomScale, panOffset: $panOffset)
                                PanOverlay(fitRect: rightRect, zoomScale: $zoomScale, panOffset: $panOffset)
                            } else if compareMode != .split, let fitRect = currentFitRect {
                                PanOverlay(fitRect: fitRect, zoomScale: $zoomScale, panOffset: $panOffset)
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .onAppear { containerSize = proxy.size }
                    .onChange(of: proxy.size) { _, newSize in containerSize = newSize }
                    .overlay(alignment: .bottomTrailing) {
                        if zoomScale > 1 {
                            ZoomPercentageHUD(zoomScale: zoomScale)
                        }
                    }
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
                case .adjust:
                    AdjustTabView(
                        document: document,
                        panel: $adjustPanel,
                        isPickingWhiteBalance: $isPickingWhiteBalance,
                        isPlacingRedEyeCorrections: $isPlacingRedEyeCorrections,
                        onEnterPointPickingMode: {
                            compareMode = .off
                            zoomScale = 1
                            panOffset = .zero
                        }
                    )
                case .crop:
                    CropTabView(
                        document: document,
                        selectedAspect: selectedAspect,
                        onSelectAspect: { selectAspect($0) },
                        onReset: { resetCropTab() }
                    )
                case .filters: PlaceholderTab(message: "Filters aren't available yet.")
                case .cleanUp: PlaceholderTab(message: "Clean Up isn't available yet.")
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

}

#Preview {
    ContentView(document: ImageDocumentModel(), catalog: CatalogModel())
}
