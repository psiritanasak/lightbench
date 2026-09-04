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
   **Deferred to slice 6** (a separate session): `CIRAWFilter`'s
   remaining RAW-native controls — `lensCorrectionEnabled` (measured
   UNSUPPORTED on this app's own test camera — do not "fix" this
   omission without re-measuring against whatever camera prompts
   revisiting it), `contrastAmount`/`detailAmount`/`moireReductionAmount`
   (also supported, also per-file-defaulted, deferred only because they
   weren't part of what was asked for in slice 5 — re-measure their
   native defaults before assuming a multiplicative-scale shape is safe,
   same lesson slice 5 just learned), and opting into
   `CIRAWDecoderVersion9` at runtime via `supportedDecoderVersions` on OS
   versions that offer it. A genuine inverse-geometry transform for the
   WB eyedropper's fast path (so it works regardless of crop/straighten/
   perspective/flip, not just at identity) is a separate,
   explicitly-deferred stretch goal from slice 4 — see that slice's own
   write-up above for why it was scoped out, not forgotten.
7. Local Adjustments (Masking) — **not started.** The single biggest capability
   gap versus Lightroom (see the Lightroom gap-analysis subsection above, which
   this phase supersedes/formalizes for this one item). Every adjustment in this
   app today is global — `EditState` is one flat struct, `EditPipeline.apply` is
   one pure whole-image function, zero concept of a spatial mask. Scoped
   2026-09-03 from a dedicated architecture research pass (not guessed) — see
   the two real hazards below before touching this.

   **Hazard 1 — several existing pipeline stages read the FULL image extent for
   their own geometry**, not just the masked region: Vignette centers on
   `extent.midX/midY`; Definition/Sharpen radii scale off
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

   **Hazard 2 — zero per-frame caching exists anywhere in the render path
   today**, worse than assumed before this research pass: `EditPipeline.apply`
   reruns its entire ~12-stage filter graph from scratch on EVERY `draw(in:)`
   frame (every slider tweak), synchronously on the main thread, with no
   memoization even for non-RAW images (`RawDecoder.materialize`/`RenderGate`
   solve a DIFFERENT problem — RAW decode cost — not this). Compare mode
   already proves N-way compositing works architecturally (it runs
   `EditPipeline.apply` TWICE per frame today, composited via the same lazy
   `CIImage` graph, `ImageRenderer.swift:114`+`:165`), so masking's rendering
   model is not new — but N masks means N additional full pipeline passes with
   NOTHING throttling per-frame cost, unlike literally everything else RAW-
   related this app has needed to build (`RenderGate`, debounced re-decode,
   the histogram debounce). This is a genuine performance-viability question,
   not just an engineering detail — **slice 1 below exists specifically to
   answer it with a measurement, before any UI gets built on top of an answer
   that might be "no."**

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
   2. **Mask data model + Radial mask only, no combining.** A new `Mask` type
      — NOT the full 59-field `EditState`; a small curated subset matching
      Lightroom's own per-mask panel (roughly Exposure/Contrast/Highlights/
      Shadows/Whites-or-equivalent/Clarity/Saturation/Temp/Tint — pick the
      actual set deliberately, don't default to "all of them"). Schema-
      tolerant `Codable` following `EditState`'s own established
      `decodeIfPresent ?? default` pattern. `EditState` gains `masks: [Mask]`
      — a second variable-length field alongside the existing precedent,
      `redEyePoints` (`EditState.swift:336`), but a bigger step up: each mask
      needs its OWN full parameter set, unlike `redEyePoints`' "N points
      sharing ONE shared param pair" shape. One mask at a time, Radial
      geometry only (ellipse: center/radii/rotation/feather) — reuse Crop's
      8-handle resize-drag precedent (`CropOverlayView.swift`) as the closest
      existing interaction-code shape for a resizable geometric handle set;
      it's the only existing precedent for a resizable (not just
      placed-and-done) shape. New list UI for "Mask 1, Mask 2…" reusing
      Presets' `ForEach(catalog.presets)` add/delete precedent
      (`AdjustTabView.swift:407-436`) — the only existing dynamic-list UI
      precedent in this codebase; note neither it nor `CollectionSidebarView`
      has any drag-to-reorder precedent, so v1 shouldn't promise reordering.
   3. **Linear (Graduated) mask** — second geometry type, reuses most of
      slice 2's plumbing; new interaction code is a draggable line + two
      parallel falloff guides (genuinely new — no existing precedent covers
      a rotatable line-with-parallel-guides gesture).
   4. **Brush mask** — freehand painting; the hardest UI slice, since none of
      this app's three existing overlay patterns (WB eyedropper's one-shot
      tap, Red-Eye's persistent point list, Crop's fixed-handle drag) cover a
      continuous multi-point stroke gesture. Needs size/hardness/feather
      controls matching Lightroom's own.
   5. **Color Range / Luminance Range masks** — computed from image
      statistics (pick a color/tone, auto-generate a mask from similarity),
      not manually drawn at all — closer in spirit to the existing "Fix Color
      Cast" auto-analysis button (`ImageDocumentModel.fixColorCast()`,
      whole-image gray-world stats) than to slices 2-4's shape-drawing.
   6. **Combining masks** (intersect/subtract, multiple simultaneous masks
      per photo) — deliberately LAST, since slices 2-5 all assume "one mask
      at a time" to keep each slice's own risk contained; only take this on
      once the single-mask performance/UX story (slice 1's whole reason for
      existing) is proven acceptable across several real masks.

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
- **Texture / Dehaze — WANTED, decided:** split `definition` into three separate
  fields — `texture`, `clarity`, `dehaze` — matching Lightroom's model exactly,
  not a bolted-on extra `dehaze` field alongside the existing composite. This is
  a **breaking change to an already-shipped field**: `definition` is a real
  `EditState` field today (schema-tolerant `Codable`, included in
  `comparisonOriginal()`/`applyingPreset(onto:)`/`isAdjustTabAtIdentity`/
  `resetAdjustmentsButton`, an existing `AdjustTabView` slider, an existing
  `EditPipeline.applyDefinition` stage) — splitting it needs a real migration
  plan for old sidecars/presets (e.g. decode `definition` into `clarity` for
  backward compatibility, or keep `definition` as a deprecated-but-still-decoded
  key), not just adding two new fields. Needs its own Plan Mode session.
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

**Tier 2 — genuinely new architecture, don't underscope these** (this app's
`EditState` is one flat, whole-image parameter set per photo; every one of these
requires a fundamentally different data model — spatial masks with their own
per-mask parameter sets, rendered and composited before/alongside the existing
global pipeline):
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
- Swift: SwiftLint defaults, no force-unwraps outside tests, `// MARK:` sections.
- Shaders live in `Sources/Rendering/Shaders/`, one kernel per file, commented with
  the math they implement and its source/reference.
- DB migrations are append-only, in `Sources/Catalog/Migrations/`.
