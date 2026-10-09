# Roadmap History — Photo Editor

This is the full, unabridged history of every roadmap item: session-by-session
write-ups, reviewer round detail, live-verification checklists, and measured
numbers. It was split out of `CLAUDE.md` on 2026-09-17 because CLAUDE.md is
loaded into every session's context and had grown to ~4x the recommended size
(158KB / 2283 lines) — almost entirely from this content.

**CLAUDE.md keeps the current, compressed status** (roadmap as a flat list,
one line per shipped item, file names, and any decision that changes future
behavior). **This file keeps the "why" and the "what was actually verified."**

Before modifying an already-shipped item — especially RAW (Phase 6) or Masking
(Phase 7), both of which accumulated multiple measured-but-counterintuitive
hazards across their slices — read that item's entry here first. Re-deriving
a hazard that was already found and fixed once wastes a session.

Nothing below this line is out of date relative to CLAUDE.md's compressed
summary; it's the same facts at full detail, not a stale duplicate to
reconcile.

---

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
   collections were NOT started at this point — all have since shipped
   (see the Pick/Reject entry at the end of this file for the last one).

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
- **Sharpen:** ✅ shipped — a single Amount slider via `CISharpenLuminance`
  (radius scales with the image's own min dimension — measured necessity,
  the filter's radius is in absolute pixels). No longer the pipeline's
  final stage as of the Grain slice below — that structural claim is kept
  current there, not repeated stage-by-stage each time it moves.
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
- **Grain — ✅ SHIPPED (2026-09-17).** Single Amount slider (0...1, matching
  Sharpen/Noise Reduction's one-directional family). No stock Core Image
  filter does "blend a second noise image, monochrome, weighted by tone" as
  one reviewable operation, so this needed a new custom kernel —
  `FilmGrain.cikernel`, the SEVENTH in this codebase (after SelectiveColor,
  ColorRange, ToneCurve, PointToneCurve, DehazeDarkChannel, DehazeRecover) —
  blending a `CIRandomGenerator` noise field.
  - **This slice's own round-1 "fix" shipped a WORSE bug than the one it
    fixed — the single most important thing to read before touching this
    stage again.** Round 1 (self-caught, before any review): a naive
    construction fed `CIRandomGenerator` through `CIColorClamp` then
    `CIColorMatrix` (to force the noise image opaque before the kernel).
    That appeared to blow up into runaway values (~90588 on a 64x64
    sample), which LOOKED like it confirmed "the generator's raw output
    isn't bounded to 0...1" and was "fixed" by clamping first and
    measuring the kernel's zero-point on the clamped-and-matrixed result
    (0.7439). Round 2 was an ADVERSARIAL REVIEWER RE-MEASUREMENT — not
    this suite, which was green throughout — and it found the round-1
    "fix" was itself built on a false premise: `CIRandomGenerator`'s raw
    output genuinely IS bounded to 0...1 (measured directly: min 0.0, max
    1.0, mean 0.4994 over a 512x512 sample). The runaway values came from
    `CIColorClamp`/`CIColorMatrix` themselves — MEASURED, not documented
    anywhere found, both members of Core Image's "color matrix" family
    treat their input as PREMULTIPLIED regardless of whether it actually
    is. `CIRandomGenerator`'s r/g/b/a are independent per-channel randoms,
    not a true premultiplied quadruple, so routing them through either
    filter performs an unwanted implicit unpremultiply/repremultiply that
    reshapes the distribution into `min(channel,alpha)/alpha` for uniform
    r/a — mean 0.7439, with exactly 24.6% of pixels pinned at 1.0
    (matching the analytic probability all three of r/g/b independently
    exceed the SAME shared alpha, `∫(1-a)³da = 1/4`). That distorted
    0.7439 zero-point was then measured a SECOND time only on a 64px test
    fixture, where the noise's later affine scale floors to a 1px no-op —
    real photos (`min(extent)` > 500px) hit a THIRD, independent
    distortion from the default bilinear resampler, drifting the mean
    further to ~0.82. Net compounded effect of all three: mid-gray at
    slider 1.0 rendered at ~0.62 (~+0.31 EV of pure lift) at real
    resolutions, not the intended few-percent artifact — a hidden,
    resolution-DEPENDENT exposure bug that every unit test in the original
    round-1 suite was structurally unable to see, because they all used
    small (32-64px) fixtures where the noise's affine scale is a no-op.
  - **Actual fix**: remove `CIColorClamp`/`CIColorMatrix` from the noise
    construction ENTIRELY. Verified directly (a passthrough kernel
    sampling the raw generator) that the kernel's own `__sample` mechanism
    delivers `CIRandomGenerator`'s true, undistorted values with no
    reinterpretation — the corruption was 100% a property of routing
    through those two specific filters, not of kernel sampling in general.
    The kernel already never read the noise argument's alpha (`n.a`), so
    once the clamp/matrix are gone there is nothing left forcing it
    opaque, and nothing needs to: the generator's independent random alpha
    is simply irrelevant to a kernel that only ever reads `n.rgb`.
    `kGrainZeroPoint` is 0.5 — confirmed BOTH analytically (the exact
    theoretical mean of a uniform-0...1 field) AND empirically (0.4994
    measured). Add `.samplingNearest()` before the noise's affine scale —
    MEASURED as still necessary on the corrected construction, just for a
    narrower reason than originally documented: bilinear resampling
    doesn't distort the MEAN on the fixed noise (measured within ~0.006
    of the true 0.4994 mean either way — well inside ordinary sampling
    noise for these fixture sizes), but it still shrinks the STD by ~34% once the cell
    exceeds 1px (adjacent random samples get averaged together, a real
    amplitude loss) — `.samplingNearest()` holds std flat within 4% across
    a 4x resolution range where bilinear alone would not.
  - **Monochrome by construction**: the kernel adds the SAME delta to r/g/b
    (averaging `CIRandomGenerator`'s three independent channels also
    narrows the noise toward Gaussian via the central limit theorem — a
    genuinely symmetric Bates(3) distribution about 0.5 — which is the
    "organic, not flat" look, with no second Size/Roughness slider).
  - **Tonal weight `w = 4*L*(1-L)` is a PRINCIPLED choice, not measured** —
    models developed-film density (grain vanishes at pure black/white and
    above 1.0 headroom); the measured shape across the tone range at
    slider 1.0, RE-MEASURED at 800px after the fix above (shadows 0.05 ->
    std 0.0547, mids 0.214 -> std 0.1642, mids 0.5 -> std 0.2019,
    highlights 0.8 -> std 0.1142, near-white 0.95 -> std 0.0324, headroom
    1.4 -> std ~0) confirms the parabola's real photographic behavior
    rather than just its formula.
  - **Ordering is measured, not conventional, on BOTH sides**: grain runs
    as the pipeline's new true final stage, after Sharpen AND after Noise
    Reduction. A temporary swap-rebuild-measure-revert harness (same
    method Curves v2 slice 3 used), RE-MEASURED after the fix above (the
    ordering conclusion did not change, only the exact figures): grain-
    before-sharpen measures std 0.23888 vs. the shipped order's 0.09936
    (~2.4x amplification — sharpen haloes the grain), and grain-before-NR
    measures 0.06439 vs. 0.09936 (NR silently ate ~35% of the grain).
    Sharpen's own doc comment and this file's Sharpen entry both
    previously called it "the pipeline's true final stage" — that
    STRUCTURAL claim is now false and was corrected in both places (its
    embedded MEASUREMENT records were left untouched).
  - **Resolution independence, a real design decision for this
    stage specifically**: noise cell size is `kGrainCellFraction *
    min(extent)`, the same fraction-of-extent mechanism Sharpen's radius
    already uses — a fixed pixel cell would make the interactive
    downscaled proxy show visibly larger grain that snaps smaller when the
    full-res frame settles, a flicker unique to grain among this
    pipeline's stages (the only stage whose signal is visible at the pixel
    scale on flat content). RE-MEASURED at 400/800/1600px after the fix:
    std 0.19946 / 0.20453 / 0.21236 — genuinely stable (<7% spread) across
    a 4x resolution range, a real improvement over the pre-fix
    construction's own much worse drift.
  - **Lower bound IS clamped, unlike Dehaze's own deliberately-unclamped
    result** — a real, measured necessity even with the CORRECTED,
    genuinely symmetric noise: near black, `w` is small but non-zero, so
    an unlucky strongly-negative sample can still push output to -0.0083
    (re-measured on a linear-0.02 patch after the fix; the pre-fix,
    asymmetric/skewed noise pushed as low as -0.0437, but the clamp is
    needed either way). Unlike Dehaze, where a negative intermediate
    value is a real byproduct an inverse optical model needs downstream,
    Grain is the pipeline's TRUE FINAL stage, so nothing downstream needs
    negative headroom, and "negative light" in the delivered image has no
    meaning — clamping the lower bound only (never the upper, preserving
    highlight headroom) is correct, not merely convenient.
  - **Mean brightness is not perfectly preserved** — measured, not assumed,
    at 800px (this drift is genuinely resolution-INDEPENDENT post-fix, so
    a small fixture isn't hiding anything the way it did pre-fix): adding
    zero-mean noise before the nonlinear perceptual encode/decode round
    trip drifts the rendered mean by up to +0.031 (at linear 0.214;
    smaller elsewhere), the expected signature of averaging a symmetric
    perturbation through a convex decode curve (Jensen's inequality), not
    a bug in the zero-centering.
  - **Noise pattern, not just amplitude, is coordinate-locked** — worth
    stating explicitly since Grain is the first stage in this pipeline
    with this property: replaying the same `EditState` against the same
    source at the same OUTPUT SIZE reproduces the identical grain pattern
    (deterministic, confirmed across independent `CIContext`s), but an
    export at a different resolution than the Editor's preview will show
    a different — still deterministic, still amplitude-consistent —
    noise realization, not a pixel match. `ImageRenderer.swift`'s own
    proxy-divergence stage list (a STRUCTURAL claim) needed `grain` added
    for the same underlying reason, and Grain is actually the MOST
    divergent stage in that list: the others differ in amplitude between
    proxy and full-res, Grain differs in its entire random pattern.
  - **`pickColorRangeTarget`'s hand-maintained field list** (`ImageDocumentModel.swift`)
    needed `grain` added alongside `vignetteStrength`/`texture`/`clarity`/
    `dehaze`/`noiseReduction`/`sharpness` — this exact list was already
    noted (line ~1525 above) as missing Dehaze once before; keep it in sync
    for any future post-mask stage.
  - **No new unit-testable claim about "the look"** — grain reading as
    photographic vs. digital noise, clump size, rolloff naturalness are
    subjective and live-verified instead, same precedent as
    `ToneCurveEditorView`'s untested SwiftUI interaction glue.
  - 1049 tests (16 new, all in `EditPipelineTests`' new `// MARK: - Grain
    math` block, plus small plumbing additions across the Codable/Preset/
    ComparisonOriginal/RawRedecode/Catalog test files following the
    existing `dehaze` pattern). Reviewer: round 1 FIX FIRST (caught the
    original, more superficial framing of the noise-distribution issue);
    round 2 FIX FIRST via an adversarial re-measurement that caught the
    round-1 fix's own deeper bug (see above) — this is the reviewer
    process working exactly as intended, not a process failure.
- **Color Grading — Slice A (backend) ✅ SHIPPED 2026-09-18, Slice B (UI)
  WANTED, not started.** 3-way Shadows/Midtones/Highlights color wheels
  (Lightroom's successor to Split Toning), each Hue/Saturation/Luminance — 9
  new `EditState` fields (`shadowHue`/`shadowSaturation`/`shadowLuminance`,
  `midtoneHue`/.../`highlightLuminance`), matching Selective Color's flat
  per-range field shape but genuine HSL angle/magnitude values (`hslHue`'s
  -180...180 convention), not amount-shift deltas like Selective Color's own
  `redHue`-style fields. User-confirmed v1 scope: the 3 wheels only —
  Blending/Balance and the 4th "Global" wheel deferred to a future slice.
  Two-slice split (backend then UI) explicitly chosen to mirror Curves v2's
  own slice 2A/2B precedent.

  `ColorGrading.cikernel` (8th custom kernel) selects by each pixel's own
  LUMINANCE — a raised-cosine falloff over LINEAR luminance distance from 3
  fixed anchors (0.0/0.5/1.0), the same mathematical FORM
  `SelectiveColor.cikernel`'s `bandWeights` already uses over CIRCULAR hue
  distance, applied to a different axis. Unlike Selective Color, this kernel
  needs NO `rgb2hsl`/`hsl2rgb` at all — each wheel's Hue/Saturation is a
  FIXED value per render, not pixel-dependent, so `ColorGradingTint.swift`
  (new, pure, `CoreImage`-free) converts it to a signed RGB tint delta ONCE
  per render in Swift via `ColorRangeSelection.rgb(forHue:saturation:lightness:)`
  (the existing pure HSL→RGB helper, reused rather than duplicated — its own
  doc comment was corrected to reflect this second caller) at `lightness:
  0.5`, minus neutral gray — a genuine simplification over Selective Color's
  on-GPU HSL round-trip, and it makes the hue/saturation math plain-XCTest-
  testable with exact numeric assertions instead of only reachable by
  rendering.

  **Two independent, both-measured reasons `applyColorGrading` runs LAST
  inside `applyPerceptualAdjustments`'s sandwich — not a style choice:**
  1. It must run AFTER Black & White's forced desaturation
     (`applySaturation(-1, ...)`), or the single most common real-world
     Color Grading use — tinting a monochrome photo for a sepia/split-tone
     look — would be silently erased. Live-confirmed via
     `testColorGradingTintSurvivesBlackAndWhite`: a shadow tint on a B&W
     photo produces r≠g≠b, not the flat gray B&W-alone would give.
  2. MEASURED (a temporary swap-rebuild-remeasure harness, this project's
     established method) not to commute with Vibrance/Saturation either: on
     a dark colored patch with Selective Color's `redHue`, global
     `hslSaturation`, and a shadow tint all active, running Color Grading
     BEFORE Vibrance/Saturation instead of its shipped position moved the
     red channel by 0.0105 — ~5.2x this suite's 0.002 tolerance. Pinned by
     `testColorGradingRunsAfterVibranceAndSaturation`.

  Weight function operates on the PERCEPTUAL (sRGB-gamma-encoded) luma,
  since the stage runs inside the perceptual sandwich — a first attempt at
  measuring the width constant used naive evenly-spaced LINEAR sample points
  (0/0.25/0.5/0.75/1.0) and was misleading, since gamma encoding compresses
  shadow detail into a much larger share of the perceptual range (linear
  0.25 is already just past perceptual midtone). Corrected to sample points
  chosen so their PERCEPTUAL encoding lands at ~0.1/0.3/0.5/0.7/0.9 instead —
  cross-checked against this file's own established "linear 0.214 ≈
  perceptual middle gray" figure. MEASURED (not guessed) constants, all
  hardcoded inside the kernel as local values (not user-adjustable in v1, so
  not passed as arguments — matching `SelectiveColor.cikernel`'s own
  `Wmin`/`Wmax`/`kHue`/`kLum` convention): width 0.4 (gives a clean
  partition — each anchor is the ONLY active range at its own center, with
  smooth overlap at the boundaries), tint strength 0.8 (strong, clearly
  visible at full Saturation without 1.5's runaway distortion), luminance
  strength 0.5 (meaningfully strong without blowing a midtone past 1.0 the
  way 1.0 does). These are v1's PRINCIPLED DEFAULTS for what Lightroom
  exposes as an adjustable "Blending" control (deferred), not a claimed
  reproduction of Lightroom's own undisclosed algorithm — same disclaimer
  precedent as Brilliance.

  **Two real kernel-math bugs caught by the reviewer's round-1 pass, both
  fixed, not just documented as limitations:**
  1. The kernel's first draft copied `SelectiveColor.cikernel`'s exact
     normalize-by-max-channel/rescale technique before adding the tint/
     luminance delta. Wrong here: SelectiveColor's operations are all
     RELATIVE (hue rotation, saturation multiply) inside the normalized
     domain, so the later rescale is harmless; this kernel's operations are
     ABSOLUTE additive offsets, so `(c/scale + delta) * scale == c +
     delta*scale` silently amplified the grade strength by the pixel's own
     headroom — the identical highlight tint measured ~3.04 on a
     1.4-linear white but only ~1.89 on a 1.0-linear white, an
     exposure-dependent grade strength with no such dependency intended.
     Fixed by adding the delta directly to the raw (unnormalized) pixel —
     the delta itself is now headroom-INDEPENDENT, confirmed by a
     regression test bounding the two cases' gap well below the old bug's.
  2. The luminance-classification `L` was also computed on the
     normalized value, which misclassified bright SATURATED pixels: a
     blown red `(1.5, 0.1, 0.1)` normalizes to `(1.0, 0.067, 0.067)`,
     whose luma (0.26) reads as "shadow," while the pixel's own real luma
     (0.398, clamped) correctly reads as "mid." Unlike SelectiveColor's HSL
     saturation formula (whose denominator genuinely goes undefined outside
     [0,1] — the actual bug that technique was built to prevent), this
     Rec.709 dot product is perfectly well-defined above 1.0 and needed no
     normalize at all. Fixed by computing `L` directly on the raw pixel.
     Both fixes turned out to be the SAME removal — dropping the
     normalize/rescale entirely fixes both defects at once.

  Headroom preservation is now correctly the SIMPLER property it always
  should have been: no destructive clamp to 1.0, no negative channels, and
  — now also correctly measured, not just asserted — the added delta's
  magnitude does not scale with the pixel's own headroom.
  `testColorGradingPreservesHighlightHeadroom` pins both the qualitative
  claim and a bound distinguishing the fix from the old bug's much larger
  gap (real encode/decode curve convexity alone still grows the gap
  somewhat with headroom, ~0.49 measured post-fix vs. ~1.15 pre-fix).

  Resolution-independent by construction (no radius/cell geometry at all,
  unlike Sharpen/Clarity/Grain) — confirmed empirically
  (`testColorGradingIsResolutionConsistent`), not just assumed, per this
  project's own convention. Does NOT join `ImageDocumentModel.
  pickColorRangeTarget`'s post-mask zeroed-field list or `ImageRenderer`'s
  proxy-divergence list — both verified by tracing the actual call order:
  Color Grading runs inside `applyPerceptualAdjustments`, which executes
  BEFORE `applyMasks` in the top-level pipeline, so its effect is already
  baked into any pre-mask sample (Selective Color, in the same sandwich,
  isn't in either list for the identical reason).

  20 new tests total (1049 -> 1069): 6 in a new `ColorGradingTintTests.swift`
  (pure Swift math, no rendering — zero-saturation-is-zero-delta, a
  hand-computed pure-red expectation cross-checked against
  `ColorRangeSelection.rgb` directly, hue-wraparound), 12 in
  `EditPipelineTests`' new `// MARK: - Color Grading math` block (isolation
  per range, luminance offset direction, alpha preservation, headroom, the
  B&W-survival test, resolution consistency, the pipeline-order regression
  pin), 2 more added to `EditStateCodableTests` (round-trip + missing-key-
  defaults, mirroring the `dehaze`/`grain` pattern exactly). Plumbing
  additions (no new test functions) to `EditStatePresetTests`,
  `EditStateComparisonOriginalTests`, `CatalogDatabaseTests`'s own fixtures.
  `AdjustTabView.isAdjustTabAtIdentity`/`resetAdjustmentsButton` extended in
  Slice A despite no UI existing yet — direct precedent from Curves v2 slice
  3 backend's own round-1 reviewer catch: without this, a photo carrying a
  Color-Grading edit from a preset or hand-edited sidecar would read as "at
  identity" with no way to clear it via Reset Adjustments.
- **Point Color — WANTED.** Lightroom's newer per-color eyedropper refinement
  (pick an exact color, then adjust ITS OWN Hue/Sat/Lum), distinct from this
  app's existing Selective Color (8 FIXED hue bands). A genuinely different
  targeting model, not a duplicate — likely needs a variable-length collection
  field (like `redEyePoints`, this app's only existing precedent for that shape)
  since the user picks arbitrary colors, not fixed bands.
- **Chromatic Aberration removal / "Defringe" — ✅ SHIPPED (2026-09-22).**
  Lightroom's Optics panel actually has TWO separate chromatic-aberration
  mechanisms: an automatic "Remove Chromatic Aberration" checkbox (needs
  per-lens profile calibration data this app has no source for and won't
  build a database for) and manual Defringe sliders (a LOCAL, hue-selective
  chroma suppression at high-contrast edges, no lens metadata needed).
  Scoped deliberately to Defringe alone — not a future slice of the same
  feature, a fundamentally different mechanism this app can't build.
  - Two new `EditState` fields, `defringePurple`/`defringeGreen` (0...1,
    identity 0), matching `dehaze`/`clarity`/`texture`'s own
    single-Amount-per-effect v1 convention. The hue windows that define
    "what counts as purple/green" are fixed tuned constants in
    `EditPipeline` (`kDefringePurpleHueCenter`/`kDefringeGreenHueCenter`/
    `kDefringeHueWindow`), not exposed — same precedent as Dehaze's own
    prior parameters.
  - **The 10th custom kernel** (`Defringe.cikernel`), built the same
    two-part way Dehaze is: `CIMorphologyMaximum`/`Minimum` on a luma image
    (built via `LuminanceRangeSelection`'s own weights, reused not
    reinvented) supply a local edge/contrast signal a `CIColorKernel`
    cannot compute itself, then one per-pixel kernel does hue-selection +
    edge-gated desaturation — headroom-normalize before `rgb2hsl` and a
    saturation-gated hue axis, both proven fixes reused from
    `SelectiveColor`/`ColorRange`/`PointColor`'s own history.
  - **Domain: perceptual** (gamma-encoded), matching the hue-selecting
    kernel family (`SelectiveColor`/`ColorGrading`/`PointColor`), unlike
    Dehaze's physically-modeled scene-linear domain — "what looks purple"
    is a display-referred judgment.
  - **Ordering: one real requirement, one convention — and the story took
    THREE corrections to get right**, worth recording in full since each
    correction was caught by a DIFFERENT independent reviewer re-measurement,
    not by re-reading the existing diff. (1) A first draft of the
    Sharpen/Defringe ordering test built its "reversed" case with a nesting
    bug that accidentally applied Sharpen before Defringe BOTH times —
    comparing an order against itself, "measuring" a false commute that
    every doc comment then repeated. (2) Fixing that bug produced a test
    that sampled only x=400/401 — the two pixels where the shipped order
    happens to win — and the doc comments then claimed a "measured
    requirement." A wider 9-point sweep (independently reproduced, not
    just trusted from the reviewer's own numbers) shows the REVERSED order
    actually wins at 4 columns, shipped at 3, ties at the 2 pixels
    carrying real input fringe, and leaves ~46% LESS residual chroma in
    AGGREGATE. The mechanism claim was ALSO wrong: at most sampled pixels
    the input is already perfectly neutral (chroma 0), so Sharpen mostly
    MANUFACTURES fresh fringing next to a misregistered edge rather than
    "shifting" an existing fringe's hue. Per CLAUDE.md's own rule for a
    measurement that comes back weak, this ships as a CONVENTION (Sharpen
    is a documented fringing producer elsewhere in this codebase, so
    Defringe naturally reads as the cleanup step), NOT a requirement — see
    `testSharpenBeforeDefringeIsAConventionNotARequirement`, which now
    asserts the aggregate finding directly rather than two favorable
    pixels. (3) A SEPARATE, genuinely unconditional requirement was found
    investigating Defringe's relationship to Grain: Grain's per-pixel
    noise, if it ran BEFORE Defringe, fools the edge gate into treating
    FLAT content as a real edge EVERYWHERE, breaking the
    flat-subject-protection guarantee across the whole image (measured: a
    flat saturated purple region desaturates almost to gray) — Defringe
    running before Grain avoids this entirely
    (`testDefringeMustRunBeforeGrainOrTheFlatGuardBreaks`, a real,
    MEASURED, unconditional requirement, unlike the Sharpen ordering).
    Final order: `... Sharpen -> Defringe -> Grain` (true final stage) —
    kept, but for a mix of reasons (convention + requirement), not
    because both legs are equally proven.
  - **A real image-math bug, not just a doc/test issue**: the luma image
    `applyDefringe` feeds to the morphology filters is built via a
    `CIColorMatrix` with a forced-opaque alpha bias (`biasVector.w = 1`),
    which makes Core Image report its extent as INFINITE — the exact same
    hazard `luminanceRangeMaskImage`'s own doc comment already documents
    in detail. `.clampedToExtent()` on an ALREADY-infinite image is a
    no-op, so without an explicit `.cropped(to: extent)` first, the
    morphology filters read true zero just outside the real frame,
    desaturating a resolution-dependent ring around the ENTIRE border of
    every image (measured before the fix: a flat saturated purple 400x400
    desaturated to chroma ~0.015 in the border ring vs. the correct 0.55
    interior). Fixed and locked in with a permanent test,
    `testDefringeDoesNotDesaturateTheFrameBorder`.
  - **Known limitation, reviewer-caught**: the edge gate protects FLAT
    purple/green subjects (a flower, a lawn — the structural guarantee it's
    designed for) but NOT TEXTURED ones in the target hue. A real
    foliage-against-sky green region reads as a genuine edge and gets
    desaturated too (measured: chroma 0.270 -> 0.022). Inherent to any
    hue-band defringe approach without a separate selection axis —
    Lightroom's own Defringe exposes a Hue Range control for exactly this
    reason, not built here. IMPROVEMENTS.md D24.
  - Reviewer: FIX FIRST → FIX FIRST (round 2 caught the ordering
    overclaim above, the border extent bug above, and a stale
    downstream-field list — see below) → [status at time of writing:
    round 3 pending]. Round 1's most serious catch was the vacuous
    ordering-test bug above; it also caught two test fixtures
    (`testDefringePreservesHighlightHeadroom`/
    `testDefringePreservesExtentAndAlpha`) that sampled FLAT content where
    the kernel's edge gate never engages, so they'd pass even with the
    active code path broken (fixed to sample inside a real fringe band —
    the alpha fixture fix surfaced a second real finding, that
    `CIColorMatrix`'s implicit premultiply-on-output behavior, the SAME
    mechanism this file's own Grain entry documents, means scaling ONLY
    `inputAVector` is the correct way to build an alpha<1 fixture, not a
    manual all-four-channel rescale, which looked more obviously correct
    and is actually wrong — double-scales), an overclaiming "two halves"
    test comment (only one half was ever asserted), a 5°-off hue-label
    comment, and two stale pipeline-stage enumerations. Round 2 caught, in
    addition to the ordering overclaim and the border bug above: a stale
    downstream-field list (`ImageDocumentModel.pickColorRangeTarget`, the
    Color Range mask eyedropper's own sampling helper, zeroes every global
    stage that runs after the mask stage so its sample matches what
    `ColorRange.cikernel` actually sees — `defringePurple`/`defringeGreen`
    were missing, the THIRD time this exact list has gone stale, per
    CLAUDE.md's own standing note); a misleading test-fixture comment
    (`misregisteredEdgeImage`'s alpha-reset step does NOT leave RGB
    untouched as claimed — the same implicit-premultiply mechanism divides
    it by 3, so the fixture's `lo`/`hi` arguments don't describe its
    actual on-screen contrast, though every numeric assertion using it
    remains correct since it's derived from the real render); and three
    more stale structural proxy/thumbnail-divergence enumerations
    (`ProxyScale.swift`, `ImageRenderer.swift` x2) missing Defringe's own
    extent-fraction radius. All fixed and reverified; 1155 tests pass
    (round 2's border-bug fix added one permanent regression test). NOT
    yet committed — see PROGRESS.md for current status before assuming
    this shipped cleanly in one pass. NOT yet live-verified against a
    real photo — see PROGRESS.md's "Exact next step".
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
    black. **LIVE-VERIFIED 2026-09-17**: headroom measured 31-49 levels away
    from what the old clamped path predicts and 0.4-3.3 from the
    headroom-intact reference; the low-end clamp still renders pure black;
    no banding on a real RAW; user's 1608 library files byte-identical.
    **Two recorded claims were
    measured to be FALSE while doing this** — `CIToneCurve` does NOT
    extrapolate below point0.x (it clamps at both ends; the "soft black point"
    is in-domain spline shape), and `luminanceRangeMaskImage` cited that false
    claim in its own rejection rationale. Both corrected in place. See
    PROGRESS.md's slice-1 section, including why believing the false claim
    would have broken Black Point.
  - **Slice 2A ✅ SHIPPED (2026-09-17)** — `EditState.toneCurvePoints` +
    `MonotoneToneCurve` + `PointToneCurve.cikernel` add the user's point curve
    as a SEPARATE, ADDITIVE stage after the parametric one. Monotone cubic
    (Fritsch-Carlson) for the user curve, natural cubic kept for the
    byte-exact parametric layer — a separate TYPE, not a mode flag, so that
    contract is structural. Variable point count renders through a
    fixed-arity kernel via a provably-free pad-to-8 scheme; cap is 8 points
    (the `vec4` argument budget). Stage order MEASURED non-commuting at
    0.07468 vs the 0.002 tolerance, so it is a requirement, not a convention.
    No UI yet.
    **The migration mandated in the bullets above is now MOOT**: because the
    parametric layer is untouched, no shipped field changes meaning and no
    `LegacyCodingKeys` work is needed. Do not go looking for it.
  - Slice 2B (the editor UI) is the remaining work and the hard part. Approved
    plan: `~/.claude/plans/declarative-wondering-mist.md`. Its blocking gate is
    that this is the first VERTICAL drag inside the sidebar's vertically
    scrolling `ScrollView` — green tests and a reviewer APPROVE are explicitly
    NOT sufficient evidence there (see the StableScrollInsets precedent).
  - Slice 3 is per-channel R/G/B. Three more curves will not fit one kernel's
    argument budget; the likely answer is four passes of the same kernel with a
    channel-selector argument, so the 8-point cap is not a dead end.
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
- **Auto Tone / Auto Settings — ✅ SHIPPED (2026-09-23).** One-click
  starting-point adjustment. Followed the anticipated shape exactly: "Fix
  Color Cast" (`ImageDocumentModel.fixColorCast()`, whole-image gray-world
  statistical analysis feeding existing WB fields, no ML) was the precedent,
  and Auto Tone follows the same "compute stats off the already-decoded
  image, write several existing `EditState` fields at once, one button"
  pattern — a heuristic v1, no ML needed.
  - **`Sources/EditEngine/ToneStatistics.swift`/`Sources/Rendering/
    ImageToneStatistics.swift`** (the statistics layer, committed first):
    linear-luma percentiles at 0.5/5/50/95/99.5%, a Reinhard log-average
    scene key, and a perceptual chroma proxy — structurally mirrors
    `ImageAverageColor` but deliberately does NOT apply that type's own
    min/max-luma exclusion band, since Auto Tone's whole job is to
    characterize exactly the shadows/highlights that filter exists to
    throw away for gray-world WB averaging's different purpose.
    Reviewer-caught, round 1: `CIContext.render`'s PREMULTIPLIED output
    was being read as if straight — a resample's edge row/column commonly
    lands at a fractional alpha (still passing the `>= 0.5` qualifying
    guard) whose RGB had therefore been scaled down by that alpha.
    MEASURED: on a uniform 0.18-gray 3000x2000 bitmap, this alone pulled
    `percentile0_5` down to 0.134 — an entirely fabricated "lifted black."
    Fixed by dividing by alpha; `ImageAverageColor`/`PixelSampler` share
    the identical latent bug, logged as IMPROVEMENTS.md D25 (out of scope
    to fix in this diff). Round 1 also caught that every constant-color-
    generator test fixture (`CIImage(color:).cropped`) is structurally
    incapable of exercising this bug at all — Core Image folds a constant
    generator through the resample with no real edge to bleed across —
    so the regression tests needed genuine bitmap-backed fixtures
    (`CIImage(bitmapData:...)`), a distinction worth remembering for any
    future test in this statistics family. Round 2 caught that the new
    rank-pinning test's own tolerance (0.01, ~2.5 column-steps on a
    256-column ramp fixture) was loose enough to silently accept a wrong
    nearest-rank convention — tightened to 0.001, re-verified exact.
  - **`Sources/EditEngine/AutoToneSolver.swift`**: solves Exposure/Black
    Point/Highlights/Shadows/Contrast/Vibrance from a `ToneStatistics`.
    Only Exposure has a genuine closed-form solve (`log2(targetKey /
    logAverageLuma)`, a pure linear-light multiplicative gain, clamped to
    ±3 EV); every other field is a proportional-error heuristic against a
    target, clamped to a conservative maximum. Deliberately does NOT
    solve for Brilliance (would double-count with Contrast/Shadows/
    Highlights via `EditPipeline.effectiveTone`'s own render-time blend),
    Brightness, Levels, or the point curve — v1 scope, touching only the
    parametric Light-section fields a real Auto-Tone workflow most
    directly maps to. Also does NOT write White Balance — Fix Color Cast
    stays its own separate button, matching Lightroom's own Auto/WB-Auto
    split (user-confirmed scope decision). Reviewer: 5 rounds, FIX FIRST
    x4 → APPROVE, the deepest review chain of this session:
    - **Round 1 — Black Point's "closed-form inverse" was wrong.** The
      first draft set `point0.x = predictedP0_5 / kBlackPointSpan`
      directly, inverting `EditPipeline.curveControlPoints`'s own
      `point0.x = max(0, -blackPoint) * kBlackPointSpan` — reasoning that
      moving point0.x to exactly the measured floor would clip that level
      to 0. It does not: `ToneCurve.cikernel`'s own `toneCurveValue`
      re-encodes its input a SECOND time before comparing against
      `point0.x` (that kernel's own header comment already documents this
      exact hazard — "the encode here is the filter's OWN and is a SECOND
      encode" — for `applyCurves`' callers generally), so `point0.x` lives
      in double-encoded space while `predictedP0_5` is only single-encoded.
      MEASURED: the first draft's `point0.x` undershot the pixel's own
      double-encoded position by 3-7x across several realistic floors,
      never actually clipping the level it claimed to target. Fixed by
      encoding a second time, matching the kernel exactly — which then
      revealed a real, accepted STRUCTURAL limit, not a further bug:
      `kBlackPointSpan`'s own 0.20 reach (tuned for the SLIDER's own feel,
      not for this solver) means `point0.x`'s own maximum, even at
      `blackPoint = -1`, maps back through the double encode to only
      linear ~0.003 — this mechanism can only ever clip a floor already
      very close to true black. `kBlackTargetPerceptual` was re-derived
      (0.02 → 0.005) to sit inside that narrow reachable window instead of
      past it — MEASURED, the non-saturating response window is only
      about linear 0.000387 (trigger) to 0.000776 (full saturation);
      outside that razor-thin band the mechanism is effectively binary
      (0 or `-kMaxAutoBlackPoint`), an honest v1 characteristic now
      documented as such rather than hidden behind a formula that looks
      more graduated than it really is. Logged as IMPROVEMENTS.md D26: given
      this, Black Point saturates to its own maximum for nearly any real,
      well-exposed photo (MEASURED: even a plain 0.18-gray fixture with no
      distinct shadow region solves to exactly -0.5) — a genuine v1 design
      question (is a consistent moderate deep-shadow crush a reasonable
      Auto default, the way some real "Auto" presets do?) worth live-tuning
      against real photos, not a bug.
    - **Rounds 2-4 — the session's deepest finding: Contrast can
      independently crush the very shadow floor Shadows is trying to
      lift, in TWO separate stages.** Found entirely by the end-to-end
      tests (`AutoToneEndToEndTests`, which render synthetic fixtures
      through the REAL `EditPipeline` and re-measure) — the pure solver
      tests alone never exercised the actual pipeline interaction and
      would not have caught either stage. STAGE 1: `EditPipeline`'s
      `CIColorControls` Contrast stage runs BEFORE Curves (where Shadows/
      Black Point actually operate), pivoting at 0.5 —
      `output = (input - 0.5) * (1 + contrast) + 0.5`. On a real
      crushed-shadow fixture, an uncapped Contrast solve pushed
      `predictedP5` NEGATIVE, and any negative value clips HARD to 0 in
      the curve stage (`point0.x` is never negative) — MEASURED, the full
      solve's `percentile5` came out at `4.96e-11`, essentially zero,
      DARKER than doing nothing at all, on a fixture Auto Tone had
      correctly diagnosed as needing a Shadows LIFT. First fix attempt:
      cap Contrast to stay merely non-negative, and suppress Black Point
      outright whenever Shadows triggers (the two fields have directly
      contradictory goals whenever both trigger on the same pixels, since
      `kBlackTargetPerceptual` sits far below `kShadowFloorPerceptual`).
      That FIRST fix attempt itself broke 2 pre-existing, already-passing
      tests (`testPunchyHighSpreadImageGivesNegativeContrast`,
      `testContrastNeverExceedsItsClampOnThePunchySide`) — a blanket
      "suppress Contrast whenever Shadows triggers" also zeroed out a
      genuinely NEGATIVE, beneficial Contrast solve on a punchy/
      high-spread image, since negative Contrast only ever pulls a value
      TOWARD the pivot (helps), never away from it (crushes). Corrected to
      `min(contrast, 0)` — block only the crushing (positive) direction.
      STAGE 2, caught by re-review AFTER stage 1's fix: a floor just ABOVE
      `kShadowFloorPerceptual` (where Shadows itself does NOT trigger, but
      Black Point still can) reproduced the IDENTICAL `4.96e-11` symptom
      via a different path — capping Contrast to merely non-negative
      still left it small enough to land inside Black Point's own
      double-encoded clip zone. FINAL fix: a single, correctly-derived cap
      — `maxSafeContrast = max(0, (predictedP5 - kShadowFloorPerceptual) /
      (0.5 - predictedP5))`, solving for the Contrast value that keeps the
      POST-CONTRAST output at or above `kShadowFloorPerceptual` itself
      (not just non-negative) — MEASURED, `srgbEncode(0.05) ≈ 0.248`,
      comfortably (~2.5x) clear of Black Point's own maximum possible
      reach (0.10 double-encoded). This one formula subsumes the earlier
      `min(contrast, 0)` override entirely (below the shadow threshold the
      cap itself evaluates to 0, reproducing that exact behavior) — the
      separate override was removed. Round 5 (independent re-derivation
      plus a 95-fixture sweep — 5 midtone levels × 19 floor levels — through
      the REAL pipeline) confirmed the final math and found only stale doc
      comments left over from the earlier fix attempts.
  - **`ImageDocumentModel.autoTone()`** (the UI wiring, committed last):
    samples geometry + white balance (`geometryOnlySamplingState()` plus
    an explicit Temperature/Tint copy — Auto Tone measures the
    WB-corrected image without ever writing WB itself), guarded by the
    same `analysisGeneration` stale-write token `fixColorCast()`'s own
    bug fix (below) introduced, and commits all 6 solved fields as ONE
    atomic undo step (`finalizePendingCommit(); ...; history.commit(next);
    applyHistoryState(...)`, the same pattern `applyPreset(_:)`/
    `revertToOriginal()` already use) rather than through the debounced
    `editState` `didSet` path `fixColorCast()` uses — `fixColorCast()` can
    get away with debouncing because it only ever writes 2 tightly-coupled
    fields; Auto Tone writes 6, and letting them merge into an in-flight
    burst (or split across two commits if a slider drag lands in the
    debounce window) would make a single ⌘Z behave inconsistently
    depending on timing. A new "Auto" button, the first row of the Light
    section, styled identically to the pre-existing "Fix Color Cast"
    button. No new `EditState` fields, so `isAdjustTabAtIdentity`/
    `resetAdjustmentsButton` needed no changes. Reviewer: APPROVE, no
    issues found.
  - **A real, pre-existing bug fix, discovered while planning this
    feature and shipped as its own first commit**: `fixColorCast()`'s
    background analysis had NO guard against a stale result landing on a
    DIFFERENT photo than the one it analyzed (switch photos mid-analysis
    → the old photo's Temperature/Tint silently writes onto the new
    photo). Fixed with the same `analysisGeneration` token Auto Tone now
    also uses — bumped once per SUCCESSFUL photo switch, in
    `resetHistory()` (deliberately NOT `loadGeneration`, which also bumps
    on a RAW-native re-decode and would wrongly invalidate an in-flight
    analysis of the SAME photo). Also extracted `fixColorCast()`'s own
    inline geometry-field-copy block into a new, reusable
    `EditState.geometryOnlySamplingState()` — a pure refactor Auto Tone
    then reused directly rather than duplicating.
  - 1199 tests (55 new across the 3 commits: 9 `ImageToneStatisticsTests`,
    25 `AutoToneSolverTests` including a Black Point regression run
    through the real `ToneCurveSpline` kernel twin, 5
    `AutoToneEndToEndTests` exercising the actual measure → solve →
    render → re-measure loop, 2 new `EditStateGeometryIdentityTests` tying
    `geometryOnlySamplingState()` to `isGeometryAtIdentity`). NOT yet
    live-verified.
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

## Pick / Reject flags (2026-09-29)
Replaced the boolean `photo.isFlagged` with a three-state `FlagStatus`
(rejected -1 / none 0 / picked 1). `Migrations/007_pick_reject_flags.swift`
adds `flagStatus`, converts flagged rows to Picked, and drops `isFlagged`
(GRDB `drop(column:)`, SQLite 3.35+; the column had no index/FK).
`LibraryFlagFilter` (All/Picked/Unflagged/Rejected/Hide Rejected, default All)
replaces `flaggedOnly`. UI: one flag icon per cell (click toggles Pick; a
Rejected photo clears to unflagged), a Pick/Reject/Unflag section in the
Photo-options menu, keys P/X/U (legacy `.`/`f` still toggle Pick), rejected
thumbnails dimmed to 0.45. Reviewer: FIX FIRST -> fixes (misplaced doc
comments, menu VoiceOver labels, a `toggledPick` unit test). The migration
upgrade test builds a real pre-007 database and would fail if either the
UPDATE or the column drop were removed.

## Phase 8 close-out: large-image + edge-case audit (2026-09-30)
Approach chosen with the user: "measure first, fix what breaks." A temporary
XCTest harness (run one size per process so a crash/memory blow-up can't
take the rest down; deleted afterwards) drove the real code paths on scratch
fixtures streamed to disk (never the user's library). Machine: Apple M1-class,
8 CPUs, 8.0GB RAM. Edit set ("heavy"): exposure, contrast, saturation,
vibrance, Clarity, Texture, Dehaze, curve shadows, noise reduction, plus one
radial mask with exposure+Clarity. Peak = process `ru_maxrss` (GPU memory not
included).

| Size | Thumbnail (edited) | Proxy @0.25 | Full-size heavy-edit JPEG export | Peak RSS |
|---|---|---|---|---|
| 6016x4016 (24MP) | 0.42s | 0.11s | 1.41s | 180MB |
| 12000x8000 (96MP) | 0.13s | 2.19s | 21.81s | 556MB |
| 20000x10000 (200MP) | 0.53s | 9.70s | 405.31s | 921MB |
| 30000x400 | 0.32s | 0.40s | 1.29s | 238MB |

Every export's decoded dimensions matched its source. Diagnostics for the
200MP slowness: 16000x12500 (200MP, both sides <=16384) heavy = 478.36s,
peak 1009MB, so the 16384px texture limit is NOT the cause; 20000x10000 with
exposure only = 8.26s (peak 1395MB), so the cost lives in the heavy stages,
not the pipeline base. The per-stage cause was NOT profiled: extent-fraction
radii in Clarity/Dehaze/Texture would predict ~area^1.5, but growth was 15.5x
for 4x area (24->96MP) and 18.6x for 2.08x area (96->200MP), which looks more
like a cliff (D17's ROI dilation, or memory pressure on an 8GB machine) than
smooth radius scaling. Possibly related to D17's ROI dilation (unverified). Not fixed: correct output,
RSS-only peaks (GPU memory not measured) well under the 60%-of-RAM threshold; recorded as IMPROVEMENTS.md D36.

Edge-case matrix (open/thumbnail/export, small files): 1x1, 1x4000,
grayscale JPEG, 16-bit PNG, CMYK JPEG, EXIF orientation 6 and 8 (dimensions
swap correctly), PNG with alpha, 16-bit TIFF all decode, thumbnail and export
correctly. Zero-byte and non-image bytes named .jpg return a clean
`unreadableSource` error (no crash, no hang). A truncated JPEG decodes and
exports with no error (partial content) — IMPROVEMENTS.md D37.

Live check (Release build, scratch JPEGs, user-approved automation): 12000x8000
and 20000x10000 open via Open... and draw in the Metal view at the correct
aspect; an Exposure drag on each visibly re-rendered (200MP: mean canvas luma
123.6 in the capture ~4s after dismissing the sidecar prompt, 178.2 in the next
capture ~3s later and unchanged after); app RSS 162MB at
200MP. NOT verified: pan/zoom at these sizes, and slider-drag latency (the
sidecar folder-access prompt interrupts the run loop, so timing was not clean).
Not tested at all: a large RAW (only a D610 is on hand and the RAW path was
already measured in Phase 6), and Enhance at these sizes (already guarded by
`SuperResolutionUpscaler.maxTextureDimension` with a Lanczos fallback and
unit tests).

## Phase 8 follow-up (2026-09-30): D37 shipped, D36 profiled, live interactive pass
**D37 (shipped).** ImageIO's `CGImageSourceGetStatus` reports `complete` for
truncated JPEG/PNG/TIFF at every cut (90/50/10% and last 16 bytes) so it can't
detect truncation; a truncated TIFF already fails to decode. `SourceIntegrity`
walks the JPEG segments / PNG chunks to the end marker; export and Enhance throw
`incompleteSource` on positive evidence only. Real library (1094 photos):
95 JPEG + 49 PNG complete; 930 NEF, 7 HEIC, 1 TIFF and 1 TIFF-named-.jpg unchecked;
11 unreadable/missing; 0 flagged (95+49+930+7+1+1+11 = 1094). Known,
accepted: a JPEG/PNG with complete pixel data but no final EOI/IEND is refused.

**D36 (profiled, not fixed).** Full per-stage table lives in IMPROVEMENTS.md D36.
Headline (noisy fixtures, full-size JPEG export, single runs, ranges up to 2x):
exposure baseline 0.14s/8.74s/30.92s at 24/96/200MP; Clarity alone 0.24/7.47/33.53;
Dehaze alone 0.57/9.06/78.82; Clarity+Dehaze 0.70/15.13-27.09/208.84; everything at
96MP 48.19-97.30s noisy vs 18.97s noiseless. Machine: 8GB, 4.0-4.6GB swap in use.

**Live interactive pass** (Release build, scratch JPEGs 12000x8000 and 20000x10000,
scratch folder granted once; frames = canvas screenshots every ~0.2s starting after
the input command returned, so times are release-to-visible-change and include
~0.2s capture latency). Synthetic scroll-wheel events (CGEvent) reach the app.
96MP: pan +0.23s; Contrast +0.5s; zoom-in first visible change ~1.5s after the last
event (single jump); zoom-out partial at once, final +1.4s; Clarity -100% first change
+14.6s, settled +20.5s. 200MP: pan +0.24s; zoom-in +2.5s; zoom-out partial +0.2s, final
+6.6s; Contrast +51% changed +6.3s after release (plus a near-zero 0.12-diff frame blip at +6.0s). INVALID and withdrawn: an
earlier "Clarity/Dehaze drag" timing whose sliders never moved (sidecar showed
clarity 0, dehaze 0). NOT measured: Dehaze slider latency — three drag attempts never
registered under automation (Clarity, Contrast and Exposure sliders did). Anomalies
(not root-caused): an invisible "Open" panel wedged the app twice until quit
(automation-related suspected); a transient solid-green rectangle appeared on the
canvas once at 96MP after zoom/pan + exposure/contrast/Clarity edits and did NOT
reproduce on a fresh open of the same saved edits (IMPROVEMENTS.md D38).

## Batch rename (2026-09-30) — Export naming + Library "Rename Files…" with Undo
User-chosen scope: both features on one shared template engine; safety = preview + collision refusal + Undo.
Commits: `b4bcb3a` naming engine + `CaptureDate`; `38d9c5f` Export naming (`ExportNamePreview` seam);
`08968f5` rename plan/engine/log/applier + Migration 009 + D39 fix; then the UI (`RenameModel`, `RenameSheetView`,
`CatalogModel` rename methods, toolbar/Photo-menu wiring) merged from `wip/batch-rename-commit4` (last commit
`1d93a06`); docs commit follows this entry.

**Why it is the riskiest feature so far:** first time the app changes the on-disk NAMES of the user's originals.
Design decisions worth knowing before touching it:
- Files first, then the catalog (one GRDB transaction that also writes/trims the rename log to the last batch,
  two-pass path update so chains/swaps don't trip the UNIQUE `path`); a failure in either half rolls the other back.
- `RenameEngine`: `renamex_np(RENAME_EXCL)` (fails instead of replacing; check-then-rename fallback only where the
  volume lacks it), two phases through hidden `.photoapp-rename-<token>-<n>-<original>` temp names, in-memory journal
  replayed backwards on failure, a sidecar is only ever moved WITH its photo and a foreign sidecar at the destination
  is refused. Known gap: a crash between phases leaves the batch hidden (D40).
- `RenamePlan` is pure and all-or-nothing: any blocked photo (collision incl. case/NFC folding, existing file/sidecar/
  catalog path, missing source, open in the Editor, target = the Editor's open photo, selected twice) blocks the batch.
- `RenameModel` re-plans against fresh disk/catalog state right before applying, and re-checks AFTER the modal folder
  prompt with no `await` before acting; refuses while anything else is busy or ANY `runModal` panel is up
  (`RenameBusyState`, `NSApp.modalWindow`); other catalog mutators (import/locate/remove) refuse while
  `isRenameInProgress`; every other open/export/enhance/paste entry point is gated on `renameModel.isWorking`.
- Reviews: commit 3 took 2 rounds (found the foreign-sidecar-on-undo gap, wrong undo recovery message, crash
  breadcrumbs, lstat vs dangling symlinks, case-insensitive catalog check); the UI took 5 rounds (gating of other
  features during a rename, checks moved AFTER the folder prompt, generation tokens, canonical path matching,
  modal-panel catch-all, error routing when the sheet vanishes). Every fix was mutation-checked.

**Live verification (2026-09-30):** Release build, 5 scratch JPEGs with EXIF dates (one with an existing sidecar)
imported into the REAL catalog (backed up first; Migration 009 applied on launch). Sheet opened from the selection
menu; preview `{date}_{seq:2}` showed each photo's own capture date and grid-order numbers; template `same` showed 5
blocked rows in red and Rename disabled; Apply from the attached sheet passed the busy check (attached sheet is not
`NSApp.modalWindow`) and reached the folder-access prompt (sheet dimmed, spinner, buttons disabled); after granting,
files + the sidecar were renamed on disk, the 5 rows were updated, the log held 1 batch / 5 entries, and the success
alert appeared; "Undo Rename" from the Photo menu restored files, sidecar and rows and cleared the log. The scratch
rows were then deleted; the catalog matched the pre-run baseline exactly (1094 photos, 0 flagged/labeled, 15
collections, rating sum 11, path-length sum 63679, integrity ok) apart from Migration 009. NOT verified live: Export
naming sheet, Photo-menu "Rename Files…", the Editor-open block, post-rename thumbnails, multi-folder selections,
real-SwiftUI re-present of a dropped sheet, alert timing on slow machines.


## Vision subject-mask feasibility spike (2026-10-01) — decision: GO for a `.subject` mask kind

Spike only: no `MaskKind`, no `EditState` field, no UI. Permanent probe:
`Tests/RenderingTests/VisionSubjectMaskProbeTests.swift` (3 tests; orientation test mutation-checked — moving
the fixture subject to the right half makes it fail). Numbers below come from a temporary scratchpad harness
(deleted), run on this Apple M1 8GB machine; real photos were COPIED to the scratchpad, originals untouched.

Measured (`VNGenerateForegroundInstanceMaskRequest`, revision 1 = `currentRevision`):
- Works; empty result on a featureless gradient is `results?.first == nil` (no error, ~16ms).
- Native `instanceMask` is a fixed 512x512 8-bit (`OneComponent8`) raster for every input whose native size was printed (1500x1000 synthetic and the three real photos that found a subject: 3024x4032, 8192x5464, 6016x4016 NEF;
  the other synthetic sizes only had latency measured). `generateScaledMaskForImage` returns input-sized 32-bit float (`OneComponent32Float`), extent
  exactly equal to the input.
- Orientation: synthetic left-third subject put all mask mass on the left (right half 0.0). Passing `.right` to the
  handler still produced a 512x512 observation. Via `CIRAWFilter` (unoriented output) the mask aligned with the
  rendered pixels — the mask follows whatever pixels it is given.
- Determinism: 5 runs on the same input, native masks byte-identical (in-process; cross-OS-version not testable here).
- Latency (warm, request / scale-to-input ms): 1024x683 15/6; 1600x1067 17/7; 3000x2000 22/11; 6016x4016 43/35-48;
  real photos warm: IMG_6328 (3024x4032) 28/20, DSC_1532 NEF (6016x4016) 24/42, 4K2A0050 JPEG (8192x5464) 422/397
  (cold first pass on that file 444/482). The 8192 file is an outlier vs. the 6016 figures; cause not investigated
  (size, content, or JPEG decode — unexplained). First call in a process: ~0.33-0.93s cold. RSS delta at 6016x4016: ~89MB.
- Real photos: 5-person group on a ridge: 4 instances found with clean silhouettes (viewed), the crouching 5th person was
  NOT selected (a model limitation — a user would need Add/brush-subtract refinement); underwater divers (3 overlapping): 1 instance covering all three as one blob, tight edges (viewed); unoriented D610 RAW (DSC_1532): single standing figure, good. No subject found
  on one phone JPEG and one D610 RAW (observation nil) — the empty path is real, not hypothetical.

Recommended architecture for the follow-up slice (not built):
- Native mask is only 512x512 8-bit => tiny to persist (256 KiB uncompressed (512x512x1); PNG size not measured; confirm in the slice) and
  edges come from model upscaling, so a Feather/edge-refine control (Lightroom has one) is likely wanted.
- Determinism is only established in-process on this OS; a model update can change masks, so PERSIST the raster
  (sidecar-adjacent or embedded) with the request revision pinned, like `rawDecoderVersionPin`; do not recompute on
  every render. Compute once on user action off the main thread (~0.4s+ for big files; cold start up to ~1s).
- Pipeline fit: a `CGImage`/CI-backed finite-extent mask matches the `.brush` kind's contract in
  `maskImageAndRegion` (no new kernel; combine/intersect/subtract reuse `Mask.combineMode`). NOT yet verified by an
  end-to-end render — the first slice must prove it.
- Cut: Sky/Landscape/Object/Depth masks are NOT provided by this request (would need a Core ML model or other API) —
  still separate spikes. Multi-instance selection (pick which person) is available via `allInstances`/pixel hit-test.
- A persisted raster is tied to the pixel space it was computed in (unlike `.brush`, re-rasterized from geometry each
  render): the slice must define the stage it is computed/applied in (pre/post orientation, crop, transform) and how it
  is resampled to proxy vs. full-res extents.

## AI Subject mask — `MaskKind.subject` v1 (2026-10-01): Subject + Invert

Follows the Vision spike above. 4 commits, each reviewed by `reviewer` (Opus) and mutation-checked; suite 1573 -> 1607 tests, 0 failures.

Design (decided in Plan Mode, scope chosen by the user: "Subject + Invert"):
- **Persisted raster, not parameters.** `Mask.subjectMaskPNG` (8-bit gray PNG, row 0 = top), `subjectMaskRevision` (provenance only, from `request.revision`), `invertSelection` (`.subject` only). Decode is `try?` per field so a corrupt blob loses only the raster. Presets/Paste already exclude `masks`. Fallback ids mix PNG presence/length/bytes, invert, revision.
- **Coordinate space.** The raster is in the frame of the UNEDITED oriented source (`ImageDocumentModel.currentImage`). `EditPipeline.subjectMaskImages` stretches it over the pipeline's input extent and runs it through `applyGeometry` (extracted from `apply`, byte-identical for the photo) so it follows straighten/perspective/scale/flip/crop and works at proxy/thumbnail/export sizes. Stronger than `.brush`, which is expressed in post-crop fractions.
- **Raster -> mask image.** Unmanaged decode (`[.colorSpace: NSNull()]`); `CIColorMatrix` with bias (1,1,1,0) and alpha = gray yields premultiplied RGB == alpha == gray. Copying gray into RGB too gave gray² (a raster value 128 blended at 0.25 coverage — caught by the 128-value test, not by 0/255 tests). Decode cache: 4 entries keyed by PNG `Data`.
- **Invert** reuses `invertedMaskImage`; a missing/undecodable raster selects NOTHING even when inverted. Zero-adjustment subject masks still serve as combine operands (a reviewer-motivated test caught that identity masks must not be skipped when building rasters).
- **Generator** (`SubjectMaskGenerator`, the only Vision importer): 1024px long-side cap (Lanczos after `clampedToExtent`), scaled mask quantized to 8-bit. Single-flight `ImageDocumentModel.selectSubject` with the `analysisGeneration` stale guard, one undo step; Subject button + Invert/Recompute rows; own alert (ContentView's body is at the type-checker limit).

Measured (throwaway harnesses, deleted; this M1 8GB machine):
- PNG size at the 1024 cap on real photos: 20434 B (3024x4032 JPEG, generate 462ms), 37957 B (8192x5464 JPEG, 337ms), 8858 B (6016x4016 NEF, 711ms) -> base64 in the sidecar 11-51 KB (well under the 100 KB threshold set in the plan).
- `Data ==` on the PNG 0.3-1.0 us; whole-`EditState ==` with a PNG 1.1 us.
- Pipeline at 6016x4016 with one subject mask: graph build 0.17 ms; render to 1600x1000 2.0 ms (no mask), 20.8 ms (subject mask + contrast, FIRST of three runs, likely cold), 5.4 ms (inverted, later run). Noisy single-process numbers on a flat synthetic image — not a frame-budget claim.

Review findings worth remembering: (1) a reviewer measured a half-strength border column with the clamp after the transforms; NOT reproducible through `apply()` here (0.8 everywhere, both orders and no clamp), so the clamp-first order is kept as defensive and its edge test is a behavior guard that no mutation fails — said so in the code comment; (2) crop keeps source coordinates, so a crop test cannot prove the geometry chain runs — the flip/scale/origin tests do (a first non-zero-origin fixture was too weak: a 37px shift passed even with the translate removed; 500px fails); (3) the generator<->renderer vertical convention is pinned by an end-to-end test using a top-placed figure and a mirrored probe.

Known v1 cuts (IMPROVEMENTS.md): no Feather/edge refine, no per-person selection (all foreground instances), no on-image overlay, no Sky/Object/Depth, Invert only on `.subject`, Vision sees unedited pixels, an older build opens a `.subject` sidecar as a default `.radial`, a recompute that returns identical bytes adds no undo step, after a photo switch mid-flight the Subject button stays disabled until the old pass ends (~1s).

Live-verified (2026-10-01, with the user's permission, Release build, scratch folder under the app container tmp with a copy of one real group photo plus a synthetic gradient; catalog backed up first and restored to the exact baseline afterwards — 1094 photos, 15 collections, 29 memberships, rating sum 11, integrity ok): Add Subject on the group photo created "Mask 1" in one step; lowering Exposure darkened exactly the 4 detected people and NOT the crouching 5th (Vision's miss, as in the spike); Invert darkened the background instead, people stayed lit, edges tight; the sidecar held `kind: subject`, `invertSelection`, `subjectMaskRevision: 1` and a 27 KB base64 PNG (sidecar 30 KB total); Undo x3 removed the mask step by step (invert, exposure, then the mask itself in ONE step) and Redo x3 restored it with its PNG; switching to the gradient photo and pressing Subject showed the "No subject was found in this photo." alert and added no mask; reopening the photo restored the inverted selection from the sidecar; Flip Horizontal in the Crop tab flipped the photo AND the selection together (people stayed lit in their new positions). The sandbox's folder-grant panel ("Grant Access", Return to accept) appeared on the first edit as designed. NOT verified live: Recompute Subject, crop-rect/straighten/scale following (flip/scale/crop/origin are unit-tested), the Subject button's "Finding…" state, an old-build forward-compat open.
Automation notes for next time: the app window can sit on a second display at negative coordinates (find it with CGWindowListCopyWindowInfo and `screencapture -l <id>`, which also keeps unrelated desktop content out of the capture); NSOpenPanel needs the AXRaise-then-Cmd-Shift-G route and Return to accept (the panel's buttons are not reachable through the AX tree); custom sliders respond to AXIncrement/AXDecrement on their AXUnknown element; AX value-sets on the sort popup/search field apply late or not at all, while AXPress on filmstrip buttons and toolbar buttons (found by description) works.

## Subject mask refinement (2026-10-01): per-subject selection + Feather

Closes two v1 cuts of the AI Subject mask. 2 code commits (data model + pipeline; generator + UI), each reviewed by `reviewer` (Opus) to APPROVE and mutation-checked; suite 1607 -> 1627.

Design:
- **One soft raster per Vision instance** (`Mask.subjectInstancePNGs`), not a label map: Vision's per-instance scaled masks are refined against the full-resolution image, its native label map is a blocky 512x512. Ordered left-to-right by mass centroid, capped at 8 (largest kept), specks (<0.05% of the frame) and empty instances dropped — the selection logic is the pure `SubjectMaskGenerator.selectInstances` so the cap (the sidecar-size bound) is unit-testable.
- `subjectInstanceEnabled` (missing entry = enabled; `[]` = everyone), `subjectFeather` (0...1, identity 0), legacy `subjectMaskPNG` kept read-only for v1 masks; instances take precedence when present. New masks no longer store the duplicate union PNG. Zero enabled rasters selects NOTHING even when inverted (documented; see IMPROVEMENTS.md).
- Pipeline: enabled rasters unioned by `CIMaximumCompositing` (RGB==alpha, so max is union), a differently-sized raster is stretched onto the first's rect, then Feather = clamped Gaussian IN RASTER SPACE (before stretch/geometry) with sigma = feather * `kMaxSubjectFeatherFraction` (0.02) * raster long side — proxy/export invariant by construction, border stays fully selected. Feather 0 skips the blur (an optimization only: a radius-0 blur renders identically here, measured). Decode cache grows to the render's working set (`reserve`, cap 64) because sequential LRU access over more than 12 rasters would miss every time.
- UI: Feather slider, a "Subjects" list with a silhouette thumbnail + toggle per subject (2+ detected; labelled Subject N because Vision also returns animals/objects), Recompute replaces the instance set and resets the enabled flags (counts/order can change) but keeps feather/invert.

Measured (throwaway harness, deleted): IMG_6328 group photo -> 4 instances in 411 ms, PNG bytes [8314, 9988, 8142, 8287] = 34731 B (base64 46316 B; the v1 union was 20434 B); the single-subject 8192px photo -> 1 instance, 37955 B. Live sidecar for the group photo with 4 instances: 49464 B total.

Test-honesty findings worth remembering: a "feather 0 equals pre-feather" test first compared a render with itself (vacuous) — rewritten to compare an instance mask at feather 0 against a legacy single-PNG mask across the edge; a proxy-invariance test had to exclude fx 0.5 (pixel-center sampling differs between sizes: measured 0.058 apart at the steepest point of the feathered edge — an artifact, not a scaling difference); forcing the feather branch always on is NOT caught by any test (same output) — said so in the code.

Live-verified (2026-10-01, Release build, scratch copy of the group photo, catalog restored to the exact baseline: 1094 photos, 15 collections, 29 memberships, rating sum 11, integrity ok): Add Subject found 4 subjects and exposure -5 darkened all four; unticking Subject 2 returned exactly that person (second from left) to normal while the others stayed dark; Invert + Feather 100% showed soft halos around the still-selected people with the unticked person darkened with the background; the sidecar held 4 instances, enabled flags [true, false, true, true], feather 1, invert true, no legacy PNG, revision 1. NOT verified live: Recompute, Undo/Redo and reopen persistence for the new fields (unit-tested/Codable-tested; v1 persistence was verified live), thumbnails' look beyond the screenshot, the first attempt was blocked for a while by a LOCKED screen (IOConsoleLocked — AX windows disappear while locked; check `ioreg -n Root -d1 -a | grep -A1 IOConsoleLocked` before blaming the app). Two of the user's own photos were opened (viewed, not edited) by mis-aimed filmstrip presses before the scratch photo was opened via Add Photos > Open… with the file path typed into Cmd-Shift-G.

## Looks (LUT profiles) v1 (2026-10-02): built-in procedural looks + `.cube` import

3 code commits (data layer; EditState + pipeline stage; LookStore + UI), each reviewed by `reviewer` (Opus) to APPROVE/FIX-FIRST-fixed and mutation-checked; suite 1627 -> 1688. The user chose this slice ("go ahead with profile/LUTs and then removal") and pre-authorized live verification.

Design:
- `EditState.lookID` ("" none; `builtin:<slug>` or `user:<sha256-12>`) + `lookIntensity` (1.0 non-zero identity default, decode `?? 1.0`). A look is copied by presets, cleared by `comparisonOriginal()`, counted by `isEffectivelyIdentity`. Unresolvable ids render as no look (fail-open) and show "Look not found".
- `CubeLUT` (size^3 RGBA float, red fastest, built once), strict `.cube` parser (TITLE, LUT_3D_SIZE 2-65, DOMAIN/INPUT_RANGE only 0 1 — a deliberate deviation from the plan's "remap" — 1D/NaN/oversize/second size line rejected, BOM tolerated), 10 procedural `BuiltInLooks` (per-pixel sRGB-domain functions sampled to 33^3), `LookLibrary` registry (EditEngine stays I/O-free), `LookStore` (Rendering; `Application Support/PhotoApp/Looks/<hash>-<name>.cube`, synchronous `loadAll()` at launch so registration precedes any render).
- Pipeline: `applyLook` is the FIRST thing in the perceptual stage (before Levels), using `CIColorCube` on already-gamma-encoded values (NOT `CIColorCubeWithColorSpace`, which converts from the linear working space and would encode twice), a clamped copy fed to the LUT and `LookHeadroom.cikernel` re-adding `original - clamped` so highlights above 1 and shadows below 0 survive for later sliders, intensity via `CIFilter.mix`.
- Ids are purely content-addressed (`user:<hash>`, name display-only) after a review caught that name-in-id broke cross-machine determinism; re-importing identical bytes (also after a remove) restores the same id.

Measured (not assumed):
- `CIColorCube` and `CIColorClamp` are premultiply-correct at alpha 0.5; `CISubtractBlendMode` clamps results to >= 0 and `CIAdditionCompositing` sums alphas — hence the small custom kernel; `CIFilter.mix` amount 1 = inputImage.
- Order: look-then-contrast vs contrast-then-look differ by 0.017 on (0.4, 0.25, 0.15) with Warm Film + contrast 0.5 (~8.5x this suite's 0.002 tolerance). Recorded as a PRODUCT convention (Lightroom's profile-before-sliders), not a derived requirement.
- A cube-sampled highlight-clipping test passed with the Warm Film clip reinstated (33-point interpolation spreads a clip that starts inside one lattice cell); the clip tests now use each look's own unclamped transform. A single-channel sweep then exposed real clipping in Cool Fade (blue gain 1.07), Vivid and Cross Process (flat saturation boost on strongly colored pixels) — fixed with normalised gains, vibrance-style `vibrantSaturate` and a hue/luma-preserving `fitGamut`.
- Removing the pre-read file-size check in `LookStore` is NOT caught by any test (the post-read check gives the same result): it is an unobservable memory guard, said so in the code.
- A gray-ramp "monotonic" test allowed equality and missed clipping; a "feather"-style comparison of a mask with itself was vacuous in the earlier Subject work — both lessons applied here.

Live-verified (2026-10-02, Release build, scratch copy of a group photo in the app container tmp, catalog backed up and verified identical afterwards: 1094 photos, 15 collections, 29 memberships, rating sum 11, integrity ok; the empty `Looks` folder the app created was removed): the Looks section lists None + 10 built-ins; picking Teal & Orange (subtle) and Noir (clearly monochrome with contrast) changed the render; the Intensity slider blended Noir at 50% (sidecar `lookID builtin:noir`, `lookIntensity 0.4999…`); Import .cube… via the file panel stored `a50a2359a816-Purple Haze.cube`, registered it under "Imported" with a trash button, selected it and rendered a purple tint; Remove asked for confirmation, deleted the file, switched the open photo to None (sidecar `lookID ""`, intensity back to 1) and the Imported section vanished; Undo then restored the removed look's id and the UI showed the orange "Look not found" note with the photo rendered without it (fail-open). NOT verified live: Undo/Redo of a normal look change, reopen persistence of an imported look across relaunch (store `loadAll` is unit-tested), Export/Enhance/Library thumbnails with a look, built-in looks other than Noir/Teal&Orange visually.
Automation notes: the file panel's titles differ ("Open" vs "Import a .cube LUT" vs "Grant Access"): `AXRaise` the right window name before Cmd-Shift-G; a typed path beginning with "/" opens the Go-to sheet by itself; Escape closes a stuck Go-to sheet; toolbar/sidebar rows are plain AXButtons found by index (labels are not exposed as AX titles).

Known v1 limits (IMPROVEMENTS.md D45): unresolved user looks render as no look in Export/Enhance/thumbnails; stale Library thumbnails after removing a look; Auto Tone/Fix Color Cast sample without the look; no live per-look thumbnails; 0-1 domain only; look math is not pinned per photo.

## Spot removal feasibility spike (2026-10-02): GO — Clone + Heal spots, perceptual-domain membrane

Spike only (no production code); throwaway CLI harness (real-photo copies in the scratchpad, since deleted), run on this M1 8GB machine. The harness prototyped the exact Core Image recipe the feature would use: a general `CIKernel` generating a spot geometry image (feathered disc mask + annulus ring weight from `destCoord()`), clone = `mix(dst, src, mask*opacity)` with `src = image translated by the source offset`, heal = `src + C` where `C = blur(diff*ring)/blur(ring)` (normalised convolution of the `dst - src` difference over an annulus outside the spot, `CIGaussianBlur` sigma 0.8R on a premultiplied RGBA where alpha carries the ring weight), applied per spot with `patch.composited(over: img)`. A dark soft blob plus a hair-like stroke was planted on clean regions of two real photos (sky, sky near a ridge, rock texture, a large rock spot, water, reef) and removed; error = mean abs error in PERCEPTUAL space vs the clean original, inside the disc / in a 1.0-1.5 R halo.

Measured (disc/halo, lower is better; "blurFill" = membrane of the surroundings only, no texture):
- sky-high: defect 0.1516/0.0005, blurFill 0.0018/0.0004, clone 0.0034/0.0006, heal(linear) 0.0028/0.0007, heal(perceptual) 0.0028/0.0007
- sky-near-ridge: 0.1880/0.0007, 0.0016/0.0005, 0.0024/0.0007, 0.0025/0.0008, 0.0025/0.0008
- rock-texture: 0.0440/0.0002, 0.0252/0.0069, 0.0515/0.0153, 0.0521/0.0143, 0.0471/0.0139
- rock-large: 0.0588/0.0002, 0.1297/0.0457, 0.1422/0.0450, 0.2364/0.0687, 0.1319/0.0344
- water: 0.0525/0.0002, 0.0036/0.0008, 0.0056/0.0015, 0.0051/0.0014, 0.0052/0.0014
- reef-texture: 0.0359/0.0001, 0.0441/0.0125, 0.0539/0.0154, 0.0608/0.0165, 0.0560/0.0149
(this table is the SECOND harness run, with a source search that also matched the candidate disc's gradient energy; the first run's search, annulus match only, gave clone/heal-perceptual halo of 0.0006/0.0007 (sky-high), 0.0006/0.0006 (sky-near-ridge), 0.0153/0.0139 (rock-texture), 0.0097/0.0165 (rock-large), 0.0021/0.0019 (water), 0.0150/0.0139 (reef) with a different source on rock-large — the annulus-only search was BETTER there, so v1 uses it.)

What it says:
- On smooth content (sky, water — the real dust/blemish case) every method removes the defect (halo errors ~0.0005-0.0015); heal ties clone, and plain blur-fill is slightly best (0.0004 vs 0.0007).
- Heal vs clone is MIXED, not a clear win: with the first (better) search, heal(perceptual) beat clone on the halo on rock-texture, water and reef, tied on both sky cases, and lost on rock-large (0.0165 vs 0.0097). The second search made rock-large worse for all methods (offsets chosen differently). MAE against the hidden truth also rewards smoothness over plausibility on textured areas, so the visual montage matters more: on rock-large heal(perceptual) left a faint light disc, heal(linear) left a clearly wrong pale glow, blurFill a pink blob, clone looked best; on rock-texture the auto source copied a dark crack and heal(linear) added a dark/teal halo while heal(perceptual) was cleaner.
- DOMAIN: perceptual beats linear (rock-large halo 0.0165 vs 0.0379 first run, 0.0344 vs 0.0687 second run). Heal runs in the perceptual domain.
- Auto source is a convenience, not a guarantee: it works on smooth regions and is unreliable on strongly textured ones; the second search (extra texture-energy term) did not help. Search cost 0.1-0.4 ms per spot on a 512 px copy. A MANUAL source drag is therefore a required part of v1, not a nice-to-have.
- Performance: on a 1600 px proxy source a full-frame render with 50 spots takes 6.9 ms (clone) / 16.9 ms (heal), 10 spots 1.3 / 2.7 ms — interactive. At full resolution (8192x5464 -> 1600 px preview) the cost is NOT free: with the decode cached the zero-spot render is ~92 ms and 10 spots cost ~590-880 ms, 50 spots ~2.4-3.4 s (roughly 55-80 ms per spot): each `composited(over:)` layer is a full-frame pass in Core Image. Acceptable for export (heavy edits cost far more) but it is the design's known scaling limit; resident memory ended at 202-216 MB.

Decision: GO for v1 as Clone + Heal spots (heal in the perceptual domain with the normalised-convolution membrane), spots in the source frame applied first in the pipeline, placement/editing UI at identity geometry only, manual source dragging required, auto-source = the annulus-match search. Out of scope: generative/content-aware removal of large objects, arbitrary-shape removal, per-spot export-cost mitigation (e.g. merging non-overlapping patches before compositing — logged for later).

## Spot removal v1 (2026-10-02): Clone / Heal spots

Follows the feasibility spike above (GO). 3 code commits (model + source search; pipeline stage; UI), each reviewed by `reviewer` (Opus) and mutation-checked; suite 1688 -> 1732. Pre-authorized by the user ("go ahead with profile/LUTs and then removal"; live verification without asking).

Design as shipped:
- `RetouchSpot` (x,y fractions of width/height y-up; radius and source offset fractions of the MIN side; heal|clone; feather; opacity) in `EditState.retouchSpots` (cap 50; element-wise tolerant decode that drops a corrupt/non-finite spot, deterministic and de-duplicated ids; preset-excluded, cleared by `comparisonOriginal()`, left alone by Reset Adjustments, like red-eye points).
- `EditPipeline.applyRetouch` is the FIRST stage, in the UNEDITED source frame, so spots stay on their content under later crop/rotate/flip (unit-tested with flip) and sources may come from later-cropped content. One encode before / decode after (perceptual domain, MEASURED better than linear in the spike and by `testHealCarriesTextureInPerceptualUnits`), sequential spots, each limited to a whole-pixel bounding box; clone = mix, heal = source + normalised-convolution membrane; the source centre is clamped to keep its disc+ring in frame. Five tiny kernels (`RetouchGeometry/HealDiff/HealCombine/Clone/Merge.cikernel`, the 12th-16th custom kernels).
- `RetouchSourceSearch` (the spike's annulus-match search, pure CPU, y-up, obstacle-aware) + `RetouchSourceBitmap` (512 px perceptual bitmap). UI: a "Remove" section after Red-Eye (Add Spot, list, Heal/Clone, Size/Feather/Opacity, Source X/Y sliders as the AT twin of the draggable circles, Find Source) and `RetouchOverlayView` (spot circle drag, dashed source circle drag). Placing/moving spots requires IDENTITY geometry (the shipped RAW-WB-eyedropper precedent): existing spots render under any geometry and the section says so.

Bugs the process caught (worth remembering):
1. `patch` is a reserved word in Core Image's kernel language: a kernel using it as a parameter name silently fails to compile, `CIColorKernel(source:)` returns nil and — with the convention "no kernel = return the input" — the whole feature becomes a silent no-op. Found when 10 of 13 tests failed with zero change, twice (spike harness and `RetouchMerge`).
2. My tests read 1x1-pixel renders, which hid that a WHOLE-FRAME render came out transparent everywhere outside each spot's box: a no-input general `CIKernel`'s output (the geometry image) is NOT reliably clipped to its extent/crop when used as another kernel's input (`geometry.cropped(to: roi)` had alpha > 0 on all 160000 pixels of a 400x400 frame). The merge marker is now a plain opaque white box. Whole-frame tests (alpha min 1, nothing outside the feathered disc changes, 7 centres incl. frame-edge, clone+heal) replaced single-point tests; a reviewer's seam finding (a fractional bounding box gives edge pixels partial coverage) led to `.integral`.
3. `CIImage.composited(over:)` as the merge compounded alpha (alpha 0.5 became 0.75) because the repair kernels keep the destination's alpha: merge by replacement via a marker.
4. Search bugs from review: the reported offset was not the scored one at tiny radii (r floored at 2 px), unguarded NaN/huge radius, duplicate fallback ids (50 identical id-less spots), and an auto-source result that could overwrite the user's own drag (now written only if the spot is unchanged).

Measured: stage order vs exposure is NOT observable (heal-then-exposure vs exposure-then-heal differ by 0.00011 mean abs pixel on the test scene) — a convention; heal from a dark textured source into a bright destination amplifies the texture (std 0.161 vs 0.03 source swing; inherent to perceptual-domain heal); the non-finite-spot filter's removal is not caught because `guard sx.isFinite` independently skips NaN spots; a full-frame render through ProxyBuilder proxies at 3 scales x Metal RGBAh/CPU RGBAf x 3 downscales left max diff 0.0 outside the disc; spike cost numbers (55-80 ms/spot at 8K full-res, not re-measured with the merge kernel).

Live-verified (2026-10-02, Release build, scratch JPEG made from a real photo's sky with a planted dark blob + hair at the exact centre, catalog backed up and verified identical afterwards — 1094 photos, 15 collections, 29 memberships, rating sum 11, integrity ok): Add Spot at the centre auto-found a source and the blob vanished (the hair outside the radius correctly remained); the spot circle (white) and dashed source circle with a connector were drawn; sidecar held `retouchSpots` with heal, offset (-0.0201, -0.0485), radius 0.015; Opacity decremented to 0 brought the dust back and incrementing restored it; Flip Horizontal (Crop tab) kept the repair and, back on the Adjust tab, the overlay was hidden, Add Spot disabled and the orange "Reset crop, straighten, perspective, scale and flip to add or move spots. Existing spots still apply." note shown; deleting a spot and re-adding it worked. In 3 EARLY captures a 1 px column about 3% darker (e.g. RGB 94,157,239 vs 98,163,248) appeared at the left and right edges of the spot's bounding box; it did NOT appear in 10 later captures (overlay hidden, overlay shown and settled, after Opacity edits, after delete/re-add) and could not be reproduced numerically in 18 render configurations — recorded as an unexplained transient (IMPROVEMENTS.md D46), likely a stale-frame/overlay-layout artifact, to investigate if seen again. NOT verified live: Clone mode (unit-tested), dragging the circles (AX cannot drag; the drag math is unit-tested and the Source X/Y sliders are the AT path), an off-centre spot following a flip (unit-tested; the centre is flip-invariant), Undo/Redo of spot edits, the 50-spot cap message.

Known v1 limits (IMPROVEMENTS.md D46): placement/moving only at identity geometry; no brush-shaped removal or generative fill; auto-source unreliable on strong texture; full-resolution cost ~55-80 ms per spot per render; a fractional source offset softens the copied texture; premultiplied-alpha caveat for varying-alpha sources; thumbnail-scale tiny-radius heal drifts toward clone.

Spot removal v1 — SECOND live pass (2026-10-02, same scratch/backup routine, catalog verified identical afterwards): the app's synthetic mouse events (a compiled `CGEvent` tool: mouse-down / 30 drag steps / up, via both the HID and session taps, with the app frontmost) did NOT reach this sandboxed SwiftUI app — a Size slider drag on a known AX position changed nothing either — so circle dragging remains unverified live (documented limitation of the automation, not of the app; the drag math is unit-tested). Instead the sidecar was pre-seeded with two spots (a Heal at (0.3, 0.62) on a second planted dust speck and a Clone at the centre) before opening the photo: both specks were gone on open (reopen persistence of `retouchSpots`, an off-centre Heal and a Clone all verified); Flip Horizontal kept the repairs and showed no dust at either the original or the mirrored position (off-centre spot follows its content, now verified live); toolbar Undo reverted only the flip (sidecar `flipHorizontal` false, both spots intact); 48 AX presses of Add Spot grew the sidecar to exactly 50 spots, the photo still rendered correctly with 50 spots, and the Add Spot button was greyed out at the cap (so the 51st press cannot even reach the "at most 50 spots" message, which remains a model-level guard). Still NOT verified live: dragging the circles, Redo, and the unexplained transient seam (D46).

## Library keywords v1 (2026-10-02): tagging, keyword filter, keyword search

**Scope.** Free-text keywords on photos, catalog-only (like ratings/flags/labels). Filter picker with per-keyword counts, search box also matches keyword names, a sheet to add/remove/delete. Deliberately not built: rename, hierarchy, Smart Collections, IPTC/XMP (IMPROVEMENTS.md D47).

**Data** (`Migrations/010_keywords.swift`, `Keyword.swift`, `CatalogDatabase`): `keyword(nameKey UNIQUE)` + `photo_keyword` (both FKs cascade). Identity is `KeywordName.key(for:)` = `lowercased()` then NFC (SQLite NOCASE folds only ASCII, so the key is computed in Swift). `addKeywords` is one transaction, find-or-create, `onConflict: .ignore`, ids chunked by 500 (SQLite variable limit).

**Bugs the reviewer caught before commit.** (1) `CharacterSet.controlCharacters` also matches Unicode Cf format characters, which silently mangled valid text: a ZWJ family emoji split into three, England and Scotland subdivision-flag tag sequences collapsed to the same key, Persian ZWNJ was removed. Fix: strip only category Cc plus U+200B/2060/FEFF; tests for each. (2) `CharacterSet.whitespacesAndNewlines` contains U+200B, so the whitespace check kept it — the invisible-character test must run first. (3) Combining-mark floods bypass a character cap; added a 256-byte cap (a lone over-cap grapheme normalizes to nil). (4) The first `addKeywords` model update looped keywords x selected x photos on the main actor, redundant with the refresh that follows; deleted. (5) `refresh()` clearing a dangling filter id could drop a just-chosen filter on a stale read; deleted (deleteKeyword clears it). (6) Photo-menu command could set sheet state while another sheet was up, leaving the binding non-nil and wedging the sheet; fixed by making the menu only REQUEST and letting `KeywordSheetModifier` (which sees the other sheets) perform or drop it. ContentView.body is at the type-checker limit, so the sheet lives in a ViewModifier.

**Mutations.** Cf stripping restored, byte cap removed, filter ignored, search ignored, prune-on-remove dropped, filter reset dropped — each caught by a named test. (My first mutation runner counted failures with a pattern that never matched xcodebuild's output and reported 0 for everything; those numbers were discarded and redone with test names.)

**Live check** (Release build, scratch PNGs imported through the real Import Folder panel, driven through System Events + a CGEvent click helper — plain CGEvent clicks DO reach the grid's selection circles, unlike drags): Return adds; partial/suggestion/remove flows; picker "Sky (3)", "Test Trip (1)" matched the DB; keyword search found a photo whose filename does not contain the term; delete-everywhere confirmation (a nested alert sheet — reach it as `UI element 2 of sheet 1`); relaunch shows "Sky (3)". Observed: selection survives filtering, so the sheet title said 3 photos while 1 was displayed — now disclosed in the sheet. In the AX tree the sheet's buttons expose no title/description at all (even plain "Done"), so VoiceOver labels are unverified.

## Export upgrades v1 (2026-10-02): remembered settings, color space, metadata policy, output sharpening, text watermark

**Scope.** Five commits on `PhotoExporter`/`ExportOptionsView`. Defaults reproduce the previous behaviour (sRGB, all metadata, no sharpening, no watermark). `PhotoEnhancer` shares `PhotoExporter.write` and stays sRGB.

**Pre-design measurements (2026-10-02, temporary test, deleted).** A scratch JPEG with EXIF/TIFF/GPS/IPTC and Orientation 6 (40x20 stored, displays 20x40) exported through the existing code kept ALL of it in JPEG/PNG/TIFF (GPS included) and kept Orientation=6 on pixels already rotated to 20x40, so a viewer honouring the tag displayed 40x20 (double rotation). Display P3 and Adobe RGB profiles embed correctly via `write*Representation(colorSpace:)` and the pixel values convert.

**Remembered settings.** `ExportSettings: Codable` per-field tolerant (`try?` per field: `decodeIfPresent` only covers a MISSING key, an unknown enum value throws), clamps, `ExportSettingsStore` over `UserDefaults` (tests must use a suite — the test host is the real app). Review rounds caught: the sheet's unseeded resize state overwriting the stored value on every export; one bad enum resetting every setting; a non-finite long edge silently stopping all saves (JSONEncoder throws); a finite-but-huge long edge crashing `Int(edge)` in the sheet on every later open (permanent lockout) — fixed with one shared `ExportResize.sanitized` (1...65536, non-finite/non-positive -> original).

**Metadata.** A first approach (rewrite the written file with `CGImageDestinationCopyImageSource`, kCFNull to delete GPS) was MEASURED not to work (GPS survived; `.none` failed). The shipped approach sets the CIImage's `properties` before the CIContext write (the writer emits them). `.none` is an allowlist of structural keys; `.withoutLocation` drops GPS + IPTC place fields; Orientation is forced to 1 under every policy (also fixes the double rotation). Reviewer caught (and I re-measured) that treating `{PNG}` as structural leaked Author/Copyright/Description from PNG text chunks into IPTC Byline/TIFF Copyright; also drops the source's PNG gAMA/cHRM/sRGB chunks so they cannot contradict a P3/Adobe profile.

**Output sharpening.** `CISharpenLuminance` on perceptual values, radius a fraction of the output's short side capped at 3px. First-draft strengths 0.5/0.9 measured a 20%/40% overshoot of a 0.3 step at 1600px -> 0.2/0.4 (8%/18%). A hypothesis that before-vs-after-resize would differ measurably was falsified (0.0043), so the order is documented as a convention. Reviewer-found, then measured: it also amplifies Grain (+14%/+35% noise std) — logged D48, not fixed.

**Watermark.** CoreText line -> sRGB bitmap (white fill, soft shadow) -> CIImage, composited after sharpening. Fixes from review: font chosen from a measurement before rasterizing (a 200-char line on a 6000px photo was ~16600px wide, over the bitmap limit, and the mark was silently dropped); opacity via a transparency layer (colour emoji ignore a fill alpha: measured alpha 255 at fill alpha 0.2); margin to the visible glyphs; iterative shrink because the system font's width is not linear in size.

**Mutation testing** every commit (runner reports FAILED TEST NAMES; an earlier regex-count runner reported 0 for everything and was discarded). Two mutations that survived revealed weak tests (the long-text regression test did not reproduce the failure because its image was too small; a loose margin tolerance) — both rewritten until the mutation was caught.

**Live check** (Release build, scratch JPEG imported via the real Import Folder panel, driven via System Events; sheet controls reached through `group 1 of sheet 1`, pop-ups by clicking then choosing the menu item, the Export button as the last button): results in PROGRESS.md. Stray keystrokes hazard: an import attempt typed a path into the main window while no panel was open — the catalog was checked afterwards (identical); always confirm the panel exists before typing. Enhance probed separately: no stale Orientation tag, no GPS (writes no metadata).

## Smart Collections v1 (2026-10-02): saved filters, evaluated live

**Design.** `smart_collection(name, criteria JSON)` (Migration 011), criteria = min rating, flag, label, one keyword stored by `nameKey` (no FK, so a keyword delete never cascades). Evaluated with the existing pure `LibraryFilterSort.apply` over ALL photos; `CatalogModel.photos` stays the full list while one is selected and `smartCollectionSourcePhotos` applies the criteria, so local-first mutators keep working on the one real list and rating/keyword changes move a photo in or out at once. The filter bar refines the result on top (AND), as for a normal collection.

**Bugs the reviewer caught before commit.** (1) An UNKNOWN stored flag/label (renamed case, newer build) decoded to "no restriction", so a saved "Rejected only" would silently show every photo — now a present-but-unrecognized criterion sets a non-persisted `hasUnrecognizedCriterion` and matches nothing; raw values are pinned by a test. (2) `renameSmartCollection` did a full-row `update`, re-serialising `criteria` through the lossy tolerant decode — now name-only, tested byte-for-byte. (3) With a smart collection selected `photos` is the whole catalog, so ContentView's Export fallback (`catalog.photos` when nothing is checked) would have exported EVERY photo — now `smartCollectionSourcePhotos`. (4) Saving called `clearLibraryFilters()`, discarding the user's sort/search — now only the four saved fields reset. (5) The smart-collection load error would re-alert on every refresh — now once per distinct message. Name uniqueness uses `KeywordName.key` inside the write transaction (SQLite NOCASE folds only ASCII).

**Mutation testing** (failed-test-name runner): deleted-keyword-matches-all, order preservation, rating clamp, duplicate allowed, label ignored, migration unregistered, criteria not applied, unknown id shows all, no reset after save, delete without fallback, keyword key dropped, full-row rename, unrecognized criterion ignored. Two mutants did not compile (enum raw rename; removing a switch arm) and prove nothing — noted in D49.

**Live check.** Results in PROGRESS.md. Technique notes: sidebar rows are `rows` of the `Sidebar` outline reached as `UI element 1 of UI element 1 of UI element 1 of UI element 1 of (UI element 1 of window 1)`; buttons inside cells are AXPress-able; an alert's text field lives at `text field 1 of group 1 of sheet 1`; a SwiftUI context menu opens as a separate small window (find it with the window lister) and its items are not in the AX tree — click them by position; CGEvent right-clicks reach the app. `outline`, `items` are reserved words in AppleScript. A blind panel import imported ~/Documents by mistake (see PROGRESS.md) — always verify the Go-to sheet text before pressing Return.

## D28 sidecar save race: snapshot hardening (2026-10-02)

`ImageDocumentModel.saveSidecarNow` captured `currentURL` at its top but read `editState` after the folder-access step (a modal `NSOpenPanel` pumps the run loop). Fix: snapshot the (photo, edits) pair first and write/report that snapshot; the folder-access helper became injectable (`SidecarFolderAccessing`, `ImageDocumentModel.init(folderAccess:)`) so a test can stub the panel.

**What was and was not established.** A stub that spins `RunLoop.main` inside `resolveOrRequest` (what the panel does) was used to try to reproduce the interleave. Probe results: from an async test job, a queued `Task` never started; from a `DispatchQueue.main.async` block it started but never resumed after a `Task.sleep` within 2s; from a `Timer` callback a toy 4-hop Task completed. A REAL `model.load(from:)` queued before a timer-triggered `flushPendingSidecarSave()` did not complete in 10s (`isLoadInFlight` stayed true). So the original scenario was never reproduced and may not be reachable; the reviewer first caught that my initial "unreachable" conclusion was drawn only from the two caller types that cannot reach it. The committed test therefore pins only the deterministic property (a change to live state during the panel cannot leak into the write); mutation (write live `editState`) fails it. Two exploratory tests (a 10s real-load interleave that did not discriminate, and a probe file) were deleted rather than kept.

**Method note.** Nested run loops do not behave uniformly: whether main-actor Tasks progress inside one depends on whether the spin starts from a Swift job, a main-queue block, or a run-loop callback. Do not reason about modal-panel interleavings without a probe from the actual caller type.

## Click-on-image subject picking v1 (2026-10-05)

**Why.** The AI Subject mask lets the user pick which detected subjects it covers, but only from a text list ("Subject 1/2/3") with no on-image view, so the user could not tell which was which (IMPROVEMENTS.md D44 explicitly cut picking and the overlay).

**Hit test.** The click is in the DISPLAYED frame (after straighten/perspective/scale/flip/crop); stored instance rasters live in the source frame. Rather than hand-write the inverse of `applyGeometry` (this codebase's recurring stale-list bug class), `EditPipeline.subjectInstanceMaskImages` builds each instance's mask through the EXISTING forward path (`subjectMaskImages`: raster stretch + `applyGeometry`, feather forced 0) and `PixelSampler.coverage(of:at:)` reads its alpha at the click. Highest coverage >= 0.5 wins. Probes during the tests: a 0.5 left crop inset is clamped to 0.45 by the pipeline; a straighten test needed values read from a probe grid (a hand-picked version did not catch a mutant that ignored geometry).

**Model.** `toggleSubjectInstance`: hit test, materialize `subjectInstanceEnabled` to the instance count (a missing entry means enabled — otherwise toggling instance 2 would disable 1), flip one entry, one history step. Refused while a Recompute runs (it resets the enabled list and would silently wipe the toggle); `reportMiss:false` for the persistent picker.

**UI.** `EditorInteractionMode.pickingSubject` (persistent like Red-Eye placement); the reviewer verified every disarm route (photo switch, leaving Adjust, Compare, Escape, mask select/deselect/delete, Undo/Revert removing the mask) reaches the new case. A red `SubjectMaskTintOverlay` renders the chosen subjects' union at <= 512px off-main, re-rendered on every edit-state change with a 30ms debounce (a detached task does not inherit cancellation, so unbatched frames would pile up).

**Live pass notes.** Mouse clicks and scroll events reach the app via CGEvent helpers; typing does not reliably (focus kept moving to Chrome), so every keystroke ran through a script that activates PhotoApp and aborts unless it is frontmost. The crafted fixture needed a folder bookmark for its sidecar to be read at all; the first save prompted and overwrote the crafted sidecar (restore it from a copy, reopen). The app window is on a second display at negative coordinates.

## D48 export follow-ups (2026-10-05)

**Privacy default.** `ExportSettings.metadata` default `.all` -> `.withoutLocation`. A bare default change would not have reached existing users, because every v1 save wrote `"metadata":"all"`; the store key moved to `exportSettings.v2` with a one-time v1 migration (all fields kept except metadata, v1 left untouched, a v2 value always wins afterwards, corrupt v1 -> defaults and nothing saved). Recorded consequences (reviewer): a user who had deliberately chosen All metadata is reset silently (the choice is one click away and the sheet warns that All metadata includes the location); downgrade then re-upgrade keeps the v2 value and ignores what the older build wrote.

**Grain vs export sharpening.** Grain is `EditPipeline`'s last stage because sharpening grain amplifies it, but export sharpening runs after `EditPipeline.apply`. Fix: when sharpening != none and the edit has grain, export runs `apply` with grain zeroed, resizes, `OutputSharpen`, then `EditPipeline.applyFinalGrain` (a wrapper over the private `applyGrain`), then the watermark. Measured through the export path (flat 800px field, Grain 0.5, mutation with the deferral off): std ratio 1.134 screen / 1.340 print — the same numbers the earlier harness found. A reviewer asked for a resized case; measuring it showed something worth recording: a 3x downsize aligns the 0.002*min-extent grain cells exactly (identical std 0.0837 either way) but a non-integer downsize (3000 -> 1100px) smooths the OLD path's grain to 0.0742 while the deferred path gives 0.0838, the same as a native-size export — so the test contract became "a resized sharpened export's grain equals the grain of a native-size export", not "equals the unsharpened resized export". Unsharpened exports keep the old path (byte-identical by design) and therefore keep the slightly weaker minified grain (D48).

**Tuning by eye.** Two real library photos (copies in the container's tmp, originals untouched) exported at 2048px long edge with none/screen/print; matching 1:1 crops composed side by side at 3x nearest zoom and looked at. Screen: modestly crisper edges and fur texture, no halo. Print: clearly crisper, a faint dark rim along the strongest bright/blue and fur/sky boundaries, still natural. Constants unchanged. Honest limits: judged by one viewer (me) on two photos, no printed output, no RAW.

## Sky / Object mask feasibility spike (2026-10-05) — decision: NEEDS-MODEL for a cloud-capable Sky mask; clear-sky-only classical v1 is possible

Spike only: no `MaskKind`, no `EditState` field, no UI, nothing in `Sources/`. Permanent probe: `Tests/RenderingTests/SkyMaskProbeTests.swift`
(3 tests: the classifier vocabulary contains `sky`/`blue_sky`/`cloudy`/`sunset_sunrise`/`night_sky`; a synthetic blue-gradient-over-green
fixture classifies as sky >= 0.3 (skip-only: it can never fail); attention saliency is a coarse fixed-size float map). Everything else below came from a temporary harness
(deleted) on this Apple M1 / macOS 27.0 (build 26A428); the user's real photos were COPIED to the container tmp (originals untouched, copies
deleted afterwards) and looked at only as <= 300px-high side-by-side overlays.

**1. OS facilities (measured).**
- `VNClassifyImageRequest` (revision 2 = the current and default revision on this machine; revisions 1 and 2 supported; 1303-label
  vocabulary) works as a SCENE gate, not a mask: 7-23ms per photo after a ~160ms first call (read from the harness log); labels `sky`/`blue_sky`/`cloudy`/
  `night_sky`/`sunset_sunrise` with confidences. Over 96 random library JPEGs, 44 had `max(sky, blue_sky) >= 0.5`; of those, every one
  produced a non-empty classical mask (no "gated but empty"; mask QUALITY on those 44 was not judged except for the photos viewed in the two batches). Without the
  gate the classical detector put a coverage > 15% "sky" mask on AT LEAST 14 of the 52 ungated photos — the printout I made was truncated at 14 and the
  photos were identified by their classifier labels (people / document / water), not all inspected by eye (white walls, ID photos, documents, underwater
  blue water among them); the three no-sky photos of the first batch (underwater, portrait against a white
  wall, a lab bench) all had no sky label.
- Attention saliency: a coarse fixed-size heat map (far smaller than the image; pinned by a test). Population: the 11 first-batch photos on which
  the version-1 detector produced a non-empty mask (that includes two non-sky photos, the underwater shot and the white-wall portrait). Mean saliency
  inside the mask was lower than outside in 9 of the 11 (clearly, e.g. 0.033 vs 0.197; but only marginally — under 15% — in three: IMG_6414 0.072 vs 0.084,
  viscuna 0.048 vs 0.053, 4K2A0048 0.063 vs 0.073) and HIGHER inside in 2 (IMG_6394 0.094 vs 0.040, IMG_8525 0.048 vs 0.038). (An earlier draft of this
  entry said "7 of 11"; recounting from the logged values gives 9 of 11. The conclusion is unchanged.) Too coarse and inconsistent to be a mask or a seed.
  NOT used.
- Foreground-instance mask: overlap with the classical sky was 0.1-0.6% in every photo that had instances — consistent (sky is never foreground)
  but the INVERSE of the foreground mask is "everything but the subject" (ground included), so it cannot identify sky; it could only subtract
  subjects from a sky mask.
- No per-pixel sky/semantic request exists in Vision (only person segmentation, foreground instances, saliency). No system segmentation
  `MLModel` was found by this spike (not exhaustively searched).

**2. Classical detector prototype (throwaway).** Per-pixel colour likelihood (blue-dominant bright pixels; bright near-neutral pixels for
overcast; dusk blue allowed once the first batch showed a miss), a smoothness test (luma gradient), 4-connected components that touch the top of
the frame, closing, a light blur; working size 480px. First batch (13 photos, mostly clear high-altitude Atacama/Bolivia skies):
- Version 1 (10 sky photos): 7 good, 1 partial, 2 wrong (a dark twilight sky not detected at all; snow leaking into the mask).
- Version 2 (dusk-blue relaxation + a column-contiguity rule for neutral pixels): 9 good, 1 wrong — the dark twilight sky and the partial case
  were fixed; the snow leak was NOT (snow is blue-tinted white, so it counts as blue sky).
- A second, harder batch: from the 96-photo pass I VIEWED six photos picked by their classifier labels (cloudy / sunset / night / salt-flat
  reflection), with the version-2 detector. Verdicts, photo by photo: IMG_6385 (blue sky with clouds) PARTIAL — blue patches selected, clouds as
  blocky gaps; DSC_0549 (cumulus) WRONG — the clouds, the sky's main content, are mostly excluded as blocky holes; IMG_6406 (sunset) PARTIAL — blue
  upper sky selected, glow band partly missed, and it leaks into the lake reflection at the lower left; 20240302_001207 (Milky Way night sky) WRONG —
  a large dark region selected with a ragged boundary against the sky/mountain edge. The two Uyuni mirror-world photos (IMG_6561, IMG_6564) are LEFT OUT of
  the tally: they select the sky reflected in the salt flat below the people (arguably right, arguably wrong).
- Honest tally (version 2): clear/dusk sky photos: 9 good of 10; cloud-rich/sunset/night photos: 0 good of 4 (2 partial, 2 wrong). The sample is one
  person's library (blue high-altitude skies dominate), small (13 + 6 photos viewed, 96 classified), and judged by me from small overlays.
- Latency: 1.8-3.0 s per photo at 480px — in a DEBUG build with unoptimised nested loops. A Release number was NOT obtained: the test target does
  not build in Release on this project (an unrelated `Float16` error in `ProxyBuilderTests`).

**3. Core ML route (assessment only; NOTHING downloaded or measured).** Recalled, not verified in this spike: DeepLabV3-class models (Apple hosts
converted ones; tens of MB) and SegFormer-B0/ADE20K (~15MB; recalled that NVIDIA's released weights are reportedly non-commercial — verify the licence
before deciding) would give a real sky class and handle clouds. Integration shape would mirror the Subject mask: `VNCoreMLRequest` at ~512px, the result stored as a
persisted raster (`Mask.subjectInstancePNGs`-style) so a render never re-runs the model (determinism), carried through `subjectMaskImages`/
`applyGeometry`. Costs: a bundled model file (size), a licence decision, and drift risk if the model is ever swapped. This is the same shape of
decision as CIRAWFilter vs LibRaw in CLAUDE.md and needs the user's call.

**4. Object select.** Foreground instances (done, plus click-on-image picking) cover "the thing in front". Selecting an arbitrary clicked object
(a building, a tree) needs a promptable segmenter (Segment-Anything-class) — a Core ML model, same decision as Sky. Attention/objectness saliency
is a coarse heat map, not a segmenter.

**5. Decision.** (a) A Lightroom-grade Sky mask (clouds, sunsets, snow-adjacent horizons) NEEDS A MODEL. (b) A "clear sky" v1 is feasible with NO new
dependency: gate on `VNClassifyImageRequest`, run the colour/smoothness detector, persist the raster (the Subject mask's machinery: Feather/Invert
already exist), and say in the UI that clouds, sunsets and bright blue-white ground (snow leaked into the mask on IMG_6553 and was not fixed) may be
mis-selected. It would be good on blue-sky photos and visibly wrong with prominent clouds — a product call whether that half-feature is worth shipping. (c) Object select: NEEDS A MODEL. Open question for the user: model route (size/licence) vs
clear-sky-only v1 vs neither.

## Persisted edit history (2026-10-05)
IMPROVEMENTS.md D35 item 8. The History panel (`EditHistory`: entries + cursor, jump by UUID) used to reset to one "Opened" row on every photo load. Now the timeline is saved with the photo.

**Where/format.** Inside the existing sidecar JSON under the reserved top-level key `"_history"` (a sibling file would need rename-engine plumbing and could orphan). `EditState`'s tolerant Codable ignores unknown keys, so thumbnails/Export/Paste/Enhance/older builds read the state unchanged (tested). `HistoryArchive` (EditEngine, Foundation-only): entry 0 full, later entries key-level deltas with `$del` tombstones, strings >= 1 KB replaced by `{"$blob": sha256}` with the bytes stored once (subject-mask PNGs are base64 inside `EditState`), all-or-nothing decode, duplicate-id / dangling-blob / undecodable-entry => nil. A caching `HistoryArchive.Encoder` (keyed by entry id; entries are immutable) keeps saves cheap: uncached encoding was 3171 ms for 101 entries with a 300 KB mask in a Debug build (documented in `HistoryArchive`).

**Consistency rule (the real hazard).** Restore only when the archive's CURRENT entry equals the sidecar's own state object (`SidecarStore.readHistory`, compared as parsed JSON from the same file bytes, so number round-trips cannot disagree — `testLongDecimalValuesStillRestore` uses 17-digit doubles). Write only when `historyURL == url`, > 1 entry and `history.current == snapshot`; otherwise the sidecar is written without `_history`. `flushPendingSidecarSave` now finalizes a pending ~350ms burst first so a quick photo switch does not lose its last step. The RAW decoder-pin backfill save moved AFTER `resetHistory` and writes a fresh one-entry history (the pin change makes the old one stale).

**Reviewer.** Commit 1 (format): FIX FIRST -> APPROVE (incl. a duplicate-id guard). Commit 2 (wiring): 2 rounds. Round 1 caught a real main-thread regression: a restored history started with an EMPTY encoder cache, so the first save after the user's next edit re-encoded (base64 + SHA-256 of every mask) the whole timeline on the main thread — fixed by warming the encoder inside the off-main read and adopting it only when the restore is accepted (`HistoryArchive.Encoder` is `@unchecked Sendable`, lock-guarded). Round 2 APPROVE. 1890 tests. Mutation checks: dropping the flush finalize and dropping the consistency check each fail a named test; two guards are untested defense in depth (D51).

**Live-verified (2026-10-05, Release build, scratch 800x600 JPEG in the app container's tmp, backups of catalog/prefs restored afterward, catalog byte-identical).** Edits made via real mouse drags + the Auto button; the sidecar showed `_history` growing with each settled step (summaries `Opened, Exposure EV, Auto Tone, Exposure EV`, cursor 3). After quitting and relaunching and reopening the photo, the History panel listed all four rows, the Undo toolbar button was enabled, and one Undo moved the cursor 3 -> 2 and exposure from 1.748 EV back to -0.237 EV in the sidecar, keeping the redo entry. Measured sidecar size for that session: 3888 bytes (2 entries) -> 4037 (3) -> 4147 (4); no masks, so no blobs. Not live-verified: a photo switch within one session (same `load(from:)` path as the relaunch), a subject-mask history (covered by the 101-entry/100 KB blob unit test).
**Process note.** An automation keystroke ("0.5") went to this terminal instead of PhotoApp because focus left the app between the guard and the keystroke; the guard now runs in the same script as the action, and mouse drags replaced typing for sliders.

## Keywords embedded in exports (2026-10-06)
User chose the smallest safe slice of "write keywords out": embed in EXPORTED files only (no `.xmp` sidecars). Spike (a throwaway script, then permanent test `KeywordEmbeddingTests.testWritersEmitIPTCAndXMPForEveryFormat`): putting `kCGImagePropertyIPTCKeywords` in the image properties makes `CIContext.write{JPEG,PNG,TIFF}Representation` emit BOTH an IPTC Keywords block and an XMP `dc:subject` bag, read back identical for accented/CJK/ZWJ-emoji strings; ImageIO also mirrors a source's XMP-only `dc:subject` into its IPTC keywords (`testXMPOnlySourceKeywordsAreUnioned`), so the union with the source's own keywords is complete. `KeywordEmbedding.merged` = catalog first, then source extras, de-duplicated by `KeywordName.key`, whitespace-trimmed. Ignored under `ExportMetadataPolicy.none` (allowlist promise) in the engine, not just the UI. Reviewer: engine APPROVE (nits fixed: XMP-only test, doc accuracy, vacuous test case, XMP-side privacy assertions); plumbing FIX FIRST -> APPROVE (the toggle's wording overpromised: with it OFF, keywords already inside the original file are still exported under All/All-except-location, so it is "Add Library keywords" with per-policy captions; `runExport`'s `= [:]` default dropped so a call site cannot silently omit keywords). 1900 tests.
**Live-verified (2026-10-06, Release build, scratch 800x600 JPEG imported into the real catalog, catalog + prefs backed up and restored byte-identical):** tagged the photo through the sheet, exported through the options sheet (toggle on, 'All except location'), and read the output with an independent ImageIO reader: IPTC and XMP `dc:subject` both `[aa, cafa a, Sky]`, no GPS; the original file had no keywords, no sidecar, and an unchanged mtime. The options sheet showed the new toggle and caption. Automation note: `System Events` `keystroke` mangled the non-ASCII test keywords (`café ☕, 日本` became `cafa a`, `aa`) — an automation artifact; Unicode is covered by the unit tests.

## Duplicate detection spike (2026-10-06)
Plan: exact duplicates by content hash, near-duplicates by Vision feature prints. Measured (Apple M1, 8 GB; real library files read in place / copied to scratch, never modified; throwaway scripts, then the permanent `FeaturePrintProbeTests`):
- **Real exact duplicates exist in the library** (catalog `fileSize` groups: 1,087 distinct sizes over 1,094 photos; the 5,617,703-byte group is six scratch-test files, the 2,110,904 and 257,142-byte pairs are `IMG_0989.jpg`/`IMG_0989 2.jpg` and `sim_chunks_62_63.png`/`(1).png`, and SHA-256 confirmed both pairs byte-identical). So a size pre-filter leaves ~7 files to hash in this library.
- **Vision feature print:** `VNGenerateImageFeaturePrintRequest` revision 2 (the only supported revision; default 2), 768 floats (3,072-byte blob), symmetric, deterministic. Warm ~4-6 ms per image at 512 px, first call ~141 ms. 20,000 `computeDistance` calls took 7 ms, i.e. ~215 ms extrapolated for all 604,450 pairs of 1,100 photos (so O(N²) grouping is cheap; extrapolation, not a run at N=1,100).
- **RAW without `RenderGate`:** `CGImageSourceCreateThumbnailAtIndex(kCGImageSourceCreateThumbnailFromImageIfAbsent, max 512, transform)` on a D610 NEF returns an oriented 512x342 image in ~37-41 ms warm (253 ms for the first file in the process), no RAW decode. A full pass over 120 consecutive NEFs (thumb + print) took 5.5 s total (thumb avg 41 ms), i.e. ~46 ms per NEF; extrapolated first scan of the 930 NEFs ~43 s (page-cache effects on cold files NOT measured, so a true cold scan may be slower).
- **Content hash throughput:** SHA-256 streamed in 1 MB chunks, 31 MB NEF in 23 ms (1.4 GB/s) — page-cache warm because it had just been copied; cold-disk throughput unmeasured.
- **Distances on real photos** (512 px previews): identical files 0.000; 1024-long-edge resize of a 5571x3719 JPEG 0.092; 5% crop 0.218; 25% crop 0.439; unrelated photos 0.89-1.27 (adjacent but different NEF frames DSC_1399/DSC_1400: 0.886). Nearest-neighbour distance over 120 consecutive Bolivia NEFs: min 0.165, q25 0.245, median 0.326, q75 0.417, max 0.801; the closest pairs (0.165-0.202) are consecutive same-scene shots with a small reframe or pose change (viewed on screen), not copies. So roughly half of this trip's frames have a "same scene" sibling below 0.35.
- **Decision (thresholds derived from the above, v1):** three tiers — *Exact* (same SHA-256), *Near-identical* (<= 0.12: re-encodes/resizes/exports), *Similar shots* (<= 0.35: same-scene bursts; opt-in, labelled as possibly different frames). A 5% crop (0.22) falls into Similar, not Near-identical. These are calibrated on one trip's photos and one JPEG; a screenshot/plot-heavy part of the library was only spot-checked (a PNG chart vs a photo: 1.200).
- **NEGATIVE FINDING:** abstract synthetic scenes (gradient + coloured rectangles) do NOT separate under feature prints (resized 0.307, q0.4 re-encode 0.454, unrelated 0.346), so the permanent probe asserts only self-distance 0/determinism/symmetry/revision facts and the grouping tests use injected distances.

## Duplicate detection (2026-10-06)
Plan `sharded-prancing-pillow` (user-chosen from the backlog). Spike numbers above. Shipped in 5 commits (ac027f3 spike, 11017d1 data layer, 20fe153 engine, 17cf473 model + sheet, this docs commit). Reviewer: data layer APPROVE with nits; engine FIX FIRST -> FIX FIRST (one-line) -> committed — round 1 caught a real design flaw (one-pass greedy clustering at the wide limit could strand a 0.02 near-copy: A, B 0.34 from A, C 0.02 from B and ~0.36 from A; fixed with two-stage clustering, tight clusters merge as whole units) and a JPEG EXIF-thumbnail trap (`FromImageIfAbsent` can return a ~160 px or STALE embedded thumbnail), round 2 caught that the thumbnail retry would force a full RAW decode outside `RenderGate` (retry skipped for RAW); model/UI FIX FIRST -> APPROVE — caught a stale regroup overwriting a newer scan's groups (which could reject unseen photos), results/flags going stale across sheet opens, rename/paste not blocked while the sheet is up, and "reject" overwriting a Pick (U would set none, not Picked). 1956 tests; ~50 mutants killed across the slice, the timing-race ones (stale regroup, cancel-in-first-read) documented as untestable.
**Live-verified (2026-10-06, Release build, scratch copies of real photos [a 12.5 MB JPEG, its byte-identical copy, a 1600 px resize, three NEFs], catalog + prefs backed up and restored byte-identical):** Photo ▸ Find Duplicates… scanned All Photos (1,089 readable-or-stat-able rows) in under 15 s on a cold cache and in under 4 s on rescan. The scratch set grouped as ONE near-identical group of 3 (exact copy and resize merged), BEST = the original; the library's two real exact-copy pairs (IMG_0989 / IMG_0989 2, sim_chunks_62_63) showed as Exact copies with correct BEST. "Keep best, reject others" flagged exactly the two non-best files (verified in the database: 2 rejected in the whole catalog), the sheet showed Rejected labels and decremented "Reject All But Best (7)" to (5). Originals untouched. FINDING: 981 of 1,089 photos could not be read in this install (no folder bookmark for Pictures/Desktop — only Downloads and the scratch folder had one) and the summary first claimed exact copies were "still found" for them, which is false; reworded (`testUnreadableImagesAreReportedHonestly`). Not live-tested: Cancel (scan too fast), the similar-shots toggle, a Picked photo in a group (unit tests only).
**Process note.** A scripted `quit` was refused by the open modal sheet and I restored the catalog while the app was still running; I then closed the sheet, quit for real, re-restored, and re-verified byte-identical (always confirm `pgrep` is empty BEFORE restoring).

## iOS Photographic Styles research (2026-10-06)
Sources: PetaPixel's interview-based explainer (capture-time AND after-capture, non-destructive via a new file-format extension that keeps data normally lost when a style is applied; selective per-region adjustment from semantic understanding of skin/light/hair/clothing; six undertone styles + nine mood styles; a 2D control pad that adjusts tone while protecting skin tones), MacRumors (pad: Tone up/down, Color left/right, Palette slider = intensity; iPhone 16+; Photographic Styles 3 on iPhone 18 Pro: texture Soft Skin/Glow/Film/Standard + intensity slider + Grain, applied after capture), Cult of Mac / MacRumors (texture and grain limited to iPhone 18 Pro / iPhone Duo cameras after Apple changed its footnote). iOS 27's other Photos additions (Extend, Reframe, Clean Up modes, keywords and star ratings, ProRAW support for the AI tools) are not style features. Unconfirmed: what each texture does to the pixels, the pad's mapping and the masking implementation. Our mapping idea: pad -> Curves shadows + HSL saturation; undertone styles -> Color Grading/white-balance nudges; mood styles -> Looks/curves; Texture -> Texture/Clarity/Sharpen; Grain -> existing Grain; skin protection -> person/face segmentation or the colour-range mask (spike).

## Styles v1 (2026-10-07)
Plan `sharded-prancing-pillow` (user-approved; own preset names). Four code commits: 47de199 (StyleLibrary + StyleMath, pure), ea6eb99 (EditState fields + pipeline), 316169a (UI), plus docs. Reviewer: library/math FIX FIRST — a real bug: clamping AFTER scaling by strength left the top of the strength slider dead whenever preset + pad overflowed ±1 (Ink + Color −1 gave −1.25 -> −1.0 at 0.8, 0.9 and 1.0); fixed with clamp-then-scale so strength is exactly linear; also missing slot-mapping tests (swap mutants survived), a duplicate id crashing the app via `Dictionary(uniqueKeysWithValues:)`, `isIdentity` disagreeing with `nudges` for NaN. Pipeline: doc-only FIX FIRST (a measured-result comment attached to the wrong function after inserting new functions between a doc comment and its function; "Color Grading runs LAST" claims stale). UI FIX FIRST — a real bug: choosing None reset strength to 1 even with the pad off-centre, making the pad's effect jump ~2.5x at strength 0.4; fixed to reset only when the pad is centred. ~35 mutants killed across the slice (three survived/unrunnable: a redundant no-op guard in `resetStyle`, and two environment issues with the filtered test runner needing `xcodegen generate` before runs).
**Measured (2026-10-07, temporary swap):** the style's tint pass after vs before the user's Color Grading — six solid colours, Copper plus strong user tints: widest per-channel gap 0.0115 (linear red of the (0.8, 0.7, 0.6) sample, 1.3387 vs 1.3272), ~5.7x the 0.002 tolerance; others 0.0002-0.006. Treated as a convention (user's own look first, the style rides on top) and pinned by a golden-value test whose pixels were RECORDED from a run.
**Live-verified (2026-10-07, Release build, scratch copy of a 2400 px group-photo JPEG, catalog + prefs backed up and restored byte-identical, PhotoApp confirmed quit before restoring):** the Style section renders under Looks (None, two labelled families, pad, readout, Strength, Reset Style); picking Cinema (punchier contrast, cooler shadows) and Honey (warmer) re-rendered live and wrote the sidecar with `_history` rows `Style: Cinema`, `Style: Honey`; dragging the pad to Tone +0.72 / Color +0.71 brightened and warmed the render and persisted exact values with a "Style Tone, Style Color" row; Undo stepped Vivid back to Honey; Reset Style cleared all four fields to defaults with a "Reset Style" row and dropped the redo branch. Also confirmed live that persisted edit history (the previous slice) records and updates correctly. Not live: Strength slider, Compare, export parity, relaunch restore, RAW, VoiceOver.
**Process note.** An import click aborted ("PhotoApp not frontmost") and my follow-up keystrokes went to the main window; I checked the catalog's flags/ratings/colour labels against the backup before continuing (unchanged). Coordinate clicks drifted when the sidebar auto-scrolled; accessibility/by-name or fresh-screenshot coordinates are safer.

## Styles v2 — Texture + Grain (2026-10-07)
Plan `sharded-prancing-pillow` (user chose a TRUE highlight bloom for Glow). Commits: 0117f29 (StyleTexture + `StyleMath.detailNudges`), 55bf3a9 (EditState fields, `EditPipeline.effectiveDetail`, exporter deferral, eyedropper), ad7ce76 (Glow stage), 70bd5cc (UI), 5f3aaf2 (tuning), docs. Reviewer: commits 1+2 APPROVE (nits: doc edge cases, replay-change note); Glow FIX FIRST — a REAL bug: the bloom faded along the right/top edges whenever a side was not a multiple of 4 (Core Image rounds a scaled extent OUTWARD, 401 -> 101, so the last row/column is partly transparent and the edge-clamped blur dragged the transparency inward: flat 0.95 field 2.632 inside, 1.560 at the last column). The reviewer's first suggested fix (flooring the already-rounded extent) did nothing; a standalone copy of the chain showed the extent was 101 and the fix is to floor the ORIGINAL size times the scale. Also caught: a resolution-consistency test sampling beyond the bloom's reach (it could not fail), and several wrong/unverified comments. UI APPROVE (nits applied). ~30 mutants killed across the slice; surviving: a redundant no-op guard, the Glow mask clamp (provably not exercised through the pipeline).
**Two bugs found by looking before assuming:** (1) The first Glow draft added NOTHING: a Core Image colour matrix re-premultiplies its output, so an "alpha 0, pure added light" layer was multiplied to zero — found because a direct pixel test showed a 0.0007 bleed and a visually-identical contact sheet; fixed with opaque straight-colour layers + a Source-In alpha restore. (2) `PhotoExporter.deferGrain` checked only `editState.grain`, so style grain would have been sharpened by output sharpening (measured grain std ratio 1.339 without the fix vs 1.0); likewise `pickColorRangeTarget` zeroed only the user's detail fields.
**Measured (2026-10-07, temporary swaps on a bright-block/mid-bar/dark scene with clarity 0.5, texture 0.5, NR 0.4, sharpen 0.6):** Glow placed after Sharpen shifts a pixel by up to 0.058 (red 1.1949 vs 1.2527), placed before Clarity by up to 0.038 (red 2.3875 vs 2.3490) — ~29x and ~19x the 0.002 tolerance — so the shipped position (after Texture, before NR/Sharpen) is a pinned, measured convention. Falloff on a 0.9 square over 0.02: +0.0735 at 2 px outside the edge, +0.0247 at 10 px, +0.0064 at 20 px, 0 from ~50 px. Patch timings as in D54.
**Tuning pass (contact sheets, three library photos, one viewer):** Glow at 0.5 gain and threshold 0.5 blew a pale studio backdrop to white -> threshold 0.75, gain 0.6; Grain toggle 0.25 looked like coarse digital noise -> 0.12; Soft smeared sleeve edges -> -0.4/-0.1.
**Live-verified (2026-10-07, Release build, a 1800 px copy of a night photo, catalog + prefs backed up and restored byte-identical, PhotoApp confirmed quit before restoring):** the Texture row (None/Soft/Glow/Film), Texture strength slider, Grain toggle and help text render under the Style section; Glow visibly bloomed the street lamps and neon shirts and wrote `styleTexture: glow` with a `Style Texture: Glow` History row; Film then Grain On wrote `Style Texture: Film` and `Style Grain: On` rows with matching UI state; Undo returned Grain to off; Reset Style cleared texture, strength and Grain to defaults with a `Reset Style` row and dropped the redo branch. Not live: the Texture strength slider, Soft, Compare, export parity, RAW, VoiceOver.
**Process notes.** (a) Filtered `xcodebuild -only-testing` runs need `xcodegen generate` first, and `-only-testing:Class/method` silently ran nothing for one test; two "surviving mutants" were really my script filtering the wrong test class. (b) A first measurement of full-frame cost was lazy and meaningless; patch timings were used and labelled as such.

## Styles v3 skin-protection spike (2026-10-07) — decision: GO to a design plan (a judgment call, gate (a) only PARTLY met); no feature code shipped
Question: can a style's colour change be kept off skin? Method: a throwaway harness (deleted; permanent synthetic probe `SkinProtectionProbeTests`) over 16 library photos copied to scratch (11 with people: studio portraits, a beige-shirt portrait, a close-up, a white-uniform portrait, an outdoor group, a group in white caps, a night race, a neon-shirt shot, underwater divers, an ID card; 5 without: red rock x2, desert/dusk telescope, vicuña) at 768 px, three detectors: A = the classic YCbCr skin window (Y>40, Cb 77-127, Cr 133-173), B = `VNGeneratePersonSegmentationRequest` (.accurate, revision 1), C = A AND B. Faces from `VNDetectFaceRectanglesRequest` (centre 60% of each box) as a recall PROXY for the FACE only — arm/hand coverage was NEVER measured, only seen on the overlays. There is NO labelled ground truth; one viewer judged the overlay sheets. Skin tones in the sample: the people are almost all East/Southeast Asian adults of light-to-medium skin tone (this library); darker skin tones were NOT tested, and one underwater scene. Machine: Apple M1 (per the project's own notes); OS is the one this session ran on (macOS 27); neither is in the harness output.
**Detector A alone is unusable:** it marked 18.2% (desert), 18.3% (dusk), 51.5% (red rock), 40.2% (rock + rabbit) and 35.8% (vicuña, whose fur and soil are skin-coloured) of NON-person scenes. **B alone** marks people (clothing and hair included) and marked 0.0% (to one decimal) of all five non-person scenes. **C = A AND B:** 0.0% (one decimal) on all five non-person scenes; face-box coverage 96-99% on every single-person portrait (studio 99%, beige 96%, close-up 98%, polo 98%, uniform 96%, neon 99%), 98% on the night race, 90% on the outdoor group (5 faces), 79% on the white-caps group (10 faces; A alone got 86% there, so the person mask also lost about 7 points — small faces are the likely reason, an INFERENCE), and 33% on the underwater divers (A alone also 33%; a blue colour cast moving skin outside the window is an INFERENCE, not tested). Failure modes seen in the overlays (one viewer's visual observations, not measurements): SKIN-COLOURED CLOTHING INSIDE A PERSON is marked as skin (on the beige-shirt photo C covered 34.9% of the frame vs 96% of the face box — the shirt is in C); printed faces (an ID card) are not people (C 0.1%, face coverage 10%); hands/arms are caught in the clear shots and small hands in groups partly missed; hair is excluded.
**Cost / determinism:** the colour window 62-93 ms per 768 px photo in plain Swift (a GPU Core Image version would be far cheaper; not built); person segmentation 56-95 ms warm per photo but the FIRST call in a process took 3,428 ms (model load) — so it must run once per photo off the main thread, never per render; face detection 5-20 ms (first 628 ms). Five runs of person segmentation on one real photo (`p_studio1`) were bit-identical; only revision 1 exists. Vision is not guaranteed stable across OS versions, so a render-time call would break replay determinism — the mask would have to be PERSISTED like the Subject mask raster, or tagged with the OS/revision that produced it. (The permanent probe cannot check determinism on a real person mask: it has no photo fixtures; its determinism test only pins that an EMPTY mask stays empty.)
**Q1 — does the existing Color axis spare skin? (median per-pixel chroma multiplier and hue shift of the C pixels vs the non-skin pixels (outside A), through the real `EditPipeline`; 10 person photos had enough C pixels)**
- Vibrance +0.5, skin / non-skin: beige 1.712/1.905, close-up 1.224/1.593, divers 1.148/1.022, caps 1.221/1.897, outdoor group 1.233/1.448, neon 1.184/1.835, night race 1.177/1.607, polo 1.136/1.724, studio 1.250/1.587, uniform 1.249/1.144. So skin got a SMALLER boost than non-skin on 8 of 10 photos and a LARGER one on 2 (divers, uniform). On the nine photos where C is mostly skin the skin multiplier was 1.136-1.250; non-skin spanned 1.022-1.905 depending on the scene. On the beige-shirt photo the "skin" sample (n=51,433) is mostly SHIRT, so its 1.712 says nothing about pale skin; no paleness/chroma measurement was made.
- Saturation +0.25: skin 1.180-1.202 on all ten; non-skin 1.022-1.251 (divers 1.022, uniform 1.139, beige 1.251).
- Both (the full Color +1 axis): skin 1.329-1.483 on the nine skin-dominated photos (beige 2.086); non-skin 1.022-2.345.
- Hue: the median skin hue shift was at most 0.97 degrees in every case; the non-skin median reached 1.97-2.18 degrees on the divers photo. Hue of SKIN is not the problem; chroma is.
- The preset TINTS (hue casts by design) were not measured here.
**Decision (against the gate fixed before looking):** (a) recall on person photos — PARTLY met (face coverage 96-99% on portraits and the night race, 79-90% on groups, 33% underwater, 10% on a printed face; arm/hand coverage unmeasured; skin tones tested were narrow); (b) false positives on non-person photos — 0.0% (one decimal), met, but a precision failure inside a person (beige shirt) was seen; (c) determinism — met only if the mask is persisted or OS-tagged; (d) cost — met if computed once per photo and cached, not per render. => GO to a DESIGN plan is a JUDGMENT CALL, not a clean pass: a "Protect skin" option with honest limits (person-only, misses underwater/printed faces, exempts skin-coloured clothing, tested on a narrow skin-tone range), needing its own Plan Mode session and user approval. The alternative is to leave v3 cut: the measured Color axis keeps SKIN hue within ~1 degree and gave skin x1.14-1.25 under Vibrance on most photos, but Vibrance did not consistently spare skin relative to the rest of the scene (2 of 10 photos) and the Saturation half boosts everything about x1.2, so "already spares skin" is NOT a safe reason to cut.

## Styles v3 "Protect skin" (2026-10-07) — SHIPPED (6 commits: 7b9d185 pure layer, ba6f690 generator, 6f18d19 EditState, 8b8195f render, 45f6e41 model + UI, docs); headless real-photo check done, GUI pass see PROGRESS.md
What it is: a "Protect skin" toggle + "Protection" slider in the Style section. Turning it on runs Vision person segmentation (`VNGeneratePersonSegmentationRequest`, revision 1 pinned, `.accurate`) ONCE on the unedited photo, ANDs it with the spike's YCbCr skin window (Y>40, Cb 77-127, Cr 133-173), and PERSISTS the result as a gray PNG (`EditState.styleSkinMaskPNG`, + `styleSkinMaskRevision`, `styleProtectSkin`, `styleProtectAmount`). Rendering (`EditPipeline.applyStyledPerceptualAdjustments`): the perceptual block runs twice — as today, and with the style's COLOUR nudges (saturation, vibrance, tints) removed but its tone nudges kept — and `CIBlendWithMask` mixes them by `amount x raster` (scene-linear, after both passes; the raster is in the source frame and the stage runs before geometry, so no geometry carry). Only when active (toggle on, raster present, amount > 0, not Black & White, not a monochrome preset — Silver/Ink — and the style changes colour); every other state renders exactly as before. Presets/Paste do not carry the raster/flag/amount; Compare's original clears them; turning it off clears raster + revision + amount in one history step. `HistoryArchive.interned` and the blob dedupe cover the new top-level Data field.
Things found while building (all measured, temporary harnesses deleted): (1) Vision's person mask is NOT empty on a person-free scene: raw 2016x1512 buffer max 6 with about 20-23 non-zero pixels on the spike's sand-gradient-plus-rock image (3000x2000: max 6, 20 non-zero), hence a person-coverage floor of 128 with a rescale above it (`SkinMaskBuilder.minimumPersonCoverage`, a convention above that noise) — an earlier version that kept any non-zero value persisted noise as skin. (2) A FLAT sand-coloured 384x288 image had about 80% marked as person (mask max 255); a flat blue one none — one synthetic observation, logged as a user-visible limit (large flat skin-coloured areas may be marked), NOT measured on real photos. (3) Cost, 24 MP synthetic gradient+noise image, RGBAh, this M1, 3 runs after warm-up, `render(toBitmap:)`: style unprotected 0.02 s, protected 0.04 s (the first protected run 0.15 s, warm-up) — about 2x for the perceptual block as predicted; a synthetic chain, NOT a RAW and not the heavy stages. (4) `createCGImage` timings (0.01 s for 24 MP) are lazy and meaningless for this; use `render(toBitmap:)`.
Headless real-photo measurement (temporary harness over 80 scratch copies of library photos — Bolivia group photos, Desktop group photos, 'Profile - NARIT' portraits, Downloads IMG_*; the real generator + the real pipeline at 768 px long side; deleted afterwards): 44 of 80 got a mask, 36 gave `noPeople` (I did not label which of those contain people, so this is NOT a recall figure); 20 had a mask covering at least 2% of the frame. Over those 20 (skin = mask >= 200; chroma = YCbCr (Cb,Cr) magnitude, per-pixel ratio vs the unedited photo, median per photo; hue shift in degrees): Vivid with Color +1: skin chroma multiplier unprotected median 2.00 (range 1.81-3.23) -> protected median 1.11 (1.10-1.28); skin hue shift 0.47 -> 0.49 deg (max 0.83). Copper (tints only): skin chroma unprotected 1.31 (1.24-1.88) -> protected 1.00 (1.00-1.08); skin hue shift unprotected median 2.6 deg (max 9.8) -> protected 0.0 (max 0.92). The protected Vivid skin is not 1.0 because the style's TONE (+0.10 contrast) is kept and raises chroma. Non-skin pixels (mask 0, outside the colour window, chroma > 12) were mostly unchanged but some photos moved: relative change in the non-skin chroma multiplier up to 0.29 (023_IMG_5160, Vivid), 0.19 (Copper) — on very small samples (n = 104-1300 pixels there; hair/edges next to the feathered raster), so this is evidence that protection reaches a few pixels beyond the raster, not a measurement of how far. The generator took 5.06 s on the first call in the test process (model load, Debug build); later calls took 0.08-0.35 s except one at 6.06 s (004_fredtofred.jpg, a duplicate of an earlier photo — unexplained, not investigated). Not measured: face-box coverage on these photos (the spike's 96-99% figures stand for its own photos), darker skin tones, arms/hands, a user-visible A/B.
Limits (shown in the UI and logged in IMPROVEMENTS.md D54): people only; printed faces and underwater skin are missed; skin-coloured clothing counts as skin; large flat skin-coloured areas may be marked; Silver/Ink are exempt (the monochrome rule reads the preset only: a +1 Color pad on Silver nets -0.75 saturation and is still exempt, a Hush look with a -1 pad nets -0.55 and is not); tested on a narrow range of skin tones; the second perceptual pass doubles that stage's cost while active.
Reviewer rounds: commit 1 (pure layer) 2 rounds — window bounds were untested (3 of 5 bounds could be deleted without failing), fixed with just-inside/just-outside probes found by a numeric search; commit 2 (generator) 2 rounds — no row-order test (orientation is that file's main risk), Vision-dependent tests hard-asserted instead of skipping, a floor comment overclaimed (step vs soft edge); commit 3 1 round APPROVE; commit 4 2 rounds — a wrong "only matters at the soft edge" doc claim; commit 5 2 rounds — a late detection could land a raster on top of Revert/Reset Adjustments (fixed with `cancelPendingSkinDetection()`). Every fix was mutation-checked.

## Looks tab (2026-10-07) — SHIPPED (3 code commits: a74e592, 615d0a9, 2b7672b)
Why: the Adjust tab was one very long scroll with Looks and Style at the top and Presets near the bottom; the user asked for a separate tab for "pick a starting point" controls (like Apple Photos' Filters tab), then a thumbnail grid later. Decisions (user, 2026-10-07): the tab is named "Looks"; History stays at the bottom of Adjust; "Reset Adjustments" resets sliders only and the new tab gets its own reset.
What shipped: `EditorTab.filters` (an inert placeholder copying Apple Photos' tab set) renamed `.looks`; pure helpers `keepsCompareAndZoom` (adjust, looks) and `disarmsPointModes` (everything but adjust), which `ContentView`'s `.onChange(of: selectedTab)` now uses (before: every non-Adjust tab reset Compare/zoom AND disarmed point modes). Looks/Style/Presets (with the Save Preset alert and the Looks import/remove helpers) moved VERBATIM into `LooksTabView` (verified by script: the only added line in `AdjustTabView` was `AdjustSectionContainer` losing `private`; every removed line appears in the new file apart from the dropped `catalog` doc); `AdjustTabView` no longer takes `catalog`. `EditState.resettingLookAndStyle()` is now the one list of look + style fields (defaults from `EditState()`), used by `isLookAndStyleAtIdentity`, `comparisonOriginal()`, `ImageDocumentModel.resetLookAndStyle()` (cancels a pending skin detection, one labelled step) and, minus the look fields, `resetStyle()`. A Mirror-based test fails when a new `look*`/`style*` stored property is not in the list. Reviewer rounds: commit 1 two rounds (four stale comments claiming Compare/zoom were Adjust-only), commit 2 one round (pure move; nits), commit 3 one round (doc wording, `resetStyle` kept its own list -> unified). Not live-verified in the GUI yet.

## Looks tab thumbnail grid (2026-10-07) — SHIPPED (3 code commits: f713a1f, 23c63a7, abe8f07)
Why: after the Looks tab shipped (above) the user asked for Apple-Photos-style thumbnails instead of a text list/chips. Principle: a cell's preview is exactly what clicking it would produce — `EditPipeline.apply` on ONE small realized base of the open photo with only that look/style chosen — so there is no new rendering math.
Design: `LookPreviewItem` (EditEngine, pure): the cells (None + 10 built-in + imported looks; None + 14 style presets), `applying(to:)` (reproduces `selectLook`/`selectStyle`, incl. their None resets — the reviewer caught that a plain id swap would not), `previewState` (strips masks/retouch spots/red-eye points: expensive at small size, never change what a Look/Style looks like, and brush masks would thrash the single-entry stroke cache), and the two grid keys (`looksGridKey` clears only `lookID`, `stylesGridKey` only `styleID`, so picking a Look re-renders only the Style grid and vice versa; the keys include the RAW decode-time fields, so a RAW re-decode must rebuild the base — covered by `imageRevision`). `LookPreviewRenderer` (Rendering): `makeBase` = `ProxyBuilder.build` at a ~160 px long side (reused, not rebuilt), `render` = `EditPipeline.apply` flattened through `CIContext.render(toBitmap:)` into an sRGB premultiplied RGBA8 `CGImage`, `releaseCaches()`. `LookPreviewModel` (UI, @MainActor): per-grid keys, a base shared by both grids per image revision, sequential off-main per-cell renders published as they finish, cancellation instead of generation counters (a mutation test showed a counter added nothing; removing `cancel()` fails a test), clearAll on a photo switch, `revision` + `looks(forRevision:)` so a stale set is hidden. `ImageDocumentModel.imageRevision` is bumped by a `didSet` on `currentImage` (the only two writers: load and RAW re-decode). `LookThumbnailCell` + `LooksTabView`/`StyleSectionView` grids: exactly three flexible columns (an adaptive grid was not guaranteed three at the 360 pt sidebar minimum), refresh via `.task(id:)` with a 250 ms debounce only when previews already exist, only while the section is expanded and no load is in flight; the remove action exists only on imported looks. Looks and Style now default EXPANDED.
Measured (temporary harness, deleted; synthetic 6016x4016 gradient(+noise) source, this M1, `render(toBitmap:)`, state with exposure/contrast/vibrance/sharpness/clarity): the 160 px base built in 0.201 s; the first (cold, first kernel/cube use) pass: 11 looks 0.389 s total (worst cell 0.177 s), 15 styles 0.153 s (worst 0.032 s); warm: looks 0.013-0.016 s, styles 0.014-0.022 s (~1 ms per cell); the style grid with skin protection on: 0.18 s on its first run (first use of that path) then equal to plain (0.008 s). So pushing every cell progressively is cheap and no per-cell pull was needed. NOT measured: a real 24 MP JPEG's base build, heavy states (e.g. Dehaze; masks are stripped from previews anyway), RAW.
Verified (not in the running app): unit tests; and an OFFSCREEN render of the real `LooksTabView` (temporary test, deleted) hosted in an `NSHostingView` on a scratch scene with the real model: 11 look + 15 style previews appeared, three columns, selection rings, the Intensity slider after a look; pixel means of a cell crop confirmed the stacking — after picking the Honey style the Warm Film look cell moved from (151,166,155) to (157,167,149); after picking a Look the Frost style cell moved from (150,166,173) to (150,167,163).
Reviewer rounds: commit 1 two rounds (a false 'matches the click' doc for the None cells, a vacuous local-edits test, missing row-order/alpha tests); commit 2 two rounds (renders were unstructured `Task.detached`, a doc that overclaimed, tests that could not tell whose image was published, and a stale-photo flash fixed with `revision`); commit 3 two rounds (a VoiceOver 'Remove' action on every cell, three columns not guaranteed, RAW re-decode double pass). Every fix mutation-checked.

## History moved to a toolbar popover (2026-10-07) — SHIPPED (commit ae9a078)
Why: the Adjust tab was a very long scroll and History (the last section) is about EVERY edit, including the ones made in other tabs, so it did not belong there. The user left the shape open ("a history icon with a drop-down, or something better"); chosen: a toolbar button + popover — always one click away from any tab, scrubbable, no sidebar space. Alternatives considered and not built: a dock/panel above the filmstrip (permanent screen cost), an Edit-menu command only (poor discoverability, and a Scene command cannot read `ContentView`'s `@State`), putting it on the Looks tab (it also records slider edits).
What changed: pure `HistoryRow.rows(entries:currentIndex:)` (newest first, current/past/undone, VoiceOver strings identical to the old section's); `HistoryPopoverView` (300 pt, height-capped bounded ScrollView + ScrollViewReader, tap = `jumpToHistory(id:)`, stays open); `ContentView.historyToolbarItem` (editor only, own `@ToolbarContentBuilder` because the toolbar closure has hit type-checker failures, yellow tint + `.isSelected` like the filmstrip toggle, `.popover(arrowEdge: .bottom)` — the app's first popover); dismissed on a photo switch, on the Crop tab and in Library mode; the focus hand-back to the image pane is skipped in Library mode and when the dismissing click landed on a text field (checked one run-loop turn later via the field editor's `NSTextView`). The Adjust section, `AdjustPanelState.isHistorySectionExpanded` and its test line were removed. Reviewer: 2 rounds — round 1 caught that an unconditional focus hand-back would steal focus from a text field clicked while dismissing, and from the Library grid.
Read by code, not run: `MetalImageView`'s scroll monitor only acts when `event.window === window`, so scrolling over the popover cannot zoom the photo. NOT verified live: the popover in the running app (see IMPROVEMENTS.md D55).

## Multi-spot Remove — the "Place Spots" tool (2026-10-07) — SHIPPED (08255ed, 72746d6, 62355f3)
Why: the user asked whether spots could be applied "multiple times the same way Lightroom does". The tool already held up to 50 spots and rendered them all, but the editing UI was one-at-a-time: spots were added only by the sidebar button (dropped near the frame centre, not where you click), only the selected spot showed circles, clicking the photo did nothing, size was a slider only. User decisions: an EXPLICIT "Place Spots" toggle (not always-armed), and zoom-while-editing deferred.
Design: pure maths first (`RetouchOverlayGeometry`: view point -> normalized y-up position, drag -> clamped radius, click-vs-drag, hit test, radius handle; `radiusPoints` now clamps to the renderer's range so draw/hit/handle match what is repaired); then the model (`addRetouchSpot(atNormalized:radius:)`, `deleteRetouchSpot(id:)`, each ONE labelled undo step committed directly — through the debounced `editState` path two clicks inside 350 ms would have merged; the auto-source result is its own "Find Source" step and is dropped when redo exists or the spot changed; refusals for no image/non-identity geometry/cap/load in flight/non-finite); then `EditorInteractionMode.placingRetouchSpot` (the enum makes tools mutually exclusive by construction) and the UI (`RetouchSpotsOverlay`: all spots as thin rings + the armed capture layer, create-on-release with a live preview ring; `RetouchOverlayView` gained the radius handle; Delete/Escape via the pure `RetouchKeyAction`; the Compare menu, `canZoom` and the pane's accessibility label know about the tool).
Things the reviewer caught that mattered: hit-test tie-breaking (a small spot exactly centred on a big one could never be selected when the big one came later), an unclamped stored radius making the hit circle bigger than the repaired disc, a late source-search commit that would have wiped the redo stack (click A, click B, undo, A's result lands), the search result merging with the next edit through the coalescing path, rings drifting when the photo is zoomed with the tool off, a stale drag preview when a gesture is cancelled (now a `@GestureState`), and the Stop button being greyed out after Undo restored non-identity geometry. Every fix was mutation-checked; one test had to be turned from a skip into a failure (a skip let a mutant pass silently).
Verified: unit tests; a permanent offscreen render of the real overlays (ring positions incl. the y flip, selected spot not drawn twice, handle on the right edge). NOT verified: the pointer gestures (synthetic mouse events do not reach this sandboxed app) — see the manual checklist in PROGRESS.md. Next: zoom/pan while editing spots (the overlays assume the un-zoomed fit rect).

## Zoom and pan while editing spots (2026-10-08) — SHIPPED (af72012, ed9d669, 476d31b)
Why: the multi-spot Remove tool (above) worked only at fit size — a 0.002-radius spot is 1-2 px on screen — because every overlay is positioned against the UN-zoomed `currentFitRect`, so `canZoom` was false while the tool was armed or a spot selected and the rings hid when zoomed. User decision: pan with Space + drag (the temporary hand tool); zoom itself is the existing scroll-about-cursor.
Design (option "a": only the Remove overlays learn about zoom; every other overlay keeps blocking zoom): the zoomed picture's rectangle did not exist anywhere (the transform lived only in `ImageRenderer.fitted`, in y-up pixel space), so `ZoomPanGeometry.zoomedOriginYUp` was extracted and `fitted` now calls it (reviewer verified the output bit-identical: `-(ph*h)` vs `(-ph)*h`), with `displayedRect` (y-down, mirrored about the fit rect's centre) and `visiblePictureRect` derived from it. All `RetouchOverlayGeometry` maths already took only a rect, so the overlays just receive the displayed rect: circle radii grow with zoom (a fraction of the picture's min side — correct), while hit slop / min ring size / handle size / sizing-drag threshold stay in view points. Presses are accepted only on the visible picture (`displayedRect ∩ pane`); both overlays clip themselves to the pane (anchored top-left, so a one-update lag of the pane size cannot shift them) and handles whose centre is off the pane are switched off (`clipped()` does not limit hit-testing). A press that spans a zoom/pan change is dropped (`PressRecord`, keyed to the press's start point — an earlier version re-recorded on zero translation and could be bypassed; and nil must be VALID or a missing change event would drop every plain click). Space-pan: a separate `.onKeyPress(keys: [.space], phases: [.down, .repeat, .up])` (not folded into `handleImagePaneKeyPress`, whose idempotent-Escape assumptions depend on its default phases), `RetouchZoomRules` (pure) decides tool-active / space-held / pan-layer-mounted, the layer is mounted only with Space held while the tool is active and grabs drags over the whole pane; `isSpaceHeld` resets on tool end (incl. non-identity geometry), pane focus loss, app deactivation and any window resigning key. Picking an off-screen spot from the sidebar pans it to the centre (`ZoomPanGeometry.panToCenter`, verified through `displayedRect`); selecting on the photo never moves the view (a first version panned on every selection change and would have jumped the view under a click near the edge — reviewer-caught). `PanOverlay` got a balanced hover cursor push/pop.
Reviewer rounds: Z1 1 (a stale `fitted` comment, a double trailing newline); Z2 2 (the press guard could be bypassed and could drop clicks; a centred-in-a-mismatched-parent frame; hit-testing not clipped); Z3 3 (Space stuck after an app switch, key-repeat beep, tool 'active' with non-identity geometry, the off-screen spot and the pan-on-every-selection bug). Every fix mutation-checked. Verified: unit tests (geometry incl. cursor-anchored zoom invariance through `displayedRect`, rules, press record, panToCenter), permanent offscreen renders (zoomed ring position, clipping of rings and handles). NOT verified: pointer and key events (they do not reach this sandboxed app) — manual checklist in PROGRESS.md; D59 lists the follow-ups.


## Faces v1 — accuracy spike (2026-10-09, throwaway harness; copies deleted)
Question: can the on-device `VNGenerateImageFeaturePrintRequest` (revision 2, 768 floats, Euclidean) group FACE CROPS by person? (Vision has no public face-identity embedding; the user declined a bundled model.) Method: a standalone Swift script (outside the sandbox, read-only on the catalog DB and on photo files), then COPIES of 23 of the user's photos in `/tmp/livetest_faces` (deleted afterwards): `VNDetectFaceRectanglesRequest` (revision 3) + `VNDetectFaceCaptureQualityRequest` on a 1600 px ImageIO thumbnail, padded square crop resized to 224, prints for 4 crop variants. 32 faces. Ground truth labelled BY EYE from the crops, conservatively: 3 people seen in 3 consecutive frames (A yellow cap, B black cap, C red beanie), a 4th person in 3 frames (D, may equal A so no D-A pairs), 4 studio portraits of one person (E), 5 singles taken as distinct people; ambiguous faces (scuba masks, blurred crowd, p04/p10/p22/p14) EXCLUDED. 18 same-person pairs, 183 different-person pairs.
Measured (distance = Euclidean between unit-ish prints):
- pad 25%: AUC 0.996; same 0.20–0.60 (median 0.36), different 0.45–1.22 (median 1.03); zero-false-merge threshold 0.41 recalls 72 % of same pairs.
- pad 40%: AUC 0.997; same 0.16–0.67 (med 0.30), different 0.53–1.22 (med 1.06); zero-false-merge 0.47 recalls 89 %.
- pad 60%: AUC 0.998; same 0.21–0.61 (med 0.26), different 0.57–1.18 (med 1.05); zero-false-merge 0.47 recalls 83 %.
- pad 40% + roll alignment (rotate by `face.roll`): AUC 0.975 — WORSE than no alignment (rotation artefacts); do not use.
Unlabelled cross-scene probes (pad 40%, distance to the studio portraits E): IMG_2038 0.33–0.43 (very likely the same person), p10 0.48–0.57, p04 0.50–0.54, medal-runner 0.70–0.73, distinct singles 0.72–1.06, same-scene different people (A/B/C) 0.71–0.87. So cross-scene same-person distances reach ~0.55 while clearly different people start near 0.7: there IS a grey zone 0.5–0.7.
Cost: ~20 ms per face print including detection on this Mac; detection over 155 readable photos took 7 s (≈ 45 ms per photo including the 1600 px decode) -> ~1,100 photos in roughly 50 s. Faces found: 43 of 155 photos; quality 0.08–0.11 for the blurred crowd faces, 0.30–0.81 for usable ones (a floor near 0.15 drops the blurred ones).
Caveats (do not over-read): tiny labelled set; many same-person pairs share a scene (prints also encode background/clothing), although the different-person pairs from the SAME scene still separated (0.71–0.87); labels are by eye; no children, no twins, no very different ages, no profile views beyond the tilted frames. Real-world accuracy on the whole library is unmeasured.
DECISION GATE: separation is clean enough for AUTOMATIC grouping at a HIGH-PRECISION threshold. Chosen for v1 (pad 40%, no roll alignment): auto-assign / auto-cluster at distance <= 0.45 (just under the 0.47 zero-false-merge point); faces between 0.45 and ~0.60 of a person are NOT auto-merged (candidates for a later "might also be X" suggestion); faces below a quality floor of 0.15 or narrower than 40 px at the 1600 px thumbnail are not grouped. Complete linkage for clustering (same reasoning as duplicates); manual merge, rename, "not this person" are part of v1 because the grey zone and the small sample guarantee mistakes.

## Photo Merge spike (HDR + panorama) — started 2026-10-09
Plan: /Users/praween/.claude/plans/curious-twirling-teapot.md (staged: spikes, shared plumbing, HDR, panorama; output 16-bit TIFF with headroom).
Stage 0, spike 1 (registration), `Tests/RenderingTests/ImageRegistrationProbeTests.swift`, Apple M1, macOS 27.0, 800x600 synthetic textured scene:
- `VNTranslationalImageRegistrationRequest`: content moved +13 px right / 7 px up gave tx = -13.0, ty = -7.0 exactly, 0.017 s. The transform maps the target onto the reference in bottom-left-origin (Core Image) coordinates.
- `VNHomographicImageRegistrationRequest`, shift + 2 degree rotation: recovered sin(theta) 0.03497 / 0.03462 (true 0.03490), 0.109 s.
NOT yet measured: real handheld photos, large frames (proxy scaling), exposure-differing pairs (HDR brackets are the hard case for registration), spikes 3 and 4 (merge algorithm, panorama projection/blend).
Stage 0, spikes 2+3 (`Tests/RenderingTests/HDRMergeProbeTests.swift`, same machine, 400x300 synthetic, highlights to radiance 4.0, 8-bit sRGB frames):
- Registration across EXPOSURE differences: translational registration of the frames as-is works only at 0 EV; at +1/+2/+3/-2 EV it returns garbage ((174,-5), (260,225), (300,225), (-8,225)). Brightening the DARKER frame to the brighter one's exposure (gain, clip, re-encode) recovers the true (9,-5) shift exactly at every tested offset. Normalizing only the target fails for brighter targets (clipped highlights cannot be restored). So HDR alignment must register exposure-matched PAIRS (darker frame brightened), not raw frames.
- Weighted radiance merge in linear light (tent weight squared on the encoded value, divide by 2^EV) of a -2/0/+2 EV bracket: max relative error 1.1%, mean 0.37% over all pixels; highlight pixels above radiance 1.0 (n=35996, only the -2 EV frame holds them unclipped) max 0.75%. Fixture is noise-free 8-bit quantization only: sensor noise, real camera response curves and moving subjects are NOT measured.
Still open: panorama projection/blend (spike 4), real handheld photos, large-frame proxy scaling.
Stage 0, spike 4 (panorama registration, `Tests/RenderingTests/PanoramaRegistrationProbeTests.swift`; same machine; 480x320 frames, 60 degree FOV pinhole camera yawing over a synthetic textured sphere, EXACT K R K^-1 truth, sanity-checked: mean pixel difference 0.85 gray levels at mapped points):
- Convention: `VNHomographicImageRegistrationRequest`'s `warpTransform`, converted with a bottom-left <-> top-left y flip, maps TARGET pixels onto REFERENCE pixels (same direction as the translational request).
- Plain homography is a SMALL-MOTION API: mean error 0.055 px at a 1 degree step (~8 px of shift), 3.6 px at 2 deg, 17.8 px at 4 deg, 43.8 px at 6 deg, 76 px at 10 deg, 136 px at 20 deg. Useless alone for panorama steps (30%+ of the frame).
- Translational request on large pans: horizontal shift is right (154 px at 20 deg, f*tan(20 deg) = 151) but the VERTICAL component came back wrong (about -188 px) at 10, 20 and 30 deg for a level pan whose true dy is 0 — cause NOT investigated.
- Coarse-to-fine (translational dx, dy FORCED 0, shift the target, then homographic refinement, composed): mean error 0.41 / 0.54 / 0.53 px at 4 / 10 / 20 deg, 6.1 px (max 16.5) at 30 deg (about 50% overlap). With the unconstrained dy it fails at >= 10 deg. So level yaw-only panoramas of up to ~20 deg steps are bootstrappable with Vision alone; a general (handheld, tilted, rolled) panorama needs real feature matching, which does not exist in the repo or Vision. A chained 3-frame level pan (0, 15, 30 deg): per-step mean 1.96 / 0.46 px, chained 2->0 mean 1.83 px, max 6.75 px (n=41) — before blending, so a visible seam is plausible without a blend/refinement pass.
NOT measured: blend method (feather vs pyramid), cylindrical re-projection (the homography chain is exact only for pure rotation and stretches badly toward wide fields of view), real handheld frames, exposure differences between panorama frames, parallax.
Stage 0 conclusion for the plan: HDR (small handheld motion, exposure-matched pairs, radiance merge) is feasible with the measured building blocks. Panorama is feasible ONLY for level, yaw-style pans in v1 unless a feature matcher is built (own spike) — recommend scoping v1 panorama to that and telling the user in the UI.
Stage 0, spike 5 (hand-built feature matcher, `Tests/RenderingTests/FeatureMatchProbeTests.swift`; same machine/scene as spike 4; Debug build): Harris corners (5x5 window, NMS 8 px, <=500) + ORB-style intensity-centroid orientation + 21x21 rotated, zero-mean unit-norm patch descriptors + mutual nearest-neighbour matching with a 0.85 ratio test + RANSAC homography (2000 iterations, 3 px threshold, conditioned DLT, inlier refit). Against the exact rotation homography:
- Level yaw: 10 deg mean 0.22 px (47 inliers), 20 deg 0.33 px (max 1.10, 25 inliers), 30 deg 0.37 px (max 1.50, 14 inliers), 40 deg (about 33% overlap): 27 matches and NO model.
- Yaw 20 + pitch 5 + roll 5: 0.56 px (max 1.09, 21 inliers); yaw 15 + pitch -8 + roll 12: 0.29 px (max 0.56, 23 inliers). Vision's homography/translation fail these; so this closes the general-panorama gap on synthetic data.
- Caveats: ~90 keypoints per frame because the synthetic scene is sparse; no scale change, no noise, no parallax, no lens distortion, no exposure difference, 480x320 frames only. Timing (~2 s per pair) is an unoptimised Debug build and not a performance figure. Real handheld photos are the next unknown.
Conclusion for the plan: panorama registration should use this feature-matching approach (moved into Sources/EditEngine as a pure, tested module), and does NOT need to be limited to level pans; the usable overlap floor on this scene is between 33% and 50%, so the UI should ask for >= ~50% overlap. HDR alignment can also use it on exposure-matched pairs.
Stage 0, spike 6 (feature matcher on REAL photos, 2026-10-09; standalone `swiftc -O` harness built from the same matcher source in the session scratchpad — not in the repo — run on scratch COPIES of 3 Bolivia photos (IMG_6406 sunset car, IMG_6564 group jump, IMG_6386 selfie), each downscaled to 960 px wide, keypoint cap 1000):
- Known-truth crops of ONE real photo (target = reference window moved right 30 / 50 / 65% of its width): inliers 98 / 97 / 93% (IMG_6406), 94 / 91 / 85% (IMG_6564), 98 / 97 / 92% (IMG_6386); mean error 0.19-0.57 px, worst max 1.52 px (65% shift = 35% overlap). Same crop rotated 5 / 10 deg: mean 0.07-0.42 px; scaled 1.1: 0.08-0.24 px; rotated 5 deg + scaled 1.15: 0.07-0.17 px (the descriptor is NOT scale-invariant by design, yet 1.15x still matched at 87-96% inliers).
- REAL handheld pairs (no ground truth; implied centre motion only): IMG_6562->6563 94 inliers of 122 matches (77%), centre moves (0.9, -2.1) px; 6563->6564 95/134 (70%), (-2.6, -5.5) px; 6386->6387 382/461 (82%), (-26, -12) px with 1.8% scale change; 6406->6407 405/419 (96%), (-9.2, -0.8) px. These burst photos contain moving people, so lower inlier ratios there are expected; no visual verification of a warped result was done.
- Timing, optimised build, one pair at 960 px: detection 0.06-0.13 s, matching 0.09-0.30 s (brute-force 1000x1000 descriptor dot products, the dominant cost), RANSAC 0.01-0.02 s. About 0.2-0.5 s per pair.
Caveat: same-photo crops share noise, exposure and lens, so they are the optimistic case; real overlapping panorama frames (exposure drift, parallax, vignetting, distortion) are NOT yet tested because no true panorama sequence was available. Decision: build the matcher into Sources/EditEngine (pure, tested) for both HDR (exposure-matched pairs) and panorama; keep the 0.85 ratio test, 3 px RANSAC threshold; ask for >= ~50% overlap in the UI.
Stage 2 (HDR merge engine, 2026-10-09; commits 6d4266d FeatureMatcher, d061a67 HDR core, then PhotoMerger):
- PLAN CORRECTION (`Tests/RenderingTests/FloatTIFFProbeTests.swift`): the plan's "16-bit TIFF keeps headroom" was wrong. An integer RGBA16 TIFF clipped a linear 3.0 to 1.0 on the round trip through `RawDecoder.decode`; half-float (`.RGBAh`) and float32 (`.RGBAf`) TIFFs returned 3.0 / 7.25 exactly. The merge therefore writes a HALF-FLOAT TIFF (about 8 bytes/pixel: ~190 MB for 24 MP, uncompressed).
- `PhotoMerger.mergeHDR` end-to-end on a synthetic -2/0/+2 EV JPEG bracket (480x360, EXIF shutter/aperture/ISO written, the dark/bright frames shifted (7,-4) / (-5,3) px, true radiance to 4.0): mean relative error of the merged red channel vs the true radiance 1.05% WITH alignment vs 17.2% with alignment off; 9158 true-highlight pixels (>1.2), 100% came back above 1.0 through the float TIFF. Registration inliers 13 (the -2 EV frame; the floor is 12, so this is marginal) and 43 — shadows of a dark 8-bit frame, once brightened, give the matcher little to work with. Real photos not yet run through PhotoMerger.
- Reference = the median-brightness frame (brightness = shutter * ISO / f^2; EXIF exposure bias ignored); gains must lie within 1/16..16 (4 stops from the reference) and a bracket needs >= 0.3 stop spread; frame count 2...9; frames must share pixel size.
