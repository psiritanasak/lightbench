# Photo Editor (Lightroom-style) — Project Memory

## What this project is
A native macOS photo editor with a library/catalog, in the spirit of Lightroom.
Non-destructive editing is the core invariant: **original files are never modified**.
Edits are stored as parameter sets and rendered live on the GPU.

## Stack
- Swift + SwiftUI (AppKit interop where needed)
- Metal / Core Image for the GPU edit pipeline (custom kernels for curves, HSL, WB)
- SQLite via GRDB for the catalog (photos, edits, collections, ratings)
- RAW decoding via Core Image's `CIRAWFilter` (macOS 12+) — decided over the
  originally-planned LibRaw/C++-interop route in Phase 6 slice 1 (2026-09-02),
  after a user-approved tradeoff review: CIRAWFilter supplies demosaic and
  camera profiles for ~784 bodies at zero new dependencies/build-toolchain risk,
  vs. LibRaw's first-ever C++ interop, vendored binary, and hand-written
  demosaic/profile handling. See roadmap item 6 below for what shipped and
  what's deferred. LibRaw remains the documented fallback if a camera body
  outside CIRAWFilter's support list is ever needed — do not "fix" this line
  back to LibRaw without re-reading that history.
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
   format) — ✅ COMPLETE. Batch export ✅ COMPLETE: exports the Library's
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
   own `.frame(width:140,height:140)` before `.clipShape`. Two unrelated
   real issues surfaced live during batch export's own verification, both
   since fixed in later sessions (see PROGRESS.md): Library thumbnails not
   reflecting edits, and the Editor's on-screen rendering looking
   brighter/less saturated than Preview.app.

   **Presets ✅ COMPLETE** (2026-09-01): save/apply named edit-state
   "looks". Scope deliberately excludes crop/straighten/perspective/flip
   geometry and placed `redEyePoints` — both specific to one photo's
   composition, never part of a reusable look — reusing the EXACT field
   partition `EditState.comparisonOriginal()` (Compare feature) already
   established, via a new `EditState.applyingPreset(onto:)`. New
   `Sources/Catalog/Preset.swift` + `Migrations/005_presets.swift` — the
   first JSON-column record in this codebase (`editState: EditState`
   nested `Codable`, auto-serialized by GRDB's Codable-record support to
   a `.text` column, verified against GRDB's own source to be single-pass/
   not double-encoded, not `.blob` as an earlier draft assumed — GRDB
   persists nested Codable values as a JSON string, `.blob` only "worked"
   because SQLite's BLOB affinity does no type conversion). `CatalogDatabase`/
   `CatalogModel` gained `allPresets`/`createPreset` (`onConflict: .replace`
   — same-name saves overwrite, no separate confirmation UI)/`deletePreset`,
   mirroring the collections/photo-removal methods' exact shapes.
   `ImageDocumentModel.applyPreset(_:)` is structurally identical to the
   already-shipped `revertToOriginal()` — one atomic, immediately-committed
   undo step. `AdjustTabView` gained a 7th collapsible section ("Presets"),
   its own `.alert` (not `ContentView`'s, already at 5 and previously split
   over a 6th breaking the type-checker), and a flat list with no nested
   `Menu` (avoiding the exact type-checker pathology that broke the
   toolbar's `.toolbar {}` closure earlier). Reviewer APPROVE (Opus 5,
   after the default review model hit the account's monthly spend limit
   mid-review) — independently set-diffed the two field-partition methods
   programmatically and read the vendored GRDB source directly rather than
   trusting the docs. Two non-blocking findings fixed before commit: the
   `.blob`→`.text` column-type correction above, and the "Save Preset"
   button switched from saving `document.editState` wholesale to saving
   `document.editState.applyingPreset(onto: .identity)` — so a saved
   preset only ever contains the reusable fields, not the source photo's
   geometry as inert dead data. 390 tests (10 new). NOT yet verified live.

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

   **Post-Phase-5 follow-up #8 (shipped, 2026-09-03): click-to-type
   numeric entry on every Adjust/Crop slider.** `EditSliderRow`'s live
   readout (`Sources/UI/EditControlRows.swift`) was plain, non-interactive
   `Text` — the only way to set a value was dragging `ThinSlider`, which
   can't reliably hit a precise target. Tapping the readout now swaps in
   a `TextField`, typed in the SAME units already on screen (a new
   `displayMultiplier` param, default `1`, threaded through the ~29
   percent-formatted rows across `AdjustTabView`/`CropTabView` via a
   scripted multi-line substitution, reviewer-verified 36/36 call sites
   correct with zero misses) rather than parsing the formatted string
   (fragile: `%`/`EV`/`K`/`°` suffixes, locale-dependent decimals).
   Reviewer FIX FIRST → APPROVE: caught three real bugs pre-commit —
   Escape wasn't a reliable cancel (depended on unverified SwiftUI
   focus-teardown ordering between `onExitCommand` and the focus-loss
   `onChange`); a plain tap-then-click-away with no typing wrote a lossy
   `"%g"`-rounded value back regardless, firing a phantom undo-history
   entry and sidecar save for an interaction where nothing changed; and
   `"nan"`/`"inf"` input silently slammed the slider to its range
   minimum instead of no-opping. Fixed with a captured `seedText`
   comparison (only writes `value` when the typed text actually differs
   from what editing was seeded with) and a `typed.isFinite` guard. No
   new automated tests — `EditSliderRow` is a SwiftUI `View` body with no
   existing unit-test precedent in this codebase (only pure extracted
   geometry, like `ThinSliderGeometry`, gets tested) — verified live
   instead: type-to-edit on both a percent and a non-percent row,
   Escape-discards, tap-then-click-away-is-a-no-op, and garbage input,
   all confirmed working by the user. 420 tests unchanged.
6. RAW support: LibRaw bridge, demosaic, camera profiles — **slice 1 (decode
   only) ✅ COMPLETE** (2026-09-02), shipped on Core Image's `CIRAWFilter`
   instead of LibRaw — see the Stack section above for why. New
   `Sources/Rendering/RawDecoder.swift` is the app's first shared file-decode
   chokepoint: before this, `ImageDocumentModel.load(from:)`,
   `PhotoExporter.export`, and `ThumbnailGenerator.thumbnail(for:maxPixelSize:)`
   each decoded a file URL independently (three separate call sites, no shared
   helper beyond an orientation lookup); all three now route through
   `RawDecoder.decode`/`isRaw`/`decodeDraft`, non-RAW behavior byte-identical
   to before. `PhotoImporter.supportedExtensions` (a hardcoded non-RAW
   extension `Set`) is now paired with `RawDecoder.isRaw`'s
   `UniformTypeIdentifiers` classification (`.rawImage`/`public.camera-raw-image`)
   rather than growing the literal set with every RAW extension by hand — this
   tracks whatever RAW formats the OS itself knows about. Verified against the
   user's real Nikon D610 library (930 `.NEF` files,
   `/Users/praween/Pictures/Bolivia_trip/raw_files`) — `sips` and a direct
   `CIRAWFilter` probe both confirmed this exact camera decodes correctly on
   this machine before any code was written, retiring CIRAWFilter's one real
   risk (an unsupported camera body) empirically rather than by assumption.
   RAW thumbnails deliberately do NOT use ImageIO's thumbnail API (it would
   return the camera's own embedded JPEG preview, not Apple's RAW rendering —
   the same Editor-vs-grid mismatch post-Phase-5 follow-up #4 already fixed
   once) — they go through `CIRAWFilter`'s own `isDraftModeEnabled`/`scaleFactor`
   instead, matching `ImageRenderer`/`PhotoExporter`/`WhiteBalanceSolver`'s
   `extendedLinearSRGB`/`RGBAh` working space.
   **Orientation, measured live, not assumed** (this codebase has been bitten
   by unverified coordinate assumptions before — the Metal y-flip, the
   Compare-mode split inversion): `CIRAWFilter.orientation` is a readwrite
   property whose default already matches the file's own EXIF value and whose
   `outputImage` is pre-rotated accordingly — confirmed against a real NEF
   with its orientation tag byte-patched to a non-identity value, not just the
   header doc. So `RawDecoder` never chains `.oriented(_:)` after a RAW decode
   (that would double-rotate), and only overrides `filter.orientation` when an
   independent EXIF read actually succeeds — never with a guessed fallback,
   since that could stomp an already-correct default for a RAW container
   ImageIO parses differently than Core Image's own RAW decoder does (reviewer-
   caught in an earlier draft). Reviewer (Opus 5, after the default model hit
   the account's monthly spend limit mid-review — same as the Presets session):
   FIX FIRST → APPROVE after fixing that orientation-stomping risk, a RAW-
   thumbnail double-gamut-clip (edits were running on an already-flattened
   8-bit sRGB intermediate instead of the raw extended-range/wide-gamut
   `CIImage`, silently clipping exactly the headroom RAW provides before the
   edit math ever saw it — same defect class as post-Phase-5 follow-up #4),
   and an unclamped/unguarded `scaleFactor`. 399 tests (9 new; RAW *decode*
   itself has no fixture-based automated test — no RAW file ships in the repo
   — and was verified live instead; classification/importer behavior is
   fixture-free and fully covered).
   **Known limitation, logged not fixed this slice**: `CIRAWFilter.decoderVersion`
   defaults to "the newest available decoder for the image type" and is
   neither pinned nor serialized into `EditState` — replaying the same params
   after an OS update could render a RAW photo slightly differently, an
   exception to this file's "replaying the same params must be deterministic"
   principle above. Not addressed here since it's coupled to slice 2 (below);
   `decoderVersion` should become a serialized `EditState` field when RAW
   controls ship.
   **Two severe freezes surfaced during the user's own live pass**
   (2026-09-03), both diagnosed via `sample` on the actually-hung process,
   fixed, reviewer-approved (Opus 5, two full rounds each), and
   re-verified live with no recurrence — full detail in PROGRESS.md's two
   "Phase 6 slice 1 follow-up" sections. (1) `ImageRenderer.draw(in:)`
   re-ran the ENTIRE full-resolution RAW demosaic on every redraw (every
   slider tweak), since a `CIImage` is a lazy recipe, not decoded pixels —
   fixed with `RawDecoder.materialize(_:)`, rendering once into a cached
   extended-range `CVPixelBuffer` at photo-load time instead of per-frame.
   (2) Retrying immediately re-froze the app, differently — concurrent RAW
   decode requests (the Editor opening one photo while the Library grid
   decoded thumbnails for others in the background) deadlocked each other
   inside Apple's own closed `RawCamera.framework`, not just contending for
   CPU — fixed with `RawDecoder.RenderGate`, an actor serializing every
   heavy RAW CoreImage call app-wide (materialize, thumbnails, export) so
   the app never asks the framework to do two RAW things at once. That fix
   itself needed a follow-up round (reviewer-caught): overlapping
   `load(from:)` calls had no ordering guard, so a slower RAW load
   resuming after a faster load already committed could silently discard
   the second photo's edits — fixed with a monotonic generation token.
   **Phase 6 slice 1 is now fully shipped AND live-verified**, both
   freezes closed, 403 tests passing. 3 commits total for the two
   follow-up fixes (feature code + PROGRESS.md doc entries kept separate
   per this file's own convention).
   **Slice 2 (`boostAmount`, the first RAW-native `EditState` field) ✅
   COMPLETE** (2026-09-03). Two candidates were measured live against the
   user's real Nikon D610 library BEFORE any code was written, not chosen
   by assumption: `lensCorrectionEnabled` (the original candidate) was
   found DEAD — `CIRAWFilter.isLensCorrectionSupported == false` on all
   three sampled `.NEF` files, meaning the toggle would visibly do nothing
   on any photo the user actually has — so it's deferred to slice 3, not
   shipped as a no-op; `boostAmount` (Core Image's own RAW tone-curve
   strength, 0...1, default 1) was measured viable — matching default,
   genuinely different rendered pixel at 0 vs 1. Architecturally distinct
   from every other `EditState` field: it configures `CIRAWFilter` itself,
   upstream of `EditPipeline` (which is a pure `CIImage → CIImage`
   function with no file/URL access and structurally cannot express it),
   so changing it only takes effect via a full re-decode, not a pipeline
   re-run against `RawDecoder.materialize`'s cached buffer — exactly the
   "forward hazard" that function's own doc comment predicted in slice 1.
   New `EditState.requiresRawRedecode(comparedTo:)` is the single source
   of truth for which fields behave this way;
   `ImageDocumentModel.editState`'s `didSet` triggers a debounced
   (~0.4s) async re-decode (`scheduleRawRedecode`/
   `redecodeForRawNativeChange`), sharing `loadGeneration`/`RenderGate`
   with `load(from:)` so it can't race a photo switch or contend with
   concurrent RAW work elsewhere in the app. Along the way, confirmed and
   fixed a real ordering bug: `load(from:)` restored the incoming photo's
   `EditState` only AFTER decoding, so a newly-opened RAW photo would
   decode with the OUTGOING photo's `boostAmount` with nothing downstream
   ever correcting it — fixed by hoisting the sidecar read (and the flush
   that must move with it) above the decode. `boostAmount` is deliberately
   excluded from BOTH `comparisonOriginal()` and `applyingPreset(onto:)`
   (inherited like geometry, not reset/copied like color/tone) — the real
   reason, reviewer-corrected: `EditPipeline` never reads the field at
   all, so neither method has any way to actually apply a value to it
   regardless of what it's set to. `revertToOriginal()`'s literal
   `EditState()` IS the control that resets it. Reviewer (Opus 5, two
   full rounds, both after the default model hit the account's monthly
   spend limit — same pattern as slice 1): FIX FIRST → APPROVE. Round 1
   caught three real bugs in the re-decode/reorder machinery — a missing
   generation check letting a superseded re-decode still pay a full
   `materialize` inside `RenderGate` before discarding the result; a
   narrowed-but-still-open window where a slider drag during `load(from:)`'s
   own await could be silently dropped; a stale debounced re-decode that
   could survive a photo switch and fire a guaranteed-no-op re-decode
   right after opening the next photo — all fixed and independently
   re-traced by round 2 against the rewritten code. 412 tests (9 new).
   **Fully LIVE-VERIFIED (2026-09-03)**: user confirmed the slider works
   correctly, including that 100% is genuinely the correct/full-strength
   default (`boostAmount` is a strength dial on the decoder's own tone
   curve, 0...1, not a brightness multiplier — there is no way to exceed
   it), and exercised both interaction patterns automated tests can't
   reach (dragging mid-load of a different photo; switching photos
   immediately after/during a drag) with no issues. **Phase 6 slice 2 is
   now fully complete.**
   **Slice 3 (`rawExposureEV` + `shadowBoostScale`) ✅ COMPLETE**
   (2026-09-03). Chosen over the true no-search WB eyedropper and
   RAW-native NR/sharpness specifically because it reuses slice 2's
   already-twice-reviewed re-decode/debounce/`RenderGate` machinery
   rather than touching an already-shipped feature (WB) or opening a
   precedence question against an existing pipeline stage (NR/sharpness).
   Both candidates were measured live against the user's real Nikon D610
   library before design, same discipline as slice 2 — and the
   measurements changed the plan mid-flight, twice:
   - `CIRAWFilter` pre-populates `baselineExposure`/`boostShadowAmount`
     from the file's own embedded camera profile AT CONSTRUCTION TIME —
     measured `0.3`/`0.9` on real NEFs, not the `0`/`0` originally assumed
     (see below for the corrected citations). An `EditState` field with a
     fixed default would have silently overridden each file's own camera
     profile on every load — the exact regression class `boostAmount`'s
     own universal-default design avoided by coincidence, not by the same
     reasoning. This is why `shadowBoostScale` is a 0...1 SCALE of the
     file's own native value, not an absolute slider — the only precedent
     in this codebase for a relative (not absolute) `EditState` field.
   - `boostShadowAmount`'s upward half (native→2.0) was measured
     INERT — mean linear luma over the darkest quartile moved +3.5% at
     max vs. -31% at zero — so the slider only covers the `0...1` half
     that actually does anything, the same "measure before exposing dead
     travel" discipline that deferred `lensCorrectionEnabled` in slice 2.
   - The exposure field went through a REVIEWER-CAUGHT design change
     mid-review: an earlier draft mutated `baselineExposure` with `+=`
     (matching `shadowBoostScale`'s relative shape) to work around the
     same per-file-default problem. The reviewer found, from the actual
     SDK header, that `CIRAWFilter.exposure` is a SEPARATE property with
     a genuinely fixed, camera-profile-independent default of `0` — and
     live measurement confirmed `exposure = 2.0` and
     `baselineExposure += 2.0` render BYTE-IDENTICAL pixels on the same
     file. Switched to `filter.exposure`: same rendered result, but a
     plain absolute assignment instead of a read-modify-write, so
     `rawExposureEV` stays fully deterministic on replay — no exception
     to this file's "replaying the same params must be deterministic"
     principle, unlike the design it replaced. Distinct from the
     already-shipped `exposureEV` (post-decode `CIExposureAdjust`
     gain) — measured, not assumed, to preserve highlight headroom the
     post-decode control cannot: at +2 EV, decoder-level exposure clipped
     zero of 1600 sampled points above 1.0 (max 0.9907), while
     `exposureEV` at +2 pushed 99 of 1600 past 1.0 (max 1.9506).
   - The reviewer also caught two citation errors in the first draft's
     doc comments (both fixed): the SDK header declares `boostShadowAmount`'s
     own default as `1`, not `0` (the measured `0.9` anomaly is real but
     smaller than first stated); and the header states
     `boostShadowAmount` "has no effect if the boostAmount is 0" — so the
     Shadow Boost row now disables itself whenever Boost Amount is `0`,
     rather than being a silently dead control (the same trap
     `lensCorrectionEnabled` was deferred to avoid in slice 2).
   - Both remaining mutating properties (`exposure`, `boostShadowAmount`)
     are now guarded to only touch `filter` when the value is non-identity
     — a STRUCTURAL guarantee that an untouched photo never has either
     property written at all, rather than relying on `x += 0`/`x *= 1`
     being a semantic no-op on an ObjC-bridged filter property (reviewer
     flagged this as unverified — a setter can plausibly flip an internal
     "user overrode this" flag regardless of the value written). Also
     closed a related ordering inconsistency the reviewer caught: `decode`
     and `decodeDraft` applied these fields at different relative
     positions (before vs. after draft-mode/orientation setup) — now
     identical in both, immediately after construction, removing the need
     to measure whether that setup perturbs the profile-seeded values.
   - `RawDecoder.decode`/`decodeDraft` were widened from a single
     `boostAmount: Double` parameter to the whole `editState: EditState`
     — adding a third scalar the slice-2 way would have made the
     parameter list unwieldy and, worse, created a SECOND place enumerating
     which fields are RAW-native (alongside `requiresRawRedecode`) that
     could silently drift out of sync. `applyRawNativeSettings` is now the
     one place all three fields are read; a future slice-4 field needs
     zero signature changes anywhere, only that function and
     `requiresRawRedecode`.
   Reviewer (Opus 5, after the default model hit the account's monthly
   spend limit — same pattern as slices 1 and 2): FIX FIRST → APPROVE.
   420 tests (8 new). **Fully LIVE-VERIFIED (2026-09-03)**: user confirmed
   RAW Exposure preserves highlight headroom the regular Exposure slider
   clips at the same EV, Shadow Boost visibly darkens shadows and
   disables itself when Boost Amount is 0, both sliders return to an
   identity-matching render at their defaults, and both race conditions
   automated tests can't reach (drag-then-switch-photos;
   switch-then-drag-during-load) behaved correctly. **Phase 6 slice 3 is
   now fully complete.**
   **Slice 4 (`rawWhiteBalanceNeutralPoints`, a true no-search RAW
   white-balance eyedropper) ✅ COMPLETE** (2026-09-04). Chosen over
   RAW-native NR/sharpness and the `CIRAWDecoderVersion9` opt-in. Uses
   `CIRAWFilter.neutralLocation`: set it to a pixel and the decoder
   computes and applies the correct white balance directly, no search —
   vs. the existing eyedropper's `WhiteBalanceSolver`, a ~52-evaluation
   numerical search against `EditPipeline`'s post-decode
   `CITemperatureAndTint` filter. Two live measurements shaped the
   design, both changing the plan mid-flight:
   1. `CIRAWFilter`'s own computed `neutralTemperature`/`neutralTint` for
      a tapped point do NOT neutralize the same pixel when fed directly
      into the app's existing `whiteBalanceTemperature`/`whiteBalanceTint`
      fields — measured `[37,44,59]` → `[48,43,38]` (moved the right
      direction, nowhere near neutral), vs. `[47,47,48]` via
      `neutralLocation` itself. The two mechanisms are numerically
      incompatible (different filter, different convention), so this
      shipped as a genuine fourth RAW-native `EditState` field
      (`rawWhiteBalanceNeutralPoints: [RawNeutralPoint]`, at most one
      element — mirrors `redEyePoints`' empty-means-off convention),
      following `boostAmount`/`rawExposureEV`/`shadowBoostScale`'s exact
      architecture, not a thin translation layer.
   2. `neutralLocation` operates on the RAW's own native, un-rotated,
      PRE-geometry pixel grid (before straighten/perspective/crop/flip,
      which run post-decode in `EditPipeline`). A tap on the CURRENT
      on-screen view needs inverting through those transforms to map back
      — not simple affine math for straighten/perspective. Deliberately
      scoped (via `AskUserQuestion`) to sidestep this rather than build
      it: the fast path only activates when app geometry is at identity
      (new `EditState.isGeometryAtIdentity`, covering the same 9-field
      "geometry" group already named together in
      `comparisonOriginal()`/`applyingPreset()`) AND the file's EXIF
      orientation is CONFIRMED `.up` — a second, related hazard found
      while re-verifying the existing "apply immediately after
      construction" ordering the other three RAW-native fields
      established: `neutralLocation` measured to produce a DIFFERENT,
      implausible result depending on whether `orientation` was already
      non-`.up` at assignment time, but identical regardless of order
      when orientation is `.up`. Every other case (any geometry edit, a
      rotated file) falls through unchanged to the existing search.
   New `RawDecoder.confirmedOrientation(of:)` — `RenderGate`-gated,
   returns the real `Optional` (no `.up` fallback, unlike the existing
   `exifOrientation(of:)`) — is read ONCE per RAW photo load and cached
   on `ImageDocumentModel.currentRawOrientationIsUp`, not re-read at tap
   time. Reviewer (Opus 5, after the default model hit the account's
   monthly spend limit twice mid-review — same pattern as every prior
   slice): FIX FIRST → APPROVE. Caught three real bugs: the fast path
   left a stale `whiteBalanceTemperature`/`whiteBalanceTint` applied on
   top of the RAW-neutralized decode (silent double-correction whenever
   those fields were already non-identity from a manual nudge, a preset,
   or an earlier slow-path tap) — fixed by resetting both to identity on
   the fast path, matching the slow path's own always-overwrite
   semantics; the orientation gate treated an UNREADABLE orientation as
   `.up`, precisely the unsafe case the whole design exists to avoid —
   fixed by requiring a genuinely-read `.up`, never a fallback; and the
   gate re-opened the file synchronously on the main actor at tap time —
   reintroducing a defect class `RawDecoder.decode`'s own doc comment
   already records as reviewer-caught once before — fixed by the
   load-time caching described above. Also measured live before commit:
   `neutralLocation` produces identical results through `decodeDraft`'s
   draft-mode/`scaleFactor` path as a full decode (thumbnail won't
   diverge from the Editor). 435 tests (15 new). **Known gap, accepted
   for this slice**: unlike the other three RAW-native fields, this one
   has NO UI representation at all (no slider, not shown, not resettable
   except via Undo/Revert to Original) — flagged explicitly in
   `AdjustTabView`'s existing gap-note doc comment for whoever next
   touches the RAW section. **Fully LIVE-VERIFIED (2026-09-04)**: user
   confirmed near-instant correction with no crop applied; an asymmetric
   tap test (clearly warm vs. clearly cool area) both corrected sensibly,
   confirming `neutralLocation`'s y-origin convention is right-side-up
   (the one thing the reviewer flagged as unverifiable without visual
   inspection); adding a crop and tapping again correctly fell back to
   the existing search; a fast-path correction survived a LATER crop
   being added; and a non-RAW photo's eyedropper was unaffected. **Phase
   6 slice 4 is now fully complete.**
   **Slice 5 (`rawLuminanceNoiseReductionAdjust` + `rawColorNoiseReductionScale`
   + `rawSharpnessScale`, RAW-native Noise Reduction and Sharpness) ✅
   COMPLETE** (2026-09-04). This slice was originally deferred pending "a
   precedence decision" — the app already has post-decode `noiseReduction`/
   `sharpness` fields (`EditPipeline`'s `CINoiseReduction`/
   `CISharpenLuminance`, any photo type) — resolved by measurement, not
   argument: these three RAW-native fields configure `CIRAWFilter` itself
   at DECODE time, entirely upstream of and independent from those
   post-decode stages, so the two compose additively (no replacement, no
   mutual exclusion), the same relationship `rawExposureEV` already has
   with `exposureEV`. Measured, unlike `lensCorrectionEnabled`, that all
   three ARE supported on this camera
   (`isLuminanceNoiseReductionSupported`/`isColorNoiseReductionSupported`/
   `isSharpnessSupported` all `true`) — viable, not another dead end.
   Their native per-file defaults (`0.0`/`0.5`/`0.9`) match
   `shadowBoostScale`'s own per-file-camera-profile-seeded pattern, not
   `boostAmount`'s universal-default pattern.
   Reviewer (Opus 5, after the default model hit the account's monthly
   spend limit — same pattern as every prior slice): FIX FIRST →
   APPROVE. Caught two real bugs:
   1. `rawLuminanceNoiseReductionAdjust` was originally shipped as the
      SAME multiplicative `*=` scale shape as `shadowBoostScale` — but
      this camera's own native `luminanceNoiseReductionAmount` measures
      exactly `0.0`, making `native * anything` always `0`: a provably
      dead control across its ENTIRE range, not a narrow inert band like
      `boostShadowAmount`'s upper half. Fixed by switching to an
      ADDITIVE offset (`native + adjust`, clamped to the property's own
      `0...1` range) — re-verified live to reproduce the reviewer's own
      measured 256×256-region pixel delta (80914) exactly, confirming
      the fix reaches the genuinely useful range above `0.0` a scale
      never could. `rawColorNoiseReductionScale`/`rawSharpnessScale`
      stayed multiplicative scales, since their native defaults
      (`0.5`/`0.9`) are meaningfully non-zero and measured effective as
      scales — flagged in their own doc comments that a future camera
      with a near-zero native default here would hit the identical trap.
   2. All three fields' doc comments claimed "no capability gate
      needed" — false: `isLuminanceNoiseReductionSupported`/
      `isColorNoiseReductionSupported`/`isSharpnessSupported` are
      structurally identical to `isLensCorrectionSupported`, the exact
      flag that killed `lensCorrectionEnabled` in slice 2. Fixed with
      new `RawDecoder.confirmedAdjustmentSupport(of:)` (`RenderGate`-
      gated, mirrors `confirmedOrientation`'s own slice-4 pattern),
      cached once per RAW photo load on
      `ImageDocumentModel.currentRawAdjustmentSupport`, disabling each
      of the three RAW-section UI rows individually.
   447 tests (12 new). **LIVE-VERIFIED (2026-09-04), with one real live
   finding root-caused, not dismissed**: user reported RAW Luminance NR
   and RAW Color NR both looked "barely visible" when dragged. Diagnosed
   as content-adaptive visibility, not a code defect — noise reduction
   only visibly changes pixels where noise exists, and the reviewer's
   own earlier measurement is consistent with this: RAW Color NR's
   pixel delta (203683 over a 256×256 region) was actually the LARGEST
   of the three RAW-native fields, so the underlying code is doing
   substantial work — the user's source photos (a daylight travel
   shoot, low ISO, good light) are just genuinely low-noise outside
   shadow regions. User accepted this explanation. RAW Library
   thumbnails not reflecting any of the three sliders (measured live
   pre-commit: `decodeDraft`'s `isDraftModeEnabled` path produces zero
   pixel delta for all three) was NOT independently re-confirmed live
   this pass, accepted as a known, already-measured gap rather than
   re-tested.
   **Slice 6 (`rawContrastAdjust` + `rawDetailAdjust` +
   `rawMoireReductionAdjust`, RAW-native Contrast/Detail/Moiré Reduction)
   ✅ COMPLETE** (2026-09-04). Live-measured BEFORE writing any code,
   applying slice 5's own lesson proactively rather than re-discovering
   it: all three underlying `CIRAWFilter` properties (`contrastAmount`,
   `detailAmount`, `moireReductionAmount`) have a native default of
   `0.0` on this camera — the exact degenerate case that made
   `rawLuminanceNoiseReductionAdjust`'s original multiplicative-scale
   design dead-on-arrival in slice 5 — so all three shipped as ADDITIVE
   offsets from the start, not a repeat of that mistake. Confirmed
   supported (`isContrastSupported`/`isDetailSupported`/
   `isMoireReductionSupported` all `true`) and confirmed substantial
   real effect via absolute assignment (256×256 region, total abs
   delta): `contrastAmount` at `1.0` → `290565` (the LARGEST single-field
   pixel effect measured anywhere in this app's RAW-native work so far),
   `detailAmount` at `3.0` → `180787`.
   Also found and worked around a real SDK documentation bug:
   `moireReductionAmount`'s own header comment says "3 indicates
   maximum" but declares its range as `0...1` — almost certainly a
   copy-paste artifact from the adjacent `detailAmount` comment (which
   genuinely has range `0...3`). Measured, not trusted: the property
   genuinely accepts and retains `0...3` with no clamping, but the
   effect saturates hard above `1.0` (delta grew only ~3% across the
   entire `1.0→3.0` span) — so `rawMoireReductionAdjust`'s UI-facing
   range is deliberately capped at the measured-useful `-1...1`, while
   the applied RESULT still clamps to the property's true `0...3` range
   — the same "don't expose measured-dead travel" principle already
   established for `boostShadowAmount` in slice 3.
   Reviewer (Opus 5, after the default model hit the account's monthly
   spend limit — same pattern as every prior slice): APPROVE on the
   first pass — correctly built additive from the outset this time, no
   FIX FIRST round needed. The shared `RawAdjustmentSupport` capability-
   gate struct (from slice 5) was extended to all six NR/Sharpness/
   Contrast/Detail/Moiré fields without regressing the three existing
   ones. Two non-blocking notes fixed before commit: a stale doc
   comment on `ImageDocumentModel.currentRawAdjustmentSupport`
   enumerating only "NR/Sharpness" instead of all six gated fields; and
   an explicit doc-comment acknowledgment that the NEGATIVE half of the
   three new sliders is inert on THIS specific camera (native `0.0` is
   the property's own floor) — kept symmetric anyway as camera-generic
   design (a body with a genuinely non-zero native default would have
   real use for it), not a UI call about this camera's own range the
   way the moiré cap was.
   459 tests (12 new). **Fully LIVE-VERIFIED (2026-09-04)**: user
   confirmed the new RAW sliders work on the real D610 library. Along the
   way, user asked whether RAW Contrast should differ from the app's
   EXISTING global `CIColorControls`-based Contrast slider — answered
   from Apple's own SDK documentation (not independently re-verified
   live): `CIRAWFilter.contrastAmount` is explicitly LOCAL/edge-aware
   contrast ("applied to the edges of the image"), architecturally
   closer to this app's existing Clarity slider than to its
   global Contrast slider, despite the "RAW Contrast" label suggesting
   a direct parallel — flagged as a candidate rename (e.g. "RAW Local
   Contrast") if it reads as confusing with more use, not changed this
   pass since it wasn't requested. The RAW Moiré Reduction visibility
   caveat, flagged proactively this time, did not come up as an issue.
   **Deferred to slice 7** (a separate session): `lensCorrectionEnabled`
   (measured UNSUPPORTED on this app's own test camera — do not "fix"
   this omission without re-measuring against whatever camera prompts
   revisiting it), and opting into `CIRAWDecoderVersion9` at runtime via
   `supportedDecoderVersions` on OS versions that offer it — the last
   two items on `CIRAWFilter`'s RAW-native deferred list, everything
   else measured-viable has now shipped. A genuine inverse-geometry
   transform for the WB eyedropper's fast path (so it works regardless
   of crop/straighten/perspective/flip, not just at identity) is a
   separate, explicitly-deferred stretch goal from slice 4 — see that
   slice's own write-up above for why it was scoped out, not forgotten.
   **Slice 7 (`rawDecoderVersionPin`, deterministic RAW decode across OS
   updates) ✅ COMPLETE** (2026-09-04). The user picked this slice via
   AskUserQuestion framed as "`CIRAWDecoderVersion9` opt-in" — live
   measurement before writing any code showed that framing didn't
   actually apply: `supportedDecoderVersions` for a real D610 NEF on this
   system returns only `[6, 7]` (version 9 isn't offered at all here),
   and the SDK header confirms a freshly-constructed filter already
   defaults to the newest available version automatically — there's no
   "opt in to get newer" action to build. Reframed instead as closing the
   determinism gap this file logged all the way back at slice 1: without
   pinning, replaying the same saved edit after a future macOS/Core Image
   update could silently decode a RAW photo differently, the one
   documented exception to this app's own "replaying the same params must
   be deterministic" principle. Confirmed live the setting genuinely
   matters, not cosmetic: switching this camera's decoder from its own
   default (7) to 6 produced a substantial measured pixel delta (57790,
   256×256 region) — a materially different demosaic. Confirmed
   position-independent (unlike `neutralLocation`): setting
   `decoderVersion` before vs. after `boostAmount` produced byte-identical
   output.
   Deliberately no new UI — an 11th RAW-native field
   (`EditState.rawDecoderVersionPin: String = ""`, `""` = not yet
   pinned), but unlike the other ten it isn't a creative/tunable control
   at all, so there's no slider. Captured exactly once by
   `ImageDocumentModel.load(from:)`, only when a RAW photo's restored
   `EditState` still has it empty (a never-opened photo, or a
   pre-slice-7 sidecar predating the field), never overwritten once set.
   Applied in `RawDecoder.applyRawNativeSettings` via a MEMBERSHIP check
   against `filter.supportedDecoderVersions`, not a min/max clamp like
   every other RAW-native field — the SDK header documents that an
   out-of-list assignment produces a nil output image.
   Reviewer (Opus 5, launched with the model override from the start this
   time, not after a spend-limit failure — this session's own established
   workaround): **3 full rounds, FIX FIRST → FIX FIRST → APPROVE**, the
   most rounds any RAW-native slice has needed. Round 1 caught two real
   blocking bugs: the pin was captured only in memory for a photo with a
   PRE-EXISTING sidecar (from before this slice shipped), since the
   `editState` assignment happens inside the `isLoadingPhoto` bracket that
   deliberately suppresses `scheduleSidecarSave()` — defeating the whole
   feature for exactly the photos it mattered most for; fixed by
   persisting immediately via a direct `saveSidecarNow()` call once
   `currentURL` is set, but ONLY when a sidecar already existed (so no new
   folder-access prompt is ever introduced for a genuinely untouched
   photo). And `revertToOriginal()`'s literal `EditState()` cleared the
   pin — unlike `load(from:)`'s write, that commit isn't
   `isLoadingPhoto`-guarded, so revert both wrote an unpinned sidecar AND
   immediately re-decoded with "whatever's newest now," silently
   reintroducing the exact non-determinism this field exists to close;
   fixed by carrying the pin forward across revert instead of resetting
   it — the one RAW-native field revert does NOT clear.
   Round 2 caught a real bug the round-1 fixes themselves introduced:
   carrying the pin through both load and revert means a RAW photo's
   `editState` never again equals literal `.identity`, so
   `ContentView`'s "Revert to Original" button — gated on
   `editState == .identity` — read as permanently ENABLED for every RAW
   photo, including a never-touched one. Fixed with a new
   `EditState.isEffectivelyIdentity` (copies self, clears only
   `rawDecoderVersionPin`, compares to `.identity`) — every "is this
   photo edited?" call site must use this, not a bare identity
   comparison, once a RAW photo always carries a pin. Deliberately did
   NOT apply the same fix to `ThumbnailGenerator`'s own `!= .identity`
   fast-path check: that path intentionally decodes UNPINNED, so making
   it pin-insensitive would desync the grid thumbnail's decoder version
   from the Editor's — left as a documented, non-blocking perf nit
   instead. Also took a non-blocking suggestion: `saveSidecarNow()`
   gained a `suppressErrorMessage` parameter (default `false`, only the
   backfill call opts in), so opening a never-edited RAW photo on a
   read-only volume doesn't surface "Couldn't save edits" from merely
   viewing it.
   465 tests (11 new). **Fully LIVE-VERIFIED (2026-09-04)**: user confirmed
   a fresh edit correctly pins `rawDecoderVersionPin: "7"` in the sidecar;
   Revert to Original preserves the pin and correctly returns to disabled;
   and — the direct test of the round-1 fix — a photo edited in a prior
   session, with no pin key yet, got backfilled with the pin from merely
   being opened, no edit required. A separate, unrelated sidecar-save
   flake ("Couldn't save edits" not self-healing on an immediate retry
   within the same process, unlike the similar Phase-5-era flake) surfaced
   mid-pass; investigated with temporary diagnostic logging, then resolved
   itself via a genuinely fresh process launch before the logging was even
   needed — logging fully reverted, no code change shipped for it. See
   PROGRESS.md's own slice-7 section for full detail. **Phase 6's
   RAW-native work (all ten measured-viable `CIRAWFilter` controls plus
   this determinism fix) is now functionally complete for this camera** —
   only `lensCorrectionEnabled` (measured unsupported here) and the WB
   eyedropper's beyond-identity-geometry stretch goal remain, both
   deliberately deferred pending different circumstances, not blocking.
7. Local Adjustments (Masking) — **✅ FULLY COMPLETE (2026-09-15).** The single
   biggest capability gap versus Lightroom (see the Lightroom gap-analysis
   subsection above, which this phase supersedes/formalizes for this one item)
   is now closed: five mask kinds (`.radial`, `.linear`, `.brush`,
   `.luminanceRange`, `.colorRange`), multiple independently-compounding masks
   per photo, and intersect/subtract combining between any two masks — see
   item 6 below for the final slice's own write-up. Every adjustment before
   this phase was global — `EditState` was one flat struct, `EditPipeline.apply`
   one pure whole-image function, zero concept of a spatial mask. Scoped
   2026-09-03 from a dedicated architecture research pass (not guessed) — see
   the two real hazards below, both confirmed non-blocking by the slices that
   followed.

   **Hazard 1 — several existing pipeline stages read the FULL image extent for
   their own geometry**, not just the masked region: Vignette centers on
   `extent.midX/midY`; Clarity/Texture/Sharpen radii scale off
   `min(extent.width, extent.height)`; Red-Eye centers map against `extent`.
   Running a masked adjustment by CROPPING to the mask's bounding box first and
   running `EditPipeline.apply` on the crop would silently compute WRONG
   absolute radii/centers for any of these stages if the masked subset ever
   includes them. The correct approach (confirmed architecturally sound):
   run the adjustment subset against the FULL, untouched image extent — same
   as the main pipeline always has — then confine the RESULT to the mask
   region via a composite, exactly like `EditPipeline.applyRedEye` already does
   (`CIRadialGradient` → mask → `CIBlendWithMask`, `EditPipeline.swift:843-891`)
   — that stage is the closest existing precedent for "compute a spatial mask,
   apply one effect, composite by mask" and should be studied directly before
   designing the general case.

   **Hazard 2 — corrected 2026-09-08, was stale.** This paragraph originally
   (2026-09-03) claimed "zero per-frame caching exists anywhere in the render
   path." That's no longer true: P3 (an `EditState`-keyed pipeline-output
   cache, `ImageRenderer.swift`'s `cachedEditState`/`cachedEdited`/
   `cachedOriginalState`/`cachedOriginal`, shipped 2026-09-04) and P2 (an
   interactive downscaled proxy that engages on the 2nd+ consecutive
   `editState` change during a drag, shipped 2026-09-07) both landed after
   this hazard was written, and the paragraph's own `ImageRenderer.swift:114`/
   `:165` line-number citations now land inside unrelated comment text. The
   real remaining unknown was narrower than originally framed: not "does any
   caching exist" but "what does one additional mask-composite pass cost ON
   TOP OF the P3 cache and P2 proxy that already exist." Slice 1 (below)
   answered this with a live measurement rather than further analysis.

   **Slicing** (each its own Plan Mode session; stop and reassess after slice 1
   if the numbers are bad):
   1. **Performance probe, not a shipped feature.** One hardcoded radial mask
      (fixed center/radius, no UI, no persisted `EditState` field), ONE
      adjustable parameter routed through it, applied via the Red-Eye-style
      mask-then-composite approach above. Measure real per-frame cost on a
      large JPEG AND a materialized RAW buffer on real hardware. This is the
      direct analog of Phase 6 slice 2's `isLensCorrectionSupported` probe —
      retire the biggest unknown empirically before committing further design.
      If the numbers are bad, the next steps are architectural (e.g. caching
      unchanged masked layers between frames, downscaling live preview,
      throttling to a lower live-preview quality with full-quality only at
      export) — decide then, don't pre-solve a problem not yet confirmed real.
      **✅ COMPLETE (2026-09-08) — GO.** Live-measured on real hardware
      following this codebase's own established `CFAbsoluteTimeGetCurrent()`
      probe-and-fully-revert methodology (P2/P3/P4/P5's precedent) — a
      temporary `applyMaskProbe` stage (structurally identical to
      `applyRedEye`'s mask-then-composite shape, reusing the existing
      `exposureEV` field as its one "adjustable parameter" so the P3 cache
      key stayed valid) was added to `EditPipeline.apply`, exercised live via
      synthetic mouse drags on the real Exposure `ThinSlider` (user-authorized
      for this one task), then fully removed — confirmed via a clean
      `git diff` — before this doc-only commit. Two real assets: a 20.7MP
      JPEG (`IMG_6564.jpeg`) and a 24MP Nikon D610 RAW (`DSC_1665.NEF`,
      `RawDecoder.materialize`'s cached buffer), same 2268×1385 drawable both
      times. Measured per-frame `draw(in:)` cost, mask ON vs. OFF:
        - **Interactive proxy frames (P2 engaged, 2nd+ consecutive drag
          step):** ~0.33–0.4ms baseline on both assets; ~0.34–0.65ms with the
          mask composite added. Delta near the noise floor — the downscaled
          proxy makes one extra composite pass essentially free.
        - **Full-resolution frames (first/last drag step, or any isolated
          non-consecutive edit — P2 does NOT engage):** JPEG baseline
          ~0.35–0.65ms vs. ~1.07–1.59ms with the mask (delta ~0.6–1.0ms). RAW
          baseline ~0.89–1.38ms vs. ~0.98–1.38ms with the mask (delta near
          the noise floor — RAW's own already-heavier per-frame cost, even
          from the cached materialized buffer, appears to dwarf one added
          composite pass at this resolution). A key architectural finding
          along the way, confirmed live rather than assumed: `CIContext`'s
          lazy evaluation means a composite pass's cost scales with the
          DRAWABLE/display resolution, not the source image's megapixel
          count — the 24MP RAW and 20.7MP JPEG showed statistically
          indistinguishable mask-pass costs at the same window size, so the
          original "large JPEG" sizing concern is less severe than it looked
          architecturally, for non-RAW images at least.
      All measured numbers, including the worst case (~1.6ms for one mask on
      a full-resolution non-proxied JPEG frame), sit far under the 16ms/60fps
      budget P2/P3/P5 already use as this codebase's bar — even a handful of
      simultaneous masks would need to roughly 10x this cost before becoming
      a framerate risk. **Slice 2 (the real mask data model) is architecturally
      cleared to proceed** on the existing P2/P3 caching foundation, with no
      speculative mitigation (caching masked layers, downscaling, throttling)
      needed before starting it — revisit only if slice 2's real N-mask
      compositing measures differently from this single-mask probe.
   2. **Mask data model + Radial mask (no combining) ✅ COMPLETE — both the
      data-model/pipeline half (Session A, 2026-09-09) and the UI half
      (Session B, 2026-09-09).** Session A shipped a new `Mask` type
      (`Sources/EditEngine/Mask.swift`) — NOT the full `EditState` (which
      turned out to be 69 stored fields, not the roadmap's stale "59-field"
      estimate above); the curated 8-param set the user confirmed:
      Exposure, Contrast, Highlights, Shadows, Clarity, Saturation,
      Temperature, Tint. Schema-tolerant `Codable` following `EditState`'s
      own `decodeIfPresent ?? default` pattern, in a hand-written extension
      one level down (the first nested type in this codebase to need that
      treatment — `RedEyePoint`/`RawNeutralPoint` both get away with
      synthesized `Codable`). `EditState` gains `masks: [Mask]` — a second
      variable-length field alongside `redEyePoints`, a bigger step up:
      each mask owns its OWN full parameter set, unlike `redEyePoints`' "N
      points sharing ONE shared param pair" shape. New
      `Sources/EditEngine/RadialMaskGeometry.swift` (pure, `CoreGraphics`-
      only, mirrors `CropAspectMath`'s "real math gets unit tests" role) is
      the ellipse-via-affine-transform math (`CIRadialGradient` is
      circle-only) feeding a new `EditPipeline.applyMasks` stage inserted
      between Red-Eye and Vignette. **Scope deviation from this roadmap's
      own text, confirmed deliberate, not drift**: this slice ships
      MULTIPLE simultaneous masks per photo (sequential, compounding —
      deliberately unlike Red-Eye's union-then-correct-once), pulling that
      part of item 6 below forward; only INTERSECT/SUBTRACT boolean
      combining semantics remain in slice 6.
      Session A reviewer (Opus 5): 3 rounds — FIX FIRST → APPROVE → a clean final
      APPROVE after addressing every non-blocking nit too, not just the
      required fixes. Round 1 caught a real correctness bug: unclamped
      mask Contrast/Shadows/Highlights/Saturation/Tint could drive
      `CIColorControls`'s factor negative and invert hue/channels — this
      slice ships with no UI, so a hand-authored sidecar was the only
      input path and nothing else bounded these values; fixed by reusing
      the same `clamped(_:to:)` helper the global path's own
      `effectiveTone(_:)` already uses. Also caught: a factually backwards
      doc-comment claim that `radiusX`/`radiusY`'s different denominators
      "keep a circle a circle" (they don't — equal fractions draw an
      ellipse matching the extent's own aspect ratio); a tautological
      order-check test that would have passed regardless of where
      `applyMasks` actually ran in the pipeline; two fully redundant
      no-op tests. Round 2 (after those fixes) found a live perf
      optimization opportunity — `corrected` (the per-mask correction
      result) is now cropped to the ellipse's own bounding box right
      before the blend, verified byte-identical (max diff 0.0 across 5
      configs including rotated/off-image ellipses) since the mask is
      exactly 0 outside that region anyway — plus a `!state.blackAndWhite`
      gate so a mask's Temperature/Tint can't repaint color into an
      already-desaturated B&W render, and a deterministic (not
      random-per-decode) fallback for a mask's `id` when a sidecar is
      missing one. 631 tests (166 new): the mask math is almost entirely
      EQUIVALENCE-tested against the identically-valued global slider
      (masking the whole frame and comparing pixels) rather than
      hand-derived magic numbers — a stronger, self-verifying guarantee,
      with real measured numbers reserved for genuinely spatial claims
      (soft-edge falloff, rotation, the y-down convention), matching this
      file's own Red-Eye/Vignette precedent.
      **Live-measured perf (required by this roadmap's own slice-1
      conditional above — "revisit only if slice 2's real N-mask
      compositing measures differently from this single-mask probe," and
      it does)**: 3 masks with Clarity active, same probe-and-fully-revert
      methodology as slice 1, on the same two real assets. JPEG stays
      comfortably under the 16ms/60fps budget at every frame type (~5-6ms
      proxied, ~3.6-8.3ms full-res). **RAW does NOT**: full-resolution
      frames measured ~15-21ms — at/slightly over budget — a real,
      substantial cost versus RAW's own ~0.4-1.7ms masks-off baseline,
      confirming Hazard-class concern the roadmap flagged rather than a
      false alarm. Root cause: each mask's Clarity pays a full-image
      `CIUnsharpMask` pass; the ROI-cropping optimization above narrows
      this to each mask's own bounding box, but RAW's already-heavy
      per-frame baseline (even from `RawDecoder.materialize`'s cached
      buffer) means 3 such passes still add up. Accepted as a known,
      documented finding for this slice rather than blocking it — see
      PROGRESS.md's own write-up for the full numbers and the case for a
      future targeted mitigation (e.g. skip Clarity specifically on the
      interactive RAW path) if this proves to matter in practice once a
      UI exists to create masks at all.

      **Session B (UI half) ✅ COMPLETE** (2026-09-09). Masks are now
      reachable from the app itself: a new "Masks" `AdjustSectionContainer`
      (between Red-Eye and RAW) with an "Add Radial Mask" button, a
      "Mask N" list (add/select/delete, `presetsSection`'s exact shape),
      and a 14-slider detail view (`Sources/UI/MaskDetailView.swift`) for
      the selected mask's 8 tone/color params plus 6 shape params (Center
      X/Y, Radius X/Y, Rotation, Feather) — the 14 rows are the
      accessibility answer, the same reasoning `CropOverlayView` already
      established: they let the on-image overlay be
      `.accessibilityHidden(true)` since every draggable value is
      independently AT-adjustable. New `Sources/UI/MaskGeometry.swift`
      (pure, `CoreGraphics`-only, 22 tests in
      `Tests/EditEngineTests/MaskGeometryTests.swift`) is the UI-side
      INVERSE-geometry sibling `RadialMaskGeometry.swift`'s own doc
      comment reserved for this session — screen-drag math, not the
      forward render transform — reusing `RadialMaskGeometry.resolve`'s
      exact rotation convention (verified by a cross-check test hand-
      confirmed by the reviewer to agree numerically across the y-flip).
      New `Sources/UI/MaskBinding.swift` (`Binding<EditState>.mask(id:)`)
      resolves a mask by IDENTITY on every access, never a captured array
      index — the setter silently no-ops if the mask was deleted
      mid-drag, exactly the same shape `CropOverlayView`'s baseline-drag
      pattern already established. New `Sources/UI/MaskOverlayView.swift`
      renders 4 resize handles (one per radius, symmetric about a
      stationary center — not Crop's opposite-corner anchoring, since the
      data model is one center + two independent radii) plus an interior
      move region and a dashed feather guide reusing
      `RadialMaskGeometry.innerRadiusFraction(feather:)` directly so the
      guide can never drift from what's actually solid. Rotation is
      slider-only in v1 (no drag handle — no rotation-gesture precedent
      exists anywhere in this app), but the 4 resize handles still sit on
      the ROTATED ellipse via `MaskGeometry`, so a future rotation handle
      is purely additive.
      `ContentView.swift` wires a new `isEditingMask` computed property
      (resolved live against `document.editState.masks`, self-healing if
      Undo/Revert/Apply-Preset deletes the selected mask out from under
      any disarm site) into `canZoom`'s existing gate (Crop/WB/Red-Eye
      precedent), a new overlay branch in `pointAndZoomOverlays`, and an
      Escape handler; the WB and Red-Eye arm buttons in `AdjustTabView`
      were each extended one line to also clear `selectedMaskID`, the
      same disarm-at-arm-site pattern those two already used on each
      other. Compare deliberately stays ENABLED with a mask selected
      (only the overlay/detail panel clears) — the best way to see what a
      mask actually did.
      Reviewer (Opus 5): 2 rounds, FIX FIRST → APPROVE, both non-blocking
      on the second pass. Round 1: no non-finite guard on the overlay (a
      hand-edited/corrupt sidecar's NaN would hit `.position()` directly,
      unlike the render side's own `resolve` which safely returns `nil`);
      misleading/circular geometry-test comments and a missing render-side
      cross-check; no-op writes on a click-without-movement and redundant
      dual radius writes; "Add Radial Mask" not disabled without a loaded
      photo; collapsing the Masks section left a mode armed; missing
      mask-editing accessibility label; an unused `CaseIterable`
      conformance; a feather-threshold magic number duplicating
      `RadialMaskGeometry.minimumFeather` instead of reusing it — all
      fixed. Round 2 (after those fixes) caught one real bug: the shared
      `onEnterPointPickingMode` callback only grabbed image-pane focus
      inside `AdjustTabView`'s WB/Red-Eye arm sites, not for Mask
      selection, and clicking an ALREADY-selected "Mask N" row doesn't
      change `selectedMaskID` — so the rising-edge-only
      `.onChange(of: adjustPanel.selectedMaskID)` focus grab would never
      fire, leaving Escape unreachable if focus had drifted elsewhere;
      fixed by making the callback grab focus unconditionally. 653 tests
      (22 new, all in `MaskGeometryTests`; every other new file is
      SwiftUI interaction glue with no unit-test precedent in this
      codebase, per its own "geometry gets tests, gesture composition
      gets live verification" convention).
      **Live-verified (2026-09-09)** against the user's real Bolivia-trip
      library (`IMG_6564.jpeg`, a landscape group photo, and a separate
      portrait car-interior JPEG, both real JPEG assets): added
      multiple masks with only the selected one showing handles; dragged
      all 4 resize handles confirming symmetric resize about a stationary
      center on both a landscape AND a non-square (portrait) `fitRect`;
      set Rotation to +30° with unequal radii and confirmed the drawn
      outline, the RENDERED soft ellipse, and all 4 handles rotate
      together in the same direction; dragged the interior to an edge
      and confirmed Center X clamps at 0% while the ellipse is free to
      overhang the image; swept Feather and confirmed the dashed guide
      tracks the solid region; dragged a handle then ⌘Z'd and confirmed
      the WHOLE drag undoes as one step; typed into one mask's Exposure
      field without committing, clicked a different mask's row, and
      confirmed neither mask absorbed the stray value (the `.id(id)`
      view-identity fix works); confirmed Crop and the WB eyedropper both
      disarm an active mask selection; confirmed mask selection survives
      a Library round-trip (by design — only Crop/WB/Red-Eye/Compare/
      photo-switch/tab-switch clear it) and that Escape still reaches and
      deselects it afterward; used Compare → Split and confirmed the
      "before" side shows zero mask effect while "after" shows it exactly
      confined to the ellipse, then dragged the split divider to confirm
      the effect appears only past it; used Revert to Original to
      confirm it cleanly clears masks back to "No masks yet." Not
      independently live-exercised this session (accepted on code-review
      strength instead): literally-concurrent delete-during-drag (a
      single input device cannot drive two simultaneous mouse-downs, so
      this is covered by the reviewed `MaskBinding` setter guard, not a
      literal repro); Red-Eye's own arm-button disarm (identical one-line
      diff to the WB button, which WAS live-verified); and a JPEG export
      round-trip through a masked photo (this app's export path already
      flows any `EditState` field through unmodified, per Session A's own
      confirmed-no-changes-needed research).
      **Deferred, logged as a follow-up in IMPROVEMENTS.md, not an
      oversight**: arrow-key nudge/resize of the on-image overlay itself.
      Both test photos' masks/sidecars were reverted to identity before
      this commit — the library is unchanged.
   3. **Linear (Graduated) mask — Session A (data model, render geometry,
      pipeline, sliders) ✅ COMPLETE (2026-09-10); Session B (the on-image
      line-drag gesture) code + reviewer-APPROVED + 717 tests green
      (2026-09-11), live-verification still pending — see PROGRESS.md's
      own Session B section for the exact outstanding checklist.**
      Extends the SAME `Mask` struct
      (per that struct's own doc comment reserving exactly this) with a
      new `kind: MaskKind` discriminator (`.radial`/`.linear`) and a new
      `width` field (`.linear`-only — the full guide-to-guide distance),
      reusing `centerX`/`centerY`/`rotationDegrees` unchanged across both
      kinds so there's one shared anchor point and ONE rotation sign
      convention in this struct, not two. New
      `Sources/EditEngine/LinearMaskGeometry.swift` feeds
      `CIFilter.linearGradient()` — the y-flip/rotation-sign math is
      handled by flipping each of the two guide POINTS individually (the
      same `1 - y` formula the center already uses), rather than
      negating the whole angle the way `RadialMaskGeometry` does before
      building its rotation matrix. Reviewer-corrected mid-slice: an
      earlier draft claimed the angle-negation trick was mathematically
      WRONG for a bare direction vector — false; both formulations are
      equivalent and independently re-derived to produce byte-identical
      points. The per-point flip is used only because it mirrors the
      center's own existing `1 - y` line-for-line, keeping ONE flip idiom
      in this file instead of mixing it with an angle-negation idiom for
      the same quantity — a code-clarity choice, not a correctness fix.
      A too-small `width` CLAMPS to `LinearMaskGeometry.minimumWidth`
      (fixed mid-slice to clamp the PIXEL half-width, not the fractional
      input — the original clamp still let a small enough EXTENT, e.g. a
      Library thumbnail, silently drop the whole mask) rather than
      skipping it entirely (unlike a too-small radial radius, which does
      skip) — a zero-width linear mask is a legitimate hard-edged
      half-plane split, a real deliberate look, not "nothing."
      `EditPipeline.applyMasks`'s single geometry-resolve call became a
      `switch mask.kind`, with the `.linear` branch needing no transparent-
      base/union step the `.radial` branch requires (MEASURED, not
      assumed: `CILinearGradient` clamps to `color0`/`color1` beyond each
      point rather than being undefined there, unlike a radial gradient
      outside its own bounding disc). Fixed a real decode hazard along the
      way: `MaskKind` is a `String`-raw-value enum, and naively decoding
      it via `decodeIfPresent(MaskKind.self, forKey:)` throws — not
      returns `nil` — on an unrecognized-but-present value, which (since
      every sidecar reader in this app wraps the whole `EditState` decode
      in `try?`) would have silently discarded an ENTIRE sidecar's worth
      of edits the moment a future slice adds a third kind; fixed by
      decoding the raw string by hand with a `.radial` fallback.
      Reviewer (Opus 5): 3 rounds, FIX FIRST → FIX FIRST → APPROVE — see
      PROGRESS.md's own slice-3 Session A section for the round-by-round
      detail, including round 2's catch that some of round 1's own
      documentation fixes were incomplete (a stale claim survived outside
      the one file round 1 touched) and a real behavioral regression the
      round-1 `canZoom` fix introduced (arrow-key pan silently broken for
      a selected Linear mask). 701 tests (48 new). Live-verified
      against the user's real library: the 0°/90°/180° sign checks all
      matched the geometry's own predicted compass directions exactly
      (this is the single highest-risk claim in the slice, given this
      codebase's documented y-flip/sign-bug history — Metal, Compare
      split); Width 0%→100% swept from a clean hard edge to a gradual
      ramp with no artifacts; mask creation on a non-square portrait photo
      didn't crash. Required RAW perf re-check (deferred from slice 2
      until masks were reachable): one Linear mask with Clarity on the
      user's real RAW asset measured ~0.6-1.0ms over baseline at
      steady state, comfortably under budget.
      **Session B (the draggable center line + two draggable parallel
      guide handles, reusing `MaskGeometry.movedCenter` verbatim for the
      center drag — genuinely new interaction code, no existing
      precedent covers a rotatable line-with-parallel-guides gesture)**
      shipped 2026-09-11: new `Sources/UI/LinearMaskOverlayView.swift`
      plus `MaskGeometry.linearGuidePoint`/`resizedWidth`/
      `guideLineLength`, `ContentView.swift`'s overlay site becoming a
      `switch mask.kind`, and deletion of the Session-A-introduced
      `isEditingRadialMask` carve-out now that both mask kinds have their
      own overlay (`canZoom` reverted to the simpler kind-agnostic
      `isEditingMask` gate). **Reviewer (Opus 5): 6 rounds — the most of
      any Phase 7 slice** — 2 rounds of genuine SwiftUI-layout bugs
      invisible to unit tests, caught only because the reviewer started
      ACTUALLY RENDERING the view code rather than just reading it (a
      bare-`Path`-ignores-`.frame()` bug, and an insufficient guide-line
      length); a documentation-accuracy bug in my own IMPROVEMENTS.md
      (a "known issue" logged without tracing the code first, itself
      factually wrong); and 2 more rounds on my own post-approval polish,
      which twice introduced the same class of unverified-claim error it
      was meant to fix, before a clean APPROVE. Full round-by-round detail
      in PROGRESS.md's own Session B section — worth reading before
      touching this feature again, since several of its lessons
      (measure/render before asserting, re-verify claims after "just a
      doc fix") aren't obvious from the code alone. 717 tests (16 new).
      **Live-verified (2026-09-11/12), all 11 points passed, zero code
      changes needed** — driven via screen automation across two real
      assets (landscape + portrait): center-line drag, guide-handle drag
      at 0°/45°, portrait repeat, edge clamping, undo-as-one-step,
      cross-mask isolation, Crop/WB/RedEye/Compare disarm, and
      Radial-vs-Linear overlay selection all confirmed directly; Revert
      to Original was cross-checked against the on-disk sidecar, not
      just the UI. Zoom-blocked was confirmed by reading `canZoom`
      directly (`Sources/UI/ContentView.swift:98-101` — the reviewed,
      kind-agnostic `!isEditingMask` gate) rather than interactively,
      since synthetic scroll-wheel events couldn't be made to reach
      `ImageRenderer`'s local `NSEvent` monitor in this environment —
      see PROGRESS.md's own write-up for the automation-environment
      notes (HiDPI coordinate scaling, the scroll-event limitation)
      worth knowing before the next screen-automation session on this
      machine. **Phase 7 slice 3 is now fully complete.**
   4. **Brush mask (freehand painting) ✅ COMPLETE** (2026-09-13). The
      hardest UI slice, confirmed while scoping it: unlike Radial/Linear
      (which ship a default-visible shape immediately adjustable via
      sliders before any drag gesture exists), a Brush mask starts
      completely empty, so this shipped as ONE session, gesture included
      — no data-model/gesture split the way slice 3 had. Confirmed via
      `AskUserQuestion`: painting is continuous drag-to-paint (a real
      brush feel), reusing `ImageDocumentModel`'s existing ~350ms
      undo-coalescing debounce as-is — an accepted, documented gap (a
      stroke paused >350ms mid-drag splits into two undo steps), not
      solved this slice.
      `MaskKind` gains `.brush`, reading a new flat `brushPoints:
      [BrushPoint]` (mirrors `RedEyePoint`'s shape/convention) plus
      `brushSize` (dab radius, same non-axis-specific-fraction convention
      `width` already established) — `feather` is REUSED from `.radial`
      rather than adding a new field, now shared across both kinds. One
      Brush mask is exactly one continuous stroke; painting a second area
      means adding another Brush mask, since masks already compound
      sequentially for free (slice 2's own scope decision). New
      `Sources/EditEngine/BrushMaskGeometry.swift` is pure
      `CoreGraphics`-only sizing/rect math (mirrors `RadialMaskGeometry`/
      `LinearMaskGeometry`'s own split from `EditPipeline`) — its own
      documented correction (F1, named after `LinearMaskGeometry`'s
      identical real bug): a too-small brush size CLAMPS to a pixel floor
      rather than making the mask disappear on a small extent (e.g. a
      Library thumbnail), the same trap `width` already hit once.
      `EditPipeline.applyMasks`'s `.brush` branch rasterizes the stroke
      into a small, padded `CGContext` bitmap (stroked with round
      caps/joins; a single point fills a circle instead) — sized to the
      stroke's own bounding box, never the full extent — then softens it
      with `CIGaussianBlur`, reusing no new Core Image filter beyond that.
      Two corrections baked in from the start, not discovered by a
      reviewer: no `.clampedToExtent()` before the blur (fails OPEN —
      flooding the whole frame — if padding is ever insufficient, whereas
      skipping it merely clips an already-negligible feather tail); the
      rasterized bitmap loads via `CIImage(cgImage:options:
      [.colorSpace: NSNull()])` so Core Image performs no color
      management on it, preserving the RGB==alpha co-variance the
      `.radial`/`.linear` branches' gradients already rely on implicitly.
      New UI: `Sources/UI/BrushMaskOverlayView.swift` (the LIVE
      in-progress stroke only — no on-image handles once painting ends,
      a deliberate v1 cut) and `MaskDetailView`'s Brush shape rows
      (Size/Feather sliders, a "Paint Stroke"/"Redraw Stroke" button —
      label depends on whether a stroke exists yet). `AdjustTabView`'s
      two pre-existing mask-icon/label ternaries (`.radial ? X : Y`)
      became exhaustive `switch`es as part of this slice — they compiled
      fine against a third case and would have silently mislabeled every
      Brush mask as Linear. `ContentView` tracks a new
      `brushPaintingMaskID: UUID?` (not `Bool` — the falling-edge cleanup
      needs to name the OLD id after selection has already moved on);
      ONE `.onChange` handler on it is the single place every disarm
      route (Escape, natural stroke end, tab/photo switch, Compare, WB,
      Red-Eye, selecting another mask, collapsing the Masks section)
      funnels through to delete a never-painted mask, rather than each
      site separately remembering to.
      Live-measured perf (same methodology as slices 1/2): one brush mask
      with Clarity stays comfortably under the 16ms/60fps budget on both
      a real JPEG and the user's real RAW asset, full-res and proxied
      (worst case ~2ms over baseline). Three simultaneous brush masks
      with Clarity reproduce the SAME known, already-documented RAW
      finding slice 2 recorded for Radial/Linear (full-resolution,
      non-interactive RAW frames exceed budget under multiple
      Clarity-bearing masks) — measured somewhat higher for Brush
      (~34ms) than the ~15-21ms slice 2 measured for Radial/Linear,
      plausibly because each Brush mask also pays its own CGContext
      rasterization + blur pass on top of Clarity's cost — accepted as
      the same documented, non-blocking limitation, not fixed this slice
      (the interactive/proxied path, what a user actually drags against,
      stays fast in every configuration measured).
      Reviewer (Opus 5): 4 rounds — FIX FIRST → FIX FIRST → FIX FIRST →
      APPROVE, the most of any Phase 7 slice, all verified empirically
      (built, ran the suite, wrote standalone probes rendering
      `BrushMaskOverlayView` offscreen and replaying the rasterizer)
      rather than trusted from the diff. Round 1 caught two real bugs: an
      `.onChange(of: brushPaintingMaskID)`-coalescing gap where "Add
      Brush" while a DIFFERENT unpainted Brush mask was already armed
      leaked that earlier mask forever (SwiftUI collapses two synchronous
      writes — `nil` then the new id — into one `.onChange` call that
      never observes the intermediate `nil`; fixed by discarding on ANY
      id change, not just the falling edge to `nil`); and a
      `maximumPointCount`-guard ordering bug that permanently broke
      "Redraw Stroke" once a stroke hit the point cap. Round 2 caught a
      THIRD real bug: switching PHOTOS while an unpainted Brush mask is
      armed is NOT covered by the central disarm handler (`Image
      DocumentModel.load(from:)` swaps `editState` to the incoming photo
      before `ContentView`'s own cleanup can look up the OLD mask) —
      deliberately left as a documented, accepted gap (`IMPROVEMENTS.md`'s
      new D13) rather than rushing a fix that needs a different mechanism
      shape entirely. Round 3 caught that round 2's own gap-documentation
      had two more accuracy mistakes (an inverted summary sentence, a
      wrong file attribution) — both fixed. Also addressed along the way:
      a measured ~3.9ms eager-rasterization cost per call, now memoized
      via an `NSLock`-guarded single-entry cache keyed on the already-
      `Equatable` `BrushMaskGeometry.Resolved` (documented limitation:
      degrades to near-zero hit rate with 2+ simultaneous brush masks,
      not fixed this slice); a per-stroke `NSCursor` push/pop leak; a
      `feather == 1` doc-comment overstatement (measured: a Gaussian blur
      never reaches alpha 1.0, capping around ~86%/~95%, unlike
      `.radial`'s gradient). 717 tests before this slice; 763 after —
      brush-specific coverage in `BrushMaskGeometryTests` (new) plus
      additions to `MaskGeometryTests`/`EditPipelineTests`/
      `EditStateCodableTests` (F6: repointed an existing test's
      unknown-mask-kind stand-in off the now-real `"brush"` string onto
      `"colorRange"`, slice 5's own future kind; plus default-when-absent,
      malformed-`brushPoints`, round-trip, and deterministic-id tests
      matching slice 3's own precedent).
      **Live-verified**: Add Brush arms immediately and the three
      add-mask buttons don't truncate the sidebar (a real regression from
      adding a third button, caught and fixed live — shortened to
      "Radial"/"Linear"/"Brush" labels, full "Add ___ Mask" wording kept
      in each button's accessibility label); a continuous drag paints a
      smooth stroke landing exactly where painted, including the
      y-flip/top-of-frame check on a real photo; releasing the mouse ends
      paint mode cleanly; one continuous stroke undoes/redoes as ONE
      step; "Add Brush" then Escape with no drag leaves no stray mask in
      the list; switching to the Crop tab while an unpainted stroke is
      armed cleanly discards it; Revert to Original clears masks. Two
      items accepted on code-review + prior-slice-precedent strength
      rather than independently live-exercised this pass: the Brush
      Size/Feather sliders and "Redraw Stroke" button (both unmodified,
      already-shipped `EditSliderRow`/`Button` code paths — reaching them
      needed scrolling the Adjust sidebar past 8 tone/color rows, and
      synthetic scroll events could not be made to reach this app's
      `ScrollView` in this automation environment, the same class of
      limitation slice 3 Session B already documented for scroll-wheel
      zoom); and Compare/Split, Library-thumbnail refresh, and JPEG
      export round-trip (all pre-existing, kind-agnostic code paths per
      slice 2 Session A's own confirmed-no-changes-needed research, not
      touched by this slice at all).
   5. **Color Range / Luminance Range masks** — computed from image
      statistics (pick a color/tone, auto-generate a mask from similarity),
      not manually drawn at all — closer in spirit to the existing "Fix Color
      Cast" auto-analysis button (`ImageDocumentModel.fixColorCast()`,
      whole-image gray-world stats) than to slices 2-4's shape-drawing.
      **Luminance Range half ✅ COMPLETE (2026-09-14)** — the first
      CONTENT-DERIVED mask kind (`MaskKind.luminanceRange`), selecting by
      tone rather than drawn geometry, judged in scene-linear light via a
      new pure `LuminanceRangeSelection` type (tone→linear sRGB-EOTF
      mapping) feeding a `CIColorMatrix`(luma)→two clamped tone-ramp
      `CIColorMatrix`/`CIColorClamp` pairs→`CIMinimumCompositing`
      (exact trapezoid)→`CIMaskToAlpha` chain in `EditPipeline.applyMasks`
      — no custom kernel needed, built-ins sufficient. `feather` reused a
      third time (after `.radial`/`.brush`) for its transferable meaning.
      Measured, not assumed: `CIColorMatrix`'s output extent is NOT
      naturally finite even given finite input (confirmed on a real
      20.7MP JPEG), so this kind's explicit `.cropped(to: extent)` is
      load-bearing, unlike `.linear`/`.brush`'s naturally-finite chains.
      This slice also fixed `ContentView`'s kind-agnostic `isEditingMask`/
      `canZoom` gate (a new `hasOnImageOverlay(_:)` check) so a mask kind
      with no on-image overlay no longer blocks zoom/pan or steals focus
      merely by being selected — `AdjustTabView`'s 3-button mask-kind row
      became a 2×2 grid to fit a 4th button. Perf measured small
      (JPEG +0.45ms, RAW +1.18ms vs. no-mask baseline, both well under the
      16ms/60fps budget, no ROI-crop possible for this kind by
      construction). Live-verified on the user's real library via
      accessibility actions (`AXPress`/`AXIncrement`) rather than
      synthetic mouse clicks — this automation environment's synthetic
      `cliclick` events do not reach the app at all (confirmed directly:
      an `AXPress` on a toolbar button worked instantly; a pixel-exact
      `cliclick` at the same location, cursor position confirmed via
      screenshot, did nothing) — a broader version of the scroll-wheel-
      only limitation slice 3 Session B already logged for this machine.
      Confirmed live: tone-targeting genuinely moved the affected region
      (bright snow vs. dark clothing, not just a brightness change);
      Rec.709 luma weights meant the saturated blue sky was correctly
      UNaffected by a highlight-targeted mask despite looking bright to
      the eye; Range/Feather reactive; Radial's on-image overlay still
      shows and correctly hides again when reselecting the Luminance
      Range mask (dynamic, not just at add-time); Revert to Original
      clears cleanly, cross-checked against the on-disk sidecar. See
      PROGRESS.md's own "Phase 7 slice 5" section for full detail,
      including the one test-only bug (not a pipeline bug) found and
      fixed along the way.

      **Color Range half ✅ COMPLETE (2026-09-14).** Pick an exact color
      via eyedropper, generate a soft selection matching pixels similar
      to it (hue + saturation + luminance JOINTLY, in scene-linear
      light — a darker/lighter or more/less saturated version of the
      picked color is treated as less similar), selected via the
      curated 8-param Mask adjustments same as every other kind. One
      combined Tolerance slider (0...1, interpolating all three axes'
      windows together — mirrors `EditState.selectiveColorRange`'s own
      "one slider, many windows" shape), not three per-axis sliders;
      `feather` reused a FOURTH time (after `.radial`/`.brush`/
      `.luminanceRange`), here as the falloff ramp's width directly in
      normalized-distance units rather than a plateau/tent split.

      The project's SECOND custom Core Image kernel
      (`Sources/Rendering/Shaders/ColorRange.cikernel`, after
      `SelectiveColor.cikernel`) — built-ins genuinely can't express a
      joint 3-axis per-pixel color distance. New
      `Sources/EditEngine/ColorRangeSelection.swift` is both the
      tolerance-window resolver (mirrors `LuminanceRangeSelection`'s own
      contract) AND the Swift-side twin of the kernel's per-pixel HSL/
      luma conversion — the single highest-risk correctness surface in
      this slice, since Swift and GLSL must agree bit-for-bit in intent.
      Two corrections baked in over `SelectiveColor.cikernel` (the
      kernel this one's HSL math was modeled on): negative channels
      clamped to 0 BEFORE headroom-normalizing (that older kernel never
      clamps negatives — logged as its own follow-up, not touched here),
      and a FLOORED modulo (not Swift's symmetric `truncatingRemainder`)
      on the max-red hue branch — GLSL's `mod()` is floored, and without
      correcting this every magenta-side red pixel would disagree
      between the two implementations. Measured, not assumed: a
      throwaway probe (`TempColorRangeProbeTests.swift`, deleted before
      commit — the established `TempLuminanceRangeProbeTests.swift`
      precedent) confirmed the kernel compiles, solid-patch selection at/
      away from target, hue wraparound, headroom selection, and a
      12-color Swift/GLSL agreement sweep (worst measured delta 1.73e-7,
      re-confirmed at 16 colors during reviewer re-verification) — and
      that unlike `.luminanceRange`'s own forced-opaque-alpha-bias
      infinite-extent trap, this kernel's output extent is genuinely
      finite and exactly the requested `extent:`, so its own
      `.cropped(to:)` is structural consistency only, not load-bearing.

      `ImageDocumentModel.pickColorRangeTarget(maskID:normalizedX:normalizedY:)`
      is architecturally distinct from `pickWhiteBalance`: no RAW fast
      path (no decoder-level equivalent for a per-mask target), no
      `Task.detached`/solver (one closed-form HSL conversion,
      microseconds), and — the one genuinely novel piece — it samples
      the image `ColorRange.cikernel` will ACTUALLY compare against
      inside `applyMasks`, not the naive fully-edited display: zeroes
      `vignetteStrength`/`dehaze`/`clarity`/`texture`/`noiseReduction`/
      `sharpness` (every stage that runs AFTER `applyMasks` in the fixed
      pipeline order — `definition` here predated the texture/clarity
      split, and Dehaze was added later still; keep this list in sync with
      `ImageDocumentModel.pickColorRangeTarget`, its source twin) and truncates `masks` to only those BEFORE the target mask,
      then renders exactly that truncated state — structurally
      guaranteed correct (both the sampler and `applyMasks`'s own loop
      read the identical array prefix through the identical earlier
      stages), independently re-derived and confirmed by the reviewer,
      not just asserted.

      UI: `AdjustTabView`'s 2x2 mask-kind grid gained a third row (one
      half-width "Color" button + an explicit empty cell, not a bare
      full-width button — matches that section's own "would read as a
      different class of action" convention); `ContentView` gained a
      `colorPickingMaskID: UUID?` state (mirrors `brushPaintingMaskID`'s
      `UUID?`-not-`Bool` shape) driving a new eyedropper tap-capture
      layer (byte-for-byte the same `Color.clear`/crosshair-cursor/
      `SpatialTapGesture` shape as the WB eyedropper's own, but resolves
      its target mask by IDENTITY at commit time, mirroring
      `MaskBinding`'s own discipline) and a `discardUnpickedColorRangeMask`
      falling-edge cleanup (the `.brush`/F4 pattern: `oldID != newID`,
      not falling-edge-to-`nil`, to survive the same
      `addMask -> select -> beginColorPick` SwiftUI-coalescing hazard
      slice 4's reviewer caught once already). This is the 5th
      hand-rolled mutual-exclusion site (after WB/Red-Eye/`select(_:)`/
      `beginBrushStroke`) — logged in IMPROVEMENTS.md's D14 that a
      shared mode enum is now genuinely worth it, not built this slice.
      `MaskDetailView` gained a "Pick Color"/"Re-pick Color" button
      (mirrors `.brush`'s "Paint Stroke"/"Redraw Stroke"), a swatch
      reconstructed via `ColorRangeSelection.displaySRGB` (never a
      redundant 4th/5th/6th stored RGB field) plus a perceptual-tone text
      readout, and the Tolerance/Feather sliders.

      Reviewer (Opus 5, per this session's standing convention): **2
      rounds, FIX FIRST → APPROVE.** Round 1 caught 3 blocking issues,
      all fixed: (1) `MaskDetailView`'s tone-percent `Int(...)` cast had
      no guard against `ColorRangeSelection.tone(forLinearLuminance:)`'s
      deliberately-unclamped output — a hand-edited sidecar's `.nan` or
      astronomically large `colorRangeTargetLuminance` would CRASH the
      app the moment that mask was merely selected, not just misrender
      (the identical defect CLASS slice 2 Session B's reviewer already
      caught once for the on-image overlay) — fixed with an `.isFinite`
      check plus a ±1,000,000 clamp before the cast. (2)
      `ColorRangeSelection.displaySRGB` had NO non-finite guard at all
      (unlike `resolve`'s own `nil` return) and didn't wrap hue into
      0..<360 the way `resolve` does — a corrupt sidecar's `.nan`
      propagated straight into a SwiftUI `Color`, and an out-of-range
      hue (e.g. a hand-edited `-400`) fed the unwrapped HSL→RGB
      conversion's wrong branch, producing a swatch inconsistent with
      the hue the kernel actually selects on — fixed with a guard + the
      same wrap, two new regression tests added. (3) an `EditPipelineTests`
      comment wrongly claimed a +4EV brighten mask leaves hue/saturation
      UNCHANGED (citing a test that only demonstrates scale-invariance
      WITHIN one headroom regime, not across the boundary this test's
      own colors actually cross) — reviewer independently re-derived the
      real numbers (hue fixed at 276°, saturation shifts 0.614 -> 1.0)
      and the comment (plus a new clarifying paragraph on
      `ColorRangeSelection.hueSaturation`'s own doc comment) was
      corrected to match; the test's own assertion was never wrong, only
      its stated mechanism. Also fixed from round 1's non-blocking list:
      a silently-deleted-mask failure mode (a failed pixel sample now
      surfaces `whiteBalanceSampleMessage`, reused rather than a new
      property — the same message/alert `pickWhiteBalance` already
      uses), a missing `!isPaintingBrush` guard on the tap-capture layer,
      and a `%d`/line-length nit. Round 2 re-derived all three blocking
      fixes' math independently (confirmed the hue-wrap test genuinely
      distinguishes the old-vs-new branch, not vacuously) and
      re-verified the whole diff holistically (pipeline-order claim,
      y-flip convention, kernel/Swift agreement, deterministic-id
      hashing, non-destructive integrity, thread safety) before
      APPROVE — one more trivial fix (a shared alert's hardcoded "White
      Balance" title, now "Color Sample", since this slice made a third
      caller share it) taken directly from round 2's own non-blocking
      notes, not re-reviewed.

      **Deliberately NOT fixed, accepted, documented in code**: a
      premultiplied-vs-unpremultiplied alpha mismatch between
      `PixelSampler.averageColor` (returns premultiplied values) and
      `ColorRange.cikernel` (unpremultiplies before its own math) — measured
      real but narrow (only affects a tap on a semi-transparent region,
      alpha in `[0.5, 1)`), and fixing it means widening `PixelSampler`'s
      shared, already-reviewed return type that `pickWhiteBalance` also
      uses (same latent gap there, never reported before this slice) — a
      separate future session, not a drive-by edit; the hue axis's
      measured weakness at low/moderate saturation (`ColorRange.cikernel`'s
      `saturationAttenuation = min(hsl.y, target.y)` term) — a tuning
      characteristic, live-verified acceptable on a real photo, not a bug.

      865 tests (32 new in `ColorRangeSelectionTests`, 19 new in
      `EditPipelineTests`, plus `EditStateCodableTests` additions — the
      unrecognized-mask-kind stand-in repointed off the now-real
      `"colorRange"` string onto `"depthRange"`).

      **Fully LIVE-VERIFIED (2026-09-14)**, via AX-driven automation
      (`AXPress`/`AXIncrement`/direct `AXScrollBar` positioning — this
      machine's own established "synthetic clicks don't reach this app,
      AX actions do" constraint, same as slice 5's first half) plus ONE
      real user click for the eyedropper tap itself (no AX affordance,
      the same accepted limitation IMPROVEMENTS.md's D14 now names): on
      the user's real Bolivia-trip library (`IMG_6414.jpeg`, a car-
      roof-loading scene with clear blue sky), confirmed the Masks
      section's 2x2+1 grid renders with the new "Color" button; adding a
      mask arms picking and shows "Pick Color"/"No color picked yet"; a
      real click on the blue sky correctly wrote a plausible target
      (readout "Hue 222° Sat 75% Lum 49%", swatch rendered as a matching
      blue circle) and flipped the button to "Re-pick Color"; pushing
      Exposure to +5EV visibly and PRECISELY confined the blowout to the
      sky and its own reflections in the car's rear window/chrome
      (matching color, not matching position — the car body, people, and
      ground stayed completely untouched, a strong live confirmation of
      genuine per-pixel color matching over any geometric proxy); Revert
      to Original cleanly cleared the mask, cross-checked directly
      against the on-disk sidecar (`"masks": []`) — the user's real
      library is unchanged. One real live-testing hazard encountered and
      resolved, not a code bug: an abandoned pick (armed, then left
      idle ~90 minutes real-world) was correctly auto-discarded by
      `discardUnpickedColorRangeMask` exactly as designed, confirming
      that safety net fires correctly for a genuinely abandoned pick,
      not just a synthetic one. **CLAUDE.md's Phase 7 roadmap item 5
      (Color Range / Luminance Range masks) is now FULLY COMPLETE** —
      both content-derived kinds shipped, reviewed, tested, and live-
      verified.
   6. **Combining masks** (intersect/subtract boolean semantics between
      masks) — deliberately LAST, ✅ **COMPLETE** (Session A 2026-09-15,
      Session B same day). Corrected scope (2026-09-09): slice 2 already
      shipped multiple simultaneous, independently-compounding masks per
      photo (confirmed by the user, not drift from this roadmap's original
      "one mask at a time" framing above) — what remained here was
      specifically INTERSECT/SUBTRACT, i.e. one mask's shape modifying
      another's rather than both applying independently.

      **Session A (data model + pipeline)** shipped `Mask.combineMode`
      (`.none`/`.intersect`/`.subtract`) and `Mask.combineWithMaskID`,
      wired into `EditPipeline.applyMasks` between a mask's own geometry
      resolve and its final `CIBlendWithMask`: intersect via
      `CIMinimumCompositing` (direct precedent — `luminanceRangeMaskImage`
      already ANDs two ramps this way), subtract via `CIMinimumCompositing`
      against a channel-inverted operand. All five `MaskKind`s are valid
      operands, resolved against the same running `img` the consumer's own
      content-derived selection would see — no restriction, since the
      extraction needed to support it (`resolveMaskGeometry`/
      `maskImageAndRegion`) was free either way and unlocks real cases like
      "brighten only the highlights inside this drawn area." Deliberately
      non-transitive (an operand's own combine settings are never read —
      cycle-safe by construction) and fail-open in every broken-reference
      case (self-reference, dangling reference, or an operand whose own
      shape resolves to nothing all degrade toward `.none`/a no-op, never
      toward silently vanishing the whole adjustment).

      **A genuine, self-caught Core Image bug** found via a throwaway probe
      before any reviewer involvement: the first `invertedMaskImage`
      (needed for subtract) used `CIColorMatrix` inverting all four
      channels independently — passes at the two degenerate extremes but
      silently fails at every PARTIAL weight, because `CIColorMatrix`
      unpremultiplies an RGB==alpha pixel before applying its matrix,
      collapsing RGB to 0 for any weight `> 0` regardless of the true
      value. Fixed with Porter-Duff `CISourceOutCompositing`
      (`Src * (1 - Dst.alpha)`, always premultiplied, so RGB==alpha
      covariance is preserved automatically) — verified exact across the
      full `0...1` weight range via the probe, not just the endpoints.
      Reviewer (Opus 5): 2 rounds, FIX FIRST → APPROVE — round 1 caught a
      genuinely tautological test (proven by fault-injecting both false
      starts and confirming it didn't fail under either, since
      `CIBlendWithMask` weights R/G/B uniformly regardless of which bug
      produced the weight), a dangling doc-comment citation, and two doc
      comments describing not-yet-built UI in present tense — all fixed;
      round 2 independently re-derived the premultiplied-RGB claim and the
      Porter-Duff extent behavior via its own standalone probes before
      APPROVE. 903 tests (7 new — `MaskCombineTargetTests`; the pipeline
      side added no new tests of its own beyond Session A's original
      ~30, since the primary regression gate was the FULL pre-existing
      mask suite passing with ZERO edits after the extraction).

      **Session B (UI)** added `MaskCombineTarget`/`CombineTargetSelection`
      to `MaskDetailView.swift` (a `combineRows` group appended last in
      `body`, hidden when there's nothing to combine against) and one new
      argument at `AdjustTabView.maskDetail`'s `MaskDetailView(...)` call
      site. The target picker mirrors this codebase's own `LibraryFilter`
      fix (`Sources/UI/CatalogModel.swift`/`CollectionSidebarView.swift`)
      for the identical class of bug — a SwiftUI `Picker` bound directly to
      an `Optional` selection can make the "None" row silently
      unselectable once a real value is chosen — via a coercing computed
      `Binding` whose getter maps any unresolvable stored id back to
      `.none`. A new behavior not in the original Session A plan, added
      after exploration surfaced a real dead-end state: choosing a non-
      `.none` mode with no target yet auto-fills the first available
      target, so the control never reads as inert. `maskKindLabel`
      widened from `private` to `static` so `MaskCombineTarget`'s pure
      `targets(excluding:in:)` helper (tested in
      `MaskCombineTargetTests.swift`) can share the exact same label
      strings `maskListRows` shows — the two can never disagree.

      **Live-verified (2026-09-15)**, via AX-driven automation on the
      user's real `IMG_6564.jpeg`: Intersect confined a +5EV brightening to
      exactly the circular overlap between two radial masks (confirmed via
      a cropped close-up — the blown-out region was round, matching the
      SMALLER mask's shape, not oval like the larger one, proving genuine
      geometric intersection); Subtract on the same two masks produced the
      exact inverse — the full ellipse blown out except a precise
      unaffected hole where the other mask sat; deleting the operand
      correctly failed open on BOTH the canvas (full uncombined effect
      returned) and the picker (independently re-derived "None," not
      reading a stale value); the mask's own `combineMode` was confirmed
      to survive the delete unchanged (still "Subtract") while only the
      target coerces to "None" — exactly the documented fail-open split;
      undo/redo correctly stepped a combine-target change as one unit;
      the on-disk sidecar was inspected directly and showed the real
      `combineMode`/`combineWithMaskID` UUIDs, matching the picker; Revert
      to Original cleanly cleared back to "No masks yet," confirmed both
      on-screen and in the sidecar (`"masks": []`). One real, live-only
      finding, now logged (IMPROVEMENTS.md D15): deleting an operand when
      it's the ONLY other mask hides the entire Combine section (correctly
      — nothing to combine against), which makes the surviving mask's own
      stale `combineMode`/`combineWithMaskID` invisible until a second
      mask exists again, at which point the picker re-resolves correctly —
      harmless, but worth knowing before mistaking the hidden section for
      a bug.

      **Perf** (same `CFAbsoluteTimeGetCurrent()` probe-and-fully-revert
      methodology as every prior Phase 7 slice, on the user's real
      20.7MP JPEG and 24MP RAW assets, temporary instrumentation confirmed
      fully reverted via a clean `git diff` before commit): three of the
      four planned scenarios stayed comfortably under the 16ms/60fps
      budget; `.brush` ∩ `.brush` did NOT (see below — a real, predicted
      cost, not a false alarm). `.radial` ∩ `.radial` with Clarity
      measured ~1.05–1.7ms proxied /
      ~1.4ms full-res on JPEG (delta over the ~0.3–0.4ms masks-off
      baseline is roughly the cost of ONE mask's Clarity alone — intersect
      itself adds close to nothing, confirming the ROI-narrowing win) and
      near the noise floor on RAW (~1.0–1.3ms proxied / ~4.1ms full-res,
      RAW's own heavier baseline dwarfing the combine cost). `.radial` −
      `.radial` (no ROI win possible for subtract) measured a real but
      small ~1.2–1.5ms proxied / ~2.6–2.9ms full-res on JPEG.
      `.radial` ∩ `.luminanceRange` — the scenario Session A's own
      reviewer flagged as the one to prioritize, since a content-derived
      operand adds a second full-extent kernel pass with no ROI crop
      available — measured ~1.4–1.8ms proxied / ~2.5–3.2ms full-res on
      JPEG and, measured on BOTH assets per that flag, ~1.3–1.9ms proxied
      / ~5.6–8.0ms full-res on RAW (a real ~4–6ms delta over RAW's own
      baseline, the largest of the four scenarios on RAW, but still under
      half the 16ms budget). `.brush` ∩ `.brush` was the one predicted in
      advance to hurt, and did — the ONE scenario that measured OVER the
      16ms/60fps budget on full-resolution frames: ~9.1–10.4ms proxied /
      ~12.5–**19ms** full-res on JPEG — `BrushStrokeImageCache`'s
      single-entry cache thrashing between two different masks' keys,
      confirming the already-logged, already-scoped remedy (a small ring,
      or keying by `Mask.id`) is real and worth prioritizing if
      brush-on-brush combining proves common in practice; not fixed this
      slice, per that cache's own standing doc comment. The interactive/
      proxied path (~9-10ms, what a user actually drags against) stays
      under budget in every scenario measured — only the full-resolution
      settle frame exceeds it for `.brush` ∩ `.brush`.

      **Reviewer (Opus 5) on the Session B UI diff — round 1: FIX FIRST.**
      Caught two doc-accuracy issues — this file and PROGRESS.md both
      originally claimed "all four scenarios stayed comfortably under
      budget" in the same breath as reporting `.brush` ∩ `.brush`'s 19ms
      full-res number, a direct self-contradiction, and both files had a
      reviewer-approval sentence written BEFORE the review actually ran —
      the exact defect class slice 3 Session B's own reviewer already
      caught once (a claim asserted without being true yet). Also caught a
      real, if narrow, correctness gap: the auto-select-first-target
      behavior in `combineModeSelection`'s setter only guards the
      MODE-change path — a user could still reach a live, silently-inert
      combine (`Mode = Intersect`, `With = None`) via the OTHER picker,
      setting the target back to "None" without touching the mode. Fixed
      by having `combineTargetSelection`'s `.none` setter branch also
      reset `mask.combineMode` to `.none`. Two non-blocking notes also
      addressed: the Mode/With `Picker`s gained explicit
      `.accessibilityLabel`s ("Combine Mode"/"Combine With") so VoiceOver
      doesn't read them as bare "Mode"/"With" detached from the "Combine"
      section caption; and a live check (a `.luminanceRange` mask — this
      app's longest kind label — as a combine target, `AXWindow` size
      compared before/after) found no sidebar-width regression from a long
      target label, closing that note without a further code change.

      **Round 2: FIX FIRST again** — this time on the doc fixes
      themselves, not the code. The blocker-1 correction had only been
      applied to this file, not PROGRESS.md, which still carried the
      original self-contradiction; and this section's own first attempt
      at a review-summary paragraph made the exact mistake it was
      describing — asserting a "2 rounds, FIX FIRST → APPROVE" verdict and
      a "no FIX FIRST round needed" claim in PROGRESS.md before round 2
      had actually returned, plus an inaccurate claim that round 2
      "did not re-review" the accessibility/width notes when it explicitly
      had been asked to and did. Both docs corrected to state facts only
      as they're confirmed, not projected ahead of the actual verdict —
      see this paragraph's own history for why that discipline matters
      here specifically.

      **Round 3: APPROVE.** A doc-only round — confirmed both budget
      contradictions were fully resolved in both files (not just the one
      round 2 caught), confirmed no round-3 outcome had been pre-asserted
      anywhere, and confirmed the "can't disagree in either direction"
      overstatement was gone rather than reworded into a new overstatement.
      Independently re-verified the two underlying claims those sentences
      rest on: `MaskCombineTarget.targets(excluding:in:)`'s numbering
      against `maskListRows`' own, and the picker's fail-open coercion
      against `EditPipeline.applyMasks`'s actual guard conditions — both
      confirmed to genuinely match, not just asserted to. One non-blocking
      process note: `Tests/EditEngineTests/MaskCombineTargetTests.swift`
      was untracked through all three rounds (`git diff HEAD` never shows
      new files) — reviewed by reading it directly instead; flagged only
      so it isn't forgotten at `git add` time.

      **Phase 7 (Local Adjustments/Masking) is now FULLY COMPLETE** — all
      five mask kinds, independent compounding, and boolean combining all
      shipped, reviewed, tested, and live-verified.

   **Explicitly out of scope, needs its own separate research spike before
   even being scoped** (not part of this phase's slicing above): AI Subject/
   Sky/Background/Object select masks (needs an on-device ML segmentation
   model — check what Apple's own Vision framework actually offers before
   assuming a model needs to be bundled) and Depth Range masks (needs depth
   data most JPEGs/RAWs don't carry at all).
8. Polish: tiled rendering for large images, perf, edge cases

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
  headroom above linear 1.0 when active, see `EditPipeline.applyCurves`).
  **v2 — WANTED, confirmed by the user 2026-09-16** — full interactive draggable
  RGB point-curve editor. Also tracked in the Lightroom-gaps section below so it
  surfaces when picking the next slice; it had previously lived ONLY here and was
  missed when listing candidates. See that entry for scope.
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
- **Definition (Clarity):** ✅ shipped, then **SUPERSEDED** — the single
  `definition` field was split into `texture` + `clarity` (see the
  Texture/Clarity entry under "Gaps vs. Adobe Lightroom Desktop" below).
  `definition` no longer exists as a field; it survives only as a read-only
  legacy decoding key. Do not re-add it. Its original design notes (large-radius
  `CIUnsharpMask` at 16x Sharpen's radius fraction, runs after Vignette because
  measured non-commutative with it unlike Sharpen, before Noise Reduction/
  Sharpen) all still describe `clarity`, which inherited the math unchanged.
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

### Gaps vs. Adobe Lightroom Desktop (2026-09-03, not yet scheduled)
The backlog above was built against Apple Photos. The user asked to cross-check
against Lightroom Desktop's own Edit panel
(https://helpx.adobe.com/lightroom/desktop/edit-photos/edit-photos.html and its
Masking/Remove-tool/Denoise sub-pages — Lightroom's Light/Color/Effects/Detail/
Optics/Geometry panel structure) for tools this app still doesn't have at all.
Nothing below is implemented yet; each is still a separate future
one-feature-per-session candidate, same as every other backlog item — but the
items marked **WANTED** have been explicitly confirmed by the user (2026-09-03)
as things to actually build, not just researched gaps, so pick from those first
when this section comes up. Split into two tiers by how big a lift each actually is:

**Tier 1 — fits the existing global-adjustment architecture** (a new `EditState`
field(s) + `EditPipeline` stage(s) + `AdjustTabView` section, the same shape every
shipped slider already follows):
- **Texture / Clarity — ✅ SHIPPED** (the first two thirds of the Texture/
  Dehaze split). `definition` was replaced by two BIPOLAR (-1...1) fields,
  `texture` (radius fraction 0.01) and `clarity` (0.04, inheriting
  `definition`'s exact math on the positive half). Both are `CIUnsharpMask` at
  different radii — radius is the ONLY difference between the two controls.
  - **Migration**: `definition` lives on as a read-only key in `EditState`'s
    own `LegacyCodingKeys` enum, decoded into `clarity`. It is kept in a
    SEPARATE enum, not as an extra `CodingKeys` case, because Swift's
    synthesized `encode(to:)` — which `EditState` still relies on, only
    `init(from:)` is hand-written — requires every `CodingKeys` case to have a
    matching stored property. Presets migrate for free: GRDB serializes
    `Preset.editState` through the same decoder, so NO SQL migration was
    needed.
  - **Bipolar took a second construction.** The negative half cannot use
    `CIUnsharpMask` (measured: it clamps negative `intensity` to a
    bit-identical no-op, which is why `definition` originally shipped
    one-directional). `EditPipeline.localContrast` runs the positive half
    through `CIUnsharpMask` and the negative half through a blend toward
    `CIGaussianBlur` at the same radius. The blur EXPANDS extent, so that
    path clamps-then-crops back. (An earlier version of this bullet said
    `applyMasks` depends on that extent — backwards: `applyMasks` runs ABOVE
    both stages. The real dependents are downstream, e.g. Sharpen's own
    `min(extent)` radius fraction.)
  - `Mask.clarity` became bipolar too, sharing the same helper. Masks have no
    `texture` counterpart yet (Lightroom's do) — a future additive item.
  - Texture/Clarity ordering is coarse-then-fine by CONVENTION, not
    measurement: swapping them moves the profile by at most 0.00215, only
    marginally above the test suite's own 0.002 tolerance. Recorded honestly
    as such in `applyTexture`'s doc comment.
- **Dehaze — ✅ SHIPPED.** The Presence panel is now complete
  (Texture/Clarity/Dehaze). A real DARK CHANNEL PRIOR (He, Sun & Tang, CVPR
  2009), not an approximation: Core Image ships no dehaze filter, so it is
  assembled from two NEW custom kernels — `DehazeDarkChannel.cikernel` and
  `DehazeRecover.cikernel`, the third and fourth in this codebase — plus
  `CIAreaMaximum` and `CIMorphologyMinimum`. Bipolar -1...1; negative ADDS
  haze by blending toward the same estimated atmospheric light.
  - **How the per-pixel/neighbourhood split works**, since it is the reason
    this was possible at all: a `CIColorKernel` cannot sample neighbours, so
    the per-pixel half (cross-channel min of I/A) is a kernel and the spatial
    half is `CIMorphologyMinimum` between the two kernels.
    `DehazeRecover.cikernel` is also the first kernel here to take THREE
    `__sample`s (`DehazeDarkChannel.cikernel` already takes two).
  - **Atmospheric light stays on the GPU**: `CIAreaMaximum` reduces a blurred
    copy to 1x1, then `.clampedToExtent()` spreads it back to a constant
    field. Do NOT "simplify" this into `ImageAverageColor`'s CPU readback —
    that is right for Cast, a one-shot action, and would stall every frame.
    Because A is a whole-frame STATISTIC, it depends on what is in the frame:
    cropping changes the dehaze result (documented in `applyDehaze`), and so
    does RENDER RESOLUTION — a proxy or thumbnail estimates A from a different
    set of pixels entirely. Flagged as unmeasured reasoning, then measured,
    and it invalidated more than this stage: the claim that downscaling is
    "correct, not an approximation, for every stage except Noise Reduction"
    is WRONG, and was wrong before Dehaze existed. It appeared verbatim in
    TWO places (`ProxyScale` and `ImageDocumentModel`); `ThumbnailGenerator`
    claimed exactness without the NR exception and `ImageRenderer` concluded
    every other stage "renders identically" — four sites corrected, but only
    two carried the exact claim. All FOUR measured stages diverge (dehaze,
    NR, sharpen, clarity); texture, vignette and red-eye were NOT measured,
    so nothing here claims anything about them. Rank swaps with scale AND
    with content. **See IMPROVEMENTS.md D18 for the measured matrix** — note
    the content dependence inverts: absolute deltas fall on photo-like
    content, but Dehaze's ratio to every other measured stage RISES, and on
    photo-like content Dehaze leads at every scale.
  - **Runs in scene-linear with no perceptual sandwich**, unlike
    Clarity/Texture. That is a PRINCIPLED choice, not a measured one, and is
    labelled as such in the code: the haze model is defined on radiance, so
    the working space is already correct.
  - **Ordering is measured, not conventional** (unlike Texture/Clarity, which
    nearly commute): Dehaze runs BEFORE Vignette and Clarity, and swapping
    either moves the result 0.4+ — Vignette darkens corners and the
    atmospheric light is estimated from the frame's brightest region, so
    letting it run first feeds the estimate a value the scene never had.
  - **Known cost, accepted by user decision**: Dehaze combines superlinearly
    with CLARITY specifically (Vignette shows no excess, Texture is mild) via
    ROI dilation. **No ratio is quoted here — the absolute numbers do not
    reproduce**, and three claims in the first write-up were wrong because the
    harness shared one `CIContext` across configurations. See IMPROVEMENTS.md
    D17 for the methodology trap and the three withdrawn claims.
  - **Identity at 0 comes from the `dehazeActive` GATE**, not from the maths:
    `(I - A)/1 + A` is not identity in float32 (measured). That guard is
    load-bearing.
  - **Limitation**: no transmission refinement (no soft matting / guided
    filter), so transmission is blocky at the patch scale and halos at sharp
    depth discontinuities.
  - **LIVE-VERIFIED 2026-09-17** against a ground-truth hazy image built
    with the haze model itself: correction scales ~14x with haze density
    and restores contrast only where haze was, i.e. genuinely depth-aware,
    not a global contrast boost. See PROGRESS.md for the per-band table.
  - **Known limitation, found live**: does essentially nothing on
    UNDERWATER photos (measured delta 0.00 on open water). Water absorbs
    red, so the dark channel reads "not hazy" — the textbook failure case
    for this prior, not an implementation bug. IMPROVEMENTS.md D19.
  - Masks have no `dehaze` or `texture` — still a future additive item.
- **Grain — WANTED.** Film-grain effect, not present in any form. Straightforward
  new `EditState` field + a new perceptual-domain `EditPipeline` stage (likely
  Core Image's own grain-simulation building blocks, or a small custom kernel if
  none fit) — no migration concern, purely additive.
- **Color Grading — WANTED.** 3-way shadows/midtones/highlights color wheels
  (Lightroom's successor to Split Toning). Not present; no existing field covers
  this. Bigger UI lift than a slider (needs a color-wheel control, not an
  `EditSliderRow`) but purely additive to `EditState` — no migration concern.
- **Point Color — WANTED.** Lightroom's newer per-color eyedropper refinement
  (pick an exact color, then adjust ITS OWN Hue/Sat/Lum), distinct from this
  app's existing Selective Color (8 FIXED hue bands). A genuinely different
  targeting model, not a duplicate — likely needs a variable-length collection
  field (like `redEyePoints`, this app's only existing precedent for that shape)
  since the user picks arbitrary colors, not fixed bands.
- **Chromatic Aberration removal — WANTED.** A single checkbox in Lightroom's
  Optics panel, separate from lens distortion correction (already tracked above
  under Transform/Distort, blocked on camera-profile data). Purely additive.
- **Manual Transform Scale/Aspect — WANTED.** Lightroom's Geometry panel has
  Scale/Aspect sliders alongside Vertical/Horizontal perspective; this app has
  the perspective sliders but not the follow-up Scale/Aspect fine-tuning. Purely
  additive, same Transform/Distort pipeline stage group already exists.
- **RAW-native AI Denoise** — overlaps directly with this app's own already-
  deferred Phase 6 slice 3 (`CIRAWFilter.luminanceNoiseReductionAmount`/
  `colorNoiseReductionAmount`, RAW-only) — not a new item, just a cross-reference
  confirming Lightroom treats this as a first-class, separate-from-manual-NR tool
  worth eventually distinguishing from the existing global `noiseReduction` slider.

**Note:** Curves v2 (below, in Tier 2) reached this list late — it was tracked
only in the Phase 2 backlog above, was never tagged WANTED, and so did not
surface when next-slice candidates were listed on 2026-09-16. Cross-listed here
to stop that recurring. When answering "what should we build next", read BOTH
this section and the Phase 2 backlog above, not just the WANTED items here.

**Tier 2 — genuinely new architecture, don't underscope these** (this app's
`EditState` is one flat, whole-image parameter set per photo; every one of these
requires a fundamentally different data model — spatial masks with their own
per-mask parameter sets, rendered and composited before/alongside the existing
global pipeline):
- **Curves v2 (interactive point-curve editor) — WANTED (2026-09-16).** The
  draggable spline editor with per-channel RGB modes, replacing/extending v1's
  two parametric sliders. Tier 2 not because the MATH is hard (`CIToneCurve`
  already ships, and v1 uses it) but because the INTERACTION is: a draggable
  curve canvas with point hit-testing, add/remove/drag points, curve
  interpolation between them, and a channel selector — none of which any
  existing `EditSliderRow`/overlay pattern covers. Nearest precedent in this
  codebase is the Phase 7 mask overlays (`CropOverlayView`,
  `BrushMaskOverlayView`) for hit-tested direct manipulation, plus
  `HistogramView` for drawing in the sidebar — a curve editor wants both at
  once (curve drawn over a live histogram, Lightroom-style).
  - **Fixes a recorded v1 defect**: `EditPipeline.applyCurves` clamps highlight
    headroom above linear 1.0 whenever curves are active, so headroom created by
    Exposure is crushed the moment Shadows/Highlights move. Every other stage in
    this pipeline deliberately preserves headroom. v2 should fix this, not
    inherit it.
  - **Unblocks a pending structural decision** already noted in the Light-group
    entry above: whether Shadows/Highlights should split out into dedicated
    Light sliders once Levels/Curves v2 lands.
  - **Migration**: `curvesShadows`/`curvesHighlights` are shipped fields in real
    sidecars and presets. Same class of breaking change as the `definition` ->
    `texture`/`clarity` split — reuse that pattern (a `LegacyCodingKeys` enum
    decoding the old fields into the new curve representation). Do NOT design
    the v2 data model without reading that migration first.
  - **Slice 1 ✅ SHIPPED (2026-09-17)** — `Sources/Rendering/Shaders/ToneCurve.cikernel`
    (+ `Sources/EditEngine/ToneCurveSpline.swift`, the Swift twin doing the
    spline solve) REPLACED `CIToneCurve` inside `applyCurves`, which kept its
    signature so Black Point, Brilliance and per-mask Shadows/Highlights came
    along unchanged. The reverse-engineering held: every in-domain assertion of
    the ~70 passed untouched, and the ONLY tests that failed were the 6
    asserting the old clamp. Highlight headroom now survives an active curve
    (linear extrapolation above the last control point); below `point0` the
    curve still CLAMPS, deliberately — that is what makes Black Point clip to
    black. Not yet live-verified in the app. **Two recorded claims were
    measured to be FALSE while doing this** — `CIToneCurve` does NOT
    extrapolate below point0.x (it clamps at both ends; the "soft black point"
    is in-domain spline shape), and `luminanceRangeMaskImage` cited that false
    claim in its own rejection rationale. Both corrected in place. See
    PROGRESS.md's slice-1 section, including why believing the false claim
    would have broken Black Point.
  - Slice 2 (the interactive editor) is the remaining work and the hard part;
    `ToneCurveSpline`'s solve is already n-point-general, but the kernel's
    unrolled segments and `vec4` argument packing are 5-point-specific.
- **Masking / local adjustments** — the single biggest capability gap found.
  Lightroom's whole modern editing paradigm centers on this: AI Subject/Sky/
  Background/Object select, Brush, Linear (Graduated) and Radial gradients, Color
  Range mask, Luminance Range mask, Depth Range mask, combinable via intersect/
  subtract, each carrying its OWN copy of most Light/Color/Effects sliders. This
  app has zero general local-adjustment capability today — only Red-Eye (point-
  placed, single fixed effect, not a general mask) and Crop (geometric, not
  tonal/color). **Promoted to its own formal roadmap Phase 7 (2026-09-03), with a
  real architecture-research-grounded slicing plan — see that section above for
  the full plan, the two concrete rendering hazards found, and why this is not a
  simple backlog line item.**
- **Remove tool** — AI-powered content-aware object/spot/blemish removal
  (Lightroom's successor to manual Spot Removal/Healing Brush). Needs inpainting,
  not achievable with this app's current Core Image filter-chain approach without
  a new model/algorithm. Not present in any form.
- **Auto Tone / Auto Settings — WANTED.** One-click starting-point adjustment.
  This app already has ONE precedent for exactly this shape — "Fix Color Cast"
  (`ImageDocumentModel.fixColorCast()`, whole-image gray-world statistical
  analysis feeding existing WB fields, no ML) — a full Auto Tone likely follows
  the same "compute stats off the already-decoded image, write several existing
  `EditState` fields at once, one button" pattern rather than needing genuine ML,
  at least for a v1 (histogram-driven heuristics for exposure/contrast/black-
  white points). Worth scoping a heuristic-only v1 before assuming ML is required.
- **Enhance / Super Resolution — WANTED.** AI upscaling; unrelated to this app's
  current edit-parameter model entirely — this is a new RENDER/EXPORT capability
  (an upscaled output image), not an `EditState` field, so it doesn't fit the
  Adjust-tab pattern at all. Needs its own design: where does the upscale run
  (on-demand at export time only, given the cost, almost certainly NOT live in
  the Editor preview), what model/API (Core ML, an Apple system API if one
  exists, or a third-party model bundled with the app), and how large a download/
  bundle-size cost that implies. Most speculative WANTED item — needs real
  research into what's actually available on macOS before it can be scoped at
  all, let alone Plan-Mode-ready.
- **History panel** — a full, browsable/scrubbable list of every edit step, not
  just linear Undo/Redo. This app's `EditHistory` already has the underlying
  data (a list of committed `EditState` snapshots per photo); a UI to browse and
  jump to any past state would be a smaller lift than the other Tier 2 items,
  but still a new UI surface, not a slider addition.
- **Copy/Paste and Sync edit settings across selected photos** — distinct from
  this app's existing Presets (a named, manually-saved reusable look): Lightroom's
  version copies one photo's EXACT current settings and applies them to N selected
  photos in one action, no naming/saving step. Partially served today by saving a
  throwaway preset and applying it repeatedly, but not the same one-step workflow.

**Confirmed NOT a gap** (already shipped, just noting the cross-reference):
Before/After comparison — this app's Compare mode (Side by Side / Split,
post-Phase-5 follow-up #5) already covers Lightroom's Before/After views.

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
- **Measurement records are historical facts, not descriptions of the current
  code.** A doc comment that says "measured live: X and Y active, 24.6-399.9ms"
  records a run that actually happened. When a stage is RENAMED, propagating the
  new name into that record is correct. When a stage is ADDED, adding it to that
  record is NOT — it invents a configuration nobody ever ran. Distinguish these
  from STRUCTURAL claims ("radii are extent fractions"), which describe the code
  as it stands and should be kept current. Caught by the reviewer during the
  Texture/Clarity split, where a comment sweep falsified three past timing runs.
- **Never write measurement-shaped prose you have not run.** If a number is
  needed, add a temporary harness, run it, paste the real figures, delete the
  harness. A fabricated measurement is worse than no measurement, and this
  codebase's doc comments are load-bearing precisely because their numbers are
  real. Also applies to negative results: when a measurement comes back weak
  (e.g. Texture/Clarity commutativity, 0.00215 against a 0.002 tolerance), say
  so and call the decision a convention rather than dressing it up as a measured
  necessity.
- Swift: SwiftLint defaults, no force-unwraps outside tests, `// MARK:` sections.
- Shaders live in `Sources/Rendering/Shaders/`, one kernel per file, commented with
  the math they implement and its source/reference.
- DB migrations are append-only, in `Sources/Catalog/Migrations/`.
