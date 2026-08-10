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
   — STARTED. Catalog DB foundation + basic folder import ✅ COMPLETE:
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
   note carried forward in `PROGRESS.md` (rapid repeated taps can
   transiently show a stale rating in the grid — self-heals, not a
   persisted-data bug). Collections is NOT started; also not started:
   sort/filter/search (including by rating/flag), removing photos from
   the catalog, detecting files deleted on disk since import, a
   three-state pick/reject model, keyboard shortcuts for rating/flagging.
5. Presets + export: save/apply presets, batch export (resize, quality, format)
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
