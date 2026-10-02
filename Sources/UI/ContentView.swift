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

    /// Owns "Copy Settings"/"Paste Settings" (a Lightroom-style Copy/Paste
    /// Edit Settings across a Library multi-selection). Owned by
    /// `PhotoAppApp`, not this view — same reasoning as `document`/
    /// `catalog`: the Photo menu's own ⇧⌘C/⇧⌘V (a Scene-level construct)
    /// needs to act on the SAME instance the toolbar buttons below do.
    @ObservedObject var pasteModel: PasteSettingsModel

    /// The Library's "Rename Files…" sheet and "Undo Rename". Owned by `PhotoAppApp` (its Photo-menu
    /// items must reach the same instance); those items only set `renameModel.request`, which this
    /// view performs below because only it can see the selection and the Export/Enhance state.
    @ObservedObject var renameModel: RenameModel

    /// What batch rename must re-check at APPLY and UNDO time (see `RenameModel`): a load in flight,
    /// a running Export/Enhance, or an open paste confirmation makes renaming unsafe right now.
    private var renameProviders: RenameProviders {
        RenameProviders(
            openPhotoPath: { document.currentURL?.path },
            busyReason: {
                RenameBusyState(
                    isLoadInFlight: document.isLoadInFlight,
                    isExporting: exportModel.isExporting,
                    isExportSheetOpen: exportModel.isPresentingOptions,
                    isEnhancing: enhanceModel.isEnhancing,
                    isImporting: catalog.isImporting,
                    hasPendingPaste: pasteModel.pendingTargets != nil,
                    hasModalPanel: NSApp.modalWindow != nil
                ).reason
            }
        )
    }

    /// Phase 5 slice 1: batch export. Scoped to this view (not lifted to
    /// `PhotoAppApp`) — unlike `document`/`catalog`, nothing outside this
    /// view (no Scene-level command, no other view) needs to observe it.
    @StateObject private var exportModel = ExportModel()

    /// Enhance/Super Resolution. Same scoping reasoning as `exportModel`
    /// — v1 deliberately has no Photo-menu item (unlike `pasteModel`'s
    /// ⇧⌘C/⇧⌘V, a Scene-level construct), so nothing outside this view
    /// needs to observe it.
    @StateObject private var enhanceModel = EnhanceModel()

    /// What "Export…" actually exports. A pure refinement on top of the
    /// existing filtered set: if 1+ photos are checked in the grid,
    /// export ONLY those (overriding whatever Collection/Folder is
    /// active in the sidebar); with nothing checked, behaves exactly as
    /// before this feature existed — the current filtered set.
    private var photosToExport: [Photo] {
        guard !catalog.selectedPhotoIDs.isEmpty else { return catalog.photos }
        return catalog.photos.filter { catalog.isSelected($0) }
    }

    /// What "Add to Collection" actually acts on — the same
    /// currently-displayed-and-selected intersection
    /// `CatalogModel.addSelectedPhotos` itself computes internally, so the
    /// menu can't be left enabled for a selection that would silently do
    /// nothing (e.g. a photo toggled out of the collection being viewed,
    /// which stays selected — see that method's own doc comment). Forwards
    /// to `CatalogModel.selectedPhotos`, so a planned batch-paste feature's
    /// own Scene-level shortcut (which has no access to this private
    /// property) can share the exact same filter.
    private var selectedPhotosVisibleInGrid: [Photo] {
        catalog.selectedPhotos
    }

    /// Kept as a small helper, not inlined into the `.confirmationDialog`
    /// closure below — this file's own `mainContent`/`body` have hit a
    /// real Swift type-checker scaling limit before from too much packed
    /// into one `@ViewBuilder` closure; string interpolation this size
    /// stays out of that closure on principle, not because it's strictly
    /// required here.
    private var pasteConfirmationTitle: String {
        let count = pasteModel.pendingTargets?.count ?? 0
        return "Paste settings onto \(count) photo\(count == 1 ? "" : "s")?"
    }

    /// Names the copied source and states the irreversibility caveat —
    /// only the currently-open photo (if included in `targets`) is
    /// undoable; every other target is overwritten on disk directly.
    /// Reviewer-caught: the original wording ("Crop, masks, and red-eye
    /// corrections are kept") understated what `EditState.
    /// applyingPreset(onto:)` — the merge this feature reuses — actually
    /// leaves untouched on each target: geometry (crop, straighten,
    /// perspective, scale/stretch, flip), masks, red-eye POINTS (their
    /// correction intensity IS copied, matching how Presets already treat
    /// this field), and every RAW-native field (white balance set via the
    /// RAW eyedropper fast-path, Boost, RAW noise reduction/sharpness/
    /// contrast/detail/moiré, the decoder version pin). A photo whose
    /// White Balance was set via that RAW-native fast path won't get its
    /// White Balance carried at all — a real, user-visible v1 gap this
    /// message now names rather than implies is comprehensive.
    private func pasteConfirmationMessage(for targets: [Photo]) -> String {
        let source = pasteModel.copied?.sourceFileName ?? "the copied photo"
        let openPath = document.currentURL?.path
        let includesOpenPhoto = openPath != nil && targets.contains { $0.path == openPath }
        let undoNote = includesOpenPhoto
            ? "This can't be undone, except for the currently open photo."
            : "This can't be undone."
        return """
        Settings copied from \(source). Each photo's own crop, geometry, masks, Point Color, and \
        RAW-specific adjustments (including White Balance set with the RAW eyedropper) are kept. \(undoNote)
        """
    }

    /// Phase 4 slice 2: toggles the main window between the single-photo
    /// Editor (the existing `HSplitView`, unchanged) and the Library
    /// thumbnail grid. Presentation-only — switching back to the Editor
    /// leaves whatever photo was already loaded exactly as it was. Owned by
    /// `PhotoAppApp` rather than this view (it was `@State` here until the
    /// Photo menu's ⌘←/⌘→ commands needed to disable while the grid is up);
    /// everything below uses it exactly as before, through the binding.
    @Binding var showLibrary: Bool

    /// Which top-level editing tool is active — Apple Photos-style tab bar.
    /// Selecting `.crop` IS entering crop-editing mode (see `isCroppingActive`
    /// below); there's no separate in-sidebar toggle anymore.
    @State private var selectedTab: EditorTab = .adjust

    /// IMPROVEMENTS.md D1(b): whether the bottom filmstrip (browsing
    /// between photos without leaving the Editor) is shown. Presentation-
    /// only, defaults on to match Lightroom/Photos' own default.
    @State private var isFilmstripVisible = true

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
    /// able to zoom in while comparing) — only the four overlay-owning
    /// point-interaction/crop/mask modes do, since their overlays are
    /// positioned against `currentFitRect` assuming no zoom/pan is active.
    /// Phase 7 slice 3 Session A briefly narrowed this to a `.radial`-only
    /// variant of this check (a since-deleted `isEditingRadialMask`
    /// property — don't grep for it, it's gone), since the Linear mask had
    /// no overlay yet — that carve-out is gone now that
    /// `LinearMaskOverlayView` exists (Session B) and is ALSO positioned
    /// against `currentFitRect` with the same no-zoom/pan assumption, so
    /// both kinds share this one kind-agnostic gate again.
    private var canZoom: Bool {
        // `!isPaintingBrush` is currently implied by `!isEditingOverlayMask`
        // (the painted mask is always also the selected one — see
        // `isPaintingBrush`'s own doc comment) but spelled out explicitly
        // rather than relied on, matching this property's own documented
        // history of NOT assuming one mode implies another (Session A's
        // now-deleted `isEditingRadialMask` carve-out was exactly that kind
        // of implicit coupling). Phase 7 slice 5: `isEditingMask` narrowed
        // to `isEditingOverlayMask` here — a mask kind with no on-image
        // overlay (`.luminanceRange`) has no reason to block zoom/pan,
        // since this restriction exists ONLY because an overlay is
        // positioned against an un-zoomed `currentFitRect`.
        // Phase 7 slice 5 (second half): `!isPickingColorRange` is its own
        // term, NOT routed through `isEditingOverlayMask` — different
        // concern: `hasOnImageOverlay(.colorRange)` is `false` (nothing to
        // draw), but the eyedropper TAP's own `location -> image fraction`
        // math still assumes an un-zoomed `currentFitRect`, same as the WB
        // eyedropper's own capture layer. `!isPickingPointColor` is the
        // exact same term, one kind later (Point Color Slice B) — same
        // reasoning, same un-zoomed assumption in its own tap-capture layer.
        document.currentImage != nil && !isCroppingActive && !isPickingWhiteBalance
            && !isPlacingRedEyeCorrections && !isEditingOverlayMask && !isPaintingBrush && !isPickingColorRange
            && !isPickingPointColor && !isEditingRetouchSpot
    }

    /// Spot removal: whether a spot is selected in the (expanded) Remove section at identity geometry — the only
    /// state in which its on-image circles are drawn. Resolved against the LIVE array (Undo/Revert can delete the
    /// selected spot without passing through any disarm site) and, like every overlay, it blocks zoom/pan because the
    /// circles are positioned against the un-zoomed `currentFitRect`.
    private var isEditingRetouchSpot: Bool {
        guard adjustPanel.isRetouchSectionExpanded, !isCroppingActive,
              document.editState.isGeometryAtIdentity,
              let id = adjustPanel.selectedRetouchSpotID else { return false }
        return document.editState.retouchSpots.contains { $0.id == id }
    }

    /// Phase 7 slice 2: the mask `adjustPanel.selectedMaskID` currently
    /// editing, RESOLVED against the LIVE array on every read — never
    /// trust `adjustPanel.selectedMaskID` raw. Undo, Revert to Original,
    /// and Apply Preset can all delete the selected mask WITHOUT passing
    /// through any of this file's own disarm sites, which would otherwise
    /// leave the overlay gate / Escape routing stuck pointing at a mask
    /// that no longer exists. Same "compute the truth, don't trust every
    /// call site" shape as `EditState.isEffectivelyIdentity`. Kind-
    /// agnostic — both `.radial` and `.linear` masks now have their own
    /// on-image overlay (`MaskOverlayView`/`LinearMaskOverlayView`), so
    /// there's no longer any call site that needs to narrow this to one
    /// kind (see `canZoom`'s own doc comment for the one that used to).
    private var isEditingMask: Bool {
        guard let id = adjustPanel.selectedMaskID else { return false }
        return document.editState.masks.contains { $0.id == id }
    }

    /// Point Color Slice B: the same "compute the truth, don't trust the
    /// stored id" shape as `isEditingMask` — Undo, Revert to Original, and
    /// Apply Preset can all delete the selected instance WITHOUT passing
    /// through `deletePointColor`, which would otherwise leave
    /// `pointColorPickingID` pointing at an instance that no longer exists.
    private var isPointColorSelected: Bool {
        guard let id = adjustPanel.selectedPointColorID else { return false }
        return document.editState.pointColors.contains { $0.id == id }
    }

    /// Whether `kind` draws an on-image overlay positioned against
    /// `currentFitRect`. Exhaustive on purpose, same reasoning as
    /// `AdjustTabView`'s own copy of this switch (UI knowledge, not
    /// `EditEngine` knowledge — deliberately duplicated rather than
    /// shared, since `EditEngine` stays UI/rendering-API-free).
    private func hasOnImageOverlay(_ kind: MaskKind) -> Bool {
        switch kind {
        case .radial, .linear, .brush: return true
        // `.colorRange`: a one-shot eyedropper tap is not a persistent
        // draggable shape — `isEditingOverlayMask` (which this feeds) is
        // NOT the gate for the pick capture layer, `colorPickingMaskID`
        // is (see `pointAndZoomOverlays`'s own new branch).
        case .luminanceRange, .colorRange, .subject: return false
        }
    }

    /// Phase 7 slice 5: `isEditingMask`, narrowed to kinds that actually
    /// own an on-image overlay. THIS — not `isEditingMask` — is what
    /// should block zoom/pan or claim keyboard focus: those restrictions
    /// exist only because an overlay is positioned against an un-zoomed
    /// `currentFitRect`, so a kind with no overlay (`.luminanceRange`) has
    /// no reason to pay them. `isEditingMask` itself is UNCHANGED and
    /// keeps its existing jobs (the `brushPaintingMaskID` safety net
    /// below is about the selected mask's mere existence, not about an
    /// overlay) — but reviewer-caught: Escape's own key handler still
    /// KEYS OFF `isEditingMask` unconditionally, it just isn't
    /// GUARANTEED REACHABLE for `.luminanceRange` the way it is for an
    /// overlay kind, since `select(_:)` no longer grabs image-pane focus
    /// for it and the rising-edge `.onChange(of: selectedMaskID)` focus
    /// grab is now gated to `hasOnImageOverlay`. Harmless for this kind
    /// specifically (deselecting a `.luminanceRange` mask blocks nothing
    /// now that `canZoom` is itself kind-aware, unlike an overlay kind
    /// where losing Escape would strand the user mid-drag) — but Escape
    /// is not unconditionally reachable the way this comment used to
    /// imply.
    private var isEditingOverlayMask: Bool {
        guard let id = adjustPanel.selectedMaskID,
              let mask = document.editState.masks.first(where: { $0.id == id })
        else { return false }
        return hasOnImageOverlay(mask.kind)
    }

    /// The Editor's single armed-interaction-mode value — replaces 5
    /// separate `@State` properties (a bool each for WB/Red-Eye, a `UUID?`
    /// each for brush-painting/Color-Range-picking/Point-Color-picking)
    /// that 6 separate arm sites in `AdjustTabView` used to keep mutually
    /// exclusive by hand. See `EditorInteractionMode`'s own doc comment for
    /// the full history (IMPROVEMENTS.md D14).
    @State private var interactionMode: EditorInteractionMode = .none

    /// The 5 properties below are READ-ONLY projections of `interactionMode`
    /// kept under their original names/types — every existing read site
    /// (`canZoom`, the overlay gates, `.onChange` handlers, the crosshair
    /// tint switch) keeps reading exactly these, unchanged. Only writes
    /// (armed/disarmed transitions) go through `interactionMode` itself now.

    /// Phase 7 slice 4: which mask (if any) currently has live brush-paint
    /// mode armed — `UUID?`, not `Bool` (F4), so the falling-edge cleanup
    /// (`discardUnpaintedBrushMask`, wired via the `.onChange` below) can
    /// name the OLD id even after `AdjustTabView.select`/`beginBrushStroke`
    /// has already repointed `adjustPanel.selectedMaskID`. Always set
    /// TOGETHER with `adjustPanel.selectedMaskID` (`AdjustTabView.addMask`/
    /// `beginBrushStroke` both do), so `isPaintingBrush` implies
    /// `isEditingMask` in practice — see `canZoom`'s own doc comment for
    /// why that implication is still spelled out explicitly there rather
    /// than relied on.
    private var brushPaintingMaskID: UUID? { interactionMode.brushPaintingMaskID }
    private var isPaintingBrush: Bool { brushPaintingMaskID != nil }

    /// Phase 7 slice 5 (second half): which mask (if any) currently has
    /// the Color Range eyedropper armed — `UUID?`, not `Bool`, same F4
    /// reasoning as `brushPaintingMaskID` (a future falling-edge cleanup
    /// would need to name the OLD id). UNLIKE `brushPaintingMaskID`, this
    /// kind has no on-image overlay at all (`hasOnImageOverlay(.colorRange)`
    /// is `false`) — this state exists purely to gate the tap-capture
    /// layer in `pointAndZoomOverlays` and `canZoom`'s own
    /// `isPickingColorRange` term, not to draw anything.
    private var colorPickingMaskID: UUID? { interactionMode.colorPickingMaskID }
    private var isPickingColorRange: Bool { colorPickingMaskID != nil }

    /// Point Color Slice B: which point color instance (if any) currently
    /// has its eyedropper armed — `UUID?`, same F4/`colorPickingMaskID`
    /// reasoning (a falling-edge cleanup needs to name the OLD id). Like
    /// `.colorRange`, this kind has no on-image overlay at all — this state
    /// exists purely to gate the tap-capture layer in `pointAndZoomOverlays`
    /// and `canZoom`'s own `isPickingPointColor` term.
    private var pointColorPickingID: UUID? { interactionMode.pointColorPickingID }
    private var isPickingPointColor: Bool { pointColorPickingID != nil }

    /// Whether a tap on the image should be captured as a WB eyedropper
    /// sample. Its own overlay only exists while this is true AND cropping
    /// is not active (see `body`), so the two point-interactions are
    /// mutually exclusive by construction, not by a shared runtime check.
    private var isPickingWhiteBalance: Bool { interactionMode.isPickingWhiteBalance }

    /// Whether taps on the image should place/remove Red-Eye correction
    /// points. UNLIKE `isPickingWhiteBalance`, placing a point does NOT
    /// auto-disarm this mode — the user will often place several
    /// corrections (both eyes) in one sitting, so it stays armed until
    /// toggled off or the user leaves the Adjust tab.
    private var isPlacingRedEyeCorrections: Bool { interactionMode.isPlacingRedEyeCorrections }

    /// D8 (IMPROVEMENTS.md): the keyboard-driven crosshair's current
    /// position — normalized 0...1, SwiftUI-local/y-DOWN, the SAME
    /// convention `ImageDocumentModel.pickWhiteBalance`/`RedEyePoint`
    /// already use. Shared by WB pick and Red-Eye placement (never both
    /// at once — they're already mutually exclusive by construction, see
    /// `isPickingWhiteBalance`'s own doc comment); meaningless while
    /// neither mode is armed, but kept as one plain property rather than
    /// two mode-specific ones since only one can ever be relevant.
    /// Reset to center whenever either mode newly arms — see the
    /// `.onChange` handlers below — and kept in sync with the MOUSE too
    /// (the WB tap handler and `RedEyeOverlayView`'s `onTap`), the direct
    /// analogue of a real bug D4's reviewer caught: without that sync, a
    /// keypress after a mouse click could silently act on a stale
    /// position instead of where the user just clicked.
    @State private var crosshairPosition = CGPoint(x: 0.5, y: 0.5)

    /// D8 (IMPROVEMENTS.md): whether the image pane itself (as opposed to
    /// a sidebar slider, the search field, or nothing) currently holds
    /// keyboard focus — required for `.onKeyPress` below to fire at all.
    /// This is the Editor's FIRST use of `.focusable()`/`.onKeyPress`
    /// anywhere; deliberately not the `NSEvent` scroll-wheel monitor
    /// pattern `MetalImageView` already uses for zoom, since that monitor
    /// fires BEFORE SwiftUI's own focus dispatch — exactly wrong here, it
    /// would steal keystrokes from any focused sidebar `TextField`.
    @FocusState private var isImagePaneFocused: Bool

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

    // MARK: - D8 (IMPROVEMENTS.md): keyboard paths for the point-placement/pan overlays

    /// One dispatch point for every key the image pane handles while it
    /// holds keyboard focus (`isImagePaneFocused`). Bails immediately
    /// unless `keyPress.modifiers.isDisjoint(with: [.command, .option,
    /// .control])` — the D4-final form (see that feature's own
    /// `PROGRESS.md` write-up): subtracting an "allowed" set like
    /// `.shift` instead would reject every arrow press outright, since
    /// macOS tags arrow-key events with `.numericPad`/`.function`
    /// regardless of any real modifier.
    private func handleImagePaneKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let semanticModifiers: EventModifiers = [.command, .option, .control]
        guard keyPress.modifiers.isDisjoint(with: semanticModifiers) else { return .ignored }

        // Reviewer-caught: the render branches in `pointAndZoomOverlays`
        // all defensively re-check `!isCroppingActive` on top of
        // `isPickingWhiteBalance`/`isPlacingRedEyeCorrections` (trusting
        // `.onChange(of: selectedTab)` to have disarmed both isn't enough
        // for THEM), so the key path matches that same discipline rather
        // than trusting the invariant silently — if it ever breaks, this
        // fails closed (falls through to the pan branch, or `.ignored`)
        // instead of committing a point against a crop-mode `fitRect`
        // with no crosshair even drawn.
        if !isCroppingActive,
           isPickingWhiteBalance || isPlacingRedEyeCorrections || isPickingPointColor || isPickingColorRange {
            return handlePointPlacementKeyPress(keyPress)
        }
        // Phase 7 slice 2: same defensive re-check discipline as the
        // branch above — `!isCroppingActive` on top of `isEditingMask`,
        // not trusting `.onChange(of: selectedTab)` alone.
        //
        // Only intercept when `handleMaskKeyPress` actually handles the
        // key (Escape); any other key falls through to the pan branch
        // below. A selected mask (either kind) currently forces `canZoom
        // == false` again (see that property's own doc comment), so pan
        // can't fire regardless — but Session A briefly had a window
        // where a selected `.linear` mask left `canZoom` true while this
        // routing still unconditionally swallowed every key, silently
        // breaking arrow-key panning. Keeping this narrower
        // only-intercept-on-`.handled` form is defensive practice against
        // that same class of regression recurring, independent of
        // whichever kind currently does or doesn't block zoom.
        if !isCroppingActive, isEditingMask {
            let maskResult = handleMaskKeyPress(keyPress)
            if maskResult == .handled { return maskResult }
        }
        // Point Color Slice B: same only-intercept-on-`.handled` discipline
        // as the mask branch above, for the SAME reason. Reviewer-caught
        // gap: without this, a merely-SELECTED (not currently picking)
        // Point Color instance had no keyboard way to deselect at all —
        // the branch above only covers the picking-mode Escape stage
        // (`handlePointPlacementKeyPress`, reached while `isPickingPointColor`
        // is still true); once the eyedropper disarms, `isPickingPointColor`
        // goes false and nothing else routed Escape to the selection itself.
        if !isCroppingActive, isPointColorSelected {
            let pointColorResult = handlePointColorKeyPress(keyPress)
            if pointColorResult == .handled { return pointColorResult }
        }
        if canZoom, zoomScale > 1, compareMode != .split {
            return handlePanKeyPress(keyPress)
        }
        return .ignored
    }

    /// Escape deselects the currently-selected Point Color instance — the
    /// `isEditingMask`/`handleMaskKeyPress` analogue for this kind. No
    /// intermediate "picking-only" stage needed here the way brush masks
    /// have: that stage already exists one level up, inside
    /// `handlePointPlacementKeyPress` (Point Color's eyedropper IS routed
    /// through the shared point-placement dispatch — D14, IMPROVEMENTS.md,
    /// Color Range's own eyedropper now routes through the exact same
    /// dispatch too) — by the time control reaches here,
    /// `pointColorPickingID` is already `nil` and only the SELECTION
    /// remains to clear.
    private func handlePointColorKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard keyPress.key == .escape else { return .ignored }
        adjustPanel.selectedPointColorID = nil
        return .handled
    }

    /// Escape deselects the currently-edited mask — matches every other
    /// Editor mode's own Escape behavior (`handlePointPlacementKeyPress`
    /// below), and without it there would be no keyboard way to leave
    /// mask-editing (which, given `canZoom`'s own mask gate, means no
    /// keyboard way to re-enable zoom either). Arrow-key nudge/resize of
    /// either overlay itself is deliberately deferred — `MaskDetailView`'s
    /// slider rows (14 for `.radial`, 12 for `.linear`) are this slice's
    /// accessibility answer, matching how `CropOverlayView` covers the
    /// same bar via `CropTabView`'s sliders. `.brush` (Phase 7 slice 4) is
    /// the one kind this reasoning does NOT extend to — a stroke's own
    /// shape has no slider equivalent; see `IMPROVEMENTS.md`'s D11 for
    /// that gap. NOT `phase == .down`-gated: a
    /// repeated deselect is idempotent, the same reasoning
    /// `handlePointPlacementKeyPress`'s own Escape case uses. The caller
    /// only short-circuits on `.handled` (Escape) — any other key falls
    /// through to pan handling, see that call site's own comment for why.
    private func handleMaskKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard keyPress.key == .escape else { return .ignored }
        // Phase 7 slice 4: two-stage, mirroring `handlePointPlacementKeyPress`'s
        // own Escape-disarms-without-committing shape. While actively
        // painting, Escape disarms paint mode ONLY (whatever's already
        // painted survives, or the never-painted mask is discarded by
        // `discardUnpaintedBrushMask` via the falling-edge `.onChange`
        // below) — the mask stays selected, so a SECOND Escape is still
        // needed to deselect, matching every other mode's "one Escape per
        // stage" shape.
        if isPaintingBrush {
            // Guarded by `isPaintingBrush`, so `interactionMode` is exactly
            // `.paintingBrush` here — a blanket `.none` is safe (nothing
            // else could be armed under the one-at-a-time invariant).
            interactionMode = .none
            return .handled
        }
        // D14 (IMPROVEMENTS.md): Color Range's own eyedropper-Escape stage
        // USED to live here (a bespoke branch mirroring `.brush`'s own
        // two-stage shape above), back when it was mouse-only and never
        // reached `handleImagePaneKeyPress`'s point-placement dispatch at
        // all. Now that `isPickingColorRange` is included in THAT dispatch's
        // own arm-check, Escape while picking is caught by
        // `handlePointPlacementKeyPress`'s `.escape` case before control
        // ever reaches this function — this function only ever sees Escape
        // for the SECOND stage (deselecting an already-disarmed mask,
        // the `adjustPanel.selectedMaskID = nil` line below), matching how
        // Point Color's own two stages are already split across
        // `handlePointPlacementKeyPress` (picking) and
        // `handlePointColorKeyPress` (selection) rather than living
        // together in one function.
        adjustPanel.selectedMaskID = nil
        return .handled
    }

    /// F5: deletes `id` iff it's a `.brush` mask that was armed for
    /// painting and NEVER PAINTED (no points, geometry-only/identity
    /// adjustments) — i.e. exactly the "Add Brush, then Escape/switch away
    /// without drawing" case. Wired to `brushPaintingMaskID`'s change (see
    /// the `.onChange` below), which covers every disarm route EXCEPT
    /// PHOTO SWITCH (Escape, natural stroke end via `onStrokeEnded`, tab
    /// switch, Compare, WB, Red-Eye, selecting another mask, collapsing
    /// the Masks section ARE all covered — confirmed, not just claimed,
    /// via a reviewer trace) in ONE place, rather than needing each disarm
    /// site to separately remember this cleanup. Never fires for "Redraw
    /// Stroke" on an already-painted mask: that mask has real points (F5
    /// also mandates `BrushMaskOverlayView`'s `onChanged` never clears
    /// `brushPoints` before the new gesture's first point), so
    /// `brushPoints.isEmpty` is false the whole time.
    ///
    /// Reviewer-caught (real, not fixed this slice — see IMPROVEMENTS.md's
    /// D13): switching PHOTOS while an unpainted brush mask is armed is
    /// NOT actually covered, despite this doc comment previously claiming
    /// otherwise. `ImageDocumentModel.load(from:)` sets `currentURL` and
    /// `editState` to the INCOMING photo synchronously, in the same block
    /// — by the time `.onChange(of: document.currentURL)` below fires and
    /// clears `brushPaintingMaskID`, `document.editState.masks` is
    /// already the new photo's array, so `discardUnpaintedBrushMask`
    /// looks the old id up in the WRONG photo and silently no-ops, while
    /// the outgoing photo's phantom empty mask has already been flushed
    /// to its own sidecar. Fixing this properly needs the cleanup to run
    /// BEFORE `load(from:)` swaps state, at every photo-switch call site
    /// (filmstrip, Library grid, ⌘←/⌘→) or via a hook inside
    /// `ImageDocumentModel` itself — out of scope for this slice's own
    /// `ContentView`-only disarm mechanism.
    private func discardUnpaintedBrushMask(_ id: UUID?) {
        guard let id, let mask = document.editState.masks.first(where: { $0.id == id }) else { return }
        guard mask.kind == .brush, mask.brushPoints.isEmpty, mask.isIdentity else { return }
        document.editState.masks.removeAll { $0.id == id }
        if adjustPanel.selectedMaskID == id {
            adjustPanel.selectedMaskID = nil
        }
    }

    /// Phase 7 slice 5 (second half): the `.colorRange` analogue of
    /// `discardUnpaintedBrushMask` — deletes `id` iff it's a `.colorRange`
    /// mask that was armed for the eyedropper and NEVER PICKED (no
    /// `colorRangeHasTarget`, geometry-only/identity adjustments), i.e.
    /// exactly the "Add Color, then Escape/switch away without tapping"
    /// case. Wired to `colorPickingMaskID`'s change the same way, and
    /// inherits that mechanism's own documented photo-switch gap (see
    /// `discardUnpaintedBrushMask`'s own doc comment and IMPROVEMENTS.md's
    /// D13 — not re-litigated here, same root cause, same accepted scope).
    private func discardUnpickedColorRangeMask(_ id: UUID?) {
        guard let id, let mask = document.editState.masks.first(where: { $0.id == id }) else { return }
        guard mask.kind == .colorRange, !mask.colorRangeHasTarget, mask.isIdentity else { return }
        document.editState.masks.removeAll { $0.id == id }
        if adjustPanel.selectedMaskID == id {
            adjustPanel.selectedMaskID = nil
        }
    }

    /// Point Color Slice B: the Point Color analogue of
    /// `discardUnpickedColorRangeMask` — deletes `id` iff it's an instance
    /// that was armed for the eyedropper and NEVER PICKED (no `hasTarget`,
    /// identity adjustments — `PointColor.isIdentity` is exactly this,
    /// adjustment fields only, matching `Mask.isIdentity`), i.e. exactly
    /// the "Add Point Color, then Escape/switch away without tapping"
    /// case. Wired to `pointColorPickingID`'s change the same way, and
    /// inherits that mechanism's own documented photo-switch gap (see
    /// `discardUnpaintedBrushMask`'s own doc comment and IMPROVEMENTS.md's
    /// D13 — not re-litigated here, same root cause, same accepted scope).
    private func discardUnpickedPointColor(_ id: UUID?) {
        guard let id, let pointColor = document.editState.pointColors.first(where: { $0.id == id }) else { return }
        guard !pointColor.hasTarget, pointColor.isIdentity else { return }
        document.editState.pointColors.removeAll { $0.id == id }
        if adjustPanel.selectedPointColorID == id {
            adjustPanel.selectedPointColorID = nil
        }
    }

    /// Arrow keys move `crosshairPosition`; Return commits (samples WB,
    /// toggles a Red-Eye point, or picks a Point Color/Color Range target
    /// at the crosshair — see `commitPointPlacement`); Escape disarms
    /// without committing — a
    /// genuinely NEW capability, since today there's no way to leave
    /// point-placement mode without a mouse click on the toolbar button
    /// or switching tabs.
    private func handlePointPlacementKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        switch keyPress.key {
        case .leftArrow:
            crosshairPosition = CrosshairGeometry.moved(crosshairPosition, dx: -CrosshairGeometry.step, dy: 0)
        case .rightArrow:
            crosshairPosition = CrosshairGeometry.moved(crosshairPosition, dx: CrosshairGeometry.step, dy: 0)
        case .upArrow:
            crosshairPosition = CrosshairGeometry.moved(crosshairPosition, dx: 0, dy: -CrosshairGeometry.step)
        case .downArrow:
            crosshairPosition = CrosshairGeometry.moved(crosshairPosition, dx: 0, dy: CrosshairGeometry.step)
        case .return:
            // Reviewer-caught: `.onKeyPress` defaults to `[.down, .repeat]`
            // phases, and committing is NOT idempotent for Red-Eye
            // (add-or-remove) — holding Return past the key-repeat delay
            // would toggle the same point on/off at repeat rate, a real
            // parity coin-flip plus a burst of spurious `editState`
            // mutations (undo history + sidecar debounce). Only the
            // initial press commits; repeats are swallowed (still
            // `.handled`, not `.ignored`, so a held Return doesn't leak
            // through to whatever's behind this pane).
            guard keyPress.phase == .down else { return .handled }
            commitPointPlacement()
        case .escape:
            // This function is only ever reached while one of WB/Red-Eye/
            // Point-Color/Color-Range is armed (the dispatch guard in
            // `handleImagePaneKeyPress` below) — brush painting is never
            // among them, so a blanket `.none` can't disarm it by mistake.
            interactionMode = .none
        default:
            return .ignored
        }
        return .handled
    }

    /// Commits the keyboard crosshair's current position. For WB, the
    /// EXACT same call the mouse tap handler makes (see
    /// `pointAndZoomOverlays`), then disarms — matching that handler's
    /// own one-shot behavior. For Red-Eye, reuses `RedEyeHitTest.
    /// toggling` — the SAME pure add-or-remove decision `RedEyeOverlayView.
    /// toggle(at:)` itself calls, extracted during D8 specifically so this
    /// and that mouse path can't silently drift apart (reviewer-caught: an
    /// earlier version reimplemented the sequence here by hand, sharing
    /// only the threshold constant, not the actual logic).
    private func commitPointPlacement() {
        guard let fitRect = currentFitRect else { return }
        if isPickingWhiteBalance {
            document.pickWhiteBalance(normalizedX: crosshairPosition.x, normalizedY: crosshairPosition.y)
            interactionMode.disarm(.pickingWhiteBalance)
        } else if isPlacingRedEyeCorrections {
            document.editState.redEyePoints = RedEyeHitTest.toggling(
                crosshairPosition, in: document.editState.redEyePoints, fitRect: fitRect,
                threshold: RedEyeOverlayView.hitTestThreshold
            )
        } else if let id = pointColorPickingID {
            // One-shot, matching WB's own shape above (not Red-Eye's
            // stays-armed one) — Point Color's eyedropper picks exactly
            // one target per arm, mirroring the mouse tap handler in
            // `pointAndZoomOverlays`.
            document.pickPointColorTarget(pointColorID: id, normalizedX: crosshairPosition.x, normalizedY: crosshairPosition.y)
            interactionMode.disarm(.pickingPointColor(pointColorID: id))
        } else if let maskID = colorPickingMaskID {
            // D14 (IMPROVEMENTS.md): one-shot, matching Point Color's own
            // shape immediately above — the SAME call the mouse tap
            // handler in `pointAndZoomOverlays` makes.
            document.pickColorRangeTarget(maskID: maskID, normalizedX: crosshairPosition.x, normalizedY: crosshairPosition.y)
            interactionMode.disarm(.pickingColorRange(maskID: maskID))
        }
    }

    /// Arrow keys nudge `panOffset` by a fixed step (`0.05`, the same
    /// "fraction of `fitRect`" unit `PanOverlay`'s own drag delta already
    /// uses), through the SAME already-tested `ZoomPanGeometry.
    /// clampedPan` the mouse drag calls — no new pan math. `"0"` resets to
    /// identity, mirroring `PanOverlay`'s own double-tap-to-reset gesture
    /// exactly.
    ///
    /// Direction, confirmed deliberate (reviewer flagged for confirmation,
    /// not as a bug): pressing Right INCREASES `panOffset.width`, the same
    /// sign a rightward mouse DRAG already produces (`PanOverlay.swift`'s
    /// `dx`). That mirrors "drag the content" semantics, not the
    /// "arrow-keys-scroll-a-document" convention (where Right usually
    /// reveals content further right, the opposite sign) — chosen so
    /// keyboard panning feels like the SAME action as the mouse drag this
    /// app already has, rather than importing an external convention this
    /// app has no other precedent for.
    private func handlePanKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        if keyPress.key == "0" {
            zoomScale = ZoomPanGeometry.minZoom
            panOffset = .zero
            return .handled
        }
        let step: Double = 0.05
        let delta: CGSize
        switch keyPress.key {
        case .leftArrow: delta = CGSize(width: -step, height: 0)
        case .rightArrow: delta = CGSize(width: step, height: 0)
        case .upArrow: delta = CGSize(width: 0, height: -step)
        case .downArrow: delta = CGSize(width: 0, height: step)
        default: return .ignored
        }
        panOffset = ZoomPanGeometry.clampedPan(
            CGSize(width: panOffset.width + delta.width, height: panOffset.height + delta.height), zoom: zoomScale
        )
        return .handled
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
    /// Vertical/Horizontal perspective, Scale/Stretch, Flip, the crop
    /// rectangle, and the aspect lock. A real, implementable analog to the
    /// screenshot's
    /// "Reset" button. ("Auto" is deliberately not implemented — it would
    /// need actual auto-straighten/auto-crop detection, which doesn't
    /// exist in this app; skipped rather than faked.)
    private func resetCropTab() {
        document.editState.straightenAngle = 0
        document.editState.verticalPerspective = 0
        document.editState.horizontalPerspective = 0
        document.editState.transformScale = 1.0
        document.editState.transformAspect = 0
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
        // A SECOND split, same reasoning as `mainContent`'s own doc
        // comment below: adding the Paste Settings alert + confirmation
        // dialog pushed `contentWithExportAlerts.alert(...).
        // confirmationDialog(...)` past what the compiler could
        // type-check in reasonable time as ONE expression — splitting
        // `contentWithExportAlerts` out as its own opaque `some View` is
        // what fixed it (measured: reproduced the exact "unable to
        // type-check this expression" failure by inlining it back in,
        // confirmed the split resolves it).
        contentWithExportAlerts
            .alert(
                "Paste Settings",
                isPresented: Binding(
                    get: { pasteModel.statusMessage != nil },
                    set: { isPresented in
                        if !isPresented { pasteModel.statusMessage = nil }
                    }
                ),
                presenting: pasteModel.statusMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            // Irreversibility mitigation: only the currently-open photo
            // (if it's among the targets) gets an undo step, via
            // `ImageDocumentModel.pasteSettings(_:)`'s own `EditHistory`
            // commit — every OTHER target photo is overwritten on disk
            // directly, with no undo at all. This confirmation is v1's
            // only safeguard against a batch paste onto the wrong
            // selection.
            .confirmationDialog(
                pasteConfirmationTitle,
                isPresented: Binding(
                    get: { pasteModel.pendingTargets != nil },
                    set: { isPresented in
                        if !isPresented { pasteModel.pendingTargets = nil }
                    }
                ),
                presenting: pasteModel.pendingTargets
            ) { targets in
                Button("Paste Settings", role: .destructive) {
                    // Reviewer-caught (2 rounds on this exact race): the
                    // `isLoadInFlight` guard on REQUESTING a paste (the
                    // toolbar button/menu item's own `.disabled`) isn't
                    // enough alone — the confirmation dialog can stay open
                    // across a load that starts AFTER the request (⇧⌘V
                    // isn't Library-scoped, so a user can open it, then
                    // press ⌘→ to start opening a different photo, then
                    // confirm). Re-check here too, at the moment of the
                    // actual, mostly-irreversible write.
                    guard !document.isLoadInFlight, !renameModel.isWorking else {
                        pasteModel.statusMessage = "A photo is still loading or being renamed — try Paste Settings again in a moment."
                        return
                    }
                    // Captured ONCE, synchronously, in the same step as
                    // the guard above — `openPhotoPath` must name the
                    // photo this exact confirm is acting on.
                    let openPhotoPath = document.currentURL?.path
                    pasteModel.performPaste(
                        onto: targets,
                        openPhotoPath: openPhotoPath,
                        // Reviewer-caught, a THIRD round on this race: by
                        // the time this runs, no load was in flight (the
                        // guard above just confirmed it) — but
                        // `performPaste`'s OWN folder-access pre-flight
                        // can show `NSOpenPanel`, which pumps the AppKit
                        // modal run loop and CAN let a NEW load start
                        // during it (e.g. a Photo-menu shortcut firing
                        // while the panel is up), not merely let an
                        // already-in-flight one resume. `performPaste`
                        // checks this ONCE, right after its own pre-flight
                        // and before any write, aborting the whole batch
                        // if it fails rather than risk writing over a
                        // target that just became "the open photo" (or
                        // vice versa) mid-batch.
                        canProceed: {
                            !document.isLoadInFlight && !renameModel.isWorking
                                && document.currentURL?.path == openPhotoPath
                        },
                        applyToOpenPhoto: { source in
                            // Cheap backstop, not the primary guard (that's
                            // `canProceed` above) — re-verified once more
                            // at the point of actually applying the paste.
                            guard document.currentURL?.path == openPhotoPath else { return .skipped }
                            return document.pasteSettings(source)
                        },
                        onSidecarWritten: { catalog.invalidateThumbnail(for: $0) },
                        clearDeclinedFolder: { document.clearDeclinedFolder($0) }
                    )
                }
                Button("Cancel", role: .cancel) {}
            } message: { targets in
                Text(pasteConfirmationMessage(for: targets))
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

    private var contentWithExportAlerts: some View {
        // Split out of `body` (into `mainContent` below) so the type
        // checker only has to solve the alert chain against ONE already-
        // opaque `some View` type, not the whole `HSplitView` tree AND
        // every alert simultaneously — adding the `importStatusMessage`
        // alert pushed the previously-single expression past what the
        // compiler could type-check in reasonable time (measured: this
        // split is what fixed it).
        mainContent
            .modifier(KeywordSheetModifier(catalog: catalog, blocked: otherSheetIsPresented))
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
                // Reviewer-caught (Phase 7 slice 5, second half): this
                // alert is shared by `pickWhiteBalance`/`fixColorCast`
                // AND (as of this slice) `pickColorRangeTarget` — a
                // hardcoded "White Balance" title read as misleading for
                // the latter two callers. "Color Sample" covers all three.
                "Color Sample",
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
                // Was "Import Folder" — widened to a generic title once
                // this same `importStatusMessage`/alert pair started also
                // reporting relocate-photo summaries (D5 follow-up), not
                // just import summaries.
                "Photo Catalog",
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
                ExportOptionsView(
                    exportModel: exportModel, photoCount: photosToExport.count, previewPhoto: photosToExport.first
                ) {
                    guard !renameModel.isWorking else { return }
                    exportModel.runExport(photos: photosToExport)
                }
            }
            .alert(
                "Enhance",
                isPresented: Binding(
                    get: { enhanceModel.statusMessage != nil },
                    set: { isPresented in
                        if !isPresented { enhanceModel.statusMessage = nil }
                    }
                ),
                presenting: enhanceModel.statusMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            .sheet(isPresented: $renameModel.isPresentingSheet) {
                RenameSheetView(model: renameModel)
            }
            .alert(
                "Rename",
                isPresented: Binding(
                    get: { renameModel.statusMessage != nil },
                    set: { isPresented in
                        if !isPresented { renameModel.statusMessage = nil }
                    }
                ),
                presenting: renameModel.statusMessage
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message)
            }
            // The Photo menu can't see the selection or the Export/Enhance state, so it only sets
            // `request`; this view performs it with its own providers, then clears it.
            .onChange(of: renameModel.request) { _, request in
                guard let request else { return }
                renameModel.request = nil
                guard catalog.keywordSheetPhotoIDs == nil else { return }
                switch request {
                case .rename:
                    renameModel.begin(photos: selectedPhotosVisibleInGrid, catalog: catalog, providers: renameProviders)
                case .undo:
                    renameModel.undo(catalog: catalog, providers: renameProviders)
                }
            }
            // "Undo Rename" is only offered when a batch is logged; the catalog opens asynchronously,
            // so re-check as the library loads/changes.
            .task(id: catalog.photos.count) {
                await renameModel.refreshCanUndo(catalog: catalog)
            }
            .overlay(alignment: .bottom) {
                if let progress = exportModel.progress {
                    ExportProgressHUD(progress: progress)
                } else if enhanceModel.isEnhancing {
                    EnhancingHUD()
                }
            }
    }

    /// True while any other sheet/dialog a keyword sheet could collide with is up (or a long operation runs).
    private var otherSheetIsPresented: Bool {
        renameModel.isPresentingSheet || renameModel.isWorking || exportModel.isPresentingOptions
            || exportModel.isExporting || pasteModel.pendingTargets != nil
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
        //
        // Keyed on `currentURL`, not `currentFileName`: two photos in
        // different folders can share a filename, in which case a filename
        // key silently skips this whole reset. Reachable now that ⌘←/⌘→ can
        // step straight between them — the Name (A–Z) sort puts identical
        // filenames adjacent.
        .onChange(of: document.currentURL) { _, _ in
            selectedTab = .adjust
            selectedAspect = .freeform
            customAspectRatio = nil
            interactionMode = .none
            adjustPanel.selectedMaskID = nil
            adjustPanel.selectedPointColorID = nil
            adjustPanel.selectedRetouchSpotID = nil
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
                interactionMode = .none
                adjustPanel.selectedMaskID = nil
                adjustPanel.selectedPointColorID = nil
                adjustPanel.selectedRetouchSpotID = nil
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
        // D8 (IMPROVEMENTS.md): newly arming either point-placement mode
        // resets the keyboard crosshair to center AND grabs keyboard focus
        // for the image pane — so right after clicking "Pick White
        // Balance"/"Fix Red-Eye" in the sidebar, arrow keys work
        // immediately with no extra click needed. Deliberately fires on
        // the RISING edge only (`isArmed` true) — disarming doesn't need
        // to touch either, the crosshair simply stops being drawn.
        .onChange(of: isPickingWhiteBalance) { _, isArmed in
            if isArmed {
                crosshairPosition = CGPoint(x: 0.5, y: 0.5)
                isImagePaneFocused = true
            }
        }
        .onChange(of: isPlacingRedEyeCorrections) { _, isArmed in
            if isArmed {
                crosshairPosition = CGPoint(x: 0.5, y: 0.5)
                isImagePaneFocused = true
            }
        }
        // Phase 7 slice 2: mirrors the two `.onChange`s above — selecting a
        // mask (a non-nil RISING edge) grabs keyboard focus for the image
        // pane, so Escape (routed in `handleImagePaneKeyPress` below) works
        // immediately with no extra click needed. No crosshair to reset
        // here (masks have no point-placement crosshair).
        //
        // Phase 7 slice 5: narrowed to overlay-owning kinds only —
        // selecting a `.luminanceRange` mask (no overlay) has nothing on
        // the image pane to justify yanking focus away from whatever
        // sidebar slider the user is about to drag.
        .onChange(of: adjustPanel.selectedMaskID) { _, newID in
            guard let newID, let mask = document.editState.masks.first(where: { $0.id == newID }) else { return }
            if hasOnImageOverlay(mask.kind) {
                isImagePaneFocused = true
            }
        }
        // Phase 7 slice 4: rising edge grabs focus (same reasoning as the
        // `selectedMaskID` `.onChange` above); every other transition is
        // the ONE place every disarm route EXCEPT photo switch (Escape,
        // natural stroke end via `onStrokeEnded`, tab switch, Compare, WB,
        // Red-Eye, selecting another mask, collapsing the Masks section)
        // funnels through, so none of those sites individually needs to
        // remember `discardUnpaintedBrushMask` — F4's whole reason for
        // `UUID?` instead of `Bool`: this closure captures `oldID`, the
        // mask that was JUST disarmed, which a bare boolean couldn't name
        // once `adjustPanel.selectedMaskID` may already point elsewhere.
        // Photo switch is a REAL, documented gap, not covered here — see
        // `discardUnpaintedBrushMask`'s own doc comment and
        // IMPROVEMENTS.md's D13 for why.
        //
        // Reviewer-caught: `AdjustTabView.addMask(kind: .brush)` calls
        // `select(mask)` (which sets `interactionMode = .none`) and
        // then `beginBrushStroke(for:)` (which writes the NEW id) in one
        // synchronous action — SwiftUI coalesces both writes into a SINGLE
        // `.onChange` invocation with `old = <previous mask>, new = <new
        // mask>`, so the intermediate `nil` is never observed and an
        // `else` branch keyed on `newID == nil` never fires. "Add Brush"
        // while a different unpainted Brush mask was already armed used to
        // leak that earlier mask forever. Fixed by discarding whenever the
        // id CHANGES at all (a no-op when `oldID` is already `nil`), not
        // only on the falling edge to `nil`.
        .onChange(of: brushPaintingMaskID) { oldID, newID in
            if oldID != newID {
                discardUnpaintedBrushMask(oldID)
            }
            if newID != nil {
                isImagePaneFocused = true
            }
        }
        // Phase 7 slice 5 (second half): the `.colorRange` analogue of the
        // `brushPaintingMaskID` `.onChange` above — same `oldID != newID`
        // (not falling-edge-to-nil) form, the exact coalescing bug slice
        // 4's reviewer caught: `addMask -> select -> beginColorPick` is
        // one synchronous action SwiftUI collapses into a single
        // `.onChange` call that would never observe an intermediate `nil`.
        //
        // D14 (IMPROVEMENTS.md): now ALSO resets the keyboard crosshair +
        // grabs focus on the rising edge, matching `pointColorPickingID`'s
        // own `.onChange` below — added once this mode gained a keyboard
        // path; previously had nothing to reset for (mouse-only).
        .onChange(of: colorPickingMaskID) { oldID, newID in
            if oldID != newID {
                discardUnpickedColorRangeMask(oldID)
            }
            if newID != nil {
                crosshairPosition = CGPoint(x: 0.5, y: 0.5)
                isImagePaneFocused = true
            }
        }
        // Point Color Slice B: same `oldID != newID` shape as
        // `colorPickingMaskID`'s own `.onChange` above (the identical
        // add->select->pick coalescing hazard), PLUS the WB/Red-Eye
        // rising-edge crosshair reset + focus grab those two `.onChange`s
        // handle separately — combined here since both concerns key off
        // the same `pointColorPickingID` change. `colorPickingMaskID`'s
        // own `.onChange` above now does the identical rising-edge reset
        // (D14, IMPROVEMENTS.md) — kept as two separate `.onChange`
        // handlers rather than merged, since each already carries its own
        // discard-if-unpicked logic keyed on its own distinct id type.
        .onChange(of: pointColorPickingID) { oldID, newID in
            if oldID != newID {
                discardUnpickedPointColor(oldID)
            }
            if newID != nil {
                crosshairPosition = CGPoint(x: 0.5, y: 0.5)
                isImagePaneFocused = true
            }
        }
        // Point Color Slice B: the `isEditingMask` analogue — Undo/Revert/
        // Apply-Preset can delete the selected instance without passing
        // through `deletePointColor`, which would otherwise leave
        // `pointColorPickingID` pointing at an instance that no longer
        // exists.
        .onChange(of: isPointColorSelected) { _, stillSelected in
            if !stillSelected {
                interactionMode.disarmPointColorPick()
            }
        }
        // Closes the same hazard `isEditingMask`'s own doc comment already
        // names one level up: Undo, Revert to Original, and Apply Preset
        // can all delete the selected mask WITHOUT passing through any
        // disarm site above — more likely to matter here than for a quick
        // handle drag, since a brush stroke can run for several seconds.
        // Without this, `brushPaintingMaskID` would keep pointing at a
        // mask that no longer exists: `canZoom` stays wrongly blocked, and
        // `BrushMaskOverlayView`'s binding into the (now-vanished) mask's
        // `brushPoints` silently no-ops on every further drag callback.
        // `colorPickingMaskID` gets the identical treatment for the
        // identical reason.
        .onChange(of: isEditingMask) { _, stillEditing in
            if !stillEditing {
                interactionMode.disarmMaskModes()
            }
        }
        // Reviewer-caught: returning to the Editor from the Library while
        // a point-placement mode is STILL armed (it survives the round
        // trip — `showLibrary` merely toggles which pane is shown, it
        // doesn't reset either boolean) doesn't re-fire the two
        // `.onChange`s above, since neither boolean itself changes across
        // that transition — so the crosshair stayed invisible (gated on
        // `isImagePaneFocused`, which the Library grid's own focus claim
        // had taken) until the user clicked the image once. Re-focusing
        // here on every return-to-Editor closes that gap; harmless when
        // neither mode is armed (nothing reads `isImagePaneFocused` then).
        .onChange(of: showLibrary) { _, isShowingLibrary in
            if !isShowingLibrary,
               isPickingWhiteBalance || isPlacingRedEyeCorrections || isEditingOverlayMask
                || isPaintingBrush || isPickingColorRange || isPickingPointColor {
                isImagePaneFocused = true
            }
        }
        .toolbar {
            libraryToolbarItems
            editHistoryToolbarItems
            compareToolbarItem
            filmstripToolbarItem
            cropDoneToolbarItem
        }
        .navigationTitle(showLibrary ? "Library" : (document.currentFileName ?? "PhotoApp"))
    }

    /// Library-mode toggle + file-import + export/selection items, split
    /// out of `mainContent`'s `.toolbar { }` (alongside the other
    /// `*ToolbarItem`/`*ToolbarItems` properties below) purely to keep that
    /// closure's statement count low enough for the Swift type-checker —
    /// see `filmstripToolbarItem`'s doc comment for the full story; this
    /// split predates D1(b) reaching in but was needed once it did.
    /// Compacted from one `ToolbarItem` (and one Liquid-Glass capsule) per
    /// action to two `ToolbarItemGroup`s of icon-only controls — same
    /// actions/`.disabled` logic throughout, just fewer/smaller controls.
    /// Each `Label`'s text is kept (not `.labelStyle(.iconOnly)`) so it still
    /// supplies the AX `description`/tooltip macOS already derives for
    /// toolbar buttons; it just doesn't render alongside the icon.
    @ToolbarContentBuilder
    private var libraryToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button {
                showLibrary.toggle()
            } label: {
                Label(showLibrary ? "Editor" : "Library", systemImage: showLibrary ? "photo" : "square.grid.2x2")
            }
            Menu {
                Button("Open…") {
                    guard !renameModel.isWorking else { return }
                    Task { await document.openImage() }
                }
                .disabled(renameModel.isWorking)
                Button("Import Folder…") {
                    catalog.importFolder()
                }
                .disabled(catalog.isRenameInProgress)
                Button("Import Folder Tree…") {
                    catalog.importFolderTree()
                }
                .disabled(catalog.isRenameInProgress)
            } label: {
                Label("Add Photos", systemImage: "plus")
            }
        }
        if showLibrary {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    exportModel.beginExport()
                } label: {
                    Label(exportButtonTitle, systemImage: "square.and.arrow.up")
                }
                .disabled(photosToExport.isEmpty || exportModel.isExporting || renameModel.isWorking)
                .help(exportButtonTitle)

                // Deliberately the RAW `catalog.selectedPhotoIDs`, not
                // `selectedPhotosVisibleInGrid` (IMPROVEMENTS.md D33,
                // reviewer-caught): the menu's own "Clear Selection" button
                // is the ONLY call site of `catalog.clearSelection()`
                // anywhere in this app. Gating the whole menu on the
                // ghost-filtered set would hide that button too the moment
                // every selected id becomes a ghost, trapping the user with
                // a selection they can no longer reach any way to clear
                // (switching Collection/Folder still clears it via
                // `selectedFilter`'s own `didSet`, but that's not always
                // where the user wants to go). The label INSIDE the menu
                // already shows the correctly-filtered count (`"\
                // (selectedPhotosVisibleInGrid.count) Selected"` below) —
                // this outer gate only decides whether the menu ITSELF is
                // reachable at all, which must stay keyed on the raw set.
                if !catalog.selectedPhotoIDs.isEmpty {
                    Menu {
                        Menu("Add to Collection") {
                            ForEach(catalog.collections) { collection in
                                Button(collection.name) {
                                    catalog.addSelectedPhotos(to: collection)
                                }
                            }
                        }
                        .disabled(catalog.collections.isEmpty || selectedPhotosVisibleInGrid.isEmpty)

                        Button("Locate Selected…") {
                            Task { await catalog.relocateSelectedPhotos() }
                        }
                        .disabled(selectedPhotosVisibleInGrid.isEmpty || catalog.isRenameInProgress)

                        Button("Edit Keywords (\(selectedPhotosVisibleInGrid.count))…") {
                            catalog.keywordSheetRequested = true
                        }
                        .disabled(selectedPhotosVisibleInGrid.isEmpty || otherSheetIsPresented)

                        Button("Rename Files (\(selectedPhotosVisibleInGrid.count))…") {
                            renameModel.begin(photos: selectedPhotosVisibleInGrid, catalog: catalog, providers: renameProviders)
                        }
                        .disabled(
                            selectedPhotosVisibleInGrid.isEmpty || renameModel.isWorking || renameModel.isPresentingSheet
                                || document.isLoadInFlight
                        )

                        Button("Undo Rename") {
                            renameModel.undo(catalog: catalog, providers: renameProviders)
                        }
                        .disabled(!renameModel.canUndo || renameModel.isWorking || document.isLoadInFlight)

                        Button("Paste Settings (\(selectedPhotosVisibleInGrid.count))…") {
                            pasteModel.requestPaste(onto: selectedPhotosVisibleInGrid)
                        }
                        // `document.isLoadInFlight`, reviewer-caught: a photo
                        // load is async and `document.currentURL` still names
                        // the OUTGOING photo for its whole duration — a paste
                        // confirmed during that window could target the
                        // INCOMING photo without recognizing it as "the open
                        // photo," write its sidecar directly, and then have
                        // the load's own completion silently overwrite that
                        // with pre-paste data. Disabling REQUESTING a paste
                        // during the window narrows it — it is NOT the full
                        // guard by itself (a load can still start AFTER a
                        // request, while the confirmation dialog is open); see
                        // `PasteSettingsModel.performPaste`'s own doc comment
                        // for the complete, multi-layered story.
                        .disabled(
                            pasteModel.copied == nil || selectedPhotosVisibleInGrid.isEmpty
                                || document.isLoadInFlight || renameModel.isWorking
                        )

                        Divider()

                        Button("Clear Selection") {
                            catalog.clearSelection()
                        }
                    } label: {
                        Label("\(selectedPhotosVisibleInGrid.count) Selected", systemImage: "checkmark.circle")
                    }
                }
            }
        }
    }

    /// Shared between the Export button's `Label` and its `.help` tooltip —
    /// same text the old text-only button showed, just no longer the only
    /// place that text is used.
    private var exportButtonTitle: String {
        // The "is anything selected AT ALL" check is the RAW
        // `catalog.selectedPhotoIDs`, deliberately matching `photosToExport`'s
        // own guard (line ~41) exactly — the title and the `.disabled` state
        // right above must agree on when to show the "Selected" form at all,
        // or a disabled button can end up reading the same as an enabled
        // "export everything" one (reviewer-caught: an all-ghost selection
        // with this check on the FILTERED set instead showed plain "Export…"
        // — indistinguishable from the truly-nothing-selected case — while
        // still disabled, with no visible reason why).
        //
        // The COUNT shown once something's selected, `selectedPhotosVisibleInGrid`
        // (IMPROVEMENTS.md D33): ghost ids (a photo toggled out of the
        // currently-viewed collection, still selected — see
        // `CatalogModel.selectedPhotos`'s own doc comment) must not inflate
        // this number past what `photosToExport` actually exports — that
        // part of the original fix stands, including the honest "(0)" an
        // all-ghost selection now shows instead of a silently wrong count.
        guard !catalog.selectedPhotoIDs.isEmpty else { return "Export…" }
        return "Export Selected (\(selectedPhotosVisibleInGrid.count))…"
    }

    /// Grouped into two `ToolbarItemGroup`s (history vs. document actions)
    /// instead of five separate `ToolbarItem`s — same actions/`.disabled`
    /// logic, just fewer Liquid-Glass capsules on macOS 26+.
    @ToolbarContentBuilder
    private var editHistoryToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
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

            Button {
                document.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!document.canRedo)

            Button {
                document.revertToOriginal()
            } label: {
                Label("Revert to Original", systemImage: "arrow.counterclockwise")
            }
            // `isEffectivelyIdentity`, not `== .identity` — a RAW photo's
            // `rawDecoderVersionPin` is invisible bookkeeping set on
            // every open, not a user edit; a bare `== .identity` check
            // would leave this button permanently enabled for every RAW
            // photo, including never-touched ones (Phase 6 slice 7
            // review round 2). See `EditState.isEffectivelyIdentity`'s
            // own doc comment.
            .disabled(document.currentImage == nil || document.editState.isEffectivelyIdentity)
        }
        ToolbarItemGroup(placement: .automatic) {
            Button {
                pasteModel.copy(document.editState, fileName: document.currentFileName ?? "photo")
            } label: {
                Label("Copy Settings", systemImage: "doc.on.doc")
            }
            // Same condition as "Revert to Original" just above, and
            // deliberately NOT gated on `!showLibrary` — this whole
            // toolbar group already renders (disabled as appropriate) in
            // BOTH the Library and Editor panes; a new gate here would be
            // an inconsistency, not a safety improvement.
            .disabled(document.currentImage == nil)

            Button {
                // Snapshotted synchronously, same pattern as "Copy
                // Settings" just above — `enhanceModel.enhance` reads
                // exactly what's on screen right now, including an edit
                // still inside its debounce window.
                guard !renameModel.isWorking else { return }
                enhanceModel.enhance(sourceURL: document.currentURL, editState: document.editState, catalog: catalog)
            } label: {
                Label("Enhance", systemImage: "square.resize.up")
            }
            // `wand.and.stars` is already Auto Tone's icon (Light section,
            // AdjustTabView) — `square.resize.up` avoids the collision.
            // `isLoadInFlight`/`isEnhancing` both gate this: a photo
            // switch or an enhance already in progress must not let a
            // second click start a second one on top of it.
            .disabled(
                document.currentImage == nil || document.isLoadInFlight || enhanceModel.isEnhancing
                    || renameModel.isWorking
            )
        }
    }

    @ToolbarContentBuilder
    private var compareToolbarItem: some ToolbarContent {
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
                    || isPickingWhiteBalance || isPlacingRedEyeCorrections || isPickingColorRange
                    || isPickingPointColor
            )
            .tint(compareMode != .off ? .yellow : nil)
            .accessibilityAddTraits(compareMode != .off ? [.isSelected] : [])
            .onChange(of: compareMode) { _, newMode in
                if newMode != .off {
                    // Clears every armed mode in one assignment now —
                    // the `.disabled` above blocks entering Compare from
                    // the MENU while armed, but `compareMode` is also a
                    // plain `@State` this `.onChange` observes regardless
                    // of how it changed (reviewer-caught: this branch was
                    // once missing entirely, so nothing actually stopped
                    // Point Color's eyedropper from staying armed over a
                    // Side-by-Side/Split viewport whose `currentFitRect`
                    // assumption no longer holds).
                    interactionMode = .none
                    // Deliberately does NOT disable the Compare menu itself
                    // above (masks stay APPLIED — Compare is the best way
                    // to see what a mask did) — this only clears the
                    // overlay/detail-panel SELECTION, matching the armed-mode
                    // clear right above.
                    adjustPanel.selectedMaskID = nil
                    adjustPanel.selectedPointColorID = nil
                    adjustPanel.selectedRetouchSpotID = nil // its circles are positioned against the single-image fit rect
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var cropDoneToolbarItem: some ToolbarContent {
        if selectedTab == .crop {
            ToolbarItem(placement: .automatic) {
                Button("Done") { selectedTab = .adjust }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
            }
        }
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
                // Switch to the Editor pane BEFORE the (possibly async, for
                // RAW) load completes, not after — so a RAW photo's loading
                // indicator (`document.isLoadingImage`) is actually visible
                // instead of the user staring at an unchanged Library grid
                // during the gap.
                // Never load a photo while a rename/undo is moving files (it could read "no sidecar"
                // in the temp window and then save edits to a path that is about to vanish).
                guard !renameModel.isWorking else { return }
                showLibrary = false
                Task {
                    await catalog.ensureAccessActive(forPhotoAt: photo.path)
                    await document.load(from: URL(fileURLWithPath: photo.path))
                }
            }
        }
    }

    /// The single-photo editor — unchanged from before the Library grid
    /// was added, just extracted out of `mainContent` so `mainContent` can
    /// switch between this and `LibraryGridView`.
    /// IMPROVEMENTS.md D1(b)'s filmstrip toggle, extracted out of the main
    /// `.toolbar { }` closure into its own `@ToolbarContentBuilder` property
    /// — inlining it there pushed that closure's item count past the point
    /// where the Swift type-checker could resolve it in reasonable time
    /// (a real build failure, not a style preference); splitting complex
    /// `ToolbarContent`/`ViewBuilder` closures into named sub-properties is
    /// the standard fix.
    @ToolbarContentBuilder
    private var filmstripToolbarItem: some ToolbarContent {
        if !showLibrary {
            ToolbarItem(placement: .automatic) {
                Button {
                    isFilmstripVisible.toggle()
                } label: {
                    Label("Filmstrip", systemImage: "square.grid.3x1")
                }
                .tint(isFilmstripVisible ? .yellow : nil)
                .accessibilityAddTraits(isFilmstripVisible ? [.isSelected] : [])
            }
        }
    }

    private var editorContent: some View {
        VStack(spacing: 0) {
            editorSplitView
            if isFilmstripVisible {
                EditorFilmstripView(catalog: catalog, currentURL: document.currentURL) { photo in
                    guard !renameModel.isWorking else { return }
                    Task {
                        await catalog.ensureAccessActive(forPhotoAt: photo.path)
                        await document.load(from: URL(fileURLWithPath: photo.path))
                    }
                }
            }
        }
    }

    /// The Editor's image pane + control sidebar — unchanged from before
    /// D1(b) added the filmstrip below it, just extracted so `editorContent`
    /// can wrap it in a `VStack` alongside `EditorFilmstripView`.
    private var editorSplitView: some View {
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
                        // Covers the async gap while a RAW photo's one-time
                        // `RawDecoder.materialize` is in flight (see
                        // `ImageDocumentModel.isLoadingImage`'s doc comment)
                        // — without this, that gap reads as a second freeze
                        // rather than as "working."
                        if document.isLoadingImage {
                            ProgressView("Decoding RAW photo…")
                                .padding(24)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        // D8 (IMPROVEMENTS.md): extracted out of this
                        // `ZStack` (Crop/WB/Red-Eye/CompareDivider/Pan×1-2,
                        // now plus the keyboard crosshair) specifically to
                        // keep the `ZStack`'s OWN literal small — this file
                        // has hit real Swift type-checker failures from
                        // exactly this shape before (see `mainContent`'s
                        // and `filmstripToolbarItem`'s own doc comments);
                        // "extract into a named sub-property" is the
                        // established fix here, applied proactively rather
                        // than after a 7th branch actually broke the build.
                        pointAndZoomOverlays
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .onAppear { containerSize = proxy.size }
                    .onChange(of: proxy.size) { _, newSize in containerSize = newSize }
                    .overlay(alignment: .bottomTrailing) {
                        if zoomScale > 1 {
                            ZoomPercentageHUD(zoomScale: zoomScale)
                        }
                    }
                    // D8 (IMPROVEMENTS.md): the Editor's first
                    // `.focusable()`/`.onKeyPress` — see
                    // `isImagePaneFocused`'s own doc comment for why this,
                    // not `MetalImageView`'s `NSEvent` scroll monitor, is
                    // the right tool. `.simultaneousGesture` (not `.gesture`
                    // or `.onTapGesture`) so a click anywhere in the pane
                    // reclaims focus WITHOUT intercepting the
                    // `SpatialTapGesture`/`DragGesture` already attached to
                    // whichever overlay is conditionally present inside
                    // `pointAndZoomOverlays` — mirrors D4's own
                    // click-reclaims-grid-focus fix, but this is the first
                    // time that composition is tried against SPATIAL
                    // gestures rather than `Button` taps; live-verify this
                    // specifically, not just review it.
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isImagePaneFocused)
                    .onKeyPress { keyPress in handleImagePaneKeyPress(keyPress) }
                    .simultaneousGesture(TapGesture().onEnded { isImagePaneFocused = true })
                    // Reviewer-caught: a focusable view with no
                    // accessibility label announces nothing when tabbed/
                    // VoiceOver-navigated to — a bare "image" is still
                    // better than silence, and names the one state
                    // (armed point-placement) where this pane's keyboard
                    // behavior actually changes. `children: .contain` (not
                    // the default, which would let this label override
                    // whatever a descendant already announces) —
                    // reviewer-caught: `CompareDividerOverlay` builds its
                    // OWN named, adjustable accessibility element inside
                    // this same subtree; without `.contain`, that would
                    // get shadowed into announcing "Image" instead of
                    // "Compare divider".
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(
                        isPickingWhiteBalance ? "White balance picker"
                            : isPlacingRedEyeCorrections ? "Red-eye placement"
                            : isPaintingBrush ? "Brush painting"
                            : isPickingColorRange ? "Color range picker"
                            : isPickingPointColor ? "Point color picker"
                            // Phase 7 slice 5: narrowed to overlay-owning
                            // kinds — with no overlay, nothing about the
                            // PANE itself changed, so announcing "Mask
                            // editing" here would be inaccurate.
                            : isEditingOverlayMask ? "Mask editing" : "Image"
                    )
                }
            }
            .frame(minWidth: 480, minHeight: 360)
            .layoutPriority(1)

            editControls
                // `minWidth` bumped 260 -> 360, not `idealWidth` — user-
                // caught via two side-by-side fresh-launch screenshots
                // (identical collapsed sidebar width whether or not a
                // photo was loaded) that bumping `idealWidth` alone
                // (300 -> 340 -> 360, two prior attempts) had NO visible
                // effect on `HSplitView`'s actual cold-start pane width.
                // `HSplitView` on macOS is backed by real `NSSplitView`/
                // `NSSplitViewController` machinery whose initial-layout
                // algorithm does not appear to honor a nested `.frame`'s
                // `idealWidth` hint the way `HStack`/`VStack` would —
                // `minWidth` is a genuine hard floor instead, so it's the
                // only lever that reliably determines the cold-start
                // width. 360 was the value the user separately confirmed
                // (by manually dragging the divider) doesn't clip Color
                // Grading's caption/labels; `maxWidth` bumped 380 -> 420
                // to keep some manual resize headroom above the new floor.
                .frame(minWidth: 360, maxWidth: 420)
        }
    }

    /// Extracted out of `editorSplitView`'s `ZStack` — see that call
    /// site's own doc comment for why (this file's recurring Swift
    /// type-checker ceiling). Behavior-preserving for the five overlays
    /// that lived directly in the `ZStack` before D8 (Crop/WB/Red-Eye/
    /// CompareDivider/Pan×1-2); the keyboard crosshair (D8, IMPROVEMENTS.md)
    /// is the only genuinely new branch.
    @ViewBuilder
    private var pointAndZoomOverlays: some View {
        // Fit against the ACTUAL displayed extent (post-straighten/
        // perspective, crop-zeroed), not the raw `image.extent`. Every
        // feature before Straighten preserved extent exactly, so those
        // were equal by coincidence; Straighten grows the extent
        // (measured +padding from resampling), so this distinction is
        // load-bearing — using the raw extent here would misalign the
        // overlay against a straightened photo. (Perspective correction,
        // added later, was verified to preserve extent exactly since its
        // corners only move inward — it doesn't newly exercise this path,
        // but this computation still correctly reflects whatever extent
        // the pipeline actually produces.) Building the filter graph to
        // read `.extent` is cheap (Core Image doesn't render pixels for
        // it). `currentFitRect` is shared with the aspect-picker action in
        // the sidebar (outside the `GeometryReader`'s own scope), via
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
        // WB eyedropper tap-capture. Gated on `!isCroppingActive` (on top
        // of `isPickingWhiteBalance` itself only ever being armable from
        // the Adjust tab — see the `.onChange(of: selectedTab)` below) so
        // this and `CropOverlayView`'s own drag gestures above can never
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
                        let normalizedX = tap.location.x / fitRect.width
                        let normalizedY = tap.location.y / fitRect.height
                        document.pickWhiteBalance(normalizedX: normalizedX, normalizedY: normalizedY)
                        // D8 (IMPROVEMENTS.md): keeps the keyboard
                        // crosshair in sync with the mouse — see
                        // `crosshairPosition`'s own doc comment. Harmless
                        // that this mode disarms right below (the NEXT
                        // arm resets to center anyway); kept for symmetry
                        // with Red-Eye's own sync, which genuinely needs
                        // it since that mode does NOT auto-disarm.
                        crosshairPosition = CGPoint(x: normalizedX, y: normalizedY)
                        interactionMode.disarm(.pickingWhiteBalance)
                    }
                )
                // D6 (IMPROVEMENTS.md): a spatial tap-anywhere-on-the-image
                // gesture has no non-mouse equivalent — but UNLIKE when
                // this comment was written, one now exists (D8's keyboard
                // crosshair, `handleImagePaneKeyPress` below); left hidden
                // anyway since this specific `Color.clear` capture surface
                // itself is still mouse-only and still vends no meaningful
                // accessibility content of its own.
                .accessibilityHidden(true)
        }
        // Red-Eye correction markers/tap-capture. Gated on
        // `!isCroppingActive` and `!isPickingWhiteBalance` (on top of
        // `isPlacingRedEyeCorrections` itself only ever being armable from
        // the Adjust tab) so only one of the three point-interaction modes
        // can ever be live at once. UNLIKE the WB eyedropper, a tap does
        // NOT disarm this mode — see `isPlacingRedEyeCorrections`'s own
        // doc comment.
        if isPlacingRedEyeCorrections, !isCroppingActive, !isPickingWhiteBalance,
           let fitRect = currentFitRect {
            RedEyeOverlayView(
                fitRect: fitRect, points: $document.editState.redEyePoints,
                // D8 (IMPROVEMENTS.md): see `crosshairPosition`'s own doc
                // comment — this mode does NOT auto-disarm on tap, so
                // staying in sync genuinely matters (switching to arrow
                // keys after a mouse-placed point should continue from
                // there, not snap back to center).
                onTap: { crosshairPosition = $0 }
            )
        }
        // Phase 7 slice 2: the selected mask's resize/move handles. Gated
        // on ALL THREE earlier modes, on top of `isEditingMask` itself only
        // ever being armable from the Masks section — same cumulative-
        // exclusion discipline as the Red-Eye branch above (each new mode
        // re-checks every earlier one; earlier modes never gain a
        // predicate about this one — mutual exclusion is enforced by
        // disarming at the ARM site instead, see `AdjustTabView.select`/
        // the WB/Red-Eye buttons). A capture layer, so it's placed BEFORE
        // the keyboard crosshair below — that overlay must always draw on
        // top of whichever capture layer is active.
        //
        // Phase 7 slice 3 Session B: kind-switched — `.radial` gets
        // `MaskOverlayView` (slice 2), `.linear` gets
        // `LinearMaskOverlayView` (this session), under the SAME shared
        // guards either way. `isEditingMask`/`canZoom`/`handleMaskKeyPress`/
        // every `.onChange` disarm site are all kind-agnostic (verified by
        // reading each one, not assumed) — both kinds now behave
        // identically for zoom-blocking, focus-grab, and Escape, since
        // both have their own `currentFitRect`-positioned overlay.
        //
        // Phase 7 slice 5: gate narrowed to `isEditingOverlayMask` — a
        // selected `.luminanceRange` mask has no overlay to draw here at
        // all (see the required, but practically unreachable given this
        // gate, `case .luminanceRange` arm below — a compile-time
        // tripwire, not dead code the gate makes pointless: the switch
        // itself must stay exhaustive so a FUTURE overlay-less kind can't
        // silently fall through some OTHER, less careful gate).
        if isEditingOverlayMask, !isCroppingActive, !isPickingWhiteBalance, !isPlacingRedEyeCorrections,
           let id = adjustPanel.selectedMaskID,
           let maskBinding = $document.editState.mask(id: id),
           let fitRect = currentFitRect {
            switch maskBinding.wrappedValue.kind {
            case .radial:
                MaskOverlayView(
                    fitRect: fitRect,
                    centerX: maskBinding.centerX, centerY: maskBinding.centerY,
                    radiusX: maskBinding.radiusX, radiusY: maskBinding.radiusY,
                    rotationDegrees: maskBinding.wrappedValue.rotationDegrees,
                    feather: maskBinding.wrappedValue.feather
                )
            case .linear:
                LinearMaskOverlayView(
                    fitRect: fitRect,
                    centerX: maskBinding.centerX, centerY: maskBinding.centerY,
                    width: maskBinding.width,
                    rotationDegrees: maskBinding.wrappedValue.rotationDegrees
                )
            case .brush:
                // Phase 7 slice 4: unlike the two branches above, this
                // overlay ALSO gates on `brushPaintingMaskID == id` — a
                // placed Brush stroke has NO persistent editing overlay
                // (no handles once painting ends, see `Mask.brushPoints`'s
                // own doc comment), so there's nothing to draw here for a
                // merely-selected-but-not-currently-painting Brush mask.
                if brushPaintingMaskID == id {
                    BrushMaskOverlayView(
                        fitRect: fitRect,
                        points: maskBinding.brushPoints,
                        brushSize: maskBinding.wrappedValue.brushSize,
                        onStrokeEnded: { interactionMode.disarm(.paintingBrush(maskID: id)) }
                    )
                }
            case .luminanceRange, .colorRange, .subject:
                // Phase 7 slice 5: no on-image overlay for either kind —
                // see `isEditingOverlayMask`'s own doc comment. This branch
                // is unreachable in practice (the surrounding `if` already
                // gates on `isEditingOverlayMask`, which is false for both
                // kinds), but the switch must stay exhaustive regardless —
                // the same compile-time tripwire `maskKindIcon`/
                // `maskKindLabel` already rely on to catch a FUTURE kind
                // silently falling through.
                EmptyView()
            }
        }
        // Spot removal: the selected spot's on-image circles (spot + dashed source), identity geometry only. Gated
        // against every armed point-interaction mode like the mask overlay above.
        if isEditingRetouchSpot, !isPickingWhiteBalance, !isPlacingRedEyeCorrections, !isPickingColorRange,
           !isPickingPointColor, !isPaintingBrush,
           let id = adjustPanel.selectedRetouchSpotID,
           let spotBinding = $document.editState.retouchSpot(id: id),
           let fitRect = currentFitRect {
            RetouchOverlayView(fitRect: fitRect, spot: spotBinding)
        }
        // Phase 7 slice 5 (second half): the Color Range eyedropper's
        // tap-capture layer — mirrors the WB eyedropper's own capture
        // layer above almost exactly (same `Color.clear`/crosshair-cursor/
        // `SpatialTapGesture` shape), gated on the same cumulative-
        // exclusion discipline every later mode in this function already
        // follows. One structural difference from WB: this resolves the
        // target mask by IDENTITY at commit time (mirrors `MaskBinding`'s
        // own discipline — Undo/Revert/Apply-Preset could delete the mask
        // mid-pick) and writes into that SPECIFIC mask via
        // `document.pickColorRangeTarget(maskID:normalizedX:normalizedY:)`,
        // rather than a shared global field. D14 (IMPROVEMENTS.md): now
        // ALSO syncs `crosshairPosition` on a mouse tap, matching Point
        // Color's own tap handler below — the direct analogue of the real
        // D4 bug (a keypress after a mouse click silently acting on a
        // stale position) now that this mode has a keyboard path too.
        if isPickingColorRange, !isCroppingActive, !isPickingWhiteBalance, !isPlacingRedEyeCorrections,
           !isPaintingBrush, let maskID = colorPickingMaskID, let fitRect = currentFitRect {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: fitRect.width, height: fitRect.height)
                .position(x: fitRect.midX, y: fitRect.midY)
                .onHover { inside in
                    if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                }
                .gesture(
                    SpatialTapGesture(coordinateSpace: .local).onEnded { tap in
                        let normalizedX = tap.location.x / fitRect.width
                        let normalizedY = tap.location.y / fitRect.height
                        document.pickColorRangeTarget(maskID: maskID, normalizedX: normalizedX, normalizedY: normalizedY)
                        crosshairPosition = CGPoint(x: normalizedX, y: normalizedY)
                        interactionMode.disarm(.pickingColorRange(maskID: maskID))
                    }
                )
                .accessibilityHidden(true)
        }
        // Point Color Slice B: this eyedropper's tap-capture layer —
        // mirrors the WB eyedropper's own capture layer above almost
        // exactly (same `Color.clear`/crosshair-cursor/`SpatialTapGesture`
        // shape, same one-shot auto-disarm, same keyboard-crosshair sync).
        // The Color Range eyedropper's own tap-capture layer above now has
        // this exact same keyboard-crosshair sync too (D14, IMPROVEMENTS.md
        // — closed for that kind the same way, rather than leaving a third
        // instance of the gap open). Resolves the target instance by
        // IDENTITY at commit time (mirrors `PointColorBinding`'s own
        // discipline — Undo/Revert/Apply-Preset could delete the instance
        // mid-pick),
        // same as the Color Range branch above.
        if isPickingPointColor, !isCroppingActive, !isPickingWhiteBalance, !isPlacingRedEyeCorrections,
           !isPaintingBrush, !isPickingColorRange, let id = pointColorPickingID, let fitRect = currentFitRect {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: fitRect.width, height: fitRect.height)
                .position(x: fitRect.midX, y: fitRect.midY)
                .onHover { inside in
                    if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                }
                .gesture(
                    SpatialTapGesture(coordinateSpace: .local).onEnded { tap in
                        let normalizedX = tap.location.x / fitRect.width
                        let normalizedY = tap.location.y / fitRect.height
                        document.pickPointColorTarget(pointColorID: id, normalizedX: normalizedX, normalizedY: normalizedY)
                        crosshairPosition = CGPoint(x: normalizedX, y: normalizedY)
                        interactionMode.disarm(.pickingPointColor(pointColorID: id))
                    }
                )
                .accessibilityHidden(true)
        }
        // D8 (IMPROVEMENTS.md): the keyboard-driven crosshair itself —
        // only while a point-placement mode is armed AND the pane holds
        // keyboard focus (so it doesn't linger on screen after focus
        // moves to a sidebar control). Rendered ABOVE all four tap-capture
        // layers above (WB/Red-Eye/Point-Color/Color-Range, later in the
        // `ZStack` = on top), same z-ordering `RedEyeOverlayView`'s own
        // persistent markers use.
        if isImagePaneFocused, let fitRect = currentFitRect {
            if isPickingWhiteBalance, !isCroppingActive {
                EditorCrosshairOverlay(fitRect: fitRect, normalizedPosition: crosshairPosition, tint: .white)
            } else if isPlacingRedEyeCorrections, !isCroppingActive {
                EditorCrosshairOverlay(fitRect: fitRect, normalizedPosition: crosshairPosition, tint: .yellow)
            } else if isPickingPointColor, !isCroppingActive {
                EditorCrosshairOverlay(fitRect: fitRect, normalizedPosition: crosshairPosition, tint: .cyan)
            } else if isPickingColorRange, !isCroppingActive {
                // D14 (IMPROVEMENTS.md): a distinct tint from every other
                // picker (white/yellow/cyan already taken) so it's visually
                // unambiguous which mode is armed.
                EditorCrosshairOverlay(fitRect: fitRect, normalizedPosition: crosshairPosition, tint: .green)
            }
        }
        // Compare Split's draggable divider. `compareMode` can only be
        // non-`.off` with no WB-eyedropper/Red-Eye-placement mode armed —
        // belt-and-braces enforced BOTH by the toolbar Menu's own
        // `.disabled(...)` (gates on `isPickingWhiteBalance`/
        // `isPlacingRedEyeCorrections`) AND by arming either one calling
        // `onEnterPointPickingMode()`, which sets `compareMode = .off`.
        // A selected MASK is a separate case — the Menu's `.disabled(...)`
        // does NOT gate on `isEditingMask` at all: Compare is
        // intentionally left enabled with a mask selected (see
        // IMPROVEMENTS.md's D10 note and slice 2 Session B's own
        // write-up — "the best way to see what a mask did"), so
        // `isEditingMask && compareMode == .split` is reachable in
        // principle. For an OVERLAY-OWNING mask kind (`.radial`/`.linear`/
        // `.brush`) it doesn't overlap in practice because the OTHER
        // direction is covered instead: selecting one
        // (`AdjustTabView.select(_:)`) calls `onEnterPointPickingMode()`,
        // forcing `compareMode = .off`, and `compareToolbarItem`'s own
        // `.onChange(of: compareMode)` clears `selectedMaskID` the moment
        // `compareMode` becomes non-`.off` again — so the two states stay
        // mutually exclusive by construction, not because either
        // overlay's real estate is walled off from the other.
        //
        // Phase 7 slice 5 changed this to be genuinely ONE-DIRECTIONAL for
        // `.luminanceRange` (no overlay): `select(_:)` no longer calls
        // `onEnterPointPickingMode()` for this kind (see that function's
        // own doc comment), so selecting a `.luminanceRange` mask no
        // longer forces Compare off — `isEditingMask && compareMode ==
        // .split` is now a REAL, reachable combination for this kind, not
        // just a theoretical one. This is deliberate and safe: no overlay
        // is drawn for this kind (see `isEditingOverlayMask`), so nothing
        // competes with `CompareDividerOverlay` below for the same screen
        // real estate. `compareToolbarItem`'s own `.onChange(of:
        // compareMode)` still unconditionally clears `selectedMaskID` the
        // other way (engaging Compare still deselects ANY mask, including
        // this kind) — making that kind-aware too, so a `.luminanceRange`
        // mask could stay selected THROUGH engaging Compare, would be a
        // real further improvement, deliberately deferred (logged in
        // PROGRESS.md, not fixed this slice).
        if compareMode == .split, let fitRect = currentFitRect {
            CompareDividerOverlay(fitRect: fitRect, orientation: splitOrientation, position: $splitPosition)
        }
        // Click-drag-to-pan, once zoomed past fit. Not shown in Split —
        // the divider above already owns click-drag there; scroll-to-zoom
        // still works in Split (the `NSEvent` monitor doesn't depend on
        // this overlay), you just can't ALSO drag to reposition without
        // changing zoom. In Side by Side, TWO overlays (one per half, both
        // bound to the same `$zoomScale`/`$panOffset`) so dragging either
        // photo pans both in sync. D8's keyboard pan (`handleImagePaneKeyPress`
        // below) reuses this SAME `canZoom && zoomScale > 1 && compareMode
        // != .split` gate, so it never offers more than the mouse already
        // does.
        if canZoom, zoomScale > 1 {
            if compareMode == .sideBySide, let (leftRect, rightRect) = sideBySideFitRects {
                PanOverlay(fitRect: leftRect, zoomScale: $zoomScale, panOffset: $panOffset)
                PanOverlay(fitRect: rightRect, zoomScale: $zoomScale, panOffset: $panOffset)
            } else if compareMode != .split, let fitRect = currentFitRect {
                PanOverlay(fitRect: fitRect, zoomScale: $zoomScale, panOffset: $panOffset)
            }
        }
    }

    private var editControls: some View {
        ScrollView {
            Group {
                switch selectedTab {
                case .adjust:
                    AdjustTabView(
                        document: document,
                        catalog: catalog,
                        panel: $adjustPanel,
                        interactionMode: $interactionMode,
                        onEnterPointPickingMode: {
                            compareMode = .off
                            zoomScale = 1
                            panOffset = .zero
                            // Reviewer-caught: WB/Red-Eye arming is a bool
                            // TOGGLE, so `.onChange(of: isPickingWhiteBalance/
                            // isPlacingRedEyeCorrections)` always fires on a
                            // true rising edge and grabs focus there. Mask
                            // selection is by ID, not a toggle — clicking an
                            // ALREADY-selected mask's row calls `select(_:)`
                            // (which calls this closure) without changing
                            // `selectedMaskID`, so the corresponding
                            // `.onChange(of: adjustPanel.selectedMaskID)`
                            // would silently NOT fire, leaving Escape
                            // unreachable if focus had since moved to a
                            // sidebar slider. Grabbing focus here too closes
                            // that gap unconditionally — redundant but
                            // harmless for WB/Red-Eye's own already-working case.
                            isImagePaneFocused = true
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
        // User asked for a thinner sidebar scrollbar (this ScrollView wraps
        // ALL sidebar tabs — Adjust/Crop/Filters/Clean Up — not just
        // Adjust). Deliberately hidden entirely rather than shrunk — pure
        // SwiftUI, zero AppKit interop. This exact `ScrollView` has a
        // documented, hard-won history: a prior fix reaching into
        // `NSScrollView`/`NSScroller` internals to solve a DIFFERENT bug
        // (sidebar content-shift-on-scroll) went through two reviewer
        // passes (FIX FIRST, then APPROVE) and passed all tests, then broke
        // ALL slider click/drag interaction live and had to be reverted
        // (see "Sidebar content-shift-on-scroll bug" in PROGRESS.md).
        // Reviewer-confirmed: `.scrollIndicators` is a pure visibility
        // toggle with no gesture/hit-testing side effects, so it can't
        // reproduce that regression. Note: hiding indicators was ALSO one
        // of five things already tried against the content-shift bug
        // itself (PROGRESS.md) and did NOT fix it — that bug is unrelated
        // and remains open; this change is purely cosmetic. Scrolling
        // itself (trackpad/mouse wheel/keyboard) is unaffected — only the
        // visible track/thumb (and the ability to drag it directly) is
        // gone.
        .scrollIndicators(.hidden)
        .disabled(document.currentImage == nil)
        .background(Color(white: 0.11))
    }

}

#Preview {
    ContentView(
        document: ImageDocumentModel(), catalog: CatalogModel(), pasteModel: PasteSettingsModel(),
        renameModel: RenameModel(), showLibrary: .constant(false)
    )
}
