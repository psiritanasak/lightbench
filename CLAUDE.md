# Photo Editor (Lightroom-style) — Project Memory

## What this project is
A native macOS photo editor with a library/catalog, in the spirit of Lightroom.
Non-destructive editing is the core invariant: **original files are never modified**.
Edits are stored as parameter sets and rendered live on the GPU.

## Stack
- Swift + SwiftUI (AppKit interop where needed)
- Metal / Core Image for the GPU edit pipeline (custom kernels for curves, HSL, WB)
- SQLite via GRDB for the catalog (photos, edits, collections, ratings)
- LibRaw via C++ interop for RAW decoding (Phase 6 — do not start early)
- Xcode project is generated from `project.yml` via XcodeGen (`brew install xcodegen`,
  then `xcodegen generate`); the `.xcodeproj` itself is gitignored and regenerable.
- Build/test from CLI: `xcodegen generate && xcodebuild -scheme PhotoApp build` /
  `xcodebuild -scheme PhotoApp test` (scheme: PhotoApp)

## Architecture principles
- Non-destructive: edit state = ordered list of adjustment params, serialized to the DB
  (and optionally XMP-style sidecars). Replaying the same params must be deterministic.
- Edit pipeline order is fixed: decode → WB → exposure → contrast → curves → HSL → transform/distort → crop → output transform.
- All image math in linear light in a defined working color space; convert to display/sRGB only at output. Document any deviation.
- DB access never blocks the main thread. Thumbnails generate on a background queue.
- Keep modules separated: Catalog / EditEngine / Rendering / UI. No UI imports in EditEngine.

## Roadmap (build strictly in this order)
1. Foundation: Xcode project, open + display an image in a Metal-backed view
2. Edit engine: exposure, contrast, white balance, curves, HSL, crop, transform/distort
   — see detailed backlog below (grown from the original 6 items after review)
3. Non-destructive pipeline: param serialization, edit history, undo — ✅
   COMPLETE. In-memory Undo/Redo (`Sources/EditEngine/EditHistory.swift`,
   time-coalesced ~350ms bursts, toolbar buttons + ⌘Z/⇧⌘Z); Revert to
   Original (toolbar button, atomic commit, always resets to true identity
   regardless of any loaded sidecar); Edit-menu `CommandGroup(replacing:
   .undoRedo)` integration (`document` ownership lives in `PhotoAppApp`,
   passed down to `ContentView`); sidecar-file persistence (each photo's
   edits auto-save to `MyPhoto.jpg.photoapp.json` next to it via a lazy,
   per-folder security-scoped bookmark — the FIRST real edit in an
   unapproved folder prompts once via a directory-mode `NSOpenPanel`,
   reused silently afterward; declining is honored for the rest of the
   session, not persisted). `EditState`'s `Codable` is schema-tolerant
   (falls back to each field's own default on a missing key, in a
   separate `extension EditState` so the synthesized memberwise init
   isn't suppressed) — safe for this project's habit of adding new
   `EditState` fields almost every session.
4. Library: import, catalog DB, thumbnail grid, ratings/flags, collections
   — ✅ COMPLETE (all four slices shipped). Catalog DB foundation + basic folder import ✅ COMPLETE:
   GRDB (first external dependency) added via `project.yml`'s `packages:`;
   `Sources/Catalog/` now holds `Photo` (a metadata/path-only record —
   `path` is `UNIQUE`, making re-import idempotent), the first
   append-only migration (`Migrations/001_initial.swift`), and
   `CatalogDatabase` (async, off-main-thread GRDB `DatabaseQueue` wrapper
   at `Application Support/PhotoApp/catalog.sqlite` — inside the sandbox
   container, so no bookmark is needed for the DB itself); `PhotoImporter`
   is a pure folder-scan helper. `Sources/UI/CatalogModel.swift` (kept out
   of `Sources/Catalog` to keep that module UI-free) opens the database
   via a `Task.detached` inside `init()`, never synchronously on
   `@MainActor` — a real bug the reviewer caught in the first draft.
   Basic "Import Folder…" toolbar button only. Library thumbnail grid
   ✅ COMPLETE: `Sources/Rendering/ThumbnailGenerator.swift` (pure ImageIO
   decode, `CGImageSourceCreateThumbnailAtIndex`, EXIF orientation via
   `kCGImageSourceCreateThumbnailWithTransform`); `CatalogModel` gained
   `@Published photos`/`refresh()`, an actor-isolated `NSCache`-backed
   thumbnail cache (bounded, in-flight-deduplicated), and — the key
   sandbox piece — a read-only security-scoped bookmark PER IMPORTED
   FOLDER, held open (`startAccessingSecurityScopedResource()`, never
   `stop`ped) for the app's whole process lifetime and re-activated for
   every known folder at launch, because `ImageDocumentModel.load(from:)`'s
   `CIImage(contentsOf:)` decode is lazy (reads happen at render time,
   possibly repeatedly) so scoping access only around `load()` isn't
   enough; `Sources/UI/LibraryGridView.swift` is a `LazyVGrid` toggled via
   a new toolbar button, swapping `ContentView`'s `mainContent` between it
   and the existing single-photo editor (renamed `editorContent`).
   Reviewer's first pass caught 4 real bugs, all in the folder-access/
   thumbnail-cache logic (a bookmark failure silently skipping the
   `start` call too; a discarded `Bool` success/failure result; an
   unbounded cache; unmatched repeated `start` calls on re-import) —
   all fixed, re-reviewed, APPROVED. Ratings and flags ✅ COMPLETE: a
   0–5 star rating and a boolean flag, settable via a `StarRatingRow` +
   flag `Button` always visible below the filename in every
   `LibraryGridView` cell (Library-grid-only, not in the Editor).
   `Migrations/002_ratings_and_flags.swift` is the first migration since
   `001_initial` and the first `ALTER TABLE` — adds `NOT NULL ... DEFAULT`
   columns, the specific form SQLite requires for altering an
   already-populated table (verified against the real, pre-populated
   on-disk `catalog.sqlite` from slices 1/2 via two live quit/relaunch
   cycles, not just a fresh test DB). `CatalogDatabase.setRating`/
   `setFlagged` are the first `UPDATE` queries (every prior write was
   `importPhotos`'s `INSERT`); rating is clamped to 0...5 in Swift before
   the query runs. Reviewer APPROVED on the first pass; one non-blocking
   note carried forward in `PROGRESS.md` (rapid repeated taps could
   transiently show a stale rating in the grid) — SINCE FIXED, see
   `PROGRESS.md`'s "Library tap mutators update in place": the tap
   mutators now update local state synchronously instead of re-reading
   the whole catalog. Collections ✅ COMPLETE: photos can belong to any
   number of user-created albums, browsed via a left sidebar next to the
   grid (`Sources/UI/CollectionSidebarView.swift` — the app's first
   `List`) plus a per-cell `Menu` to toggle membership.
   `Migrations/003_collections.swift` is the first migration to create two
   tables with a foreign key (`onDelete: .cascade` on both sides) and a
   composite primary key — reviewer independently confirmed against the
   vendored GRDB source that `PRAGMA foreign_keys` is on by default and
   never overridden, so cascade delete genuinely takes effect. The new
   record type is named `PhotoCollection`, not `Collection` — this project
   is a single Swift module, so a bare `Collection` would shadow
   `Swift.Collection` project-wide. `CatalogDatabase` gained
   `allCollections`/`createCollection`/`photos(inCollection:)`/
   `allMemberships`/`setMembership` (this project's first `IN`-clause
   filter and first `onConflict: .ignore` insert). **A real bug caught by
   live testing** (not the reviewer): binding `selectedCollectionID: Int64?`
   (`nil` = "All Photos") directly to SwiftUI's `List(selection:)` made
   the `nil`-tagged "All Photos" row silently stop being selectable once a
   real collection had been chosen — a known category of quirk with
   `Optional`-typed List selection bindings. Fixed with `LibraryFilter`, a
   non-optional enum (`.allPhotos` / `.collection(Int64)`), so every row's
   tag is a concrete value; the sidebar exposes a computed
   `Binding<LibraryFilter?>` (still required by `List`'s own API) that
   coerces the framework's "nothing selected" `nil` back to `.allPhotos`.
   Reviewer confirmed this is the sound, standard fix. Sort/filter/search
   shipped later as a Post-Phase-5 follow-up (see below — kept out of
   Phase 4's own scope at the time). Removing photos from the catalog,
   detecting files deleted on disk since import, a three-state pick/reject
   model, keyboard shortcuts for rating/flagging, and renaming/deleting
   collections are all still NOT started — candidates for a future
   session.

   **Post-Phase-4 follow-up (shipped, outside the original roadmap
   scope): folder-mirrored nested collections.** The user organizes
   photos on disk as Year/Trip/Day and asked for the Library to mirror
   that automatically. A new, separate "Import Folder Tree…" action
   (the original flat "Import Folder…" is untouched) recursively scans a
   folder (`PhotoImporter.scanFolderTree`, the project's first recursive
   directory walk) and creates a matching nested `PhotoCollection` tree
   (`Migrations/004_folder_collections.swift` adds `parentId`/`isFolder`/
   `folderPath` to `collection` — the first FK added via `ALTER TABLE`
   and the first self-referencing one; verified against the actual
   vendored GRDB source, not assumed, including that SQLite genuinely
   disallows a `UNIQUE` column via `ALTER TABLE ADD COLUMN`, which is why
   `folderPath` uniqueness is enforced by a check-then-insert inside one
   `dbQueue.write` transaction instead). `CatalogDatabase.importPhotos`
   was refactored (behavior-preserving) to share its insert-or-skip logic
   with the new `importFolderTree`, so a photo imported flat first still
   gets correctly associated, not duplicated, when a later tree import
   reaches it. `CollectionSidebarView` gained the app's first
   `OutlineGroup`, showing the tree in a new "Folders" section below the
   existing flat "Collections" section. Reviewer APPROVED on the first
   pass; three non-blocking notes carried forward in `PROGRESS.md` (no
   index on `folderPath`, no symlink-loop guard in the recursive scan, a
   mismatched `parentID` on re-import from a different root is silently
   ignored rather than reparenting).
5. Presets + export: save/apply presets, batch export (resize, quality,
   format) — STARTED. Batch export ✅ COMPLETE: exports the Library's
   currently-filtered set (`catalog.photos` — all photos, or one
   Collection/Folder's members, whatever the sidebar selection is; no
   new multi-select UI in this slice) as JPEG/PNG/TIFF with quality/
   resize options and a live progress HUD. `Sources/Rendering/PhotoExporter.swift`
   renders via decode → EXIF-orient → `EditPipeline.apply` → optional
   resize → `CIContext.write*Representation` — deliberately never
   touches `ImageRenderer`/manual `MTLTexture` rendering (that type's
   own doc comment flags its "no y-flip" behavior as verified only for
   the live `MTKView` drawable and warns export must independently
   re-verify orientation for an offscreen destination, not assume it);
   visually confirmed live, not just assumed safe from avoiding that
   landmine. Required extensive live debugging to get sandboxed writes
   working, root-caused to `project.yml`'s `user-selected.read-only`
   sandbox entitlement — a hard cap that made every write fail
   regardless of thread/API/folder — fixed by switching to
   `user-selected.read-write` (this exact change broke the "Open…"
   picker once before, in Phase 3; re-verified live this time that it
   doesn't regress). Reviewer's first pass caught 2 real bugs (no
   re-entrancy guard around a destination-filename race; no validation
   against a non-positive resize value, silently corrupting output) —
   both fixed, re-reviewed, APPROVED. **Selecting individual photos for
   export** (the user's immediate follow-up ask) ✅ COMPLETE: an
   always-visible checkbox badge on each Library thumbnail
   (`CatalogModel.selectedPhotoIDs`, pure in-memory — no DB write, unlike
   every other mutator in that class); `ContentView.photosToExport` is a
   pure refinement (non-empty selection overrides the sidebar's
   Collection/Folder filter, empty selection is a no-op — zero behavior
   change for anyone not using it). No changes needed to `ExportModel`/
   `PhotoExporter`/`ExportOptionsView` — `runExport(photos:)` was already
   subset-agnostic. **A real bug caught by live testing** (a screenshot,
   not the reviewer): adding `alignment: .topLeading` to the thumbnail
   `ZStack` (for the badge) exposed a latent sizing issue —
   `Image().resizable().aspectRatio(contentMode: .fill)` had no `.frame`
   of its own, so it reported a different effective size to the ZStack
   per photo depending on that photo's own aspect ratio (invisible under
   the old default `.center` alignment); fixed by pinning the image's
   own `.frame(width:140,height:140)` before `.clipShape`. Presets
   (save/apply named edit-state presets) are NOT started. Two unrelated
   real issues surfaced live during batch export's own verification,
   still explicitly deferred to their own future sessions: Library
   thumbnails don't reflect edits (`ThumbnailGenerator` bypasses
   `EditPipeline` entirely — a Phase 4 gap), and the Editor's on-screen
   rendering looks brighter/less saturated than Preview.app (a
   color-management question in `ImageRenderer`, not export).

   **Post-Phase-5 follow-up (shipped, outside the original roadmap
   scope): Editor Adjust-tab sidebar restyle to match Apple Photos'
   Adjust panel.** Visual-restyle-only, confirmed with the user up front
   (deferred: per-section live preview filmstrips, AUTO buttons,
   per-section enable toggles — all real new features, not styling).
   `Sources/UI/ContentView.swift`'s 6 Adjust-tab sections (Light, Color,
   Selective Color, Black & White, Effects, Red-Eye) are now wrapped in
   a new `AdjustSectionContainer` (the app's first `DisclosureGroup`),
   collapsible with an icon header, all collapsed by default; a new
   `resetAdjustmentsButton` resets every Adjust-tab field (not
   Crop-tab fields) to identity in one action; `EditSliderRow`'s
   per-row reset became an icon-only button. **A real, pre-existing bug
   re-surfaced by making sections collapsible, caught live by the user**:
   the Selective Color band-swatch row was wide enough to force the
   whole sidebar wider once expanded — invisible before sections could
   collapse/expand, nothing to compare width against; fixed by resizing/
   re-centering the swatch row to fit the sidebar's minimum width.
   Zero `EditState`/`EditPipeline` changes. Reviewer APPROVE on first
   pass (one non-blocking accessibility nit, fixed before commit).

   **Post-Phase-5 follow-up #2 (shipped): custom thin slider replacing
   the native `Slider`.** The native macOS slider's glossy 3D knob
   doesn't restyle to match the flat dark theme, so — confirmed via
   AskUserQuestion — built a fully custom one instead of a native tint
   tweak. NEW `Sources/UI/ThinSlider.swift`: `ThinSliderGeometry` (pure,
   unit-tested value↔pixel mapping, same testable-UI-math pattern as
   `CropAspectMath.swift`) plus `ThinSlider`, a `GeometryReader`+
   `DragGesture` view with the exact same `Binding<Double>`/
   `ClosedRange<Double>` shape as `Slider(value:in:)` — so
   `EditSliderRow` needed exactly one line changed, zero call-site
   changes across ~18 existing rows. Deliberately pure SwiftUI, no
   AppKit interop, unlike the reverted "StableScrollInsets" regression
   this sidebar has history with (see `PROGRESS.md`) — still got live
   drag/click/scroll verification before commit per that lesson (review
   + tests alone weren't sufficient last time). Thumb shape/fill color
   tuned live from user feedback (circle → thin bar, accent blue →
   white). Reviewer APPROVE (one non-blocking accessibility-label gap,
   fixed before commit). 300 tests (16 new).

   **Post-Phase-5 follow-up #3 (shipped): fixed Editor-vs-Preview color
   discrepancy.** The Editor rendered visibly brighter/less saturated
   than Preview.app at identity edits. Root cause: the on-screen renderer
   (`ImageRenderer.swift`) and exporter (`PhotoExporter.swift`) encode
   byte-for-byte identical working/output color spaces into sRGB, but the
   `.rgba16Float` `MTKView`'s `CAMetalLayer` was never tagged with a
   `colorspace` (no `_sRGB` variant exists for float pixel formats to
   imply it) — so CoreAnimation presented the sRGB-gamma-encoded values
   undecoded, while export's file-based `write*Representation` correctly
   bakes in an sRGB tag. Fixed by tagging the presenting layer with the
   exact same `CGColorSpace` instance the renderer already encodes into
   (`outputColorSpace` widened `private` → internal), plus a debug
   `assert` on the layer cast so a future regression here is detectable.
   Display-tag-only — no pixel math/pipeline changes. Reviewer APPROVE.
   Live-verified against Preview.app on multiple photos, no
   over-correction. 300 tests unchanged (live-compositor-only artifact,
   not unit-testable, same category as the y-flip/crop-tiling bugs).

   **Post-Phase-5 follow-up #4 (shipped): Library thumbnails now reflect
   saved edits.** `ThumbnailGenerator` was pure ImageIO and never built a
   `CIImage`, so `EditPipeline` never ran; `CatalogModel`'s
   `ThumbnailCache` had no invalidation either. Added an `EditState`-aware
   overload that runs `EditPipeline` on the ALREADY-SMALL, EXIF-oriented
   ImageIO thumbnail (not a second full-res decode — pipeline geometry is
   extent-relative, so this is proportionally correct) via a `CIContext`
   using the app's own `extendedLinearSRGB`/`RGBAh` working space —
   matching `ImageRenderer`/`PhotoExporter`/`WhiteBalanceSolver`, a mistake
   the reviewer caught on the first pass (an earlier draft used a bare
   `CIContext()`, wrongly citing `HistogramComputer` as precedent).
   `ImageDocumentModel` gained `onSidecarSaved`, wired in `ContentView` to
   `CatalogModel.invalidateThumbnail` — `LibraryGridView` is torn down and
   rebuilt on every Editor↔Library switch, so cache invalidation alone (no
   live-reactivity machinery) is enough for the next visit to show the
   edit. **Two real bugs, one reviewer-caught, one live-caught by the
   user**: (1, reviewer) `ThumbnailCache.invalidate`'s `Task.cancel()` was
   cosmetic (the decode never checks `isCancelled`), so a slow
   pre-invalidation decode could finish after a newer one and silently
   overwrite the cache with stale data — fixed with a per-path generation
   counter, not cancellation. (2, live) Undo then immediately switching to
   Library didn't update the thumbnail (the ~1s debounced sidecar save
   hadn't landed yet) — fixed by flushing the pending save
   (`flushPendingSidecarSave`, widened from `private`) on every
   Editor→Library transition, not just on switching to a different photo.
   Reviewer: FIX FIRST (missing working color space; the cache race) →
   both fixed → APPROVE. 303 tests (3 new).

   **Post-Phase-5 follow-up #5 (shipped): Compare mode (Side by Side +
   Split before/after).** New Editor toolbar `Menu`: Off / Side by Side /
   Split, with a vertical or horizontal divider for Split. Confirmed
   design (AskUserQuestion): "original" keeps the current crop/straighten/
   perspective/flip geometry — only color/tone resets to identity — so
   both sides always share one extent and align pixel-for-pixel
   (`EditState.comparisonOriginal()`, a superset of the pre-existing
   `resetAdjustmentsButton`'s field list — also clears `redEyePoints`,
   since `EditPipeline`'s red-eye stage stays active on points alone
   regardless of the strength slider's default, reviewer-verified against
   the actual pipeline code). `ImageRenderer`/`MetalImageView` gain an
   optional `CompareRenderConfig`; `nil` keeps the existing single-image
   path byte-identical via an extracted `fitted(_:into:)` transform
   helper. New `Sources/UI/CompareLayout.swift` holds the pure,
   unit-tested side-by-side/split-rect/divider-fraction geometry
   (`CropAspectMath`/`ThinSliderGeometry` precedent). Mutually exclusive
   with crop-editing/WB-eyedropper/red-eye-placement (arming one disarms
   the others). **Two real bugs caught live, both fixed**: (1) the
   renderer's own `fitRect` has visual-BOTTOM at `minY` (this app's
   existing documented Metal y-convention) while the SwiftUI overlay has
   visual-TOP at `minY` — opposite for the y axis only — so horizontal
   split needed its position inverted and the opposite region picked;
   vertical needed no change (x has no such inversion). (2) The divider's
   grab-vs-click-elsewhere gesture was first a single gesture with manual
   distance bookkeeping, which worked for one orientation but not the
   other (root cause not pinned down) — replaced with two separate
   hit-tested regions (a wide invisible grab strip layered over a
   background jump layer) so SwiftUI's own hit-testing routes the gesture
   instead of custom state. Reviewer APPROVE on first pass — independently
   re-derived the y-axis coordinate math and the red-eye field-clearing
   requirement from first principles rather than trusting the diff or the
   live-test outcome. 319 tests (16 new).

   **Post-Phase-5 follow-up #6 (shipped): scroll-to-zoom + click-drag-to-
   pan.** Works in the normal Editor view and both Compare modes (unavailable
   during Crop/WB-eyedropper/red-eye-placement, mirroring Compare's own
   mutual-exclusion). New `Sources/UI/ZoomPanGeometry.swift` (pure,
   unit-tested — `CompareLayout`/`CropAspectMath` precedent): a
   cursor-centered-zoom formula and a pan-clamp formula, both derived and
   independently re-derived by the reviewer, not eyeballed. `ImageRenderer`'s
   shared `fitted(_:into:)` widened with defaulted zoom/pan params
   (byte-identical at defaults — verified) so all three render paths
   (off/sideBySide/split) get zoom for free; Side by Side syncs both halves
   by feeding the same values into each (pan is normalized per-rect).
   Scroll capture uses an `NSEvent` local monitor on the `MTKView` subclass,
   not a `scrollWheel` override — a plain override would never fire in
   Split mode, since `CompareDividerOverlay`'s background overlay sits on
   top of the MTKView in the same `ZStack` and would swallow the event via
   SwiftUI's own responder chain first. Swift 6: the monitor's token is
   `nonisolated(unsafe)` so `deinit` can remove it (a real compile error —
   `NSEvent` is non-`Sendable` — ruled out wrapping the closure in
   `MainActor.assumeIsolated`; `NSView` subclasses are already implicitly
   `@MainActor`-isolated here). **A real bug caught live**: Side by Side
   didn't crop each fitted image to its own half — harmless at
   `zoomScale == 1` but once zoomed past 1 the larger fitted image bled
   into the neighboring half and visually covered it; fixed by cropping
   each side to its own rect before compositing. Reviewer APPROVE on first
   pass — independently re-derived both geometry formulas and the y-axis
   flip, confirmed the crop-bleed fix's completeness for any zoom, and
   confirmed the build compiles clean under this project's real Swift 6
   settings. 337 tests (18 new).

   **Post-Phase-5 follow-up #7 (shipped): Library sort/filter/search —
   Library polish, slice 1.** Scoped down from the broader "Library
   polish" backlog item (removing photos, detecting missing files,
   renaming/deleting collections are still deferred). New
   `Sources/Catalog/LibraryFilterSort.swift`: a pure, unit-tested
   `LibraryFilterSort.apply` (sort: oldest/newest/rating/name;
   minimum-rating threshold; flagged-only; filename search) applied
   entirely IN-MEMORY over the already-loaded `photos` array — not a new
   DB query, avoiding what would have been this codebase's first GRDB
   `LIKE` query and a DB round-trip per keystroke, composing on top of
   the pre-existing `selectedFilter` Collection/Folder selector without
   touching it. Default sort matches the existing DB order exactly
   (reviewer-verified). `LibraryGridView` gained a filter bar and two
   distinct empty states (true-empty library vs. filtered-to-nothing).
   **Two live-caught follow-ups**: re-sorting caused a visible delay
   before thumbnails reappeared (`LazyVGrid` only keeps a limited
   instantiated window, so re-sorting scrambles which photos land in it,
   forcing fresh decodes for previously off-screen ones) — fixed by
   bumping `ThumbnailCache` from 64MB (~270 thumbnails) to 256MB (~1165)
   and adding a small loading spinner to the placeholder. Reviewer
   APPROVE on first pass. 350 tests (13 new).
6. RAW support: LibRaw bridge, demosaic, camera profiles
7. Polish: tiled rendering for large images, perf, edge cases

One feature per session. Do not start a later phase while an earlier one has open issues.

### Phase 2 edit engine backlog
Grouped to match Apple Photos' adjustment panel (used 2026-07-31 as a reference for
completeness — a mature, shipping editor's full control set). ✅ = shipped (v1, may be
a simplified version — see note); everything else is not built yet. Pick ONE at a time,
each gets its own Plan Mode session per the workflow rules below.

- **Light (tone):** Exposure ✅, Contrast ✅, Brightness ✅ (additive lightness,
  distinct from Exposure's multiplicative linear-light gain, applied in the
  perceptual domain), Black Point ✅ (shadow clipping point, implemented by
  moving Curves' point0 along its X axis), Brilliance ✅ (this app's own
  composite approximation — NOT Apple's proprietary algorithm — a render-time
  blend of effective contrast/shadow-lift/highlight-protection/saturation).
  Shadows/Highlights currently live under Curves v1 below rather than as dedicated
  Light-group sliders — revisit whether to split them out once Levels/Curves v2 lands.
- **Color:** Saturation ✅ (global, under HSL v1 below), Vibrance ✅ (saturation
  that protects already-saturated tones and skin tones — a genuinely different
  algorithm from plain saturation, via Core Image's `CIVibrance`). Cast ✅
  shipped — whole-image gray-world statistical analysis (downsampled,
  luma-outlier-clipped mean in scene-linear light via
  `Sources/Rendering/ImageAverageColor.swift`) feeding the existing
  `WhiteBalanceSolver`/`whiteBalanceTemperature`/`whiteBalanceTint` fields —
  no new `EditState` fields or pipeline stage, a new UI-driven way (a single
  "Fix Color Cast" button, `ImageDocumentModel.fixColorCast()`) to set
  fields that already exist, exactly like the WB eyedropper.
- **Black & White:** ✅ shipped — a single toggle forcing full desaturation
  (reuses the same `CIColorControls` saturation-zero mechanism `hslSaturation`'s
  own -1 extreme uses). Not built: Intensity/Neutrals/Tone/Grain sliders
  (Photos' fuller B&W panel — v1 is on/off only).
- **Red-Eye:** ✅ shipped — tap to place correction points (tap an existing
  marker to remove it), shared Size/Strength sliders apply to every point at
  once. `EditState.redEyePoints` is the app's first variable-length/user-
  placed collection field (every other adjustment is a fixed set of named
  fields). Localized soft-masked "suppress red + darken" via
  `CIRadialGradient`/`CIColorMatrix`/`CIBlendWithMask` — no custom kernel
  needed. Multiple points combine into one union mask (`CIMaximumCompositing`)
  before the color transform runs once, avoiding double-correcting overlaps.
- **White Balance:** Temperature + Tint ✅. "Pick a neutral gray" eyedropper ✅
  shipped — the app's first point-and-click interaction. `CITemperatureAndTint`
  has no closed-form inverse, so `WhiteBalanceSolver` runs a live numerical
  search (coarse grid + refine, ~52 filter evaluations, off the main thread)
  at tap-time rather than a probe-baked constant; classifies results as fully
  solved vs. best-achievable (some strong casts can't be fully neutralized
  within the slider's own range).
- **Curves:** ✅ v1 shipped as simplified parametric Shadows/Highlights sliders (2
  control points of a `CIToneCurve` spline — known limitation: clamps highlight
  headroom above linear 1.0 when active, see `EditPipeline.applyCurves`). v2 not built:
  full interactive draggable RGB point-curve editor.
- **Levels:** ✅ shipped — `levelsBlackPoint`/`levelsWhitePoint`/`levelsGamma`
  sliders (distinct fields from Curves' own `blackPoint`, despite overlapping
  purpose) via `CIColorMatrix` → `CIColorClamp` → `CIGammaAdjust` (clamp
  deliberately before gamma to avoid NaN below the black point), running
  first in the perceptual sandwich (measured non-commuting with Brightness).
  Live histogram (`HistogramComputer`, 256-bin luminance + independently-
  normalized per-channel R/G/B, one shared downsample/render pass,
  independent `CIContext`) computed off the main thread, debounced ~150ms.
  A Luminance/RGB toggle (`HistogramDisplayMode`) switches `HistogramView`
  between the plain luminance bars and an additive-blended (`.plusLighter`)
  overlay of all four series.
- **Definition (Clarity):** ✅ shipped — a single Amount slider via a large-radius
  `CIUnsharpMask` (16x Sharpen's radius fraction), runs after Vignette (measured
  non-commutative with it, unlike Sharpen) and before Noise Reduction/Sharpen.
  One-directional 0...1, NOT bipolar: `CIUnsharpMask` was measured to silently
  clamp negative intensity to a no-op, so the originally-planned bipolar
  "Clarity" (positive=punch, negative=soften) was dropped for Apple Photos'
  one-directional "Definition" convention. v1 scope: single Amount slider only.
- **Selective Color:** ✅ shipped — this is HSL v2, 8 fixed hue bands
  (Red/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta) × Hue/Saturation/Luminance
  (24 params) + a shared Range falloff-width parameter. The first custom Core
  Image kernel in this codebase (`Sources/Rendering/Shaders/SelectiveColor.cikernel`
  — no built-in filter exposes per-pixel hue). Band weight is scaled by the
  pixel's own saturation (achromatic pixels get zero weight in every band) and
  the pixel's brightness is normalized before the HSL round-trip and restored
  after, so a colored pixel's own headroom survives even inside an active band.
- **HSL:** ✅ v1 shipped as global Hue + Saturation sliders (no Lightness — would
  duplicate Exposure/Curves). v2 = Selective Color above.
- **Noise Reduction:** ✅ shipped — a single Amount slider via `CINoiseReduction`,
  runs scene-linear just before Sharpen (`inputSharpness` pinned to 0 — its own
  default is a re-sharpen that adds noise back, measured). Unlike Sharpen's
  radius, `noiseLevel` needed no extent-derived scaling (measured
  resolution-independent). v1 scope: single Amount slider only.
- **Sharpen:** ✅ shipped — a single Amount slider via `CISharpenLuminance`, the
  pipeline's true final stage (radius scales with the image's own min
  dimension — measured necessity, the filter's radius is in absolute pixels).
  v1 scope: no separate Radius/Detail/Masking controls.
- **Vignette:** ✅ Strength + Radius shipped (via Core Image's `CIVignetteEffect`,
  centered on the post-crop extent so it correctly follows a crop). Softness
  (falloff) not built — fixed at a measured constant for now.
- **Transform/Distort:** refined against Apple Photos' Crop panel (2026-07-31
  reference): Straighten (rotation angle, degrees), Vertical and Horizontal
  perspective/keystone correction (two independent axes, not one combined "distort"
  control), lens distortion correction. Geometric like crop; runs before crop in the
  fixed pipeline order (see Architecture principles above). ✅ Straighten shipped
  (rotates around the extent's own center; growing the extent on a nonzero angle is a
  documented v1 limitation — use Crop to remove the resulting corner gaps). ✅
  Vertical/Horizontal perspective (keystone) correction shipped (via CIPerspectiveTransform,
  one combined filter call for both axes; corners move inward only so the extent is
  preserved exactly, unlike Straighten). Not built: lens distortion correction (explicitly
  out of the current feature batch — needs camera-profile data).
- **Flip:** ✅ shipped — two independent toggles mirroring horizontal/vertical around
  the image's own extent center, as a new Transform/Distort stage before crop.
- **Crop:** ✅ v1 shipped as four numeric inset sliders (Top/Bottom/Left/Right). ✅ v2's
  interactive drag-handle crop rectangle also shipped (overlaid on the full image, 8
  handles + interior drag, numeric sliders kept and stay in sync; handles styled as
  Apple-Photos-style L-shaped corner brackets + edge bars). ✅ Aspect-ratio presets also
  shipped: Original, Freeform, Square, 16:9, 4:5, 5:7, 4:3, 3:5, 3:2, Custom — selecting one
  snaps the crop to the largest inscribed/centered rect of that ratio; while locked, only
  the 4 corner handles stay interactive (ratio-preserving resize, anchored at the opposite
  corner). Straighten/Vertical/Horizontal live under Transform/Distort above, not
  duplicated here, even though Photos surfaces them in the same Crop panel.

## Workflow rules (important)
- Model is `opusplan`: ALWAYS enter Plan Mode before starting a new feature so the
  plan is produced by the stronger model. Keep plans scoped to ONE feature.
- After completing a feature and BEFORE any git commit, invoke the `reviewer` agent
  on the diff (`git diff HEAD`).
- If the reviewer verdict is FIX FIRST: fix every listed issue, then re-run the
  reviewer. Only commit on APPROVE.
- Never commit shader or color-math changes without a reviewer pass.
- Write unit tests for all edit math (curves interpolation, WB scaling, color
  conversions) — these are cheap to test and expensive to debug visually.
- Commit small and often, one logical change per commit, imperative commit messages.
- Build and run tests via xcodebuild after every significant change; fix failures
  before moving on.

## Quota / safe-pause discipline
The subscription can hit a usage limit and end the session at any moment. You
cannot see the exact remaining quota, so assume a cutoff could happen after any
step and make every stopping point safe:
- Keep `PROGRESS.md` at the repo root always current. After finishing any feature
  or before a long-running task, update it with: current phase, what's done, what's
  in progress, the exact next step, and any open reviewer issues.
- Work in small committed increments so no more than one small unit of work is ever
  uncommitted. A hard cutoff should never lose more than a few minutes.
- If the user says they are near their limit, or asks you to pause: immediately
  commit work-in-progress on a branch, update PROGRESS.md, summarize where things
  stand and the exact resume command, then stop — do not start new work.
- To resume in a new session: read PROGRESS.md first, then continue from its
  "next step".

### Conserving quota (make the subscription last)
- Reserve the stronger model for planning only (opusplan already does this). Don't
  ask for Opus-level reasoning on routine implementation.
- Run `/clear` between features so context doesn't accumulate — large context is
  the main driver of token burn.
- Keep plans and diffs scoped to one feature; avoid re-reading the whole codebase
  when a targeted Grep/Read will do.
- The reviewer agent only reads diffs, not the full tree — keep it that way.

## Conventions
- Swift: SwiftLint defaults, no force-unwraps outside tests, `// MARK:` sections.
- Shaders live in `Sources/Rendering/Shaders/`, one kernel per file, commented with
  the math they implement and its source/reference.
- DB migrations are append-only, in `Sources/Catalog/Migrations/`.
