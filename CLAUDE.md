# Photo Editor (Lightroom-style) — Project Memory

## What this project is
A native macOS photo editor with a library/catalog, in the spirit of Lightroom.
Non-destructive editing is the core invariant: **original files are never modified**.
Edits are stored as parameter sets and rendered live on the GPU.

## Documentation map
- **CLAUDE.md** (this file): current, compressed status — what's shipped, what's
  next, rules. Kept small because it loads into every session's context.
- **`docs/ROADMAP_HISTORY.md`**: the full unabridged history behind every roadmap
  line below — session write-ups, reviewer rounds, live-verification detail,
  measured numbers. Read the relevant entry there before modifying an
  already-shipped item, especially RAW (Phase 6) or Masking (Phase 7).
- **`PROGRESS.md`**: resumption state — current phase, in-progress work, exact
  next step, open reviewer issues. Read first when resuming after a cutoff.
- **`IMPROVEMENTS.md`**: known non-blocking gaps/nits logged during review,
  not yet worth their own session.

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

Full history, reviewer rounds, live-verification detail, and measured numbers
for every item below live in `docs/ROADMAP_HISTORY.md`. Before modifying any
already-shipped item — especially RAW (Phase 6) or Masking (Phase 7) — read
that item's entry there first: several ship with hazards, migration notes, or
measured-but-counterintuitive behavior that isn't repeated here.

1. Foundation: Xcode project, open + display an image in a Metal-backed view — ✅ COMPLETE
2. Edit engine: exposure, contrast, white balance, curves, HSL, crop, transform/distort — see Phase 2 backlog below
3. Non-destructive pipeline: param serialization, edit history, undo — ✅ COMPLETE
   - In-memory Undo/Redo, time-coalesced ~350ms bursts — `Sources/EditEngine/EditHistory.swift`
   - Revert to Original (always resets to true identity)
   - Sidecar-file persistence (`MyPhoto.jpg.photoapp.json`, per-folder security-scoped bookmark)
   - `EditState.Codable` is schema-tolerant (missing key → per-field default)
4. Library: import, catalog DB, thumbnail grid, ratings/flags, collections — ✅ COMPLETE
   - Catalog DB (GRDB) + folder import — `Sources/Catalog/`, `Photo`, `Migrations/001_initial.swift`, `CatalogDatabase`
   - Thumbnail grid — `Sources/Rendering/ThumbnailGenerator.swift`, `LibraryGridView.swift`
   - Ratings (0–5) + flags — `Migrations/002_ratings_and_flags.swift`
   - Collections (albums) — `Migrations/003_collections.swift`, `CollectionSidebarView.swift`; the record is `PhotoCollection`, not `Collection` (would shadow `Swift.Collection`)
   - `LibraryFilter` enum replaces an optional `selectedCollectionID` binding — avoids a known SwiftUI `List(selection:)`-with-`Optional` quirk
   - Not started: removing photos from catalog, detecting deleted-on-disk files, pick/reject 3-state, keyboard shortcuts, rename/delete collections
   - Post-Phase-4 follow-up: folder-mirrored nested collections — `PhotoImporter.scanFolderTree`, `Migrations/004_folder_collections.swift`, `OutlineGroup` in sidebar
5. Presets + export: save/apply presets, batch export — ✅ COMPLETE
   - Batch export (JPEG/PNG/TIFF, resize/quality, progress HUD) — `Sources/Rendering/PhotoExporter.swift`; sandbox needs `user-selected.read-write` (not read-only)
   - Per-photo export selection — `CatalogModel.selectedPhotoIDs`
   - Presets (save/apply named looks, excludes crop/geometry fields) — `Sources/Catalog/Preset.swift`, `Migrations/005_presets.swift`, `EditState.applyingPreset(onto:)`
   - Follow-ups: Adjust-tab restyle to match Apple Photos (`DisclosureGroup` sections), custom `ThinSlider.swift` replacing the native slider, Editor/Preview color-space fix (`outputColorSpace` tagging on the Metal layer), Library thumbnails now reflect saved edits, Compare mode (Side by Side / Split — `CompareLayout.swift`, `EditState.comparisonOriginal()`), scroll-to-zoom + pan (`ZoomPanGeometry.swift`), Library sort/filter/search (`LibraryFilterSort.swift`), click-to-type numeric entry on sliders (`displayMultiplier` param)
6. RAW support — ✅ COMPLETE for this camera (Nikon D610). Shipped on `CIRAWFilter` instead of LibRaw (see Stack section above — do not revert without re-reading that rationale).
   - `Sources/Rendering/RawDecoder.swift` — shared decode chokepoint for Editor/Export/Thumbnails
   - RAW-native `EditState` fields shipped: `boostAmount`, `rawExposureEV`, `shadowBoostScale`, `rawWhiteBalanceNeutralPoints` (fast-path WB eyedropper, identity-geometry only), `rawLuminanceNoiseReductionAdjust`, `rawColorNoiseReductionScale`, `rawSharpnessScale`, `rawContrastAdjust`, `rawDetailAdjust`, `rawMoireReductionAdjust`, `rawDecoderVersionPin` (determinism pin, captured once per photo, survives Revert)
   - `EditState.requiresRawRedecode`/`isEffectivelyIdentity` are the single sources of truth for "which fields force a re-decode" / "is this RAW photo untouched" — use these, not ad hoc checks
   - Deferred: `lensCorrectionEnabled` (measured unsupported on this camera — don't re-add without re-measuring), full inverse-geometry for the WB eyedropper beyond identity geometry
7. Local Adjustments (Masking) — ✅ FULLY COMPLETE (2026-09-15)
   - 5 mask kinds: `.radial`, `.linear`, `.brush`, `.luminanceRange`, `.colorRange` — `Sources/EditEngine/Mask.swift`, `EditPipeline.applyMasks`
   - Multiple independently-compounding masks per photo + intersect/subtract combining (`Mask.combineMode`/`combineWithMaskID`)
   - Geometry helpers: `RadialMaskGeometry.swift`, `LinearMaskGeometry.swift`, `BrushMaskGeometry.swift`, `MaskGeometry.swift` (UI-side inverse), `ColorRangeSelection.swift`, `LuminanceRangeSelection.swift`
   - Second custom Core Image kernel in this area: `ColorRange.cikernel`
   - Known non-blocking perf finding: `.brush` ∩ `.brush` with Clarity exceeds the 16ms/60fps budget on full-res RAW frames (interactive/proxied path stays under budget) — see history doc before optimizing
   - Explicitly out of scope, needs its own research spike: AI Subject/Sky/Object select masks, Depth Range masks
8. Polish: tiled rendering for large images, perf, edge cases — not started

One feature per session. Do not start a later phase while an earlier one has open issues.

### Phase 2 edit engine backlog
Grouped to match Apple Photos' adjustment panel. Full detail in `docs/ROADMAP_HISTORY.md`.

- **Light:** Exposure ✅, Contrast ✅, Brightness ✅ (additive, distinct from Exposure's multiplicative gain), Black Point ✅ (via Curves' point0), Brilliance ✅ (this app's own composite approximation, not Apple's algorithm). Shadows/Highlights live under Curves v1, not as dedicated sliders.
- **Color:** Saturation ✅ (HSL v1), Vibrance ✅ (`CIVibrance` — protects saturated/skin tones), Cast ✅ (`ImageDocumentModel.fixColorCast()`, writes existing WB fields, no new fields/stage).
- **Black & White:** ✅ on/off toggle only (no Intensity/Neutrals/Tone/Grain).
- **Red-Eye:** ✅ — `EditState.redEyePoints` (this app's first variable-length/user-placed collection field), union mask via `CIMaximumCompositing`.
- **White Balance:** Temperature/Tint ✅, eyedropper ✅ (`WhiteBalanceSolver`, numerical search — `CITemperatureAndTint` has no closed-form inverse).
- **Curves:** v1 ✅ (2-point parametric, now on `ToneCurve.cikernel` since v2 slice 1 — headroom-preserving, replacing the old `CIToneCurve` highlight clamp). v2 (interactive point-curve editor) — **✅ FULLY SHIPPED**. Slices 1 (kernel swap), 2A (additive point-curve stage — `EditState.toneCurvePoints`, `MonotoneToneCurve`, `PointToneCurve.cikernel`, 8-point cap), 2B (the editor UI — `ToneCurveEditing.swift`, `ToneCurveEditorView.swift`, a new "Curve" sidebar section), and 3 (per-channel RGB — `EditState.toneCurvePointsRed/Green/Blue`, `PointToneCurve.cikernel`'s `channelMask` argument, a segmented Red/Green/Blue/RGB channel picker in the "Curve" section via `ToneCurveChannel.swift`, `.id(channel)`-scoped `ToneCurveEditorView`) are all shipped, reviewed, and live-verified. Slice 3's composite-then-channel stage order is a measured REQUIREMENT (~23.5x this suite's tolerance); R/G/B mutual order is not (measured bit-identical). Slice 2B was the first vertical-drag-inside-a-vertically-scrolling-sidebar interaction in this app — live-verified with real synthetic mouse/scroll events (not just AX actions or tests) that it doesn't fight the ScrollView; see `docs/PROGRESS_HISTORY.md` for the two real bugs (a crash, and a multi-point-delete data-loss bug) the reviewer caught across 3 rounds before APPROVE.
- **Levels:** ✅ — `levelsBlackPoint`/`levelsWhitePoint`/`levelsGamma` (distinct fields from Curves' own `blackPoint`). Live histogram — `HistogramComputer`, `HistogramView`.
- **Definition (Clarity):** superseded — split into bipolar `texture` + `clarity`. `definition` no longer exists as a field; kept only as a read-only legacy decode key (`EditState.LegacyCodingKeys`). **Do not re-add `definition`.**
- **Dehaze:** ✅ — dark channel prior (He/Sun/Tang 2009), 2 custom kernels (`DehazeDarkChannel.cikernel`, `DehazeRecover.cikernel`). Runs before Vignette/Clarity (measured, not conventional). Known limitation: near-zero effect on underwater photos (water absorbs red — the textbook failure case for this prior, not a bug).
- **Selective Color:** ✅ — HSL v2, 8 fixed hue bands × Hue/Saturation/Luminance, `SelectiveColor.cikernel` (this app's first custom kernel).
- **Color Grading:** Slice A (backend) ✅ — 3-way Shadows/Midtones/Highlights, each Hue/Saturation/Luminance (9 fields), `ColorGrading.cikernel` (8th custom kernel). Unlike Selective Color (per-hue targeting), selects by each pixel's own LUMINANCE via a raised-cosine falloff over 3 fixed anchors — no on-GPU HSL round-trip needed, since `ColorGradingTint.swift` converts each wheel's Hue/Saturation to a signed RGB tint delta once per render in Swift. Runs LAST inside `applyPerceptualAdjustments`'s sandwich — a measured REQUIREMENT, not a convention, for two independent reasons: it must survive Black & White's forced desaturation (so a B&W split-tone/sepia look works, this feature's single most common real use) and it measurably does not commute with Vibrance/Saturation either. `Blending`/`Balance` sliders and the 4th "Global" wheel are deferred; the kernel's fixed width/tint-strength/luminance-strength constants (0.4/0.8/0.5) are v1's principled default for what Blending will eventually control. Slice B (the color-wheel UI) — ✅ SHIPPED: `ColorWheelGeometry.swift` (pure polar↔screen-point math, this app's first continuous-hue rendering UI), `ColorGradingWheelView.swift` (the draggable wheel), `ColorGradingRange.swift` (presentation-only Shadows/Midtones/Highlights selector, `selectedToneCurveChannel`'s pattern), wired into a new "Color Grading" section in `AdjustTabView`. Reviewer: 3 rounds, FIX FIRST → FIX FIRST → APPROVE — round 1 caught a wrong `AngularGradient` fraction-convention assumption (painted wheel rotated 90° from the puck), a missing wrap-around gradient stop, an unrelated hardcoded `RadialGradient` radius, a too-tight/incomplete center-snap epsilon (didn't zero Saturation, and was an absolute point distance rather than a radius fraction, so real cursor input essentially never hit it), three disagreeing "is this range edited" definitions across the segment-label dot/per-range Reset/top-level identity check, and an overclaiming `.id()` doc comment; round 2 caught a residual doc contradiction and a test that passed trivially without cross-checking anything. The `AngularGradient` convention itself (fraction 0 = right edge, sweeping clockwise) is DERIVED from documentation, not live-verified on screen — flagged in both `ColorWheelGeometry.angularGradientFraction`'s and `ColorGradingWheelView.hueGradientStops`'s own doc comments for a future live pass. Keyboard/VoiceOver support and a numeric Hue/Saturation readout are explicitly deferred (`IMPROVEMENTS.md` D20) — only Luminance has an accessible/typed-entry path today.
- **HSL v1:** ✅ global Hue + Saturation only (no Lightness — would duplicate Exposure/Curves).
- **Noise Reduction:** ✅ single Amount slider (`CINoiseReduction`).
- **Sharpen:** ✅ single Amount slider (`CISharpenLuminance`). No longer the pipeline's final stage — Grain runs after it (measured: sharpening after grain amplifies it ~2.4x).
- **Grain:** ✅ single Amount slider, `FilmGrain.cikernel` (7th custom kernel) blending a `CIRandomGenerator` noise field, sampled directly by the kernel with NO `CIColorClamp`/`CIColorMatrix` in between — an adversarial reviewer re-measurement caught that those Core Image "color matrix" family filters silently corrupt `CIRandomGenerator`'s output (an implicit premultiply/unpremultiply round trip they perform on ANY input, real premultiplied data or not) into a resolution-dependent hidden exposure lift; see `EditPipeline.kGrainZeroPoint`'s own doc comment for the full story of a real bug caught after this slice's own initial ship-ready review. Noise cell size is a fraction of `min(extent)` (same mechanism as Sharpen's radius), sampled with `.samplingNearest()` (not the default bilinear, which measurably shrinks the noise's amplitude once the cell exceeds 1px) so apparent grain size AND intensity stay consistent across thumbnail/proxy/full-res. Grain-AFTER-Sharpen and grain-AFTER-Noise-Reduction are both measured requirements, not conventions (reversing either is what was measured and rejected) — see `EditPipeline.applyGrain`'s own doc comment.
- **Vignette:** ✅ Strength + Radius (`CIVignetteEffect`, centered on post-crop extent). Softness/falloff not built.
- **Transform/Distort:** Straighten ✅, Vertical/Horizontal perspective (keystone) ✅ (`CIPerspectiveTransform`). Lens distortion correction not built (needs camera-profile data).
- **Flip:** ✅ horizontal/vertical toggles.
- **Crop:** ✅ v1 (numeric insets) + v2 (drag-handle rect, 8 handles) + aspect-ratio presets (Original/Freeform/Square/16:9/4:5/5:7/4:3/3:5/3:2/Custom).

### Gaps vs. Adobe Lightroom Desktop
Cross-checked 2026-09-03 against Lightroom Desktop's Light/Color/Effects/Detail/
Optics/Geometry panels and Masking/Remove-tool/Denoise sub-pages. Full
rationale/history in `docs/ROADMAP_HISTORY.md`. Items marked **WANTED** are
user-confirmed to build — pick from those first when choosing the next slice.
(Curves v2, above, is also WANTED — check both this section and the Phase 2
backlog above when picking what's next; Curves v2 previously lived only in the
backlog and was missed once for that reason.)

**Tier 1 (fits the existing global-adjustment architecture — new `EditState`
field(s) + `EditPipeline` stage(s) + `AdjustTabView` section):**
- Texture / Clarity — ✅ SHIPPED (see Phase 2 backlog above; do not re-add `definition`)
- Dehaze — ✅ SHIPPED (see Phase 2 backlog above)
- Grain — ✅ SHIPPED (see Phase 2 backlog above)
- Color Grading (3-way shadow/mid/highlight color wheels) — ✅ FULLY SHIPPED, both Slice A (backend) and Slice B (the color-wheel UI control) — see Phase 2 backlog above
- Point Color (per-color eyedropper refinement, distinct from Selective Color's 8 fixed bands) — WANTED, not started; likely needs a variable-length collection field, like `redEyePoints`
- Chromatic Aberration removal — WANTED, not started; purely additive
- Manual Transform Scale/Aspect — WANTED, not started; same Transform/Distort stage group already exists
- RAW-native AI Denoise — cross-reference only, overlaps the already-shipped RAW NR fields in Phase 6

**Tier 2 (genuinely new architecture — don't underscope):**
- Curves v2 (interactive point-curve editor) — ✅ FULLY SHIPPED (slices 1/2A/2B/3, all reviewed and live-verified); see Phase 2 backlog above
- Masking / local adjustments — ✅ SHIPPED as Phase 7 (see Roadmap above)
- Remove tool (AI content-aware object/spot removal) — not started, needs inpainting, not achievable with the current Core Image filter-chain approach
- Auto Tone / Auto Settings — WANTED, not started; likely a heuristic v1 following the Fix-Color-Cast pattern (histogram-driven, no ML), not assumed to need ML
- Enhance / Super Resolution — WANTED, not started; a new render/export capability, not an `EditState` field — needs research into what's actually available on macOS before it can be scoped
- History panel (browsable/scrubbable edit list, not just linear undo) — not started; `EditHistory` already has the underlying data
- Copy/Paste and Sync edit settings across selected photos — not started; distinct from Presets (no naming/saving step)

**Confirmed NOT a gap:** Before/After comparison — covered by Compare mode
(Side by Side / Split, Phase 5 follow-up).

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
