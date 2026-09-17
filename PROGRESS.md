# Progress

## Current phase
**Phase 2 (Edit engine), Phase 3 (non-destructive pipeline), and Phase 4
(Library) are ALL COMPLETE.** Phase 4's four slices — catalog DB
foundation + basic folder import, thumbnail grid browsing view, ratings
and flags, and collections — all shipped, reviewer-approved, and
manually verified live; see below. A user-requested follow-up feature,
folder-mirrored nested collections (outside Phase 4's original scope),
has ALSO shipped since — see its own section below. **Phase 5 (Presets +
export) is now COMPLETE** — slice 1 (batch export) and slice 2 (Presets,
2026-09-01) both shipped and reviewer-approved; see their own sections
below. (The two real issues found live during slice 1's own verification —
Library thumbnails not reflecting edits, and the Editor-vs-Preview color
discrepancy — were both fixed in later sessions, see their own sections.)
**Phase 6 (RAW support) slice 1 (decode only, via Core Image's `CIRAWFilter`
rather than the originally-planned LibRaw) is COMPLETE and fully live-verified
2026-09-03** — shipped and reviewer-approved 2026-09-02, then two severe
freezes surfaced during the user's own live pass (see the two "Phase 6 slice
1 follow-up" sections below), both diagnosed, fixed, reviewer-approved, and
re-verified live; see CLAUDE.md's roadmap item 6. Slice 2 (RAW-native
controls: exposure/boost/lens correction/true WB eyedropper/NR/sharpness as
`EditState` fields) is not yet started. The original six
roadmap items, five
backlog tone/color additions (Brightness, Black Point, Brilliance, Vibrance,
Vignette), Crop v2's drag-handle rectangle + aspect-ratio presets, Flip,
Straighten, Vertical/Horizontal perspective correction, the full Apple
Photos-style layout (dark theme + top tab bar), Black & White, Sharpen,
Noise Reduction, Definition (Clarity), Levels (with a live histogram), the
WB neutral-gray eyedropper, Selective Color (HSL v2), Red-Eye removal, and
finally Cast (color-cast neutralization) are all shipped, each
reviewer-approved and manually verified live — every item in CLAUDE.md's
"Phase 2 edit engine backlog" is now ✅. Only Undo/Revert-to-Original
remains explicitly deferred (see "Exact next step" below); nothing else is
outstanding in Phase 2. The Apple Photos Crop-panel batch (6 features, see
below) completed first; the user then asked to work through the REST of
the Phase 2 backlog, ending with Cast. The roadmap in
CLAUDE.md was expanded three times at the user's request to spell out the
fuller scope: first adding Transform/Distort and v2 notes for
curves/HSL/crop, then using Apple Photos' adjustment panel (screenshots the
user shared) as a completeness reference, then again refining
Transform/Distort and Crop v2 against Photos' specific Crop-panel controls.
Full detail lives in CLAUDE.md's "Phase 2 edit engine backlog" section — do
not duplicate it here, just read it there.

**The Apple Photos Crop-panel batch (complete):**
1. ✅ Flip — done (see below).
2. ✅ Straighten (rotation angle) — done (see below).
3. ✅ Vertical + Horizontal perspective correction (keystone) — done (see below).
4. ✅ Grid guideline overlay for Straighten/Vertical/Horizontal — shipped,
   then **REMOVED** by feature 6 below. Do not re-add without re-reading
   feature 6's write-up first — it's not a regression, the functionality it
   provided is now covered by `CropOverlayView`'s own always-visible grid.
5. ✅ Crop v2 aspect-ratio presets — done (see below), including a follow-up
   visual tweak (crop handles restyled from plain circles to Apple-Photos-
   style L-shaped corner brackets + edge bars, per user feedback).
6. ✅ Layout redesign (dark theme + top tab bar) — done (see below). Closed
   out the batch triggered by the user's second screenshot + explicit
   "change app color to dark mode" request.
Lens distortion correction (also listed under Transform/Distort in
CLAUDE.md's backlog) was explicitly OUT of that batch — it wasn't in the
screenshot and needs camera-profile data, a much bigger, separate concern;
flag to the user if they want it included later.

**Remaining Phase 2 backlog, user-requested sequence (cheapest/foundational
first, new-interaction-paradigm items next, biggest-scope items last, Cast
deliberately last since it needs a different content-aware architecture):**
1. ✅ Black & White (monochrome mode) — done (see below).
2. ✅ Sharpen (parametric) — done (see below).
3. ✅ Noise Reduction (parametric) — done (see below).
4. ✅ Definition/Clarity (local-contrast enhancement) — done (see below).
5. ✅ Levels (black/white-point/gamma sliders + a live histogram) — done
   (see below).
6. ✅ WB neutral-gray eyedropper (first point-and-click interaction in the
   app) — done (see below).
7. ✅ Selective Color (HSL v2, per-band panel — 8 bands × 3 params, biggest
   scope of the remaining items) — done (see below).
8. ✅ Red-Eye removal (point-and-click + region-based correction) — done
   (see below).
9. ✅ Cast (color-cast neutralization — content-aware gray-world-style
   statistics, a different architecture from every other adjustment so
   far; deliberately last, as established when it was first deferred) —
   done (see below). **This was the FINAL item in the Phase 2 backlog —
   Phase 2 is now complete** (modulo Undo/Revert, still explicitly
   deferred pending the user asking again).

**User also asked about Undo / "Revert to Original" (2026-08-04) — held off
for now, explicitly deferred, not started.** Clarified the scope split for
next time: a simple "Revert to Original" button (reset `editState` to
identity, same as what already happens on new-photo load) is trivial and
could be added standalone anytime; full Undo/Redo with edit history is
Phase 3 work ("non-destructive pipeline: param serialization, edit history,
undo" in CLAUDE.md) and needs its own explicit go-ahead as a new phase, per
CLAUDE.md's roadmap-order rule — same gating as always for Phase 3.

Phase 3 (non-destructive pipeline: param serialization, edit history, undo)
remains after Phase 2's expanded scope is done, and also needs its own
explicit go-ahead when reached.

### Backlog items — Brightness, Black Point, Brilliance (complete, verified live)
- `Sources/EditEngine/EditState.swift` — `brightness` (-1...1, after
  `exposureEV`), `blackPoint` (-1...1, in the Curves section), `brilliance`
  (-1...1, its own section before HSL). All default 0.
- `Sources/EditEngine/EditPipeline.swift` — **Brightness**: `CIColorControls.brightness`,
  perceptual domain (documented deviation, same family as Contrast) —
  measured that a linear-domain additive offset is non-photographic (crushes
  shadows hard); runs FIRST in the sandwich (measured non-commuting with
  Contrast); does not clamp highlight headroom. **Black Point**: extends the
  existing `applyCurves`'s `point0` (previously hardcoded `(0,0)`) along its
  X axis — verified, not assumed, to produce Levels-style clip-to-black.
  Known, documented limitation: `CIToneCurve` extrapolates rather than
  hard-clamps near point0, giving a mild "soft" overshoot on the crush side,
  same family as curves' existing clamp/crossover notes. **Brilliance**: this
  app's OWN composite (explicitly not Apple's proprietary, undocumented
  algorithm) — a pure render-time blend via a new `EffectiveTone` struct that
  nudges *effective* contrast/shadows/highlights/saturation without ever
  mutating the underlying slider values. Verified algebraically:
  `brilliance: 1` produces byte-identical output to manually dialing in its
  constituent weighted deltas.
- Reviewer traced that `brilliance == 0` reduces to exactly the pre-existing
  behavior for every already-shipped test (no regression), and independently
  re-verified several of the ~35 new measured test values via a standalone
  script rather than trusting the numbers because tests passed.
- 77 tests total (35 new), all passing. 1 commit (color-math + tests, UI
  folded into the sidebar restructure below).

### UI — moved to a resizable right-hand sidebar (complete, verified live)
User requested (after seeing the 3 new sliders land in the old bottom bar)
moving the whole panel to a Lightroom/Photos-style right-hand sidebar, then
moving each row's label above its slider instead of beside it. Implemented
as `HSplitView` (image canvas + resizable sidebar, 260-380pt) and a new
reusable `EditSliderRow` component replacing 15 near-identical
label/slider/readout/reset blocks. Reviewer cross-checked all 15
label/binding/range/identity/format pairings for transposition errors (none
found) and confirmed toolbar/title/alert placement is unaffected by the
restructure. 1 commit.

### Backlog item — Vibrance (complete, verified live)
- `Sources/EditEngine/EditState.swift` — `vibrance` (-1...1, default 0, own
  `// MARK: - Vibrance` section, after `hslSaturation`).
- `Sources/EditEngine/EditPipeline.swift` — new `applyVibrance` via Core
  Image's `CIVibrance` (`filter.amount`, 1:1 map, no span constant needed).
  Runs in the perceptual sandwich immediately BEFORE plain saturation
  (measured non-commuting with it — max delta 0.243 on a saturated color).
  Selective by design: +0.5 lifts a muted color's HSV-saturation by +0.164
  but an already-saturated color by only +0.018 (~9x less) — the defining
  "protects already-saturated tones" property, measured not assumed. Does
  NOT clamp highlight headroom. Kept independent of Brilliance (Brilliance
  already nudges plain saturation; routing it into vibrance too would
  double-count one slider's "pop").
- **Notable asymmetry, caught by the reviewer's own re-measurement**: vibrance's
  "protection" is a positive-amount-only property. At `vibrance: -1`, the
  already-saturated test color actually loses MORE absolute HSV-saturation
  (0.184 drop) than the muted one (0.140 drop) — the opposite of the
  positive-side story. First test-writing attempt assumed false symmetry and
  failed against the real `xcodebuild test` run; corrected to assert the
  actual measured relationship and documented the asymmetry in a comment so
  a future reader doesn't assume it's mirrored.
- First reviewer pass was FIX FIRST: missing dedicated MARK sections in both
  `EditState.swift` and `EditPipeline.swift` (vibrance had been appended
  under the HSL/Saturation headings instead of getting its own), and no test
  covered the negative side of the slider at all. All fixed; second pass
  independently re-derived every new numeric assertion end-to-end (not just
  trusted the write-up) and APPROVEd. One pre-existing, non-blocking
  observation carried forward from that review: `EditState`'s synthesized
  `Codable` doesn't apply field defaults to missing JSON keys — a landmine
  for Phase 3/4 persistence once any `EditState` blob predates a newly added
  field; needs a custom `init(from:)` before persistence is wired up, not
  before then.
- 84 tests total (6 AspectFit + 78 EditPipeline, +7 new Vibrance tests). 1
  commit (color-math + tests + UI together, single reviewed diff).

### Backlog item — Vignette (complete, verified live)
- `Sources/EditEngine/EditState.swift` — `vignetteStrength` (-1...1, default
  0) and `vignetteRadius` (0...1, default 0.5 — non-zero on purpose, since it
  has no effect while strength is 0), both appended after `cropInsetRight`,
  own `// MARK: - Vignette` section.
- `Sources/EditEngine/EditPipeline.swift` — new TRUE FINAL pipeline stage,
  running AFTER `applyCrop` (everything else runs before or inside the
  perceptual sandwich) — center/radius are derived from the CURRENT
  (post-crop) `image.extent`, so the vignette correctly follows a crop
  instead of the original frame (measured on an offset extent: all four crop
  corners darken equally). Uses `CIVignetteEffect` (explicit center + pixel
  radius), not `CIVignette` (an opaque, saturating normalized radius unit) —
  both auto-center correctly on a cropped extent, so this was a control/
  predictability choice, not a centering-bug fix. Applied in SCENE-LINEAR
  light, no perceptual encode/decode wrap (measured: wrapping it crushes
  corners toward black, 0.030 vs linear's graceful 0.130). Asymmetric
  strength→intensity map (darken span 1.0, lighten span 0.25) because the
  filter's negative intensity was measured to brighten ~8x harder than
  positive intensity darkens — kept both slider extremes comparably
  strong-but-graceful. Does not clamp highlight headroom; preserves alpha.
- Reviewer traced the pipeline call order directly (not just the doc
  comment) to confirm `applyVignette` genuinely reads the post-crop extent,
  and confirmed the non-zero `vignetteRadius` default can't violate the
  `EditState.identity` no-op invariant (guard is on `vignetteStrength` only).
  APPROVE on first pass.
- 91 tests total (6 AspectFit + 85 EditPipeline, +7 new Vignette tests). New
  test helpers added: `solidColorImage(r:g:b:a:size:)` and `pixel(of:at:)`
  (arbitrary-coordinate sampler — vignette is the first spatial/radial
  filter, so the existing origin-only `linearPixel(of:)` couldn't show
  falloff). 1 commit (color-math + tests + UI together).

### Crop v2 — interactive drag-handle rectangle (complete, verified live; aspect presets still deferred)
- NEW `Sources/UI/CropOverlayView.swift` — click-and-drag crop rectangle
  overlaid on the full image. 8 handles (4 corners drive their two adjacent
  insets, 4 edge midpoints drive one each) plus dragging the interior to
  translate the whole rect. Presentation-only: reads/writes the SAME
  `EditState.cropInsetTop/Bottom/Left/Right` fields the numeric sliders
  already bind to (four individual `@Binding`s, not the whole `EditState`,
  so it structurally cannot touch any other field) — **zero changes to
  `EditState.swift` or `EditPipeline.swift`**, confirmed by both reviewer
  passes.
- **Crux coordinate-math risk, resolved by direct verification, not
  reasoning**: `cropInsetTop` was confirmed (re-reading
  `testCropTopInsetRemovesTopContent`) to trim the image's VISUAL top. In
  `CIImage`'s own bottom-left/y-up space that's the HIGH-y region; in
  SwiftUI's top-left/y-down point space (where the overlay lives) visual top
  is LOW-y. The two spaces agree on what "visual top" MEANS even though the
  y-VALUE representing it differs — so the on-screen mapping is a direct add
  (`y = fitRect.minY + fitRect.height * top`) with no flip, despite this
  project having shipped two real y-flip bugs before. `AspectFit.rect(fitting:in:)`
  (already used by the renderer) is reused as-is with the SwiftUI container's
  point-size, so the overlay and the Metal view always agree on where the
  image sits on screen.
- **Crop-editing mode** is a local, ephemeral `@State` in `ContentView`
  (deliberately NOT part of `EditState`/the document — it's a UI mode, not an
  edit). While active, a computed `displayEditState` zeroes the crop insets
  only for what's rendered (so the full frame shows with every other edit
  still applied); the overlay itself reads the REAL insets for its rectangle.
  Exits automatically when a new photo loads (`onChange(of: currentFileName)`).
  The four numeric sliders remain and stay in sync for free (both read/write
  the same fields) — no slider removal.
- `Sources/Rendering/MetalImageView.swift` — small equality guard added in
  `updateNSView` (skip `setNeedsDisplay` when `image`/`editState` are
  unchanged) so a crop drag, where `displayEditState` is constant
  frame-to-frame, doesn't re-run the full Core Image pipeline for no reason —
  benefits every slider, not just crop.
- **First reviewer pass was FIX FIRST — one real bug**: dragging the
  rectangle's interior clamped the translation to preserve the
  `left+right`/`top+bottom` sums (preventing inversion) but didn't stop that
  sum from piling onto a single side past the enforced 0.45 max, silently
  desyncing the overlay from what `EditPipeline.applyCrop`'s own independent
  per-side clamp would actually render. Fixed by bounding the interior-drag
  translation to each side's individual headroom under the max; second
  reviewer pass independently re-derived the bound algebraically (checked
  all four cross-inequalities) and APPROVEd. A doc-comment imprecision
  (claimed "visual top is low-y in both spaces" — true only for SwiftUI's
  space) was also caught and corrected in the same pass.
- No new unit tests — confirmed appropriate both times: this is UI/gesture
  code with zero `EditEngine` changes, and `applyCrop`'s existing
  coordinate-direction tests already cover the geometry the overlay drives.
  91 tests still pass unchanged. 1 commit.

### Flip (complete, verified live) — feature 1 of 5 toward the full Photos-style set
- `Sources/EditEngine/EditState.swift` — `flipHorizontal`/`flipVertical`
  (`Bool`, default `false`), own `// MARK: - Flip` section, after `vibrance`
  and before `// MARK: - Crop` (matches pipeline order — flip runs before
  crop).
- `Sources/EditEngine/EditPipeline.swift` — new `applyFlip` stage, inserted
  between the perceptual color sandwich and crop. Mirrors around the
  CURRENT extent's own center (`x ↦ (minX+maxX)-x`, `y ↦ (minY+maxY)-y`),
  not assumed to be at the origin — same discipline `applyCrop` already
  follows. Pure geometry, no color-space/domain questions to measure (unlike
  every color-math feature so far); designed directly rather than via a
  dispatched Plan agent, matching the established precedent for Crop v1.
- Verified via `quadrantImage()` direction proofs (not diagnostic-script
  numbers) — including `testFlipAppliedBeforeCrop`, which asserts specific
  sample points chosen to DISCRIMINATE the correct flip-then-crop order from
  the wrong crop-then-flip order (reviewer independently traced both
  orderings by hand and confirmed the test would fail if the pipeline stages
  were swapped — a real ordering proof, not just isolated-stage coverage).
- Reviewer independently re-derived the `CGAffineTransform.concatenating`
  composition algebra for all three cases (horizontal-only, vertical-only,
  both) and confirmed each matches the claimed centerline-reflection
  formula. APPROVE on first pass.
- 98 tests total (7 new Flip tests). 1 commit.

### Straighten (complete, verified live) — feature 2 of 5
- `Sources/EditEngine/EditState.swift` — `straightenAngle: Double = 0`
  (degrees), own `// MARK: - Straighten` section, after `vibrance` and
  before `// MARK: - Flip` (matches pipeline order — straighten runs before
  flip).
- `Sources/EditEngine/EditPipeline.swift` — new `applyStraighten` stage,
  rotates around the current extent's own center via the standard
  translate-rotate-translate-back recipe. Positive angle rotates
  COUNTERCLOCKWISE — derived from `CGAffineTransform(rotationAngle:)`'s
  standard matrix in `CIImage`'s y-up space, verified (not just derived)
  with an exact-90° test against `quadrantImage`'s known layout. Runs before
  Flip (matches the Photos reference panel order); rotation and reflection
  don't commute in general, so this order is real and pinned by an ordering
  discriminator test, same pattern as Flip's own `testFlipAppliedBeforeCrop`.
  Rotating a rectangle around its own center always yields a bounding box
  centered at that same point (provable by symmetry, pinned by a test) — so
  Flip, running next, still mirrors around the correct center even after
  Straighten grows the extent.
- **Known, documented v1 limitation**: any nonzero angle grows the
  bounding-box extent (except at 0/90/180/270°); the resulting corners
  outside the actual rotated content render black (existing renderer
  background composite) — the standard "rotate reveals corners" behavior.
  No auto-fit-to-inscribed-rectangle; the already-shipped Crop tool removes
  the gaps. Same tradeoff philosophy as curves' headroom clamp.
- **A real measure-vs-derive gap caught by the test run itself**: the pure
  rotated-bounding-box formula predicted a 100×100 image at 30° would grow
  to ≈136.60px; the ACTUAL `xcodebuild test` run measured 138.0px — Core
  Image pads a transformed extent for its resampling kernel, a real
  implementation detail the closed-form geometry doesn't predict. Fixed by
  asserting the measured value (with a supplementary lower-bound assertion
  still anchored to the pure-geometry prediction) rather than the idealized
  one. Reviewer independently reproduced 138.0 via a standalone probe before
  approving — didn't just trust the write-up.
- **A real latent bug in ALREADY-SHIPPED Crop v2 code, caught proactively
  while designing this feature, not after shipping**: the crop overlay's
  `fitRect` was computed from the raw, pre-edit `currentImage.extent.size`.
  Every feature shipped before Straighten happened to preserve extent
  exactly, so this was silently correct by coincidence — Straighten is the
  first to grow the extent, which would have misaligned the overlay during
  crop-editing mode. Fixed in `Sources/UI/ContentView.swift` to compute
  `fitRect` from the actual post-pipeline (crop-zeroed) extent instead.
  Reviewer traced the full call graph (both `MetalImageView`/`ImageRenderer`
  and the overlay's new `EditPipeline.apply` call) and confirmed they're
  provably consistent, and confirmed no eager-rendering performance concern.
  Vertical/Horizontal perspective correction (next feature) will hit the
  same extent-growth issue, so this fix pays forward.
- One non-blocking product-sanity note from the reviewer: the CCW
  convention is mathematically correct/consistent/tested, but some editors
  define a Straighten slider's positive direction as clockwise instead —
  purely a UI-facing convention choice, not a bug, didn't block approval.
- 104 tests total (7 new Straighten tests). APPROVE on first pass. 1 commit.

### Vertical + Horizontal perspective correction (complete, verified live) — feature 3 of 5
- `Sources/EditEngine/EditState.swift` — `verticalPerspective`/
  `horizontalPerspective` (-1...1, default 0), own
  `// MARK: - Perspective (keystone)` section, between `straightenAngle` and
  `// MARK: - Flip` (matches pipeline order).
- `Sources/EditEngine/EditPipeline.swift` — new `applyPerspective` stage,
  between Straighten and Flip. Unlike Flip/Straighten's closed-form affine
  math, this genuinely needed empirical investigation — a Plan agent ran
  real Core Image diagnostics (`scratchpad/perspdiag*.swift`) and determined:
  `CIPerspectiveTransform` (maps the extent's 4 corners to an arbitrary
  output quad), NOT `CIPerspectiveCorrection` (the inverse — rectifies an
  existing quad into a rectangle, measured to change extent to
  `(0,0,100,170)` for the same corners — wrong tool); the corner-name
  convention (`topLeft=(minX,maxY)` etc., matching `CIImage`'s established
  y-up "top=high-y" space, measured via a quadrant identity map); that
  corners moving strictly INWARD preserve the extent EXACTLY (measured
  `output.extent == input.extent`, genuinely different from Straighten's
  measured +1.4px resampling padding); `kMaxPerspectiveShift = 0.25` (the
  combined dual-axis worst case goes non-convex above ~0.34, measured via a
  sweep); and that both axes must be applied as ONE combined filter call,
  not two sequential ones (measured to double-warp shared corners
  otherwise). Runs before Flip (measured non-commuting).
- Reviewer did NOT just trust the design agent's numbers or the fact that
  tests passed — independently re-ran every measured claim with its own
  standalone Core Image diagnostic scripts (corner semantics, extent
  preservation, the 0.25 cap's convexity margin including its own additional
  full sign/magnitude sweep, Flip non-commutativity, hand-traced the
  combined corner math) before approving. APPROVE on first pass.
- 115 tests total (11 new perspective tests, all passed on first run — the
  design agent's measured values held up exactly). 1 commit.

### Grid guideline overlay (complete, verified live) — feature 4, added mid-sequence
- NEW `Sources/UI/GridGuidelineView.swift` — a `GridLines` enum
  (`major(in:)`: rule-of-thirds, 2 lines/direction; `minor(in:subdivisions:)`:
  finer subdivisions, excluding the positions `major` already draws so the
  two paths never overlap) plus `GridGuidelineView`, a non-interactive
  overlay drawing both tiers over the full displayed image.
- Shows only while ACTIVELY DRAGGING Straighten/Vertical/Horizontal (via
  `Slider`'s `onEditingChanged`, wired through a new defaulted parameter on
  `EditSliderRow` so the ~18 other slider call sites in `ContentView.swift`
  are unaffected), appearing on drag start and disappearing on release —
  matches Apple Photos' own behavior. Suppressed while `isCroppingActive`
  (the two `if` conditions are structurally mutually exclusive, both grids
  showing at once is impossible), since `CropOverlayView` already shows its
  own grid.
- `CropOverlayView`'s pre-existing single-tier `thirdsGrid` was refactored
  to call the same shared `GridLines.major`/`.minor` (behavior-preserving
  for the major tier, verified by the reviewer to be pixel-identical to the
  old inline code; the minor tier is a pure addition).
- **User asked mid-review whether the grid should also warp/rotate to
  follow the photo's transformed shape** (a genuinely harder ask — would
  have needed replicating the pipeline's rotation/perspective math, plus an
  approximated bilinear warp, in the UI layer). Before committing to that
  complexity, checked the real Apple Photos app and confirmed the grid
  stays STATIC while the photo rotates/warps underneath it — matching what
  was already built. No geometry work needed; request resolved by
  verification, not extra engineering.
- **Follow-up contrast fix**: user reported the (initially plain white,
  low-opacity) grid lines were hard to see against bright image content.
  Fixed by drawing a dark "shadow" stroke under each white line (both
  tiers, both overlays) — reviewer confirmed the shadow strokes are wider
  than the lines on top (visible halo, not fully occluded) and derived from
  the same deterministic `Path` so they stay pixel-aligned.
- No `EditState`/`EditPipeline` changes, no new unit tests (UI-only, no
  color/geometry math changed) — reviewer confirmed all 115 existing tests
  are the exact pre-existing set, unaffected. 1 commit (grid overlay +
  contrast fix bundled, reviewed together).

### Crop v2 aspect-ratio presets (complete, verified live) — feature 5, done
- NEW `Sources/UI/CropAspectMath.swift` — `CropAspectPreset` enum
  (Original, Freeform, Square, 16:9, 4:5, 5:7, 4:3, 3:5, 3:2, Custom) plus
  pure, SwiftUI-independent geometry: `snappedInsets` (reshapes the crop to
  the largest rect of a target ratio, INSCRIBED and CENTERED within the
  current crop, on preset selection) and `cornerResize` (ratio-preserving
  corner drag, anchored at the opposite corner — the standard editor
  convention). Presentation-layer only — **zero `EditState`/`EditPipeline`
  changes**, confirmed by the reviewer via `git diff --stat`; the final
  crop is still just the same four `cropInset*` fields `applyCrop` already
  consumed before this feature existed.
- Deliberately extracted the math into a plain, non-SwiftUI file so it gets
  real unit test coverage despite living in the UI layer (8 new tests,
  `Tests/EditEngineTests/CropAspectMathTests.swift`) — matching this
  project's standing preference for testing real arithmetic wherever it
  lives, not just in `EditEngine`.
- `Sources/UI/CropOverlayView.swift` — while a ratio is locked, only the 4
  corner handles stay interactive (edge handles hidden, since a single-edge
  drag can't preserve a fixed ratio); corner drags route through
  `cornerResize` instead of the freeform independent-per-axis math, which
  is otherwise completely UNCHANGED (byte-for-byte, confirmed by reviewer)
  when no ratio is locked.
- `Sources/UI/ContentView.swift` — new compact `Menu`-based Aspect picker
  in the sidebar (the full always-expanded vertical list from the
  screenshot is deliberately deferred to the layout redesign, feature 6);
  `.custom` captures the CURRENT crop ratio at selection time (not a
  numeric-entry field — documented v1 scope cut); `.original` resolves to
  the CURRENT displayed frame's ratio (reflects Straighten/Perspective/Flip
  already applied, not the raw file). Also hoisted the crop pane's
  `fitRect` computation (previously duplicated inline in three places) into
  one shared `currentFitRect`, tracked via a new `containerSize` state
  synced from the `GeometryReader`.
- Reviewer independently re-derived the `snappedInsets` and `cornerResize`
  algebra by hand (not just re-running tests) and spot-checked several test
  values for genuine correctness, not just internal self-consistency.
  APPROVE on first pass, with three minor non-blocking notes for a future
  pass: (1) `snappedInsets`'s per-side clamp can desync from the requested
  ratio at extreme mismatches — unreachable via the shipped presets, only
  via a manually-extreme Custom ratio, worth a doc-comment note next time
  this file is touched; (2) `containerSize` refresh via `onAppear`/
  `onChange` introduces a technically-possible one-frame lag vs the
  previous synchronous `proxy.size` read, imperceptible in practice; (3)
  `maxInset = 0.45` is now triplicated across `EditPipeline`/
  `CropOverlayView`/`ContentView` with no compiler-enforced consistency —
  matches this project's existing `kMaxCropInset` duplication precedent, so
  accepted, just flagged.
- **Follow-up visual tweak** (same session, user feedback after trying it
  live): crop handles restyled from plain white circles to Apple-Photos-
  style L-shaped corner brackets + short edge bars (with the same dark-
  shadow-stroke contrast technique already used for the grid guideline).
  Bundled into the same reviewed diff/commit.
- 123 tests total (8 new `CropAspectMath` tests). 1 commit (math + UI +
  handle restyle together, single reviewed diff).

### Layout redesign — dark theme + top tab bar (complete, verified live) — feature 6, LAST of the batch
- Confirmed with the user (AskUserQuestion) before designing: the app
  should be **permanently dark**, not following system appearance —
  simpler (one palette) and matches the reference screenshot exactly.
  `.preferredColorScheme(.dark)` applied at the `HSplitView` root, covering
  the whole window; explicit darker-than-default charcoal backgrounds on
  the sidebar and new tab bar layered on top.
- NEW `Sources/UI/EditorTab.swift` (`.adjust, .filters, .crop, .cleanUp`)
  and `Sources/UI/EditorTabBar.swift` (capsule-pill tab bar, matching the
  screenshot's segmented look) — replaces the flat sidebar + standalone
  Crop/Done toggle. `@State private var selectedTab` REPLACES the old
  `@State private var isCroppingActive`; `isCroppingActive` becomes a
  computed property (`selectedTab == .crop`) so every existing consumer
  (`displayEditState`, the `CropOverlayView` gate) kept working with a
  one-line change each rather than a broad rename.
- Sidebar content now switches per tab: `.adjust` = the existing tone/color
  sliders (Straighten/Vertical/Horizontal/Flip moved OUT, into `.crop`);
  `.crop` = those moved controls + the Aspect list (upgraded from a compact
  `Menu` to the full always-visible vertical list from the screenshot, with
  a checkmark on the selected preset) + the 4 crop insets + a new
  **Reset** button (clears straighten/perspective/flip/crop/aspect back to
  identity); `.filters`/`.cleanUp` = inert placeholder text (selectable, no
  functionality). **"Auto"** (also in the screenshot) was deliberately
  skipped — it would need real auto-straighten/auto-crop detection, which
  doesn't exist in this app; not faked, same policy as the top-right info/
  heart/share/wand icons in the screenshot (none correspond to built
  functionality, none were added).
- **A real architectural consequence, caught while designing, not after
  shipping**: moving Straighten/Vertical/Horizontal into the Crop tab means
  they're now only ever visible while `selectedTab == .crop` — at which
  point `CropOverlayView`'s own grid is already showing. This made the
  separate grid-guideline-while-dragging feature (shipped as its own
  feature earlier in this same batch) **unreachable dead code**. Removed
  entirely — `Sources/UI/GridGuidelineView.swift` deleted, replaced by
  `Sources/UI/GridLines.swift` (keeping only the shared line-drawing math
  `CropOverlayView` still needs) — rather than leaving inert state/code
  around. Reviewer independently traced this and found it's actually a
  **strict improvement**, not a wash: `CropOverlayView`'s grid renders
  unconditionally while the Crop tab is active, not just during an active
  slider drag the way the old guideline did.
- Pure UI/navigation restructuring — no `EditState`/`EditPipeline` changes.
  Reviewer traced every claim in the diff against the actual code rather
  than trusting the diff text (the `isCroppingActive` migration, the
  dead-code-removal argument, the toolbar conditional's compile-and-behave
  correctness, `.preferredColorScheme`'s actual scope) and ran the build/
  test suite itself rather than trusting reported numbers. APPROVE on first
  pass, one non-blocking note (a harmlessly-redundant double `.disabled`
  check on the Reset button).
- 123 tests total, unchanged (no EditEngine touched). 1 commit.

### Black & White (complete, verified live) — backlog item 1 of 9 remaining
- `Sources/EditEngine/EditState.swift` — `blackAndWhite: Bool = false`, own
  `// MARK: - Black & White` section, after `vibrance`.
- `Sources/EditEngine/EditPipeline.swift` — NOT a new filter or pipeline
  stage: a one-line override at the EXISTING `applySaturation` call site
  inside `applyPerceptualAdjustments` — when `blackAndWhite` is true, the
  call is forced to `-1` (factor 0) regardless of `hslSaturation`/
  `vibrance`/`hslHue`'s own values. Reuses a mechanism ALREADY proven
  grayscale by the pre-existing `testSaturationMinusOneIsGrayscale` (not
  new Core Image behavior), so this was designed directly, no empirical
  diagnostics needed for the mechanism itself. Contrast/Highlights/
  Shadows/Black Point/Brilliance's non-saturation nudges all still apply
  normally to a B&W image.
- v1 scope: on/off only, no Intensity/Neutrals/Tone/Grain sliders (Photos'
  fuller B&W panel) — documented scope cut, consistent with every other v1
  feature in this project.
- **First reviewer pass was FIX FIRST — one real doc-comment overclaim**:
  a comment said leaving Hue/Vibrance active before the forced desaturation
  was "moot." Reviewer MEASURED (not assumed) this to be inaccurate: while
  the R=G=B grayscale invariant always holds, the resulting gray VALUE
  shifts by up to ~0.013 depending on Hue/Vibrance (CIColorControls
  computes luminance from whatever RGB is present in the graph at that
  point) — well past the test suite's 0.002 tolerance. Fixed by rewording
  to accurately describe this as an intentional (if incidental)
  color-filter-style luminance mapping — like shooting B&W film through a
  colored filter — not a no-op. Second pass APPROVEd.
- 128 tests total (5 new Black & White tests, all passed on first run — the
  reused-mechanism design meant no new magic numbers to get wrong for most
  of them; two tests use structural assertions (`r==g==b`) rather than
  fabricated exact values where the composed Hue+Vibrance+desaturation
  result wasn't already a known measurement). 1 commit (+1 comment-only
  follow-up fixed before commit, not a separate commit).

### Sharpen (complete, verified live) — backlog item 2 of 9 remaining
- `Sources/EditEngine/EditState.swift` — `sharpness: Double = 0` (0...1,
  one-directional like Vignette Radius/Crop insets, not the bipolar
  -1...1 family), own `// MARK: - Sharpen` section, at the END of
  declaration order (after Vignette, before `static let identity`).
- `Sources/EditEngine/EditPipeline.swift` — new `applySharpen`, the
  pipeline's new TRUE FINAL stage (after Vignette, which was previously
  final) via `CISharpenLuminance`. A genuinely new filter (unlike Black &
  White, which reused already-proven math), so a Plan agent ran real
  empirical diagnostics. **Notable finding**: the textbook claim that
  `CISharpenLuminance` avoids color fringing (vs a naive per-channel
  unsharp mask) does NOT hold in this app's linear working space — measured
  `CISharpenLuminance` and `CIUnsharpMask` to be numerically IDENTICAL on
  both grayscale and color test edges. `CISharpenLuminance` is still the
  right choice, but for its clean single-parameter API, not a fringing
  advantage that doesn't actually exist here. **Also caught and fixed a
  real resolution-dependence problem before it shipped**: the filter's
  `radius` is in absolute pixels — a fixed radius gives an identical
  pixel-halo regardless of image size (measured: same peak on a 400px and
  a 1600px image), meaning it would look wildly different on a 12MP vs
  48MP photo. Fixed via `kSharpenRadiusFraction = 0.0025 * min(extent.width,
  extent.height)`, mirroring how Vignette/Perspective already derive their
  own geometry from `image.extent` rather than fixed constants. Runs in
  the perceptual domain (measured more even edge response than linear);
  does not clamp headroom; preserves alpha; measured to commute with
  Vignette within 0.00100 (so placement between those two specifically
  doesn't matter, but running dead last overall does — after all
  geometric/resampling stages so nothing softens its work afterward).
- v1 scope: single Amount slider only, no Radius/Detail/Masking controls
  — documented scope cut, same pattern as every other v1 feature.
- Reviewer independently re-derived ALL FIVE empirical claims (filter
  equivalence, resolution-scaling, domain choice, headroom/alpha,
  placement/commutativity) from fresh standalone diagnostic scripts, not
  by re-running the shipped tests or trusting the design agent's numbers.
  APPROVE on first pass. One non-blocking nit noted for a future pass: the
  shipped `testSharpenCommutesWithVignette` samples only the image's dead
  center (which happens to be near a no-op for `CIVignetteEffect`) with a
  looser tolerance — a weak discriminator on its own, though the
  underlying claim was independently confirmed true by the reviewer's own
  corner-sampling stress test.
- New test helper `stepEdgeImage(lo:hi:size:alpha:)` — sharpening needs
  real edges to measure (a flat solid shows zero effect); `quadrantImage()`'s
  8-bit device-RGB construction was unsuitable for the required sub-0.002
  precision, so this uses true linear-space compositing instead.
- 135 tests total (7 new Sharpen tests, all passed on first run — the
  design agent's measured values held up exactly). 1 commit.

### Noise Reduction (complete, verified live) — backlog item 3 of 9
- `Sources/EditEngine/EditState.swift` — `noiseReduction: Double = 0` (0...1,
  one-directional, same family as Vignette Radius/Sharpen). Declared BEFORE
  the existing Sharpen field — declaration order deliberately mirrors
  pipeline order, and Noise Reduction runs before Sharpen.
- `Sources/EditEngine/EditPipeline.swift` — new `applyNoiseReduction`,
  inserted between Vignette and Sharpen (the pipeline's "detail" pair,
  standard denoise-then-sharpen order). A genuine new filter, so a Plan
  agent ran real empirical diagnostics rather than reusing proven math.
  **Two notable measured findings**: (1) `CINoiseReduction`'s own
  `inputSharpness` parameter is a re-sharpen that ADDS noise back — at the
  filter's own default (0.4) it raised a flat noisy patch's residual std to
  136% of baseline — so it's explicitly pinned to 0, with only
  `inputNoiseLevel` driven by the slider. (2) UNLIKE Sharpen, whose radius
  needed `extent`-derived scaling (absolute pixels, looked wildly different
  across image sizes), Noise Reduction's `noiseLevel` needed NO resolution
  scaling — measured near-identical residual std and byte-identical edge
  ramps at 400/800/1600px, because noise is inherently per-pixel rather
  than a frame-relative feature like an edge halo. Runs in SCENE-LINEAR
  light (not Sharpen's perceptual sandwich) — measured to denoise evenly
  across tones (24% residual at all three test brightnesses), whereas the
  perceptual domain under-denoises shadows (47%) because the sRGB encode
  lifts shadow noise above the filter's threshold. Does not clamp highlight
  headroom, preserves alpha and extent exactly (measured).
- v1 scope: single Amount slider only — same scope-cut pattern as every
  other v1 feature.
- **Two reviewer passes, both catching/confirming real issues** (not a
  clean first-pass APPROVE like Sharpen): first pass was FIX FIRST — the
  shipped `testNoiseReductionSharpnessPinnedToZero` used `noiseReduction: 0`,
  which short-circuits the pipeline stage's guard before the filter (and its
  sharpness pin) is ever constructed, making the test pass regardless of
  whether the pin exists. Investigated before accepting the reviewer's
  suggested fix at face value (per this project's measure-don't-assume
  discipline): confirmed empirically that a flat SOLID test image can't
  discriminate this at all (nothing for a re-sharpen to act on regardless of
  its parameter), so the test was rewritten to use a moderately-denoised
  NOISY patch instead (slider 0.5, enough residual noise left for an
  un-pinned default sharpness to measurably amplify — verified by
  temporarily removing the pin and confirming the rewritten test fails hard,
  0.05930 vs an expected 0.04378, then restoring it). Second pass: APPROVE,
  independently re-reproduced the same removed-pin failure before signing
  off, confirmed the overlap with the pre-existing `testNoiseReductionReducesFlatNoise`
  is intentional belt-and-suspenders, not blocking.
- New test helpers `noisyGray(base:amp:size:seed:alpha:)` (deterministic
  seeded-LCG per-pixel noise) and `regionStd(_:x:y:w:h:)` (mean/std over a
  pixel region) — noise reduction's effect is a std reduction over an area,
  not a single-pixel value shift, so the existing single-pixel samplers
  couldn't measure it.
- 143 tests total (8 new Noise Reduction tests). 1 commit.

### Definition (Clarity) (complete, verified live) — backlog item 4 of 9
- `Sources/EditEngine/EditState.swift` — `definition: Double = 0` (0...1,
  one-directional), declared after `vignetteRadius`, before `noiseReduction`
  (pipeline order). Local-contrast enhancement — boosts midtone/texture
  contrast at a much wider spatial scale than Sharpen, without Contrast's
  global flatness.
- **The plan's original design intent was a BIPOLAR `-1...1` slider named
  "Clarity"** (positive = punch, negative = soften, the Lightroom
  convention), matching the already-shipped bipolar Contrast/Vignette
  family. Per this project's measure-don't-assume discipline, before
  implementing I ran a real compiled Swift probe (not the planning agent's
  prediction — plan-mode agents can't execute code) against `CIUnsharpMask`
  in this app's exact working space, and found Core Image silently clamps
  NEGATIVE `intensity` to a no-op: at intensity -0.2 through -1.0 on a
  step-edge test image, output was BIT-IDENTICAL to the unfiltered
  baseline (contrast stayed exactly at the 0.3 input value, not even
  subtly reduced). Not a subtle finding — half the intended slider range
  would have done literally nothing. Pivoted the shipped feature to
  one-directional `0...1`, renamed "Definition" to match Apple Photos'
  convention and CLAUDE.md's own "Definition (Clarity)" backlog heading.
  No softening/negative capability ships.
- `Sources/EditEngine/EditPipeline.swift` — new `applyDefinition`, via
  `CIUnsharpMask` — the SAME filter Sharpen uses (already measured
  numerically identical to `CISharpenLuminance`), here at 16x Sharpen's
  radius fraction (`0.04` vs `0.0025`, extent-scaled the same way). Runs
  between Vignette and Noise Reduction. Rejected: `CIHighlightShadowAdjust`
  (measured to be an asymmetric shadow/highlight tone-mapper, not a
  symmetric local-contrast operator — it LIFTS the dark side of a test
  edge). Domain: perceptual sandwich, matching Sharpen — though measured,
  domain barely mattered here (~1% relative difference across tones,
  unlike Sharpen's ~5% or Noise Reduction's ~2x). **Notable measured
  finding**: unlike Sharpen (which commutes with Vignette within 0.00100),
  Definition does NOT cleanly commute with Vignette — measured corner
  differences up to 0.0188 between orderings — so running Definition AFTER
  Vignette is a real, measured requirement, not an arbitrary choice.
- v1 scope: single Amount slider only.
- Reviewer APPROVE on first pass, independently re-verified all six review
  checkpoints (range consistency end-to-end, radius scaling idiom match,
  pipeline placement, the halo-width discriminator test's validity, field
  declaration order, general style/force-unwrap/non-destructive checks).
  One non-blocking gap noted: no dedicated test proves the claimed
  Definition/Vignette non-commutativity the way `testSharpenCommutesWithVignette`
  proves Sharpen's commutativity, or the way Straighten/Flip have explicit
  ordering discriminators. Investigated adding one before committing:
  a real discriminator would need to call `applyDefinition`/`applyVignette`
  directly in both orders, but those are `private` (matching the file's
  encapsulation), and — unlike Straighten/Flip's pure-geometry ordering
  tests, which can be hand-derived analytically — there's no clean
  closed-form way to predict two composed color filters' order-sensitivity
  without actually running both orders. Chose not to weaken encapsulation
  or ship a test that LOOKS rigorous but doesn't actually discriminate;
  left as a tracked, explicitly non-blocking gap rather than faked
  coverage. Revisit if this pattern (a new feature non-commuting with an
  existing stage) recurs — may be worth adding package-internal (not
  private) access to pipeline stages specifically to make ordering tests
  possible, but that's a real API decision, not a one-line addition.
- 151 tests total (8 new Definition tests). 1 commit.

### Levels + live histogram (complete, verified live) — backlog item 5 of 9
- The first Phase 2 feature needing BOTH an `EditPipeline` math investigation
  AND a UI-architecture design in the same session — CLAUDE.md flagged the
  histogram as a genuinely new UI capability, not just more sliders. Two
  Plan agents' worth of work: one investigated the filter math (grounding
  every claim in this repo's own existing measurements, since plan-mode
  agents can't execute code); the histogram data-flow architecture was
  designed directly from reading `ImageRenderer.swift`/
  `ImageDocumentModel.swift`/`MetalImageView.swift` — no filter-math
  uncertainty there, a data-flow decision.
- `Sources/EditEngine/EditState.swift` — `levelsBlackPoint: Double = 0`,
  `levelsWhitePoint: Double = 1`, `levelsGamma: Double = 1`, inserted right
  after `exposureEV`, before `brightness` (Levels runs first in the
  perceptual sandwich). **Naming collision avoided deliberately**: this app
  already has an unrelated `blackPoint` field (the Curves `point0` control,
  -1...1) that shipped earlier — the new fields are named with a
  `levels`-prefix specifically so they can't be confused with it; reviewer
  independently confirmed no collision anywhere in the diff.
- `Sources/EditEngine/EditPipeline.swift` — new `applyLevels`: classic
  Photoshop/Lightroom remap, `CIColorMatrix` (global scale+bias, luminance-
  style not per-channel) → `CIColorClamp` (0...1, BEFORE gamma) →
  `CIGammaAdjust` (`power = 1/gamma`). **Real empirical probe run before any
  constant was set** (same discipline as Sharpen/Noise Reduction/
  Definition): confirmed (1) `power = 1/gamma` gives the correct sign
  convention (gamma>1 brightens, monotonic, verified at several inputs);
  (2) the clamp-before-gamma order genuinely prevents NaN — a below-black-
  point input combined with a fractional gamma power (gamma=3 → power=1/3)
  measured an exact, finite `0.0`, not NaN, both before and after the
  encode/decode round-trip; (3) the degenerate black==white (or inverted
  black>white) case stays finite via `kMinLevelsGap`, just steep; (4) Levels
  does NOT commute with Brightness — a real, measured 0.0119 gap (smaller
  than Brightness/Contrast's own 0.15 gap, but well above this file's 0.002
  test tolerance) — confirming Levels should run FIRST in the sandwich,
  before Brightness, as the corrective base-tone remap prior to "creative"
  adjustments. **A genuinely important correctness finding surfaced by the
  probe**: calling the raw filter chain unconditionally — even at identity
  params (0, 1, 1) — clips headroom anyway, because `CIColorClamp` runs
  regardless of the black/white/gamma values. The `levelsActive` guard
  isn't just a performance optimization here the way it is for most other
  stages; it's what makes "identity" actually mean zero-effect at all.
  Levels intentionally clips highlight headroom once ACTIVE (that's what a
  white point does) — an accepted, documented deviation from the
  headroom-preserving family, same accepted category as active Curves' own
  clamp-to-[0,1].
- 9 new Levels tests, including `testLevelsRunsBeforeBrightness` (pins the
  real pipeline's ordered value and asserts it does NOT match the reversed-
  order value — reviewer independently re-derived both numbers by hand and
  confirmed the 0.01187 delta matches the measured 0.0119 gap almost
  exactly) and `testLevelsNegativeRemapNoNaN` (reviewer manually traced the
  math and confirmed the test genuinely drives a negative value through the
  matrix step before the clamp catches it — not just an assertion that
  happens to pass).
- **Live histogram** — `Sources/Rendering/Histogram.swift`'s new
  `HistogramComputer`: its own independent, non-Metal `CIContext` (NOT
  `ImageRenderer`'s `@MainActor`/Metal-drawable-bound one — this one must be
  safely callable off the main thread), downsamples to 256px, computes a
  256-bin Rec. 709 luminance histogram in DISPLAY sRGB (not this app's
  scene-linear editing space — a histogram represents what a viewer sees,
  matching every real photo editor and `ImageRenderer`'s own final
  `outputColorSpace`). `Sources/UI/ImageDocumentModel.swift` triggers a
  debounced (~150ms `DispatchWorkItem`) background recompute via
  `Task.detached` on every `editState` change, publishing back via
  `MainActor.run` guarded by a monotonic `histogramGeneration` counter
  (chosen over `Task` cancellation, since Task cancellation is only
  cooperative and neither `EditPipeline.apply` nor `HistogramComputer`
  check for it — reviewer verified this race-guard is actually sound given
  `ImageDocumentModel`'s `@MainActor` isolation serializes the
  increment/compare). Satisfies CLAUDE.md's "DB access never blocks main
  thread... background queue" principle, applied for the first time to a
  UI computation rather than DB/thumbnails.
- **What the histogram reflects — a deliberate v1 scope decision**: NOT a
  literal "state before you touch Levels" (would need new `EditPipeline`
  API surface to expose a pre-Levels intermediate). Instead, the full
  pipeline output with the user's OWN not-yet-applied Levels adjustment
  held at identity — stays stable while dragging the Levels sliders
  themselves, correctly updates for every other edit (crop, exposure,
  contrast, etc.), without new pipeline surface.
- `Sources/UI/HistogramView.swift` (new) — a small `Canvas`-based bar chart,
  purely presentational. UI group ("Levels" label + histogram + 3 sliders)
  placed after the existing Black Point row and before Hue, grouping with
  the other Light/tone tools per this app's established panel-grouping
  convention — independent of the pipeline's own execution order.
  `Tests/RenderingTests/HistogramComputerTests.swift` (new, 5 tests) follows
  the established `AspectFitTests.swift` pattern (pure type in
  `Sources/Rendering`, tested in `Tests/RenderingTests`).
- Reviewer APPROVE on first pass — independently re-ran the full build/test
  suite, hand-traced the color math for several tests to confirm they
  weren't placeholders, and reasoned through the concurrency/race-safety of
  the histogram's generation-counter guard rather than trusting the design
  description. Three non-blocking notes, none requiring a fix-first round:
  a doc-comment wording overstatement (fixed immediately, see below — "same
  order as" the 0.15 gap was inaccurate for a 0.0119 gap, reworded to state
  both numbers plainly), a corner-case invariant note (`levelsWhitePoint`
  can be pushed fractionally above 1.0 by `kMinLevelsGap` when
  `levelsBlackPoint` is very close to 1 — still finite/safe, just not
  strictly bounded in that corner), and a latent NaN-propagation gap in
  `levelsGamma`'s clamp shared with how every other numeric field in this
  file already trusts its input (not a regression, not fixed).
- 165 tests total (9 new Levels + 5 new HistogramComputer tests). 2 commits
  (feature + the one wording fix, both before any reviewer re-pass was
  needed since the note was non-blocking).

### WB neutral-gray eyedropper (complete, verified live) — backlog item 6 of 9
- The app's FIRST point-and-click interaction — every prior control was a
  slider or toggle. Architecturally different from every earlier feature:
  `CITemperatureAndTint` (already used by the shipped `applyWhiteBalance`)
  is a full 3×3 chromatic-adaptation matrix with no documented closed-form
  inverse — MEASURED from this repo's own existing test values (a 0.18 gray
  input's per-channel gains at temp=9500 do NOT predict the filter's real
  output on a *different*, non-gray input run through the same transform:
  gray-derived gains predict r≈2.10 on `(1.4,0.5,0.2)`, but the real,
  already-tested value is `1.80724`). So instead of one probe-measured
  constant baked in ahead of time, this needed a live NUMERICAL SEARCH at
  tap-time — the measure-don't-assume discipline taken to its logical
  extreme: the "probe" runs live, once per tap, against the actual sampled
  color, via the real filter.
- `Sources/EditEngine/EditPipeline.swift` — refactored (behavior-preserving,
  confirmed by the pre-existing WB tests passing unmodified) to extract
  `applyWhiteBalance`'s filter construction into an internal `static func
  whiteBalanced(_:temperature:tint:)`, so the new solver calls the EXACT
  same formula (both measured sign inversions intact) rather than a
  duplicate that could drift from it.
- `Sources/EditEngine/WhiteBalanceSolver.swift` (new) — coarse grid (7
  temperature steps × 6 tint steps = 42 evaluations) + one local refine
  pass (10 more), 52 evaluations total, each running the real filter and
  minimizing a brightness-normalized neutrality error. **Real empirical
  probe run before any constant was set** (same discipline as every prior
  feature): confirmed the search converges correctly in direction (warm
  cast → lower temperature, cool → higher, green → positive tint, magenta →
  negative) and that solved parameters, fed back through the real filter on
  the original sample, actually neutralize it. **A real, important
  correctness finding the probe caught**: some strong casts (a saturated
  orange, a saturated magenta) hit the edge of the search's temperature/
  tint bounds WITHOUT actually reaching neutral — the naive design would
  have silently presented a non-neutral result as if it were a clean fix.
  Added a `solvedPartially` outcome (vs `solved`), classified by a
  MEASURED, well-separated error threshold (good cases ~0.00009-0.0009,
  boundary-clamped bad cases ~0.004-0.052 — over 4x higher than the worst
  genuinely-good case). **Batching many search candidates into one
  composited render, to amortize per-call overhead, was measured to be a
  dramatic dead end**: 402ms vs ~15ms for the same 42 candidates via
  separate small renders — Core Image's evaluation cost for a wide
  `composited(over:)` chain scales badly with layer count, the opposite of
  the intended optimization. Real per-call overhead (measured ~0.26ms per
  1×1 render+readback) is what actually dominates cost, not the number of
  separate filter objects. Runs via `Task.detached` (measured: even the
  reduced 52-eval search takes ~13-30ms on real hardware — a real
  main-thread-hitch risk if run synchronously from the tap handler).
- `Sources/Rendering/PixelSampler.swift` (new) — averages a 5×5 pixel
  neighborhood (not a single pixel — more robust against sensor noise/
  compression artifacts), excluding any pixels below an alpha threshold so
  a sample box overlapping a transparent margin (revealed by straighten/
  perspective) isn't diluted by meaningless transparent content.
- `Sources/UI/ImageDocumentModel.swift` — `pickWhiteBalance(normalizedX:
  normalizedY:)` samples from a GEOMETRY-ONLY render (only straighten/
  perspective/flip/crop copied from the real `editState`; every color/tone
  field including WB itself left at identity) rather than the fully-edited
  image: WB is pipeline stage 1, so the RAW front-of-pipeline chromaticity
  is what actually needs to become neutral, and later color stages don't
  commute with WB, so sampling post-those-stages would solve a subtly
  different (wrong) problem. Since color stages don't change extent, this
  still shares `currentFitRect`'s exact coordinate space — no geometric-
  transform inversion needed. Uses the same y-flip convention already
  established and tested elsewhere in this codebase (`quadrantImage`'s
  "high-y = visual top" contract).
- `Sources/UI/ContentView.swift` — new "Pick White Balance" button (SF
  Symbol `eyedropper`), a tap-capture overlay gated `isPickingWhiteBalance
  && !isCroppingActive` (mutually exclusive with `CropOverlayView`'s own
  gestures BY CONSTRUCTION, not just convention, since each overlay only
  exists under its own tab's condition), disarmed on tab change/new photo/
  after a successful tap, and an alert for rejection feedback (too dark, or
  couldn't fully correct).
- **Two reviewer passes**: first pass FIX FIRST — three force-unwraps in
  production code (`CGColorSpace(name:...)!` in two files, `CIColor(...)!`
  inside the solver's hot search loop, run 52× per tap), a real violation
  of CLAUDE.md's "no force-unwraps outside tests" and this codebase's own
  established `Histogram.swift` precedent (a safe `??` fallback) for the
  identical situation. Fixed by matching that precedent for the two
  `CGColorSpace` sites, and — for the `CIColor` site — restructuring so the
  sample image is built ONCE per tap (via a `guard let`, not force-unwrap)
  rather than rebuilt on every one of the 52 search evaluations, which also
  incidentally removed 52x redundant identical work per tap as a side
  benefit of the correctness fix. Second pass: APPROVE, independently
  confirmed all three sites were actually gone (not just moved), and that
  the restructuring was output-preserving (all 10 solver tests still pin
  the identical numeric expectations).
- 181 tests total (10 new WhiteBalanceSolverTests + 6 new PixelSamplerTests).
  2 commits (feature, force-unwrap fix folded into the same commit before
  the second review pass rather than committed separately, since the first
  commit hadn't landed yet).

### Selective Color (HSL v2, per-band panel) (complete, verified live) — backlog item 7 of 9
- **The highest-risk feature shipped this session.** 8 fixed hue bands
  (Red/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta) × Hue/Saturation/
  Luminance (24 params) + a shared Range falloff-width parameter — this
  app's own name for what CLAUDE.md's backlog calls "HSL v2." The FIRST
  custom Core Image kernel in this codebase's history: no built-in filter
  exposes per-pixel hue, and no composition of built-in filters can produce
  a smooth 8-band mask without one. `CIColorCube` was investigated and
  rejected (clamps highlight headroom unconditionally, RGB-space trilinear
  interpolation mistracks hue near low-saturation nodes, needs CPU LUT
  recomputation on every slider drag). New `Sources/Rendering/Shaders/`
  directory — CLAUDE.md's Conventions section had already reserved this
  path and named the exact use case ("custom kernels for curves, HSL, WB")
  long before any kernel existed; this is the first time it was used.
- **Kernel math** (`SelectiveColor.cikernel`): RGB↔HSL round-trip, a
  raised-cosine falloff over the CIRCULAR hue distance from each band
  center (handles 350°/10° wraparound correctly), band weight scaled by
  the pixel's own saturation (an achromatic pixel has no real hue and must
  not register as belonging to any band — MEASURED necessity, not a
  nicety: without it, every gray pixel's undefined-hue fallback happened
  to coincide with the Red band's center, silently giving every gray pixel
  spurious full Red-band weight). Unnormalized weighted sum across bands
  (not divided by total weight) — what makes all-24-params-zero an exact
  identity and gives adjacent-band blending its natural additive feel.
- **Empirical discipline taken further than any prior feature**: a real
  compiled `CIColorKernel(source:)` was built and executed via a
  standalone probe BEFORE any project file was written — not just
  verifying parameters like every prior feature, but verifying the kernel
  compiles and runs AT ALL, since kernel-language bugs are a risk category
  nothing else in this codebase has faced. That first probe run caught a
  real bug before it ever reached the codebase: an early design's
  undefined-hue-defaults-to-red flaw (above), fixed by the saturation-
  weighting before a single line of Swift was written.
- **A second, more serious bug — caught by the reviewer, not the
  pre-implementation probe.** The standard HSL saturation formula's
  denominator (`1 - abs(2L-1)`) goes NEGATIVE once perceptual lightness
  exceeds 1.0 — for any COLORED pixel with real headroom (e.g. a saturated
  highlight after a modest positive Exposure), this made every band's
  weight negative, which tripped the SAME "not in any band" passthrough
  guard meant only for genuinely untouched pixels. Net effect: Selective
  Color was a complete, silent no-op on any sufficiently bright colored
  image region — skies, boosted highlights, anything with headroom on
  saturated content — regardless of which slider was moved. The original
  pre-implementation probe didn't catch this because its own headroom test
  used an ACHROMATIC pixel (which sidesteps the bug via the `C==0` short
  circuit) — a real reminder that a probe only proves what it actually
  tests, not everything "similar." Fixed by normalizing the pixel's own
  brightness (by its own max channel) before the HSL round-trip and
  rescaling the result afterward — verified via a fresh standalone probe
  before touching the kernel file, confirming both the fix (a colored
  headroom pixel now IS correctly affected) and that literally every
  previously-verified case at normal brightness stays byte-identical
  (`scale` is an exact no-op multiply/divide whenever the pixel's max
  channel is ≤1.0). A genuine improvement fell out of the fix too: a
  colored pixel genuinely inside an active band now keeps its OWN
  headroom while still being correctly color-processed, rather than being
  destructively clamped to flat white the way the original (buggy) design
  did — better than either the bug or the original band-aid.
- `EditState.swift` — 24 flat named band fields + `selectiveColorRange`,
  NOT an array/dictionary: a deliberate recommendation (not a default),
  consistent with this codebase's established per-slider convention even
  at this scale (crop's 4 insets are 4 separate named fields, not a
  struct) — preserves the memberwise initializer, trivial `Codable`/
  identity semantics, and per-slider key-path binding every other feature
  already relies on.
- `Sources/UI/SelectiveColorBand.swift` (new) + `ContentView.swift` — a
  horizontal row of 8 tappable color swatches (not a new top-level
  `EditorTab`, which is explicitly fixed to mirror Apple Photos' own tab
  bar; Photos itself doesn't give this a separate top-level tab either),
  one shared Range slider, then 3 sliders for whichever band is currently
  selected — routed via a small per-band `Binding<Double>` dispatcher
  function, not 24 simultaneous rows.
- **Two reviewer passes** — the most thorough review this session, matching
  the feature's stakes. First pass: FIX FIRST on the headroom-negative-
  denominator bug above (a real, systematic functional gap, not a narrow
  corner case) plus two minor nits (a stale test-name cross-reference in a
  comment, PROGRESS.md not yet updated — expected at that stage). Fixed,
  re-verified via a fresh probe, one test renamed with new (better) expected
  values, one new regression-guard test added reproducing the reviewer's
  own bug repro. Second pass: APPROVE, independently re-derived the fix's
  correctness via a from-scratch reimplementation of the kernel math (not
  just re-reading the diff), confirmed the regression test would genuinely
  have failed against the old kernel, and caught one more residual doc-
  comment nit (two other places still said "headroom-clamping," stale
  after the fix changed that exact behavior) — fixed before commit.
- 193 tests total (12 new Selective Color tests, including the one renamed
  regression guard). 2 commits (the headroom-negative-denominator fix and
  the residual doc-comment cleanup were both folded into the single
  feature commit, since neither had landed separately before the second
  review pass completed).

### Red-Eye removal (complete, verified live) — backlog item 8 of 9
- The app's SECOND point-and-click interaction (after the WB eyedropper),
  and the FIRST feature needing a variable-length, user-placed collection
  in `EditState` — every prior adjustment, including Selective Color's 24
  fixed-band fields, is a fixed set of named fields; red-eye spots are
  inherently unbounded (0 to N per photo, wherever the user taps), so a new
  `redEyePoints: [RedEyePoint]` array is a deliberate, justified departure
  from the flat-field convention, not an inconsistency with it.
- **Notably did NOT need a custom kernel**, unlike Selective Color — a
  genuine, useful contrast the Plan agent investigated and confirmed:
  "soft circular mask + suppress-red + darken" decomposes cleanly into
  built-in filters (`CIRadialGradient` for an arbitrarily-centered soft
  mask — `CIVignetteEffect` can't do this, it's pinned to the frame's own
  center; `CIColorMatrix` for the red-suppress/darken transform in one
  multiply; `CIBlendWithMask` to composite), because unlike Selective
  Color this needs neither per-pixel hue detection nor a dynamic-length
  kernel argument list.
- **Multiple points — a real design decision, not an afterthought.**
  Combined into ONE union mask via `CIMaximumCompositing` before the color
  transform runs ONCE, rather than compositing N sequential single-point
  corrections. MEASURED, a real and substantial difference: on two
  overlapping correction circles, sequential double-application measurably
  OVER-corrected the overlap region (red channel down to 0.061) versus the
  union mask's single-pass result (0.191, close to a lone circle's own
  reference value of 0.240) — the union approach is what makes an
  overlapping-points correction apply exactly once, not twice. This is the
  test (`testRedEyeOverlappingPointsCorrectOnce`) that actually proves the
  design decision, not just documents it.
- **Real empirical probe run before any code was written** (same
  discipline as every prior feature): confirmed `CIRadialGradient`'s
  falloff is smooth and monotonic (no ring/banding), `CIMaximumCompositing`
  correctly unions two masks (not additive), the darken coefficient (0.4)
  reads as a natural dark pupil rather than crushed black or still visibly
  red, scene-linear domain gives a clean result (no crushing, matching
  Vignette's own domain reasoning), and — genuinely useful, not just
  confirmatory — that Red-Eye commutes EXACTLY with Vignette (measured at
  both a frame-center and frame-corner correction point, diff ≈ 0), so
  their relative pipeline order is a soft choice, while running before
  Definition/Noise Reduction/Sharpen is the real requirement (those must
  refine the corrected pupil, not an uncorrected red one).
- `EditPipeline.swift` — new stage, FIRST among the post-crop stages
  (`crop → applyRedEye → vignette → definition → noiseReduction → sharpen`):
  needs the CURRENT (post-crop) extent to map stored normalized points
  correctly, the same requirement Vignette already established. Preserves
  headroom exactly on pixels OUTSIDE every point's mask (a 1.4 pixel far
  from any point reads back 1.4) — pixels INSIDE an active mask are, by
  design, reduced toward a dark corrected value, which IS the feature, not
  a headroom bug the way an unrelated slider crushing a bright pixel would
  be. Alpha and extent preserved exactly.
- `Sources/UI/RedEyeOverlayView.swift` (new) — mirrors `CropOverlayView`'s
  structure (an `fitRect`-sized/positioned container, children in its own
  local coordinate space) more than the WB eyedropper's one-shot tap
  capture, since this needs PERSISTENT markers for every placed point.
  Reuses the exact same y-flip convention `ImageDocumentModel.
  pickWhiteBalance` already established for point capture — the flip
  happens exactly once, at the pipeline boundary, not duplicated in the UI
  layer (traced by hand and independently confirmed by review). Tap adds a
  point; tapping near an existing marker removes it instead — the hit-test
  decision extracted into `Sources/UI/RedEyeHitTest.swift`, a pure,
  directly testable function, matching the established `CropAspectMath`
  precedent for UI-adjacent geometry math worth unit-testing despite
  living in the UI layer. Shared Size/Strength sliders apply to every
  placed point at once (no per-point sliders — v1 scope, matching this
  app's established scope-cut pattern); Strength defaults to a non-zero
  0.7 (not the usual 0-identity) so placing a point immediately produces a
  visible correction without a required second slider step.
- Mutual exclusivity: the three point-interaction modes (Crop, WB
  eyedropper, Red-Eye placement) can only ever have one armed at a time —
  each mode's button explicitly clears the other on arm (not just relying
  on overlay-gating to hide an inactive one), so disarming one mode can
  never silently resurrect another that was left armed in the background.
- Reviewer APPROVE on first pass — independently re-verified the union-
  mask implementation shape (not just trusting the doc comment), hand-
  traced the full y-flip coordinate round-trip across all three touched
  files, confirmed the mutual-exclusivity clearing happens on arm (not
  disarm) so no stale-armed-state bug is possible, and re-derived the
  `CIColorMatrix` arithmetic by hand to confirm the pinned test values are
  real, not placeholders. No issues found, nothing to fix.
- 210 tests total (11 new Red-Eye pipeline tests + 6 new
  `RedEyeHitTestTests`). 1 commit.

### Cast — color-cast neutralization (complete, verified live) — backlog item 9 of 9, FINAL Phase 2 item
- Turned out LOWER risk than several preceding features despite CLAUDE.md
  describing it as needing "a different architecture from every other
  adjustment": it reuses `WhiteBalanceSolver.solve(sampleLinearRGB:)` (the
  WB eyedropper's already-tested numerical search) and
  `ImageDocumentModel.pickWhiteBalance`'s own structural template almost
  unchanged — the only genuinely new piece is HOW to compute a robust
  whole-image "gray world" average color to feed the solver. **No new
  `EditState` fields and no new `EditPipeline` stage** — Cast, like the WB
  eyedropper, is a new UI-driven way to set the SAME
  `whiteBalanceTemperature`/`whiteBalanceTint` fields, not a new adjustment.
- `Sources/Rendering/ImageAverageColor.swift` (new) — mirrors
  `HistogramComputer`'s structure (own independent, non-Metal `CIContext`,
  downsample to 256px before analyzing — reused, not re-derived) but
  computes a MEAN in SCENE-LINEAR light (`extendedLinearSRGB`/`RGBAf`,
  matching `WhiteBalanceSolver`/`PixelSampler`'s domain), not a histogram in
  display space — a deliberate domain divergence from the file it's
  structurally modeled on. Excludes `alpha < 0.5` pixels (same reasoning
  `PixelSampler` already established for a sample region overlapping a
  transparent margin).
- **Real compiled probe run before any project file was written** (same
  discipline as every prior feature): built a synthetic 4-quadrant
  multi-color scene (not flat — genuinely exercises whole-image averaging),
  confirmed the gray-world approach actually recovers an injected synthetic
  cast end-to-end (solved correction reapplied to the cast scene tightened
  its color spread to 0.0275, even tighter than the original uncast scene's
  own 0.0375); confirmed 256px downsampling is EXACTLY lossless for this
  statistic (diff = 0.0 vs full-resolution on the test scene, not just
  "close enough"); and — the plan's own explicitly open question — measured
  that LUMA-OUTLIER CLIPPING matters: a scene with a blown-out quadrant
  skewed a plain mean measurably away from the true base tone
  ((0.625,0.610,0.587) vs correct (0.5,0.48,0.45)) and solved a meaningfully
  different (250K off) correction, while excluding near-black/near-white
  pixels (linear luma outside 0.05...0.95) recovered the true base tone
  almost exactly. Shipped WITH outlier clipping as a result.
- `Sources/UI/ImageDocumentModel.swift` — new `fixColorCast()`, structurally
  mirroring `pickWhiteBalance` (same geometry-only sampling render — WB is
  pipeline stage 1, so the raw front-of-pipeline chromaticity is what needs
  to average to neutral; same `WhiteBalanceSolver.solve` → three-way
  `Outcome` switch, reusing the existing `whiteBalanceSampleMessage` alert)
  but whole-image rather than point-tap driven — no coordinate/tap needed.
- `Sources/UI/ContentView.swift` — a single "Fix Color Cast" button
  (`wand.and.rays`, disabled with no image loaded) next to the existing
  "Pick White Balance" button — the simplest UI addition in the whole
  backlog: no armed mode, no overlay, no gesture, no mutual-exclusivity
  wiring needed (unlike the WB eyedropper/Red-Eye/Crop point-interaction
  trio).
- **First reviewer pass was FIX FIRST — one real concurrency bug**:
  `fixColorCast()` initially called `EditPipeline.apply(...)` and
  `ImageAverageColor.compute(of:)` synchronously on the main actor before
  entering `Task.detached` — copied `pickWhiteBalance`'s shape without
  noticing this analysis is a full 256px render + 65k-pixel CPU scan (the
  same cost profile `recomputeHistogram` already backgrounds for
  `HistogramComputer`), not `pickWhiteBalance`'s trivial 5×5-pixel sample.
  Fixed by moving both calls inside the detached task, with the `nil`-sample
  early-return hopping back to `MainActor.run` rather than returning
  synchronously on the main actor. Second pass independently verified the
  capture semantics (value-type `EditState`/`CIImage`, non-`MainActor`
  `EditPipeline`/`ImageAverageColor`) are sound, re-ran build (Swift 6
  strict concurrency, no Sendable diagnostics) and the full test suite, and
  APPROVEd.
- `Tests/RenderingTests/ImageAverageColorTests.swift` (new, 6 tests) —
  mirrors `HistogramComputerTests`/`PixelSamplerTests` style: solid image
  averages to itself, two-region image averages to the weighted mean,
  alpha-excluded pixels don't dilute, a blown-out outlier region doesn't
  skew the average (the luma-clipping behavior specifically), zero-extent
  returns `nil`, offset extent doesn't crash. No new `WhiteBalanceSolver`
  tests needed — untouched, already covered.
- 216 tests total (6 new `ImageAverageColorTests`). 1 commit (feature +
  the FIX FIRST concurrency correction, both folded into the single
  reviewed/approved diff before commit).
- **This closes out Phase 2 entirely** (modulo Undo/Revert, which stays
  explicitly deferred pending the user asking again, per their own earlier
  instruction).

### Undo/Redo — in-memory edit history (complete, verified) — Phase 3, first slice
- User was asked to choose between the small "Revert to Original" button and
  full Phase 3 Undo/Redo once Phase 2 closed out; chose full Undo/Redo. Two
  design questions confirmed up front: (1) granularity — time-coalesced
  bursts (group rapid changes into one undo step, ~350ms pause starts a new
  one) over one-step-per-intermediate-value (would make ⌘Z nudge a slider
  back one hair per press — unusable); (2) scope — in-memory history now,
  disk persistence deferred (targets the Phase 4 catalog DB, which doesn't
  exist yet — `Sources/Catalog/` is still an empty `.gitkeep`).
- `Sources/EditEngine/EditHistory.swift` (new) — a pure value struct:
  `current: EditState` + `past`/`future: [EditState]` stacks, `limit`
  (default 100, bounds memory — `redEyePoints` is the only unbounded
  `EditState` field), `canUndo`/`canRedo`, `commit`/`undo`/`redo`. `commit`
  no-ops if the new value equals `current` (via `EditState`'s existing
  `Equatable` — prevents a burst that nets no real change, e.g. a slider
  dragged back to its start, from creating a phantom step) and clears
  `future` (standard undo-stack semantics — a new edit after an undo
  abandons the redone-from branch). No timing, no UI, no Core Image —
  matches this project's strong precedent of extracting real logic into a
  pure, directly testable type (`CropAspectMath`, `RedEyeHitTest`).
- `Sources/UI/ImageDocumentModel.swift` — the coalescing glue, hung entirely
  off `editState`'s EXISTING `didSet` chokepoint, needing **zero changes to
  the ~40 slider/toggle/overlay call sites** across `ContentView`/
  `CropOverlayView`/`RedEyeOverlayView`. A new `recordEditChange()`
  (re)schedules a debounced `finalizePendingCommit()` (0.35s, same
  `DispatchWorkItem` idiom as the histogram's own 0.15s debounce, just a
  different interval and purpose) unless a new `isApplyingHistoryChange`
  guard flag is set — set only while `applyHistoryState(_:)` (the undo/
  redo-driven write) is assigning `editState`, so undo/redo's own write
  isn't re-recorded as a new burst. `undo()`/`redo()` each flush any
  in-progress burst first (so ⌘Z mid-drag undoes the drag itself, not some
  older step) before stepping `history`. `load(from:)` resets history via a
  new `resetHistory()` right after resetting `editState` — history is
  per-photo, can't undo across photos.
- **Reviewer verified, not just trusted, the one genuinely order-sensitive
  piece**: in `load(from:)`, `editState = EditState()` must run BEFORE
  `resetHistory()`, not after — reviewer traced that the reversed order
  would seed the fresh `EditHistory` with the PREVIOUS photo's values as
  `current`, making the subsequent reset look like a real one-step edit and
  committing a bogus "old-photo-values → identity" undo step into the new
  photo's history. The shipped order avoids this; confirmed correct, not
  assumed. Reviewer also traced (not assumed) that the existing async WB
  eyedropper/Color Cast `MainActor.run` writes are automatically coalesced
  by the same debounce path with no special-casing needed — both fields'
  writes happen synchronously back-to-back before the 0.35s debounce can
  fire, so they settle into one commit like a fast slider burst.
- `Sources/UI/ContentView.swift` — two toolbar buttons (Undo/Redo,
  `arrow.uturn.backward`/`arrow.uturn.forward`) next to "Open…",
  `.keyboardShortcut("z", modifiers: .command)` / `[.command, .shift]`,
  each `.disabled` when its `canUndo`/`canRedo` flag is false. Documented v1
  scope choice: no Edit-menu `CommandGroup(replacing: .undoRedo)` (would need
  lifting `@StateObject document` to `PhotoAppApp` — a real API change, not
  needed for functional undo) — toolbar + shortcuts are sufficient for now.
- Reviewer APPROVE on first pass — independently traced the `EditHistory`
  push/pop/limit-eviction logic by hand (not just re-running tests),
  confirmed the reentrancy guard is watertight (no code path re-enters
  `editState`'s setter from inside its own `didSet`), and confirmed every
  `history`-mutating call site correctly refreshes the published
  `canUndo`/`canRedo` flags. One non-blocking observation, not required to
  fix: the toolbar's global `⌘Z` shortcut may intercept text-field-native
  undo (e.g. while typing in a crop-inset numeric field) rather than
  deferring to the responder chain first — flagged for a manual check next
  time there's GUI access, not a correctness issue for edit history itself.
- 9 new `EditHistoryTests` (fresh-history flags, commit+undo, redo, no-op
  commit of the current value, new-commit-after-undo clears redo, undo/redo
  on empty stacks, a deep multi-step sequence, `limit` eviction). Debounce
  timing and toolbar/shortcut wiring are UX "feel" concerns, not measurable
  filter values, so they got manual verification instead of a probe: app
  launched via `open` and confirmed to stay running with the new toolbar
  items present (this environment has no GUI automation tool for a native
  macOS app, so full interactive drag-coalescing verification — confirming
  a real slider drag becomes exactly one undo step — is flagged as an
  OUTSTANDING manual check for the user, not yet done).
- 225 tests total (9 new `EditHistoryTests`). 1 commit.
- **Disk/DB persistence of edit state or history remains explicitly
  deferred** (Phase 4 catalog dependency) — this slice is in-memory only,
  consistent with the scope confirmed before starting.

### Sidebar top-padding bug fix (complete, verified live) — found during Undo/Redo manual verification
- User began the outstanding manual GUI verification (see below) and
  reported (with a screenshot) that the sidebar's first slider row
  ("Brilliance") sat flush against the window toolbar (Open/Undo/Redo
  buttons), with no visual gap — unlike the image pane, which gets natural
  clearance below the toolbar from its own `EditorTabBar` row.
- `Sources/UI/ContentView.swift`'s `editControls` — the sidebar's `ScrollView`
  content had a single `.padding()` (16pt all sides). Split into
  `.padding(.horizontal)` + `.padding(.bottom)` (byte-for-byte unchanged from
  before) plus a new, larger explicit `.padding(.top, 20)` for clearance.
  Pure SwiftUI layout change, no `EditState`/`EditPipeline` touched.
- User confirmed live in the running app that this fixes the crowding.
  Reviewer APPROVE (quick pass, appropriate for a low-risk one-hunk padding
  change — confirmed the horizontal/bottom split doesn't double or drop
  spacing on any edge). 225 tests unchanged (no logic touched). 1 commit.
- Also reported during this same round, NOT yet acted on: (1) the Levels
  histogram shows luminance only, no per-channel RGB — confirmed not a bug,
  a v1 scope decision; user picked this as the NEXT feature to plan
  (see "Exact next step"); (2) request to reorganize the sidebar into
  Apple-Photos-style labeled sections (Light/Color/B&W/etc, vs. today's flat
  slider list) — confirmed not yet built, explicitly deferred (not picked
  as next) pending the user asking again.

### RGB channel histograms (complete, verified live) + two more sidebar bug fixes
- Planned feature: user picked adding per-channel Red/Green/Blue histogram
  overlays to the existing Levels luminance histogram (over the deferred
  sidebar-regrouping alternative). Two design choices confirmed with the
  user before planning: (1) overlaid additive-color blending (Photos/
  Lightroom-style — overlapping channels visually mix, e.g. red+green reads
  yellow) over four separate small strips; (2) each channel normalized
  independently to its own peak (tallest bin = 1.0) over one shared global
  scale.
- `Sources/Rendering/Histogram.swift` — `HistogramComputer.histogram(of:)`
  changed from returning `[Float]` (luminance only) to a new `HistogramData`
  struct (`luminance`/`red`/`green`/`blue`, plus `.empty`). Reuses the EXACT
  same downsample+render pass (256px target, display-sRGB, `.RGBA8`) — no
  new render pass needed, since the R/G/B bytes were already being read to
  derive luminance and were simply discarded before. Each channel's raw
  8-bit byte value IS its own bin index directly (no weighting math needed,
  unlike luminance's Rec.709-weighted sum, which is unchanged). Each of the
  four arrays normalized independently via a new shared `normalized()` helper.
- `Sources/UI/HistogramView.swift` — takes `data: HistogramData` +
  `showChannels: Bool`. Luminance drawn first as the unchanged gray base
  layer (normal compositing); if `showChannels`, `context.blendMode =
  .plusLighter` is set before drawing translucent Red/Green/Blue bar areas
  on top — real additive color mixing via the Canvas compositor itself, not
  a manually computed blend.
- `Sources/UI/HistogramDisplayMode.swift` (new) — small presentation-only
  enum (Luminance/RGB), mirrors the existing `SelectiveColorBand` transient-
  `@State` pattern; not stored in `EditState`. New segmented `Picker` above
  the histogram in `ContentView.swift`; defaults to Luminance (matches the
  histogram's original look).
- `Sources/UI/ImageDocumentModel.swift` — `histogramBins: [Float]` renamed
  to `histogramData: HistogramData`; the debounced/generation-guarded
  background-render flow in `recomputeHistogram()` is otherwise unchanged.
- New `testChannelsTrackTheirOwnColorIndependently` test — a solid image
  with distinctly different r/g/b values (0.9/0.5/0.1), asserting the three
  channels' peak bins are ordered `red > green > blue`. Reviewer walked
  through several plausible bugs this would need to catch (all-three-
  collapsed-to-luminance, channel-index swaps, byte-offset errors) and
  confirmed each would fail this assertion — a genuine discriminator, not
  just plumbing coverage. Existing `HistogramComputerTests` extended to
  check all four arrays instead of one.
- **Two more sidebar layout bugs found and fixed live during this same
  verification round** (both from the SAME user-facing symptom — "the
  sidebar's top row crowds the toolbar" — that turned out to have TWO
  independent causes, found and fixed one at a time via direct live
  testing, not guessed):
  - **Bug A (top clearance)**: the earlier round's guessed `.padding(.top,
    20)` (see previous section) undershot once tested against a real photo
    with the fuller Adjust-tab content — a whole row ("Temperature") was
    still hidden under the toolbar. Root cause: both `HSplitView` panes
    start at the SAME native y-offset below the window's toolbar chrome
    (that chrome is outside the SwiftUI view hierarchy, applied uniformly
    across the whole window) — the image pane's content only sits lower
    because `EditorTabBar` is prepended above it. Fixed by MEASURING
    `EditorTabBar`'s real rendered height live via `.onGeometryChange`
    (into a new `tabBarHeight` state) instead of guessing a constant, and
    using that measured value as the sidebar's top padding.
  - **Bug B (scroll position) — a completely different bug that LOOKED
    like the same symptom**: even after Bug A's fix, "Temperature" was
    still not visible on open. Diagnosed via a direct, targeted live test
    (asked the user to scroll the sidebar up and check whether a hidden row
    appeared above the visible top one) — confirmed: the `ScrollView` was
    starting scrolled one row past the top on appear; "Temperature" was
    correctly laid out with correct padding, just not visible until
    scrolled up manually. Not a padding/spacing problem at all. Fixed with
    `.defaultScrollAnchor(.top)`, pinning the initial scroll position
    explicitly (macOS 14+ API, matches this project's deployment target).
  - **A third, separate cosmetic issue was found and NOT fixed, logged as
    known/deferred**: the `HSplitView` divider between the image pane and
    sidebar shifts by a small amount specifically when a photo is opened
    (confirmed via direct testing to be the DIVIDER moving, not the whole
    window). User confirmed the shift is minor/low-priority and explicitly
    asked to defer rather than risk a bigger structural change (replacing
    the native resizable `HSplitView` divider with a custom state-controlled
    one) for a few-pixel cosmetic drift. Revisit only if the user asks again
    or it turns out to be more disruptive than initially assessed.
- Reviewer APPROVE on first pass for the whole bundled diff (histogram
  feature + both fixed sidebar bugs, reviewed together since they came from
  the same live-verification session) — independently confirmed the binning
  math (raw 8-bit byte as direct bin index for R/G/B vs. luminance's
  weighted-sum-then-clamp, unchanged), the `.empty` contract holds through
  the zero-extent guard, the new channel-independence test genuinely
  discriminates, and `.onGeometryChange`/`.defaultScrollAnchor` are used
  safely (no layout feedback loop, correct API for the deployment target).
  One non-blocking observation: `tabBarHeight`'s initial fallback default
  (44) could cause a one-frame padding pop before the real measurement
  lands — cosmetic only.
- 226 tests total (1 new `HistogramComputerTests` test; the rest updated in
  place for the new return type, not net-new). 1 commit (feature + both
  bug fixes together, matching this session's established pattern of
  bundling same-session fixes into one reviewed diff).

### Sidebar content-shift-on-scroll bug + HSplitView divider drift — divider drift FIXED, content-shift attempted then REVERTED (critical regression)
- User asked to revisit the `HSplitView` divider drift previously logged as
  low-priority/deferred. Live investigation (many rounds of build → relaunch
  → user tests → report back, the established pattern for UI bugs this
  session) revealed it was actually TWO separate, unrelated bugs conflated
  under one symptom description:
  1. **Divider drift on first photo load — FIXED, shipped, still in place.**
     The ACTUAL divider position issue originally deferred. Root cause:
     `MetalImageView`'s underlying `MTKView` wasn't opting out of intrinsic
     content sizing, so `HSplitView` could pick up a content-dependent
     sizing signal from it the FIRST time it had a real drawable/texture,
     differing from its signal while empty — a one-time settling event
     (never recurs after the first photo). Fixed by overriding
     `intrinsicContentSize` on `ResizingMTKView` to always report
     `NSView.noIntrinsicMetric` on both axes — the view's layout is now
     governed purely by its SwiftUI-provided frame, never by content. This
     part of the fix is SOUND and remains shipped.
  2. **A completely different bug, initially mistaken for the same thing —
     attempted, then REVERTED after a critical regression.** Sidebar
     CONTENT (not the divider) shifting left by a few points, specifically
     the first time the user actually SCROLLS the sidebar (not on
     photo-open at all — that red herring cost several rounds before the
     user pinned down the real trigger via direct testing).
- **The content-shift bug's diagnosis was genuinely hard-won** — five
  different plausible-sounding fixes were tried and FAILED before finding
  the apparent root cause: matching padding to measured tab-bar height,
  forcing `.frame(maxWidth: .infinity)`, hiding scroll indicators, and a
  first one-time `scrollerStyle = .overlay` attempt. A temporary
  `.onGeometryChange`/file-logging diagnostic (writing into the sandboxed
  app's own container via `NSTemporaryDirectory()`, since a path outside it
  silently fails) eventually caught `NSScrollView.scrollerStyle`
  MOMENTARILY REVERTING to `.legacy` DURING an active scroll gesture, even
  after being explicitly set to `.overlay` at view creation — AppKit's
  `automaticallyAdjustsContentInsets`/`scrollerStyle` get lazily
  RE-ASSERTED mid-scroll, not just once at initial layout.
- **The fix based on that diagnosis (`StableScrollInsets`, an
  `NSViewRepresentable` continuously re-applying zero content insets +
  `.overlay` scroller style on every scroll event) passed TWO full reviewer
  passes** (first FIX FIRST on four real AppKit-interop hygiene gaps —
  missing observer teardown, registration retry, equality guards to stay
  cheap on the slider-drag hot path, and documenting the accessibility
  trade-off of hardcoding `.overlay` — then APPROVE on the second pass) and
  226 tests still passed throughout, since none of this is unit-testable
  UI-interaction behavior.
- **Despite two clean reviewer passes and passing tests, live testing
  caught a CRITICAL regression the reviewer and test suite both missed
  entirely: it broke ALL slider click/drag interaction in the sidebar** —
  the app became unusable for its core editing purpose. Reproduced
  on a fresh launch (ruling out session-state corruption) and in BOTH a
  sibling-element placement AND a `.background()` placement (a safer
  standard NSViewRepresentable idiom, tried as a fix attempt) — neither
  avoided the regression. **REVERTED** — the entire `StableScrollInsets`
  type and its call site were removed. The cosmetic content-shift-on-scroll
  bug is BACK (re-deferred), but the app is fully usable again. A working
  app matters more than a few-pixel cosmetic polish item.
- **Lesson recorded for future attempts at this specific bug**: reaching
  into `NSScrollView.contentInsets`/`automaticallyAdjustsContentInsets`/
  `scrollerStyle` via an `NSViewRepresentable` probe — even implemented
  "correctly" per AppKit-interop hygiene standards and reviewer-approved —
  can silently break SwiftUI's own gesture recognition for sibling controls
  in ways NEITHER code review NOR the unit test suite catches; only live,
  hands-on interaction testing surfaced it. If this cosmetic bug is
  revisited again, budget for thorough live interaction testing (not just
  "does the shift stop") as part of verifying ANY fix touching
  `NSScrollView` internals, and consider that the "design improvement"
  the reviewer suggested during the second pass (a stable, never-toggling
  reserved inset from the start, rather than reactively correcting AppKit's
  own lazy reassertion) might avoid this class of side effect — untried.
- 226 tests unchanged throughout (both the fix attempt and the revert are
  pure AppKit-interop/layout code, no `EditState`/`EditPipeline`/color-math
  touched — consistent with why neither the fix's regression nor its
  revert needed new test coverage, and also why tests alone couldn't have
  caught this class of bug). 3 commits total for this whole investigation:
  the divider-drift + first content-shift fix attempt (reviewed, FIX
  FIRST'd, re-reviewed, APPROVEd), a follow-up PROGRESS.md update (now
  itself partially superseded by this correction), and this revert commit
  (lightly re-reviewed given it's a well-evidenced, purely subtractive,
  user-confirmed-live change).
- **Re-confirmed present, 2026-09-03**: user asked to re-verify this
  exact bug (thought it might have been fixed since — it was not; this
  session's work was all Phase 6/RAW, nothing touched the sidebar
  `ScrollView`). Live-authorized reproduction (screenshots, not code
  changes): expand Selective Color, scroll the sidebar — the WHOLE
  window shifts right by ~15-20px on the first scroll, not just sidebar
  content, confirmed from screenshot pixel comparison (traffic-light
  buttons and title text both move right; a sliver of desktop/another
  window becomes visible at the window's left edge, only possible if
  the window itself moved). No fix attempted this session — the
  "Lesson recorded" note above still applies; still deferred.
- **Unrelated follow-up, same conversation**: the user separately asked
  for a thinner sidebar scrollbar. Given this exact `ScrollView`'s
  history above, went with the deliberately safest option —
  `.scrollIndicators(.hidden)` (`ContentView.swift`'s `editControls`),
  pure SwiftUI, zero `NSScrollView`/`NSScroller` access, so it can't
  reproduce the `StableScrollInsets` class of regression — confirmed by
  the reviewer as a plain visibility toggle with no gesture/hit-testing
  side effects. Also confirmed: hiding indicators was already one of the
  five things tried against the content-shift bug itself (see above) and
  did NOT fix it — this change is unrelated/purely cosmetic, that bug
  remains open. Scrolling itself (trackpad/mouse wheel/keyboard)
  unaffected; only the visible track/thumb (and direct-drag) is gone.
  Reviewer (Opus 5): APPROVE, no live pass required given the mechanism
  can't reach the prior regression — unlike every other RAW/concurrency
  change this session. 412 tests unchanged (pure visual/no logic).

### Revert to Original button (complete, verified live) — last remaining small Phase 3 item
- User picked this over Edit-menu `CommandGroup` integration (the other
  small Phase 3 item deferred when Undo/Redo shipped) and over moving to
  Phase 4. Genuinely small — reused `EditState()` (the same identity value
  `load(from:)` already resets to on new-photo load), `EditHistory`'s
  existing `finalizePendingCommit()` flush-first pattern (already used by
  `undo()`/`redo()`), and each `EditSliderRow`'s own `.disabled(value ==
  identity)` convention applied at the whole-`EditState` level. No new
  `EditState` fields, no new `EditPipeline` stage, no confirmation dialog
  (matches existing app conventions — trivially undoable via ⌘Z anyway).
- `Sources/UI/ImageDocumentModel.swift` — new `revertToOriginal()`.
  **First reviewer pass was FIX FIRST — one real correctness gap**: the
  initial implementation set `editState = EditState()` directly, routing
  through the normal DEBOUNCED `didSet` → `recordEditChange()` path (same
  as an ordinary slider drag) instead of committing immediately like
  `undo()`/`redo()` do. Reviewer traced two real consequences: (1) a
  follow-up edit made within the ~350ms debounce window could silently
  merge into the SAME undo step as the revert, contradicting the method's
  own doc comment claiming atomicity; (2) `canUndo`/`canRedo` could go
  stale relative to what the toolbar buttons showed during that window
  (e.g. clicking Redo right after Revert could silently no-op, since
  `redo()`'s own `finalizePendingCommit()` would commit the pending revert
  and clear the redo stack as a side effect before `history.redo()` ran).
  Fixed by mirroring `undo()`/`redo()`'s exact pattern: `finalizePendingCommit()`
  → `history.commit(EditState())` (direct, synchronous) → `applyHistoryState(
  history.current)` — the revert is now always its own atomic,
  immediately-committed step, `canUndo`/`canRedo` accurate the instant the
  button is clicked. Second pass independently traced through the
  guard/flag interactions (`isApplyingHistoryChange`, `refreshUndoRedoFlags`)
  and confirmed both consequences are closed, with no divergence from
  `undo()`/`redo()`'s own established shape. APPROVEd.
- `Sources/UI/ContentView.swift` — one toolbar button after Redo,
  `arrow.counterclockwise` icon (distinct from Undo's `arrow.uturn.backward`,
  matches Apple Photos' own convention), disabled when no photo is loaded
  or nothing to revert.
- No new tests — matches this project's own established gap: `ImageDocumentModel`
  (unlike `EditEngine`/`Rendering`) has no unit test target at all (depends
  on `NSOpenPanel`/file I/O), and `undo()`/`redo()` are likewise untested;
  this diff is consistent with that existing gap, not a new one.
- 226 tests unchanged (no test-relevant code touched). 1 commit (feature +
  the FIX FIRST correction together, after user confirmed live both before
  and after the fix).

### Edit-menu Undo/Redo integration (complete, verified live) — the FINAL small Phase 3 item
- Last of the two small Phase 3 items deferred when Undo/Redo shipped (the
  other, Revert to Original, done above). Adds a real macOS Edit menu
  Undo/Redo pair via `.commands { CommandGroup(replacing: .undoRedo) }` —
  the canonical, discoverable, keyboard-shortcut-owning home for these
  actions on macOS, previously only available as toolbar buttons.
- `Sources/App/PhotoAppApp.swift` — `ImageDocumentModel` ownership LIFTED
  here from `ContentView` (was `@StateObject private var document` inside
  `ContentView`; now `@StateObject private var document` in `PhotoAppApp`,
  passed down as `ContentView(document: document)`), since `.commands` is a
  `Scene`-level construct that needs direct access to the same document
  instance the toolbar buttons already act on. New `CommandGroup(replacing:
  .undoRedo)` with Undo/Redo `Button`s wired to the SAME `document.undo()`/
  `.redo()` — zero duplicated logic, `canUndo`/`canRedo` being `@Published`
  means the menu items reactively enable/disable in sync with the toolbar.
- `Sources/UI/ContentView.swift` — `document` changed from a self-owned
  `@StateObject` to an externally-supplied `@ObservedObject var document:
  ImageDocumentModel` (now a required init parameter; `#Preview` updated to
  `ContentView(document: ImageDocumentModel())`). The two existing toolbar
  Undo/Redo buttons kept their click behavior/`.disabled` binding exactly
  as-is but had their `.keyboardShortcut` modifiers REMOVED — the Edit menu
  is now the sole canonical owner of ⌘Z/⇧⌘Z, so two separate views don't
  both claim the same key combo. Reviewer confirmed this actually REMOVES a
  pre-existing latent shortcut ambiguity (the toolbar's own shortcuts were
  likely colliding with `WindowGroup`'s default inert Edit>Undo/Redo
  shortcuts all along, before this diff added a real, intentional menu).
- Reviewer APPROVE on first pass — confirmed `@ObservedObject`/`@StateObject`
  ownership split is the correct SwiftUI pattern (no double-observation or
  dangling-reference risk), `CommandGroup(replacing: .undoRedo)` usage is
  standard/correct, and that macOS menu-bar key equivalents are dispatched
  ahead of first-responder key-down handling — so ⌘Z/⇧⌘Z keep working
  regardless of toolbar focus state. One non-blocking note worth tracking:
  since `document` is now shared app-wide rather than per-`ContentView`,
  IF a future "New Window" affordance is ever added (macOS's `WindowGroup`
  supplies ⌘N by default; nothing in this app currently overrides or
  exercises it), a second window would mirror and mutate the SAME edit
  state/undo history live, not get an independent one — inert today (no
  multi-window UI exists), but worth an explicit `CommandGroup(replacing:
  .newItem) { }` suppression or a real per-window-document design if/when
  multi-window or multi-document support (Phase 4 library) is considered.
- No new tests — pure `Scene`/`Commands`/ownership wiring, no new logic,
  consistent with this project's established gap for `ImageDocumentModel`/
  `ContentView` UI glue (no unit test target exists for that layer).
- 226 tests unchanged. 1 commit.
- **This closes out Phase 3's initial slice entirely** — both small
  deferred items (Revert to Original, Edit-menu integration) are now done,
  alongside the core in-memory Undo/Redo feature itself. Disk persistence
  of edit state/history remains the one still-deferred Phase 3 item,
  blocked on the Phase 4 catalog DB.

### Sidecar-file persistence of edit state (complete, verified live) — the LAST Phase 3 item — PHASE 3 NOW FULLY COMPLETE
- The final item in Phase 3 ("non-destructive pipeline: param
  serialization, edit history, undo"). User confirmed scope: a lightweight
  JSON sidecar per photo (`MyPhoto.jpg.photoapp.json`, same directory) —
  CLAUDE.md's own architecture principle explicitly sanctions this
  ("serialized to the DB **and optionally XMP-style sidecars**"), so this
  stayed inside Phase 3 without pulling in Phase 4's much larger
  library/catalog scope. Auto-save (no Save button), reusing the same
  settle/debounce feel already established for undo history.
- **Fixed a landmine flagged months earlier in this project's own
  history**: `EditState`'s `Codable` was fully synthesized, so a missing
  JSON key would throw `keyNotFound` rather than falling back to that
  field's default — meaning any sidecar written today would fail to
  decode ENTIRELY the moment a future session added one more `EditState`
  field (this project adds fields almost every session). Fixed with a
  custom, schema-tolerant `init(from decoder:)` covering all 58 stored
  fields via `decodeIfPresent(...) ?? <declared default>`. **A real,
  live-caught gotcha**: putting this custom init directly in the struct's
  own body silently SUPPRESSED Swift's synthesized memberwise
  initializer, breaking every bare `EditState()` call site across the
  whole codebase (a build failure, caught immediately). Fixed by moving
  the custom `init(from:)` + its `CodingKeys` into a separate
  `extension EditState { ... }` — extensions don't suppress synthesis,
  only the primary struct body does. New `Tests/EditEngineTests/
  EditStateCodableTests.swift` (9 tests) directly exercises the fix:
  missing-field-defaults, empty-object-decodes-to-identity, unknown-key-
  ignored, the one array field (`redEyePoints`) absent vs. present, plus
  `ImageDocumentModel.sidecarURL(for:)` (marked `nonisolated` so tests
  don't need `@MainActor` context — it touches no actor state).
- **A real platform constraint found via live testing, not assumed**:
  the plan's original design (write a sidecar file as a sibling of the
  user-selected photo, upgrading `com.apple.security.files.user-selected
  .read-only` to `.read-write`) turned out to be blocked by App Sandbox
  outright — confirmed live via a temporary probe write, which failed
  with "You don't have permission to save the file... in the folder
  'Downloads'." App Sandbox's access grant for a user-SELECTED file does
  NOT extend to writing new sibling files in the same directory. **User
  was asked directly and chose the security-scoped-bookmark approach**
  (over the simpler alternative — storing edit data invisibly inside the
  app's own container, keyed by path) to preserve the visible, portable,
  Lightroom-style "sidecar sits next to the photo" model.
- **A SECOND real platform gotcha, also only found live**: upgrading to
  `.read-write` (which seemed necessary at first) turned out to BREAK the
  basic "Open…" photo picker outright — files became unclickable, only
  Cancel worked, reproduced on a fresh launch. Root cause not fully
  pinned down (suspected: an ad-hoc "Sign to Run Locally" signing
  identity, with no real Team ID/provisioning profile, interacting badly
  with this specific entitlement under `ENABLE_HARDENED_RUNTIME: true`).
  Resolved by reverting to `.read-only` and confirming LIVE that the
  security-scoped folder bookmark (obtained via its own, separate,
  user-consented directory-mode `NSOpenPanel` + `bookmarkData(options:
  .withSecurityScope)`) works completely independently of the
  `user-selected` entitlement family — it's an orthogonal sandbox grant.
  Net result: `project.yml`/`PhotoApp.entitlements` show NO diff versus
  the pre-feature state (ended up back at the original `.read-only`).
  **Also discovered along the way (unrelated to this feature, but
  load-bearing for future entitlement work)**: `project.yml`'s own
  `entitlements.properties` block, not the `.entitlements` XML file
  directly, is the actual source of truth — `xcodegen generate`
  regenerates the XML from it every run, silently overwriting any direct
  edit to the XML file alone. Cost a full confused round before being
  traced.
- `Sources/UI/ImageDocumentModel.swift` — the bulk of the new code:
  `currentURL` (previously never retained after `load(from:)` — only the
  bare filename string survived); `folderBookmarks: [String: Data]`
  (UserDefaults-backed, keyed by folder path); `resolvedBookmarkURL`/
  `requestFolderAccess`/`declinedFolders`/`isLoadingPhoto`/
  `scheduleSidecarSave`/`flushPendingSidecarSave`/`saveSidecarNow`/
  `loadSidecarIfReachable`. Auto-save reuses the EXACT debounce/coalesce
  `DispatchWorkItem` idiom already established for undo history (a
  longer ~1.0s interval, since disk I/O doesn't need undo-step
  sub-second responsiveness). The `isLoadingPhoto` guard (set only around
  `load(from:)`'s own restore-or-identity assignment) keeps auto-save
  LAZY — merely opening/viewing a photo must never trigger a folder-
  access prompt, only a REAL subsequent edit should; this was designed
  in from the start, not a live-caught bug.
- **A real UX gap WAS caught live and fixed before shipping**: declining
  a folder-access prompt once caused EVERY subsequent edit to re-prompt
  again (nothing remembered the decline) — five slider drags would have
  meant five dialogs. Fixed with an in-memory-only (deliberately NOT
  persisted) `declinedFolders: Set<String>`, checked before prompting —
  suppresses re-prompting for the rest of THIS session only; a fresh
  launch asks again, so one accidental cancel doesn't permanently block
  a folder.
- **First reviewer pass was FIX FIRST — two real bugs**: (1)
  `sidecarSaveWorkItem` was never cleared once its debounced closure
  actually FIRED (only replaced on a NEW edit) — meaning
  `flushPendingSidecarSave()`'s guard stayed permanently "true" after
  the first-ever edit of a session, silently making every later
  `load(from:)` (i.e. every photo switch, even to an untouched photo)
  redundantly re-invoke `saveSidecarNow()`, which could pop an unwanted
  permission prompt on a mere switch if a bookmark had gone stale — fixed
  by clearing the flag as the FIRST statement inside the work item's own
  closure; (2) `requestFolderAccess`'s `try? bookmarkData(...)` silently
  swallowed a genuine creation failure even after the user explicitly
  GRANTED access, with zero feedback — fixed with a proper `do/catch`
  surfacing via the new `sidecarSaveErrorMessage` alert, while keeping
  the separate "user declined the panel" path correctly silent. Second
  pass independently traced `saveSidecarNow()`'s full call graph to
  confirm no re-entrancy hazard from clearing-before-calling, confirmed
  the decline-vs-failure paths are now cleanly separated, and APPROVEd.
- **A live, unexplained flake, documented rather than hidden**: during
  testing, a save attempt for a second photo in an ALREADY-bookmark-
  granted folder failed once with "you don't have permission" (reaching
  the actual write step, not a resolution failure), then succeeded on a
  later attempt with no code change in between. Not reproduced a second
  time; not root-caused with certainty (Console.app sandbox-denial logs
  were not captured). Reviewer confirmed the resolve→start→defer-stop
  security-scoped-resource lifecycle is Apple's own documented correct
  pattern and found no logic bug that would explain it — currently
  believed to be a transient macOS sandbox/extension-registration timing
  quirk, possibly made rarer by the `sidecarSaveWorkItem` fix above
  (which was also generating spurious extra save attempts). Flagged here
  for anyone debugging a similar report later, not treated as blocking.
- 235 tests total (9 new `EditStateCodableTests`). 1 commit (feature +
  both FIX FIRST corrections together, after extensive live verification
  across many rebuild-and-relaunch rounds — this was, by a wide margin,
  the most live-testing-intensive feature this entire session, given it
  was the first disk-write code and first security-scoped-bookmark code
  in the whole project).
- **PHASE 3 IS NOW FULLY COMPLETE** — in-memory Undo/Redo, Revert to
  Original, Edit-menu integration, and sidecar-file persistence are all
  shipped and reviewer-approved. Nothing remains deferred in Phase 3.

### Adjust tab regrouping into labeled sections (complete, verified live)
- User picked this as a lighter follow-up after Phase 3 closed out, over
  suppressing the default ⌘N "New Window" behavior or revisiting the
  re-deferred sidebar scroll-shift bug. Deferred earlier in favor of the
  RGB histogram feature; confirmed scope via a preview shown at that time
  (LIGHT/COLOR/EFFECTS groupings), extended here to cover every existing
  control.
- `Sources/UI/ContentView.swift` — `adjustTabContent`'s single flat
  ~20-row `VStack` split into six labeled, `Divider()`-separated
  sub-sections matching Apple Photos' own adjustment-panel groupings:
  `lightSection` (Exposure, Brightness, Brilliance, Contrast, Highlights,
  Shadows, Black Point, Levels), `colorSection` (Temperature, Tint, Pick
  White Balance, Fix Color Cast, Hue, Vibrance, Saturation), the
  pre-existing `selectiveColorSection` (kept as its own top-level section
  rather than folded into Color — big enough, and already visually
  distinct, to deserve staying separate, matching how Apple Photos' own
  panel treats it), a new `blackAndWhiteSection` (just the toggle, its own
  small section — B&W is a mode switch, not a continuous slider, matching
  Apple Photos giving it a distinct panel entry), `effectsSection`
  (Vignette, Vignette Radius, Definition, Sharpen, Noise Reduction), and
  the pre-existing `redEyeSection` (untouched internals, gained one new
  `Text("Red-Eye").font(.headline)` label for consistency with the other
  sections' header style).
- Purely presentation-only — zero `EditState`/`EditPipeline` changes,
  every binding/range/identity/format closure claimed to be copied
  byte-for-byte into its new location, just regrouped and reordered.
- Reviewer APPROVE on first pass — given the real, checkable risk in a
  large manual transcription (20 rows moved, a silent copy-paste swap
  between two similar-looking rows being the realistic failure mode),
  explicitly cross-checked every row's `range`/`identity`/format string
  against `EditState.swift`'s own documented defaults (not just confirmed
  the code compiles), confirmed every field binding points at the correct
  property, confirmed no row was dropped or duplicated (each
  `$document.editState.<field>` binding appears exactly once), and
  confirmed `selectiveColorSection`/`redEyeSection`'s bodies are untouched
  except the one intentional header addition. No issues found.
- 235 tests unchanged (pure UI reorganization, no test-relevant code
  touched) — matches this project's own precedent (the earlier dark-
  theme+tab-bar layout redesign also shipped with zero new tests). 1
  commit.

## Open reviewer issues
One non-blocking note carried forward (last reviewer verdict was
APPROVE, first pass, for photo selection for export): `selectedPhotoIDs`
is only pruned via `selectedFilter`'s `didSet`, not on every `refresh()`
— if a user selects a photo while viewing a Collection, then removes
that same photo from that Collection via its own folder-badge menu
(`toggleMembership`) WITHOUT changing `selectedFilter`, its ID lingers in
`selectedPhotoIDs` after it drops out of `catalog.photos`. Cosmetic
only — the toolbar label's raw count can overstate, but `photosToExport`
(and the sheet's displayed count) always filter against live
`catalog.photos`, so the actual exported set is always correct. Worth
pruning `selectedPhotoIDs` to intersect with `photos` at the end of
`refresh()` sometime, not urgent.

Before that: one non-blocking note carried forward (reviewer verdict was
APPROVE, second pass, for Batch export — after one FIX FIRST round, see
"Phase 5, Slice 1" below): `ExportOptionsView`'s own "Export" button
isn't gated on `exportModel.isExporting` and doesn't disable itself
after being tapped once — a very rapid double-click on it, before the
sheet's `dismiss()` completes, could in theory queue two
`DispatchQueue.main.async { onExport() }` calls that both see
`isExporting == false`. Low-probability edge case, orthogonal to the
toolbar-button re-entrancy guard that WAS required and fixed; worth a
follow-up `.disabled(...)` there sometime, not urgent.

Before that: three non-blocking notes carried forward (reviewer verdict
was APPROVE, first pass, for Folder-mirrored nested collections): (1)
`collection.folderPath` has no index at all (not even a plain non-unique
one — SQLite's restriction is specifically on `UNIQUE`/`PRIMARY KEY` via
`ALTER TABLE ADD COLUMN`, a separate `CREATE INDEX` isn't restricted), so
every folder node in a tree import does a full-table scan to find-or-
create — fine at today's personal-library sizes, cheap to fix later with
a dedicated index migration; (2) `PhotoImporter.scanNode` has no
symlink-loop guard or recursion-depth cap — a folder tree containing a
symlink cycle would recurse unboundedly; low real-world likelihood for a
personal photo library, a one-line defensive guard would be cheap
insurance; (3) `findOrCreateFolderCollection` matches purely by
`folderPath` and silently ignores a mismatched `parentID` on an existing
row (never reparents on re-import from a different root) — safe (never
silently moves a branch) but undocumented.

Before that: two non-blocking notes carried forward (reviewer verdict was
APPROVE, first pass, for Collections): (1) the SAME "overlapping
`refresh()` calls can complete out of order" class of issue already
recorded below for ratings/flags now generalizes to EVERY mutation
(`createCollection`, `toggleMembership`, imports, ratings, flags) — each
independently kicks off its own `Task.detached` + `refresh()` with no
cancellation/sequencing, so a fast second action can have its slower
first `refresh()` clobber `photos` with stale data; still just a
transient, self-correcting display glitch, not data corruption (worth a
generation-counter or `Task` cancellation guard if it ever becomes
user-visible); (2) `collection.name` has no `UNIQUE` constraint, so
rapid double-submits of "New Collection…" could create duplicate-named
collections — consistent with rename/delete management being explicitly
out of this slice's scope, not a data-integrity bug.

Also carried forward: rapid repeated taps on the same photo's
rating/flag can similarly show a transiently-stale value in the grid
(same underlying cause as (1) above, first observed in Ratings and
flags) — NOT a persisted-data bug, confirmed via multiple full
quit/relaunch cycles across both that slice and Collections that writes
always land correctly in the database.

Before that: last reviewer verdict was APPROVE (Library thumbnail grid, second
pass, after one FIX FIRST round with 4 issues, all in `CatalogModel.swift`:
(1) `activateFolderAccess` returned early on a bookmark-creation failure
BEFORE ever calling `startAccessingSecurityScopedResource()`, silently
killing access for the current session too, not just future relaunches;
(2) the `Bool` return of `startAccessingSecurityScopedResource()` was
discarded everywhere, treating a failed grant as success; (3) the new
thumbnail cache was an unbounded `[String: CGImage]` — every photo ever
scrolled into view stayed decoded in memory forever; (4) re-importing the
same folder twice in one session called `startAccessingSecurityScopedResource()`
again with no matching stop. All four fixed — access-capture and
scope-activation are now independent steps (a bookmark failure no longer
blocks the `start` call), failures surface as a warning folded into the
import summary, the cache is now an `NSCache` capped at 64MB, and an
`activeFolders` set prevents starting the same folder's scope twice —
re-reviewed, APPROVED. One non-blocking note carried forward for a future
session: `activateKnownFolders` keys `activeFolders` by the bookmark's
original path, so a folder renamed/moved between sessions could get its
scope started twice on re-import — a corner case, not a regression.

One non-blocking note carried forward from Catalog DB foundation (slice 1)
review, still accurate: the `#Preview` in `ContentView.swift` constructs a
real `CatalogModel()`, side-effecting the on-disk catalog on every
canvas-preview render — harmless, low priority.

Before that: last reviewer verdict was APPROVE (Adjust tab regrouping, first
pass). One documented, unexplained live flake carried forward for
awareness (not blocking, not reproduced a second time, from the sidecar-
persistence work): a transient "you don't have permission" sidecar-save
failure that self-resolved without a code change — see "Sidecar-file
persistence of edit state" above for its own write-up. Non-blocking note
carried forward from the Edit-menu
integration: consider suppressing or redesigning the default ⌘N "New
Window" behavior before any multi-window UI is added, since `document`
is shared app-wide.

Prior: Revert to Original (second pass, after one FIX FIRST round on the
atomic-commit correctness gap).
Separately, the sidebar layout investigation status stands as recorded
above: the divider-drift bug IS fixed and shipped (`MetalImageView`'s
`intrinsicContentSize`
override); the sidebar content-shift-on-scroll bug is BACK/re-deferred
after its fix caused a critical regression (broke all slider interaction)
that passed two reviewer passes and the full test suite before live
testing caught it — see that section's "Lesson recorded" note before
attempting this again. One non-blocking observation carried forward from
the Undo/Redo review (still not required to fix): the global ⌘Z toolbar
shortcut may intercept a focused text field's native undo; worth a manual
check, not a correctness bug.

**Outstanding manual verification** (could not be automated in this
environment — no GUI automation tool for a native macOS app): the toolbar-
crowding visual issue found during this pass is now fixed and confirmed,
but the UNDO/REDO FUNCTIONALITY ITSELF is still not yet manually confirmed.
Still needed: confirm live that a continuous slider/crop drag coalesces into
exactly ONE undo step (not many), that Undo/Redo buttons enable/disable
correctly, that a red-eye tap / aspect-preset snap / per-slider Reset / WB
eyedropper / Fix Color Cast each become one undoable step, that opening a
new photo clears history, and that undo updates the live histogram. See
"Exact next step" for the full manual checklist.

Prior: Selective Color (second pass, after one FIX FIRST round on a real
functional bug — resolved and independently re-verified before commit).

Prior: Selective Color (second pass, after one FIX FIRST round on a real
functional bug — resolved and independently re-verified before commit).

Prior: WB eyedropper (second pass, after one FIX FIRST round on
force-unwraps in production code — resolved before commit).

Prior: Levels + live histogram (first pass, three non-blocking notes — one
addressed by a same-commit-batch wording fix, two left as accepted,
documented, non-regressive gaps).

Prior: Definition/Clarity (first pass, one non-blocking coverage gap — no
dedicated Vignette non-commutativity test, deliberately not force-added).

Prior: Noise Reduction (second pass, after one FIX FIRST round on a
test-rigor issue: the sharpness-pin regression guard originally couldn't
fail even if the pin were removed).

Prior: Sharpen (first pass, one minor non-blocking test-rigor nit only).
Every shipped Phase 2 feature and backlog addition has a clean final
reviewer verdict (Noise Reduction's FIX FIRST round was resolved before
commit, per workflow rules).

## Done
### Phase 1 — Foundation (complete, verified live)
- Repo initialized, CLAUDE.md workflow rules in place (quota/safe-pause
  discipline, this PROGRESS.md file).
- Xcode project scaffolded via XcodeGen (`project.yml`); `.xcodeproj` is
  generated, gitignored, regenerate with `xcodegen generate`.
- Rendering: `MetalImageView` (MTKView, on-demand redraw) + `ImageRenderer`
  (CIContext-based draw, aspect-fit + centered) + `AspectFit` math with unit
  tests.
- UI: `ContentView` + `ImageDocumentModel` — Open… via NSOpenPanel, read-only
  file access, EXIF orientation applied, decode-failure alert.
- Golden path manually verified live: real photo opens upright, readable,
  centered. (One round-trip bug along the way: a vertical-flip "fix" validated
  only against an offline MTLTexture test actually caused 180° rotation in the
  *live* MTKView drawable; removing it fixed it — see the comment in
  `Sources/Rendering/ImageRenderer.swift` for the scoped, empirical explanation
  and the flagged re-verify-later risk for Phase 5 export / Phase 7 tiled
  rendering, which will target offscreen textures like the misleading test did.)

### Phase 2, Feature 1 — Exposure adjustment (complete, verified live)
- `Sources/EditEngine/EditState.swift` — `exposureEV`.
- `Sources/EditEngine/EditPipeline.swift` — applies exposure via Core Image's
  built-in `CIExposureAdjust`, scene-linear.
- `Sources/Rendering/ImageRenderer.swift` — `CIContext` explicitly sets
  `workingColorSpace` (extended-range linear sRGB) + `workingFormat` (`RGBAh`),
  satisfying CLAUDE.md's "linear light in a defined working color space"
  instead of relying on framework defaults; output stays sRGB, applied only at
  final render. `draw(in:)` applies the edit pipeline and uses the *edited*
  image's extent throughout (forward-compatible with crop).
- Exposure slider (bottom bar, −5…+5 EV); edit state resets per photo on load.
- Reviewer-approved; user manually confirmed live.

### Phase 2, Feature 2 — Contrast adjustment (complete, verified live)
- `Sources/EditEngine/EditState.swift` — `contrast` (-1...1, maps to
  `CIColorControls` factor `1 + contrast`).
- `Sources/EditEngine/EditPipeline.swift` — contrast is applied in the
  **perceptual sRGB-gamma domain, not linear light** — a documented deviation
  from CLAUDE.md's default rule (which CLAUDE.md permits when documented).
  Rationale: a linear-domain pivot at 0.5 sits at ~0.735 perceptual
  brightness, crushing photographic middle gray (linear ≈0.214) toward black
  at typical contrast factors — empirically verified against real
  `CIColorControls` behavior before implementing. Implementation:
  `CIColorControls` sandwiched between `CILinearToSRGBToneCurve` (encode) and
  `CISRGBToneCurveToLinear` (decode), applied after exposure. The tone-curve
  filters are exact inverses and don't clamp values >1, so exposure's
  highlight headroom survives the round-trip. This encode/decode boundary
  (`applyPerceptualAdjustments`) is a **shared sandwich** — curves and HSL
  must be added *inside* it, not given their own.
- Contrast slider (bottom bar, -1...1, live % readout).
- 8 contrast tests; values independently re-derived by the reviewer from the
  stated sRGB transfer functions, confirmed correct to ~2e-6.
- Reviewer-approved; user manually confirmed live.

### Phase 2, Feature 3 — White balance (temperature + tint) (complete, verified live)
- `Sources/EditEngine/EditState.swift` — `whiteBalanceTemperature` (Kelvin,
  3500...9500, default 6500 = neutral) and `whiteBalanceTint` (-100...100,
  default 0).
- `Sources/EditEngine/EditPipeline.swift` — WB is first in the pipeline
  (`applyWhiteBalance` runs before `applyExposure`), applied in **scene-linear
  light — NOT a deviation** (unlike contrast), since chromatic adaptation is
  physically a linear matrix multiply. Empirically confirmed via real
  `CITemperatureAndTint` behavior: identity round-trips exactly, values >1.0
  stay finite/un-clamped.
- **Two composed sign inversions**, both measured not assumed: (1) the raw
  Core Image filter's own semantics run opposite to intuition (lower
  `targetNeutral.x` = warmer; negative `targetNeutral.y` = magenta); (2) mid-session
  the user asked to switch the Temperature UI from a relative scale to actual
  Kelvin, which required a SECOND inversion to match the Lightroom/Camera Raw
  convention (higher Kelvin slider = warmer on screen — itself backwards from
  both blackbody physics and the raw filter). Final mapping:
  `targetNeutral.x = 2*6500 - whiteBalanceTemperature`. Verified: 6500K → exact
  filter neutral (true identity), 9500K → the measured "warm" filter input,
  3500K → the measured "cool" one. Reviewer independently verified this
  composition arithmetically (not just self-consistency) after the pivot,
  including checking for leftover old-scale (`-100...100`/default-`0`)
  remnants — none found.
- Temperature slider now shows Kelvin directly (`"%.0fK"`, 3500...9500,
  resets to 6500); Tint slider unchanged (-100...100, resets to 0).
- 10 new WB tests using values measured from the real filter (chromatic
  adaptation has no closed-form transfer function to hand-derive against).
- All 31 tests pass (6 AspectFit + 25 EditPipeline); 2 commits (color-math,
  then UI); user manually confirmed live, including after the Kelvin pivot —
  dragging Temperature right visibly warms the photo, matching Lightroom.

### Phase 2, Feature 4 — Curves (parametric shadows/highlights) (complete, verified live)
- `Sources/EditEngine/EditState.swift` — `curvesShadows`, `curvesHighlights`
  (both -1...1, default 0), added after `contrast`.
- `Sources/EditEngine/EditPipeline.swift` — curves runs inside the existing
  perceptual sandwich, **after contrast** (measured non-commutative: reversed
  order gives a different result for the same inputs — 0.84872 vs 1.59067 at
  one test point). Scoped as two sliders (Highlights, Shadows) each moving one
  control point of Core Image's `CIToneCurve` (a 5-point spline), matching
  Lightroom's simplified Basic-panel tone controls rather than a full
  interactive point-based curve editor — consistent scope with every other
  Phase 2 feature.
- **Known, measured, documented limitation**: `CIToneCurve` clamps its domain
  to [0,1] the moment it's non-identity, so enabling any curve adjustment
  collapses highlight headroom above linear 1.0 — including headroom contrast
  alone would otherwise preserve — to white. Confirmed via diagnostic script,
  independently re-confirmed by the reviewer, who also stress-tested the
  obvious "cheap" workaround (split off headroom, curve only the safe range,
  recombine) and found it **silently corrupts alpha** via premultiplication
  math — concretely validating that shipping the clamp as a documented v1
  limitation and deferring a custom Metal kernel (per CLAUDE.md's Stack note:
  "custom kernels for curves, HSL, WB") is the right tradeoff, not a shortcut.
  Two tests (`testCurvesClampHighlightHeadroom`,
  `testContrastHeadroomLostWhenCurveActive`) pin this as an intentional
  regression guard, not just documentation.
- Highlights/Shadows sliders (bottom bar, -1...1, live % readout), after
  Contrast.
- 10 new curves tests using values measured from the real filter (chromatic
  spline behavior has no closed-form transfer function to hand-derive
  against). All 40 tests pass (6 AspectFit + 34 EditPipeline); 2 commits
  (color-math, then UI); user manually confirmed live — both sliders produce
  visible, monotonic, controllable tonal shaping.

### Phase 2, Feature 5 — HSL (global hue + saturation) (complete, verified live)
- `Sources/EditEngine/EditState.swift` — `hslHue` (-180...180°, default 0) and
  `hslSaturation` (-1...1, default 0), added after `curvesHighlights`.
- `Sources/EditEngine/EditPipeline.swift` — HSL runs inside the perceptual
  sandwich, **after curves** (measured non-commutative, like contrast↔curves).
  Scoped as two sliders (global Hue, global Saturation) rather than a
  per-color-band professional HSL panel (8 bands × 3 params — an order of
  magnitude more surface with no analog in anything shipped). Lightness
  intentionally omitted: would duplicate exposure + curves' shadow/highlight
  lift (same reasoning curves used to skip a midtones slider).
- **Headline finding, verified not assumed**: unlike curves, HSL does NOT
  clamp highlight headroom — `CIHueAdjust` and `CIColorControls.saturation`
  are matrix/blend ops with no internal [0,1] LUT (measured: saturation +1 on
  a 1.4 channel → 2.57770, not clamped). Confirms the curves plan's own
  warning not to blindly repeat its clamp precedent for HSL. Hue's raw
  rotation direction already matched on-screen intuition — no sign inversion
  needed (unlike white balance's two).
- **A first reviewer pass caught a real gap**: the initial claim "hue and
  saturation commute" only held at modest slider values, untested at the
  actual slider range, where the two measurably diverge (~0.0043 at hue
  -90°/sat +1, over 2x the test tolerance) even though the shipped order is
  fixed. Fixed by correcting the doc comment and adding
  `testHueSaturationOrderIsFixed` as a real regression guard — the reviewer
  verified this by temporarily reversing the code's internal order and
  confirming the test failed with the exact predicted values, then restoring
  it.
- Hue/Saturation sliders (bottom bar, after Shadows).
- 9 new HSL tests (+1 from the review fix = 10) using values measured from
  the real filters. All 49 tests pass (6 AspectFit + 43 EditPipeline); 2
  commits (color-math + fix, then UI); user manually confirmed live — hue
  rotates colors around the wheel, saturation ranges grayscale to punchier.

### Phase 2, Feature 6 — Crop (final Phase 2 feature) (complete, verified live)
- `Sources/EditEngine/EditState.swift` — `cropInsetTop`/`Bottom`/`Left`/`Right`
  (all 0...0.45, default 0), added after `hslSaturation`. Struct does NOT
  itself enforce the range (documented) — `EditPipeline` clamps on every use.
- `Sources/EditEngine/EditPipeline.swift` — `applyCrop` is the final pipeline
  stage, after the perceptual sandwich (pure geometry, no color-space
  concerns — unlike every other Phase 2 feature). Unlike those features, this
  plan was designed directly rather than via a dispatched Plan agent (given
  this session hit a spend limit once already, and crop's risk profile is
  much lower — close analog to `AspectFit`, no Core Image diagnostics needed).
  Coordinate-direction claim ("top inset" trims the high-y portion of
  `CIImage`'s coordinate space) was verified empirically before writing code,
  then pinned with unit tests using a quadrant-colored synthetic image rather
  than just extent-number checks.
- **A real bug was found and fixed during live manual testing** (not caught
  by any unit test, since it's a live-rendering-only artifact): dragging the
  crop sliders continuously produced repeated/tiled strips of the image
  instead of a clean single crop. Root cause: `ImageRenderer.draw(in:)`
  renders directly into `drawable.texture`, bypassing MTKView's normal clear
  pass; before crop, the fitted image always filled at least one full
  dimension of the drawable, so uncovered margins never mattered. Crop is the
  first stage that can shrink the fitted image on both axes at once, and
  MTKView's buffered drawables retained stale content from earlier frames of
  the same drag in those margins. Fixed by compositing the fitted image over
  an explicit full-bounds black background every frame
  (`Sources/Rendering/ImageRenderer.swift`). Verified live after the fix —
  clean single crop, correct on all four sides. Reviewer confirmed the fix is
  sound and color-space-invariant, noted a cheaper hardware-clear alternative
  exists but isn't necessary before Phase 7's perf work.
- Four crop inset sliders (bottom bar, last of 12 total rows — the control
  panel is now wrapped in a `ScrollView` to stay usable).
- 8 new crop tests, including a quadrant-image coordinate-direction proof.
  All 57 tests pass (6 AspectFit + 51 EditPipeline); 3 commits (crop
  color/geometry math, the rendering fix as its own commit, then UI).
- 24 commits total on `master`.

### Phase 4, Slice 1 — Catalog DB foundation + basic folder import (complete, verified live)
- The project's FIRST external dependency ever: GRDB 7.x, added via
  `project.yml`'s new `packages:`/`dependencies: [- package: GRDB]` keys
  (XcodeGen syntax, confirmed via a live `xcodebuild -resolvePackageDependencies`
  — resolved to 7.11.1). `xcodegen generate` only writes the package
  reference; the actual fetch happens at build time and needs network then.
- `Sources/Catalog/` (previously empty) now holds: `Photo.swift` (a
  metadata/path-only GRDB record — `path` is `UNIQUE`, which is what makes
  re-importing the same folder idempotent), `Migrations/001_initial.swift`
  (the first append-only migration, per CLAUDE.md convention), and
  `CatalogDatabase.swift` (an `async`, off-main-thread wrapper around a
  GRDB `DatabaseQueue`, opened at `Application Support/PhotoApp/catalog.sqlite`
  — inside the app's own sandbox container, so no security-scoped bookmark
  is needed for the DB itself, and no user photo file is ever touched).
  `PhotoImporter.swift` is a separate, pure/stateless folder-scan helper
  (no DB, no UI) so it's trivially unit-testable.
- `Sources/UI/CatalogModel.swift` (new) is the UI-facing wrapper — kept out
  of `Sources/Catalog` to keep that module SwiftUI/AppKit-free, matching
  CLAUDE.md's "No UI imports in EditEngine" principle extended to Catalog.
  Shows a directory-mode `NSOpenPanel`, then imports via `Task.detached`.
- **A real bug caught by the reviewer's first pass**: `CatalogModel.init()`
  originally opened `CatalogDatabase()` (real blocking I/O — directory
  creation, SQLite open, migration) synchronously on `@MainActor` at app
  launch, contradicting CLAUDE.md's own "DB access never blocks the main
  thread" principle. Fixed by making `init()` cheap/synchronous (just
  launches a `Task.detached`) and hopping back to `@MainActor` only to
  publish the opened `database`/`initError`/seeded `photoCount`. Second
  reviewer pass confirmed the fix is genuinely off-main and race-free
  (`database`/`initError` are only ever read/written from `@MainActor`,
  so serialized) — APPROVE.
- A separate, unrelated build failure surfaced along the way: adding a 5th
  `.alert` to `ContentView`'s already-large `body` made Swift's type
  checker fail ("unable to type-check this expression in reasonable
  time"). Fixed by splitting `body` into `mainContent` (the existing view
  tree, unchanged) + `body` (`mainContent` followed by the alert chain) —
  confirmed behavior-preserving by the reviewer (same modifiers, same
  conditions, nothing dropped or duplicated).
- `Tests/CatalogTests/` (new): `CatalogDatabaseTests` (in-memory GRDB
  queue — insert, idempotent re-import, fetch round-trip, ordering) and
  `PhotoImporterTests` (real temp directory — case-insensitive extension
  filtering, excludes this app's own `.photoapp.json` sidecars). All 245
  tests pass (235 prior + 10 new).
- Manually verified live (after killing a STALE already-running instance
  from days earlier that `open` was silently refocusing instead of
  launching the fresh build — worth remembering for next time): "Import
  Folder…" toolbar button imports and reports a count; re-importing the
  same folder reports 0 new (idempotent); existing Open/edit flow
  unaffected; re-verified again after the async-init fix.
- Explicitly OUT of scope for this slice (by the user's own chosen scope):
  thumbnail grid/browsing UI, ratings/flags, collections, persisting a
  bookmark for re-reading catalogued files later.
- 4 commits (GRDB dependency; the Catalog module; UI wiring + the
  body/mainContent split; tests).

### Phase 4, Slice 2 — Library thumbnail grid (browsing view) (complete, verified live)
- `Sources/Rendering/ThumbnailGenerator.swift` (new): a pure, stateless
  ImageIO-based decoder — `CGImageSourceCreateThumbnailAtIndex` with
  `kCGImageSourceCreateThumbnailWithTransform` (applies EXIF orientation
  for free, unlike `ImageDocumentModel.load`'s own manual
  `exifOrientation(of:)` step) and a `maxPixelSize` cap. Never
  materializes the full-resolution image.
- `Sources/UI/CatalogModel.swift` extended: `@Published photos: [Photo]` +
  `refresh()` (re-reads `photoCount`/`photos`, called after init's
  background DB-open and after every successful import); `thumbnail(for:)`
  backed by a `private actor ThumbnailCache` with in-flight de-duplication
  (two concurrent requests for the same path await the same decode) and,
  after the reviewer's fix, an `NSCache` (not a plain dictionary) capped
  at 64MB so a large, growing library's thumbnails don't stay resident
  forever.
- **Persisted, read-only folder access across relaunches** — the key new
  piece of sandbox handling this slice needed: `ImageDocumentModel.load(from:)`'s
  `CIImage(contentsOf:)` decode is LAZY (the file is actually read at
  render time, possibly repeatedly), so scoping security access only
  around the `load()` call isn't enough — the scope must outlive it. Design:
  capture a `.withSecurityScope` read-only bookmark for each imported
  folder (own `UserDefaults` store, separate key from
  `ImageDocumentModel`'s existing sidecar-save bookmarks — deliberately
  not shared, so this newer/less-tested path can't affect the working
  one), and hold `startAccessingSecurityScopedResource()` open for the
  process's entire lifetime (no matching `stop` — intentional, the OS
  reclaims on quit). Every known folder is re-activated once at launch
  (`activateKnownFolders()`), so thumbnails and "open" both keep working
  after quit/relaunch — manually verified live, including a full quit +
  relaunch cycle.
- **A real reviewer-caught bug batch, all in this bookmark/scope logic**
  (first pass FIX FIRST, 4 issues — see "Open reviewer issues" above for
  the full list): a bookmark-creation failure was short-circuiting past
  the `start` call entirely (killing CURRENT-session access, not just a
  future relaunch's); `startAccessingSecurityScopedResource()`'s `Bool`
  result was discarded everywhere, hiding a failed grant; the thumbnail
  cache was unbounded; re-importing the same folder twice stacked
  unmatched `start` calls. All four fixed (independent bookmark/start
  steps with a surfaced warning folded into the import summary, an
  `activeFolders` guard set, `NSCache`), re-reviewed, APPROVED.
- `Sources/UI/LibraryGridView.swift` (new): a `LazyVGrid` over
  `catalog.photos` with an empty-state prompt, each cell fetching its own
  thumbnail via `.task(id: photo.path)`.
- `Sources/UI/ContentView.swift`: a "Library"/"Editor" toolbar toggle;
  `mainContent` now branches between `LibraryGridView` and the existing
  editor (mechanically renamed to `editorContent`, confirmed
  behavior-preserving by the reviewer — same modifier chain relocated
  onto the new outer `Group`, nothing dropped or duplicated). Selecting a
  thumbnail calls `document.load(from:)` and switches back to the editor.
- `Tests/RenderingTests/ThumbnailGeneratorTests.swift` (new, 4 tests):
  size-cap enforcement, no-upscale-beyond-source, missing file, non-image
  file — writes a real PNG to a temp file first. All 249 tests pass (245
  prior + 4 new). `CatalogModel`'s bookmark/actor-cache code itself is
  left untested, matching this project's established UI-glue convention
  (no `UITests`, bookmarks can't be exercised headlessly).
- Manually verified live end-to-end, including the specific behavior most
  likely to silently regress: thumbnails render, clicking one opens it
  into a fully-editable state, toggling Library/Editor works, AND — after
  fully quitting and relaunching the app — thumbnails still render and a
  photo still opens (the actual payoff of the persisted-bookmark design).
- 3 commits (ThumbnailGenerator + tests; CatalogModel extensions; grid +
  ContentView wiring).

### Phase 4, Slice 3 — Ratings and flags (complete, verified live)
- Confirmed with the user up front: a classic 0–5 star rating, a single
  boolean flag ("Pick"), both always visible below the filename in every
  grid cell (not hover-only) — Library-grid-only for now, not surfaced in
  the single-photo Editor.
- `Sources/Catalog/Migrations/002_ratings_and_flags.swift` (new): the
  project's first migration since `001_initial` and its first
  `ALTER TABLE` — adds `rating INTEGER NOT NULL DEFAULT 0` and
  `isFlagged BOOLEAN NOT NULL DEFAULT 0` via GRDB's `table.add(column:)`.
  Reviewer independently confirmed (against the vendored GRDB source) this
  is exactly the constant-default form SQLite requires for adding a
  `NOT NULL` column to an ALREADY-POPULATED table — real risk here, since
  slices 1/2 shipped without this column and this machine's on-disk
  `catalog.sqlite` already had rows. `001_initial.swift` itself has zero
  diff — append-only convention held.
  Manually verified against that exact real, pre-populated database (not
  just a fresh test DB): two full quit/relaunch cycles, ratings/flags
  persisted correctly both times.
- `Sources/Catalog/Photo.swift`: `rating`/`isFlagged` fields added with
  Swift-side defaults matching the migration's, so `CatalogDatabase.importPhotos`'s
  existing `Photo(...)` construction kept compiling unchanged.
- `Sources/Catalog/CatalogDatabase.swift`: `setRating`/`setFlagged` — the
  project's first `UPDATE` queries (every prior write was `importPhotos`'s
  `INSERT`). Rating clamped to 0...5 in Swift before the query runs, not
  relying on any DB-side constraint.
- `Sources/UI/CatalogModel.swift`: `setRating(_:for:)`/`setFlagged(_:for:)`,
  mirroring `importFolder()`'s `Task.detached` + `refresh()` shape;
  failures swallowed via `try?` rather than surfaced as an alert (a rating
  tap is frequent/low-stakes — a proportionate, documented choice).
- `Sources/UI/LibraryGridView.swift`: a new `StarRatingRow` (5 tappable
  stars; tapping the current rating clears it to 0) and a flag `Button`,
  both below the filename — matching the app's existing "row of small
  tappable icons" style (aspect-preset list, Selective Color swatches).
  Confirmed live that clicking a star/flag does NOT also open the photo
  (standard SwiftUI `Button`-inside-`.onTapGesture` precedence, reviewer
  independently confirmed the reasoning, not just the live result).
- 5 new tests in `Tests/CatalogTests/CatalogDatabaseTests.swift`: default
  unrated/unflagged on import, rating round-trip, clamp-above-5,
  clamp-below-0, flag toggle both directions. All 254 tests pass (249
  prior + 5 new).
- Reviewer verdict: APPROVE on the first pass — see "Open reviewer
  issues" above for the one non-blocking note carried forward
  (display-ordering race on rapid repeated taps, not a persisted-data
  bug).
- 3 commits (migration + Photo fields + DB methods + their tests;
  CatalogModel methods; grid UI).

### Phase 4, Slice 4 — Collections (complete, verified live) — Phase 4 now COMPLETE
- Confirmed with the user up front: a left sidebar list of collections
  (the app's first `List`-based navigation) plus an "All Photos" row;
  assigning a photo via a per-cell menu button listing every collection
  with a membership checkmark; creating collections via a "New
  Collection…" row prompting for a name through a simple `.alert` +
  `TextField`. Explicitly OUT of scope: renaming/deleting collections,
  reordering, drag-and-drop, bulk operations, smart/dynamic collections,
  nested collections, folder→collection auto-mapping (the user separately
  asked about auto-collections mirroring their on-disk Year/Trip/Day
  folder structure — noted as a good idea for a FUTURE session, not this
  one, see "Exact next step" below).
- `Sources/Catalog/Migrations/003_collections.swift` (new): the most
  novel GRDB surface yet — creates TWO tables in one migration
  (`collection`, `collection_photo`) with a foreign-key relationship
  (`onDelete: .cascade` on both sides) and a composite primary key
  (`collectionId`, `photoId`) on the join table. Reviewer independently
  verified against the vendored GRDB source that `PRAGMA foreign_keys` is
  on by default and never overridden in `CatalogDatabase`, so cascade
  delete genuinely takes effect; also verified the empty-array edge case
  in the `IN`-clause query (`[].contains(...)` compiles to literal
  `false`, never "matches everything").
- `Sources/Catalog/PhotoCollection.swift` (new): named `PhotoCollection`,
  not `Collection` — this is a single Swift module (no per-directory
  targets), so a bare `struct Collection` would have shadowed
  `Swift.Collection` project-wide. `Sources/Catalog/CollectionPhoto.swift`
  (new): the join record, `PersistableRecord` not `MutablePersistableRecord`
  (no autoincrement column — the composite key is its whole identity).
- `Sources/Catalog/CatalogDatabase.swift`: `allCollections`,
  `createCollection`, `photos(inCollection:)` (a two-query join, both
  queries inside one `dbQueue.read` so they observe a consistent
  snapshot), `allMemberships`, `setMembership` (`insert(onConflict:
  .ignore)` makes re-adding an existing membership a no-op instead of a
  primary-key-violation error — the first use of GRDB's `onConflict` in
  this project).
- **A real bug caught by LIVE testing, not the reviewer**: the first
  `CatalogModel` implementation bound `selectedCollectionID: Int64?`
  (`nil` = "All Photos") directly to `List(selection:)`. The user found
  that after selecting a real collection, tapping back on the
  `nil`-tagged "All Photos" row silently failed to register — a known
  category of SwiftUI/AppKit `List(selection:)` quirk with
  `Optional`-typed selection bindings. Fixed by introducing
  `LibraryFilter` (a non-optional enum: `.allPhotos` /
  `.collection(Int64)`) so every sidebar row is tagged with a concrete,
  non-optional value; `CollectionSidebarView` exposes a computed
  `Binding<LibraryFilter?>` (List's API still requires an
  Optional-wrapped binding) that coerces the framework's "nothing
  selected" `nil` back to `.allPhotos` in its setter, without ever
  letting a real row be tagged `nil`. Re-verified live after the fix —
  selecting a collection, returning to All Photos, and re-selecting all
  now work correctly. Reviewer independently confirmed this is the sound,
  standard fix for this exact quirk category.
- `Sources/UI/CollectionSidebarView.swift` (new), `Sources/UI/LibraryGridView.swift`
  extended (a folder-badge `Menu` per cell), `Sources/UI/ContentView.swift`
  extended (`libraryContent`, a new `HSplitView` of sidebar + grid,
  mirroring `editorContent`'s own split shape).
- 6 new tests in `Tests/CatalogTests/CatalogDatabaseTests.swift`:
  create-assigns-id, order-by-name, add-to-collection (+ confirms
  `allPhotos()` stays unaffected), idempotent-add (exercises
  `onConflict: .ignore`), remove-from-collection, `allMemberships()`
  round-trip. All 260 tests pass (254 prior + 6 new).
- Reviewer verdict: APPROVE on the first pass. Two non-blocking notes
  carried forward — see "Open reviewer issues" above.
- Manually verified live end-to-end, including the List-selection bug
  fix, and a full quit/relaunch cycle confirming the collection and its
  membership persisted against the real, already-populated on-disk
  catalog (exercising migration `003`).
- 3 commits (migration + models + DB methods + their tests; CatalogModel
  state/methods + the `LibraryFilter` fix; sidebar view + per-cell menu +
  `ContentView` wiring).

**Phase 4 (Library) is now fully COMPLETE** — every item in CLAUDE.md's
roadmap line 4 shipped: import, catalog DB, thumbnail grid, ratings/
flags, collections.

### Folder-mirrored nested collections (complete, verified live) — user-requested follow-up, outside Phase 4's original scope
- The user, while verifying Collections, asked whether importing could
  auto-create a collection per on-disk folder (they organize photos as
  Year → Trip → Day) with a mirrored tree in the sidebar. Confirmed up
  front: a NEW, separate "Import Folder Tree…" action (the existing flat
  "Import Folder…" stays completely unchanged); a separate "Folders"
  sidebar section below the existing "Collections" section; idempotent
  re-import (matched by on-disk folder path, no duplicate branches).
  Explicitly OUT of scope: renaming/deleting folder collections,
  detecting folders/files removed on disk since import, nested submenus
  in the existing per-photo assignment menu.
- `Sources/Catalog/Migrations/004_folder_collections.swift` (new): adds
  `parentId`/`isFolder`/`folderPath` to the existing `collection` table —
  the project's first foreign key added via `ALTER TABLE` (every prior FK
  was only ever on `CREATE TABLE`) and first self-referencing one
  (`parentId` → `collection.id`). Reviewer verified against the actual
  vendored GRDB source (not just trusting it compiles) that this is a
  genuinely supported construct — the same column-SQL generator handles
  both `CREATE`/`ALTER` paths including the self-reference branch — and
  confirmed SQLite really does disallow a `UNIQUE` column via
  `ALTER TABLE ADD COLUMN` (the stated reason `folderPath` has no SQL
  `UNIQUE` constraint); idempotency instead comes from a check-then-insert
  inside one `dbQueue.write` transaction, which `DatabaseQueue` genuinely
  serializes (also verified, not assumed).
- `Sources/Catalog/PhotoImporter.swift`: the project's first recursive
  directory walk (`scanFolderTree`/`scanNode`), building a `FolderScanNode`
  tree that excludes any subfolder with no images anywhere in its own
  subtree (keeps the tree free of empty dead-end branches).
- `Sources/Catalog/CatalogDatabase.swift`: `importFolderTree` walks the
  whole tree — every folder-collection find-or-create, every photo
  insert-or-skip, every membership row — inside ONE transaction (reviewer
  confirmed the recursion never re-enters `dbQueue.write`, one real
  transaction for the whole tree). `importPhotos` was refactored
  (behavior-preserving, reviewer diffed old vs new) to share its
  insert-or-skip logic via a new `insertPhotoIfNeeded` helper, so a photo
  already imported flat gets correctly associated — not duplicated — the
  first time a tree import reaches it.
- `Sources/UI/CatalogModel.swift`: `importFolderTree()` mirrors
  `importFolder()`'s exact shape; the blocking recursive scan runs inside
  `Task.detached`, never on `@MainActor` (no repeat of the earlier
  `CatalogDatabase()`-on-main bug from Phase 4 slice 1).
- `Sources/UI/CollectionSidebarView.swift`: the app's first `OutlineGroup`
  — a client-side `FolderTreeNode`/`buildFolderTree` turns the flat
  `collections` array into a tree (grouped by `parentId`; `children`
  computed as `nil`, not empty, so `OutlineGroup` hides disclosure
  triangles on leaf folders), in a new "Folders" section below the
  unchanged "Collections" section. `Sources/UI/ContentView.swift`: one new
  "Import Folder Tree…" toolbar button.
- 9 new tests (4 `PhotoImporterTests` for `scanFolderTree` against real
  temp directories; 5 `CatalogDatabaseTests` for `importFolderTree`
  against hand-built `FolderScanNode` trees — nested `parentId` chain,
  direct-folder-only membership, idempotent re-import, picks up genuinely
  new photos, associates a previously-flat-imported photo). All 269 tests
  pass (260 prior + 9 new).
- Reviewer verdict: APPROVE on the first pass. Three non-blocking notes
  carried forward — see "Open reviewer issues" above.
- Manually verified live end-to-end with a real nested test tree (Year →
  Trip → Day1/Day2, one deliberately empty subfolder, 6 real photos):
  correct nested sidebar structure with the empty subfolder absent,
  clicking a nested folder or an ancestor-with-its-own-direct-photo both
  filter correctly, "All Photos" still works, re-running the import on
  the same folder created no duplicate branches, and a full quit/relaunch
  cycle confirmed the whole tree and its memberships persisted against
  the real, already-populated on-disk catalog (exercising migration
  `004`).
- 3 commits (migration + `PhotoImporter` + `CatalogDatabase` + their
  tests; `CatalogModel.importFolderTree()`; sidebar tree UI + toolbar
  button).

### Phase 5, Slice 1 — Batch export (complete, verified live) — Phase 5 STARTED
- Confirmed with the user up front: no new multi-select UI — exports the
  Library's currently-filtered set (`catalog.photos`, already exactly
  "all photos" or one Collection/Folder's members depending on the
  sidebar selection), with format (JPEG/PNG/TIFF)/quality/resize options
  and a live progress HUD. RAW support (Phase 6) was separately declined
  for this session — `CLAUDE.md` gates it "do not start early"; user
  chose Phase 5 first as planned.
- `Sources/Rendering/PhotoExporter.swift` (new): decode → EXIF-orient
  (`ImageDocumentModel.exifOrientation(of:)`, widened from `private` to
  `nonisolated static` for this reuse, mirroring `sidecarURL(for:)`'s
  existing treatment) → `EditPipeline.apply` → optional resize (never
  upscales, treats a non-positive max-long-edge as a no-op) → write.
  Deliberately never touches `ImageRenderer`/manual `MTLTexture`
  rendering — that type's own doc comment flags its "no y-flip" behavior
  as verified ONLY for the live `MTKView` drawable and explicitly warns
  Phase 5 export must independently re-verify, not assume, for an
  offscreen destination. `PhotoExporter` sidesteps that whole path via
  `CIContext.write*Representation` directly on the edited `CIImage` —
  visually confirmed live (correct orientation, edited look present),
  not just assumed safe because it avoids the landmine.
- 13 tests (`Tests/RenderingTests/PhotoExporterTests.swift`): resize,
  collision-suffix naming, sidecar `EditState` loading, end-to-end export
  for all three formats.
- **Extensive live debugging was required to get sandboxed writes
  working** — automated tests never exercised the real sandbox path
  (they write to the test bundle's own writable temp directory). In
  order: (1) a SwiftUI `.sheet`-dismiss vs. immediately-opening
  `NSOpenPanel` race made the destination picker appear but not respond
  to clicks — fixed by deferring the panel via `DispatchQueue.main.async`
  after `dismiss()`; (2) moved `startAccessingSecurityScopedResource()`
  onto the same execution context as the actual writes (a `Task.detached`,
  not `@MainActor`); (3) replaced `CIContext` writing directly to the
  security-scoped destination with writing to an app-writable temp file
  first, then `Data.write` into the real destination (matching
  `ImageDocumentModel.saveSidecarNow`'s own working write mechanism);
  (4) switched to a Metal-backed `CIContext` (built once) after a plain
  one reliably failed on real, full-size photos with an internal Core
  Image error despite passing fine against small synthetic test images;
  (5) round-tripped the destination through an actual security-scoped
  bookmark (`bookmarkData` → `URL(resolvingBookmarkData:...)`) rather
  than using the raw panel URL, mirroring
  `ImageDocumentModel.requestFolderAccess`'s pattern.
- **The actual root cause, found last**: `project.yml`'s sandbox
  entitlement was `com.apple.security.files.user-selected.read-only` —
  a hard sandbox-profile cap that made EVERY write fail with
  `NSCocoaErrorDomain Code=513` / `NSPOSIXErrorDomain "Operation not
  permitted"`, regardless of thread, write API, or destination folder
  (confirmed by testing multiple different folders, including ones
  outside the specially-TCC-protected Desktop/Documents/Downloads).
  Fixed by switching to `user-selected.read-write`. **This exact change
  was tried once before** (Phase 3, sidecar-persistence work) and broke
  the "Open…" picker's clickability at the time, never fully root-caused
  — reverted then. This time, the user explicitly re-tested "Open…"
  FIRST, before re-testing export, and confirmed no regression. Items
  (2)/(3)/(5) above were all added WHILE the entitlement bug was still
  present and only confirmed working together with the entitlement fix
  — their individual necessity now that the real cause is fixed was
  deliberately NOT re-isolated (reviewer explicitly agreed this is
  reasonable to ship as a "proven-together" combination, not a blocking
  concern), and the code comments say so plainly for future maintainers.
- **A real bug caught by the reviewer's first pass, fixed**: no
  re-entrancy guard on `ExportModel.runExport` — a second concurrent
  export could race the first on `uniqueDestinationURL`'s check-then-write,
  potentially silently overwriting a file mid-batch. Fixed with a
  `guard !isExporting` plus UI-level `.disabled(...)` on the toolbar
  button. **A second real bug, also fixed**: `resized(_:option:)` had no
  validation against a non-positive resize value — `0` produced a
  zero-extent image, a negative value silently mirrored the output at
  the wrong size, neither case threw. Fixed with a `maxLongEdge > 0`
  guard plus a UI-level clamp, both covered by new tests. Re-reviewed,
  APPROVED (one further non-blocking note, see "Open reviewer issues"
  above).
- Live verified end-to-end, extensively: options sheet + destination
  picker work; exported files show the EDITED look, not the original;
  orientation correct; re-exporting into the same folder produces
  `(2)`-suffixed files, never overwrites; PNG/TIFF both work; resize
  actually shrinks output dimensions; a Collection/Folder-filtered export
  limits correctly; the progress HUD displays/updates live during a real
  batch; macOS's own Downloads-folder TCC consent prompt (separate from
  the app's own sandbox entitlement) is normal, expected behavior, not a
  bug.
- 3 commits (entitlement fix + `exifOrientation` visibility; the
  `PhotoExporter` engine + tests; `ExportModel`/`ExportOptionsView`/
  `ContentView` wiring).
- **Two issues surfaced live during this verification that are
  EXPLICITLY NOT part of this slice, not fixed, and need their own
  future sessions**: (1) Library thumbnails don't reflect edits —
  `ThumbnailGenerator` reads straight from the source file via ImageIO,
  entirely bypassing `EditPipeline`/the sidecar; a real, by-design gap
  from Phase 4 slice 2, never wired up. (2) The Editor's on-screen
  rendering looks brighter/less vivid ("more faded") than the same photo
  in Preview.app — a color-management question in the core pipeline
  (`ImageRenderer`'s handling of the source image's own embedded color
  profile going into the linear working space), not export-specific.
  This is a real correctness concern that deserves its own careful,
  empirical investigation (matching how every other color-math question
  in this project has been handled), not a guess-fix.

### Phase 5, Slice 1 follow-up — Select individual photos for export (complete, verified live)
- The user asked for this immediately after batch export shipped.
  Confirmed up front: an always-visible small checkbox badge in the
  corner of every grid thumbnail (tapping it toggles selection; tapping
  elsewhere still opens the photo, unchanged — no selection "mode" to
  enter/exit); selection is a pure refinement on top of the existing
  filter-based export (non-empty selection overrides the sidebar filter,
  empty selection behaves exactly as before).
- `Sources/UI/CatalogModel.swift`: `selectedPhotoIDs` (pure in-memory
  `Set<Int64>`, no DB write — unlike every other mutator in this class)
  + `toggleSelection`/`isSelected`/`clearSelection`. `selectedFilter`'s
  existing `didSet` gained a `selectedPhotoIDs.removeAll()` so switching
  Collections/Folders always starts from a clean selection.
- `Sources/UI/LibraryGridView.swift`: a checkbox `Button` overlay on each
  thumbnail (dark circular backing + `circle`/`checkmark.circle.fill`),
  following the same already-proven "`Button` inside a parent
  `.onTapGesture`" pattern as the existing star row/flag/collection menu
  in the same cell.
- **A real bug caught by LIVE testing** (via a screenshot, not the
  reviewer): after adding `alignment: .topLeading` to the thumbnail
  `ZStack` (needed for the badge), the badge appeared at an inconsistent
  position on different photos. Root cause: the thumbnail `Image` used
  `.aspectRatio(contentMode: .fill)` with no `.frame` of its own, so it
  reported a different effective size to the ZStack depending on each
  photo's own native aspect ratio — invisible under the ZStack's old
  `.center` alignment, but exposed once alignment started mattering for
  the badge. Fixed by pinning the image's own `.frame(width:140,
  height:140)` before `.clipShape`, so every photo reports the same size
  regardless of its own dimensions. Reviewer independently confirmed
  this reasoning and the fix's correctness/placement.
- `Sources/UI/ContentView.swift`: `photosToExport` (empty selection →
  `catalog.photos` unchanged; non-empty → filtered to just the selected
  ones) replaces the 3 existing `catalog.photos` call sites in the
  export wiring. Toolbar button relabels to "Export Selected (N)…" with
  a "Clear Selection" button appearing alongside it. Zero changes to
  `ExportModel`/`PhotoExporter`/`ExportOptionsView` — `runExport(photos:)`
  was already fully subset-agnostic.
- No new tests — pure UI-glue state, matching this project's established
  precedent for `CatalogModel`'s other mutators. Reviewer agreed no
  coverage gap here.
- Reviewer verdict: APPROVE on the first pass. One non-blocking note
  carried forward — see "Open reviewer issues" above.
- Manually verified live end-to-end, including: checkbox badges
  consistently positioned after the fix; tapping the badge toggles
  selection and updates the toolbar; tapping elsewhere still opens the
  photo (confirmed with the user that opening a selected photo does NOT
  clear its — or any other photo's — selection, by design, since
  selection and single-photo-editing are intentionally orthogonal);
  "Export Selected…" exports only the checked photos; switching the
  sidebar filter clears selection; empty selection still exports the
  filtered set exactly as before.
- 2 commits (`CatalogModel` selection state; checkbox UI + the
  badge-position bug fix + `ContentView` wiring).

### Editor Adjust-tab sidebar restyle — Apple Photos look (complete, verified live)
- User shared a screenshot of Apple Photos' own Adjust panel and asked
  for a similar look. Scoped down via AskUserQuestion to VISUAL RESTYLE
  ONLY (icons, collapsible sections, "ADJUST" header, a "Reset
  Adjustments" button, disclosure chevrons) — explicitly deferred: the
  reference's per-section live mini-preview filmstrips (a real rendering
  feature), per-section "AUTO" buttons (needs a real auto-adjust
  algorithm), and per-section enable/disable toggle circles (new
  behavior). Zero `EditState`/`EditPipeline`/shader changes.
- `Sources/UI/ContentView.swift`: new `AdjustSectionContainer<Content:
  View>` wraps each of the 6 existing Adjust-tab sections (Light, Color,
  Selective Color, Black & White, Effects, Red-Eye) in a native
  `DisclosureGroup` with an icon+title header — the app's first use of
  `DisclosureGroup`, deliberately NOT touching `Slider` itself (this
  sidebar has a documented painful history, the "StableScrollInsets
  saga," of custom AppKit-adjacent interaction code silently breaking
  slider click/drag). Each section's inner rows kept their exact
  pre-existing bindings/ranges/identities/formats — only the outer shell
  changed. All 6 sections default COLLAPSED (`@State ... = false` each,
  one bool per section, matching this file's existing convention) per
  explicit user request mid-session, overriding the original plan's
  `true` default.
- `EditSliderRow`'s per-row Reset control changed from a text "Reset"
  button to an icon-only `arrow.uturn.backward` button (same
  `.disabled(value == identity)` behavior); a new
  `resetAdjustmentsButton` + `isAdjustTabAtIdentity` at the bottom of the
  tab reset every Light/Color/White-Balance/HSL/Selective-Color/
  B&W/Vignette/Definition/Sharpen/Noise-Reduction/Red-Eye field back to
  its identity in one action — deliberately excludes `redEyePoints` (has
  its own "Clear All" button) and every Crop-tab field (crop insets,
  straighten, perspective, flip — out of scope, has its own separate
  `resetCropTab()`).
- **A real, pre-existing bug re-surfaced by making sections
  collapsible, caught live by the user (not the reviewer)**: the
  Selective Color section's 8-swatch band-picker `HStack` (originally
  22pt circles / 10pt spacing ≈ 246pt) exceeded the sidebar's usable
  width at its 260pt minimum (~228pt after padding), forcing the whole
  sidebar wider whenever that section was expanded — invisible before
  sections could collapse/expand (nothing to compare width against).
  Fixed in two live-tested passes: first shrunk to 18pt/6pt (186pt) to
  stop the overflow; user then asked for the swatches bigger again, so
  settled on 22pt circles at the tighter 6pt spacing (218pt, still under
  the ~228pt usable width) plus `.frame(maxWidth: .infinity, alignment:
  .center)` to center the row (was left-aligned with dead trailing
  space).
- Reviewer APPROVE on first pass — independently confirmed every
  section's rows kept their exact original bindings (no transposition),
  the Reset Adjustments field list is complete and correctly excludes
  `redEyePoints`/Crop-tab fields, and the 218pt swatch-row arithmetic
  genuinely fits the sidebar's minimum width. One non-blocking nit
  (the new icon-only per-row Reset button had no `accessibilityLabel`,
  a minor VoiceOver regression from the old text button) — fixed before
  commit, not deferred.
- No new tests — pure UI restyling of already-bound/already-tested
  fields, matching this project's established precedent (the earlier
  "Adjust tab regrouping into labeled sections" restyle). 284/284 tests
  unchanged. 1 commit.

### Custom thin slider — Apple Photos look (complete, verified live)
- Immediate follow-up to the Adjust-tab sidebar restyle: the user pointed
  at the native macOS `Slider`'s chunky glossy 3D knob and said it didn't
  match the flat dark theme. Native `Slider` can't be restyled to remove
  that knob, so — confirmed via AskUserQuestion — went with a fully
  custom-drawn slider rather than a native tint-only tweak.
- NEW `Sources/UI/ThinSlider.swift`: `ThinSliderGeometry`, a pure
  SwiftUI-independent value↔pixel-mapping enum (mirrors the
  `CropAspectMath.swift` precedent for testable UI-layer math) —
  `fraction(of:in:)`/`value(atFraction:in:)` (clamped linear map) and
  `thumbCenterX`/`fraction(atX:)` (true inverses, both built from the
  same `usableSpan` term so they can't drift apart; NaN-safe on a
  zero-width value range or a track narrower than the thumb — e.g. a
  `GeometryReader` briefly reporting near-zero width before layout
  settles). `ThinSlider` itself: a `GeometryReader` + `DragGesture(
  minimumDistance: 0)` (so a plain click also seeks) drawing a thin flat
  track + small white capsule thumb, with the exact same
  `Binding<Double>`/`ClosedRange<Double>` public shape as the native
  `Slider(value:in:)` it replaces — so `EditSliderRow`
  (`ContentView.swift`) needed exactly ONE line changed, and all ~18
  existing Adjust/Crop rows kept working with zero call-site changes.
  Custom `accessibilityElement`/`accessibilityValue`/
  `accessibilityAdjustableAction` (arrow-key increment/decrement) since
  a hand-drawn control loses the native `Slider`'s built-in VoiceOver
  support otherwise.
- **Deliberately pure SwiftUI (`DragGesture`/`GeometryReader`), no
  AppKit interop, unlike the reverted "StableScrollInsets" regression**
  this exact sidebar has history with (see that section above) — that
  prior incident passed two reviewer passes AND the full test suite yet
  still broke all slider click/drag, caught only by live testing, via an
  `NSViewRepresentable` reaching into `NSScrollView` internals. This
  change's mechanism is structurally different and lower-risk (reviewer
  independently confirmed: macOS delivers trackpad/scroll-wheel scrolling
  as a separate `NSEvent` stream from mouse-drag, so there's no
  scroll-vs-drag arbitration happening the way there would be on iOS
  touch) — but per that lesson, this still got the same live hands-on
  drag/click/scroll verification before commit, not just review + tests.
- Thumb shape and fill color were tuned live, twice, from direct user
  feedback after seeing the first version rendered: thumb changed from a
  14pt white circle to a thinner 5×18pt white vertical bar/capsule ("too
  much of a blob"), and the filled-track color changed from the app's
  accent blue to white (a fully monochrome look, closer to the
  reference).
- Reviewer APPROVE — independently re-verified the `git diff` really is
  only the one-line `ContentView.swift` swap (not taken on faith),
  algebraically confirmed `thumbCenterX`/`fraction(atX:)` are true
  inverses, and reasoned through the scroll-gesture risk given this
  project's specific history rather than dismissing it. One non-blocking
  note — the new accessibility value/adjustable-action had no
  `.accessibilityLabel`, so VoiceOver would announce only a bare
  percentage with no indication of which slider — fixed before commit
  (`.accessibilityLabel(label)` at the `EditSliderRow` call site,
  mirroring how the per-row Reset button already does the same).
- NEW `Tests/EditEngineTests/ThinSliderGeometryTests.swift` (16 tests,
  mirrors `CropAspectMathTests`' structure) — endpoints/midpoint mapping,
  clamping in both directions, the inverse round-trip, and NaN-safety on
  both documented degenerate cases. No tests for the drawn view/gesture
  itself (UI-interaction code, not unit-testable here — consistent with
  every prior UI-only restyle, and exactly the category this project's
  own history says needs live testing instead).
- 300 tests total (16 new). 1 commit.

### Editor-vs-Preview color discrepancy — FIXED (complete, verified live)
- Long-standing deferred item (first surfaced live during Phase 5 batch
  export verification): the Editor's on-screen rendering looked visibly
  brighter and less saturated ("faded") than the same file in Preview.app,
  at identity edits — a genuine color-management bug, not a stylistic
  difference. Investigated per this project's empirical discipline: an
  Explore agent traced the FULL color path end to end (decode → pipeline →
  on-screen renderer → export, with exact file:line references), cross-
  checked directly by reading the same files myself.
- **Root cause**: decode (`ImageDocumentModel.load`, bare
  `CIImage(contentsOf:)`) is fully color-managed and identical between the
  on-screen and export paths — not the cause. `EditPipeline` never touches
  color SPACE (only the unrelated perceptual sRGB-gamma domain a few
  adjustments already use). The on-screen renderer
  (`Sources/Rendering/ImageRenderer.swift`) and the exporter
  (`Sources/Rendering/PhotoExporter.swift`) define BYTE-FOR-BYTE IDENTICAL
  working/output color spaces and both encode their final `CIContext` call
  into sRGB via `colorSpace: outputColorSpace`. The only real divergence:
  export writes to a FILE via `write*Representation(colorSpace:)`, which
  bakes an sRGB ICC tag into the file (Preview then color-manages it
  correctly); the on-screen path renders into an `.rgba16Float` `MTKView`
  drawable whose underlying `CAMetalLayer` was NEVER assigned a
  `colorspace` (confirmed via grep — none existed anywhere in the
  codebase). Float pixel formats have no `_sRGB` variant to imply that tag
  implicitly, so CoreAnimation presented the sRGB-gamma-encoded values
  without decoding them as sRGB — under-decoding lifts midtones and
  desaturates, exactly the observed symptom.
- **Fix**: `Sources/Rendering/ImageRenderer.swift`'s `outputColorSpace`
  widened from `private` to internal, so `Sources/Rendering/
  MetalImageView.swift`'s `makeNSView` can tag the presenting
  `CAMetalLayer` with the EXACT SAME `CGColorSpace` instance the renderer
  already encodes into (`(view.layer as? CAMetalLayer)?.colorspace =
  renderer.outputColorSpace`) — a single source of truth so the two can
  never drift apart. A debug-only `assert` (reviewer's suggestion) fires
  if the layer cast ever fails, so a future regression here is at least
  detectable rather than silently resurrecting the exact same "faded" bug
  with zero signal. No pixel math, working space, output encoding, or
  pipeline logic touched — purely a missing display-side color tag.
- No new tests — deliberate and justified: the fix changes only the
  drawable layer's color TAG, not any pixel value, so an offscreen
  readback would be byte-identical before and after; this is a
  live-compositor-only artifact, unreachable by this project's existing
  offscreen test infrastructure, same category as the y-flip and
  crop-tiling bugs `PROGRESS.md` already records as invisible to unit
  tests. 300 tests unchanged (all still pass).
- Reviewer independently re-derived the diagnosis (why an untagged float
  drawable under-decodes rather than over-decodes or no-ops), confirmed
  tagging the layer with the SAME color space used to encode is a single
  matched encode→decode pair (not a double-conversion — corroborated by
  the live result showing no over-darkening/over-saturation), verified
  `view.layer` is guaranteed a `CAMetalLayer` at that point in
  `makeNSView` (MTKView forces `wantsLayer`/`layerClass` at init,
  independent of window attachment), and confirmed no actor-isolation
  regression from widening `outputColorSpace`'s access level under Swift 6
  strict concurrency. APPROVE, one non-blocking suggestion (the debug
  assert above) adopted before commit.
- **Live-verified by the user** side-by-side against Preview.app on
  multiple photos (including a saturated one): brightness/saturation now
  match, no over-correction. Closes out this deferred item — see updated
  "Exact next step" below. 1 commit.

### Library thumbnails reflect edits — FIXED (complete, verified live)
- The other long-tracked deferred item from batch export's own
  verification: Library grid thumbnails always showed a photo's ORIGINAL
  pixels, even after real, saved edits — `ThumbnailGenerator` was pure
  ImageIO (`CGImageSourceCreateThumbnailAtIndex`), decoding straight to a
  small `CGImage` and never building a `CIImage`, so `EditPipeline` never
  ran; even if it had, `CatalogModel`'s `ThumbnailCache` actor had no
  invalidation, so a stale thumbnail would never refresh.
- `Sources/Rendering/ThumbnailGenerator.swift` gained a second overload,
  `thumbnail(for:maxPixelSize:editState:)`: reuses the EXISTING fast
  ImageIO thumbnail (already small, already EXIF-oriented) as
  `EditPipeline`'s input rather than a second full-res decode — correct
  because the pipeline's geometric stages (crop, straighten, vignette/
  sharpen radius) already derive from the image's own current extent, so
  they scale proportionally. `editState == .identity` (the common,
  unedited case) takes a fast path — byte-identical to the old behavior,
  zero extra cost. Renders via a new `CIContext` with the app's own
  `extendedLinearSRGB` working space and `RGBAh` format — matching
  `ImageRenderer`/`PhotoExporter`/`WhiteBalanceSolver` exactly, not a
  default/untagged context (a mistake the reviewer caught on the first
  pass — see below).
- `Sources/UI/CatalogModel.swift`'s `ThumbnailCache.thumbnail(for:)` now
  takes a `Photo` (was a bare path string) and loads its saved
  `EditState` via the already-existing `PhotoExporter.loadEditState(for:)`
  on a cache MISS only — a cache HIT still short-circuits before any
  sidecar read, so repeat-scroll performance is unchanged. New
  `invalidate(path:)` drops the cache entry; `CatalogModel` gained
  `invalidateThumbnail(for:)`.
- `Sources/UI/ImageDocumentModel.swift` gained `onSidecarSaved: ((URL) ->
  Void)?`, fired only after a REAL successful sidecar write (not a
  decline/skip/error). `Sources/UI/ContentView.swift` wires it to
  `catalog.invalidateThumbnail` — the two models are otherwise fully
  decoupled siblings, both owned by `PhotoAppApp`. Since
  `LibraryGridView` is torn down and freshly recreated on every
  Editor↔Library switch (a genuine `if/else` branch, confirmed directly,
  not assumed), each cell's `.task(id:)` naturally re-fires on return —
  so invalidating the cache on save, without any live-reactivity-while-
  visible machinery, is sufficient for the thumbnail to update by the
  next visit.
- **A real bug caught live by the user** (not the reviewer): editing a
  photo via Undo, then immediately switching to the Library, didn't
  update the thumbnail — had to do something else (like open another
  photo) first. Root cause: sidecar saves are debounced ~1s
  (`scheduleSidecarSave`); switching to Library didn't flush a pending
  save the way switching to a DIFFERENT photo already did (via the
  pre-existing `flushPendingSidecarSave()`, previously `private`). Fixed
  by widening that method's access and calling it from a new
  `.onChange(of: showLibrary)` handler in `ContentView` whenever the user
  leaves the Editor for the Library — confirmed fixed live afterward.
- **Reviewer's first pass was FIX FIRST — two real issues**: (1) the new
  `CIContext()` had zero options, omitting the working color space
  `EditPipeline`'s math actually needs — the doc comment's claim that
  this "mirrors `HistogramComputer`'s precedent" was backwards (Histogram
  never runs `EditPipeline`; `WhiteBalanceSolver`, which DOES run
  pipeline color math off-main in a small plain `CIContext`, was the
  correct, unfollowed precedent) — fixed by matching
  `ImageRenderer`/`PhotoExporter`/`WhiteBalanceSolver`'s
  `extendedLinearSRGB`/`RGBAh` exactly. (2) `ThumbnailCache.invalidate`'s
  `Task.cancel()` was purely cosmetic — the task body is a plain
  synchronous decode that never checks `Task.isCancelled` — so a slow
  decode started BEFORE an invalidation could still finish AFTER a newer
  one and silently overwrite the cache with stale data; fixed with a
  per-path monotonic generation counter (each request captures its
  generation before decoding, only touches shared cache/`inFlight` state
  on completion if nothing invalidated that path in the meantime). Both
  fixed, re-reviewed (reviewer hand-traced the exact race against both
  orderings), APPROVE.
- No new tests for the cache-invalidation/flush plumbing (actor/async
  UI-glue state, matching this project's established precedent for
  `CatalogModel`'s other mutators). 3 new tests extend the existing
  `ThumbnailGeneratorTests.swift` for the edit-aware overload (identity
  fast path, a structural `r==g==b` proof the pipeline genuinely ran via
  Black & White, nonexistent-file `nil`). 303 tests total. 1 commit.
- **Live-verified by the user**: editing then returning to Library shows
  the edit; unedited photos unaffected; Undo→immediate-switch now updates
  correctly after the flush fix; no scroll/performance regression
  reported. Closes out this deferred item.

### Compare mode — Side by Side + Split (before/after) (complete, verified live)
- User-requested new Editor feature: compare the original photo against
  the current edit, two ways — (1) both full images side by side, (2) one
  image area with a draggable divider (vertical or horizontal), original
  on one side. Both modes confirmed in scope via AskUserQuestion; a
  second AskUserQuestion confirmed the "original" semantics: KEEP the
  current crop/straighten/perspective/flip geometry, only reset
  color/tone — so both compared images always share one extent and align
  pixel-for-pixel (the user explicitly rejected "true original before any
  crop," which would have had mismatched framing whenever crop/straighten
  was active). A Plan agent, given this full context plus a prior Explore
  pass mapping the render architecture, produced the concrete design;
  independently verified against the actual pipeline code before
  implementation (see the red-eye finding below).
- `Sources/EditEngine/EditState.swift`: new `comparisonOriginal()` —
  resets every color/tone field to identity (the SAME field list
  `resetAdjustmentsButton`/`isAdjustTabAtIdentity` already use) while
  preserving every geometry field untouched. **Also clears
  `redEyePoints`** — a deliberate difference from `resetAdjustmentsButton`
  (which keeps points, has its own "Clear All" button), directly verified
  against `EditPipeline`: red-eye correction stays active whenever
  `redEyePoints` is non-empty AND `redEyeStrength != 0`, and the identity
  `redEyeStrength` (0.7) is non-zero — so merely resetting the slider
  would still show red-eye correction on the "original" side.
- NEW `Sources/UI/CompareLayout.swift`: `CompareViewMode`/
  `SplitOrientation`/`CompareRenderMode`/`CompareRenderConfig`, plus a
  pure `CompareLayout` enum (`sideBySideFitRects`, `splitRects`,
  `dividerFraction`) — mirrors the `CropAspectMath`/`ThinSliderGeometry`
  precedent for testable UI-layer geometry.
- `Sources/Rendering/ImageRenderer.swift`/`MetalImageView.swift`: gained
  an optional `CompareRenderConfig` (`nil` = off, the default). The
  existing single-image transform math was extracted into a private
  `fitted(_:into:)` helper so the off-path stays byte-identical to
  before, verified by the reviewer directly (not just "tests still
  pass"). Side by Side fits original/edited into independent left/right
  halves; Split shares ONE `fitRect` (both images have identical extent
  by construction) and crops each to its side. `MetalImageView`'s redraw
  guard widened to include `compare` (dragging the divider only changes
  one associated value, nothing else the old guard already watched).
- `Sources/UI/ContentView.swift`: new toolbar `Menu` (mode + orientation
  pickers), a new `CompareDividerOverlay` in the image pane's `ZStack`,
  and `compareOriginalEditState`/`compareRenderConfig` computed
  properties mirroring the pre-existing `displayEditState` presentation-
  substitution pattern. Mutually exclusive with crop-editing/WB-
  eyedropper/red-eye-placement in both directions (arming one disarms the
  others); resets to Off on tab-leave and new-photo-load.
- **Two real bugs, both caught live by the user, neither by the
  reviewer**: (1) **Horizontal split showed the wrong regions entirely**
  ("line doesn't split photo," "moving the line up moves the edited area
  down — opposite direction"). Root cause: `ImageRenderer`'s own `fitRect`
  has visual BOTTOM at `minY` (this app's pre-existing documented Metal
  "no y-flip" quirk — the CI image's bottom-left-origin/y-up convention
  passes straight through to the drawable, unflipped, and displays
  correctly) — the OPPOSITE of the SwiftUI overlay's `fitRect`, where
  visual TOP is at `minY`. This inversion only affects the y axis; x
  (vertical split) has no such inversion, and vertical was correct from
  the first pass. Fixed by inverting `position` and swapping which region
  is picked, for `.horizontal` only. (2) **The divider's grab-vs-click
  gesture worked for one orientation but not the other** — a plain click
  near the handle would make the line jump sideways before the drag even
  registered. First fix attempt (manual "how close to the line counts as
  a grab" distance bookkeeping in `@State`, decided once per gesture)
  didn't fully resolve it and the root cause wasn't pinned down. Replaced
  entirely with a different design: two separate hit-tested `ZStack`
  layers (a background for click-elsewhere-jump, under a wide invisible
  grab strip for smooth delta-tracked dragging) so SwiftUI's own
  hit-testing routes the gesture, rather than custom disambiguation
  logic — confirmed working for both orientations afterward.
- NEW `Tests/EditEngineTests/CompareLayoutTests.swift` (12 tests) +
  `EditStateComparisonOriginalTests.swift` (4 tests, including one that
  runs the real `EditPipeline` to confirm `comparisonOriginal()` and the
  edited state produce the SAME extent — the invariant the whole
  single-`fitRect` design rests on). No tests for the divider
  gesture/toolbar itself — UI-interaction-only, relies on live
  verification, consistent with this project's established precedent
  (the crop drag, the WB tap).
- Reviewer APPROVE on first pass — independently re-derived the y-axis
  coordinate math from the stated coordinate-space facts (not just
  trusting the live-test outcome) and the red-eye field-clearing
  requirement against the actual `EditPipeline` code, confirmed the
  off-path is genuinely byte-identical, and confirmed the mutual-
  exclusion state machine has no gap. Two non-blocking style nits, no
  fix-first needed.
- 319 tests total (16 new). 1 commit.

### Zoom and pan — Editor + Compare (complete, verified live)
- User-requested: scroll wheel/trackpad scroll to zoom (centered on the
  cursor), click-drag to pan once zoomed — confirmed via two rounds of
  AskUserQuestion (scroll not pinch; click-drag not two-finger-scroll for
  pan). Must work in the normal Adjust view AND both Compare modes.
  Scoping decision (mirrors Compare mode's own precedent, not re-asked):
  unavailable during Crop/WB-eyedropper/red-eye-placement — those
  overlays are positioned against `currentFitRect`, which assumes no
  zoom/pan.
- NEW `Sources/UI/ZoomPanGeometry.swift`: pure, unit-tested geometry
  (`CompareLayout`/`CropAspectMath` precedent) — `steppedZoom` (
  multiplicative, clamped 1...8), `panForZoomAboutCursor` (the
  cursor-centered-zoom formula, `p' = (f-0.5)*(1-r) + r*p`, derived from
  requiring the content point under the cursor to map back to the same
  screen fraction after a zoom change — independently re-derived by both
  the orchestrating session and the reviewer before shipping), `clampedPan`
  (derived from requiring the zoomed content to always fully cover the fit
  rect: `p ∈ [-(z-1)/2, (z-1)/2]`), `cursorFractionInFitRect` (NaN-safe on
  degenerate input). Everything normalized to the fit rect, SwiftUI y-DOWN
  throughout — the y-axis flip to this app's renderer-space convention
  happens in exactly ONE place (`ImageRenderer.fitted`), nowhere else.
- `Sources/Rendering/ImageRenderer.swift`: the shared `fitted(_:into:)`
  transform helper (already extracted during Compare mode) widened to
  `fitted(_:into:zoomScale:panOffsetNorm:)` with both new params defaulted
  — every pre-existing call site behaves byte-identically (verified by
  both the orchestrating session and the reviewer: at the defaults,
  `zoomedMinX`/`zoomedMinY` reduce to exactly `fitRect.minX`/`fitRect.minY`).
  All three render paths (off/sideBySide/split) thread `zoomScale`/
  `panOffset` through; Side by Side passes the SAME values into both
  halves (pan is normalized to each congruent rect's own dimensions, so
  this alone syncs "same detail on both sides" with no extra code); Split
  shares one `fitRect` for both images, with the divider's own crop region
  still derived from the UN-zoomed `fitRect` so the seam stays fixed on
  screen while content zooms underneath it. Still one `ciContext.render(...)`
  call, one color space.
- `Sources/Rendering/MetalImageView.swift`: `ResizingMTKView` (the private
  `MTKView` subclass) installs an `NSEvent.addLocalMonitorForEvents(
  matching: .scrollWheel)` in `viewDidMoveToWindow()` — deliberately NOT a
  `scrollWheel(with:)` override, because in Compare's Split mode
  `CompareDividerOverlay`'s full-area background sits on top of the MTKView
  in the same `ZStack`, so an unhandled override would never even reach
  this view (SwiftUI's own responder chain routes it elsewhere first); a
  local monitor intercepts the event BEFORE that dispatch, immune to
  overlay stacking. Guards against consuming scroll events meant for other
  UI (`event.window === window`, `bounds.contains(pointInView)`, falls
  through via `return event` otherwise — reviewer confirmed this can never
  swallow the sidebar's/Library grid's own scrolling). **Swift 6
  concurrency**: `scrollMonitor`'s token marked `nonisolated(unsafe)` so
  `deinit` (always `nonisolated`) can remove it — a real compile error was
  hit first (wrapping the closure body in `MainActor.assumeIsolated`
  failed because `NSEvent` is explicitly non-`Sendable`); removing that
  wrapper and accessing `self` directly compiled clean, confirming
  `NSView` subclasses are already implicitly `@MainActor`-isolated here.
  `updateNSView`'s redraw guard widened to include `zoomScale`/`panOffset`
  (the same lesson already learned once for `compare`).
- NEW `Sources/UI/PanOverlay.swift`: click-drag-to-pan, structured like
  `CompareDividerOverlay`'s grab strip (start-snapshot delta drag); also a
  double-tap to reset zoom/pan to identity. In Side by Side, two instances
  (one per half) both bound to the same `$zoomScale`/`$panOffset` so
  dragging either photo pans both in sync.
- `Sources/UI/ContentView.swift`: `canZoom` (Compare active does NOT block
  zoom); `sideBySideFitRects`/`handleScrollZoom` (converts the scroll
  monitor's pane-relative cursor fraction into the correct fit-rect-relative
  fraction, picking the right half in Side by Side); resets to identity on
  new-photo-load, leaving Adjust, arming WB/red-eye, and a new
  `.onChange(of: compareMode)` (a mode switch gets a fresh zoom/pan, since
  the fit-rect geometry differs between modes). A small "N%" HUD
  (`zoomPercentageHUD`, styled like the pre-existing export-progress HUD)
  added per a live follow-up request, shown only while zoomed past fit.
- **A real bug caught live by the user** (not the reviewer): Side by Side
  didn't crop each fitted image to its own half — harmless at `zoomScale
  == 1` (exact fit, no overflow) but once zoomed past 1 the fitted image
  became larger than its half-rect and bled into the neighboring half,
  where — composited on top — it visually covered that side entirely
  ("one side enlarges and takes over the other"). Fixed by cropping each
  side to its own rect before compositing; reviewer independently
  confirmed the fix is complete for any zoom/pan combination.
- Reviewer APPROVE on first pass — independently re-derived both
  `ZoomPanGeometry` formulas and the y-axis flip from first principles,
  confirmed the widened `fitted(_:into:)`'s byte-identity at defaults,
  confirmed the crop-bleed fix's completeness, verified `MTKView`/`NSView`
  are genuinely unflipped (not assumed), traced every mutual-exclusion
  path for dangling zoom state, and confirmed the build actually compiles
  clean under this project's real Swift 6 strict-concurrency settings (not
  just "stopped complaining" from an earlier failed attempt). One
  non-blocking note: `handleScrollZoom` runs a full `EditPipeline.apply`
  on every scroll tick in Side by Side to compute `sideBySideFitRects` —
  likely cheap (Core Image builds a lazy graph, doesn't render), but worth
  a live perf check on a large image if scrolling ever feels janky there.
- 337 tests total (18 new). 1 commit.

### Library sort/filter/search (complete, verified live) — Library polish, slice 1
- Scoped down (AskUserQuestion) from the broader "Library polish" backlog
  item to just sort/filter/search this session — removing photos,
  detecting missing files, and renaming/deleting collections are still
  explicitly deferred (not started).
- NEW `Sources/Catalog/LibraryFilterSort.swift`: `LibrarySortOption`
  (`.dateOldest` default/`.dateNewest`/`.ratingHighToLow`/`.nameAZ`) +
  pure `LibraryFilterSort.apply(to:sort:minimumRating:flaggedOnly:
  searchText:)`. **Design decision, reviewer-confirmed sound**: entirely
  in-memory (a view-level refinement over the already-loaded `photos`
  array), NOT a new DB query — a personal library is at most a few
  thousand rows already fully materialized, so this avoids what would
  have been this codebase's first GRDB `LIKE` query and a DB round-trip
  per keystroke, and composes on top of the pre-existing `selectedFilter`
  (Collection/Folder) source-set selector without touching it or
  `refresh()`. `.dateOldest` default deliberately matches
  `CatalogDatabase.allPhotos()`/`photos(inCollection:)`'s existing
  `ORDER BY importedAt, id` ascending exactly (reviewer verified: `Array.
  sort()`'s stability since Swift 5 plus the DB's own tie-break makes
  this functionally identical) — nothing changes for anyone not touching
  the new controls. Minimum rating is a threshold ("N+ stars"), not exact
  match; name sort uses `localizedStandardCompare` for Finder-style
  natural numeric ordering ("Photo 2" before "Photo 10").
- `Sources/UI/CatalogModel.swift`: 4 new `@Published` fields
  (`sortOption`, `minimumRating`, `flaggedOnly`, `searchText`,
  deliberately NOT reset on Collection/Folder switch — persists while
  browsing) and a computed `displayedPhotos` applying the filter fresh on
  every access (reviewer flagged, non-blocking: this means ANY unrelated
  `@Published` mutation — e.g. a rating change's `refresh()` — also
  re-filters the whole array, and it's read twice per `LibraryGridView`
  body pass; cheap enough at this project's target scale, not worth
  memoizing yet). New `clearLibraryFilters()`.
- `Sources/UI/LibraryGridView.swift`: `ForEach(catalog.photos)` →
  `ForEach(catalog.displayedPhotos)`; new filter bar (sort/rating
  pickers, flag toggle, search field) above the grid. **Two distinct
  empty states, reviewer-verified no gap**: true-empty library (the
  pre-existing "Import Folder…" state, byte-unchanged) vs. photos
  existing but none matching the current filter (new "No photos match" +
  "Clear Filters" button).
- **Two live-caught follow-up fixes** (not in the original plan): after
  shipping, the user reported a noticeable delay before thumbnails
  reappeared after re-sorting — `LazyVGrid` only keeps a limited window
  of cells instantiated, so re-sorting scrambles which photos land in
  that window, and previously off-screen/evicted photos need a fresh
  decode. Fixed with two remediations together: `ThumbnailCache`'s
  `totalCostLimit` bumped from 64MB (~270 thumbnails) to 256MB (~1165,
  reviewer verified the arithmetic and that 256MB is a reasonable
  commitment), and a small `ProgressView` added to the loading
  placeholder (reviewer confirmed it reports the same fixed 140×140 size
  as the loaded image, so it does NOT reintroduce the documented
  `.aspectRatio(contentMode:.fill)`-reports-native-size bug that shaped
  this same cell's sizing before). User confirmed this "seems better."
- Reviewer APPROVE on first pass — independently verified the DB-order-
  match claim against the actual `CatalogDatabase` code, spot-checked the
  filter/sort logic, confirmed the two-empty-states logic has no gap, and
  confirmed the `ProgressView` addition's sizing is safe. Two
  non-blocking, cosmetic-only notes (tie-break ordering undocumented;
  `displayedPhotos` evaluated twice per body pass), neither requiring a
  fix.
- 350 tests total (13 new). 1 commit.

## In progress / blocked
Nothing blocked. Nice-to-have not yet eyeballed (low risk, not required):
window-resize re-fit behavior, opened-file mtime check. Non-blocking
reviewer note from zoom/pan: `handleScrollZoom`'s Side-by-Side path
recomputes `EditPipeline.apply` per scroll tick — worth a live perf check
on a large image if Side-by-Side scrolling ever feels janky (see its own
section above for detail). Non-blocking reviewer notes from Library sort/
filter/search: `dateNewest`/`ratingHighToLow` tie-break ordering is an
undocumented stable-sort artifact (harmless); `displayedPhotos` recomputes
on every access, including from unrelated `@Published` mutations, cheap at
this project's target scale but not memoized.

### ThumbnailCache test coverage + a DISPROVED performance theory (complete)

Triggered by `IMPROVEMENTS.md` (a codebase-wide improvement review written
2026-08-28, repo root), item P1: the claim that `ThumbnailCache`'s decode
`Task { }`, created inside an actor-isolated method, inherits that isolation
via `@_inheritActorContext` and so holds the actor's serial executor for the
whole decode — serializing all thumbnail decoding AND stalling cache hits.
The theory was argued from the code, then re-confirmed by a second analytical
review pass. **It is false, and the measurements retired it.**

- Wrote `Tests/RenderingTests/ThumbnailCacheTests.swift` (7 tests) and used it
  to measure: 8 concurrent decodes vs the same 8 sequential ran at **ratio
  0.32 — already ~3x parallel**. Rewriting to `Task.detached` measured **0.32
  too, i.e. no change at all**. A cache HIT issued while 8 large decodes were
  in flight returned in **0.0 ms**, disproving the second half as well.
- **Production behavior therefore left UNCHANGED** — the `Task.detached`
  rewrite was reverted; the executable code in `ThumbnailCache` is
  byte-identical to what it was, verified by a comments-stripped diff against
  `HEAD`. `Task.detached` would also have dropped priority/task-local
  propagation, a downgrade for zero measured gain.
- What DID ship: (1) `ThumbnailCache` extracted from the bottom of
  `CatalogModel.swift` into `Sources/UI/ThumbnailCache.swift` and widened
  `private` → internal so tests can reach it (the same
  private→internal-for-testability precedent `PhotoExporter.resized`
  documents); `CatalogModel.swift` drops 535 → 442 lines. (2) The 7 tests —
  this type had ZERO coverage despite owning the Library's subtlest
  concurrency logic, including the reviewer-caught generation counter.
  (3) A doc comment on `thumbnail(for:)` recording the measurement so the
  theory can't be independently rediscovered and re-implemented.
- **A flaky assertion of our own making, caught only by the FULL suite:** two
  tests originally asserted a re-request returns the identical `CGImage`
  instance. They passed in isolation but failed in a full-suite run — other
  tests' memory pressure evicts `NSCache` entries, and `NSCache` guarantees
  no residency at all, so re-decoding there is correct behavior. Rewritten to
  assert equivalence (dimensions) instead, with the reasoning recorded in the
  test file. A reminder that running one test file green is not the same as
  running the suite green.
- 357 tests (7 new), 0 failures, stable across 3 consecutive full-suite runs
  (ratio 0.25–0.32 each time).
- Lesson, and the reason this section exists at all: P1 was derived by reading
  code and reasoning about Swift concurrency semantics, and survived a review
  pass, and was still wrong. This project's existing "verify empirically,
  don't assume" pattern (recorded below as hit six times across Phase 2)
  extends to performance claims. `IMPROVEMENTS.md`'s remaining items P3/P4/P5
  assert *structural* facts that are true by inspection — but a real
  structural inefficiency still does not prove a fix is measurably faster.

### Library tap mutators update in place (complete) — IMPROVEMENTS.md P4

Every star tap, flag toggle, and membership toggle used to run
`Task.detached { write; await refresh() }`, and `refresh()` re-read the ENTIRE
catalog — `photoCount`, `allCollections`, `allMemberships`, `allPhotos` — to
learn one changed field. Three of those four reads cannot change as a result of
a star tap.

**MEASURED FIRST, before any production change** (deliberately, after P1 — see
the section above — proved that a structurally real inefficiency can still be
worth nothing). Timed against an ON-DISK catalog, the four queries alone:
**6.45 ms per tap at 1,000 photos, 30.37 ms at 5,000**, scaling linearly, on
top of which the wholesale `photos` republish re-rendered the grid. At 5,000
photos that is roughly two dropped frames per tap, so unlike P1 this one was
worth doing on performance grounds as well as correctness.

- **Fixes the documented Phase 4 slice 3 bug** (rapid repeated taps transiently
  showing a stale rating), which was also deferred option (6). Root cause: each
  tap's independent `refresh()` could publish an OLDER snapshot after a newer
  one. The mutators now update local state synchronously on `@MainActor`, so
  taps land in tap order by construction, then write to the database.
- `updatePhotoInPlace(id:_:)` is the shared helper. `setRating` mirrors
  `CatalogDatabase.setRating`'s 0...5 clamp — a deliberate duplication that must
  stay in sync, since the UI no longer learns the stored value by re-reading.
- **Genuine behavior change:** a failed write is no longer swallowed (`try?`).
  With the local update applied first, silence would leave the grid showing a
  value the catalog never accepted, so the failure path now falls back to a full
  `refresh()`, resyncing from the database as the authority — the old behavior,
  now reserved for the rare case that needs it.
- **Ghost-cell case handled:** while the sidebar is filtered to a collection,
  `photos` IS that collection's membership list, so removing a photo must drop
  it from `photos` too, not just from `membershipsByPhotoID`. Re-adding while
  that same filter is active still calls `refresh()`, since only a re-read knows
  the correct sort position (and that direction is unreachable from the UI
  anyway — every visible cell is already a member).
- `refresh()` is untouched and still used where a full reload is genuinely
  required: `init`, both imports, `createCollection`, and the `selectedFilter`
  `didSet`.
- **New testing seam:** `CatalogModel.init(database:)` takes an already-open
  catalog and skips `activateKnownFolders()` (which touches `UserDefaults` and
  real sandbox scopes). `CatalogModel` previously had ZERO tests; it now has 7,
  and **each was verified to FAIL against the old implementation** before being
  accepted — the rating tests and both membership tests were run against the
  reverted code and did fail, so they are real regression tests rather than
  tests that merely pass.
- **KNOWN LIMITATION, pre-existing and unchanged:** the database writes are
  still independent `Task.detached` calls, so two very rapid taps could still
  reach GRDB's write queue out of order and persist the older value. The
  DISPLAY bug is fixed; this narrower write-ordering window is not, and would
  need per-photo write serialization. `testRapidRepeatedRatingTapsShowTheLastValue`
  deliberately asserts only the displayed value for this reason. Note the
  reviewer observed this is the same persisted-data window as before, but now
  HIDDEN rather than shown: the display follows the last tap even if the
  database kept an older value, which surfaces only on relaunch.
- **Two non-blocking reviewer notes carried forward** (neither gated the
  commit): (1) the failure-path `refresh()` can itself race a SUBSEQUENT tap —
  if tap1's write fails and its resync reads before tap2's write commits, the
  republished snapshot omits tap2 and nothing republishes afterward, leaving a
  stale display until the next full refresh. Needs a write failure overlapping
  a tap, so it is rare, and the fix is the same per-photo write serialization
  the limitation above needs — address them together. (2) The in-place removal
  leaves the photo's ID in `selectedPhotoIDs`, so the "Export Selected (N)"
  count can over-count ghosts; pre-existing (the old `refresh()` behaved
  identically) and harmless to the actual exported set, since
  `ContentView.photosToExport` intersects with `photos`.
- 364 tests (7 new), 0 failures, stable across 3 consecutive full-suite runs.

### ContentView split into Adjust/Crop/chrome views (complete, verified live 2026-08-28) — IMPROVEMENTS.md D7

Pure, behavior-preserving refactor. `Sources/UI/ContentView.swift` went from
1352 lines to **766**, with four new files beside it in `Sources/UI/`:
`AdjustTabView.swift` (482 — the six collapsible sections, "Reset
Adjustments", `isAdjustTabAtIdentity`, the three selective-color binding
dispatchers, and `AdjustSectionContainer`), `CropTabView.swift` (88 —
straighten/perspective/flip, the Aspect list, the four crop-inset sliders),
`EditorChromeViews.swift` (54 — `ZoomPercentageHUD`, `ExportProgressHUD`,
`PlaceholderTab`), and `EditControlRows.swift` (48 — `EditSliderRow` and
`EditToggleRow`, now internal since both tabs use them). `ContentView` stays
the coordinator: tab/library state, viewport state, crop-aspect math,
`body`/`mainContent`/`libraryContent`/`editorContent`/`editControls`.

`IMPROVEMENTS.md` asked for this BEFORE D1–D4, since all of those touch
`ContentView`. (That item gave the path as `Sources/App/ContentView.swift`;
it has always been `Sources/UI/` — a reminder that its claims need checking,
which is what its own working agreement 5 says.)

- **The one non-obvious constraint, and the real regression risk.** The Adjust
  tab's eight presentation-only states (6 section-expansion bools,
  `histogramDisplayMode`, `selectedSelectiveColorBand`) CANNOT be moved into
  `AdjustTabView` as its own `@State`. `editControls` picks the tab body with a
  `switch`, so the Adjust subtree is destroyed on every switch to Crop —
  child-owned `@State` would re-collapse every section, reset the histogram
  picker to Luminance and the band to Red on each round-trip. They are grouped
  into a new `AdjustPanelState` struct that `ContentView` still owns as one
  `@State`, passed down as a single `@Binding`.
- `isPickingWhiteBalance`/`isPlacingRedEyeCorrections` stay `@Binding`:
  `canZoom`, the WB/red-eye tap overlays, the photo-change reset, the
  library-toggle reset and the crop-arming mutual exclusion all still read or
  write them from `ContentView`.
- The compare/zoom/pan triple the two point-picking buttons performed inline
  (`compareMode = .off; zoomScale = 1; panOffset = .zero`) is now an
  `onEnterPointPickingMode` callback supplied by `ContentView`, so the panel
  doesn't take bindings to three unrelated viewport states. Order is unchanged.
- Crop's aspect math (`effectiveAspectRatio`, `selectAspect`, `resetCropTab`)
  deliberately stayed in `ContentView` — it needs `currentFitRect`/
  `containerSize`, and `editorContent` reads `effectiveAspectRatio` for the
  on-image overlay. `CropTabView` gets `selectedAspect` by value plus
  `onSelectAspect`/`onReset` closures.
- Verified as a pure move by diffing each new file against the exact
  pre-change line ranges: the ONLY differences are the intended transforms
  (`adjustTabContent`/`cropTabContent` → `body`, the eight states re-rooted
  through `panel.`, the triple → callback, the two crop closures, `private` →
  internal on the two shared rows). No dropped modifier, no changed
  range/identity/format string, no reordered statement, no lost comment.
- No `project.yml` change needed (it globs `path: Sources`); `xcodegen
  generate` picks the new files up.
- Build clean, **364 tests, 0 failures**. Reviewer **APPROVE**, with one
  non-blocking note: one struct binding instead of eight coarsens SwiftUI
  invalidation granularity — an invalidation-scope change only, no observable
  behavior difference at this panel's scale.
- **Verified live 2026-08-28** (a later session, via Accessibility-driven UI
  automation once Screen Recording/Accessibility permission was granted):
  expanded Light and Selective Color, set the histogram picker to RGB,
  selected a non-Red Selective Color band (Purple), switched to Crop and
  back to Adjust — all four persisted exactly as `AdjustPanelState` is
  designed to guarantee. `Filters` tab's placeholder text also confirmed
  live. WB-eyedropper/Red-eye-button Compare-clearing, Crop aspect-preset
  reshaping, and Crop's own Reset button were NOT exercised this pass
  (scope cut for time, not a failure) — still open if this checklist is
  revisited.

### Previous/Next photo — ⌘←/⌘→ (complete, verified live 2026-08-28) — IMPROVEMENTS.md D1(a)

`IMPROVEMENTS.md` called D1 the biggest UX gap: editing a second photo meant
toolbar → Library → click the next thumbnail. A new `CommandMenu("Photo")` in
`PhotoAppApp` adds "Previous Photo" (⌘←) and "Next Photo" (⌘→).

- **Order is `CatalogModel.displayedPhotos`**, the post-sort/filter/search list
  the grid itself renders — ⌘→ goes to the photo the user would SEE next, not
  to a hidden catalog order.
- **Decisions taken and documented in code** (D1 asked for them explicitly): no
  wraparound at either end (matching Photos/Lightroom — the items just
  disable); both items disable when the open photo isn't in `displayedPhotos`
  at all (filtered out, or the sidebar moved to another collection) rather than
  guessing a position; and both disable while the Library grid is showing,
  since this is EDITOR navigation.
- **Reuses `ImageDocumentModel.load(from:)`** rather than a parallel load path,
  exactly as `IMPROVEMENTS.md` instructed. That method already flushes the
  OUTGOING photo's still-debounced sidecar save (while `currentURL`/`editState`
  still belong to it, so A's edits land in A's sidecar), restores the incoming
  photo's edits, and calls `resetHistory()` so undo can't reach across photos.
  Reviewer traced the A→B→A round-trip and confirmed no edit loss and no
  cross-photo sidecar write, including mid-debounce.
- New `Sources/Catalog/LibraryNavigation.swift` — pure
  `neighbor(of:in:offset:)`, placed beside `LibraryFilterSort` for the same
  stated reason (pure logic extracted so it gets direct unit tests), with 10
  tests in `Tests/CatalogTests/LibraryNavigationTests.swift`.
- `ImageDocumentModel.currentURL` is now `@Published` (`private(set)`
  unchanged, `load(from:)` still the only writer) so the menu items can locate
  the open photo and track their enabled state — the same reason
  `canUndo`/`canRedo` are published for the Edit menu.
- `showLibrary` lifted from `ContentView` `@State` to `PhotoAppApp` `@State`
  passed as a `@Binding` — the same lift, for the same reason, that `document`
  and `catalog` already had: a Scene-level command can't read a view's private
  state.
- **Rider fix.** `ContentView`'s photo-change reset keyed on
  `document.currentFileName`, so two photos in different folders sharing a
  filename silently skipped the whole reset (tab, aspect lock, point-picking,
  compare, zoom/pan). Prev/next makes that easy to reach — the Name (A–Z) sort
  puts identical filenames adjacent — so it now keys on `currentURL`.

**Perf, measured before shipping rather than after.** The menu's enabled state
depends on `displayedPhotos`, a full filter+sort, and the Scene body
re-evaluates on every `document.editState` publish — i.e. every slider tick
while editing. Measured `LibraryFilterSort.apply`: **0.37 ms at 1,000 photos,
3.61 ms at 10,000, 18.50 ms at 50,000**. The naive shape (one `.disabled` per
item) would pay that TWICE per tick, so both neighbours now resolve from ONE
pass per body evaluation (`PhotoAppApp.photoNeighbors`), behind cheap
disqualifiers so "no photo open" and "browsing the grid" never touch the sort at
all. This is the first thing to put real main-thread pressure on that computed
property; `IMPROVEMENTS.md` P6's cached-`displayedPhotos` fix now has a measured
case behind it at 10,000+ photos, though it stays unjustified at this project's
current scale.

- Build clean, **374 tests (10 new), 0 failures**. Reviewer **APPROVE**, having
  traced the sidecar flush ordering, the `currentURL` publish (no widened write
  path, no feedback loop), the `showLibrary` lift (all five uses identical), and
  the captured-`neighbors` binding (self-consistent; worst case re-opens the
  same photo, which is safe and already reachable via a grid tap).
- One reviewer note was a real doc error and was FIXED before commit:
  `LibraryNavigation`'s comment claimed `currentURL` only ever comes from
  `URL(fileURLWithPath: photo.path)`. It doesn't — `openImage()`'s `NSOpenPanel`
  URL also feeds `load(from:)`, and a panel URL can normalize differently
  (`/tmp` vs `/private/tmp`). The comment now states the real behavior: such a
  photo simply won't match, degrading to "both commands disabled", never to a
  wrong jump.
- Two other reviewer notes left as-is, both non-blocking and pre-existing:
  `showLibrary` is App-level so it is shared across ⌘N windows (as `document`
  and `catalog` already were — same bounded single-window assumption), and a
  same-URL early return in `load(from:)` would be cheap hardening against rapid
  repeated ⌘→ resetting the re-opened photo's undo history.
- **Verified live 2026-08-28**, same session as the D7 live pass. Walked a
  small 3-photo test set with ⌘→/⌘← (grid order matched navigation order:
  Profile→IMG_1691→ATM_0662). **The case that actually matters, confirmed**:
  set Exposure to +1.81 EV on photo A, ⌘→ to B (Exposure read back as
  +0.00 EV — untouched), ⌘← back to A (Exposure still +1.81 EV, and the
  render visibly brightened once the frame caught up — the edit is real,
  not just a stale slider readout). ⌘Z on A back at rest immediately
  afterward was a no-op (nothing left to undo) — consistent with
  `resetHistory()` firing on the photo reload, i.e. undo genuinely cannot
  reach across the round-trip. `Previous Photo` confirmed disabled
  (greyed) at the first photo in the list. NOT exercised this pass: sort/
  rating-filter reordering navigation, filtering the open photo out of
  view, disabling while the Library grid is showing, and the
  zoom/Compare/Crop-tab reset behavior on navigate — still open if this
  checklist is revisited.

### Bottom filmstrip in the Editor (complete, verified live 2026-08-28) — IMPROVEMENTS.md D1(b)

The cheaper half of D1, now that D1(a) settled the navigation-order and
load-path questions. New `Sources/UI/EditorFilmstripView.swift`:
`EditorFilmstripView` (a `ScrollViewReader` + horizontal `ScrollView`/
`LazyHStack` over `catalog.displayedPhotos` — the same sort/filter/search-
respecting array D1(a) and the Library grid already use) and a private
`FilmstripCell` (a compact 56×56 thumbnail, no rating/flag/filename —
those stay Library-grid-only concerns). Cells fetch through the exact
same `catalog.thumbnail(for:)` path `LibraryThumbnailCell`
(`LibraryGridView.swift`) uses, sharing its `ThumbnailCache` actor, and
repeat that cell's documented load-bearing `.frame` BEFORE `.clipShape`
ordering. Tapping a cell calls the exact same
`document.load(from: URL(fileURLWithPath: photo.path))`
`libraryContent`'s onTap and `PhotoAppApp.open(_:)` already call, so the
existing `.onChange(of: document.currentURL)` reset (tab, crop aspect,
WB/red-eye picking, Compare, zoom/pan) applies to filmstrip taps for
free — no new mode-exclusion logic needed, same guarantee D1(a) already
has. `ContentView.editorContent` now wraps the pre-existing `HSplitView`
(extracted unchanged into `editorSplitView`) in an outer `VStack` with
the filmstrip below it, toggled by a new toolbar button
(`isFilmstripVisible`, defaults on) using the same active-state
yellow-`.tint` convention the Compare menu button already uses.

**A real, unplanned compiler-limits detour**: adding the new toolbar
button to the existing single `.toolbar { }` closure made the WHOLE
closure fail to compile — "the compiler is unable to type-check this
expression in reasonable time" — even though the new button itself was
trivial. Root-caused to total statement/branch COUNT in one `@ViewBuilder`/
`@ToolbarContentBuilder` closure, not any one sub-expression's own
complexity (confirmed by first extracting only the new button into its
own `@ToolbarContentBuilder` property, which did NOT fix it). Fixed by
splitting the entire toolbar into five named `@ToolbarContentBuilder`
properties (`libraryToolbarItems`, `editHistoryToolbarItems`,
`compareToolbarItem`, `filmstripToolbarItem`, `cropDoneToolbarItem`),
each independently type-checked — behavior-preserving, confirmed by the
reviewer item-by-item against the diff (same `ToolbarItem`s, same order,
same `.disabled`/`.tint`/`.onChange`/conditionals, just relocated).
- Reviewer **APPROVE**, one non-blocking doc-comment fix made before
  commit: the new file originally claimed `EditorFilmstripView` being a
  separate `View` (observing only `catalog`, taking `currentURL` by
  value) meant its `body` provably does NOT re-run on every
  `document.editState` publish/slider tick. Reviewer correctly pointed
  out this overclaims — `onSelect` is a fresh closure built on every
  `ContentView` body pass, making the view non-`Equatable`, so SwiftUI
  can't actually prove it unchanged and likely re-evaluates `body`
  anyway. The comment was corrected to state the real, honest reasoning:
  the COST of that re-evaluation is small regardless (`LazyHStack`
  diffing is cheap, `.task(id:)` only re-fires on a `photo.path` change,
  `@State` images persist), so it wasn't worth chasing a real guarantee.
- No new tests — matching the precedent already set for Crop v2's drag
  rectangle, the Compare divider, and D7's own ContentView split: pure
  SwiftUI composition/interaction, zero `EditEngine` changes, reusing
  already-tested `CatalogModel.thumbnail(for:)`,
  `ImageDocumentModel.load(from:)`, and `LibraryFilterSort`/
  `LibraryNavigation`.
- Build clean, **374 tests, 0 failures** (unchanged — no new tests
  expected). 1 commit.
- **Verified live 2026-08-28**, same Accessibility-driven session as D7/
  D1(a). Confirmed: the strip shows and is tappable even with no photo
  open yet (an incidental, harmless side effect of reusing the generic
  tap handler); tapping a cell switches photos (title, Adjust tab stayed
  active) and the tapped cell gets the accent-border highlight; ⌘→ (via
  the Photo menu) moves the highlight to the correct next cell AND
  auto-scrolls the strip to keep it in view; the toolbar toggle button
  collapses the strip (image pane grows to fill the space) and a second
  click reliably re-shows it with the correct cell still highlighted.
  NOT independently re-verified this pass: navigating via the strip
  specifically while zoomed/in Compare/on the Crop tab — not re-tested
  live, but it's covered by construction (the filmstrip's tap handler
  calls the IDENTICAL `document.load(from:)` already live-verified for
  ⌘←/⌘← in the D1(a) pass, which exercises that exact reset), not by
  inference alone.
  - **Toolbar-button visual quirk, harmless, noted for anyone testing
    this live in the future**: the Compare and Filmstrip toolbar buttons'
    SF Symbol glyphs (`rectangle.split.2x1`, `square.grid.3x1`) render as
    plain, glyph-less dark circles in this macOS build (26.5.2) — cost
    real verification time before being traced to a rendering-only
    quirk, confirmed via the Accessibility tree (both elements ARE
    present, correctly named "Filmstrip"/a "group", at the expected
    toolbar position) and via clicking them successfully (the Filmstrip
    toggle visibly works). Not a code bug — no action taken.

### Remove photos from the Library catalog (complete, verified live 2026-09-01) — IMPROVEMENTS.md D5, part 1 of 3

D5 bundles three separate items (remove-from-catalog, missing-file
detection, rename/delete collections), each flagged as needing its own
session. This ships the first, chosen because it was the exact friction
that surfaced two sessions ago (had to hand-edit the SQLite database
directly to remove 3 test photos). **Scope: catalog row only — the
original file on disk is never touched**, confirmed correct by the
reviewer (no `FileManager` deletion API called anywhere in the new code)
and consistent with three independent facts: the app only holds
READ-ONLY security-scoped bookmarks on imported folders (no write access
to delete a file even if it wanted to), `Photo.swift`'s own doc comment
already states the original is never touched, and D5's own wording lists
"detect files deleted on disk" as a separate item — implying catalog and
disk are expected to be able to diverge. The confirmation alert says so
explicitly ("The original file on disk is not affected").

`Sources/Catalog/CatalogDatabase.swift` gained `deletePhoto(id:)` — the
project's first live row-DELETE on `photo` (`try Photo.filter(...).deleteAll(db)`).
No migration needed. `collection_photo` memberships are cleaned up by the
existing `ON DELETE CASCADE` FK from `Migrations/003_collections.swift`,
verified — not just trusted — by tracing GRDB's vendored source
(`Configuration.swift`'s `foreignKeysEnabled = true` default, never
overridden anywhere in `CatalogDatabase`) and by a new test,
`testDeletePhotoCascadeDeletesCollectionMemberships`, that genuinely
discriminates a working cascade from a broken one (reviewer confirmed:
nothing else deletes the membership row, so either FK-off or
FK-on-but-RESTRICT would fail the test) — the first time this cascade,
shipped in Phase 4, has actually been exercised by a live DELETE.

`Sources/UI/CatalogModel.swift` gained `removePhoto(_:)`, following the
same local-first-then-write P4 pattern every tap mutator uses
(`setRating`/`setFlagged`), but the first one that's a PERMANENT removal
rather than a re-toggleable field — so unlike `toggleMembership`'s
transient "ghost cell" (expected to resolve on the next `refresh()`),
this one also prunes `selectedPhotoIDs` and `membershipsByPhotoID[id]`
outright (both permanently stale otherwise) and invalidates the
thumbnail cache entry so a later re-import of the same path can't
resurrect a stale cached image.

`Sources/UI/LibraryGridView.swift`: `LibraryThumbnailCell`'s existing
per-photo collections `Menu` gained a `Divider()` + `Button(role:
.destructive)` "Remove from Library" — the first `Divider()` and first
`role: .destructive` in any Menu in this codebase. The confirmation
`.alert` lives on `LibraryGridView` itself, deliberately NOT
`ContentView` — `ContentView.body` was already split once specifically
because a 5th `.alert` pushed the type-checker past its limit, so a 6th
alert there was a real compile-time risk this session didn't need to
reintroduce. The alert generalizes `ContentView`'s own `presenting:`-driven
shape from `String?` to `Photo?`.

- Reviewer **APPROVE** on first pass — independently traced the cascade
  claim against GRDB's vendored source rather than trusting the migration
  comment, confirmed the catalog-only scope by checking no filesystem-
  deletion API is called anywhere, confirmed the alert genuinely doesn't
  compose into `ContentView`'s fragile alert chain (different `View` type
  entirely), and confirmed `Set.remove`/`Dictionary.removeValue` on an
  absent member/key are safe no-ops. Two non-blocking notes carried
  forward, neither gating: (1) if the fire-and-forget DB write ever fails
  after the local removal, the photo silently reappears on the next
  `refresh()` with no error surfaced to the user — acceptable for now
  (a local SQLite DELETE-by-id has essentially no realistic failure mode
  short of disk catastrophe), same pattern already accepted for
  `setRating`/`setFlagged`; (2) removing a photo currently open in the
  background Editor doesn't force-close that Editor session — reachable
  only via Library → remove → switch back to Editor, an accepted v1
  limitation, same category as Straighten's documented corner-gap
  limitation.
- 380 tests (6 new: 3 `CatalogDatabaseTests` — remove-the-row, the cascade
  proof, delete-a-nonexistent-ID-is-a-no-op — and 3 `CatalogModelTests` —
  synchronous local removal, `selectedPhotoIDs` pruning, DB persistence).
  1 commit.
- **Verified live 2026-09-01** — by the user directly (this pass, unlike
  D7/D1/D1(b), was driven manually rather than via Accessibility
  automation, after automation overhead on this pass ran too high for
  the value it was adding). Confirmed: the per-cell Menu shows "Remove
  from Library" below a divider, the confirmation alert's wording and
  buttons are correct, Cancel is a genuine no-op, Remove drops the cell
  immediately, and the photo stays gone after quitting and relaunching
  the app (the DB write landed, not just the in-memory removal).
  **One real, live-caught visual bug, fixed same session**: the menu
  item's `role: .destructive` did NOT render red text — unlike an
  `.alert`'s destructive button (which the user confirmed WAS correctly
  red), macOS `Menu` items don't automatically tint from that role
  alone. Fixed with explicit `.foregroundStyle(.red)` on both the label
  text and the trash icon. Rebuilt, retested (380 tests unchanged),
  1 commit.

### Library thumbnail-size slider + edited-photo badge (complete, verified live 2026-09-01) — IMPROVEMENTS.md D2 + D3

Two small, self-contained Library-grid UI features, bundled into one
session as the user's own choice. Both confined to
`Sources/UI/LibraryGridView.swift` — no migration, no new catalog state.

**D2**: a bottom-right `ThinSlider` (this app's own custom slider, not
the native SwiftUI one) drives `@AppStorage("PhotoApp.libraryThumbnailSize")`,
which now feeds both `columns` (`GridItem(.adaptive(minimum:
thumbnailSize))`, previously a hardcoded `let`) and a new `cellSize:
CGFloat` parameter on `LibraryThumbnailCell`, replacing all three
previously-hardcoded `140`s. Deliberately capped at **100...240** and
`ThumbnailCache` itself is completely untouched — the cache decodes at a
fixed 240px and keys purely on path (no size component), so widening it
would've meant either quadratic memory growth per entry or a genuine
cache-key redesign; instead this only resizes the SAME already-decoded
image for display, the identical trick `EditorFilmstripView`'s 56pt
cells already rely on. `@AppStorage`, not `@State`, specifically because
`LibraryGridView` is torn down and recreated on every Editor↔Library
switch — a plain `@State` would silently reset the slider every time.

**D3**: a small badge (same circular-backdrop visual language as the
existing selection checkbox) appears bottom-trailing on any cell whose
photo has a sidecar file, via `FileManager.fileExists` against
`ImageDocumentModel.sidecarURL(for:)` (already `nonisolated static`,
reusing the exact precedent `PhotoExporter.loadEditState(for:)` already
established for calling it without an instance). Deliberately NOT
implemented inside `ThumbnailCache` — its `NSCache<NSString, CGImage>`
and its other call site (`EditorFilmstripView`'s `FilmstripCell`) both
expect a bare `CGImage?`; widening that shared return type would have
rippled into both cells and every `ThumbnailCacheTests` call site for a
check only the Library grid needs. Instead rides along in
`LibraryThumbnailCell`'s own existing `.task(id: photo.path)`, using
`async let` so the cheap stat runs concurrently with the (much slower)
thumbnail decode rather than serializing behind it. Filmstrip explicitly
untouched — its own doc comment already states its cells are
deliberately lighter than the Library grid's.

- Reviewer **APPROVE** on first pass — confirmed the 100...240 cap is
  real and nothing requests a display size outside it, confirmed
  `@AppStorage`'s key doesn't collide with the app's two existing
  `UserDefaults` keys, grepped for and found no surviving hardcoded
  `140`, confirmed the frame-before-clipShape ordering (load-bearing for
  the selection checkbox's positioning) still holds with `cellSize`
  substituted in, confirmed the badge overlay is scoped to the ZStack
  only (can't collide with the rating/flag row below), confirmed the
  `async let` genuinely runs the stat and the decode concurrently, and
  confirmed `EditorFilmstripView.swift`/`ThumbnailCache.swift`/its tests
  are untouched by the diff. One non-blocking correction, carried
  forward rather than fixed: `.task` bodies on a plain `View` actually
  inherit that view's `@MainActor` isolation (not off-main-actor as
  initially assumed while designing this) — so the sidecar
  `FileManager.fileExists` stat in `LibraryThumbnailCell`'s `.task` does
  run on the main actor. Negligible for a single local-volume syscall
  per cell-appearance; worth moving to a background context only if
  library folders on network shares ever become a supported case.
- No new tests — matches this project's established judgment call for
  UI-wiring-only changes with no new pure logic (Crop v2, the Compare
  divider, D7, D1(b) all shipped the same way). 380 tests unchanged.
  1 commit.
- **Verified live 2026-09-01** (Accessibility-driven, via the slider's
  own `accessibilityAdjustableAction` — AXIncrement/AXDecrement — since
  the custom `ThinSlider` proved awkward to hit reliably with raw pixel
  clicks on this multi-monitor setup): the grid's cell size AND column
  count both responded live in both directions; quit-and-relaunch
  confirmed the chosen size persisted via `@AppStorage`; the edited
  badge was confirmed showing correctly only on the 3 photos with real
  saved edits, not on any of the ~20 unedited ones in the library, with
  no collision against the top-leading selection checkbox, confirmed at
  both slider extremes.

### Presets — save/apply named edit-state "looks" (complete, verified live 2026-09-02) — Phase 5 slice 2

The last remaining piece of Phase 5 (batch export shipped earlier). CLAUDE.md
had stated plainly: "Presets (save/apply named edit-state presets) are NOT
started." Also outranks the entire IMPROVEMENTS.md backlog per the roadmap's
own ordering rule.

**Scope decision, grounded in code already shipped, not invented fresh**: a
preset captures color/tone only — exposure, WB, curves, selective color,
B&W, vignette, definition, sharpen, noise reduction, and the red-eye
correction *intensity* sliders. It deliberately excludes crop/straighten/
perspective/flip geometry and the actual placed `redEyePoints` (both
specific to one photo's composition/face positions, never part of a
reusable "look"). This exact partition already existed and was tested:
`EditState.comparisonOriginal()` (the Compare feature's "original" side)
resets precisely this field set to identity while preserving geometry — the
new `EditState.applyingPreset(onto:)` reuses that SAME partition in the
opposite direction (copy color/tone IN from the preset, keep geometry/
red-eye-points OUT, preserved from the target) rather than re-deriving a
second list that could drift out of sync.

`Sources/Catalog/Preset.swift` (new) + `Migrations/005_presets.swift` (new)
— the first blob/JSON-style column in this codebase: `editState: EditState`
is a nested `Codable` property that GRDB's Codable-record support
auto-serializes with zero manual encode/decode, reusing `EditState`'s own
already-schema-tolerant `Codable`. `CatalogDatabase` gained
`allPresets()`/`createPreset(name:editState:)` (`onConflict: .replace` —
saving under an existing name transparently overwrites, matching
Lightroom-style UX, no separate "overwrite?" confirmation needed)/
`deletePreset(id:)`, all mirroring the collections/photo-removal methods'
exact shapes. `CatalogModel` gained `@Published presets` + matching
`createPreset`/`deletePreset` mutators (`createPreset` fire-and-forget-then-
refresh like `createCollection`; `deletePreset` local-first-prune like
`removePhoto`). `ImageDocumentModel` gained `applyPreset(_:)`, structurally
identical to the already-shipped `revertToOriginal()` — commits directly to
`history` as one atomic, immediately-committed undo step rather than the
debounced path, for the same stale-canUndo reason `revertToOriginal()`
already documented.

`AdjustTabView` gained a 7th collapsible section ("Presets", after Red-Eye):
a "Save Preset…" button (a `.alert` hosted on `AdjustTabView` itself, NOT
`ContentView` — which already carries 5 alerts and was previously split
specifically because a 6th broke the type-checker) and a flat list
(deliberately no nested `Menu`, to avoid repeating the exact type-checker
pathology that broke the toolbar `.toolbar {}` closure earlier this
session) of saved presets, each row tap-to-apply plus a trash-icon delete
with explicit `.foregroundStyle(.red)` (not relying on `role: .destructive`,
already proven not to render red on a macOS Menu/button this session).

- Reviewer **APPROVE** (Opus 5, after the default review model hit the
  account's monthly spend limit mid-review on the first attempt — retried
  successfully on Opus 5) — independently set-diffed `comparisonOriginal()`
  and `applyingPreset(onto:)`'s field lists programmatically rather than
  eyeballing (49 vs 48 fields, exact expected difference `{redEyePoints}`,
  zero copy-paste-swapped identifiers), read the vendored GRDB source
  directly to confirm the JSON round-trip is single-pass/not double-encoded
  and that the round-trip test is genuinely discriminating (a mangled blob
  throws during `EditState`'s custom decode rather than silently
  defaulting), confirmed `applyPreset`'s undo-commit ordering reads the
  CURRENT `editState` before any mutation, confirmed the `CatalogModel`
  mutator shapes aren't swapped, and confirmed the prior red-text and
  alert-placement lessons were genuinely applied (not just claimed). **Two
  non-blocking findings fixed same session before commit**: (1) the
  migration declared the `editState` column `.blob`, but GRDB's
  Codable-record support actually persists nested `Codable` values as
  TEXT (verified against GRDB's own source) — `.blob` "worked" only
  because SQLite's BLOB affinity means "no type conversion", silently
  storing the text verbatim; fixed to `.text` (the column type GRDB's own
  docs recommend) while the table is still new/unshipped, since migrations
  are append-only and this is the cheapest possible moment to fix it. (2)
  the "Save Preset" button was saving `document.editState` wholesale,
  meaning every preset's stored blob also carried the SOURCE photo's crop
  insets/straighten angle/flips/placed red-eye points as inert dead data
  (harmless today since `applyingPreset(onto:)` ignores it, but a future
  preset-export or "apply full state" code path would silently inherit one
  photo's composition) — fixed by saving
  `document.editState.applyingPreset(onto: .identity)` instead, reusing the
  exact same field-partition method the apply path already uses, so a
  saved preset now only ever contains the reusable fields. Three other
  non-blocking notes carried forward, all matching pre-existing patterns
  rather than new gaps: preset-name sort uses SQLite's default
  case-sensitive BINARY collation (same as `allCollections()`); the
  trash-icon delete button has no `accessibilityLabel` (tracked under the
  still-open D6 accessibility-pass backlog item, not fixed ad-hoc); and
  `CatalogModel.createPreset`'s `try?` discards a genuine write failure
  (matches `createCollection`'s own existing behavior exactly).
- 390 tests (10 new: 3 `EditStatePresetTests` — color/tone copied from the
  preset, target's geometry/red-eye-points survive untouched, and an
  asymmetry-aware round-trip check against `comparisonOriginal()` that
  deliberately does NOT assume naive symmetry, since `comparisonOriginal()`
  clears `redEyePoints` while `applyingPreset` preserves the target's own —
  5 `CatalogDatabaseTests` including a full-field round-trip through the
  new JSON column, and 2 `CatalogModelTests`). 1 commit.
- **Verified live 2026-09-02**, manually by the user (not Accessibility-
  automation-driven — a large amount of automation overhead earlier this
  session, spent chasing an unrelated sidecar-save permission issue,
  established a new working agreement: screen-capture/UI-automation now
  needs the user's explicit per-task go-ahead, code-only work is the
  default). Confirmed: saving a preset from dialed-in Adjust-tab sliders
  shows it in the list; applying it to a DIFFERENT photo (one with its own
  crop/straighten already set) matches color/tone while leaving that
  photo's own geometry/red-eye points untouched; deleting a preset removes
  it immediately with no confirmation; it stays deleted after quit and
  relaunch (the app was relaunched for this step, on request, since a
  plain process quit/reopen isn't screen-capture/UI-driving); saving under
  an existing name overwrites in place rather than duplicating.
  **Phase 5 is now fully shipped AND live-verified.**

  A real, unrelated bug surfaced during this verification pass and was
  investigated: "Couldn't save edits: the file couldn't be opened" on a
  photo in `~/Downloads`, reproducible on ANY edit to that photo (not
  specific to Presets — confirmed before investigating further). Traced to
  `ImageDocumentModel.swift`'s `requestFolderAccess`/`saveSidecarNow`
  (pre-existing code, untouched by this session's actual changes) via
  temporary diagnostic logging (added, used to confirm the failure was in
  the post-grant `bookmarkData`/write path, then fully reverted — `git
  diff` against HEAD came back empty, confirming a clean revert with
  nothing shipped). Root cause: a transient TCC permission-propagation
  delay for `~/Downloads` specifically (Files and Folders privacy access
  was confirmed already toggled ON in System Settings, yet the FIRST
  fresh in-app folder-access grant still failed; a second grant attempt
  succeeded cleanly with no code change). Not reproducible after that;
  no code fix was needed or made.

### Phase 6 slice 1: RAW file support via Core Image — SHIPPED (complete, not yet live-verified)
- User explicitly said "phase 6", lifting CLAUDE.md's own "do not start
  early" gate on this roadmap item.
- **Deliberately diverges from CLAUDE.md's original Stack line** ("LibRaw
  via C++ interop for RAW decoding"), with the user's approval after a
  tradeoff review (`AskUserQuestion`, twice — once broad, once after the
  user asked to "check tradeoff" specifically, backed by `WebSearch`,
  `WebFetch`, and reading the actual `CIRAWFilter.h` header + Apple SDK
  directly rather than trusting search-result summaries alone). Core
  Image's `CIRAWFilter` (macOS 12+; this project targets 14.0) supplies
  demosaic and camera profiles for ~784 bodies, updated by the OS, and
  returns a `CIImage` that drops into `EditPipeline.apply` at the exact
  seam every existing decode site already used — zero new dependencies,
  zero C++ interop, zero `project.yml` changes (confirmed: `xcodegen
  generate && xcodebuild` needed no build-setting edits). LibRaw would
  have meant this codebase's first C/C++ interop, a vendored binary,
  hardened-runtime signing work, and hand-written demosaic/profile
  handling Apple otherwise supplies for free — logged as the fallback if
  a camera body outside CIRAWFilter's support list is ever needed.
- **The one real CIRAWFilter risk — an unsupported camera body — was
  retired empirically before any code was written**, not assumed: the
  user's actual RAW library is `/Users/praween/Pictures/Bolivia_trip/raw_files`
  (930 Nikon `.NEF` files, ~52GB, camera identified via the file's own
  embedded string as NIKON D610). `sips -g pixelWidth …` on
  `DSC_1017.NEF` already returned `6016×4016`/16-bit/RGB — Apple's RAW
  pipeline decodes this exact file on this machine today.
- New `Sources/Rendering/RawDecoder.swift` is the app's first shared
  file-decode chokepoint. Before this, three call sites decoded files
  completely independently: `ImageDocumentModel.load(from:)`
  (`CIImage(contentsOf:).oriented(...)`), `PhotoExporter.export`
  (hand-duplicated the same shape), and `ThumbnailGenerator` (a separate
  ImageIO thumbnail API) — sharing only an orientation-lookup helper. All
  three now route through `RawDecoder.decode`/`isRaw`/`decodeDraft`, with
  the non-RAW path byte-identical to the prior inline code at every site
  (reviewer independently confirmed this).
- `RawDecoder.isRaw` classifies via `UniformTypeIdentifiers`
  (`UTType(filenameExtension:)?.conforms(to: .rawImage)`) rather than a
  hardcoded extension list, so RAW coverage tracks whatever formats the
  running OS actually knows about instead of this app's own list going
  stale as new cameras ship. `PhotoImporter.supportedExtensions` (the
  pre-existing non-RAW `Set`) is now paired with a new
  `isSupportedImage(_:)` that also checks `RawDecoder.isRaw`, used by
  both the flat (`imageFiles(in:)`) and recursive (`scanNode(at:)`) scan
  paths — RAW files are now importable both ways. No DB migration: `Photo`
  has no type/format column and needs none, since RAW is classified from
  the path extension at decode time, not stored.
- **Orientation, measured live, not assumed** — this codebase has been
  bitten by unverified coordinate/orientation assumptions before (the
  Metal y-flip, the Compare-mode split inversion). `CIRAWFilter.orientation`
  is a readwrite property; measured against a real NEF with its
  orientation tag byte-patched from 1 to 6 (a scratch copy, made and
  deleted during review — the user's real files were never modified):
  the filter's OWN DEFAULT already matched the independently-read EXIF
  value (6), and `outputImage`'s extent was already rotated accordingly
  (4016×6016, swapped from the native 6016×4016). So `RawDecoder.decode`
  never chains `.oriented(_:)` after a RAW decode (that would
  double-rotate) — confirmed empirically, not just from the header doc's
  wording.
- RAW thumbnails deliberately do NOT use ImageIO's thumbnail API — it
  would return the camera's own embedded JPEG preview, not Apple's RAW
  rendering, reintroducing the exact Editor-vs-grid mismatch post-Phase-5
  follow-up #4 already fixed once for edited-vs-unedited thumbnails.
  Instead they go through `CIRAWFilter`'s own `isDraftModeEnabled`/
  `scaleFactor` (exactly what Apple built draft mode for), rendered
  through `ThumbnailGenerator`'s existing `context`/`outputColorSpace` —
  the app's `extendedLinearSRGB`/`RGBAh` working space, matching
  `ImageRenderer`/`PhotoExporter`/`WhiteBalanceSolver`.
- **Reviewer (Opus 5 — the default model hit the account's monthly spend
  limit mid-review, same as the Presets session): FIX FIRST → APPROVE**,
  after independently re-measuring the orientation claim live (not
  trusting the diff's own reasoning) and catching three real issues,
  all fixed before commit:
  1. `filter.orientation` was being unconditionally assigned from a
     helper that silently falls back to `.up` on any read failure —
     since the filter's own default is already correct (measured above),
     this assignment had zero upside and one failure mode: a RAW
     container ImageIO parses differently than Core Image's RAW decoder
     (CR3/RAF/vendor-specific — untestable against this session's
     NEF-only sample) could have a correct non-`.up` default silently
     overwritten with a wrong guess, shipping a sideways image to
     Editor, export, and thumbnails simultaneously. Fixed: the read now
     returns `nil` (not a `.up` guess) on failure, and `filter.orientation`
     is only ever assigned when a real value was read.
  2. The RAW edited-thumbnail path defeated its own stated rationale:
     `CIRAWFilter.outputImage` is extended-range/wide-gamut, but the
     first draft flattened it to an 8-bit sRGB `CGImage` BEFORE handing
     it to `EditPipeline`, silently clipping exactly the headroom/gamut
     RAW provides before the edit math ever saw it — for any edit
     touching highlight recovery or saturated color, this would make the
     grid disagree with the Editor, the same defect class as
     post-Phase-5 follow-up #4. Fixed: the RAW branch now hands
     `EditPipeline` the raw `CIImage` directly and flattens to 8-bit
     sRGB exactly once, after the edit math runs.
  3. `scaleFactor` was unclamped/unguarded against `maxPixelSize <= 0`.
     Fixed: `min(1, ...)` clamp plus a `maxPixelSize > 0` guard, matching
     the header's documented `0...1` range and this app's existing
     never-upscale precedent.
  Re-review (same reviewer instance, resumed via its own transcript, not
  a fresh review) confirmed all three fixes independently, plus a trivial
  stale doc-comment reference caught and fixed in the same pass. Final
  verdict: APPROVE.
- **Known limitation, logged not fixed this slice**: `CIRAWFilter.decoderVersion`
  defaults to "the newest available decoder for the image type" and isn't
  pinned or serialized into `EditState` — replaying identical params after
  a future OS update could render a RAW photo slightly differently, a real
  exception to CLAUDE.md's "replaying the same params must be
  deterministic" invariant. Coupled to slice 2 (`decoderVersion` should
  become a serialized field when RAW-native controls ship), not addressed
  here.
- 399 tests (9 new: `RawDecoderTests` — fixture-free classification only,
  since no RAW file ships in the repo for CI — plus 3 new `PhotoImporterTests`
  cases for RAW-extension acceptance in both scan paths). RAW *decode*
  itself has no automated test; it was verified empirically during review
  against the user's real files (see above) and is scheduled for the
  user's own live pass, not asserted in a unit test. 1 commit.
- **VERIFIED LIVE 2026-09-03**, manually by the user on their real RAW
  library (`/Users/praween/Pictures/Bolivia_trip/raw_files`, 930 Nikon
  `.NEF` files). Two severe freezes surfaced during this pass — see the
  two follow-up sections immediately below — both diagnosed, fixed,
  reviewer-approved, and re-verified live. With those fixed, the full
  checklist passed: Open… renders a `.NEF` right-side-up; imported
  thumbnails match the Editor's own rendering; grid scroll across all
  930 files was judged acceptable (the documented ImageIO-fallback for
  slow draft-mode decode was NOT needed); slider edits on a RAW photo
  persist through a Library round-trip AND a full quit/relaunch
  (sidecar save confirmed surviving a real process restart); RAW→JPEG
  export confirmed working. **Phase 6 slice 1 is now fully shipped AND
  live-verified.**

### Phase 6 slice 1 follow-up: RAW Editor freeze — FIXED (complete, verified live 2026-09-03)
- The user's own live pass (opening a real Nikon D610 NEF from
  `raw_files` in the Editor, immediately after import) found a real,
  severe bug within minutes: the app froze completely. Also separately
  reported: after relaunching onto a fresh build, `.NEF` couldn't be
  selected in the Open… panel and Import Folder reported "0 files" —
  traced to a STALE running process (PID launched before the RAW
  support build finished), not a code bug; fixed by quitting and
  relaunching onto the current binary (plain process management, not
  screen-capture/UI-automation, consistent with this project's existing
  carve-out for app relaunches).
- **Root-caused with `/usr/bin/sample` on the actually-hung process**
  (process-level CLI diagnostics, not screen-capture/UI-driving — no
  permission needed under the standing working agreement) — virtually
  100% of samples over 3 seconds were inside `ImageRenderer.draw(in:)` →
  `-[CIContext render:toMTLTexture:commandBuffer:bounds:colorSpace:]`.
  `MTKView` here has `isPaused = true`/`enableSetNeedsDisplay = true` (no
  internal render loop, confirmed by reading `ImageRenderer.swift`'s own
  doc comment), so this wasn't a redraw storm — it was one or more
  individually catastrophic renders. Cause: a `CIImage` is a lazy
  RECIPE, not decoded pixels. `ImageRenderer.draw(in:)` runs
  `EditPipeline.apply` and re-renders `currentImage` on every redraw
  (every slider tweak); for a plain `CIImage(contentsOf:)` source that's
  cheap to re-run (already-demosaiced pixels), but for a RAW source
  `currentImage` was `CIRAWFilter`'s own lazy graph — so every redraw
  silently re-ran the ENTIRE full-resolution RAW demosaic from scratch,
  synchronously, on the main thread. Same root cause also hit the
  debounced histogram recompute and the WB eyedropper's ~52 filter
  evaluations (each would have been ~52 full demosaics) — caught by the
  reviewer, not found live, since neither had been exercised yet.
- **Fix, chosen via `AskUserQuestion`** over the alternative (draft-mode
  Editor preview, a real quality tradeoff the user would be looking at
  while editing): new `RawDecoder.materialize(_:)` renders the RAW
  output ONCE into a realized `CVPixelBuffer`
  (`kCVPixelFormatType_64RGBAHalf`, extended-range, matching this app's
  `extendedLinearSRGB`/`RGBAh` working space everywhere else
  `EditPipeline` runs — deliberately not an 8-bit/sRGB intermediate,
  which would silently clip exactly the range/gamut RAW provides),
  re-wrapped as a `CIImage` backed by that buffer. `ImageDocumentModel.load(from:)`
  calls this only for RAW sources; non-RAW, export, and thumbnails are
  untouched (each already renders once, so materializing would be pure
  overhead there). Standalone CLI timing check against the same real
  NEF confirmed the mechanism: materialize costs ~0.75s once, and
  re-rendering the materialized result afterward is ~0-24ms — down from
  whatever the original hang's true cost was (never measured to
  completion; the process was killed while still stuck).
- **Reviewer (Opus 5): FIX FIRST → APPROVE**, catching two real issues
  in this fix's own first draft, both fixed before commit: (1) a
  genuine RUNTIME CRASH, not just a bad guess — `CGRect.infinite`'s
  width is `CGFloat.greatestFiniteMagnitude`, which is FINITE by IEEE
  semantics (not `.infinity`), so an `.isFinite`-only guard never caught
  it and `Int(extent.width.rounded())` trapped; fixed with `CGRect`'s
  own `.isInfinite`/`.isNull` plus an explicit `< Int32.max` bound (the
  reviewer independently confirmed even a PARTIALLY-infinite extent,
  which `.isInfinite` alone doesn't catch, is caught only by that bound).
  (2) A genuine test-coverage gap: the pixel round-trip test only used
  in-gamut `[0,1]` values sampled through an 8-bit bitmap, so it could
  not detect the exact silent-clipping regression the function's own doc
  comment claims to prevent — the reviewer proved this by hand-writing
  an 8-bit-intermediate mutant of `materialize` that passed the old test
  with zero measured drift; fixed by adding an extended-range test using
  out-of-`[0,1]` values sampled through a dedicated extended-range
  context, which the reviewer confirmed the same mutant fails on all
  five assertions. 403 tests (1 new). 1 commit.
- **Known limitation, logged not fixed this pass** (reviewer's framing):
  materialize's ~0.75s cost is now front-loaded onto `load(from:)` (a
  bounded, one-time pause per RAW photo open, vs. the old unbounded
  per-interaction cost) — still a real main-thread pause with no
  progress indicator, and there's no `url != currentURL` early-out, so
  re-tapping the already-open photo in the filmstrip pays it again.
  Adding that early-out would change `load(from:)`'s history-reset
  semantics and belongs in its own scoped change, not bundled into a
  freeze fix.
- **VERIFIED LIVE 2026-09-03** — re-opened a `.NEF` on the relaunched
  build; no freeze.

### Phase 6 slice 1 follow-up #2: RAW Editor deadlock — FIXED (complete, verified live 2026-09-03)
- The user retried the freeze fix above immediately and it **still
  froze** — same symptom, different cause. This confirmed the per-frame
  repeat-demosaic bug really was fixed (only ONE `materialize` call
  showed up in a fresh `sample`), but exposed a second, genuinely
  different problem: the main thread was `dispatch_sync`-blocked inside
  CoreImage's `GetSurfaceFromCacheAndFill`, waiting on TWO
  `RawCamera-Provider-Render-Queue` worker threads that were themselves
  stuck on an internal semaphore deep inside Apple's private
  `RawCamera.framework` (opaque, unsymbolicated frames — nothing
  further diagnosable from this side). This happened specifically
  while the Library grid was concurrently decoding RAW thumbnails in
  the background for the same 930-file import. Concurrent RAW decode
  requests from different parts of the app appear to genuinely
  stall/deadlock each other inside that closed framework, not just
  contend for CPU.
- **Fix, confirmed with the user via `AskUserQuestion` before building**
  (given the real scope increase beyond the original ask): new
  `RawDecoder.RenderGate`, a nested `actor` whose single `run` method
  serializes every heavy RAW CoreImage call app-wide — `materialize`'s
  render, `ThumbnailGenerator`'s RAW thumbnail path, and
  `PhotoExporter`'s RAW export writes — so the app can never ask
  Apple's framework to do two RAW things at once, regardless of which
  call site. `ImageDocumentModel.load(from:)`/`openImage()` are now
  `async`; a new `@Published isLoadingImage` drives a
  `ProgressView("Decoding RAW photo…")` overlay in the Editor so the
  async gap reads as "working," not as a second freeze. `showLibrary =
  false` in the Library grid's tap-to-open now happens BEFORE the load
  `Task`, not after, so that spinner is actually visible instead of the
  user staring at an unchanged grid. All non-RAW paths are byte-for-byte
  untouched and pay none of this cost.
- **Reviewer (Opus 5, two full rounds): FIX FIRST → APPROVE**, catching
  two real, substantive issues in this fix's own first draft:
  1. **A genuine non-destructive-editing integrity bug**, not cosmetic:
     `load(from:)` becoming `async` with no ordering guard meant a
     SLOWER-finishing RAW load could resume AFTER a FASTER-finishing
     later load already committed, silently overwriting
     `currentImage`/`currentURL`/`editState` with stale data —
     concretely, open RAW A (suspends mid-decode) → open JPEG B
     (completes immediately) → user edits B → A resumes and stomps
     everything with A's data, discarding B's edits with no error and
     no trace. Fixed with a monotonic `loadGeneration` token, captured
     before the first `await` and re-checked after every subsequent
     one before touching any `@Published` state; also unconditionally
     clears `isLoadingImage` at the top of every call (not just RAW
     ones) so a superseded RAW load's spinner can't get stuck on when
     the load that supersedes it is non-RAW and never touches the flag.
  2. `RawDecoder.decode`/`decodeDraft` still ran `CIRAWFilter`
     construction and a SECOND `CGImageSourceCreateWithURL` open
     (inside `readExifOrientation`) synchronously, ungated, on the
     calling actor — the first draft only gated `materialize`'s
     downstream render, missing that construction itself does real
     RawCamera/ImageIO work and is exactly the class of concurrent
     access the gate exists to prevent. Fixed by moving the entire RAW
     branch of both functions inside `RenderGate`, both now `async`.
  Round 2 independently re-traced both failure scenarios against the
  rewritten code (not just re-read it), confirmed no gate-nesting/
  self-deadlock exists across the four production render paths, and
  re-measured non-RAW thumbnail parallelism live —
  `ThumbnailCacheTests.testDecodesRunInParallel`: 0.30 ratio, at/better
  than the documented 2026-08-28 baseline of 0.32 — confirming the fix
  didn't quietly re-serialize JPEG/PNG/TIFF/HEIC decoding. Build clean
  under this project's real Swift 6 strict-concurrency settings, zero
  warnings.
- **Known limitations, logged not fixed this pass** (reviewer's
  framing): (1) the gate queue is unbounded, unprioritized, and
  uncancellable — under a 930-file library, the Editor's load queues
  behind every already-waiting thumbnail render, and
  `ThumbnailCache`'s `Task<CGImage?, Never>` never checks
  `isCancelled` (a pre-existing, already-documented limitation — see
  `ThumbnailCache.swift`), so nothing drops out of the queue; a
  "freeze" becomes a multi-second spinner instead, bounded by however
  many RAW decodes are ahead of it, not eliminated. A real fix needs
  cancellation support in `ThumbnailCache`, out of scope for this bug
  fix. (2) `materialize`'s graceful-degradation fallback (pixel-buffer
  creation failure, unreachable in practice) escapes the gate entirely
  and would hand `ImageRenderer.draw(in:)` a still-lazy `CIRAWFilter`
  graph to evaluate per-frame on the main thread if it ever triggered —
  degrading back to both bugs at once. Documented in the code, not
  fixed, since the failure mode it guards is not reachable from a
  well-formed RAW file.
- No new tests this pass — the race condition needs a real RAW file or
  an injectable artificial delay to reproduce deterministically (no
  fixture ships in this repo, and `RawDecoder` has no seam for
  dependency-injecting a delay without a larger refactor); reasoned
  through and reviewer-verified by tracing the exact interleaving twice
  against the real code, the same category as this project's other
  live-render-only bugs (y-flip, crop-tiling) that unit tests can't
  reach. 403 tests unchanged, all still passing. 1 commit.
- **VERIFIED LIVE 2026-09-03** — retried the exact scenario that
  deadlocked (opening a `.NEF` from the Library grid immediately after
  importing the 930-file folder, background thumbnail decoding
  genuinely concurrent) with no freeze; brief "Decoding RAW photo…"
  spinner shown instead. **Phase 6 slice 1 is now fully shipped AND
  live-verified, both freezes closed.**

### Phase 6 slice 2: boostAmount, the first RAW-native EditState field — SHIPPED and LIVE-VERIFIED
- User said "phase 6 slice 2" (via a decision point after slice 1's live
  verification closed out). Two candidates were measured live against
  the user's real Nikon D610 library BEFORE any code was written —
  matching this whole phase's established discipline of retiring risk
  empirically rather than by assumption.
- **`lensCorrectionEnabled`** (the original candidate, per CLAUDE.md's
  roadmap item 6) was MEASURED DEAD: a throwaway CLI probe against three
  real `.NEF` files
  (`/Users/praween/Pictures/Bolivia_trip/raw_files`) showed
  `CIRAWFilter.isLensCorrectionSupported == false` on all three — Apple's
  RAW lens-correction database apparently has no profile for this
  camera+lens combination, so the toggle would visibly do nothing on any
  photo the user actually has. Re-scoped (`AskUserQuestion`) to
  **`boostAmount`** (Core Image's own RAW tone-curve strength, `0...1`,
  default `1`) instead — also measured live first: real default `1.0`
  (matches the SDK header), and a genuinely different rendered pixel at
  `boostAmount = 0` vs `1` on the same real file (`[37,44,59]` vs
  `[36,41,52]`) — confirmed visible, not another no-op.
- **Architecturally distinct from every other `EditState` field**:
  `boostAmount` configures `CIRAWFilter` itself, upstream of
  `EditPipeline` — `EditPipeline.apply` is a pure `CIImage → CIImage`
  function with no file/URL access, and its own doc comment says "decode
  already happened before this point." So changing `boostAmount` can
  only take effect by re-decoding the file, not by re-running the
  pipeline against `RawDecoder.materialize`'s cached, already-baked
  buffer from slice 1 — exactly the "forward hazard for Phase 6 slice 2"
  that function's own doc comment predicted back then, now confirmed
  true. New `EditState.requiresRawRedecode(comparedTo:)` is the single
  source of truth for which fields behave this way (one today; slice 3's
  remaining RAW-native fields belong there too).
  `ImageDocumentModel.editState`'s `didSet` triggers a debounced
  (~0.4s — long enough to coalesce a slider drag into one re-decode, not
  N) async re-decode (`scheduleRawRedecode`/`redecodeForRawNativeChange`),
  sharing `loadGeneration`/`RawDecoder.RenderGate` with `load(from:)` so
  it can't race a photo switch or contend with concurrent RAW work
  elsewhere in the app — reusing, not duplicating, the exact machinery
  the two slice-1 freeze fixes built and got reviewed for. A new
  `isLoadInFlight` flag (distinct from `isLoadingImage`/`isLoadingPhoto`)
  refuses to fire a re-decode while a DIFFERENT photo is still loading —
  the Adjust sidebar stays interactive during a load (only the image
  pane shows the spinner), so the user really can drag the new slider
  mid-load.
- **A real ordering bug, confirmed by tracing the actual code, fixed
  along the way** (not `boostAmount`-specific — implied by adding ANY
  field that configures the decode itself): `load(from:)` restored the
  incoming photo's `EditState` only AFTER decoding, so the FIRST decode
  of any newly-opened RAW photo applied the OUTGOING photo's
  `boostAmount` (or `1.0` on first launch), with nothing downstream ever
  correcting it — the panel and the pixels would silently disagree until
  the user manually nudged the slider. Fixed by hoisting the sidecar
  read above the decode. That hoist had its own hazard, also fixed:
  `flushPendingSidecarSave()` had to move together with it (flush
  first), or re-opening the CURRENTLY-OPEN photo (a filmstrip tap on
  itself, or a ⌘←/⌘→ round-trip) while an edit was still inside its ~1s
  save debounce would read the stale on-disk sidecar and silently
  discard that pending edit.
- **`boostAmount` is deliberately excluded from BOTH
  `comparisonOriginal()` and `applyingPreset(onto:)`** — inherited like
  the 9 geometry fields, not reset/copied like every color/tone field.
  Reviewer-corrected reasoning (the first draft's comment overstated it
  as "a lying before/after" in the Compare feature; the real reason is
  simpler and more fundamental): `EditPipeline` never reads the field at
  all, so neither method has any way to actually apply a value to it
  regardless of what it's set to — inheriting it is the only coherent
  choice, not a judgment call about "looks vs. geometry." Consequence,
  confirmed correct: `revertToOriginal()`'s literal `EditState()` commit
  IS the control that resets `boostAmount` (and re-decodes); "Reset
  Adjustments" deliberately does not, and now says so explicitly in
  `isAdjustTabAtIdentity`'s own doc comment, including the resulting
  asymmetry (a RAW photo with a non-default Boost Amount but everything
  else at identity shows Reset Adjustments correctly disabled, since
  that button's whole field list mirrors `comparisonOriginal()`'s).
- **Reviewer (Opus 5, two full rounds — the default model hit the
  account's monthly spend limit mid-review on round 1, same pattern as
  both slice-1 fixes): FIX FIRST → APPROVE.** Round 1 caught three real
  bugs, all in the re-decode/reorder machinery specifically (nothing in
  the mechanical `RawDecoder`/`PhotoExporter`/`ThumbnailGenerator`
  threading, which the reviewer confirmed correct on the first pass):
  1. `redecodeForRawNativeChange()` had no generation check between the
     decode and the `materialize` call — a superseded re-decode (user
     switched photos mid-re-decode) still paid a full-res `materialize`
     inside the app-wide serialized `RenderGate` before discarding the
     result, needlessly delaying whatever actually superseded it. Fixed
     with a guard immediately after the decode succeeds.
  2. The `load(from:)` reorder narrowed but didn't close a window where
     a slider drag DURING the function's own decode/materialize awaits
     (the sidebar stays live for the outgoing photo throughout) would be
     silently discarded the moment `editState` was overwritten with the
     incoming photo's restored state. Fixed with a second
     `flushPendingSidecarSave()` immediately before the commit point,
     with no further `await` after it — verified this closes the gap
     completely. One narrow, accepted residual documented in code rather
     than engineered around: reopening the SAME already-open photo
     mid-drag can leave in-memory `editState` transiently behind what's
     already correctly saved to disk.
  3. A debounced re-decode scheduled during either await could survive
     the load it was scheduled during, then fire ~0.4s later as a
     guaranteed-no-op full re-decode of the photo just opened (which
     already decoded with the correct value). Fixed by cancelling the
     pending work item right after the incoming photo's `editState` is
     restored.
  Round 2 independently re-traced all three fixes against the rewritten
  code (not the summary) and confirmed no self-deadlock/reentrancy
  issue, plus two non-blocking observations logged for awareness (a
  pre-existing-shaped cold-bookmark `NSOpenPanel` reentrancy window,
  unchanged from before this slice; confirmation that dropping rather
  than deferring a blocked re-decode is always correct here, not just
  usually).
- 412 tests (9 new): `EditState` schema round-trip
  (`EditStateCodableTests`), the fully-populated memberwise test in
  `EditPipelineTests` gained the field, a new pinning test
  `testBoostAmountHasNoEffectOnTheEditPipeline` (varies `boostAmount` on
  top of ALREADY-active exposure/contrast/B&W/vignette, not just the
  identity case — reviewer-strengthened from an initial near-identity
  version, to also rule out interaction with live pipeline stages, not
  only prove it's inert alone), `comparisonOriginal`/`applyingPreset`
  preserve-not-reset tests in both directions, a new
  `EditStateRawRedecodeTests.swift` for `requiresRawRedecode`'s
  true/false cases, and `RawDecoderTests` updates including a
  non-RAW-files-ignore-`boostAmount` test. 2 commits (feature+tests,
  then this doc entry).
- **LIVE-VERIFIED (2026-09-03).** User confirmed the slider works
  correctly on a real RAW photo, including that it correctly defaults
  to 100% on open. One live question answered, not a bug: 100% IS the
  correct/full-strength default (`CIRAWFilter`'s own default), and
  there is no way to exceed it — `boostAmount`'s range is a strength
  dial on the decoder's own tone curve (0 = linear/off, 1 = full
  curve), not a brightness multiplier that could push further. The two
  interaction patterns an automated test can't reach (dragging while a
  DIFFERENT photo is still loading; switching photos immediately
  after/during a drag) were exercised as part of this pass with no
  issues reported.

### Phase 6 slice 3: rawExposureEV + shadowBoostScale — SHIPPED and LIVE-VERIFIED
- User chose this scope (via `AskUserQuestion`) over the true no-search
  WB eyedropper and RAW-native NR/sharpness specifically because it
  reuses slice 2's already-twice-reviewed re-decode/debounce/
  `RenderGate` machinery instead of touching an already-shipped feature
  or opening a precedence question against an existing pipeline stage.
- Live-measured against the real Nikon D610 library before any code was
  written, same discipline as slice 2 — and the measurements reshaped
  the design twice, not once:
  1. `CIRAWFilter` pre-populates `baselineExposure`/`boostShadowAmount`
     from the file's own embedded camera profile AT CONSTRUCTION TIME —
     measured `0.3`/`0.9` on real NEFs. First draft wrongly cited the
     SDK's declared defaults for both as `0`/`0` (reviewer-caught from
     the actual header: `baselineExposure`'s declared default is
     "can vary based on the image," and `boostShadowAmount`'s is `1`,
     not `0` — the anomaly is real, just smaller than first stated). An
     `EditState` field with a fixed default would have silently
     overridden each file's own camera profile on every load, so
     `shadowBoostScale` ships as a 0...1 SCALE of the file's own native
     value — the only relative (non-absolute) `EditState` field in this
     codebase.
  2. `boostShadowAmount`'s upward half was measured INERT: mean linear
     luma over the darkest quartile moved +3.5% at max (native→2.0) vs.
     -31% at zero (native→0), with 1.4 and 2.0 rendering identically —
     so the slider only exposes the half that does anything, same
     "measure before shipping dead travel" discipline that deferred
     `lensCorrectionEnabled` in slice 2.
- **Real reviewer-caught design change, not just a fix**: the exposure
  field's first draft mutated `baselineExposure` with `+=` (mirroring
  `shadowBoostScale`'s relative shape) to route around the per-file
  default problem above. Reviewer found, from the real SDK header, that
  `CIRAWFilter.exposure` is a SEPARATE property with a genuinely fixed,
  camera-profile-independent default of `0` — and live measurement
  confirmed `exposure = 2.0` and `baselineExposure += 2.0` render
  BYTE-IDENTICAL pixels on the same file. Switched to `filter.exposure`:
  identical rendered result, but a plain absolute assignment instead of
  a read-modify-write, so `rawExposureEV` (renamed from
  `baselineExposureAdjust` once the mechanism changed) stays fully
  deterministic on replay — closing what would otherwise have been this
  app's first exception to its own "replaying the same params must be
  deterministic" principle. Still measured distinct from the
  already-shipped `exposureEV` (post-decode `CIExposureAdjust`): at +2
  EV, decoder-level exposure clipped zero of 1600 sampled points above
  1.0 (max 0.9907) vs. `exposureEV`'s 99 of 1600 (max 1.9506) — the
  headroom advantage survived the mechanism swap intact, as expected
  since the two mechanisms were shown to render identically.
- Two more reviewer-caught, pre-commit fixes: (1) both remaining
  mutating properties (`exposure`, `boostShadowAmount`) are now guarded
  to only touch `filter` when non-identity — a STRUCTURAL guarantee
  rather than relying on `x += 0`/`x *= 1` being a semantic no-op on an
  ObjC-bridged property, which isn't guaranteed (a setter can plausibly
  flip an internal "user overrode this" flag regardless of the value
  written); (2) `decode` and `decodeDraft` applied these fields at
  different relative positions (before vs. after draft-mode/orientation
  setup) — now identical in both, immediately after construction,
  removing the need to measure whether that setup perturbs the
  profile-seeded values, the same defect class that already cost this
  app a thumbnail/Editor mismatch once (post-Phase-5 follow-up #4).
- `RawDecoder.decode`/`decodeDraft` widened from a single
  `boostAmount: Double` parameter to the whole `editState: EditState` —
  a third scalar the slice-2 way would have made the parameter list
  unwieldy and created a second place enumerating RAW-native fields that
  could drift from `requiresRawRedecode`. `applyRawNativeSettings` is
  now the one place all three fields are read; a slice-4 field needs no
  signature changes anywhere else.
- Shadow Boost row in `AdjustTabView` additionally disables itself
  whenever Boost Amount is `0` (reviewer-caught: the SDK header states
  `boostShadowAmount` "has no effect if the boostAmount is 0," so
  without this it would be a silently dead control — the same trap
  `lensCorrectionEnabled` was deferred to avoid).
- Reviewer (Opus 5, after the default model hit the account's monthly
  spend limit — same pattern as slices 1 and 2): FIX FIRST → APPROVE.
  Round 1 caught the 7 items above (the `exposure`-vs-`baselineExposure`
  mechanism switch, both citation errors, the dead-control coupling, the
  ordering inconsistency, and the structural no-op guards); a follow-up
  pass renamed 4 test function names that still referenced the dead
  `baselineExposureAdjust` field (bodies were already correct). 420
  tests (8 new): `EditState` schema round-trip for both new fields, the
  fully-populated memberwise test gained both, `EditPipelineTests`'
  no-effect-on-pipeline pinning test extended to vary all three
  RAW-native fields together (not just `boostAmount` alone),
  `EditStateRawRedecodeTests` gained independent true-cases for each
  field, `comparisonOriginal`/`applyingPreset` preserve-not-reset tests
  for both, `RawDecoderTests`' non-RAW-ignores-RAW-native-fields test
  extended to all three. 2 commits (feature+tests, then this doc entry).
- **LIVE-VERIFIED (2026-09-03).** User confirmed all of: RAW Exposure at
  +2 EV visibly retains highlight detail the regular Exposure slider
  blows out at the same +2; Shadow Boost visibly darkens shadows when
  pulled toward 0%; Shadow Boost's row visibly disables when Boost
  Amount is dragged to 0%; both sliders return to an identity-matching
  render at their defaults; and both race conditions automated tests
  can't reach (dragging a RAW slider then immediately switching photos;
  switching photos then dragging a RAW slider while the new one is still
  loading) behaved correctly. **Phase 6 slice 3 is now fully complete.**

### Post-Phase-5 follow-up #8: click-to-type numeric entry on every Adjust/Crop slider — SHIPPED and LIVE-VERIFIED
- User request: every slider shows a live formatted readout ("100%",
  "+2.00 EV") but it was plain non-interactive `Text` — dragging
  `ThinSlider` alone can't reliably hit an exact number.
  `EditSliderRow` (`Sources/UI/EditControlRows.swift`) now swaps the
  readout for a `TextField` on tap, typed in the SAME units already
  shown (a new `displayMultiplier: Double = 1` param — `100` for the 29
  percent-formatted rows across `AdjustTabView`/`CropTabView`, default
  `1` correct unchanged for the 7 EV/Kelvin/degree/plain-decimal rows)
  rather than trying to parse the formatted string's suffix.
  `displayMultiplier: 100` was added to all 29 percent rows via one
  scripted multi-line `perl` substitution, not hand-edited — reviewer
  independently re-parsed all 36 `EditSliderRow(` call sites
  programmatically and confirmed 0 misses, 0 spurious additions.
- Reviewer: FIX FIRST → APPROVE, two rounds. Round 1 caught three real
  bugs: (1) Escape wasn't a reliable cancel — `onExitCommand` only
  flipped `isEditingText`, leaving whether the edit actually discarded
  dependent on unverified ordering between that and the focus-loss
  `onChange`; fixed by explicitly clearing `editingText` back to the
  seed and resigning focus in the same closure, order-independent
  either way. (2) A plain tap-then-click-away with NO typing still
  wrote `value` from a lossy `"%g"`-formatted round-trip (e.g. `1/3`
  reformats to `0.333333`), firing a phantom undo-history entry and
  sidecar save for an interaction where nothing changed; fixed with a
  new `seedText` captured at edit-start, compared against the final
  text before committing — a true no-op when nothing was typed. (3)
  `"nan"`/`"inf"` parsed successfully and silently slammed the slider
  to its range minimum instead of no-opping; fixed with a
  `typed.isFinite` guard alongside the existing clamp. Round 2
  independently re-verified all three fixes close the hole (not just
  move it) and re-confirmed the mechanical 36-site check hadn't
  drifted while fixing. Two non-blocking nits also landed:
  `.contentShape(Rectangle())` on the readout (bigger tap target) and
  `.accessibilityLabel` on the new `TextField`.
- No new automated tests — `EditSliderRow` is a SwiftUI `View` body
  with no existing unit-test precedent in this codebase (only pure
  extracted geometry, like `ThinSliderGeometry`/`CropAspectMath`, gets
  tested, not the `View`s that use it) — verified live instead. 420
  tests unchanged. 2 commits (feature, then this doc entry).
- **LIVE-VERIFIED (2026-09-03).** User confirmed all 7 checklist items:
  click-to-edit works on a percent row (Contrast → 50%) and a
  non-percent row (Exposure → +2.50 EV); tap-then-click-away with no
  typing leaves the value and Reset-button state unchanged; Escape
  after typing discards the edit; garbage input (`"abc"`) reverts
  cleanly with no crash; and dragging `ThinSlider` itself is unaffected.
  Reviewer's two remaining non-blocking observations (Enter's
  focus-resignation relies on the same "SwiftUI removes the view, so
  `@FocusState` resets" assumption fix #1 deliberately stopped relying
  on for Escape; Enter fires `commitEditingText()` twice, harmlessly,
  since the second pass re-parses the identical already-committed
  string) are noted here, not fixed — low-risk, and the reviewer's own
  call was "worth doing only if touching the file again."

### Phase 6 slice 4: rawWhiteBalanceNeutralPoints, a true no-search RAW white-balance eyedropper — SHIPPED and LIVE-VERIFIED
- User chose this scope over RAW-native NR/sharpness and the
  `CIRAWDecoderVersion9` opt-in. `CIRAWFilter.neutralLocation`: set it to
  a pixel, the decoder computes and applies the correct white balance
  directly — no search, vs. the existing eyedropper's `WhiteBalanceSolver`
  (~52-evaluation search against post-decode `CITemperatureAndTint`).
- **Measurement changed the design twice, not once**, same discipline as
  every RAW slice this session:
  1. Feeding `CIRAWFilter`'s own computed `neutralTemperature`/
     `neutralTint` for a tapped point directly into the app's EXISTING
     `whiteBalanceTemperature`/`whiteBalanceTint` fields does NOT
     neutralize the same pixel — measured `[37,44,59]` → `[48,43,38]`
     (right direction, nowhere near neutral) vs. `[47,47,48]` via
     `neutralLocation` itself. The two mechanisms are numerically
     incompatible, so this shipped as a genuine FOURTH RAW-native
     `EditState` field (`rawWhiteBalanceNeutralPoints: [RawNeutralPoint]`,
     at most one element, mirrors `redEyePoints`' empty-means-off
     convention), following `boostAmount`/`rawExposureEV`/
     `shadowBoostScale`'s exact architecture — not a thin translation
     layer on top of the existing two fields.
  2. `neutralLocation` operates on the RAW's own native, un-rotated,
     PRE-geometry pixel grid. A tap on the CURRENT on-screen view would
     need inverting through straighten/perspective/crop/flip to map back
     — not simple math for straighten/perspective. User chose (via
     `AskUserQuestion`) to sidestep this: the fast path only activates
     when app geometry is at identity (new `EditState.isGeometryAtIdentity`,
     covering the same 9-field group already named together in
     `comparisonOriginal()`/`applyingPreset()`) — found live, WHILE
     verifying this, a SECOND related hazard: `neutralLocation` measured
     to produce a different, implausible result depending on whether
     `orientation` was already non-`.up` at assignment time (identical
     regardless of order when orientation is `.up`) — so the fast path
     ALSO requires the file's EXIF orientation to be CONFIRMED `.up`.
     Every other case falls through unchanged to the existing search.
- New `RawDecoder.confirmedOrientation(of:)` — `RenderGate`-gated,
  returns the real `Optional` (unlike `exifOrientation(of:)`'s `.up`
  fallback) — read ONCE per RAW photo load, cached on
  `ImageDocumentModel.currentRawOrientationIsUp`, not re-read at tap time.
- Reviewer (Opus 5, after the default model hit the account's monthly
  spend limit TWICE mid-review — same pattern as every prior slice):
  FIX FIRST → APPROVE. Round 1 caught three real bugs, all found by
  tracing actual reachability, not by inspection alone:
  1. The fast path wrote ONLY `rawWhiteBalanceNeutralPoints`, leaving
     any pre-existing non-identity `whiteBalanceTemperature`/
     `whiteBalanceTint` (from a manual nudge, "Fix Color Cast", a preset,
     or an earlier slow-path tap before a crop was later removed) still
     applied POST-decode on top of the RAW-neutralized result — a
     silent double-correction with no message explaining it. Fixed: the
     fast path now also resets both fields to identity, matching the
     slow path's own always-overwrite semantics.
  2. The orientation gate used `exifOrientation(of:)`, which defaults
     UNREADABLE to `.up` — precisely the case the whole "confirmed `.up`"
     design exists to avoid, since an unreadable file's TRUE orientation
     could just as easily be non-`.up`. Fixed: gate on
     `confirmedOrientation(of:)`'s real `Optional`, requiring a
     genuinely-read `.up`, never a fallback.
  3. The gate re-opened the file synchronously (ImageIO) on the main
     actor at tap time — reintroducing a defect class this exact
     function was already reviewer-caught and fixed for once before (see
     `RawDecoder.decode`'s own doc comment, Phase 6 slice 1). Fixed by
     the load-time RenderGate-gated caching described above.
  Also flagged and fixed: an edge-case where a neutral point at fraction
  `1.0` would land one pixel past the last valid row/column (clamped to
  `nativeSize - 1`); stale doc comments still listing 3 RAW-native fields
  instead of 4; and an inaccurate claim that `orientation` is "never
  actually changed from its default" on the fast path (it IS assigned,
  just to the same value it already held — reworded to say that
  precisely). Measured live before commit, per the reviewer's ask:
  `neutralLocation` produces IDENTICAL results through `decodeDraft`'s
  draft-mode/`scaleFactor` path as a full decode (confirmed a RAW
  thumbnail won't diverge from the Editor's own rendering) — recorded in
  `decodeDraft`'s own doc comment.
- 435 tests (15 new): a new `EditStateGeometryIdentityTests.swift`
  (11 tests — one independent false-case per geometry field, so a
  missed `&&` clause can't hide behind another), plus the established
  RAW-native-field test set (`EditStateCodableTests`,
  `EditPipelineTests`, `EditStateRawRedecodeTests`,
  `EditStateComparisonOriginalTests`, `EditStatePresetTests`,
  `RawDecoderTests`) extended for the fourth field, mirroring slice 3's
  own additions exactly. 2 commits (feature+tests, then this doc entry).
- **Known gap, accepted for this slice**: unlike the other three
  RAW-native fields, this one has NO UI representation at all — no
  slider, not shown anywhere, not resettable except via Undo or Revert
  to Original. Documented explicitly in `AdjustTabView`'s existing
  gap-note doc comment (the same one that already covers `boostAmount`/
  `rawExposureEV`/`shadowBoostScale`'s absence from "Reset Adjustments").
- **LIVE-VERIFIED (2026-09-04).** User confirmed all 6 checklist items:
  a fresh RAW photo with no geometry edits corrects near-instantly on
  tap (no visible "solving" delay); an asymmetric tap test (a clearly
  warm area, then a clearly cool area) both corrected sensibly, with no
  sign of an inverted y-origin; adding a crop and tapping again fell
  back to the existing slower search, behaving exactly as before this
  slice; a fast-path correction survived a LATER crop being added
  (stayed anchored to the RAW's own native grid, not invalidated); and
  a non-RAW photo's eyedropper was completely unaffected. **Phase 6
  slice 4 is now fully complete.**

### Phase 6 slice 5: RAW-native Noise Reduction + Sharpness — SHIPPED and LIVE-VERIFIED
- Originally deferred pending "a precedence decision" — the app already
  has post-decode `noiseReduction`/`sharpness` fields
  (`EditPipeline`'s `CINoiseReduction`/`CISharpenLuminance`, any photo
  type). Resolved by measurement: the three new RAW-native fields
  (`rawLuminanceNoiseReductionAdjust`, `rawColorNoiseReductionScale`,
  `rawSharpnessScale`) configure `CIRAWFilter` itself at DECODE time,
  entirely upstream of and independent from those post-decode stages —
  they compose additively, same relationship `rawExposureEV` already has
  with `exposureEV`. No replacement, no mutual exclusion, no UI
  conflict.
- Measured live before design, same discipline as every RAW slice:
  unlike `lensCorrectionEnabled`, all three ARE supported on this camera
  (`isLuminanceNoiseReductionSupported`/`isColorNoiseReductionSupported`/
  `isSharpnessSupported` all `true` on three sampled D610 NEFs) — viable,
  not another dead end. Native per-file defaults measured `0.0`/`0.5`/
  `0.9` — matches `shadowBoostScale`'s own per-file-camera-profile-seeded
  pattern (SDK header: "the default value will vary per image" for all
  three), not `boostAmount`'s universal-default pattern. No
  absolute-with-fixed-default sibling exists for any of the three (no
  `exposure`-to-`baselineExposure` equivalent), so — like
  `shadowBoostScale` — each was designed as a relative field reading
  `filter`'s own current value first.
- **Reviewer (Opus 5, after the default model hit the account's monthly
  spend limit — same pattern as every prior slice): FIX FIRST →
  APPROVE.** Caught two real bugs, both found by re-measuring rather
  than trusting the first draft's own stated reasoning:
  1. `rawLuminanceNoiseReductionAdjust` was originally shipped with the
     SAME multiplicative `*=` scale shape `shadowBoostScale` uses — but
     this camera's own native `luminanceNoiseReductionAmount` measures
     EXACTLY `0.0`, so `native * anything` is always `0`: a provably
     dead control across its ENTIRE range (not a narrow inert band like
     `boostShadowAmount`'s upper half — the whole slider). This is
     precisely the trap `lensCorrectionEnabled` was deferred to avoid in
     slice 2, just discovered a slice later instead of before shipping.
     Fixed by switching to an ADDITIVE offset
     (`filter.luminanceNoiseReductionAmount = min(1, max(0, native +
     adjust))`, guarded `!= 0`, range `-1...1`, identity `0`) — the
     reviewer's own methodology (256×256 region, total abs delta) gave
     `80914` for the shipped absolute-assignment control case;
     re-verified live that the additive fix's `+1.0` path reproduces
     that EXACT number, confirming it reaches the genuinely useful range
     above `0.0` a scale never could.
     `rawColorNoiseReductionScale`/`rawSharpnessScale` stayed
     multiplicative (native `0.5`/`0.9`, meaningfully non-zero, measured
     effective as scales) — their doc comments now flag that a future
     camera with a near-zero native default here would hit the same
     trap; re-measure before assuming the shape holds.
  2. All three fields' doc comments claimed "no capability gate
     needed" — FALSE: `isLuminanceNoiseReductionSupported`/
     `isColorNoiseReductionSupported`/`isSharpnessSupported` are
     structurally identical to `isLensCorrectionSupported`, the exact
     flag that killed `lensCorrectionEnabled`. Measured `true` on this
     camera (so shipping is still correct), but the code ignored the
     flag entirely — on a camera where any one measures `false`, that
     row would be a silent dead slider still paying a full re-decode.
     Fixed with new `RawDecoder.confirmedAdjustmentSupport(of:)`
     (`RenderGate`-gated, mirrors `confirmedOrientation`'s own slice-4
     caching pattern exactly), read ONCE per RAW photo load and cached
     on `ImageDocumentModel.currentRawAdjustmentSupport`
     (`@Published`, unlike the orientation cache — `AdjustTabView`
     reads it directly to disable each of the three rows individually).
  Also fixed pre-commit: 4 dangling doc/test-name references left by the
  `rawLuminanceNoiseReductionScale` → `...Adjust` rename (caught in the
  reviewer's own final pass); renamed `RawAdjustmentSupport.none` →
  `.unsupported` (non-blocking — `.none` on a custom type is a known
  Swift footgun, collides with `Optional.none` at any future optional
  use site).
- 447 tests (12 new): the established RAW-native-field test set
  (`EditStateCodableTests`, `EditPipelineTests`,
  `EditStateRawRedecodeTests`, `EditStateComparisonOriginalTests`,
  `EditStatePresetTests`, `RawDecoderTests`) extended for all three new
  fields, mirroring slice 3's own additions. 2 commits (feature+tests,
  then this doc entry).
- **Non-blocking, confirmed by live measurement, not a new bug**:
  `decodeDraft`'s `isDraftModeEnabled` path produces ZERO pixel delta
  for all three new fields — RAW Library thumbnails will never reflect
  any of these three sliders while the Editor does. Same divergence
  class as post-Phase-5 follow-up #4, logged as a known gap rather than
  fixed this slice (reviewer's own call: verify this is the observed
  live behavior, don't chase it as a regression).
- **LIVE-VERIFIED (2026-09-04), with one real observation along the
  way.** User confirmed the RAW section shows all six sliders correctly
  at identity on open. User then reported RAW Luminance NR and RAW
  Color NR both looked "barely visible" when dragged on their real test
  photos — a legitimate live finding, not dismissed. Root-caused (not
  assumed): both are noise-reduction controls, and noise reduction is
  CONTENT-ADAPTIVE — it only visibly changes pixels where noise actually
  exists. The reviewer's own earlier measurement is consistent with this
  explanation rather than contradicting it: RAW Color NR's measured
  pixel delta (203683 over a 256×256 region) was actually the LARGEST of
  the three RAW-native fields, larger than RAW Exposure or RAW Luminance
  NR — so the underlying code is doing substantial work; the visibility
  gap is about the SOURCE PHOTOS (a daylight travel shoot, low ISO, good
  light — genuinely low-noise source material, especially outside
  shadow regions) rather than a code defect. User accepted this
  explanation and confirmed moving on without further live-testing of
  the individual sliders' visual effect. The remaining checklist items
  (mid-drag/switch-mid-drag races, thumbnail-vs-Editor divergence) were
  NOT independently re-exercised this pass — accepted as lower-risk
  since they reuse the exact `loadGeneration`/`RenderGate`/debounce
  machinery already live-verified across slices 2-4, and the thumbnail
  divergence was already confirmed by direct measurement (not live
  observation) before commit, per this slice's own section above.
  **Phase 6 slice 5 is now considered complete for this session's
  purposes.**

### Phase 6 slice 6: RAW-native Contrast, Detail, Moiré Reduction — SHIPPED and LIVE-VERIFIED
- Live-measured BEFORE writing any code, applying slice 5's own lesson
  proactively instead of re-discovering it: all three underlying
  `CIRAWFilter` properties (`contrastAmount`, `detailAmount`,
  `moireReductionAmount`) have a native default of `0.0` on this camera
  — the exact degenerate case that made
  `rawLuminanceNoiseReductionAdjust`'s ORIGINAL multiplicative-scale
  design dead-on-arrival in slice 5. All three shipped as ADDITIVE
  offsets from the start this time, not a repeat of that mistake.
  Confirmed supported (`isContrastSupported`/`isDetailSupported`/
  `isMoireReductionSupported` all `true` on three sampled D610 NEFs —
  viable, not another `lensCorrectionEnabled`-class dead end) and
  confirmed substantial real effect via absolute assignment (256×256
  region, total abs delta vs. identity): `contrastAmount` at `1.0` →
  `290565` (the LARGEST single-field pixel effect measured anywhere in
  this app's RAW-native work so far, bigger than any field from slices
  2-5), `detailAmount` at `3.0` → `180787`.
- **A real SDK documentation bug, found and worked around, not just
  trusted.** `moireReductionAmount`'s own header comment says "A value
  of 3 indicates maximum moire reduction" but the very next line
  declares "The value should be the range of 0...1" — an internal
  contradiction, almost certainly a copy-paste artifact from the
  adjacent `detailAmount` comment (which genuinely has range `0...3`).
  Measured, not trusted either half of the contradictory text: the
  property genuinely accepts and RETAINS values up to `3.0` with no
  clamping (readback confirmed `1.0→1.0`, `2.0→2.0`, `3.0→3.0`) — so the
  true valid range is `0...3` like `detailAmount`. BUT the measured
  EFFECT saturates hard near `1.0`: delta grew only `48097 → 48730 →
  49564` across the entire `1.0 → 2.0 → 3.0` span (~3% total change
  over 2 full extra units of range) — the same "inert long tail" pattern
  `boostShadowAmount` showed above its own native value in slice 3.
  `rawMoireReductionAdjust`'s `EditState` field is therefore capped at
  the measured-useful `-1...1` in the UI, even though `CIRAWFilter`
  itself would accept a wider range — the applied RESULT still clamps
  to the property's true `0...3` range internally, only the exposed UI
  travel is narrowed.
- Reviewer (Opus 5, after the default model hit the account's monthly
  spend limit — same pattern as every prior slice): **APPROVE on the
  FIRST pass — no FIX FIRST round needed**, the first slice in this
  RAW-native sequence to clear review without a caught bug, because
  slice 5's lesson (measure native defaults before choosing scale vs.
  offset) was applied proactively instead of being re-learned the hard
  way. Verified: all three fields use the additive shape throughout (no
  `*=` anywhere); each field's clamp range matches its own measured
  valid range correctly (Contrast `0...1`, Detail `0...3`, Moiré's
  input narrowed to `-1...1` while its result still clamps to the full
  `0...3`); the shared `RawAdjustmentSupport` capability-gate struct
  (built in slice 5) was extended to all six NR/Sharpness/Contrast/
  Detail/Moiré fields without regressing the three existing ones, and
  `ImageDocumentModel`'s existing caching needed zero changes since it
  stores the struct whole.
  Two non-blocking notes fixed before commit: a stale doc comment on
  `ImageDocumentModel.currentRawAdjustmentSupport` still said
  "NR/Sharpness" instead of naming all six now-gated fields; and an
  explicit doc-comment acknowledgment added that the NEGATIVE half of
  all three new sliders is inert on THIS specific camera (native `0.0`
  is the property's own floor, so `max(0, 0 + negative) == 0`) — kept
  symmetric anyway as camera-generic design (a body with a genuinely
  non-zero native default, which the SDK's own "varies per image"
  wording implies exists, would have real use for the negative half),
  not a UI call about this camera's own inert range the way the moiré
  cap was.
- 459 tests (12 new): the established RAW-native-field test set
  (`EditStateCodableTests`, `EditPipelineTests`,
  `EditStateRawRedecodeTests`, `EditStateComparisonOriginalTests`,
  `EditStatePresetTests`, `RawDecoderTests`) extended for all three new
  fields, mirroring slice 5's own additions exactly — each test uses
  values respecting its OWN field's correct range (not copy-pasted
  values that would violate a narrower field's bounds). 2 commits
  (feature+tests, then this doc entry).
- **LIVE-VERIFIED (2026-09-04).** User confirmed the new RAW sliders
  work as expected on the real D610 library. Along the way, user asked
  a genuinely useful architecture question — whether RAW Contrast
  should look different from the app's EXISTING (post-decode, global,
  `CIColorControls`-based) Contrast slider. Answered from Apple's own
  SDK documentation (not independently re-verified live this session):
  `CIRAWFilter.contrastAmount`'s header explicitly describes it as
  **local, edge-aware contrast** — "applied to the edges of the
  image" — architecturally closer to this app's existing Definition/
  Clarity slider (`CIUnsharpMask`-based local contrast) than to its
  global Contrast slider, despite the "RAW Contrast" label's naming
  suggesting a direct parallel to the latter. Worth a future rename
  (e.g. "RAW Local Contrast") if this reads as confusing once used more —
  not changed this pass since it wasn't requested. RAW Moiré Reduction's
  expected subtle-to-invisible-without-real-moiré-content caveat, flagged
  proactively this time (learning from slice 5's noise-reduction
  surprise), did not come up as an issue.

### Phase 6 slice 7: `rawDecoderVersionPin` — deterministic RAW decode across OS updates — SHIPPED, reviewer-APPROVED (3 rounds), and LIVE-VERIFIED (2026-09-04)
- Closes a gap CLAUDE.md logged all the way back at slice 1:
  `CIRAWFilter.decoderVersion` defaults to "the newest available decoder
  for the image type" and was neither pinned nor serialized — meaning
  replaying the exact same saved edit after a future macOS/Core Image
  update could silently decode a RAW photo differently, the one
  documented exception to this app's "replaying the same params must be
  deterministic" principle.
- The user picked this slice via AskUserQuestion framed as
  "`CIRAWDecoderVersion9` opt-in" — live measurement before writing any
  code showed that framing didn't actually apply: `supportedDecoderVersions`
  for a real D610 NEF on this system returns only `[6, 7]` (version 9 isn't
  offered here at all), and the SDK header confirms a freshly-constructed
  filter already defaults to the newest available version automatically —
  there's no "opt in to get newer" action to build. Reframed as the
  determinism/pinning problem instead. Confirmed live the setting genuinely
  matters: switching this camera's decoder from its own default (7) to 6
  produced a substantial measured pixel delta (57790, 256×256 region) — a
  materially different demosaic, not cosmetic. Confirmed position-independent
  (unlike `neutralLocation`): setting `decoderVersion` before vs. after
  `boostAmount` produced byte-identical output.
- Deliberately no new UI — this is bookkeeping, not a tunable control.
  `EditState.rawDecoderVersionPin: String = ""` (11th RAW-native field,
  `""` = not yet pinned). `RawDecoder.applyRawNativeSettings` applies it via
  a MEMBERSHIP check against `filter.supportedDecoderVersions`, not a
  min/max clamp like every other RAW-native field — the SDK header
  documents an out-of-list assignment produces a nil output image.
  `ImageDocumentModel.load(from:)` captures the pin exactly once, only when
  a RAW photo's restored `EditState` has it still empty (a never-opened
  photo, or a pre-slice-7 sidecar that predates the field) — never
  overwritten once set.
- **Reviewer (Opus 5, launched with the `opus` model override from the
  start this time — not after a default-model spend-limit failure, given
  this session's repeated history of hitting it mid-review): 3 full
  rounds, FIX FIRST → FIX FIRST → APPROVE.**
  - **Round 1, both blocking:** (1) the pin was captured into
    `restoredState` but that assignment to `editState` happens inside the
    `isLoadingPhoto` bracket, which deliberately suppresses
    `scheduleSidecarSave()` — so a photo with a PRE-EXISTING sidecar (from
    before this slice shipped) got backfilled only in memory, never
    persisted to disk, unless the user happened to make another real edit.
    Defeated the slice's entire purpose for exactly the photos it mattered
    most for. Fixed by tracking whether `loadSidecarIfReachable` returned
    non-nil, and — only in that case — calling `saveSidecarNow()` directly
    after `currentURL`/`editState` are committed, with no new folder-access
    prompt introduced (access was already known-resolvable). (2)
    `revertToOriginal()`'s literal `EditState()` cleared the pin, and unlike
    `load(from:)`'s write this one ISN'T `isLoadingPhoto`-guarded — so
    revert both wrote an unpinned sidecar AND immediately re-decoded with
    "whatever's currently newest" instead of the photo's original pin,
    silently reintroducing the exact non-determinism this field exists to
    close. Fixed by carrying the pin forward explicitly instead of
    resetting it — the one RAW-native field revert does NOT clear.
  - **Round 2, blocking (a real bug round 1 introduced and round-1 fixes
    made permanent):** carrying the pin through both load and revert means
    a RAW photo's `editState` never again equals literal `.identity` — so
    "Revert to Original"'s `.disabled(editState == .identity)` gate in
    `ContentView` read as permanently ENABLED for every RAW photo,
    including a never-touched one; clicking it would commit a real history
    step and fire a real sidecar save/possible folder-access prompt for a
    photo the user never edited. Fixed with a new
    `EditState.isEffectivelyIdentity` (copies self, clears only
    `rawDecoderVersionPin`, compares to `.identity`) — every "is this photo
    edited?" call site must use this instead of a bare identity comparison
    once a RAW photo always carries a pin. Deliberately did NOT apply the
    same fix to `ThumbnailGenerator`'s own `!= .identity` fast-path check —
    that path intentionally decodes UNPINNED, so making it pin-insensitive
    would desync the grid thumbnail's decoder version from the Editor's;
    left as a documented, non-blocking perf nit (an identity-but-pinned RAW
    photo pays one extra `EditPipeline` pass in the grid — correct, just
    not maximally fast).
  - Also took a non-blocking round-2 suggestion: `saveSidecarNow()` gained
    a `suppressErrorMessage` parameter (default `false`, only the new
    backfill call opts in) — so opening a never-edited RAW photo on a
    read-only volume doesn't surface "Couldn't save edits" from merely
    viewing it, preserving this app's "opening a photo should never itself
    produce an error/prompt" invariant.
  - A third non-blocking note (`RawDecoder`'s comment stating the SDK's
    nil-output warning as unconditionally observed, when the reviewer's own
    live measurement on this OS/macOS 26 showed it's actually silently
    ignored) was reworded to attribute the claim to the header specifically
    and note what was actually measured here — this project's "measured,
    not assumed" documentation convention.
- 465 tests (11 new, including 2 requested by the round-2 reviewer directly
  for `isEffectivelyIdentity`: identity-plus-pin is effectively-identity,
  identity-plus-pin-plus-one-real-field is not). 2 commits (feature+tests,
  then this doc entry).
- **LIVE-VERIFIED (2026-09-04), full checklist, all confirmed by the
  user**: a never-before-edited RAW photo (`DSC_1401.NEF`) showed
  `rawDecoderVersionPin: "7"` in its sidecar after a trivial edit;
  clicking Revert to Original preserved the pin (`"7"`, unchanged) and
  correctly returned the button to disabled — the round-1 and round-2
  fixes both confirmed working together, not just independently; a
  SEPARATE photo edited in a prior session (`DSC_1425.NEF`, sidecar with
  no `rawDecoderVersionPin` key beforehand) was opened with NO edit made
  and its sidecar was immediately backfilled with the pin — the direct
  test of the round-1 persistence fix, confirmed working.
  **A separate, unrelated flake surfaced mid-pass and was investigated,
  not shipped as a code change**: "Couldn't save edits" appeared after
  granting folder access on a real edit, and did NOT self-heal on an
  immediate retry within the same running app process (unlike the
  Phase-5-era flake documented near line 3600, which self-healed on a
  second grant attempt in the same process). Investigated with temporary
  `print`-based diagnostic logging added to `saveSidecarNow`/
  `requestFolderAccess`/`resolvedBookmarkURL` (same technique as the
  Phase-5 investigation) — before the logging was even exercised, a
  genuinely fresh process launch (running the built `.app` directly from
  Terminal instead of reusing whatever was already running) resolved it
  cleanly with zero code changes needed. Consistent with a stale/lingering
  process holding onto security-scoped resource state from an earlier
  debug session, not a regression in this slice's own code — the
  diagnostic logging was fully reverted (`git checkout --` on the one
  touched file, confirmed empty `git status`) since it was never needed
  to find a root cause. Flagged here in case it recurs and needs deeper
  investigation (mirroring the existing carried-forward note near line
  3600 for the earlier variant of this same class of flake).

### IMPROVEMENTS.md P3 — cache `EditPipeline.apply` output in `ImageRenderer` — SHIPPED and reviewer-APPROVED (first pass) 2026-09-04
- The user asked for P2 and P3 together; per IMPROVEMENTS.md's own working
  agreement, P2 (full-res pipeline re-render during an active slider drag)
  should only be attempted after P3 (cheap, low-risk) ships and gets its
  OWN separate measurement — P3's cache doesn't help P2's scenario, since
  `editState` genuinely changes every frame during a drag, so it's a cache
  miss every time regardless. This entry covers P3 only; P2 is queued next.
- **Explore agent research first** (this session's Plan Mode workflow):
  read `ImageRenderer.swift`, `MetalImageView.swift`, `EditPipeline.apply`,
  and the existing debounce idioms before designing. Two findings changed
  the plan from IMPROVEMENTS.md's original suggestion: (1) `EditPipeline.apply`
  is a pure `(EditState, CIImage) -> CIImage` with no side effects, so a
  cache key is trivially `(image identity, EditState value)`; (2)
  IMPROVEMENTS.md's own suggested approach — "reuse `MetalImageView.updateNSView`'s
  existing equality check" — turned out NOT sufficient: a resize redraw
  (`ResizingMTKView.setFrameSize`) calls `setNeedsDisplay` directly and
  reaches `draw(in:)` WITHOUT ever going through `updateNSView` at all, so
  a cache dependent on that method having run first would be stale on
  every resize. Redesigned as a fully self-contained cache inside
  `ImageRenderer`, re-checked at the top of every `draw(in:)` call instead.
- **Measured BEFORE writing the fix, not just after** (this session's own
  established discipline, matching P4/every RAW-native slice): temporary
  `CFAbsoluteTimeGetCurrent()` print instrumentation (no `os_signpost` or
  `OSLog` exists anywhere in this codebase — confirmed via grep — so this
  used the same tool as the one existing timing precedent,
  `ThumbnailCacheTests.swift`), added, exercised live by the user, then
  fully reverted before commit (confirmed via a clean `git diff`/`git status`).
  **BEFORE**: opened a large photo, dialed in non-trivial Sharpen + Noise
  Reduction + Definition (the three stages IMPROVEMENTS.md flags as
  forcing full-resolution work), then resized the window and zoomed/panned
  repeatedly with NO slider touched. Per-frame `EditPipeline.apply` cost
  was mostly 0.07-4.7ms but included real spikes: **38.6ms and 458.9ms** —
  a genuinely observed near-half-second stall on a redraw where nothing
  but the fit transform changed, not a theoretical concern.
- **Shipped**: five new private stored properties on `ImageRenderer`
  (`cachedSourceImage`/`cachedEditState`/`cachedEdited`/
  `cachedOriginalState`/`cachedOriginal`), re-validated at the top of
  every `draw(in:)`. `image !== cachedSourceImage` (identity, matching
  `updateNSView`'s own existing comparison) invalidates BOTH cached
  outputs on any true photo change; `edited` is separately keyed on
  `editState` value, `original` (Compare mode) separately on
  `compare.originalState` value — two different `EditState`s against the
  same source image, so two independent cache slots, not one shared key.
  A cache hit returns the EXACT SAME `CIImage` instance a miss would
  freshly compute — not an approximation — so there is no possible visual
  difference from this change, only a difference in how often the graph
  gets rebuilt.
- **AFTER** (identical exercise, same photo, same slider settings, fresh
  process launch): per-frame cost dropped to **~0.002-0.008ms** — just the
  cache-key comparison — with both large spikes completely gone. Recorded
  honestly per this project's "measured, not assumed" convention: most
  frames were ALREADY sub-millisecond even before the fix, so the
  steady-state improvement is modest in absolute terms; the real win is
  eliminating the rare-but-real 38-459ms stalls.
- Reviewer (Opus 5): **APPROVE on the first pass** — traced the
  identity-key premise ("`currentImage` is only ever reassigned wholesale,
  never mutated in place") against the actual write sites in
  `ImageDocumentModel.swift` (exactly two: the load path and the RAW
  re-decode path, both fresh `CIImage` construction, confirmed `CIImage`
  is immutable and `RawDecoder.materialize` never pools/reuses buffers)
  rather than trusting the doc comment's claim; confirmed no
  cross-contamination between the `edited`/`original` cache slots;
  confirmed every `draw(in:)` entry path (normal edit, resize, zoom/pan,
  divider drag, Compare toggle on/off/on) is handled correctly since the
  cache is self-validated inside `draw(in:)` itself, not dependent on
  `updateNSView`; confirmed `@MainActor`-safety (same isolation domain as
  the pre-existing `image`/`editState`/`compare` properties, no new
  concurrency surface); confirmed via grep that no debug print/timing
  leftovers remain anywhere in the diff. Two non-blocking notes, neither
  requiring action: `cachedOriginal` stays retained (harmlessly — a lazy
  recipe, not decoded pixels) after Compare is toggled off, until the next
  real photo change; and the cache's correctness depends on
  `EditPipeline.apply`'s signature staying exactly `(EditState, CIImage)
  -> CIImage`, already documented at the cache's own declaration as a
  flag for if Phase 7 masking ever adds a renderer-level input that isn't
  an `EditState` field.
- No new automated tests — `ImageRenderer`/`draw(in:)` has zero existing
  test precedent in this codebase (Metal-coupled rendering glue, same
  category as the y-flip/Compare-split/zoom-crop-bleed bugs that were
  live-caught, not unit-test-caught); judged instead by the
  cache-hit-returns-identical-instance argument (true by construction) and
  live visual verification. 465 tests unchanged, build clean. 1 commit
  (feature only — no test files touched).
- **LIVE-VERIFIED for visual correctness (2026-09-04)**: user confirmed
  Compare-off resize/zoom/pan and Compare-on (Side by Side + Split)
  resize/zoom/pan/divider-drag all render correctly with no stale-frame
  artifacts, and a real slider edit still shows up immediately (cache-miss
  path confirmed working, not just the cache-hit path). **IMPROVEMENTS.md
  P3 is now fully shipped, reviewed, and live-verified.**
- **P2's own required measurement is DONE and justifies proceeding
  (2026-09-04).** Same temporary `CFAbsoluteTimeGetCurrent()` instrumentation
  approach as P3's, timing the FULL `draw(in:)` end-to-end during an ACTUAL
  slider drag (Sharpen dragged continuously, same photo/heavy-stages setup
  as P3's measurement) — a genuinely different scenario from P3's
  static-redraw test, since P3's cache is a guaranteed miss on every frame
  of a real drag (`editState` changes every frame). Result: frequently well
  above IMPROVEMENTS.md's own 16ms/60fps threshold (22.9, 40.2, 41.6, 19.3,
  20.7, 40.7, 29.4ms, ...), with two severe outliers at **184.7ms and
  279.0ms** — real observed stutters, not theoretical. Instrumentation
  fully reverted (confirmed via clean `git diff`). Proceeding to a Plan
  Mode session for the downscaled-proxy design next.

## Exact next step
**Phase 2, Phase 3, Phase 4, and now Phase 5 are ALL COMPLETE**, plus eight
user-requested follow-ups (folder-mirrored nested collections; the Editor
Adjust-tab sidebar restyle; the custom thin slider; the Editor-vs-Preview
color-fix; Library thumbnails reflecting edits; Compare mode; zoom and pan;
Library sort/filter/search) — see their own sections above. Phase 5's two
slices: batch export (including the entitlement-fix debugging saga and 2
reviewer-caught bugs) + its immediate follow-up (selecting individual
photos for export), and Presets (2026-09-01/02, see its own section above,
including the mid-review spend-limit switch to Opus 5, 2 fixes applied
before commit, and live verification by the user on 2026-09-02, alongside
an investigated-but-unrelated-and-since-resolved sidecar-save permission
issue). All reviewer-APPROVED and live-verified. Phase 5: 390 tests passing,
app fully functional.

**Phase 6 slice 1 (RAW support, decode only, via Core Image's `CIRAWFilter`)
is SHIPPED, reviewer-APPROVED, and fully LIVE-VERIFIED (2026-09-02/03) —
see its own section above.** TWO severe freezes surfaced during the user's
first live pass (opening a RAW photo froze the app; retrying after the
first fix froze it again, differently) — both diagnosed, fixed,
reviewer-approved (two full rounds each), and re-verified live on
2026-09-03 with no recurrence; see the two "Phase 6 slice 1 follow-up"
sections immediately above. Full checklist passed on the user's real
930-file Nikon D610 `.NEF` library
(`/Users/praween/Pictures/Bolivia_trip/raw_files`): Open… and Library-grid
opening both render right-side-up with no hang; RAW thumbnails match the
Editor's own rendering; grid scroll across all 930 files was acceptable
(the documented ImageIO-embedded-preview fallback was NOT needed); slider
edits persist through both a Library round-trip and a full quit/relaunch;
RAW→JPEG export works. 403 tests passing. **A separate, unrelated
observation from this pass**: imported photos appeared in "random" order
— not a bug, `LibraryFilterSort`'s "Name (A–Z)" sort option (already
shipped, Post-Phase-5 follow-up #7) already solves this; the DEFAULT sort
("Oldest First") just preserves raw filesystem scan order for backward
compatibility, and the sort `Picker` in the grid's filter bar is easy to
miss alongside Rating/Flag/Search. No code change made or needed.

**Phase 6 slices 1-3 are all SHIPPED, reviewer-APPROVED, and fully
LIVE-VERIFIED (2026-09-03) — see their own sections above.** Post-Phase-5
follow-up #8 (click-to-type numeric entry on every Adjust/Crop slider) is
ALSO SHIPPED, reviewer-APPROVED, and fully LIVE-VERIFIED (2026-09-03) —
see its own section above. **Phase 6 slice 4 (a true no-search RAW
white-balance eyedropper via `CIRAWFilter.neutralLocation`) is SHIPPED,
reviewer-APPROVED, and fully LIVE-VERIFIED (2026-09-04) — see its own
section above.** **Phase 6 slice 5 (RAW-native Noise Reduction +
Sharpness) is SHIPPED, reviewer-APPROVED, and LIVE-VERIFIED (2026-09-04,
including a real live finding root-caused as content-adaptive
visibility, not a bug — see its own section above).** **Phase 6 slice 6
(RAW-native Contrast/Detail/Moiré Reduction) is SHIPPED,
reviewer-APPROVED on the FIRST pass, and LIVE-VERIFIED — 2026-09-04,
see its own section above.** **Phase 6 slice 7 (`rawDecoderVersionPin`,
deterministic RAW decode across OS updates) is SHIPPED,
reviewer-APPROVED (3 rounds — see its own section above for the two real
bugs caught: the pin not persisting for pre-existing sidecars, and a
follow-up bug where preserving it made "Revert to Original" read as
permanently enabled on RAW photos), and fully LIVE-VERIFIED (2026-09-04)
— full checklist confirmed by the user, see its own section above,
including a separately-investigated (and self-resolved, no code change)
sidecar-save flake. 465 tests passing.
**All ten measured-viable `CIRAWFilter` RAW-native controls plus this
determinism fix are now shipped, reviewed, and live-verified — Phase 6's
RAW-native work is functionally complete for this camera.** The two
remaining items on `CIRAWFilter`'s deferred list are `lensCorrectionEnabled`
(measured unsupported on this camera, needs a different camera body to
revisit) and a genuine inverse-geometry transform so the WB eyedropper's
fast path works beyond identity geometry — both smaller/more speculative
than slice 7 was, and neither is blocking. **IMPROVEMENTS.md P3 (cache
`EditPipeline.apply` output in `ImageRenderer`) is now SHIPPED and
reviewer-APPROVED (first pass) — see its own section above for the
measured 458.9ms-spike-to-~0.005ms result — but NOT yet live-verified for
visual correctness** (only the timing measurement itself was done live);
that's the immediate next step (resize/zoom/pan + Compare mode Side by
Side and Split + a real edit, per that section's checklist). **P2 is
queued right after**, gated on its own fresh measurement (active
slider-drag frame time, a different scenario than P3's) per
IMPROVEMENTS.md's own rule. Otherwise the user may pick from
IMPROVEMENTS.md's other open items instead (D4 Library keyboard support,
D5's remaining two parts, D6 accessibility pass, P5/P6 performance), or
one of the Tier-1 Lightroom-gap WANTED items, or Phase 7 slice 1 (masking
performance probe) — all logged in CLAUDE.md's roadmap.

**Both real issues surfaced live during batch export's own verification
are now FIXED** — the Editor-vs-Preview color/brightness discrepancy and
Library thumbnails not reflecting edits, each with its own section above.
No open correctness items remain from that batch.

A codebase-wide improvement review now lives in `IMPROVEMENTS.md` at the repo
root (performance + design backlog, written 2026-08-28). Seven of its items
are now closed and verified live: P1 was attempted and DISPROVED by
measurement, P4 was measured and SHIPPED, D7 (split ContentView) SHIPPED,
D1 is fully shipped — (a) ⌘←/⌘→ and (b) the bottom filmstrip — D2
(thumbnail-size slider) SHIPPED, D3 (edited-photo badge) SHIPPED, and D5
part 1 of 3 (remove-from-catalog) SHIPPED — each with its own section
above, all verified live 2026-09-01. Its remaining items are unmeasured
candidates, not commitments, and nothing in it outranks the roadmap
options below: D4 (Library keyboard support — needs Plan Mode + user
scope confirmation), D5's other two parts (rename/delete collections,
missing-file detection — each still its own session), D6 (accessibility
pass), and P2/P3/P5/P6 (performance — measure before implementing, per
IMPROVEMENTS.md's own working agreements).

**The user's own stated sequence ("2 then 3 and 1") is now fully done AND
live-verified**: D5, D2+D3, and finally "1" (Phase 5 slice 2, Presets) all
shipped and confirmed working live. With the roadmap's own next item
(Phase 6, RAW) explicitly out of scope until asked for, remaining options
are back to IMPROVEMENTS.md's open items — D4 (Library keyboard support),
D5's other two parts (rename/delete collections, missing-file detection),
D6 (accessibility pass), and P2/P3/P5/P6 (performance, measure first) —
whichever the user picks next.

**New working agreement, 2026-09-02**: screen-capture/UI-automation
(screenshots, cliclick, AppleScript UI-driving) now needs the user's
explicit per-task go-ahead — default mode of work is code-only. Came out
of an unrelated sidecar-save investigation where automation overhead (window
positioning, System Settings navigation, repeated screenshots) burned a lot
of turns for comparatively little diagnostic value; the fix that actually
worked was adding temporary debug logging to the code itself and asking the
user to reproduce and report back, not driving the UI. Saved to memory —
see `feedback_screen_automation_permission` — so this carries into future
sessions automatically.

**All three shipped items (D7, D1(a), and now D1(b)) got their live pass on
2026-08-28** — see their own
sections above for the full detail. Summary: D7's panel-state persistence
(section expansion, histogram RGB mode, Selective Color band, across a
Crop↔Adjust round-trip) confirmed working; ⌘←/⌘→'s grid-order navigation,
first-photo boundary graying, and — the case that actually mattered — edit
isolation across an A→B→A round-trip (A's edit survives, undo history
resets rather than reaching into B) all confirmed working. Not exercised
in that pass, still open if revisited: sort/rating-filter reordering
navigation, filtering the open photo out of view, Library-view disabling
both nav items, zoom/Compare/Crop-tab reset on navigate, "Pick White
Balance"/"Fix Red-Eye" Compare-clearing, Crop aspect-preset reshaping, and
Crop's own "Reset" button.

**Next: options** (ask the user which, don't guess): (1) Phase 5 slice 2 —
presets (save/apply named edit-state presets); (2) Library polish,
remaining slices — removing photos from the catalog, detecting files
deleted on disk since import, renaming/deleting collections (sort/filter/
search, the first slice, is DONE — see its own section above); (3) hardening the
reviewer's non-blocking note from photo selection — `selectedPhotoIDs`
isn't pruned on every `refresh()`, only on filter change (cosmetic
toolbar-count overstatement only, the actual exported set is always
correct); (4) hardening the reviewer's non-blocking note from Batch
export — `ExportOptionsView`'s own Export button isn't gated on
`isExporting`, a low-probability double-click race; (5) hardening the
reviewer's non-blocking notes from folder-mirrored collections — no index
on `collection.folderPath`, no symlink-loop guard in
`PhotoImporter.scanNode`, `findOrCreateFolderCollection` silently ignoring
a mismatched `parentID` on re-import from a different root; (6) DONE — see
"Library tap mutators update in place" above; the three tap mutators no
longer call `refresh()` at all, so overlapping snapshots can no longer
show stale data in the grid. A narrower write-ordering window remains,
recorded as a known limitation in that section; (7) `collection.name`
having no `UNIQUE` constraint, so rapid double-submits of "New
Collection…" could create duplicates; (8) revisit the still-deferred
sidebar content-shift-on-scroll cosmetic bug (see its own section above,
including the "Lesson recorded" note); (9) the reviewer's non-blocking
note from the Edit-menu work — consider suppressing/redesigning the
default ⌘N "New Window" behavior before any multi-window UI is added; (10)
the reviewer's non-blocking note from the sidecar-persistence work —
investigate the one unexplained "you don't have permission" flake further
if it recurs; (11) the reviewer's non-blocking note from Library slice 2 —
`activateKnownFolders` keys `activeFolders` by the bookmark's original
path, so a folder renamed/moved between sessions could get its scope
started twice on re-import; (12) the reviewer's non-blocking suggestion
from the color-space fix — a debug-only `assert` already covers the
`CAMetalLayer` cast, no further action needed unless it ever fires; (13)
the reviewer's non-blocking, narrow-edge-case note from the thumbnail fix
— `invalidateThumbnail(for:)` keys off `url.path` and could silently no-op
if a differently-normalized-but-equivalent path string (Unicode NFC/NFD,
symlink resolution) reached it, though every current call site round-trips
through the same `Photo.path`/`URL(fileURLWithPath:)` pattern so this
isn't reachable today.
Lens distortion correction remains out of scope (deferred to Phase 6 slice
2, since `CIRAWFilter.lensCorrectionEnabled` would finally supply the
camera-profile data the Transform/Distort backlog lacks it for — see
CLAUDE.md's roadmap item 6). RAW support itself is no longer out of
scope — slice 1 shipped 2026-09-02, see its own section above.

**Patterns worth carrying into Phase 3 and beyond:**
- This project hit "verify the sign/direction/behavior empirically, don't
  assume" as a load-bearing pattern SIX times across Phase 2 (y-flip,
  contrast pivot, WB signs ×2, curves clamping, HSL commutativity, and now
  the crop coordinate-direction check that was verified proactively and
  passed). Keep defaulting to diagnostic scripts/live testing over
  documentation-reading or intuition for anything with coordinate, sign, or
  GPU-buffering semantics.
- **Not every bug is caught by unit tests** — the crop tiling bug was a
  live-rendering-only artifact (multi-frame GPU buffer staleness) invisible
  to any offscreen test, including the project's own established
  offscreen-diagnostic technique. Manual live verification (the "drag
  continuously, not just single clicks" step) is what caught it. Keep doing
  real interactive testing, not just static single-state checks, for any
  future rendering-path change.
- When delegating empirical work to a spawned Plan-type agent, it will very
  likely need an explicit reminder that Plan Mode's read-only restriction
  applies to the top-level orchestrating agent, not to it — this happened
  twice (white balance, HSL) and cost a full extra round-trip both times.
  Front-load that reminder in the initial prompt, not just after it
  hesitates.
- Not every feature needs a dispatched Plan agent — crop was designed
  directly given its low, well-understood risk profile and this session's
  spend-limit sensitivity. Use judgment: color-math/domain questions need
  empirical Plan-agent investigation; pure-geometry or already-established
  patterns (like `AspectFit`) don't.
- **Don't assume symmetry.** Vibrance's positive-side "protects
  already-saturated tones" property does NOT mirror at negative amounts
  (measured: the saturated test color loses MORE absolute saturation than
  the muted one when desaturating). A test written from that false
  assumption failed against the real `xcodebuild test` run, not just review
  — a useful reminder that even with per-feature empirical Plan-agent
  diagnostics up front, a NEW slider direction/sign/extremum still needs its
  own explicit measurement, not an inference from the opposite direction's
  behavior.

(See "Open reviewer issues" near the top of this file for current status —
that section is kept up to date per-feature; this trailing one is historical
and intentionally not duplicated further.)

## IMPROVEMENTS.md P2 — interactive-drag preview proxy (SHIPPED + LIVE-VERIFIED, 2026-09-07)
Full plan at `/Users/praween/.claude/plans/serialized-swimming-quilt.md`
(Plan Mode session went through two design passes — session-default model,
then an explicit Opus 5 critique of that draft per CLAUDE.md's `opusplan`
rule for a change to the hottest render path — after which the design was
substantially corrected: a units bug where "headroom" was reasoned in
points against `MTKView.drawableSize`, which is actually device pixels,
would have made the proxy silently never engage on the user's real
photos). User confirmed 1.25 headroom (pixels-per-drawable-pixel, not
per-point) and sustained-drag-only engagement.

Also: user asked (mid-session) that the `reviewer` agent always run on
Opus 5 going forward, not the session's default model — saved to memory
(`feedback_reviewer_model_opus`).

**4 commits planned, 2 done so far, each reviewer-APPROVED (Opus 5) before
commit:**
1. ✅ `ProxyScale.swift` + `ProxyInteraction.swift` + tests (pure geometry
   + a count-based interaction detector, not timing-based — draw(in:) is
   synchronous, so timestamps between edits are inflated by slow frames,
   exactly the case this feature exists to fix). One reviewer round: a
   NaN `zoomScale` could slip through `max(zoomScale, 1)`; fixed with an
   explicit `.isFinite` guard.
2. ✅ `ProxyBuilder.swift` + tests (headless `CVPixelBuffer` materializer,
   mirrors `RawDecoder.materialize`'s shape — Lanczos downscale,
   `extendedLinearSRGB`/RGBAh, routed through `RawDecoder.RenderGate`).
   Two reviewer rounds, several real bugs caught: an unbounded `scale`
   could overflow `Int` and trap (fixed by constraining to the function's
   actual contract, `scale <= 1`); a border-darkening regression test
   sampled the wrong pixel and was empirically vacuous (fixed, moved to
   the true corner + asserted alpha); a missing `context.clearCaches()`
   measured ~284MB retained across repeated builds (fixed); and a
   "realized, not lazy" property had NO test at all — closed with a
   genuinely clever probe (reviewer's own suggestion): build the proxy,
   then mutate the SOURCE buffer's bytes, then sample the proxy — a lazy
   graph would observe the mutation, a realized one can't. 503 tests
   passing.
3. ✅ Wired `ProxyScale`/`ProxyInteraction`/`ProxyBuilder` into
   `ImageRenderer.draw(in:)`: count-based interaction detection, a second
   `cachedPipelineSource` cache-invalidation key layered on top of the
   existing P3 `cachedSourceImage` check (not a replacement — both must
   fire together, since `cachedSourceImage`'s check is the unconditional
   safety net and `cachedPipelineSource`'s catches the proxy transition
   specifically), and an async, generation-token-guarded proxy build that
   never blocks a frame. Two reviewer rounds (Opus 5) on this one, since
   it's the file that actually changes on-screen rendering: round 1 caught
   a real concurrency bug — the proxy-build guard allowed starting a NEW
   concurrent build whenever the required scale grew, which a real drag
   does on every frame (e.g. dragging Straighten back toward 0° shrinks
   the extent every frame) — spawning dozens of overlapping builds, each
   holding an ~80MB `CVPixelBuffer`, all serialized behind the app-wide RAW
   `RenderGate` with no guaranteed completion order (could stall RAW
   thumbnail/re-decode work for seconds — the exact freeze class
   `RenderGate` exists to prevent). Fixed by allowing at most one build in
   flight at a time; the now-dead `proxyBuildTargetScale` field was
   deleted rather than left unused. Round 1 also flagged several doc
   comments that didn't match what the code does (the extent probe runs
   every interacting frame, not only on rebuild; the proxy is held
   transitively by more than one cache slot; a failed build IS retried,
   cheaply, not a one-shot) — all fixed. Round 2: APPROVE, one trivial
   wording nit (a reviewer-derived-not-measured number mislabeled
   "measured") fixed before commit. Both reviewer passes independently
   re-verified all of: the two-check cache invalidation can never leave
   `cachedEdited`/`cachedOriginal` stale against whichever source (proxy
   or full-res) produced them; Compare's `edited`/`original` always come
   from the same resolved source within one `draw(in:)` call, so they
   can't diverge in sharpness; the settle-redraw regression guard
   (`interaction.settle()`'s return value) correctly prevents an extra
   full-res redraw after a burst that never used the proxy; the
   `isInteracting == false` path is byte-identical to the pre-P2 code.
   503 tests unchanged (no new tests possible here — `draw(in:)` has zero
   test precedent in this codebase, Metal-coupled glue whose bugs have
   historically been caught live, not by tests — verified instead via
   build + full suite + two independent Opus 5 review rounds).
4. ✅ Live measurement + verification pass (2026-09-07). Temporary
   `CFAbsoluteTimeGetCurrent()` prints added to `ImageRenderer.draw(in:)`
   and `requestProxyBuild` (frame time + whether the proxy was used +
   `drawableSize` + zoom; proxy-build duration + scale + result). App
   launched directly (not via `open`) so stdout streamed into the session
   for live analysis — Swift's `print()` is block-buffered when stdout is
   redirected to a file rather than a terminal, so output only fully
   flushed once the app was quit; re-launched and re-tested once this was
   understood.
   - **First repro attempt was individual discrete taps** (setting
     Definition/Sharpen/NR each to 100% one at a time) — correctly never
     sustained the proxy (each isolated adjustment stayed under the
     2-changes-in-a-burst threshold), exactly matching the "only sustained
     drags engage" design. Confirms the detector's discrete-change
     no-engage behavior live, not just in `ProxyInteractionTests`.
   - **Second repro (the real target): continuous click-and-hold Sharpen
     drag**, same photo (a 24MP `.NEF`), Sharpen+NR+Definition all at
     100%. Proxied frames: **0.6-2ms** (a couple of blips at 23.3ms and
     180.8ms — see below). The only slow frames in the ENTIRE session
     (174.9ms, 203.5ms, 45.2ms, 23.1ms, 20.1ms) all had `proxy=false` —
     full-res renders during idle/zoom moments or the settle frame right
     after a burst — i.e. exactly the pre-existing cost those frames
     already had; the proxy is what's different, and it works.
   - **One caveat recorded, not chased further this slice**: the 180.8ms
     blip landed on the exact frame where a SECOND proxy build was
     requested (a rebuild, not the first-ever build) — likely GPU-level
     contention between the interactive frame's own `ciContext.render`
     and the concurrently-running background build's render (a separate
     `CIContext` in `ProxyBuilder`, but the same underlying `MTLDevice`),
     even though the build itself runs fully async and never blocks
     `draw(in:)` at the CPU/thread level (confirmed by two reviewer
     rounds). Much smaller than the original 184.7/279.0ms outliers and
     looks like a rare, one-time-per-rebuild event; worth another look if
     it recurs more severely on a lower-end GPU or a larger source photo,
     not blocking for this slice.
   - **User confirmed live**: the drag felt smooth; undo/redo, typing a
     value directly, and applying a preset each rendered sharp
     immediately, no soft flash — matching the "only sustained drags
     engage the proxy" design (single discrete changes always stay at
     full-res).
   - Instrumentation fully reverted before commit — confirmed via
     `git diff HEAD` showing zero changes to `ImageRenderer.swift` after
     `git checkout --`, and the full 503-test suite re-run clean
     afterward.
   - `IMPROVEMENTS.md` P2 struck through with these final numbers.

**IMPROVEMENTS.md P2 is now fully shipped, reviewer-approved (4 commits,
each independently APPROVEd by Opus 5), and live-verified.** 503 tests
passing throughout (no new tests in the final wiring commit — `draw(in:)`
has zero test precedent in this codebase; correctness was established via
two Plan Mode design passes before any code, four rounds of Opus 5 review
across the four commits, and this live pass).

**A separate, unrelated bug surfaced during this pass (2026-09-07),
NOT caused by P2 — root-caused via the temporary print instrumentation,
not guessed.** User reported that in Compare Split mode, zooming in while
the cursor was over the "original" (left/color) side showed some of the
original photo mixed with the modified (B&W) one — a real compositing/
crop artifact, with a screenshot at 131% zoom. Investigated by checking
the live `[P2] frame=... proxy=...` log captured during the exact session
the bug happened in: `proxy=` was `false` for every single frame across
the entire zoom sequence (zoom oscillated 1.00→2.82→1.00 several times,
including 131%) — the only `proxy=true` frames in the whole session
occurred earlier, all at `zoom=1.00`, before any zooming started, and
settled back to full-res well before the user began zooming. Since the
pipeline was rendering from the full-resolution `image` the entire time
this bug was observed, P2's proxy substitution is conclusively NOT the
cause — this is a pre-existing bug in Compare Split + zoom compositing
(`ImageRenderer.draw(in:)`'s `.split` case), unrelated to any code this
feature touches. User confirmed (asked via AskUserQuestion): log it and
stay focused on closing out P2 rather than investigate now, per
CLAUDE.md's one-feature-per-session rule. **Needs its own Plan Mode
session**: reproduce with Split mode + scroll-to-zoom centered over the
original side, and check whether the existing crop-to-own-half fix from
Post-Phase-5 follow-up #6 (documented for Side by Side's zoom-bleed bug)
was ever verified for Split specifically — `fittedEdited` in the
`.split` case is composited uncropped (unlike Side by Side's `.cropped(to:
rightRect)`), which may be the same defect class re-appearing in the one
mode that wasn't fixed for it.

**FIXED and live-verified (2026-09-07), same session.** Confirmed exactly
the hypothesis above: `fittedEdited` in `.split` was composited with no
crop, while `fittedOriginal` was already bounded via `.cropped(to:
originalRegion)`. Fix: added `.cropped(to: fitRect)` to `fittedEdited`,
mirroring Side by Side's existing pattern exactly — a no-op at zoomScale 1,
bounding the edited image to `fitRect` past 1x so its zoom-overhang can
no longer bleed into the letterbox margins. Reviewer (Opus 5) went well
beyond code-reading: reproduced the pre-fix bug pixel-for-pixel (rendered
the actual pre/post composites at z=2 on a 6016×4016 image and showed the
exact letterbox columns adjacent to the original half switching from pure
edited-red to pure black), then confirmed zero bleeding pixels post-fix
across 32 zoom/orientation/pan combinations with no new gap introduced
inside `fitRect`, and confirmed the "no-op at zoomScale 1" claim by
rendering 24 cases byte-identical with/without the crop (catching that
the underlying float arithmetic isn't bit-exact, only pixel-identical —
doc comment corrected to say so precisely, matching this file's own
"measured, not assumed" discipline). User then confirmed live: bug is
gone. One commit, 503 tests unchanged (no test precedent for `draw(in:)`
in this codebase — verified via the reviewer's empirical reproduction
plus live confirmation instead, same pattern as every other
`ImageRenderer` fix in this project's history).

## IMPROVEMENTS.md P5 — histogram downsample position (SHIPPED, 2026-09-07)

**Scope correction found during investigation**: P5's write-up covered two
call sites (`ImageDocumentModel.recomputeHistogram()` and `fixColorCast()`),
but only the first is actually exposed to the convolution caveat.
`fixColorCast()`'s sampling state starts from a fresh `EditState()` —
`sharpness`/`definition`/`noiseReduction` all default to `0`, and
`EditPipeline` guards each stage on `!= 0` — so that path can never have a
convolution stage active regardless of resolution; it's a cheap
geometry-only pass. Confirmed by reading `EditState`'s actual defaults and
`EditPipeline`'s actual guards, not assumed.

**Measured (2026-09-07) — justified.** Temporary
`CFAbsoluteTimeGetCurrent()` instrumentation around `recomputeHistogram()`'s
two lines, same tool as P2/P3: `EditPipeline.apply` (just builds a lazy
graph) was ~free (0.0-5.7ms); `HistogramComputer.histogram(of:)` (the
actual render, forcing the convolutions to run at source resolution before
`HistogramComputer`'s own internal 256px downsample ever got a chance to
shrink the graph) ranged **24.6-399.9ms** on a 24MP RAW photo with
Sharpen+Noise Reduction+Definition all active — several calls exceeded
200-400ms, a real felt lag for supposedly-live histogram feedback (the
histogram is debounced ~150ms after the last edit, so this is at most once
per settle, not per frame — a lower-frequency exposure than P2's, which is
why this needed its own measurement rather than assuming P2's fix applied
here too).

**Shipped**: a pre-pipeline downscale in `recomputeHistogram()`, via a new
pure, unit-tested `HistogramComputer.inputDownscale(forDisplayedSize:)`
(`Sources/Rendering/Histogram.swift`) — headroom 2x
`HistogramComputer.sampleDimension` (512), `min(1, ...)` never-upscale,
degenerate-input guards matching `RawDecoder`/`ProxyBuilder`'s own
precedent. A plain affine scale, not Lanczos/`ProxyBuilder` — deliberately:
this matches `HistogramComputer`'s own existing plain-affine resample
exactly (introduces no NEW class of resampling error, just moves an
equivalent one earlier), and `ProxyBuilder`'s async/`RenderGate`/
`CVPixelBuffer` machinery was built for a different call site
(`ImageRenderer`'s live on-screen render) and would add real coupling/cost
for no benefit here. **Live-measured after**: a steady **13-68ms** (one
220ms outlier on the apparent first call of the session, not a recurring
cost).

**Two reviewer rounds (Opus 5)** — round 1 caught a real, blocking bug:
the first draft sized the downscale headroom against `currentImage`'s own
RAW/pre-pipeline extent, but `HistogramComputer` receives the
POST-pipeline (post-crop/straighten/perspective) extent — on a photo
cropped past ~50% linear, the headroom would have degenerated to exactly
the no-op size the 2x multiplier exists to prevent, or worse, upsampled a
tightly-cropped photo's ~51px input back up to 256 buckets. Fixed by
probing the DISPLAYED extent instead (`EditPipeline.apply(referenceState,
to: currentImage).extent.size` — cheap, no pixels render, the same pattern
`ImageRenderer.choosePipelineSource` already uses). Round 1 also caught:
an asserted-but-unmeasured claim about which direction Noise Reduction's
resolution-independence would shift the histogram (corrected to state the
direction isn't measured, only that it diverges); a wrong "aliasing
doesn't matter for a bucket count" justification (corrected to the real
reason — this matches `HistogramComputer`'s own existing resample, not a
new tolerance for aliasing); a misattributed `RawDecoder.materialize`
precedent for the never-upscale clamp (corrected to the actual precedent,
`RawDecoder.decodeDraft`'s `scaleFactor`); and a resolution-independence
test that could only ever pass regardless of whether the fix was correct
(a solid color trivially resamples to itself at any resolution) — replaced
with a 45:19 (not 50/50) two-region proportion test that genuinely
exercises the property. Round 2: APPROVE, two small non-blocking
doc-accuracy/guard-consistency notes applied before commit. 510 tests (5
new: the replaced proportion test plus 4 direct tests of the new pure
`inputDownscale` helper), 0 regressions.

**IMPROVEMENTS.md P5 is now fully shipped, reviewed, and live-verified.**
P1/P2/P3/P4/P5 are all closed (P1 disproved, the other four measured and
fixed). Remaining IMPROVEMENTS.md items: P6 (needs its own measurement
first), D4/D5 (2 remaining parts)/D6 (each needs its own Plan Mode
scoping).

## Adjust panel "can't scroll" report — investigated, NOT a bug (2026-09-08)
User reported the Adjust sidebar couldn't be scrolled up/down at all.
Explored the actual code before touching anything (this sidebar has a
documented, hard-won history with scroll-adjacent AppKit interop — see the
"Sidebar content-shift-on-scroll bug" section above and its "Lesson
recorded" note about a previously-reverted fix that broke slider
interaction live despite two clean reviewer passes): `ContentView.swift`'s
`editControls` genuinely wraps all four sidebar tabs, including Adjust, in
a real `ScrollView`; `.scrollIndicators(.hidden)` (already-shipped, commit
`3280b8e`) fully and deliberately explains the invisible-scrollbar half of
the report; neither `AdjustTabView`/`AdjustSectionContainer`/`CropTabView`
has any `.frame(height:)`/`.fixedSize()`/`.layoutPriority` that could
suppress the ScrollView's content sizing. One real candidate was found
(`.disabled(document.currentImage == nil)` disables a `ScrollView`'s own
scroll gesture on macOS, not just child controls) but ruled out — the user
confirmed a photo was loaded and sliders were responsive. Every Adjust
section defaults collapsed, so the live hypothesis was "nothing to
scroll yet, not broken scrolling" — **confirmed live**: user expanded all
sections (so content genuinely exceeds the visible panel height) and
scrolling worked normally. No code change. Worth remembering if this
resurfaces: ask whether sections are expanded before assuming a scroll
regression, and do not reach for `NSScrollView`/`NSViewRepresentable`
probing in this exact file without re-reading the content-shift bug's
"Lesson recorded" note first.

## D5 part 2 of 3 — rename/delete collections (SHIPPED + LIVE-VERIFIED, 2026-09-08)
Sidebar `.contextMenu` (the codebase's first use of that modifier) on flat
"Collections" rows only — "Rename…" + a destructive "Delete", mirroring
"Remove from Library?"'s own confirmation-alert shape. **Scope, confirmed
with the user up front via `AskUserQuestion`**: excludes "Folders" rows
(folder-tree collections) — deleting one would recursively delete its
whole subtree (`parentId` is itself `ON DELETE CASCADE`, self-referencing),
and rename/delete both interact oddly with re-import (folder-tree import
matches purely by disk path, never name) — matches this project's own
prior explicit exclusion when folder collections first shipped, kept out
again rather than solved this session.

`CatalogDatabase.renameCollection(id:to:)` is the project's first `UPDATE`
on any table other than `photo` (mirrors `setRating`/`setFlagged`'s exact
shape); `deleteCollection(id:)` is the first DELETE on `collection`
(mirrors `deletePhoto(id:)`, relying on the already-shipped `ON DELETE
CASCADE` FK for membership cleanup — verified by a real cascade test, the
collection-delete mirror of the existing photo-delete cascade test, not
just trusted from the migration's own comment). `CatalogModel.deleteCollection`
also falls back `selectedFilter` to `.allPhotos` when the collection being
deleted is the one currently being viewed, extending `toggleMembership`'s
own `affectsCurrentFilter` precedent.

**A real race caught and fixed before this shipped, then verified
empirically twice** (once by me while writing it, once independently by
the reviewer): `selectedFilter`'s own `didSet` kicks off `Task { await
refresh() }` whenever it changes. The first draft set `selectedFilter =
.allPhotos` SYNCHRONOUSLY inside `deleteCollection`, before the async
delete write landed — meaning that didSet-triggered refresh could re-fetch
the collection from the database (still there) and silently restore the
row `collections.removeAll` had just removed locally, permanently, since
`deleteCollection`'s own success path never calls `refresh()` on its own.
Fixed by deferring the filter reset into the same `Task.detached`, only
after the write is confirmed. Reviewer (Opus 5) additionally caught that
the regression test for this only asserted the EVENTUAL value
(`selectedFilter == .allPhotos`), which a reverted synchronous version
would also eventually satisfy, just sooner — fixed by asserting the filter
has NOT yet flipped immediately after `deleteCollection` returns (no
`await` in between), then the reviewer independently rebuilt a scratch
copy with the synchronous version reverted and confirmed the strengthened
test genuinely fails against it. `isFolder` guards were added to both new
`CatalogModel` methods (not just the UI-level `.contextMenu` exclusion) as
defense-in-depth, per the reviewer's own suggestion.

Reviewer: 2 rounds — round 1 FIX FIRST (the race-test weakness above, a
new compiler warning from an unchecked `updateAll` result, a doc comment
overclaiming the `didSet` as "unconditional", a missing doc comment, an
undocumented-but-harmless `membershipsByPhotoID` staleness, and the
`isFolder` defense-in-depth suggestion) → all fixed → round 2 APPROVE.
517 tests (7 new), 0 regressions, no new compiler warnings (three
pre-existing warnings elsewhere in the codebase are unrelated to this
diff). **Live-verified by the user**: rename re-sorts the sidebar and
preserves membership; deleting the actively-viewed collection falls back
to "All Photos" with the photos themselves untouched; deleting a
non-active collection changes nothing else; Folders rows show no context
menu at all, confirming the scope boundary holds.

**Missing-file detection (D5's remaining 1 of 3 parts) is still open**, its
own session.

### Batch-add selected Library photos to a collection (D5 follow-up, shipped)

The feature request that came out of the rename/delete-collections session
above: a new toolbar `Menu("Add to Collection")`, visible only when the
Library grid's own multi-select checkbox has 1+ photos checked, adding all
of them to a chosen collection in one action — previously only possible
one photo at a time via each cell's own membership `Menu`.

Always ADDS, never toggles: a batch selection can be a mix of
members/non-members of any given collection, so "toggle" has no
unambiguous meaning across N photos the way it does for one. Scope matches
the existing per-cell menu exactly — every collection is offered,
including folder-tree ones (unlike rename/delete, adding a manual
membership to a folder collection isn't destructive). Deliberately
excluded: an inline "New Collection…" shortcut (the existing sidebar flow
already covers creation; a second alert-owning `@State` here would need
its own routing decision given this codebase's prior alert-count/
type-checker history). `CatalogDatabase.addPhotos(_:toCollection:)` is a
new batched write — one `dbQueue.write` looping an `insert(db, onConflict:
.ignore)` per photo ID, mirroring `importFolderTree`'s own "one
transaction, many rows" shape rather than N separate `setMembership`
calls. `CatalogModel.addSelectedPhotos(to:)` is local-first (every
selected ID gets the collection inserted into `membershipsByPhotoID`
synchronously), one batched `Task.detached` write.

**A real bug caught by the reviewer, not by testing**: the first draft
acted on raw `selectedPhotoIDs` directly. `toggleMembership` removes a
photo from `photos` when it's toggled OUT of the currently-viewed
collection (the ghost-cell case, already shipped) but does NOT prune that
photo's ID from `selectedPhotoIDs` — unlike `removePhoto`, which does. So
a photo could be selected, silently vanish from the grid via that path,
and remain selected — and a later batch-add would silently re-add it to
whatever collection it was just removed from, invisibly. Fixed by
intersecting the raw selection against `photos` before acting
(`let visibleSelectedIDs = Set(photos.compactMap(\.id))
.intersection(selectedPhotoIDs)`), reusing the exact same
"intersect-with-currently-displayed" pattern `ContentView.photosToExport`
already established for Export. The toolbar `Menu`'s own `.disabled` was
also widened to gate on this same intersection (a new
`selectedPhotosVisibleInGrid` computed property in `ContentView`), not
just `collections.isEmpty` — otherwise the menu could sit enabled for a
selection that would silently do nothing.

**A second, related bug the reviewer caught**: the original code captured
`affectsCurrentFilter` (whether the target collection is the one currently
being viewed) BEFORE the async batched write started. For a large batch,
that write can take long enough for the user to switch the sidebar filter
mid-flight, making the captured flag stale by completion. Fixed with a new
private `refreshIfViewingCollection(_:)`, re-checking `selectedFilter` on
the `MainActor` at completion instead of trusting a value captured at call
time — structurally identical to `deleteCollection`'s own
`clearSelectedFilterIfCollectionDeleted`, which already solves the same
class of race for the delete path.

Reviewer (Opus 5): 2 rounds, FIX FIRST → APPROVE. Round 1 caught both bugs
above (plus the now-corrected doc comment, which had wrongly claimed the
refresh-on-current-filter branch was fully unreachable — it becomes a
no-op only once the intersection fix is in place, and stops being a no-op
if the filter changes mid-write, which is exactly what fix #2 handles).
Also added, per the reviewer's recommendation:
`testAddPhotosRollsBackEntirelyOnAnInvalidPhotoID` in
`CatalogDatabaseTests`, pinning that `onConflict: .ignore` only suppresses
a primary-key conflict, not a foreign-key violation — so a stale/deleted
photo ID in a batch throws and rolls back the ENTIRE transaction, not just
the offending row (verified empirically by the reviewer against GRDB's own
source before the fix, then pinned as a real test). 522 tests (3 new: the
DB rollback test, and `CatalogModelTests`'
`testAddSelectedPhotosUpdatesMembershipMapSynchronously` +
`testAddSelectedPhotosExcludesAPhotoNoLongerVisibleInTheGrid`, the latter
replacing an earlier test that turned out to describe an unreachable
scenario once the intersection fix landed). **Live-verified by the user
(2026-09-08)**: after relaunching to pick up the build (a stale prior
instance from before this session's fixes was still running, which is
likely why the menu wasn't visible on the first try), the toolbar menu
appears once photos are checked in the Library grid and adding to a
collection works.

### Missing-file detection (D5's remaining 3rd part, shipped 2026-09-08)

Closes out D5 entirely (remove-from-catalog and rename/delete-collections
already shipped). Before this, a photo whose file was deleted from disk
after import spun forever in the Library grid — `image == nil` always
fell back to `ProgressView`, with no way to distinguish "still decoding"
from "will never decode."

**Scoped view-layer-only, computed live per cell-appearance** — no DB
migration, no persisted `isMissing` column. Deliberate: a persisted flag
would need answers this codebase hasn't settled (when is it re-verified,
who clears it), and would make one false positive permanent across
relaunches instead of scoped to a single cell's next appearance. Catalog
rows and on-disk files are already expected to be able to diverge (the
remove-from-catalog session's own write-up says so explicitly), so
nothing here auto-removes a missing photo's row — the existing "Remove
from Library" menu action already covers that.

**The one real hazard, designed around up front, not discovered later**:
this app is fully sandboxed (only `files.user-selected.read-write`), and
each imported folder's access depends on a security-scoped bookmark that
`CatalogModel.activateKnownFolders()` re-activates at launch —
`startAccessingSecurityScopedResource()` can fail SILENTLY, and a
stale/unresolvable bookmark is dropped just as silently, with no
user-visible signal either way. From the process's own point of view,
"file exists but sandbox access isn't currently active" and "file
genuinely deleted" are indistinguishable by a bare `fileExists` check —
macOS sandboxing deliberately doesn't leak the difference. A naive
implementation would therefore flag an entire folder of perfectly-present
photos as "Missing" the instant its bookmark had any activation hiccup —
actively worse than the spinner it replaces.

**Mitigation**: new `PhotoImporter.confirmedActiveFolderRoot(forPhotoAt:activeFolders:)`
— pure, unit-tested, taking `CatalogModel.activeFolders` (the set of root
folder paths currently holding confirmed security-scoped access)
explicitly, rather than being a `CatalogModel` instance method, so it's
directly testable with plain `Set<String>` literals (`CatalogModel.init(database:)`'s
testing seam deliberately skips the real `activateKnownFolders()` — it
touches `UserDefaults`/real security scopes). Returns the matched root
(not just a `Bool`) via a longest-matching-prefix search — a photo whose
path isn't under any confirmed-active root can't be reliably checked at
all. New `CatalogModel.isPhotoConfirmedMissing(_:)` uses it: only once a
thumbnail decode has already failed does it check (off the main actor,
via `Task.detached`, since this is exactly the slow-filesystem path) that
the photo's own file is absent AND the matched root itself is still
reachable. `LibraryThumbnailCell` (`LibraryGridView.swift`) and
`FilmstripCell` (`EditorFilmstripView.swift` — fixed too, since it shares
the identical bug and would otherwise visibly disagree with a fixed grid
for the same file) both gained an `isMissing` `@State`, computed in their
existing `.task(id:)`, swapping the indefinite spinner for a small
"Missing" placeholder (orange `exclamationmark.triangle.fill` + text in
the grid, icon-only in the filmstrip) once confirmed.

Reviewer (Opus 5): 2 rounds, FIX FIRST → APPROVE.
- **Round 1** caught the real gap the design's own risk analysis had
  missed: `activeFolders` is insert-only — nothing ever removes an entry
  once activation succeeds, even if the volume is later ejected or the
  imported root itself is deleted/renamed mid-session. So "this root is
  in `activeFolders`" only proves access was granted at SOME point this
  session, not that it still holds now — the exact false-positive class
  the design set out to prevent, reached by a different route (a root
  that goes stale AFTER activation, not one that failed TO activate).
  Fixed by having the pure function return the matched root itself (not
  a `Bool`), so the caller can additionally verify that root is still
  reachable before trusting a negative result on the photo. Also caught:
  the filesystem checks running synchronously on the `@MainActor` (a
  `stat` on a spun-down external drive or dead network mount can block
  for seconds — exactly the failure path this feature runs on) — fixed
  with `Task.detached`, capturing `root`/`photo.path` as local values so
  the closure never touches `self`; `isMissing` not being reset when a
  `.task(id:)`-recycled cell switches to a different photo, so a photo
  following a "Missing" one could transiently show "Missing" itself —
  fixed with an explicit reset at task start; and a missing accessibility
  label on the filmstrip's icon-only placeholder — fixed.
- **Round 2 APPROVE**, with small non-blocking polish applied anyway
  before commit: fail-closed/short-circuiting operand order (check the
  photo's own file first, the root second — narrows the unmount-between-
  the-two-stats window and skips the extra root stat in the common
  present-file case); deterministic longest-matching-prefix instead of
  `Set.first` when multiple active roots nest (a flat import of a
  subfolder followed later by a tree import of its parent puts both in
  `activeFolders` — `Set` has no defined iteration order, so which root
  "won" could silently vary by launch); a stale doc-comment reference to
  the old (pre-round-1) function name; and a discarded `Bool` result in
  the new end-to-end test's fixture setup.
- `CatalogModel.activeFolders` was widened from `private` to internal
  (default) access specifically so `CatalogModelTests` can seed it
  directly with a real temp-file root — the only way to exercise
  `isPhotoConfirmedMissing(_:)` end-to-end given the model's testing seam
  skips real security scopes. Reviewer confirmed this widening is
  contained (three mutation sites, all inside `CatalogModel`, all
  MainActor-isolated).

530 tests (11 new): 6 in `PhotoImporterTests` for the pure gate
(direct child, nested subfolder, no active folders, sibling-folder
false-match guard, trailing-slash guard, longest-match-among-nested-roots),
1 end-to-end in `CatalogModelTests` (`testIsPhotoConfirmedMissingRequiresBothAnActiveRootAndAnAbsentFile`,
using a real temp directory — seeds it as an active root, confirms a
present file isn't flagged, an absent one is, then DELETES the temp
directory itself and re-confirms the same absent file is no longer
flagged — the direct regression pin for the round-1 fix). No new tests
for the SwiftUI cell bodies themselves, matching this codebase's
established convention that plain View-body logic isn't unit-tested,
only extracted pure logic is.

**Live-caught bug, fixed same session (2026-09-08), before any live
success**: the user's first live test reported no "Missing" placeholder
appearing at all. Root cause: `ThumbnailCache.thumbnail(for:)` serves an
already-decoded `CGImage` from its `NSCache` forever, with no freshness
check — it has no way to know the underlying file was deleted after
being cached. The shipped check was gated on `decoded == nil`, so for any
photo already viewed in this session (the overwhelmingly common case —
the user had almost certainly opened the Library grid before deleting a
file to test with), the decode kept "succeeding" from cache and the
missing-check never ran at all. The feature was structurally incapable
of detecting a deletion for any previously-viewed photo.

Fixed by calling `CatalogModel.isPhotoConfirmedMissing(_:)`
UNCONDITIONALLY on every cell appearance (via `async let`, concurrent
with the thumbnail fetch), and by making `isMissing` take priority over
a cached `image` in the render logic (previously: missing-placeholder
only shown when `image == nil`; now: missing-placeholder shown whenever
`isMissing`, even over an already-cached thumbnail). Reviewer (Opus 5):
2 more rounds on top of the original 2, FIX FIRST → FIX FIRST → APPROVE.
Round 1 (of this fix) caught that the always-run change silently dropped
a previously-reviewer-mandated `isMissing = false` reset at task start,
and that neither async call checks `Task.isCancelled`, so a superseded
`.task` (a recycled cell) could write a stale result over a different
photo's own in-flight check — fixed by capturing both results into
locals and adding `guard !Task.isCancelled else { return }` before either
gets written to `@State`. Also caught two now-inaccurate doc comments
(one claimed the filesystem checks "run on exactly that slow-filesystem
path (the one case a decode has already failed)," no longer true since
this runs unconditionally) — fixed.

**Explicitly confirmed scope boundary, not a bug**: this feature detects
a deletion on a cell's NEXT appearance (recycled onto a different photo
via scroll, a sort/filter change, or a Library↔Editor round trip, which
`ContentView` already tears down and rebuilds) — it does NOT live-monitor
the filesystem, so a cell that stays continuously on-screen while its
file is deleted out from under it won't update until it next appears.
Adding live monitoring (FSEvents/`NSFilePresenter`) was explicitly out of
scope from the original plan ("no bulk 'scan for missing photos' action
— this is purely per-cell, computed lazily as each cell appears") and
reviewer-confirmed as a defensible boundary for this kind of feature, not
a rationalization — the user's actual reported bug was fully explained by
the cache-masking defect above, not by this boundary.

**Live-verified by the user (2026-09-08)**: after navigating away from the
Library and back, a deleted file's cell correctly shows "Missing" while
sibling photos in the same folder render normally.

### Relocate missing photos (single + batch), shipped 2026-09-08

Direct follow-up, requested by the user immediately after confirming
missing-file detection worked live: "if I moved photo to new location
... I should be able to fix path to photo in both of a single photo or
case of I moved multiple photos." A new per-cell "Locate…" menu item
(`LibraryGridView.swift`, shown only when that cell's own `isMissing` is
true) and a toolbar "Locate Selected…" batch action
(`ContentView.swift`, same `!catalog.selectedPhotoIDs.isEmpty` gate as
"Add to Collection"), both pointing the catalog at a moved photo's new
location.

**Design**: `Photo.path` is `UNIQUE` in the schema but not the primary
key, and nothing in this codebase had ever updated an existing row's
`path` before — every prior write was INSERT, DELETE, or a non-unique
column UPDATE. New `CatalogDatabase.relocatePhotos(_ moves:
[(photoID: Int64, newPath: String)]) async throws -> Set<Int64>` handles
both the single-photo and batch cases with one shared primitive: one
`dbQueue.write` transaction, fetch-mutate-`update(db)` per pair (not a
fixed `updateAll` assignment list — see the fileSize fix below), skipping
(not aborting the whole batch on) any pair whose destination is already
claimed by a DIFFERENT catalogued row — deliberately different from
`addPhotos`' all-or-nothing FK-violation precedent, since a naming
collision here is a plausible, common outcome of a batch move (the
destination folder may already have been separately imported). New
`PhotoImporter.matchByFilename(_ photos: [Photo], in folder: URL)` (a
new pure-ish static function, unit-tested without a live `CatalogModel`,
following `confirmedActiveFolderRoot`'s own precedent) matches photos to
same-named files in one picked folder via a lowercased-filename
dictionary built from the existing shallow `imageFiles(in:)` scan —
by NAME only, not content; a same-named-but-different file would be
wrongly adopted, accepted and flagged, not solved (content-hash matching
is a much bigger feature).

**Reviewer (Opus 5) caught the most significant sandbox bug of this
whole session, in the first draft, before any live testing**: the
original single-photo flow let the user pick the exact file directly
(a FILE-mode `NSOpenPanel`), then tried to derive that file's PARENT
folder and grant security-scoped access to it. This is very likely a
silent no-op under this app's sandbox entitlement
(`files.user-selected.read-write`) — Powerbox grants a scope for exactly
the item the user picked in the panel; a file selection does not extend
to its parent directory. Every other folder-access grant in this app
(`importFolder`, `importFolderTree`, `ImageDocumentModel.requestFolderAccess`)
already picks a folder directly via a DIRECTORY-mode panel for exactly
this reason — `requestFolderAccess`'s own doc comment exists specifically
because deriving a parent from an already-picked file isn't sufficient.
Fixed by redesigning single-photo relocate to use the SAME folder-picker
+ `matchByFilename` approach as the batch flow (single photo = batch of
one) — accepting the same tradeoff the batch flow already had: a
RENAMED (not just moved) file won't be found this way, since matching is
by filename.

Two more real bugs caught in the same first round: (1) the destination-
collision probe didn't exclude the photo's OWN current row, so relocating
a photo back to its own already-current path (a stale `isMissing`
snapshot, or the file having been restored) reported a false "a
different photo is already catalogued at that location" — fixed by
excluding the target photo's own ID from the probe, and by refactoring
from a fixed `updateAll(...)` assignment list to fetch-mutate-`update(db)`
(this also fixed a related issue: a failed `attributesOfItem` read on
the new file would otherwise NULL out a previously-known `fileSize`
instead of leaving it alone). (2) `PhotoImporter.matchByFilename`'s
directory scan (real, blocking filesystem I/O) ran synchronously on the
`@MainActor` in both call sites — fixed with `Task.detached`, matching
`importFolder`/`importFolderTree`'s own established discipline for the
identical concern.

Round 2: reviewer independently reverted the collision-probe self-
exclusion fix in a scratch copy and confirmed the new
`testRelocatePhotosToItsOwnCurrentPathSucceeds` regression test genuinely
fails without it (the sibling `testRelocatePhotosWithinBatchCollisionOnlyFirstWins`
test does NOT pin that specific fix — it's a forward regression guard for
new behavior, not a before/after pin, confirmed by the same revert
check) — APPROVE. Small polish applied after APPROVE, not requiring a
third round: `activateFolderAccess`'s returned warning was being treated
as unconditionally fatal even though only ONE of its two failure modes
actually blocks a relocate (a failed bookmark WRITE still leaves access
working for the current session) — fixed to fold the warning into the
final summary message instead of always aborting, matching
`importFolder`'s own established handling of the identical helper; and
the result summary now explicitly notes that saved-edit sidecar files
are not moved by this action (documented, not solved — moving one would
need write access to the OLD folder too, not otherwise needed anywhere
in this app).

**Known, documented gaps, not solved this slice**: sidecars (saved
edits) are never moved — surfaced in the result message instead;
folder-mirrored collection membership (`importFolderTree`) is not
updated by a relocate, so a photo can end up listed under a "Folders"
sidebar entry it's no longer physically inside; and — inherited directly
from missing-file detection's own design — a photo can only be located
via this feature once it reads as "Missing" in the first place, which
requires its ORIGINALLY-IMPORTED folder root to still exist on disk. So
moving or renaming the WHOLE containing folder (not just one file out of
an otherwise-intact folder) isn't covered: those photos never show
"Missing", so "Locate…"/"Locate Selected…" are never offered for them.

538 tests (10 new): `CatalogDatabaseTests` gained
`testRelocatePhotosUpdatesPathFilenameAndFileSize` (using REAL temp
files so the `fileSize` claim in its own name is actually exercised, not
just fake `/tmp/...` paths), `testRelocatePhotosSkipsADestinationAlreadyClaimedByAnotherRow`,
`testRelocatePhotosWithinBatchCollisionOnlyFirstWins`,
`testRelocatePhotosToItsOwnCurrentPathSucceeds`, and a strengthened
`testRelocatePhotosOnNonexistentIDIsANoOp` (now also asserts row count
and that an unrelated row is untouched). `PhotoImporterTests` gained 3
tests for `matchByFilename` (case-insensitive match, unmatched count,
sidecar/non-image files correctly excluded). Live-verified by the user
— relocate worked correctly on the first try.

### Library grid: thumbnail-size slider overlap bug, fixed 2026-09-08

Live-caught by the user (with a screenshot) right after relocate shipped:
dragging the Library grid's thumbnail-size slider to its smallest
setting made each cell's folder-menu icon visually overlap the star-
rating row of the adjacent cell.

Root cause: `LibraryThumbnailCell`'s outer `VStack` (filename + the
star/flag/folder-menu row below the thumbnail) had no width constraint
of its own — only the inner thumbnail `ZStack` was pinned to `cellSize`.
The icon row's fixed-size content (5 star buttons + a flag icon + a
folder-menu icon, none of which can compress) needed more width than one
grid column had at the slider's smallest sizes, and with nothing
constraining the outer VStack, SwiftUI let it paint past the cell's own
bounds into the next column.

Fix went through 3 reviewer rounds (Opus 5), each catching a real,
precisely-measured problem with the previous round's own numbers — this
was the most measurement-intensive UI fix of the session:
- **Round 1 (FIX FIRST)**: the proposed `.frame(width: cellSize)` +
  `.clipped()` structural fix was correct, but the doc comments'
  "~108pt" estimate for the icon row's minimum width, and the new
  slider floor of 120, were both unmeasured guesses. Reviewer measured
  (via `NSImage` glyph metrics) the row's TRUE minimum at the icons'
  original font size as exactly 120.0pt — identical to the proposed
  floor, meaning zero margin, with a macOS `Menu`'s built-in disclosure
  indicator (unaccounted for at all) as an additional unknown that could
  make it worse.
- **Round 2 (FIX FIRST)**: shrunk the flag/folder icons to `.caption2`
  (matching the star row) and added `.menuIndicator(.hidden)`. Reviewer
  re-measured with `NSHostingView.fittingSize` (layout minimum) AND
  `ImageRenderer` rasterization with a per-pixel ink sweep (visible-glyph
  minimum) — two independent methods — and found the row's true minimum
  was now 122.0pt/119pt: STILL above the 120pt floor (the "~108pt" claim
  was simply wrong), meaning `.clipped()` remained load-bearing rather
  than the intended backstop. Also confirmed `.menuIndicator(.hidden)`
  contributes exactly 0pt (kept anyway — removes the ambiguity, costs
  nothing) and that the read-site clamp genuinely closes the
  stale-persisted-value gap from round 1.
- **Round 3 (APPROVE)**: tightened the icon row's own `HStack` spacing
  from 6 to 4 (the reviewer had already measured this exact variant as
  116.0pt/113pt during round 2 while checking alternatives). Re-verified
  with both methods again post-fix: real margin (4pt layout/7pt ink) at
  the floor, no ink loss at `cellSize == 120` down to a sub-floor 110,
  and — via an ink-gap analysis rather than a "does it look cramped"
  guess — the tightened gap (6.0pt) is still 1.5pt WIDER than the
  star-to-star gap already shipping in the same row, so it reads no more
  cramped than its own existing neighbors. Two more non-blocking
  inaccuracies caught and fixed before commit: the `.onAppear` migration
  recomputed `min(max(...))` independently instead of reusing the
  already-correct `cellSize` read, so a hand-corrupted NaN persisted
  value would re-detect and rewrite the same NaN forever (the exact
  repeated-write the guard existed to prevent) — fixed by writing back
  `cellSize` itself; and a stale doc comment on the slider still claimed
  120 was the ORIGINAL font size's "exact, zero-slack minimum," when the
  actual measurement showed 120 was 9pt below that minimum (actively
  insufficient, not zero-slack) — corrected.

New `LibraryGridView.thumbnailSizeRange` is the single source of truth
for the slider's `100...240` → `120...240` bounds (previously duplicated
as separate literals across the slider, the read-site clamp, and the
migration); a persisted pre-fix value below 120 is normalized on next
appearance, with a clamped `cellSize` computed property covering the
gap on the very first frame before that appearance-triggered migration
runs. 538 tests unchanged (pure SwiftUI layout code, no extracted pure
logic — matches this codebase's own convention of not unit-testing
plain View bodies; verified by the reviewer's own precise rendering
measurements instead, both pre- and post-fix, across all 3 rounds).
**Live-verified by the user (2026-09-08)**: no more overlap at the
slider's smallest setting.

---

## Session checkpoint (2026-09-08) — safe pause point

Everything below is committed on `master`; working tree is clean as of
`ef12a70`. All four items this session shipped, were reviewer-approved
(Opus 5), tested, and live-verified by the user:
1. Batch-add-to-collection (`19cd0cc`/`612f460`)
2. Missing-file detection in the Library grid + Editor filmstrip
   (`e5533c1`/`095fcb3`)
3. Relocating missing photos, single + batch (`a4f2435`)
4. Library grid icon-row overlap fix (`ef12a70`)

D5 (Library management gaps) is now **fully complete** — all three parts
shipped across this and earlier sessions.

### D6: Accessibility pass over custom controls (complete, live-verified 2026-09-08)

A full survey (Explore agent) of `Sources/UI/` found the app's entire
accessibility surface was 7 modifier call sites in 3 files (`ThinSlider`,
`EditControlRows`, `EditorFilmstripView`) — every other custom control
(built from `Button`+bare SF
Symbol, `Color.clear`+gesture, `Canvas`, or `.onTapGesture`) was silent,
stateless, or unreachable to VoiceOver. Confirmed with the user
(AskUserQuestion) to do a full declarative pass across every gap found,
not just D6's 4 named controls, and to verify live via the real
Accessibility API rather than a manual VoiceOver walk.

**What shipped** (~13 files, additive-only — zero behavior change for
mouse/pointer users): `StarRatingRow` collapsed from 5 unlabeled buttons
into one `accessibilityElement` with a value ("N of 5 stars") and an
adjustable action; the Library grid's selection checkbox/flag button/
folder-options menu/edited badge all labeled (the filename caption below
the thumbnail is hidden instead, to avoid double-announcing it — the
thumbnail element itself now carries the filename as its label), with the
whole grid cell restructured so its thumbnail becomes ONE focusable "open"
element (a sibling of the checkbox, not a `.contain`-container-level
action — see the round-1/round-2 fix below for why); the Editor filmstrip
cell; Selective Color's 8 band swatches; the preset delete button; armed-
state buttons (WB pick, Fix Red-Eye, Compare menu, Filmstrip toggle,
`EditorTabBar` tab pills) now expose `.isSelected` instead of color-tint
only; Crop's aspect-preset rows; `EditSliderRow`'s click-to-type readout
(previously a bare `Text` + tap gesture, the most invisible affordance in
the app) now announces as an action; and a new adjustable action on
`CompareDividerOverlay`, reusing step math extracted from `ThinSlider`
into `ThinSliderGeometry.incremented`/`decremented` (unit-tested). Five
overlay sites (`CropOverlayView`, `RedEyeOverlayView`, `PanOverlay`,
`HistogramView`, and the WB tap-capture overlay inline in `ContentView`)
got deliberate, documented `.accessibilityHidden(true)`
— mouse-only spatial gestures or pure decoration, each comment naming the
already-existing alternative AT path where one exists (crop's 4 insets
stay adjustable via `CropTabView`'s `EditSliderRow`s). `ThinSlider` gained
an optional `valueDescription` closure so rows announce their real
formatted value (e.g. "6500K", "+0%") instead of an always-0–100%
readout — `EditSliderRow` passes its existing `format` closure. New
IMPROVEMENTS.md **D8** entry tracks the 3 mouse-only spatial overlays
(WB eyedropper tap, red-eye placement, pan/zoom-reset) explicitly
deferred as new-interaction-design work, not labeling.

**Reviewer (Opus 5): 3 rounds, FIX FIRST → FIX FIRST → APPROVE** — every
round caught real issues, none of them cosmetic:
- **Round 1**: `EditorFilmstripView`'s missing-photo cell had its own
  `.accessibilityLabel("Missing")` silently discarded once the cell got
  `children: .ignore` — fixed by folding `isMissing` into the cell's own
  label. The whole Library grid cell had `.accessibilityElement(children:
  .contain)` + `.isButton` + `.accessibilityAction` all together — flagged
  as an unreliable combination (VoiceOver navigates INTO a `.contain`
  container rather than activating it) — fixed by moving the "open"
  label/trait/action onto the thumbnail content specifically (wrapped so
  it's one focusable child, a sibling of the checkbox `Button`, inside the
  same `ZStack`), leaving the outer container as a bare `.contain` with no
  trait/action of its own. Also: `StarRatingRow`'s adjustable action fired
  a redundant DB write at the 0/5 bounds (guarded); `ThinSliderGeometry`
  duplicated its own `/20` step constant across `incremented`/
  `decremented` (extracted to a private `step(in:)`); the thumbnail-size
  slider's value truncated instead of rounded; `EditSliderRow`'s readout
  and its `ThinSlider` both announced the identical value (readout
  relabeled to an action-only "Type X value").
- **Round 2**: caught that fixing round 1 by wrapping the thumbnail
  content in a `Group` was still fragile — SwiftUI applies a `Group`'s
  modifiers to EACH child individually, not to the group as a whole, so
  it only behaved as one element because the underlying `if`/`else
  if`/`else` happens to always yield exactly one child; switched to a
  real `ZStack` so the "one element" intent is structural, not incidental.
  Also caught that a doc-comment claim ("tracked as a follow-up") pointed
  at an IMPROVEMENTS.md entry that didn't exist yet — the same defect
  class as round 1's regression, just relocated into prose — fixed by
  actually writing D8 before commit. Smaller nits: the filename was still
  announced twice (thumbnail label + visible caption) — hidden the
  caption from accessibility; the edited badge relied on label
  propagation instead of its own explicit element; the flag button used a
  different state idiom (`accessibilityValue`) than the checkbox
  (`.isSelected`) for the same binary-state shape — unified on
  `.isSelected`.

**Live AX-tree verification (2026-09-08)**: the user's standing rule
requires asking permission per task before any screen-automation/AT
driving — asked via AskUserQuestion up front, approved for this task.
First attempt used `System Events`/AppleScript, and appeared to show
several fixes NOT working (StarRatingRow still 5 separate buttons, the
new thumbnail "open" button missing entirely, no labels surfacing on any
custom button) — before concluding those were real regressions, checked
against an already-shipped, previously-verified-live control
(`ThinSlider`'s own adjustable action) using the same method, which
ALSO appeared broken. That ruled out the app: `System Events`' Apple
Event bridge simply doesn't expose `AXTitle`/`AXDescription` for these
SwiftUI-composed elements at all (confirmed: the attribute doesn't exist
in `AXUIElementCopyAttributeNames`' own list, not merely empty) — a
tooling blind spot, not an app defect. Also separately caught: the
running `PhotoApp.app` process during the first inspection pass predated
today's rebuild entirely (stale binary from an earlier launch), which
would have invalidated any result either way — quit and relaunched the
freshly-built binary before drawing any conclusion.
Switched to a small `ApplicationServices`/`AXUIElement`-based Swift CLI
(the same underlying API VoiceOver itself uses) against the fresh
process, which confirmed every fix genuinely works at runtime:
- Library grid: thumbnail element's `AXDescription` = the photo's
  filename, role `AXButton`; `AXPress` on it genuinely opened the photo
  in the Editor (window title changed). Checkbox labeled "Select photo".
  `StarRatingRow` is ONE `AXUnknown` element, `AXAttributedDescription` =
  "Rating", `AXValueDescription` = "No rating"/"N of 5 stars"; `AXIncrement`/
  `AXDecrement` genuinely changed the persisted rating (verified via a
  fresh process query after each action, then reverted to 0 to leave the
  library untouched). Flag button labeled "Flag"; folder menu labeled
  "Photo options"; edited badge labeled "Edited".
- Editor: `EditSliderRow`'s readout announces as "Type Temperature value"
  (action-only, no duplicate value). The `ThinSlider` value fix confirmed
  directly: Temperature announces `AXValueDescription` = "6500K" (not
  "50%"); Black Point (a percent-formatted row) announces "+0%", matching
  its own on-screen format exactly.
- Armed-state traits confirmed structurally, not just visually: "Pick
  White Balance" has NO `AXSelected` attribute at rest, gains
  `AXSelected = 1` after `AXPress` arms it, and loses it again on
  disarm. `EditorTabBar`'s "Adjust" pill correctly shows `AXSelected = 1`
  while active (a bonus find — this trait wasn't in the original survey's
  Selective Color/Compare/Filmstrip list but uses the identical pattern).
  Selective Color's "Red" swatch (the default band) correctly shows
  `AXSelected = 1`.
- The `.accessibilityHidden(true)` overlays are moot in practice, not
  just successfully hidden: the image pane's `Color.clear`+gesture
  overlays (WB tap, red-eye, pan) contribute ZERO accessibility children
  regardless of the modifier — confirmed by diffing the pane's child
  count with WB-pick armed vs. disarmed (4 children either time, all 4
  being the `EditorTabBar` pills) — matching the reviewer's own round-2
  non-blocking note that `Color.clear`/`Path`/`Canvas` don't vend
  accessibility elements on this platform in the first place. The hidden
  modifiers stay as documentation of intent, not as something load-bearing.

**Not independently live-verified this pass** (reviewed statically only,
same "covered by construction" convention this file uses elsewhere):
`CompareDividerOverlay`'s adjustable action (identical `ThinSliderGeometry`
recipe as the already-verified `StarRatingRow`/`ThinSlider`, not
independently re-tested through Compare Split mode); the folder menu's
per-collection "member" label (macOS bridges `Menu` content to
`NSMenuItem`, which the reviewer flagged as commonly ignoring SwiftUI
accessibility modifiers — not confirmed either way); the filmstrip's
missing-photo label fold-in (needs a photo whose original file is
actually absent on disk, not set up this pass).

543 tests (5 new `ThinSliderGeometryTests` cases for the extracted step
math, up from 538) — consistent with this codebase's standing convention
that plain SwiftUI `View` bodies aren't unit-tested, only pure extracted
geometry is.

D6 is now **fully complete**. IMPROVEMENTS.md's D8 (deferred keyboard/AT
paths for the WB eyedropper/red-eye placement/pan-zoom-reset) is the only
accessibility work left, and is explicitly out of scope until it gets its
own interaction-design session.

**Next step**: nothing else is queued from IMPROVEMENTS.md's D-series —
it's now fully shipped (D1–D6, D8 tracked separately as new work, not a
gap in D6 itself). Candidates for the next session: **D8** (new
interaction design, not a quick follow-up — needs its own Plan Mode
scoping) or **Phase 7** (Local Adjustments/Masking, CLAUDE.md's own
roadmap item 7 — slice 1 is a performance probe, see that section for
the full slicing plan). Per CLAUDE.md workflow rules, start either with
Plan Mode.

### D4: Library keyboard support (complete, live-verified 2026-09-09)

`IMPROVEMENTS.md`'s D4 entry, flagged there as "a real feature with
design decisions — Plan Mode, confirm scope with the user first."
Research (Explore agent) before designing: the app's entire existing
keyboard surface was ⌘-modified `Commands`/`CommandMenu` items
(`PhotoAppApp.swift`) — zero `.onKeyPress`/`.focusable()` precedent
anywhere, and the one low-level `NSEvent` monitor in the app
(`MetalImageView`'s scroll-wheel handler) was confirmed the WRONG tool
here, since it fires before SwiftUI's own focus dispatch and would steal
keystrokes from the grid's search `TextField`. Confirmed with the user
(AskUserQuestion) to build full 2D grid navigation (all four arrow
directions, matching Lightroom/Photos) rather than a Left/Right-only
linear scope.

**What shipped**: a new `focusedPhotoPath: String?` on `CatalogModel` —
deliberately a DIFFERENT shape from the existing export-selection
`selectedPhotoIDs: Set<Int64>` (single optional, path-keyed, not cleared
on Collection/Folder switch, since a stale path just reads as "nothing
focused" against a fresh `displayedPhotos` lookup with no extra
invalidation code needed). New `Sources/UI/LibraryGridColumns.swift`
(pure, unit-tested — `CropAspectMath`/`CompareLayout`/`ZoomPanGeometry`/
`ThinSliderGeometry` precedent): the fit formula `GridItem(.adaptive(
minimum:))` computes internally, made explicit so Up/Down arrow math has
an authoritative column count to jump by (SwiftUI never exposes an
adaptive grid's own rendered column count). `LibraryNavigation.neighbor(
of:in:offset:)` needed ZERO changes — already generic on offset, reused
directly for Left/Right (`±1`) and Up/Down (`±columnCount`).
`LibraryGridView` gained `.focusable()`/`@FocusState`/`.onKeyPress`
keyboard capture, a `ScrollViewReader` (second use in the app, after
`EditorFilmstripView`'s filmstrip) to scroll the focused cell into view,
and a white focus-ring overlay on `LibraryThumbnailCell` — deliberately a
different color from the selection checkbox's `Color.accentColor` so
"keyboard-focused" and "export-selected" never visually merge. Arrow
keys/Return/digits/`.`/`f` all reuse existing mutators
(`catalog.setRating`/`setFlagged`, the same `onOpen` closure a mouse
click already calls) — no new `CatalogModel` write paths.

**Reviewer (Opus 5): 3 rounds, FIX FIRST → FIX FIRST → APPROVE** — the
most consequential review sequence of any D-series item: BOTH round-1
fixes for round-1's own blocking findings turned out to be broken, caught
only because round 2 verified empirically (an `NSHostingView` probe)
instead of trusting the reasoning:
- **Round 1** found: (1) the width `GeometryReader` was chained after
  `.padding()` on the `LazyVGrid` itself, measuring a padded value instead
  of the pane's real available width; (2) mouse clicks never wrote
  `focusedPhotoPath` at all (only keyboard did), so clicking a DIFFERENT
  cell's star/flag/checkbox left keyboard focus pointing at a possibly
  off-screen photo — a subsequent rating/flag keypress would silently
  mutate the WRONG photo.
- **Round 2**, re-verifying round 1's fixes: (1) moving the
  `GeometryReader` to measure the `LazyVGrid` post-padding was still
  wrong — `.fixed` columns give the grid an INTRINSIC width equal to its
  own column count, so measuring the grid's own rendered width just
  measures a function of `columnCount`, a circular fixed point untethered
  from the pane's actual width; fixed for real by moving the measurement
  to the `ScrollView`'s own frame (sized by its `HSplitView` parent,
  independent of scrollable content) with an explicit named
  `gridPadding` constant subtracted, rather than trusting `.padding()`'s
  unverified default. (2) a new `keyPress.modifiers.subtracting(.shift)`
  guard (added to stop unowned ⌘F/⌥F/⌃1-5 combos from reaching the
  plain-character branches) measured to reject EVERY arrow key press
  outright — macOS reports arrow-key events as carrying
  `.numericPad`/`.function` regardless of any real modifier, so the
  entire feature was silently dead on arrival; fixed by widening the
  subtracted set. Round 2 also caught, independently: `.fixed` columns
  create a one-way layout RATCHET — the grid's own hard minimum width
  propagates up through the `ScrollView` to the window, so enlarging the
  window could grow `columnCount` but NEVER let it shrink back (measured:
  a 1400→900→600→420pt shrink sequence stuck at the same column count
  every time) — fixed by switching to `.flexible(minimum: 1, maximum:
  cellSize)`, which has no hard minimum to propagate.
- **Round 3**, re-verifying round 2's fixes empirically again (same
  `NSHostingView`-probe discipline): both were confirmed genuinely correct
  this time — plain arrows now admitted, ⌘-combos still rejected;
  window/pane resize now tracked bidirectionally (`columnCount` measured
  cycling 7→4→2→1→4→7→1→6→1 across a real resize sequence). Non-blocking
  polish applied before commit: the modifier guard was rewritten from
  "subtract an allowed set" to "reject if any of ⌘/⌥/⌃ is held" — both
  correctness-equivalent (re-verified against the same 15 probed cases)
  and removes a macOS-12+-deprecated `.function` reference the original
  form triggered a build warning on; the `1000`-column defensive clip
  (guarding `LibraryGridColumns.count`'s documented `1_000_000`
  pathological-input ceiling against a runaway `Array(repeating:count:)`
  allocation) moved to live inside `columnCount` itself rather than only
  at `columns`' own call site, so the Up/Down key math and the rendered
  grid can't desync above that clip; two doc comments corrected against
  what the reviewer had actually measured (a scroll-restore timing "fix"
  that measured as a behavioral no-op — `ScrollViewProxy.scrollTo`
  resolves correctly regardless of which `.onAppear` triggers it; the
  scrollbar-width imprecision note's "slightly tighter" reworded to the
  measured reality, cells overlapping by ~2pt in the rare case it's
  triggered at all).

553 tests (11 new: `LibraryGridColumnsTests` — exact-fit, remainder,
single-column, and the degenerate zero/negative/non-finite-width and
zero-cellSize/huge-width cases the review rounds' own findings added).
No tests for the key-dispatch logic or focus ring themselves — plain
SwiftUI interaction glue, matching this codebase's standing convention
(`ThinSlider`, `EditSliderRow`, `CompareDividerOverlay`'s gestures are
all verified live instead).

**Live verification, in two parts.** First, an AX-driven attempt (user
authorized, same method as D6): mouse-side checks came back clean —
clicking a cell's checkbox correctly set `focusedPhotoPath` (confirmed
via `AXIncrement`/`AXDecrement` landing on exactly the clicked-then-
arrow-key-moved neighbor, never the wrong cell), and the rating/flag
state model behaved correctly under direct AX actions throughout. But
actual synthetic KEYBOARD events (`CGEvent(...).post(tap:
.cghidEventTap)`) never reached the app at all — proven cleanly by
focusing the Library's own search `TextField` via a real mouse click
(confirmed via `AXFocused == 1`, genuine AppKit-level focus) and sending
a synthetic "f": the field's value stayed empty. Mouse clicks posted the
exact same way worked perfectly throughout, so this isolates to macOS
gating synthetic KEYBOARD input specifically for an unsigned/ad-hoc
compiled tool (a separate, more restrictive TCC category than the
Accessibility permission that's already granted) — not an app bug, and
the same class of limitation the D8 review already hit trying to probe
gesture composition. Second, the user then ran the actual manual
checklist by hand (real physical key presses) and **confirmed D4 works
correctly**: arrow keys move the focus ring in all 4 directions
(wrapping row-to-row on Left/Right, stopping — not wrapping — at grid
edges on Up/Down); 0–5/`.`/`f` rate/flag the focused photo; Return opens
it; clicking a different cell then immediately pressing an arrow moves
focus from THAT cell (the per-cell `.simultaneousGesture` mouse-focus
fix); the search field is unaffected by digit/`.`/`f` keys; window
resize grows AND shrinks the column count freely (the `.adaptive`→
`.flexible` switch, the specific direction round 2 caught breaking).

### D8: Keyboard paths for the Editor's three mouse-only spatial overlays (complete, live-verified 2026-09-09)

`IMPROVEMENTS.md`'s D8 entry, opened during D6's accessibility pass:
the WB eyedropper (tap-to-pick), Red-Eye placement (tap-to-place/tap-to-
remove), and pan/zoom-reset overlays were all mouse-only, each just
`.accessibilityHidden(true)` with a comment pointing at this item.
Confirmed with the user (AskUserQuestion) to build all three in one
session rather than slicing, since WB pick and Red-Eye placement are the
SAME interaction shape (a movable point + commit) and pan/zoom-reset
shares the Editor's keyboard-focus plumbing this session had to build
from scratch anyway.

This is the Editor's FIRST use of `.focusable()`/`@FocusState`/
`.onKeyPress` anywhere — a direct sequel to this same session's D4 work
(Library grid keyboard nav), whose 3-round review sequence surfaced two
bug classes deliberately avoided here from the start: the modifier guard
used the D4-FINAL form (`keyPress.modifiers.isDisjoint(with: [.command,
.option, .control])`, not `.subtracting(.shift)`, which D4 found rejects
every arrow press outright since macOS tags arrow events with
`.numericPad`/`.function` regardless of any real modifier); and nothing
new here gives the image pane a hard minimum size the way D4's fixed
grid columns did (the new crosshair overlay is `.allowsHitTesting(false)`
and purely presentational).

**What shipped**: a shared keyboard-driven crosshair for WB pick and
Red-Eye placement — new `@State private var crosshairPosition` on
`ContentView` (normalized 0...1/y-DOWN, the same convention
`ImageDocumentModel.pickWhiteBalance`/`RedEyePoint` already use), reset
to center and auto-focused whenever either mode newly arms. Arrow keys
move it (new pure `Sources/UI/CrosshairGeometry.swift`, unit-tested);
Return commits (WB: the exact existing `pickWhiteBalance` call, then
disarms, mirroring the mouse handler; Red-Eye: a new shared
`RedEyeHitTest.toggling(_:in:fitRect:threshold:)`, extracted so the
mouse tap gesture and this keyboard path can't silently drift — see
below); Escape disarms without committing, a genuinely NEW capability
(previously the only way out was a toolbar click or switching tabs). New
`Sources/UI/EditorCrosshairOverlay.swift` renders it as a "+" reticle
(deliberately NOT `RedEyeOverlayView`'s own ring style — see round 1
below). Separately, arrow keys pan while zoomed (reusing the EXISTING,
already-tested `ZoomPanGeometry.clampedPan` — no new pan math) and `"0"`
resets zoom+pan to identity, mirroring `PanOverlay`'s existing double-tap
gesture exactly. Both the WB mouse handler and a new `RedEyeOverlayView.
onTap` callback keep `crosshairPosition` in sync with the mouse, so
switching from mouse to keyboard mid-session continues from the last
touched point — the direct analogue of a real bug D4's reviewer caught.
`ContentView`'s image-pane `ZStack` (already 6 conditional branches —
Crop/WB/RedEye/CompareDivider/Pan×1-2) was refactored, extracting those 5
pre-existing branches plus the new crosshair into one `pointAndZoomOverlays`
property, proactively avoiding this file's own documented Swift
type-checker ceiling rather than waiting for a 7th inline branch to hit it.

**Reviewer (Opus 5): 2 rounds, FIX FIRST → APPROVE**:
- **Round 1** caught 4 real issues: (1) holding Return past the
  key-repeat delay non-deterministically toggled the same Red-Eye point
  on/off — `.onKeyPress` defaults to `[.down, .repeat]` phases, and
  add-or-remove is NOT idempotent — fixed by gating only the Return
  commit on `keyPress.phase == .down` (arrows/Escape deliberately left
  ungated: arrows need repeat, Escape's repeated disarm is idempotent).
  (2) The keyboard crosshair was visually IDENTICAL to a committed
  Red-Eye marker (same ring style/size/color), so a keyboard user got
  zero feedback that a Return actually landed — fixed by redesigning
  `EditorCrosshairOverlay` from a ring to a "+" reticle. (3) The Red-Eye
  commit path reimplemented `RedEyeOverlayView.toggle(at:)`'s add-or-
  remove sequence by hand, sharing only the threshold constant — fixed
  by extracting `RedEyeHitTest.toggling`, now the ONE implementation both
  the mouse gesture and the keyboard commit call. (4) Two
  `.accessibilityHidden(true)` doc comments (`RedEyeOverlayView.swift`,
  `PanOverlay.swift`) still pointed at D8 as unfinished future work, when
  D8 *is* this diff — reworded to state a keyboard equivalent now exists
  elsewhere, and this specific mouse-capture layer stays hidden only
  because it itself vends no accessibility content. Also flagged for
  live verification, not fixed in code: the new parent-`TapGesture`
  (focus-reclaim) running alongside child `SpatialTapGesture`s (WB/
  Red-Eye tap)/`DragGesture` (Pan) — a composition with no precedent in
  this codebase (D4's own click-reclaim fix only proved this pattern
  safe against `Button` taps, not spatial gestures); the reviewer
  attempted an `NSHostingView`-probe the same way D4's round 2 did, but
  couldn't get synthetic mouse events to reach SwiftUI's recognizers in
  a non-activated accessory app — an inconclusive harness, not a clean
  result either way.
- **Round 2** re-verified all 4 round-1 fixes correct (including
  checking the actual SDK interface for `KeyPress.phase`'s real type, and
  hand-verifying the new "+" `Path`'s 4 line segments for correct,
  non-crossed geometry) — APPROVE, with 2 non-blocking polish items
  applied before commit: the new pane-level `.accessibilityLabel` used
  the default `.accessibilityElement` children mode, which would have
  let it override `CompareDividerOverlay`'s own already-shipped named,
  adjustable accessibility element living in the same subtree (fixed
  with `children: .contain`, matching that overlay's own established
  pattern); and a doc comment on `RedEyeOverlayView.hitTestThreshold`
  still described the pre-round-1-fix hand-rolled-duplicate design rather
  than the shared `RedEyeHitTest.toggling` it now feeds.

566 tests (13 new: 10 `CrosshairGeometryTests` for the step/clamp math,
3 added to `RedEyeHitTestTests` for the new shared `toggling` function).
No tests for the key-dispatch methods, focus wiring, or the gesture
composition itself — plain SwiftUI interaction glue, matching this
codebase's standing convention; verified live instead (below).

**Live-verified by the user (2026-09-09).** Manual walkthrough (not
AX-driven — see D4's own section above for why synthetic keyboard events
don't reach the app in this environment) confirmed: WB pick's arrow keys
move a white "+", Return samples and disarms, Escape disarms without
sampling; Red-Eye's arrow keys move a yellow "+", Return adds/removes a
point, Escape disarms; clicking to place a point with the MOUSE then
immediately pressing an arrow correctly continues from that clicked
point rather than jumping to center; zoomed-in arrow-key panning and
`"0"`-resets both work; and — the ONE thing neither review round could
confirm statically or empirically — the new parent-`TapGesture`
(focus-reclaim) coexisting with the child `SpatialTapGesture`s/
`DragGesture` caused no regression: mouse-only WB/Red-Eye placement,
click-drag-to-pan, and `PanOverlay`'s own double-tap-to-reset gesture
(the single riskiest case for that composition) all still work
identically to before this session.

**Next step**: nothing else queued from `IMPROVEMENTS.md` — with D8
shipped, that backlog file is down to just **P6** (minor,
take-if-passing-by only, not a dedicated session). The next real
candidate was **Phase 7** (Local Adjustments/Masking, `CLAUDE.md`'s own
roadmap item 7 — slice 1 is a performance probe). Per CLAUDE.md workflow
rules, started with Plan Mode — see the Phase 7 slice 1 write-up below.

## Phase 7 slice 1 (Local Adjustments/Masking performance probe) — ✅ COMPLETE (2026-09-08)

Scoped by `CLAUDE.md`'s own Phase 7 roadmap as a throwaway measurement,
not a shipped feature: one hardcoded radial mask, one adjustable
parameter, no UI, no persisted `EditState` field — to answer, with a
real number, whether one additional mask-composite pass per frame is
architecturally viable before slice 2 (the real mask data model) gets
built on an assumption that might be "no."

**Method**, matching this codebase's own exclusive performance-
measurement convention (P2/P3/P4/P5's precedent — temporary
`CFAbsoluteTimeGetCurrent()` instrumentation, exercised live, then fully
reverted before commit, confirmed via a clean `git diff`): a temporary
`applyMaskProbe` stage was added to `EditPipeline.apply` right after
`applyRedEye` — structurally identical to that function's own
full-extent-geometry → `CIRadialGradient` → `CIBlendWithMask` shape —
reusing the EXISTING `exposureEV` field as the probe's one "adjustable
parameter" so `ImageRenderer`'s P3 `EditState`-keyed pipeline-output
cache stayed valid (a renderer-level input outside `EditState` would
have gone stale against that cache, per its own doc comment) and so
dragging the real Exposure slider drove a genuine continuous-drag
measurement. `ImageRenderer.draw(in:)` got matching temporary timing
instrumentation, logging `[P7] frame=<ms> proxy=<bool>
drawableSize=<w>x<h>` to a file inside the sandboxed app's own container
(`print()`'s stdout is unobservable once the sandboxed binary is
launched normally via `open` — a raw/`script`-wrapped exec bypasses
LaunchServices entirely and produces no window at all).

**Live measurement** (user-authorized, this one task, via synthetic
`CGEvent` mouse drags on the real Exposure `ThinSlider` — not keyboard,
which does not reliably reach this app's SwiftUI views in this
environment): two real assets at the same 2268×1385 drawable size, a
20.7MP JPEG (`IMG_6564.jpeg`) and a 24MP Nikon D610 RAW (`DSC_1665.NEF`,
via `RawDecoder.materialize`'s cached buffer). Measured with the probe
stage ON, then with it commented out for an OFF baseline, both via a
continuous ~3s drag (exercises P2's downscaled interactive proxy) and
via isolated, spaced-out single-step edits (forces full-resolution,
non-proxied frames):

| Case | Proxy frames (P2 engaged) | Full-res frames |
|---|---|---|
| JPEG, mask OFF | ~0.33–0.4ms | ~0.35–0.65ms |
| JPEG, mask ON | ~0.34–0.65ms | ~1.07–1.59ms |
| RAW, mask OFF | ~0.33–0.58ms | ~0.89–1.38ms |
| RAW, mask ON | ~0.34–0.59ms | ~0.98–1.38ms |

Findings: the mask's added cost on proxy frames is near the measurement
noise floor (P2's downscale makes one extra composite pass essentially
free). On full-resolution frames it's a real but small ~0.6–1.0ms on
JPEG; on RAW the delta is within noise — RAW's own already-heavier
per-frame cost (even served from `RawDecoder.materialize`'s cached
buffer) appears to dwarf one added composite pass at this resolution.
A architectural finding confirmed live rather than assumed:
`CIContext`'s lazy evaluation means a composite pass's cost scales with
the DRAWABLE/display resolution, not the source image's megapixel
count — the 24MP RAW and 20.7MP JPEG showed statistically
indistinguishable mask-pass costs, so the original "large JPEG" sizing
concern is less severe than it looked architecturally, at least for
non-RAW images.

**Go/no-go: GO.** Every measured number, including the worst case
(~1.6ms for one mask on a full-resolution non-proxied JPEG frame), sits
far under the 16ms/60fps budget P2/P3/P5 already use as this codebase's
bar. Slice 2 (the real mask data model) is architecturally cleared to
proceed on the existing P2/P3 caching foundation — no speculative
mitigation (caching masked layers between frames, downscaling,
throttling) needed before starting it.

Also corrected as part of this session: `CLAUDE.md`'s Phase 7 "Hazard 2"
paragraph claimed "zero per-frame caching exists anywhere in the render
path" — true when written (2026-09-03), stale since P3's pipeline-output
cache (2026-09-04) and P2's interactive proxy (2026-09-07) both shipped
after. Corrected in place, along with its stale `ImageRenderer.swift`
line-number citations.

No reviewer agent pass — this slice ships no code (the final commit is
doc-only; `EditPipeline.swift`/`ImageRenderer.swift` are back to their
pre-session state, confirmed via `git diff`). 566 tests unchanged,
confirmed passing after the revert.

**Next step**: Phase 7 slice 2 — the real `Mask` data model and Radial
mask UI (no combining yet), per `CLAUDE.md`'s own slicing plan. Start
with Plan Mode per the standing workflow rule.

## Phase 7 slice 2 (Mask data model + Radial mask, data model/pipeline
## half) — ✅ COMPLETE (2026-09-09)

Scoped per Plan Mode (draft plan `robust-prancing-papert.md` had left one
open question — the per-mask parameter set — unanswered before the prior
session ended; resumed by asking it fresh rather than assuming the
draft's own recommendation). User confirmed: the full curated 8-param
set (Exposure, Contrast, Highlights, Shadows, Clarity, Saturation,
Temperature, Tint); split this slice into a data-model/pipeline session
(this one) and a separate future UI session, given the scope was larger
than the original draft assumed (5 new files, ~70 new tests, a
behavior-preserving refactor, 12+ `ContentView` wiring sites for the UI
half alone); keep Clarity in scope but measure its real N-mask cost live
rather than deferring it; and block zoom while a mask is selected in the
future UI (decided now so it isn't re-litigated later).

**What shipped**: `Sources/EditEngine/Mask.swift` — a new
`Identifiable, Equatable, Codable` struct: 6 geometry fields (center X/Y,
radius X/Y, rotation, feather — all normalized fractions of the CURRENT
post-crop extent, SAME top-left/y-DOWN convention `RedEyePoint` already
uses) plus the 8 curated adjustment params, EVERY one of which has
identity `0` (a deliberate property — `EditState` itself has five
non-zero identities, each a small trap for reset/compare/preset code to
remember; choosing per-mask Temperature as a relative Kelvin OFFSET
rather than an absolute value is what buys this here). First nested type
in this codebase to need HAND-WRITTEN schema-tolerant `Codable` one level
down (`RedEyePoint`/`RawNeutralPoint` both get away with synthesized
`Codable` — they're 2-field points with no room to grow); mirrors
`EditState`'s own `decodeIfPresent ?? default` pattern via a private
`CodingKeys` + `init(from:)` in a separate extension.

New `Sources/EditEngine/RadialMaskGeometry.swift` — pure, `CoreGraphics`-
only ellipse-via-affine-transform math (mirrors `CropAspectMath`'s "real
math gets unit tests despite living near rendering" precedent).
`CIRadialGradient` is circle-only, so an ellipse is built by generating
the base gradient at the LARGER of the two requested pixel radii, then
scaling the smaller axis down (never magnifying a procedural generator).
Handles the y-down-to-y-up center flip (reusing `applyRedEye`'s own `1 -
point.y`) and the UI-clockwise-to-CIImage-CCW rotation negation
(verified against `applyStraighten`'s own documented convention, not
assumed). Degenerate inputs (non-finite, zero/negative radius, a
sub-half-pixel radius, `CGRect.infinite`/`.null`) all return `nil`,
letting the caller skip that mask entirely — the same "guard makes
identity byte-identical to absent" discipline every other pipeline stage
in this file already follows.

New `EditPipeline.applyMasks` stage, inserted between the existing
Red-Eye and Vignette stages (mask geometry must map against the CURRENT
post-crop extent, same argument the file already makes for those two;
after Red-Eye because Red-Eye is corrective and masks are creative
stylization — a mask over an eye should see the already-corrected pupil;
before Vignette/Definition/NR/Sharpen because those are global stages
that should act on the final, already-locally-stylized image). Each
mask's Contrast/Shadows/Highlights/Saturation/Clarity are folded into
ONE shared `encodeToPerceptual`/`decodeToLinear` round trip rather than
each opening its own — a measured requirement, not a style choice
(`applyPerceptualAdjustments`'s own doc comment already records that a
scene-linear contrast pivot crushes photographic middle gray toward
black). Shadows/Highlights reuse `applyCurves`'s exact `EffectiveTone`/
`kCurvePointSpan` machinery, NOT `CIHighlightShadowAdjust` —
`EditState.definition`'s own doc comment already records that filter as
measured to be an asymmetric tone-mapper, rejected once already for the
same reason. A small behavior-preserving refactor extracted
`unsharpDefinition` out of the existing `applyDefinition`, so per-mask
Clarity reuses the IDENTICAL filter construction as the global Definition
slider (verified: every pre-existing Definition test stayed green,
unedited, after the extraction). Overlapping masks COMPOUND
(sequential, each applying on top of the previous mask's already-adjusted
result) — deliberately the opposite of Red-Eye's union-then-correct-once
design, since masks are independent user-authored adjustments meant to
stack, matching Lightroom's own behavior and this slice's confirmed
"multiple simultaneous masks" scope.

`EditState` gained `masks: [Mask] = []` (the second variable-length
field after `redEyePoints`, a bigger step up since each mask owns a full
independent param set rather than sharing one). Cleared by
`comparisonOriginal()` (masks are retouching, same as `redEyePoints`,
with an even simpler argument — a non-identity mask is unconditionally
active, no non-zero-default subtlety to argue). NOT copied by
`applyingPreset(onto:)` (a mask's placement is specific to one photo's
composition, joining `redEyePoints` as a documented exception to that
method's own field-partition rule). Explicitly excluded from
`requiresRawRedecode` (masks are an `EditPipeline` stage, not a
`CIRAWFilter` setting — including them would fire a multi-second RAW
re-decode on every mask drag). `EditHistory`'s doc comment updated to
name both unbounded fields and do the actual memory arithmetic (~128 KB
worst case, over-stated since Swift arrays are copy-on-write) rather than
leave a stale "only `redEyePoints`" claim in place.

**Reviewer (Opus 5): 3 rounds — FIX FIRST → APPROVE → a clean final
APPROVE**, the most thorough pass this codebase's masking work has had.
Round 1 caught a real correctness bug the live-testing-only verification
plan wouldn't have caught before shipping a UI: mask Contrast/Shadows/
Highlights/Saturation had NO clamp, unlike the global path's own
`effectiveTone(_:)` (which clamps to -1...1 specifically so the
downstream filters' native factors never go negative). Since this slice
ships with no UI, a hand-authored sidecar is the only input path today,
and nothing else bounds these values — measured on a real pixel,
`contrast: 5` drove `CIColorControls.contrast` to 6, producing negative
RGB channels (a hue inversion), falsifying the type's own documented
"reads the same as the identically-named global slider" guarantee for
any out-of-range value. Fixed by reusing the SAME `clamped(_:to:)`
helper the global path already has. Round 1 also caught: a factually
backwards doc comment claiming `radiusX`/`radiusY`'s different
denominators keep "a circle a circle" (they don't — equal fractions draw
an ellipse matching the extent's own aspect ratio, not a circle); a
NotEqual-only order-check test (`testMasksRunBeforeVignette`) that would
have passed even if `applyMasks` moved to run anywhere else in the
pipeline, not just its actual shipped position; and two fully
tautological tests asserting things already covered correctly elsewhere.
Round 2 (after those fixes) independently re-derived the color-domain
math from scratch, re-measured the `CIRadialGradient` finite-extent
claim directly (confirmed: transparent `color1` → real finite extent;
only opaque `color1` goes to `CGRect.infinite`, matching the doc
comment), and suggested a genuine perf optimization: crop the per-mask
`corrected` result to the ellipse's own bounding box right before the
blend, verified BYTE-IDENTICAL (max diff 0.0, checked across 5 configs
including a rotated 3:1 ellipse and one fully off-image) since the mask
value is exactly 0 everywhere outside that region anyway. Also caught a
B&W/mask interaction bug (a mask's Temperature/Tint would repaint color
into an already-forced-desaturated B&W photo, since the global B&W
desaturation runs BEFORE `applyMasks`) and a non-determinism gap (the
`id` decode fallback used a fresh random `UUID()`, meaning two decodes
of the same id-less sidecar bytes weren't `Equatable`-equal — replaced
with a deterministic FNV-1a-style hash of the mask's own other fields).
Round 3 re-verified every one of those fixes from first principles
(including mutation-testing the two new/strengthened tests by
temporarily breaking the code they guard and confirming they actually
fail) and gave a genuine, non-rubber-stamp APPROVE; the four remaining
non-blocking wording/coverage nits from that round were fixed anyway
before commit (two doc-comment corrections, narrowing the
`innerRadiusFraction` NaN guard to not mishandle `+infinity`, and a new
test pinning the round-1 clamp itself so a future refactor dropping it
would fail a test, not just a live-authored sidecar).

**Live-measured perf (required — CLAUDE.md's own slice-1 GO was
conditional on this exact re-check)**: 3 masks with Clarity active,
same `CFAbsoluteTimeGetCurrent()` probe-and-fully-revert methodology as
slice 1 (temporary logging added to `ImageRenderer.draw(in:)`, exercised
live via synthetic `CGEventLeftMouseDragged` sequences — plain
`CGEventMouseMoved` between a down/up pair was tried first and silently
failed to register as a continuous drag; explicit `leftMouseDragged`
events were required — then the instrumentation was fully reverted,
confirmed via a clean `git diff`), on the same two real assets as slice
1 (`IMG_6564.jpeg`, `DSC_1665.NEF`), via a hand-authored sidecar JSON
(no UI exists yet to create masks through). Masks-off baselines were
re-measured on each asset immediately before/after for a clean delta,
then both sidecars were restored byte-for-byte to their pre-session
state.

| Case | Proxy frames | Full-res frames |
|---|---|---|
| JPEG, masks off | ~0.32–0.4ms | ~0.37–0.42ms |
| JPEG, 3 masks + Clarity | ~5.1–6.6ms | ~3.6–8.3ms |
| RAW, masks off | ~0.4–1.7ms (proxy rarely engaged) | ~0.4–1.7ms |
| RAW, 3 masks + Clarity | proxy did not engage under this drag cadence | ~15–21ms |

**JPEG stays comfortably under the 16ms/60fps budget at every frame
type.** **RAW does not** — full-resolution frames measured 15–21ms,
at/slightly over budget, a real and substantial cost (~14–19ms
attributable to the 3 masks) that slice 1's own single-trivial-param
probe did not anticipate, confirming the roadmap's own predicted risk
class rather than a false alarm. Root cause: each mask's Clarity pays a
full-image `CIUnsharpMask` pass; the ROI-cropping optimization above
narrows the ACTUAL rendered region to each mask's own bounding box, but
RAW's already-heavy per-frame baseline (even served from
`RawDecoder.materialize`'s cached buffer) means 3 such passes still add
up materially. A secondary, orthogonal finding along the way: P2's
interactive proxy essentially never engaged for RAW under this
measurement's synthetic drag cadence (every captured RAW frame was
full-resolution, vs. JPEG's clean proxy/full-res split) — likely because
RAW's own heavier per-frame cost means the settle timer fires between
sparse frames before two CONSECUTIVE changed draws land, though this
wasn't root-caused further since it's outside this task's scope.

**Accepted as a known, documented finding for this slice, not a
blocker**: masks are not yet reachable from any UI, so this cost is
theoretical until Session B ships; revisit with a targeted mitigation
(e.g. skip Clarity specifically on the interactive RAW path, or apply
the same ROI-narrowing more aggressively) if it proves to matter once a
real UI exists and RAW users can actually create multiple Clarity masks
in practice.

631 tests (166 new — `RadialMaskGeometryTests` new file, a new mask
section in `EditPipelineTests`, plus additions across `EditStateCodableTests`/
`EditStateComparisonOriginalTests`/`EditStatePresetTests`/
`EditStateRawRedecodeTests`/`EditHistoryTests`). The mask math is almost
entirely EQUIVALENCE-tested — a full-frame-covering mask's output
compared directly against the identically-valued GLOBAL slider's output,
rather than hand-derived magic numbers — a stronger, self-verifying
guarantee that needs no external probe to calibrate; real measured
numbers are reserved for genuinely spatial claims this file's own
convention already treats that way (soft-edge falloff, rotation swap,
the y-down convention, the crop-relative center), each confirmed via a
temporary standalone Swift probe mirroring `applyMasks`' exact filter
chain before being written into the permanent test as fixed values.

**Next step (superseded — see the Session B section immediately below,
which shipped this)**: ~~Phase 7 slice 2's UI half...~~

## Phase 7 slice 2 (Mask data model + Radial mask, UI half — "Session B")
## — ✅ COMPLETE (2026-09-09)

Scoped per Plan Mode (plan file `crystalline-sauteeing-dragon.md`, built
entirely from Session A's own already-completed research — no new
research needed, per that plan's own framing). All line numbers in the
plan were re-verified fresh against the current `ContentView.swift`/
`AdjustTabView.swift` before writing any code, since D8 (keyboard paths
for WB/Red-Eye/pan) landed after Session A's original research and
rewrote large parts of both files.

**What shipped**: five new files plus targeted edits to
`AdjustTabView.swift`/`ContentView.swift`.

`Sources/UI/MaskGeometry.swift` — pure, `CoreGraphics`-only UI-side
geometry, the explicit INVERSE sibling `RadialMaskGeometry.swift`'s own
doc comment reserved for this session (screen-drag math, not the forward
render transform). `axes(rotationDegrees:)` returns the ellipse's local
X/Y unit vectors in y-DOWN screen space for `Mask.rotationDegrees`'
clockwise-on-screen convention — deliberately does NOT negate the angle
the way `RadialMaskGeometry.resolve` must (that negation exists only to
cross into `CIImage`'s y-UP space). `handlePoint` maps a handle to its
on-screen point; `resized` projects a drag's translation onto the
handle's own rotated axis to grow/shrink ONE radius, symmetric about a
stationary center; `movedCenter` clamps center X/Y to `0...1` while
deliberately NOT clamping the radii (a mask overhanging the image edge
is normal, unlike Crop). 22 tests in
`Tests/EditEngineTests/MaskGeometryTests.swift`, including a cross-check
test hand-verified by the reviewer to numerically agree with
`RadialMaskGeometry.resolve`'s own transform after accounting for the
y-flip (at 37° rotation, extent 300×200: both sides give `(179.90,
105.14)`).

`Sources/UI/MaskBinding.swift` — `Binding<EditState>.mask(id:) ->
Binding<Mask>?`, resolving by IDENTITY on every access (never a captured
array index, since deletion shifts every later index). The setter
silently no-ops if the mask was deleted mid-drag; reviewer-verified the
getter/setter close over the parent binding so `wrappedValue` is always
read live, not a stale snapshot.

`Sources/UI/MaskDetailView.swift` — a top-level `struct` (NOT a computed
property inside the already-large `AdjustTabView`, which has two
existing doc comments warning about a real, already-hit type-checker
blow-up from over-packed `@ViewBuilder` closures). 14 `EditSliderRow`s in
three groups (tone: Exposure/Contrast/Highlights/Shadows; color:
Clarity/Saturation/Temperature/Tint; shape: Center X/Y/Radius X/Y/
Rotation/Feather) for the selected mask's full parameter set. These 14
rows ARE the accessibility answer for `MaskOverlayView` being
`.accessibilityHidden(true)` — the same reasoning `CropOverlayView`
already established: every value the overlay lets you drag is
independently AT-adjustable here.

`Sources/UI/MaskOverlayView.swift` — renders in the PARENT's coordinate
space (like `EditorCrosshairOverlay`), NOT self-framed to `fitRect` (unlike
`CropOverlayView`) — a mask's ellipse can legitimately extend past the
image edge, and a child positioned outside its own parent's frame
wouldn't reliably receive hit-tests. 4 resize handles (one per radius,
symmetric about a stationary center — not Crop's opposite-corner
anchoring, since the data model is one center + two independent radii,
not four independent edges), an interior move region, and a dashed
feather guide reusing `RadialMaskGeometry.innerRadiusFraction(feather:)`
directly so it can never drift from what's actually solid. Rotation is
slider-only in v1 (no drag handle — no rotation-gesture precedent exists
anywhere in this app), but the 4 resize handles still sit on the ROTATED
ellipse via `MaskGeometry`, so a future rotation handle would be purely
additive. Snapshot-baseline drag (`@State private var start: (...)?`
seeded lazily in `onChanged`), the exact `CropOverlayView` pattern.

`AdjustTabView.swift` gained `isMasksSectionExpanded`/`selectedMaskID` on
`AdjustPanelState`, a new "Masks" `AdjustSectionContainer` between
Red-Eye and RAW, and `masksSection`/`maskListRows`/`maskRow`/`maskDetail`/
`addMask`/`select`/`delete` — the exact add/delete-list shape
`presetsSection` already established: `maskListRows` is a plain read-only
value `ForEach` over `document.editState.masks`, identical in spirit to
`presetsSection`'s own `ForEach(catalog.presets)` (a row only reads
`mask.id`/position, never writes). The write-back path lives one level
down, in `maskDetail`: only the SELECTED mask's sliders need a live
binding, obtained via `$document.editState.mask(id:)` (`MaskBinding.swift`)
rather than a plain value. `MaskDetailView(mask: binding).id(id)`
— the `.id(id)` is load-bearing: without it, switching the selected mask
while `EditSliderRow`'s own click-to-type `@State` is mid-edit could
write the typed value into the WRONG mask, since SwiftUI would reuse the
same view identity across the switch.

`ContentView.swift` gained `isEditingMask` (resolved live against
`document.editState.masks` by ID — self-healing if Undo/Revert/
Apply-Preset deletes the selected mask without passing through any
disarm site), folded into `canZoom`'s existing gate, a new overlay
branch in `pointAndZoomOverlays`, and `handleMaskKeyPress` (Escape only).
The WB and Red-Eye arm buttons in `AdjustTabView` were each extended one
line to clear `selectedMaskID` — the same disarm-at-arm-site pattern
those two buttons already used on each other, now a three-way mutual
exclusion. Compare deliberately stays ENABLED with a mask selected (only
the overlay/detail panel clears, masks stay applied) — the best way to
SEE what a mask did.

**Reviewer (Opus 5): 2 rounds, FIX FIRST → APPROVE**, with all non-blocking
findings from round 2 fixed anyway before commit. Round 1 caught: no
non-finite guard on the overlay (a hand-edited/corrupt sidecar's NaN
would reach `.position()` directly — the render side's own
`RadialMaskGeometry.resolve` already guards this, this view didn't);
misleading/circular geometry-test comments and a missing cross-check
against the render-side transform; no-op writes firing on a
click-without-movement and redundant dual-radius writes; "Add Radial
Mask" not disabled without a loaded photo; collapsing the Masks section
left a mode armed (fixed via a custom `Binding` that clears
`selectedMaskID` on collapse); a missing "Mask editing" accessibility
label; an unused `Handle: CaseIterable` conformance; a feather-threshold
magic number duplicating `RadialMaskGeometry.minimumFeather` instead of
reusing the constant directly — all fixed. Round 2 (after those fixes)
caught one real, previously-invisible bug: the shared
`onEnterPointPickingMode` callback (passed from `ContentView` into
`AdjustTabView`, used by WB/Red-Eye/Mask select actions to reset zoom/pan
and grab focus) only grabbed image-pane focus as a side effect of a
NEW `.onChange(of: adjustPanel.selectedMaskID)` — but clicking an
ALREADY-selected "Mask N" row doesn't change `selectedMaskID` at all, so
that rising-edge-only focus grab would never fire, leaving Escape
unreachable if focus had drifted elsewhere (e.g. after typing in a
slider's text field). Fixed by making `onEnterPointPickingMode` itself
grab focus unconditionally, not as a side effect of the ID changing.
Also fixed: two sequential writes through `@Binding var panel` merged
into one (`var next = panel; ...; panel = next`); the duplicate-UUID
hand-off note (from `Mask.swift`'s own doc comment) re-confirmed still
narrow/accepted since `addMask()` never creates ID-less masks; two more
test-comment overclaim fixes (the `.plusX`-only cross-check needed an
explanation for why `.plusY` isn't also directly asserted — the y-flip
reverses handedness; an "must not leak into radiusY" test assertion
was structural, not empirical evidence).

653 tests (22 new, all in `MaskGeometryTests` — every other new file in
this session is SwiftUI interaction glue with no unit-test precedent
anywhere in this codebase, matching its own established convention that
pure geometry gets unit tests while gesture composition gets live
verification).

**Live-verified (2026-09-09)**, with permission asked and granted via
AskUserQuestion before any screen automation, against the user's real
Bolivia-trip library (`IMG_6564.jpeg`, the group-jump/sky photo, and a
portrait car-interior JPEG, both real assets — not synthetic fixtures):
- Added multiple masks; confirmed only the currently-selected one draws
  handles, matching the v1 design (unselected masks still apply their
  effect, just show no overlay).
- Dragged all 4 resize handles at rotation 0 on a LANDSCAPE image:
  confirmed symmetric resize about a stationary center, matching the
  design (not Crop's opposite-corner anchoring).
- Set Rotation to +30° with unequal radii (a circle would hide any
  rotation bug) and confirmed the drawn outline, the RENDERED soft
  ellipse, and all 4 handles rotate together in the same direction,
  each handle staying exactly on the rotated outline.
- Repeated both the resize and the rotation test on a PORTRAIT photo
  (a non-square `fitRect`, the case that would catch a scale/rotate-
  ordering bug) — both confirmed correct.
- Dragged the interior toward an edge and confirmed Center X clamps at
  0% while the ellipse is free to overhang the image (the opposite of
  Crop's own interior-drag double-bounding).
- Swept Feather to ~90% and confirmed the dashed guide visibly shrank
  toward the center, tracking the actually-solid region.
- Dragged a handle then pressed ⌘Z once: confirmed the WHOLE drag
  undoes as a single step, not one frame of it.
- Typed into Mask 2's Exposure field without pressing Return, then
  clicked Mask 1's row: confirmed Mask 1 showed `+0.00 EV` (no
  cross-mask leak) and Mask 2 ALSO showed `+0.00 EV` when re-selected
  (the uncommitted value was correctly discarded, not silently
  committed) — the `.id(id)` view-identity fix and the click-to-type
  seed-comparison discard (Post-Phase-5 follow-up #8's own precedent)
  both hold under masks.
- Confirmed switching to Crop disarms an active mask selection
  (overlay disappears); confirmed arming the WB eyedropper does the
  same.
- Confirmed mask selection SURVIVES a Library round-trip (by design —
  only Crop/WB/Red-Eye/Compare/photo-switch/tab-switch clear it,
  per the plan's own enumerated disarm-site table) and that Escape
  still reaches and deselects it after returning, re-enabling zoom.
- Used Compare → Split on a masked photo and dragged the divider:
  confirmed the "before" side shows zero mask effect (a normal-toned
  headrest) while the "after" side shows the mask's +4 EV brightening
  clearly confined to where the ellipse was, and that toggling Compare
  off leaves the "after" (edited) state in place — direct visual proof
  `comparisonOriginal()`'s existing mask-clearing (Session A) still
  works correctly through the new UI.
- Used Revert to Original on both test photos and confirmed a clean
  return to "No masks yet" with normal exposure, leaving neither photo
  with leftover test edits.

**Not independently live-exercised this session** (accepted on
code-review strength / symmetry instead, not skipped by oversight):
literally-concurrent delete-during-drag (a single physical input device
cannot drive two simultaneous mouse-downs, so this remains covered by
the reviewed `MaskBinding` setter guard rather than a literal repro);
Red-Eye's own arm-button disarm specifically (an identical one-line diff
to the WB button, which WAS live-verified, and the automation session
ran low on time before reaching it); a JPEG export round-trip through a
masked photo (Session A's own research already confirmed export/Library-
thumbnail/Revert-enablement/P2-P3-caches all flow `masks` through as a
plain `EditState` field with no code path needing changes).

**Deferred, logged in `IMPROVEMENTS.md` as D9, not an oversight**:
arrow-key nudge/resize of the on-image mask overlay itself. The 14
`MaskDetailView` sliders already give a full keyboard/AT path to every
value the overlay can set, so this is an ergonomics follow-up, not a
closed accessibility gap.

Both test photos' sidecars were reverted to identity (via the app's own
Revert to Original) before this commit — the user's photo library is
unchanged by this session's live verification.

**Phase 7 slice 2 is now fully complete** (both the data-model/pipeline
half and the UI half).

## Phase 7 slice 3 — Linear (Graduated) mask, Session A (data model,
## geometry, pipeline, sliders) — ✅ COMPLETE (2026-09-10)

Scoped per Plan Mode: a second mask geometry — a graduated band, like
Lightroom's graduated filter — extending the SAME `Mask` struct (per its
own doc comment reserving exactly this: "slices 3-6 will add new
geometry variants... to THIS struct") rather than a new type or an
enum-with-associated-values, which would have broken the flat
`CodingKeys` list and `deterministicFallbackID`'s fixed-arity signature.
Split into Session A (this one — data model, render geometry, pipeline
branch, full slider control) and a future Session B (the on-image
line-drag gesture CLAUDE.md's roadmap calls "genuinely new"), with the
seam placed one step LATER than slice 2's own A/B split: a selected
Linear mask is already fully usable via sliders after this session
(create it, position/rotate/widen it, see it render), not a UI-dark
increment verified only via a hand-authored sidecar.

**What shipped**: new `MaskKind: String, Codable, CaseIterable { case
radial, linear }` plus two new `Mask` fields — `kind: MaskKind = .radial`
and `width: Double = 0.3` (`.linear`-only: the FULL guide-to-guide
distance, a fraction of `min(extent.width, extent.height)`, matching
Definition/Sharpen's own non-axis-specific radius-scaling precedent for
the same reason — constant on-screen thickness as the angle sweeps).
`rotationDegrees` (already existed) is REUSED, not duplicated, as the
angle field for both kinds — for `.linear` it's the line's own
orientation, CW-positive on screen, same convention/negation-rule as the
ellipse's rotation — keeping ONE rotation sign rule in this struct
instead of two. `centerX`/`centerY` are reused unchanged as the anchor
point too, so the entire center-drag UI interaction (Session B, later)
will need zero new code for that piece.

New `Sources/EditEngine/LinearMaskGeometry.swift` — pure `CoreGraphics`
sibling of `RadialMaskGeometry.swift`, feeding `CIFilter.linearGradient()`
directly. **The y-flip/rotation-sign math was the highest-risk part of
this slice, given this codebase's own documented history here (the
Metal y-flip, the Compare-split inversion)**, and the reviewer caught a
real error in the FIRST draft's own justification for it (not in the
shipped math, which was already correct): the draft claimed
`RadialMaskGeometry`'s "negate the whole stored angle before building a
rotation matrix" trick is mathematically WRONG for a bare direction
vector like this file's two guide points. Independently re-derived by
the reviewer (and re-checked here): that claim is FALSE — negating the
angle and applying the standard rotation formula to the correspondingly
y-flipped base vector produces BYTE-IDENTICAL points to this file's
per-point-flip approach; the two formulations are equivalent, not in
tension. `LinearMaskGeometry.resolve` still flips each of the two guide
POINTS individually (the identical `1 - y` formula the existing
center-mapping already uses) rather than negating the angle, but purely
so this file has ONE flip idiom instead of mixing it with an
angle-negation idiom for the same quantity — a clarity choice, not a
fix for a hazard that turned out not to exist. Hand-verified compass
checks (0°, 90°, 45°, 180°) became the FIRST tests written, before the
implementation existed (red, then green) — including a regression test
asserting that substituting the naive "just negate the angle, reuse
this SAME per-point formula" mistake (a different, genuinely wrong
shortcut than the equivalent-matrix approach above) produces a
different, mirrored point at a non-axis-aligned angle.

A width too small to matter is CLAMPED to a new
`LinearMaskGeometry.minimumWidth`, not treated as `nil` the way a
sub-half-pixel radial radius is — deliberate divergence: a zero-width
linear mask is a legitimate hard-edged half-plane split (a real,
deliberate look covering roughly half the frame), not "no mask," unlike
a zero-radius ellipse which truly covers nothing. **Reviewer-caught bug
in the first draft**: the clamp was applied to the FRACTIONAL `width`
input, not the resulting PIXEL half-width, so on any extent whose
smaller dimension was under ~100px (e.g. a Library thumbnail, capped at
240px) the pixel half-width still fell under the 0.5px sub-pixel floor
and `resolve` returned `nil` anyway — silently dropping the whole mask
in the Library grid while it still rendered in the Editor, the same
Editor/thumbnail-divergence defect class as post-Phase-5 follow-up #4.
Fixed by clamping the pixel half-width directly (`max(halfWidthPixels,
0.5)`), with a new small-extent test pinning it. `Resolved` also
carries a `regionOfInterest: CGRect` — a genuine analytic half-plane
clip of the extent (a hand-rolled single-edge Sutherland-Hodgman
polygon clip, not a hand-rolled axis-aligned band rect, which would
incorrectly clip the far corner on the opaque side at a diagonal angle)
— the linear analogue of Radial's own ROI-cropping optimization in
`applyMasks`. Reviewer-caught along the way: the polygon-clip helper had
the only three force-unwraps (`.min()!`/`.max()!`) in this entire
codebase's `Sources/` tree, against CLAUDE.md's own no-force-unwrap
convention — replaced with a manual reduce; and the "clip produced no
points" fallback (the mask has literally zero effect anywhere in the
extent) returned the FULL extent as the "region of interest," which is
safe but pays the exact per-frame cost this optimization exists to
avoid in precisely the case where the mask does nothing — now returns a
zero-size rect instead, plus a `.isFinite` guard on every computed
point so a pathological hand-authored sidecar can't propagate a `NaN`
region into `corrected.cropped(to:)`.

**Measured, not assumed, before writing the pipeline branch**: a
throwaway probe (deleted before commit, same discipline as every prior
slice's live-measurement probes) confirmed `CIFilter.linearGradient()`'s
`outputImage.extent` is `CGRect.infinite` (a linear gradient has no
natural bounding box, unlike a radial gradient's disc) and that it
CLAMPS to `color0`/`color1` beyond each point rather than being
undefined there — this is why the `.linear` branch in
`EditPipeline.applyMasks` needs no transparent-`base`/
`CIMaximumCompositing` union step the `.radial` branch requires (a
radial gradient IS undefined outside its own bounding disc, which is
exactly what that union fixes).

`EditPipeline.applyMasks`'s single `RadialMaskGeometry.resolve` call
became a `switch mask.kind` producing a local `ResolvedMaskGeometry`
enum, still `continue`-ing past a degenerate mask BEFORE the color/tone
work runs (the pre-existing early-exit ordering, unchanged) — every line
from the clamps through the final `CIBlendWithMask` composite stayed
untouched and kind-agnostic; only the geometry resolve and the
gradient-image construction are kind-dispatched. `masksActive` and the
pipeline's overall stage order (Red-Eye → applyMasks → Vignette) needed
no changes.

**Highest-severity fix in this slice**: `MaskKind` is a `String`-raw-value
enum, and `decodeIfPresent(MaskKind.self, forKey:)` THROWS on an
unrecognized-but-PRESENT raw value (it only returns `nil` for an ABSENT
key). Both this app's sidecar readers wrap the WHOLE `EditState` decode
in `try?` — so a future slice's unrecognized kind string (a hypothetical
`"brush"`) would have silently discarded the ENTIRE sidecar, every
global edit on the photo included, not just the one mask. Fixed by
decoding the raw `String` by hand and mapping it with a `.radial`
fallback for anything unrecognized — a new test
(`testUnknownMaskKindDecodesToRadialWithoutDiscardingTheSidecar`) proves
this by asserting a NON-DEFAULT GLOBAL field survives a decode alongside
an unrecognized mask kind, not just that decode doesn't throw.
`deterministicFallbackID` (the id-less-mask fallback hash) now mixes in
`kind` too, via a hardcoded per-case `UInt64` seed (NOT `.hashValue`,
which is per-process randomized) — omitting this would let a default
id-less `.radial` mask and a default id-less `.linear` mask collide on
the same id despite being visibly different masks, unlike the
already-accepted collision case of two field-identical (hence visually
identical) masks.

`MaskDetailView`'s `shapeRows` split into a kind-`switch` (`
radialShapeRows` unchanged; new `linearShapeRows`: shared Center X/Y,
"Angle" `-180...180` — NOT the ellipse's `-90...90`, since a line has no
180° symmetry (rotating it 180° swaps WHICH SIDE gets the effect,
unlike an ellipse), "Width" `0...1`). `AdjustTabView`'s single "Add
Radial Mask" button became two side-by-side buttons ("Add Radial" / "Add
Linear," each with its own `.accessibilityLabel`) — introducing a second
kind is exactly the moment discoverability matters more than a compact
menu. `maskRow`'s label/icon vary by kind (`circle.dashed` vs
`line.diagonal`), but numbering stays GLOBAL across both kinds, not
per-kind — masks composite sequentially in array order, so per-kind
counters would visibly disagree with compositing order the moment a
Radial and a Linear mask overlap. `ContentView.swift`'s on-image overlay
instantiation gained exactly one line (`maskBinding.wrappedValue.kind ==
.radial`) — verified by reading each site, not assumed, that
`isEditingMask`/`handleMaskKeyPress`/every `.onChange` disarm site are
already kind-agnostic, so a selected Linear mask still grabs focus and
still deselects on Escape; it just draws no handles yet. **`canZoom` is
the one exception, reviewer-caught**: the first draft left it gated on
the same kind-agnostic `isEditingMask`, which meant selecting a Linear
mask blocked zoom for NO reason — that gate's own documented rationale
("their overlays are positioned against `currentFitRect` assuming no
zoom/pan") doesn't apply to a kind with no overlay at all, and Escape
was the only (undiscoverable) way out. Fixed with a new, narrower
`isEditingRadialMask` used ONLY by `canZoom`, leaving `isEditingMask`
itself unchanged for every other (correctly kind-agnostic) call site.

Reviewer (Opus 5): 2 rounds, FIX FIRST → APPROVE. Round 1 caught the two
correctness bugs already folded into this section above (the width-clamp
targeting the wrong quantity; `canZoom` blocking zoom for a kind with no
overlay) plus three documentation-only issues: the false "angle-negation
is wrong for a direction vector" claim (also already corrected above,
and independently in CLAUDE.md's own slice-3 entry); the `applyMasks`
doc-comment merge (the new `ResolvedMaskGeometry` enum's doc had been
appended to the END of the pre-existing ~100-line `applyMasks` doc with
no separating blank line, leaving `applyMasks` itself with no doc
comment at all, and the merged block's stale opening line still read
"Radial (ellipse) local adjustments — Phase 7 slice 2" — fixed by moving
the enum's doc above the block and retitling the block's own opening
line to name both kinds); and the only three force-unwraps in this
codebase's entire `Sources/` tree (`clippedRegionOfInterest`'s
`.min()!`/`.max()!`), against CLAUDE.md's own explicit no-force-unwrap
convention — replaced with a manual reduce. Also flagged, fixed as
"should-fix" rather than blocking: `Mask.init(from:)`'s `kind` decode
still threw on a TYPE mismatch (e.g. a hand-authored `"kind": 2`), not
just an unrecognized-but-well-typed string — the exact class of hazard
the fix was supposed to close, from a different malformed input;
widened to `try?` so it's unconditional. `clippedRegionOfInterest`'s
"clip produced nothing" fallback returned the full `extent` (safe, but
paying the ROI-optimization's own avoided cost in exactly the case
where the mask does nothing) — now returns a zero-size rect, with an
added `.isFinite` guard on every computed point so a pathological
sidecar can't propagate `NaN` into the final crop. **Round 2 (re-run on
the fixed diff): FIX FIRST again** — every code-level fix from round 1
verified genuinely correct (independently re-derived the rotation math,
probed `CIBlendWithMask`'s actual behavior with an empty foreground
image, probed `try?`'s actual suppression of a JSON type-mismatch
`DecodingError`), but three of round 1's own DOCUMENTATION fixes were
incomplete: the same disproven "angle-negation is wrong for a direction
vector" claim survived verbatim in `Mask.swift`'s own `rotationDegrees`
doc comment and in `LinearMaskGeometryTests.swift`'s file header (both
outside the one file round 1's fix actually touched); and a NEW
`ContentView.swift` comment introduced BY the `canZoom` fix directly
contradicted that same fix ("isEditingMask/canZoom/... are all already
kind-agnostic... a selected Linear mask still blocks zoom" — false the
moment `canZoom` became `.radial`-only). Round 2 also caught one genuine
NEW behavioral regression introduced by the `canZoom` fix itself:
`handleImagePaneKeyPress` unconditionally routed every key press to
`handleMaskKeyPress` whenever ANY mask was selected, which used to be
harmless (a selected mask always forced `canZoom == false` before this
slice, so the pan branch below it was already unreachable) but now
silently broke arrow-key panning for a selected `.linear` mask, which
`canZoom` deliberately keeps enabled. Fixed by only short-circuiting on
Escape (`handleMaskKeyPress`'s only real case), falling through to the
pan branch otherwise. All three stale-doc-comment sites corrected to
match the file `LinearMaskGeometry.swift` already had right; a small
`widthInPixels`/`resolve` inconsistency the round-1 fix introduced (the
0.5px floor lived a second time in `resolve` instead of solely inside
`widthInPixels`, the function documented as this value's single source
of truth) was folded into `widthInPixels` itself; the unused
`MaskKind: CaseIterable` conformance (a repeat of a nit slice 2's own
reviewer already raised once) was dropped; and a new
`testMaskKindWithWrongJSONTypeDecodesToRadialWithoutDiscardingTheSidecar`
test was added to directly exercise the JSON-type-mismatch case that
motivated the `try?` fix (the existing test only covered an
unrecognized-but-well-typed string). Re-reviewed after all of the above:
**APPROVE**.

701 tests (48 new): `LinearMaskGeometryTests` (23, following the exact
section structure and rigor of `RadialMaskGeometryTests` — hand-derived
closed-form values, not probed constants, for every y-flip/rotation/
width claim), 20 new cases in `EditPipelineTests` (equivalence against
the identically-valued GLOBAL slider for every adjustment param, the
0°/90°/180° sign checks, the width-0-vs-width-1 steepness comparison, the
diagonal-angle far-corner-not-clipped regression, and a radial+linear
same-array compounding test), and 5 new cases in `EditStateCodableTests`
(kind/width defaulting, the unknown-kind-string and wrong-JSON-type
whole-sidecar-survival proofs, and the cross-kind deterministic-id pair).

**Live-verified (2026-09-10)** against the user's real Bolivia-trip
library (`IMG_6564.jpeg`, the same group-jump/sky photo Session B used,
plus a quick portrait photo for the non-square-extent case): added a
Linear mask, set Exposure to +3 EV, and confirmed the sky (top half)
brightened while the ground (bottom half) stayed untouched at the
default Angle 0° — the single most important real-app check in this
slice; swept Angle to +90° and confirmed the effect moved to the RIGHT
half with the left untouched, matching the geometry's own predicted
compass direction exactly; swept Angle to +180° and confirmed an EXACT
swap from the 0° case (now the ground brightens, the sky doesn't),
proving `-180...180` is real travel, not duplicate travel the way the
ellipse's own `-90...90` deliberately is; swept Width from 0% (a clean
hard edge, no rendering artifacts, no crash) to 100% (a visibly more
gradual ramp); created a Linear mask on a non-square, letterboxed
portrait photo with no crash or visible distortion; used Revert to
Original on both test photos afterward, confirming a clean return to
"No masks yet." **Required RAW perf re-check** (this exact re-measurement
was the condition slice 2's own write-up set for revisiting once masks
were reachable): rather than fight this session's flaky screen-automation
environment for a UI-driven measurement, used a temporary, non-interactive
XCTest probe (same "measure directly, delete before commit" discipline,
just via `@testable import PhotoApp` instead of synthetic UI events) that
loaded the user's real `DSC_1665.NEF` (6016×4016) via `RawDecoder.decode`/
`.materialize`, then timed `EditPipeline.apply` + a forced `CIContext`
render across repeated iterations: baseline (no mask) converged to
~7.2ms/frame; one Linear mask with Clarity active converged to
~7.8-8.2ms/frame — a ~0.6-1.0ms delta, comfortably under the 16ms/60fps
budget and consistent with slice 1's own single-Radial-mask-probe
numbers. Probe deleted before commit, confirmed via a clean `git diff`.

**Not independently live-exercised this session** (lower-risk items
covered by the automated test suite's equivalence/structural tests
instead, given this session's unusually disruptive automation
environment): a mixed Radial+Linear same-photo compounding render (covered
by `testRadialAndLinearMasksCompoundSequentiallyInTheSameArray`); Compare
→ Split specifically on a Linear-masked photo (covered by slice 2's own
already-verified masks-in-general Compare behavior, which is kind-agnostic
by construction — `comparisonOriginal()` clears `masks` as a whole array,
not per-kind).

## Phase 7 slice 3 — Linear (Graduated) mask, Session B (on-image
line-drag gesture) — 2026-09-10/11

Ships the piece Session A's own write-up deferred: a draggable center
line (moves the mask, reusing `MaskGeometry.movedCenter` VERBATIM — no
new function) and two draggable parallel guide handles (resize `width`
symmetrically about the stationary center) — the mirror image of the
Radial mask's own `MaskOverlayView` (slice 2 Session B), reusing its
established conventions line-for-line where the different geometry
allows: snapshot-baseline drag, parent-coordinate-space rendering,
value-changed write guards so a bare click doesn't fire a phantom
sidecar save, `.accessibilityHidden(true)` licensed by
`MaskDetailView`'s already-shipped 12 Linear-mask slider rows.

New pure math in `Sources/UI/MaskGeometry.swift` (`minWidth`/`maxWidth`,
`LinearHandle`, `linearGuidePoint`, `resizedWidth`, plus
`guideLineLength` added later — see below): `linearGuidePoint` is
re-derived from `LinearMaskGeometry.resolve`'s own render-side formula by
converting its `point0`/`point1` back through the same y-flip the
center mapping already uses, landing on `center ∓
axes(rotationDegrees).y · halfWidthPoints` — the SAME rotated-axis
formula `handlePoint` already uses for the ellipse, just offset along
`yAxis` only. `halfWidthPoints` comes from calling the EXISTING
render-side `LinearMaskGeometry.widthInPixels(width:extent:)` directly
with `fitRect` standing in for `extent` — valid because that function
is a pure fraction-of-`min(width,height)` scaling and `AspectFit`
preserves the ratio between `fitRect` and the real render extent, so the
drawn guide can never drift from the render's own `minimumWidth` clamp.
`resizedWidth` projects a drag's translation onto the rotated
perpendicular axis, divides by `min(fitRect.width, fitRect.height)`, and
DOUBLES the result — `width` is the FULL guide-to-guide distance while
each handle sits only HALF that from a stationary center, so moving one
guide out by `d` grows `width` by `2d`. New
`Sources/UI/LinearMaskOverlayView.swift` draws three parallel lines
(solid center, two dashed guides reusing the Radial feather guide's own
"dashed = falloff boundary" visual language) plus an invisible ~44pt
rotated drag band along the center line (there's no enclosed "interior"
the way an ellipse has one) and two 30×30 circular handles.
`ContentView.swift`'s overlay-instantiation site became a
`switch maskBinding.wrappedValue.kind`; `isEditingRadialMask` (a
Session-A-introduced, Linear-had-no-overlay-yet carve-out) was deleted
entirely and `canZoom` reverted to the simpler, kind-agnostic
`isEditingMask` gate now that both kinds have their own
`currentFitRect`-positioned overlay. `MaskDetailView`'s Width row now
cites `MaskGeometry.minWidth...MaskGeometry.maxWidth` instead of a
`0...1` literal, matching Radius X/Y's own precedent.

**Reviewer (Opus 5): 6 full rounds — by far the most of any Phase 7
slice** — FIX FIRST ×2 (rounds 1-2, both genuine SwiftUI-layout bugs
invisible to unit tests) → APPROVE (round 3) → FIX FIRST (round 3 itself
flagged a documentation-accuracy bug in my own IMPROVEMENTS.md entry,
treated as blocking) → FIX FIRST (round 5, on my own post-approval
polish) → APPROVE (round 6). Detail:
- **Round 1, BLOCKING**: a bare, literal `Path` (fixed absolute
  coordinates) conforms to `Shape` via a trivial
  `path(in _: CGRect) -> Path { self }` that IGNORES whatever rect
  layout gives it — so with no `.frame()` at all, the view took on the
  full PROPOSED size of the parent overlay (effectively the whole image
  pane), and `.position(center)` placed the line off-frame entirely.
  Caught by the reviewer ACTUALLY RENDERING the view (not just reading
  the code) and measuring — this session's methodology shift, see below.
  Fixed with a real `Shape`-conforming `HorizontalLine` type
  (`path(in rect:)` genuinely uses `rect`) plus an explicit
  `.frame(width: lineLength, height: 3)` before rotation/position.
- **Round 2, BLOCKING**: `lineLength`'s original `hypot(...) * 1.5`
  multiplier was too short — measured live via rendering to visibly
  terminate mid-image for any `centerX` outside roughly `[0.1, 0.9]` at
  rotation 0. Fixed to `* 3.0`, with a derivation proving sufficiency:
  required half-length is `D + 0.5·min(w,h)` (full diagonal for a corner
  anchor, plus a guide's own offset), and `1.5·D` already covers that
  since `D ≥ min(w,h)` always — so `3·D` (twice that sufficient
  half-length) has margin to spare. Verified correct by round 3 via a
  750-config empirical re-render sweep plus a negative control
  reproducing the old bug in the same harness.
- **Round 3, non-blocking → became blocking on inspection**: a
  `resizedWidth` doc comment understated the `width≈0` dead-zone
  magnitude as "~1-2pt" without deriving it; the actual floor is
  `LinearMaskGeometry.minimumWidth (0.01) · min(fitRect.width,
  fitRect.height) / 2`, which SCALES with the pane (≈1.0pt at a 200pt
  minimum dimension, ≈3.0pt at 600pt, ≈6.0pt at 1200pt) — fixed with the
  correct formula and scaling examples. Also suggested (non-blocking,
  done anyway): extracting `lineLength` into a testable
  `MaskGeometry.guideLineLength(fitRect:)` with its own sufficiency-proof
  doc comment and two new unit tests. **The one genuinely BLOCKING
  round-3 finding**: my own `IMPROVEMENTS.md` "D10" entry (written after
  round 2 to log the `lineLength` investigation's side-discovery) claimed
  a `CompareDividerOverlay`-vs-mask-drag z-order conflict was "real and
  reachable today" — round 3 traced the actual code
  (`AdjustTabView.select(_:)` → `onEnterPointPickingMode()` sets
  `compareMode = .off`; `compareToolbarItem`'s own
  `.onChange(of: compareMode)` clears `selectedMaskID` whenever compare
  goes non-`.off`) and found the two states are already mutually
  exclusive by construction — the entry was factually wrong. Fixed by
  rewriting D10 as an honest "latent/currently-unreachable, matters only
  if the mutual-disarm logic is ever relaxed" note. A real lesson from
  this round: writing a "known issue" doc entry without tracing the
  actual code paths first can itself introduce the same class of error
  the review process exists to catch.
- **Round 4**: APPROVE — independently re-verified the D10 rewrite
  against the actual `AdjustTabView`/`ContentView` code, re-derived the
  `resizedWidth` dead-zone formula from `LinearMaskGeometry.minimumWidth`
  directly, and confirmed `guideLineLength`'s extraction was
  behavior-identical with no leftovers. Five NON-blocking notes,
  addressed anyway before commit rather than left open: (1) a
  now-adjacent comment near the Compare-divider overlay still cited a
  nonexistent "toolbar Menu `.disabled(...)`" as the reason masks can't
  overlap Compare's divider — the Menu genuinely doesn't gate on
  `isEditingMask`, only on WB/Red-Eye; (2) the new `guideLineLength`
  negative-control test re-derived its bound inline instead of calling
  the shipped function, weakening its own discriminating power; (3) a
  stale doc-comment mention of the deleted `isEditingRadialMask` symbol;
  (4) a live-verification gap flagged for the next step (dragging the
  center line at ~45° specifically, since the drag gesture attaches
  OUTSIDE the `.rotationEffect`/`.position` modifiers, the same shape the
  shipped Radial `MaskOverlayView` already uses but which CLAUDE.md notes
  was only ever live-verified at rotation 0 for that view too); (5) this
  PROGRESS.md section not existing yet (expected — doc/commit is its own
  separate step in this project's convention, not a diff defect).
- **Round 5, on my own post-approval polish attempting to fix findings
  1-3 above**: FIX FIRST — ironically, two of the three fixes themselves
  introduced NEW factual errors of the same kind they were meant to
  remove. The Compare-divider comment rewrite over-corrected, now falsely
  claiming the Menu "doesn't gate on [WB/Red-Eye] at all" (it does — the
  round-4 note was narrowly about masks, not WB/Red-Eye) and pointed a
  "below" reference at an `.onChange(of: compareMode)` site that was
  actually above it (and the wrong one of two candidates). The
  `guideLineLength` test hardening also went from ONE inline copy of the
  sufficiency-bound formula to TWO, directly contradicting its own new
  doc comment claiming otherwise, and included a redundant assertion.
  Also caught: both edits were sitting unstaged, not staged — a plain
  commit at that point would have shipped the pre-fix wording. Fixed by
  correctly scoping the Menu-gate claim to WB/Red-Eye specifically (masks
  are the one exclusion NOT covered by it), naming `compareToolbarItem`
  explicitly instead of a dangling "below", and factoring the
  sufficiency-bound formula into one shared `requiredHalfLength(for:)`
  test helper both `guideLineLength` tests call, so the bound has a
  single source of truth.
- **Round 6**: APPROVE — independently re-traced the Menu's `.disabled`
  modifier, confirmed `compareToolbarItem` is genuinely the one holding
  the mask-clearing `.onChange`, and confirmed the test file's shared
  `requiredHalfLength` helper eliminated the duplication. One optional,
  non-blocking wording nit (`guideLineLength`'s own doc comment
  conflated "twice the sufficient half-length" with "twice the required
  half-length" — the math was right, only the phrasing was loose) fixed
  before commit.
- **Reviewer methodology note, carried forward from this slice**:
  starting in round 1, the reviewer began ACTUALLY RENDERING the SwiftUI
  view code (not just reading it) — sampling along expected lines,
  measuring coverage — which is what caught both blocking bugs; neither
  was visible to unit tests, since `MaskGeometry`'s own pure math was
  correct in both cases. Reinforces this codebase's established
  "geometry gets tests, gesture/view composition gets live/rendered
  verification" convention.

717 tests (16 new: 14 for `linearGuidePoint`/`resizedWidth` — including
the render-side y-flip cross-check and a translation round-trip test
that doesn't depend on knowing the doubling multiplier in advance — plus
2 for `guideLineLength`'s sufficiency bound and its negative control).

**Live-verified (2026-09-11/12), all 11 points passed, zero code changes
needed.** Driven via `cliclick`/`osascript` screen automation (explicit
per-session permission granted) against a real build, on two real
assets — `viscuna.jpg` (landscape) and `IMG_5160.HEIC` (portrait) — plus
a second Radial mask added alongside the Linear one for the
kind-selection/cross-mask checks:
1. Center-line drag: translated with angle/width unchanged (confirmed
   both visually — three parallel guide lines shifted together, equal
   spacing preserved — and numerically: Center Y moved 50%→17%, Angle
   and Width untouched); the Exposure effect (set to -4.35 EV for
   visibility) moved with it.
2. Guide-handle drag at 0°: the far guide mirrored symmetrically about a
   stationary Center Y (confirmed numerically: Width 0%→70%, Center Y/X
   unchanged); the rendered falloff boundary sat exactly on the dragged
   guide line, no visible gap.
3. Angle set to 45° (via the click-to-type numeric field, after an
   accidental slider-track click usefully demonstrated the same thing at
   160°): the whole three-line assembly rotated together and each handle
   stayed on its own rotated line.
4. Repeated 1–3 on the portrait photo (`IMG_5160.HEIC`, non-square
   `fitRect`) — identical behavior, both numerically and visually.
5. Center dragged to a frame edge: Center Y clamped at 0% while the
   dragged-past guide handle extended freely into the black letterboxed
   area above the image (confirmed a mid-test false alarm first: an
   earlier attempt grabbed a GUIDE handle instead of the center band by
   mistake, correctly clamping Width to 0% while leaving Center Y
   untouched — that's `resizedWidth`'s own floor working correctly, not
   a bug, and it's what motivated re-deriving `linearGuidePoint`'s exact
   on-screen position before re-attempting the real center-drag).
6. A full handle drag undid as one ⌘Z step (Center Y 0%→26% in one
   press, not incrementally).
7. Typed "-3.5" into Mask 1's Exposure field without pressing Enter,
   selected Mask 2, back to Mask 1: neither mask picked up the stray
   value — confirms the `.id(id)`-scoped `TextField` state and the
   seed-text-comparison write guard both still hold with two masks and a
   live overlay in the mix.
8. Zoom-blocked: **code-verified, not interactively confirmed** — a
   synthetic `CGEvent` scroll-wheel injection (`CGEvent
   (scrollWheelEvent2Source:...)`, tried with both `.pixel`/`.line` units
   and a continuous-phase flag) never triggered `ImageRenderer`'s local
   `NSEvent` monitor at all, with or without a mask selected, so the
   before/after comparison this checklist wanted couldn't be produced
   this way. Read `ContentView.swift`'s `canZoom` directly instead
   (`Sources/UI/ContentView.swift:98-101`) and confirmed it's exactly
   the reviewed, kind-agnostic `!isEditingMask` gate the round-1/round-2
   reviewer rounds landed on — no `.radial`-only carve-out survived.
   Genuine automation gap, not a functional doubt; a real trackpad/mouse
   scroll would settle it in seconds if this ever needs re-checking.
9. Crop, "Pick White Balance", "Fix Red-Eye", and Compare → Split all
   independently disarmed a selected Linear mask (overlay disappeared
   the instant each was armed) — all four checked individually, not
   just Crop as the earlier slices' precedent.
10. Selecting Mask 2 (Radial) showed only its ellipse+handles overlay;
    selecting Mask 1 (Linear) showed only its three-line overlay — never
    both, never neither.
11. Revert to Original cleared both masks back to "No masks yet" —
    cross-checked against the on-disk sidecar afterward
    (`IMG_5160.HEIC.photoapp.json`'s `masks` key is a genuinely empty
    array post-revert), not just the UI state.

**Automation-environment notes, worth knowing before the next
screen-automation session on this machine**: this Mac runs a HiDPI
scaled resolution — `cliclick`/AppleScript coordinates are in a
1440×900 logical space, while `screencapture` output is 2880×1800 (2×)
— get this backwards and every click silently lands off-target with no
error. `cliclick` has no scroll-wheel command; a small ad-hoc Swift
script posting `CGEvent(scrollWheelEvent2Source:...)` at
`.cghidEventTap` worked for scrolling the Adjust-tab sidebar (a normal
AppKit `NSScrollView`) but never worked for `ImageRenderer`'s local
scroll monitor (see point 8) — two different event-delivery paths, only
one reachable this way. Mid-session, the screen twice jumped to
something totally unrelated to PhotoApp (several hours of real time
appear to have elapsed between some consecutive tool calls, well beyond
this conversation's own turn-taking) — resolved both times by
re-querying `System Events` for actual window state rather than trusting
the last-known layout, and once by re-locating a test photo via its
on-disk `.photoapp.json` sidecar (`find ... -newermt ...`) rather than
guessing from a possibly-reflowed Library grid. No PhotoApp state was
lost or corrupted by this — the leftover test edits on `viscuna.jpg`
were cleaned up by deleting its sidecar afterward (no code path for
this; direct sidecar deletion is equivalent to "never edited" per this
app's own no-sidecar-means-original model).

**Phase 7 slice 3 (Linear/Graduated mask) is now fully complete** —
data model, pipeline, sliders, on-image drag gesture, and live
verification all shipped, zero open issues. Brush mask (slice 4) is
next on the roadmap.

## Phase 7 slice 4 (Brush mask) — PLAN MODE COMPLETE, implementation not
started (2026-09-12)

Full implementation plan written and approved-pending at
`~/.claude/plans/purrfect-giggling-tower.md` (Plan Mode file — persists
across sessions, not part of this repo). Two Explore agents (data model +
pipeline; UI overlays + gesture conventions) and one Plan agent produced
the design; the highest-risk claims (`Mask.swift`'s decode logic,
`EditPipeline.applyMasks`'s exact structure, and an existing test that
will need fixing) were independently re-verified by reading the real code,
not trusted from the agent reports alone.

**Key decisions locked in** (confirmed via `AskUserQuestion`, not
assumed): painting is **continuous drag-to-paint** (not click-to-place
dabs, not a new commit-boundary API) — reuses `ImageDocumentModel`'s
existing ~350ms undo-coalescing debounce as-is, accepting a documented gap
(a stroke paused >350ms mid-drag can split into two undo steps). One Brush
mask = one continuous stroke (flat `[BrushPoint]`, not nested per-stroke
arrays); paints a second area by adding another Brush mask (masks already
compound sequentially, for free). Reuses the EXISTING `feather` field for
the brush's soft edge rather than adding a new one. Rasterizes via a small
`CGContext` bitmap (sized to the stroke's own padded bounding box, never
the full extent) bridged through `CIImage(cgImage:)` and softened with
`CIGaussianBlur` — no new Core Image kernel. No on-image overlay/handles
once painting ends (v1 shows only the live in-progress path); editing a
placed stroke afterward is Size/Feather sliders plus a "Redraw Stroke"
button that replaces it entirely.

**Seven design corrections found and folded into the plan during review**
(not left for the reviewer agent to catch during implementation): clamp
(don't `nil`-skip) a too-small brush size, mirroring a real bug
`LinearMaskGeometry` already hit once; no `.clampedToExtent()` before the
blur (fails open on insufficient padding, whereas skipping it merely
clips the feather tail); the rasterized mask bitmap must be loaded via
`CIImage(cgImage:options: [.colorSpace: NSNull()])` to keep RGB==alpha,
matching what `CIBlendWithMask`'s two existing call sites already assume;
paint-mode state must be `UUID?` not `Bool` (a falling-edge cleanup needs
the OLD id, which a bool can't supply once `select(_:)` has already
repointed selection); "Redraw Stroke" must not clear the stroke until the
FIRST point of the new drag, so an Escape right after clicking it doesn't
destroy the original; an existing test
(`EditStateCodableTests.testUnknownMaskKindDecodesToRadialWithoutDiscardingTheSidecar`,
line 239) hardcodes the literal string `"brush"` as its unknown-kind
stand-in and needs repointing to a genuinely-future kind name; `brushPoints`
must decode via `(try?) ?? nil`, not a bare `try`, for the same
whole-sidecar-loss reason `Mask`'s existing `kind` decode already uses
that idiom.

**Explicitly deferred, logged for the plan's own doc-update step**:
multi-stroke-per-mask, erase/subtract within one brush mask,
reposition/resize of an already-painted stroke, per-point variable size
(pressure), and — flagged as a REAL, named accessibility gap unlike
Radial/Linear's slider-justified `.accessibilityHidden(true)` — no
keyboard/AT path to paint or adjust a stroke's shape at all.

## Phase 7 slice 4 (Brush mask) — implementation, perf, and live
verification COMPLETE (2026-09-13); reviewer pass + commit next

Followed the plan's 10-step sequencing
(`~/.claude/plans/purrfect-giggling-tower.md`) end to end: data model →
`BrushMaskGeometry` + tests → `EditPipeline` wiring + tests (y-flip test
written and checked FIRST, per the plan) → UI non-interactive
(`MaskGeometry` additions, `MaskDetailView`, `AdjustTabView`) → UI
interactive (`BrushMaskOverlayView`, `ContentView`) → live verification →
perf probe → docs (this section + CLAUDE.md + IMPROVEMENTS.md). Reviewer
pass and commit are the two remaining steps. Build green and full test
suite green (758 tests, up from 717) after every step.

**Live verification, in detail** (screen automation, user-authorized
per-task as this session's standing convention):
- **A real, live-caught regression, fixed on the spot**: the plan's own
  masks-section comment optimistically asserted the three add-mask
  buttons wouldn't truncate at the sidebar's default width — live
  screenshots showed "Add Radial"/"Add Linear"/"Add Brush" actually
  rendering as "Add Ra…"/"Add Lin…"/"Add Bru…" the moment a third button
  was added. Fixed by dropping the shared "Add" prefix from all three
  visible labels ("Radial"/"Linear"/"Brush"), keeping the full "Add ___
  Mask" wording in each button's own `accessibilityLabel` — confirmed
  live afterward that all three fit cleanly.
- Confirmed end to end on a real photo (a viscuna against plain blue
  sky, chosen specifically so both brightening and darkening would be
  clearly visible): "Add Brush" arms painting immediately; a slow,
  multi-point synthetic drag paints a continuous, gapless stroke;
  releasing the mouse ends paint mode (the live overlay disappears,
  zoom/pan become available again); the RENDERED stroke lands exactly
  along the drag path once the mask's own Exposure is set to a
  non-identity value (masks with all-zero adjustments correctly render
  as a total no-op, confirmed separately — see the false-alarm
  investigation below); the stroke's edges are properly soft (default
  feather 0.5) with rounded caps, not hard-edged.
- ⌘Z/⇧⌘Z: one continuous stroke undoes and redoes as exactly ONE step
  (confirmed via a 3-deep undo chain — Exposure edit, then the whole
  paint stroke, then "Add Brush" itself, each a separate step, exactly
  as the ~350ms coalescing window predicts for actions that far apart)
  — NOT one step per appended point.
- "Add Brush" then Escape with no drag leaves no stray mask in the list
  ("No masks yet" restored) — confirms `discardUnpaintedBrushMask`'s
  `.onChange(of: brushPaintingMaskID)` falling-edge cleanup.
- Switching to the Crop tab while an unpainted brush stroke was still
  armed cleanly discarded the mask on return to Adjust — one of the
  several disarm routes the single `.onChange` handler covers, confirmed
  live rather than only by reading the code.
- Revert to Original cleanly cleared the mask back to "No masks yet."
- **A real false alarm, investigated and resolved, not dismissed**: an
  earlier test photo (a chart PNG) briefly showed what looked like a
  thin, dark double-line artifact instead of the expected wide soft
  glow after setting Exposure — initially suspected as a real
  rasterization bug (wrong line width, wrong sign). Root-caused by
  retesting cleanly on a fresh photo with no intervening stray clicks:
  the wide, soft, correctly-positioned dab rendered exactly as
  expected (confirmed both brightening at +3 EV and darkening at -3 EV
  against a plain sky background). The original artifact is now
  believed to be a side effect of this session's own automation
  confusion (a stray click likely nudged the Brush Size slider to a
  tiny value during a long sequence of miscalculated coordinates while
  hunting for a way to scroll the sidebar — see below) rather than a
  product defect; not reproducible on a clean run.
- **Environment limitation, logged not worked around**: this session
  could not find a way to make synthetic input scroll the Adjust
  sidebar's `ScrollView` — neither `cliclick`'s drag, a JXA
  `CGEventCreateScrollWheelEvent`, Tab-to-focus, nor Page Down moved it,
  and `AppleShowScrollBars=Always` didn't surface a draggable scroller
  either (tried, then reverted). This blocked live-exercising the Brush
  Size/Feather sliders and the "Paint Stroke"/"Redraw Stroke" button
  directly, since they sit below 8 tone/color rows in `MaskDetailView`.
  Accepted on code-review + prior-slice-precedent strength instead
  (identical, unmodified `EditSliderRow`/`Button` code already
  live-verified for Radial/Linear in slices 2-3) — the same category of
  accepted gap slice 3 Session B logged for scroll-wheel zoom in this
  same environment. Worth trying a real trackpad/mouse device (not
  synthetic events) if this matters for a future session on this
  machine.
- Compare/Split, Library-thumbnail refresh, and JPEG export were NOT
  independently live-exercised this pass (time-boxed after the above) —
  accepted on the strength of slice 2 Session A's own confirmed
  no-changes-needed research (`PhotoExporter`/`ThumbnailGenerator`/
  `CatalogModel` all already flow any `EditState.masks` value through
  unmodified, kind-agnostic).

**Perf, live-measured** (same `CFAbsoluteTimeGetCurrent()`
measure-then-fully-revert methodology as every prior Phase 7 perf
check — a temporary `TempBrushPerfProbeTests.swift`, deleted before
commit, confirmed via a clean `git status`): rendered into a fixed
2268×1385 buffer (matching slice 1/2's own established drawable size)
on the user's real 20.7MP JPEG (`IMG_6564.jpeg`) and real 24MP D610 RAW
(`DSC_1665.NEF`, via `RawDecoder.materialize`):
- One brush mask with Clarity: JPEG full-res 7.4ms→9.5ms baseline→masked
  (+2.1ms), JPEG proxy 7.0ms→7.4ms (+0.4ms); RAW full-res
  7.7ms→7.7ms (near noise floor), RAW proxy 7.7ms→8.6ms (+0.9ms) — every
  configuration comfortably under the 16ms/60fps budget.
- Three brush masks with Clarity (the same stress case slice 2 used):
  JPEG full-res 11.0ms (+3.6ms), JPEG proxy 7.5ms (+0.5ms) — both fine.
  RAW proxy 8.2ms — fine. **RAW full-res: 33.7ms — over budget**,
  reproducing the SAME known, already-documented finding CLAUDE.md
  records for slice 2's Radial/Linear masks (that case measured
  ~15-21ms) — measured notably higher for Brush, plausibly because each
  Brush mask also pays its own `CGContext` rasterization + Gaussian
  blur pass on top of Clarity's own cost, compounding with RAW's
  already-heavy per-frame baseline. Accepted as the same documented,
  non-blocking limitation slice 2 already established the precedent
  for — the interactive/proxied path (what a user actually drags
  against while editing) stays fast in every configuration measured;
  only an isolated, non-interactive full-resolution RAW frame with 3+
  Clarity-bearing masks is affected.

**Reviewer** (Opus 5, per this session's standing convention): 4 rounds —
FIX FIRST → FIX FIRST → FIX FIRST → APPROVE, the most of any Phase 7
slice. All four rounds verified claims empirically (built the project,
ran the suite, wrote standalone probes rendering `BrushMaskOverlayView`
offscreen and replaying `brushStrokeMaskImage`) rather than trusting the
diff or doc comments. Round 1 caught two real, blocking bugs: (1) an
`.onChange(of: brushPaintingMaskID)`-coalescing gap — `AdjustTabView
.addMask(.brush)` writes `brushPaintingMaskID` to `nil` then immediately
to the new mask's id in one synchronous action, which SwiftUI collapses
into a single `.onChange` call (`old = A, new = B`) that never observes
the intermediate `nil` — so "Add Brush" while a DIFFERENT unpainted
Brush mask was already armed leaked that earlier mask forever; fixed by
discarding whenever the id changes at all, not only on the falling edge
to `nil`. (2) `BrushMaskOverlayView`'s `maximumPointCount` guard ran
BEFORE the "first callback of a new gesture replaces the array"
branch, so a maxed-out stroke could never be redrawn, only deleted;
fixed by reordering. Round 1 also flagged (non-blocking, all addressed):
a measured ~3.9ms-per-call eager-rasterization cost with no memoization
(fixed with an `NSLock`-guarded single-entry `BrushStrokeImageCache`,
keyed on the already-`Equatable` `BrushMaskGeometry.Resolved`); a
per-stroke `NSCursor` push/pop leak (the overlay tears itself down via
`onStrokeEnded` while the pointer is still inside, so `.onHover(false)`
never fires — fixed with an `.onDisappear` pop guarded by a tracked
hover flag); a `feather == 1` doc-comment overstatement (a Gaussian
blur, unlike `.radial`'s gradient, never reaches alpha 1.0 — measured
and documented as a real, accepted ~86%/~95% cap, not "fixed"); several
stale pre-slice-4 doc comments (Mask.swift/EditPipeline.swift/
ContentView.swift only mentioning radial/linear); and missing
`Codable` test coverage matching slice 3's own precedent (default-
when-absent, malformed-`brushPoints`-doesn't-discard-the-sidecar,
round-trip, deterministic-fallback-id-with-points, all added). Round 2
caught a THIRD real bug the fixes-so-far had missed: switching PHOTOS
while an unpainted Brush mask is armed is NOT actually covered by the
central disarm handler, despite that handler's own doc comment
claiming otherwise — `ImageDocumentModel.load(from:)` swaps
`currentURL`/`editState` to the incoming photo synchronously, before
`ContentView`'s `.onChange(of: document.currentURL)` fires, so the
cleanup looks the old mask up in the WRONG (new) photo's `masks` array
and no-ops, while the outgoing photo's phantom empty mask has already
been flushed to ITS sidecar. Deliberately NOT fixed behaviorally this
slice (would need cleanup to run before `load(from:)`, at every
photo-switch call site or via a model-level hook — a different shape
than this slice's `ContentView`-only mechanism) — instead honestly
documented as a real, accepted gap in both the code's own doc comments
and a new `IMPROVEMENTS.md` D13 entry. Round 3 caught that the FIRST
attempt at documenting round 2's gap was itself two more doc-accuracy
mistakes (an inverted summary sentence that read as claiming the exact
opposite of what round 2 required, and a doc-comment file
misattribution) — both fixed. Round 4: APPROVE, no remaining issues in
image math, non-destructive integrity, GPU/texture lifecycle, thread
safety, or catalog/DB.

763 tests (up from 717 pre-slice — 46 new, across
`BrushMaskGeometryTests` (new), `MaskGeometryTests`, `EditPipelineTests`,
and `EditStateCodableTests`). Test photos' sidecars confirmed clean
(`viscuna.jpg`/the chart PNG were already reverted during live
verification; `IMG_9804.jpg`'s leftover test sidecar, missed at the
time, was found and deleted during this doc pass — no sidecar means
original, this app's own established convention). Ready to commit.

## Phase 7 slice 5: Luminance Range mask (2026-09-14)

The first CONTENT-DERIVED mask kind — `.luminanceRange` selects pixels
by their own tone rather than by a drawn shape. Scoped via
`AskUserQuestion` at the start of the session: Luminance Range only
this pass (the sibling "Color Range" kind needs a new `.cikernel` and
an eyedropper-style armed UI — deferred to its own future session,
`"colorRange"`'s `EditStateCodableTests` stand-in re-pointed to it via
an updated doc comment); tone judged in scene-linear light, the same
domain `applyMasks` already operates in at that point in the loop; and
this slice also fixes `ContentView`'s kind-agnostic `isEditingMask`/
`canZoom` gate, since a mask kind with no on-image overlay shouldn't
block zoom/pan or steal keyboard focus merely by being selected.

**Data model** (`Sources/EditEngine/Mask.swift`): new `MaskKind
.luminanceRange` case, plus `luminanceTarget`/`luminanceRange` fields
(perceptual-tone-domain, `0.5`/`0.3` defaults). `feather` is reused a
THIRD time (after `.radial`/`.brush`) — same
`innerHalfWidth = outerHalfWidth * (1 - feather)` formula shape,
applied to a tone window's half-width instead of an ellipse's radius,
deliberately reused for its transferable meaning, not just to save a
field. Schema-tolerant decode follows the established pattern (bare
`try` for both new plain-`Double` fields — the `try?` sites in this
file exist only for `kind`'s raw-value-enum hazard and `brushPoints`'
nested-array hazard, neither of which applies here);
`deterministicFallbackID` gained both fields plus a fourth `kindSeed`
arm.

**New pure type** (`Sources/EditEngine/LuminanceRangeSelection.swift`):
`resolve(luminanceTarget:luminanceRange:feather:extent:)` maps the
perceptual tone window through the sRGB EOTF
(`linearLuminance(forTone:)`, unclamped beyond 0...1 for headroom) to
four scene-linear thresholds (`lowerZero`/`lowerFull`/`upperFull`/
`upperZero`). 25 unit tests, including the asymmetric worked example
(target 0.5, range 0.3, feather 0.5 → lower edge 0.0506 wide, upper
edge 0.0899 wide — tone-symmetric but linearly asymmetric, the whole
point of doing the tone→linear mapping instead of a bare linear
window).

**`EditPipeline.applyMasks` branch**: built from a throwaway probe
FIRST (measure-before-trusting, this codebase's own established
discipline), not assumed — `Tests/EditEngineTests/
TempLuminanceRangeProbeTests.swift`, deleted before commit (confirmed
via `git status`). Chain: `CIColorMatrix` (Rec.709 luma collapse,
forced-opaque alpha) → two clamped affine "tone ramps" (`CIColorMatrix`
scale/bias + `CIColorClamp`, one rising across the dark edge, one
falling across the bright edge) → `CIMinimumCompositing` (the exact
trapezoid/tent, zero overshoot by construction) → `CIMaskToAlpha`.
Rejected a `CIToneCurve`-based tent (the approach `applyCurves`'s own
doc comment already flags as extrapolating past its endpoints and
clamping its LUT to 0...1 — either would leak selection outside the
window or collapse headroom pixels into one bucket). The probe
confirmed, before any shipped code was written from it: RGB==alpha
holds at every luminance tested; the mask reads ~1.0 across the
plateau and ~0.0 well outside with nothing leaking through;
`CIMaskToAlpha` applies no extra gamma (opaque neutral 0.5 in → alpha
0.5 out, not 0.735 or 0.214); a pure red patch collapses to luma
0.2126; and — the one genuinely surprising finding — `CIColorMatrix`'s
output extent is NOT naturally finite even given a finite input
(confirmed on both a synthetic image and the user's real 20.7MP
`IMG_6564.jpeg`, extent reported as effectively `CGRect.infinite`
pre-crop), unlike `.linear`/`.brush`'s naturally-finite chains — this
is why the branch's own explicit `.cropped(to: extent)` is load-bearing
here, not merely defensive. No `base`/union step needed (unlike
`.radial`): every node in the chain has a genuinely finite, fully
defined extent once cropped.

**Perf, live-measured** (same probe-and-fully-revert methodology,
2268×1385 drawable): JPEG (`IMG_6564.jpeg`) no-mask baseline 12.43ms,
one ROI-cropped radial mask 12.59ms (+0.15ms), one luminanceRange mask
(no ROI possible for this kind) 12.88ms (+0.45ms). RAW (`DSC_1665.NEF`,
`RawDecoder.materialize`'s cached buffer) no-mask baseline 14.85ms,
radial 14.53ms (within noise), luminanceRange 16.02ms (+1.18ms) — both
deltas small relative to RAW's own already-heavy per-frame cost, well
within the 16ms/60fps budget this codebase's prior Phase 7 perf checks
already use as the bar.

**UI**: `AdjustTabView.masksSection` became a 2×2 button grid (Radial/
Linear row 1, Brush/Luminance Range row 2) instead of a 3-button
`HStack` already at its live-verified width limit — gives every label
more room, absorbs a future Color Range button as a natural third row.
`select(_:)` gained a `hasOnImageOverlay(_:)` check so selecting a
Luminance Range mask does NOT call `onEnterPointPickingMode()` (which
would otherwise pointlessly reset zoom/pan/Compare for a mask kind with
nothing to arm). `MaskDetailView` gained a kind-aware section title
("Luminance Range" vs. "Shape") and a `luminanceRangeShapeRows` view
(Luminance/Range sliders citing `LuminanceRangeSelection`'s own
clamp constants, plus the extracted shared `featherRow`) — no new
accessibility gap, since every parameter is a labeled `EditSliderRow`
with no gesture at all.

**`ContentView.swift` kind-aware zoom/focus gate**: new
`hasOnImageOverlay(_ kind:)` (exhaustive switch, duplicated from
`AdjustTabView`'s copy since `EditEngine` stays UI-free) and
`isEditingOverlayMask` (narrows `isEditingMask` to overlay-owning
kinds), swapped in at 5 sites: `canZoom`, the mask-overlay `switch`
(which also gained a `case .luminanceRange: EmptyView()` tripwire arm),
the rising-edge focus-grab `.onChange(of: selectedMaskID)`, the
Library-round-trip refocus condition, and the pane's accessibility-
label switch. Left deliberately unchanged: Escape routing (still
kind-agnostic), `.brush`'s own selected-but-not-painting zoom block
(a lower-value, separate improvement — logged, not folded in), and
Compare's `selectedMaskID`-clearing `.onChange(of: compareMode)` (still
clears for every kind, including Luminance Range — a real, separate
follow-up, not fixed this slice). A deliberate, desirable consequence:
selecting a Luminance Range mask no longer forces Compare off, so
mask-selected + Compare-Split is newly reachable for this kind.

**Tests**: 806 total (up from 763 pre-slice — the RAW luminance probe
tests and their harness never shipped; net permanent additions are 25
in `LuminanceRangeSelectionTests`, 14 in `EditPipelineTests`' new
Luminance Range section (including one exact-weight cross-check added
during reviewer follow-up — see below), and 4 new
`EditStateCodableTests` default/round-trip/id-collision cases:
25 + 14 + 4 = 43, 763 + 43 = 806). One test-only bug surfaced and
fixed during this pass, not a pipeline bug:
`testLuminanceRangeResponseIsMonotonicSinglePeaked`'s tone ladder
originally started at `tone = 0.0`, whose linear luminance is exactly
`0` — dividing the measured output by that denominator to isolate the
mask's weight from each rung's own baseline produced `0/0 = NaN`,
corrupting `values.max()`/`firstIndex(of:)` into a hard crash rather
than a clean assertion failure; fixed by starting the ladder at `0.05`
instead.

**Live-verified (2026-09-14)**, screen-automation permission asked and
granted fresh for this task: driven via `System Events`
accessibility actions (`AXPress`/`AXIncrement`/`AXDecrement`) rather
than synthetic mouse clicks/drags — this environment's synthetic
`cliclick` mouse events do not reach the app at all (confirmed directly:
an AXPress on the "Library" toolbar button switched views instantly,
while a pixel-identical `cliclick` at the same on-screen location,
confirmed via a cursor screenshot, did nothing), a broader version of
the scroll-wheel-only limitation slice 3 Session B already logged for
this machine. Confirmed on the user's real `IMG_6564.jpeg`: adding a
Luminance Range mask shows no armed mode and no on-image overlay;
pushing Exposure to +5EV with the default target/range visibly clipped
only the bright salt/snow, NOT the saturated blue sky — a genuine,
correct demonstration of luma-based (not perceived-brightness) tone
selection, since Rec.709 luma weights blue at only 0.0722; dropping
Luminance target to 0% (at a moderate +1.5EV) moved the visible effect
from the snow onto the dark clothing instead, confirming real,
reactive tone-targeting; pushing Range to 100% visibly widened the
effect to cover the whole frame; Feather's `AXValueDescription`
confirmed reactive (50%→0%). Regression-checked: adding a Radial mask
afterward showed its on-image ellipse overlay as expected, and
reselecting the Luminance Range mask correctly hid it again — the
kind-aware overlay switch works dynamically, not just at add-time.
Revert to Original correctly cleared both test masks back to "No masks
yet"; the on-disk sidecar was read directly afterward and confirmed
`"masks":[]` — the user's real photo library is unchanged. Not
independently exercised (zoom/pan-not-blocked, keyboard-focus-not-
stolen): the environment's mouse-click/scroll limitation above rules
out an interactive repro; accepted on the reviewed code's own strength
instead, same precedent as slice 3 Session B's zoom-block finding.

**Reviewer** (Opus 5, per this session's standing convention): 2 rounds,
FIX FIRST → APPROVE. Round 1 required one fix and flagged five
non-blocking ones, all addressed: (1, required) the doc comments
explaining the infinite-extent finding misattributed the cause to
`CIColorMatrix` in general — independently re-measured and confirmed
the true cause is specifically this branch's forced-opaque alpha bias
(`luma.aVector = 0`, `luma.biasVector.w = 1`); a `CIColorMatrix` that
passes its input's own alpha through stays finite. (2) the downscale
test used a solid-color image, tautological for a tone-based (not
geometric) selection — rewritten as a step-edge image sampled well
inside the matching half at two sizes, isolating the one real
resolution hazard (resampling blending a tone boundary) instead. (3) no
test pinned the falloff's actual values, only its shape — added
`testLuminanceRangeExactWeightAtAPartialToneMatchesTheAnalyticFormula`,
deriving the expected weight from `LuminanceRangeSelection.resolve()`
itself rather than a hand-typed magic number, so it cross-checks the
Core Image chain against the Swift math without being circular. (4)
`luminanceRangeMaskImage` returned an infinite-extent image and relied
on its caller to crop — moved the crop inside the function itself,
keyed on its own `sel.regionOfInterest`, so a future call site can't
forget it. (5) `minimumEdgeWidth`'s doc comment didn't note the floor
is fixed in LINEAR space and therefore NOT perceptually uniform across
the tone range (a dark hard edge renders measurably softer than a
bright one at the same nominal Feather) — added, with the numbers.
(6) a `ContentView.swift` doc comment overstated that Escape routing
"just works" for every mask kind — corrected to note it's reachable
only when focus already sits on the image pane for a non-overlay kind,
harmless for `.luminanceRange` specifically since `canZoom` is itself
kind-aware, but no longer implied unconditional. Round 2 caught that
fix (4) itself broke a DIFFERENT doc comment 65 lines away that still
told a future maintainer the crop was the CALLER's responsibility —
the exact same class of hazard round 1's required fix existed to
close (a "do not remove this crop" safety comment pointing at the
wrong code) — fixed to point at the function's own `return` statement.
Also caught PROGRESS.md's own test-count arithmetic going stale after
the fix round (805→806, `LuminanceRangeSelectionTests`' actual 25
methods vs. an earlier "~19" estimate) — corrected in the paragraph
above. Independently re-derived the exact-weight test's expected value
by hand (weight 0.3070 at tone 0.375) and confirmed it discriminates
against a tone-space-ramp bug (~1.5% off, well outside tolerance) and
against full-weight (way off) — not just numerically close to two
plausible answers. APPROVE on round 2, no further issues found in
color-math correctness, alpha/headroom preservation, Codable safety, or
thread safety.

**Deferred, logged, not forgotten**: Color Range mask (own future
session); combining masks (slice 6); `.brush`'s own zoom-block
behavior; Compare's `selectedMaskID` clear becoming kind-aware; any ROI
optimization for Luminance Range (structurally impossible — the mask's
extent is the whole image by construction); a custom `.cikernel` (the
built-in filter chain measured sufficient).

## Phase 7 slice 5 (second half): Color Range mask — ✅ COMPLETE (2026-09-14)

Closes out CLAUDE.md roadmap item 5: pick an exact color via eyedropper,
select pixels similar to it jointly across hue/saturation/luminance in
scene-linear light. Full design/implementation detail lives in CLAUDE.md's
own roadmap item 5 write-up (kept there rather than duplicated here, per
this file's own recent convention for Phase 7 slices) — this section
records the session mechanics: sequencing, the reviewer rounds, and the
live-verification session itself, including one real environment hazard
hit along the way.

**Sequencing followed the plan's own tripwire-cascade discipline**
(`Mask.swift`'s new case/fields first, stubbed with `continue`/`EmptyView()`
at each of the ~9 exhaustive switches it breaks, green before moving on):
`ColorRangeSelection.swift` + its 32 tests (pure math, no kernel/pipeline
involved) → `ColorRange.cikernel` + a throwaway `TempColorRangeProbeTests.swift`
(6 tests: kernel compiles, solid-patch selection, hue wraparound, headroom
selection, a 12-color Swift/GLSL agreement sweep, output-extent finiteness
— all passed on the FIRST attempt, no kernel bugs found) → `EditPipeline.swift`
wiring + 19 new `EditPipelineTests` (also all passed first attempt) → UI in
dependency order (`AdjustTabView` -> `MaskDetailView` -> `ContentView` ->
`ImageDocumentModel`) → live verification + reviewer → probe deleted,
docs updated, commit.

**Reviewer (Opus 5): 2 rounds, FIX FIRST -> APPROVE** — full detail in
CLAUDE.md's own write-up; briefly, round 1 found 3 blocking issues (a real
crash from an unguarded `Int(...)` cast on deliberately-unclamped tone
math, a NaN-propagation gap in the swatch-reconstruction function with no
guard AND no hue wrap unlike its own `resolve` sibling, and a doc comment
citing a test outside that test's own actual regime) plus several
non-blocking ones, most also fixed same-round (a silently-deleted-mask UX
gap, a missing mutual-exclusion guard, a format-specifier nit). Round 2
independently re-derived all three blocking fixes' math by hand rather
than trusting the round-1 description, confirmed the new regression tests
weren't vacuous (traced the actual RGB branch the hue-wrap fix changes),
and re-verified the whole diff holistically before APPROVE. One more
trivial fix (a shared alert's hardcoded "White Balance" title, now "Color
Sample" — this slice made it a 3rd caller) taken directly from round 2's
own non-blocking notes without a third round, matching this codebase's
own established precedent for genuinely cosmetic post-approval polish.

**Live verification (2026-09-14)** used this machine's now-standard
AX-driven approach (`AXPress` on buttons, `AXIncrement` on sliders,
direct `AXScrollBar` value-setting to scroll a `.scrollIndicators(.hidden)`
`ScrollView` that has no visible thumb to drag) plus exactly ONE real
user click for the eyedropper tap itself — the plan's own predicted
exception, confirmed true in practice: a bare `SpatialTapGesture` capture
layer has no AX affordance, unlike every button/slider elsewhere in this
feature. Photo used: the user's real `IMG_6414.jpeg` (Bolivia trip, a
roof-loading scene with a large clear-blue-sky region — chosen live from
the Library grid specifically for its color variety, not pre-selected).

One real hazard hit mid-session, diagnosed rather than dismissed: driving
the app via `open`-ing a `PhotoApp.app` bundle picked by "most recently
modified DerivedData folder" initially launched a STALE build (from an
earlier, unrelated `xcodebuild` invocation under a different DerivedData
hash) — the Masks section was simply absent from the Adjust sidebar,
which briefly looked like a real regression. Root-caused via
`xcodebuild -showBuildSettings`'s own `TARGET_BUILD_DIR` (the authoritative
answer for "which DerivedData folder does THIS scheme's THIS build
actually target"), not by guessing from mtimes; relaunching the correct
bundle immediately showed the Masks section correctly. Worth remembering
for the next live-verification session on this machine: `ls -dt` over
`DerivedData/PhotoApp-*` is NOT a reliable way to find "the app you just
built" when multiple stale DerivedData folders exist from earlier
sessions.

A second, separate hazard: the first live pick attempt appeared to fail
(the newly-added mask vanished, reading as "No masks yet" after the real
click) — traced to a large real-world time gap (the user's confirmation
of "I clicked" arrived roughly 90 minutes after the pick was armed) during
which SOMETHING (most likely simple idle time, possibly other
interaction) disarmed `colorPickingMaskID` without a completed pick,
correctly triggering `discardUnpickedColorRangeMask`'s own designed
cleanup — not a bug, but indistinguishable from one without checking the
mechanism. Retried immediately (arm -> ask -> click -> check, all within
under a minute) and it worked correctly the first time: the mask
persisted, `colorRangeHasTarget` was set, and the readout/swatch rendered
correctly (see CLAUDE.md's own write-up for the exact measured values and
the +5EV confirmation). This confirms `discardUnpickedColorRangeMask` is
doing exactly its documented job — a genuinely abandoned pick IS
supposed to clean itself up — and is a real, if incidental, live
confirmation of that safety net, not just its unit-tested logic.

The test photo (`IMG_6414.jpeg`) was reverted to identity before this
write-up via the app's own "Revert to Original" — the library is
unchanged; the `IMG_6414.jpeg.photoapp.json` sidecar this session created
is the one artifact left behind, and it was read directly off disk and
confirmed `"masks": []` after the final revert.

## Phase 7 slice 6 — Combining masks (intersect/subtract), Session A (data
## model + pipeline) — ✅ COMPLETE (2026-09-15)

Plan approved and saved at `~/.claude/plans/merry-questing-gizmo.md` — full
design rationale (data model, non-transitivity, fail-open table, pipeline
wiring, UI shape for Session B) lives there, not duplicated here. This is
the LAST slice of Phase 7 (all five mask kinds already ship; this is a
cross-cutting capability, not a sixth kind) — once Session B ships, Phase 7
(Local Adjustments/Masking) is fully complete.

Two new `Mask` fields (`Sources/EditEngine/Mask.swift`): `combineMode:
MaskCombineMode = .none` (`.none`/`.intersect`/`.subtract`) and
`combineWithMaskID: UUID? = nil`. `.none` is byte-identical to every
pre-slice-6 mask/sidecar — purely additive, no migration concern. Both new
Codable fields use `try?` (not bare `try`): `combineMode` for the same
`String`-raw-value-enum hazard `MaskKind` already established (an
unrecognized-but-present string throws, not returns `nil`); `combineWithMaskID`
because `UUID.init(from:)` throws `dataCorrupted` on a well-typed-but-
unparseable string, and a hand-edited combine reference is exactly the
reachable scenario. `deterministicFallbackID` extended with both (an
exhaustive 0/1/2 switch for the mode, a third variable-length hashing pass
for the UUID's raw 16 bytes).

Pipeline (`Sources/EditEngine/EditPipeline.swift`, `applyMasks`): two pure,
behavior-preserving extractions first (`resolveMaskGeometry`,
`maskImageAndRegion`) — gated on the FULL pre-slice-6 mask suite passing
with ZERO test edits, the actual proof the extraction didn't change
behavior. Then a combine block between a mask's own resolve and the final
`CIBlendWithMask`: intersect via `CIMinimumCompositing` (direct precedent:
`luminanceRangeMaskImage` already ANDs two ramps this way), subtract via
`CIMinimumCompositing` against a channel-inverted operand
(`invertedMaskImage`). All five `MaskKind`s are valid operands (no
restriction) — an operand is resolved against the same running `img` the
consumer's own content-derived selection would see, unlocking cases like
"brighten only the highlights inside this drawn area." No transitive
chaining (an operand's own combine settings are never read — cycle-safe by
construction, not by guarding against cycles). Self-reference and dangling
references both fail open to `.none`; a degenerate operand (unpicked Color
Range, zero-radius Radial, unpainted Brush) follows real boolean algebra —
intersect skips the whole mask (`M ∧ 0 = 0`), subtract is a no-op
(`M ∧ ¬0 = M`).

**A genuine, self-caught Core Image correctness bug**, found via a
throwaway probe (`Tests/EditEngineTests/TempCombineMasksProbeTests.swift`,
deleted before commit) before any reviewer involvement: the first
`invertedMaskImage` implementation used `CIColorMatrix` inverting all four
channels independently, which passes at the two degenerate extremes
(`w=0`, `w=1`) but silently fails at every PARTIAL weight — `CIColorMatrix`
unpremultiplies an RGB==alpha pixel `(w,w,w,w)` before applying its matrix,
and unpremultiplied RGB is `w/w=1` regardless of `w`, zeroing RGB while
alpha still computes correctly (measured: weight `0.5248` inverted gave
`R=0, A=0.4752` instead of `R=A=0.4752`) — breaking the RGB==alpha
covariance this codebase's `CIBlendWithMask`/`CIMinimumCompositing`/
`CIMaximumCompositing` calls all depend on throughout. `CIColorInvert` is
ALSO wrong, for an unrelated, simpler reason (inverts RGB, leaves alpha
untouched). Fixed with Porter-Duff `CISourceOutCompositing`
(`Src * (1 - Dst.alpha)`, always defined in premultiplied space, so RGB==
alpha covariance is preserved automatically): `Src` is an extent-sized
opaque-white constant, `Dst` is the operand's mask image. Verified exact
across the full `0...1` weight range via the probe, not just the
endpoints.

**Reviewer (Opus 5): 2 rounds, FIX FIRST → APPROVE.** Round 1 found 3
blockers — a genuinely tautological test
(`testSubtractInversionDoesNotTintTheMaskEdges`, which only asserted
`sample.r == sample.g == sample.b` on a neutral-gray input; proven
tautological by fault-injecting both false-start implementations and
confirming the test did NOT fail under either, since `CIBlendWithMask`
weights R/G/B uniformly regardless of which bug produced the weight —
deleted, not kept as false confidence, superseded by the two pre-existing
value-based tests that actually caught the real bug during development), a
dangling "IMPROVEMENTS.md's D15" citation (no such entry existed), and two
`Mask.swift` doc comments describing not-yet-built Session B UI in present
tense — plus 6 non-blocking nits (an unused-so-far `CaseIterable`
conformance, a redundant `!region.isNull` check already covered by
`!region.isEmpty`, `opaqueWhite` rebuilt per-call instead of hoisted as a
loop-invariant like `base`, and an undocumented early-exit-after-
perceptual-sandwich ordering deviation — harmless since Core Image recipes
are lazy). All fixed: the tautological test deleted; a real
`IMPROVEMENTS.md` D15 entry added (v1 scope cuts: no transitive chaining,
one operand per mask/no union mode, no on-image indication of the combined
shape, no reference-scrubbing on delete, `Mask.id`'s own still-bare-`try`
decode as a candidate for a future session); both doc comments reworded to
correctly describe Session B's UI as planned, not shipped; `opaqueWhite`
hoisted into `applyMasks` next to the existing `base` hoist and threaded
into `invertedMaskImage` as a parameter. Round 2 independently verified via
two standalone Core Image probes (not just reading the diff) that
`CIBlendWithMask` weights on the mask's premultiplied RGB — confirming both
false starts really do collapse to a zero weight and that the two
surviving tests genuinely catch this — and separately verified
`CISourceOutCompositing`'s output extent is the full source extent (not
clipped to the operand's own smaller footprint, the case only `.brush`
produces), so subtracting against a smaller-than-extent operand correctly
leaves the consumer untouched outside it — no fail-closed hole. One
non-blocking nit from round 2 (the D15 citation to
`~/.claude/plans/merry-questing-gizmo.md` should give the full path, not
just the bare filename, matching this file's own precedent elsewhere) —
fixed directly, no third round needed.

897 tests written this session; 896 pass (one intentionally deleted as
tautological, see above) — zero regressions in the full pre-existing mask
suite after the `resolveMaskGeometry`/`maskImageAndRegion` extraction, the
actual proof it's behavior-preserving.

**Not done this session, by design (Session A = data model + pipeline
only, per the approved plan's own sequencing)**: no UI at all — reachable
only via a hand-authored sidecar until Session B; no live verification (no
UI to verify); no perf probe (round 2's reviewer flagged the specific
scenario Session B must actually measure: a `.colorRange`/`.luminanceRange`
operand adds a second full-extent kernel pass per frame with no ROI crop
available for intersect, unlike the radial/brush operands this session's
tests use — worth prioritizing in Session B's own 4-scenario probe).

**Exact next step (superseded — see the Session B section immediately
below, which shipped this)**: ~~Session A is done and committed. Session
B...~~

## Phase 7 slice 6 — Combining masks (intersect/subtract), Session B (UI +
## live verification + perf) — ✅ COMPLETE (2026-09-15)

Plan Mode ran first per CLAUDE.md's standing rule — the plan file
(`~/.claude/plans/merry-questing-gizmo.md`) was rewritten for Session B
specifically after a fresh Explore pass confirmed the real code against
Session A's own design (the approved plan carried forward accurately with
two additions the exploration surfaced: a pure, testable
`MaskCombineTarget.targets(excluding:in:)` helper instead of an inline
`map`, and an auto-select-first-target behavior for the mode picker so
choosing "Intersect"/"Subtract" never reads as an inert control).

**Implementation.** `Sources/UI/MaskDetailView.swift` gained
`MaskCombineTarget` (`Identifiable`, `Hashable`, `id`+`label`),
`CombineTargetSelection` (`.none`/`.mask(UUID)` — the `LibraryFilter`
mirror, see that type's own doc comment in `CatalogModel.swift` for the
live-measured bug it avoids: an `Optional`-typed `Picker` selection can
make the `nil`-tagged row silently unselectable once a real value is
chosen), a `combineRows` view (two `Picker`s, mode and target, appended
last in `body`, hidden entirely when `combineTargets.isEmpty`), and two
coercing `Binding`s — `combineModeSelection` (auto-fills the first
available target when the mode leaves `.none` with nothing chosen) and
`combineTargetSelection` (the actual `LibraryFilter`-style fix: the getter
maps any unresolvable stored id back to `.none`). `Sources/UI/AdjustTabView.swift`
widened `maskKindLabel` from `private func` to `static func` (so
`MaskCombineTarget.targets(excluding:in:)` can reuse the EXACT same label
strings `maskListRows` shows — the picker can never disagree with the
sidebar list) and added one argument to the existing `MaskDetailView(...)`
call site. No mutual-exclusion changes — picking from a menu isn't a
spatial mode, so this doesn't become a 6th hand-rolled mutual-exclusion
site (IMPROVEMENTS.md D14's shared-mode-enum note is unaffected).

`Tests/EditEngineTests/MaskCombineTargetTests.swift` (new, 7 tests) covers
the one pure helper: numbering matches `maskListRows`' global `index + 1`
across mixed kinds, the excluded mask is absent, numbering does NOT
renumber around the exclusion (the specific bug a naive
`filter`-then-`enumerate` would introduce), empty/single-mask arrays
return `[]`, an unresolvable excluded id returns every mask, and labels
carry the kind name. 903 tests total, zero regressions (the rest of this
slice is SwiftUI interaction glue, live-verified per this codebase's own
convention rather than unit-tested).

**Perf probe** — see CLAUDE.md's own roadmap item 6 write-up for the full
numbers; summary: three of the four scenarios stayed comfortably under the
16ms/60fps budget. `.brush` ∩ `.brush` did NOT — it measured ~12.5–19ms
full-res on JPEG, over budget on the full-resolution settle frame (the
interactive/proxied path, ~9-10ms, stayed under budget in every scenario).
Same `CFAbsoluteTimeGetCurrent()`-in-`ImageRenderer.draw(in:)`
probe-and-fully-revert methodology as every prior Phase 7 slice — confirmed
reverted via a clean `git diff` before commit. `.radial` ∩ `.luminanceRange`
(the scenario Session A's reviewer flagged as highest-risk, a content-
derived operand with no ROI crop available) was measured on BOTH the
user's real JPEG and RAW assets per that flag; `.brush` ∩ `.brush` was
confirmed to be the one real cost concern (`BrushStrokeImageCache`
thrashing between two masks' keys), matching the prediction — not fixed
this slice, per that cache's own already-logged remedy.

**Live verification (2026-09-15)**, via AX-driven automation
(`AXPress`/`AXIncrement`/`AXMenuItem` press — this machine's own
established "synthetic `cliclick` doesn't reach this app, AX actions do"
constraint held for every control including, newly confirmed this
session, `AXPopUpButton`/its `AXMenu`) on the user's real `IMG_6564.jpeg`:
added two radial masks, moved one via `Center X` increments to create a
real partial overlap (a first attempt accidentally landed the two circles
EXACTLY TANGENT — zero overlap area, a genuine "my test setup, not a
product bug" moment caught by cropping and zooming into the render before
concluding anything), then confirmed Intersect confines a +5EV brightening
to precisely the round overlap region (verified via a cropped close-up:
the blown-out area was CIRCULAR matching the smaller mask, not oval
matching the larger one — real geometric proof, not just "something
changed"); switched to Subtract and confirmed the exact inverse — the full
ellipse blown out except a precise untouched hole; deleted the operand and
confirmed fail-open on both the canvas (full uncombined effect returned)
and the picker (independently re-derives "None"); confirmed the
surviving mask's own `combineMode` survives a delete unchanged
("Subtract" persisted) while only the target coerces — the exact
documented split; re-added a mask and set a new target, then `⌘Z`/`⌘⇧Z`
confirmed undo/redo steps the whole combine-target change as one unit;
read the on-disk sidecar directly and confirmed real
`combineMode`/`combineWithMaskID` UUIDs matching the picker
(`"combineMode": "subtract", "combineWithMaskID": "7165F34E-..."`); Revert
to Original cleanly cleared back to "No masks yet," confirmed both
on-screen and in the sidecar (`"masks": []`) — the user's real photo is
unchanged (`IMG_6564.jpeg.photoapp.json` verified semantically identical
to its pre-session content, JSON key ORDER differs since `JSONEncoder`
doesn't guarantee stable ordering, but every value round-tripped exactly;
`DSC_1665.NEF.photoapp.json` is byte-for-byte identical, untouched during
live verification).

**One real environment hazard hit mid-session, resolved, not a code
bug**: this Mac's screen locked itself TWICE via idle display-sleep during
the AX-only automation (AX actions don't reset the real HID idle timer the
way physical input does) — the second time, mid-lock, a macOS scheduled
"Restarting Your Computer" update prompt also fired with a live countdown,
and an attempt to dismiss it via `cliclick` mis-hit and nearly closed the
Terminal window running this very session (a "Terminate running
processes: claude, caffeinate, sourcekit-lsp" confirmation appeared) —
recovered by clicking Cancel via AX on the confirming dialog, not by
guessing coordinates again. `caffeinate -d -i -u` was started immediately
after and prevented any further recurrence for the rest of the session.
Worth remembering for the next long AX-automation session on this
machine: start `caffeinate` proactively, don't wait for the first lock.

**One real, live-only finding, logged (IMPROVEMENTS.md D15), not fixed
this slice**: deleting an operand when it's the ONLY other mask on the
photo hides the entire Combine section (correct — `combineTargets` is
empty), which makes the surviving mask's own now-stale `combineMode`/
`combineWithMaskID` invisible from the UI until a second mask exists
again — at which point the picker correctly re-resolves. Harmless per the
same fail-open design, but worth knowing before mistaking the hidden
section for a bug.

**Reviewer (Opus 5) on the Session B UI diff: 3 rounds, FIX FIRST → FIX
FIRST → APPROVE** (unlike Session A's pipeline diff, which took 2). Round 1
found real code/doc issues: `combineTargetSelection`'s setter now resets
`mask.combineMode` to `.none` whenever the target is set to "None"
(previously only `combineModeSelection`'s own auto-fill guarded the
mode-change direction — a user could reach a live, silently-inert combine
via the OTHER picker); the Mode/With `Picker`s gained explicit
`.accessibilityLabel`s ("Combine Mode"/"Combine With"); a live width-check
(a `.luminanceRange` mask — this app's longest kind label — set as a
combine target via the real UI, `AXWindow` size compared before/after:
1395×870 baseline vs. 1392×870, no growth) found no sidebar-width
regression from a long target label; and this file's own "comfortably
under budget" summary above was corrected to not contradict the
`.brush` ∩ `.brush` number two sentences later. Round 2 caught that the
budget-contradiction fix had only landed in CLAUDE.md, not here, plus a
review-summary paragraph (in CLAUDE.md) that pre-asserted round 2's own
outcome before it had run — both corrected to state only confirmed facts.
Round 3 (doc-only) confirmed both fixes actually landed in both files and
independently re-verified the two underlying claims (label-numbering
parity with `maskListRows`, picker/pipeline fail-open parity) rather than
trusting the prose. See CLAUDE.md's own roadmap item 6 write-up for the
full round-by-round detail.

`CLAUDE.md`'s Phase 7 roadmap item 7 (Local Adjustments/Masking) and item
6 (Combining masks) are both now marked ✅ FULLY COMPLETE.
`IMPROVEMENTS.md`'s D15 was updated in place (retitled off "Session A,"
the live-only hidden-section finding added) rather than duplicated as a
new entry.

**Exact next step (superseded — see the Texture/Clarity section at the
end of this file)**: Phase 7 is fully complete — no open items. The next
piece of work is a fresh pick from CLAUDE.md's own backlog: either Phase 8
("Polish: tiled rendering for large images, perf, edge cases") or one of
the Tier-1 **WANTED** Lightroom-gap items (Texture/Dehaze split — a
breaking-change migration on the already-shipped `definition` field, needs
its own careful Plan Mode session; Grain; Color Grading; Point Color;
Chromatic Aberration removal; Manual Transform Scale/Aspect) — see
CLAUDE.md's "Gaps vs. Adobe Lightroom Desktop" section for the full list
and which are user-confirmed WANTED vs. just researched gaps. Ask the user
which to pick next, same as this session's own opening question.

## Phase 8 / Lightroom Presence: `definition` → `texture` + `clarity` (2026-09-16)

**Shipped.** The first two thirds of CLAUDE.md's Tier-1 WANTED
"Texture / Dehaze" item. The single shipped `EditState.definition` field
was split into two BIPOLAR (-1...1) fields — `texture` (radius fraction
0.01) and `clarity` (0.04) — matching Lightroom's Presence model.
**Dehaze was deliberately deferred to its own slice** (user decision,
asked before planning): it is a different algorithm, not another radius
on `CIUnsharpMask`, and deserves its own measurement pass.

**Three decisions the user made before any code was written:**
1. Scope — migration + Texture + Clarity now, Dehaze separately.
2. Range — BIPOLAR -1...1, matching Lightroom, rather than keeping the
   app's one-directional Definition/Sharpen/NR convention.
3. Dehaze method — decided in the Dehaze slice, from real measurement.

**The migration is the risky part, and it is covered.** `definition` was
live in real sidecars on disk and in saved presets. It survives as a
read-only key in a SEPARATE `LegacyCodingKeys` enum on `EditState`,
decoded into `clarity`. It is deliberately NOT an extra `CodingKeys`
case: Swift's synthesized `encode(to:)` (which `EditState` still relies
on — only `init(from:)` is hand-written) requires every `CodingKeys` case
to have a matching stored property, so a property-less legacy case there
would not compile. **Presets needed no SQL migration** — GRDB serializes
`Preset.editState` through the same decoder, so `Migrations/` is
untouched. Five new tests in `EditStateCodableTests` pin this: legacy key
→ `clarity`, explicit `clarity` beating a stale `definition`, a full
decode→encode→decode round trip, that `definition` is never re-emitted,
and that negative values survive serialization.

**Bipolar needed a second construction, and this is the interesting
part.** `EditState.definition` shipped one-directional because
`CIUnsharpMask` was MEASURED to clamp negative `intensity` to a
bit-identical no-op in this working space — a provably dead half-slider.
So `EditPipeline.localContrast(amount:radiusFraction:amountSpan:to:)` now
owns both halves: `CIUnsharpMask` for positive, a blend toward
`CIGaussianBlur` at the same radius for negative. **Extent hazard,
handled:** `CIGaussianBlur` expands its output extent, and `applyMasks`
resolves mask geometry against this extent — an unhandled expansion would
MISALIGN MASKS, not merely look soft. The negative path clamps to extent
before blurring and crops straight back after; two tests assert extent
and alpha survive.

**`Mask.clarity` became bipolar too** (it shares `localContrast`), range
widened to -1...1 in `MaskDetailView`. Existing 0...1 mask values stay
valid — no migration. Masks still have NO `texture` counterpart, unlike
Lightroom's; logged in CLAUDE.md as a future additive item.

**Texture's radius was MEASURED, not guessed** — swept the real constant
over 0.0025/0.005/0.01/0.02/0.04 on the same 0.2/0.5 step edge the
Clarity and Sharpen constants were measured on, reading peak and
+15/+30/+60px. The full table is in `kTextureRadiusFraction`'s doc
comment. 0.01 is where the halo is measurably wider than a fine sharpen
(0.50955 at +15px vs 0.50032 at fraction 0.005, flat to three places) yet
still local (back to 0.50060 by +30px, where Clarity is 0.55443). Peak
height does NOT separate these controls — all three peak around
0.64-0.66. Width does.

**One honest negative result, recorded as such:** Texture and Clarity
very nearly COMMUTE. Swapping the stages moves the profile by at most
0.00215, only marginally above this suite's own 0.002 `accuracy`
tolerance. So unlike Clarity-vs-Vignette (0.0188, a genuine requirement),
this adjacency is coarse-then-fine by CONVENTION. `applyTexture`'s doc
comment says so plainly rather than dressing a weak number up as a
measured necessity.

**Process note for the next session:** the doc comments were first
written with PLACEHOLDER numbers, then a temporary measurement harness
was added to `EditPipelineTests`, run, and deleted, and every figure
replaced with the real reading. Do not copy measurement-shaped prose
forward without re-running it.

Tests: full suite green (`** TEST SUCCEEDED **`). Existing Clarity tests
kept their measured values unchanged, which is itself the regression
guard that the rename did not move pixels.

**Reviewer round 1: FIX FIRST → all items addressed.** Three BLOCKING
issues, all one class of defect and a genuinely good catch: the comment
sweep had appended "Texture" to three records of PAST LIVE TIMING RUNS
(`ImageRenderer.swift` P3 and P4, `ImageDocumentModel.swift` P5). Those
runs happened when `definition` existed and `texture` did not — they
measured THREE convolution stages, not four. `definition`→`clarity` is a
true rename so that part was correct, but adding `Texture` retroactively
invented a configuration nobody ever ran. Reverted to name only the
stages actually active at measurement time. **Lesson, same one as this
session's other near-miss: a stage rename may be propagated into a
measurement record; a stage ADDITION may not.** Structural claims about
extent-fraction radii (`ProxyScale.swift`, `Histogram.swift`,
`ImageRenderer.swift:97`) correctly do gain Texture — those describe how
radii scale, not what was timed.

Non-blocking items 5, 6 and 7 also fixed: a negative-path highlight-
headroom test (parity with the positive half — a 1.4 flat survives at
1.39873, independently reproduced by the reviewer's own probe), a test
comment aligned with `ProxyScale`'s wording, and two new
`CatalogDatabaseTests` cases closing the preset-migration gap. The
preset tests decode a `Preset` whose `editState` still carries
`"definition"`, rather than inserting a raw row — `CatalogDatabase
.dbQueue` is private and widening production visibility purely for a
test is the worse trade. That covers the nested-decoding step, the only
step the split could have broken; the column plumbing around it is
already covered by `testCreatePresetRoundTripsTheFullEditState`.

**Perf (reviewer item 4 — no measurement existed for this slice).**
Measured at 4000x4000, full `CIContext.createCGImage` over the whole
extent, best of 3. NOTE THE SCOPE: synthetic step-edge image rendered in
the test process. NOT comparable to the live P3/P4/P5 numbers earlier in
this file, which were real interactive drags on real photos — do not
quote these side by side. Mask rows use a `.radial` mask at
center (0.5, 0.5), feather 0.5, rotation 0, at the two radii shown;
**mask cost is dominated by the ellipse's bounding-box ROI, so a record
without the geometry is not reproducible** (reviewer round 2 measured
89.8ms against this entry's original unstated 32.7ms — explained entirely
by mask size).

    baseline                          5.7 ms
    texture  +1 / -1            37.1 / 35.8 ms
    clarity  +1 / -1            48.9 / 48.3 ms
    texture + clarity                92.7 ms
    1 mask r=0.25 clarity +1 / -1   35.6 / 35.1 ms
    3 mask r=0.25 clarity +1 / -1  312.5 / 313.5 ms
    1 mask r=0.90 clarity +1 / -1   82.0 / 83.5 ms
    3 mask r=0.90 clarity +1 / -1 1811.7 / 1757.1 ms

**The reviewer's perf hypothesis was WRONG, and measuring it is how we
know.** It predicted negative `Mask.clarity` would be a new worst case,
since `CIGaussianBlur` at `0.04 * min(extent)` is a ~160px radius at
24MP. Measured: negative and positive are identical within noise at every
geometry and mask count (35.6/35.1, 312.5/313.5, 82.0/83.5,
1811.7/1757.1). `CIUnsharpMask` is internally a blur plus an add, so a
same-radius `CIGaussianBlur` is the cost FLOOR, not a new ceiling. Both
reviewer rounds independently reproduced this.

**Multi-mask Clarity scaling is SUPERLINEAR, and that predates this
slice.** 1 -> 3 masks costs 8.8x at r=0.25 (35.6 -> 312.5) and 22x at
r=0.90 (82.0 -> 1811.7), not 3x — each successive mask's composite
re-dilates the ROI of everything before it. Identical for positive and
negative, so the negative half did not introduce it; it is a property of
per-mask Clarity that has been there since Phase 7 slice 2. Logged in
IMPROVEMENTS.md rather than fixed here. An earlier draft of this entry
called it "linear at ~100ms/mask" — that figure was derived by dividing
the 3-mask number by 3 and then asserted as the per-mask cost (circular),
and was cross-cited to slice 6's 1-19ms drawable-resolution numbers,
which is exactly the cross-scope comparison this same entry forbids two
paragraphs above. Reviewer-caught; the third instance of this defect
class in one session.

The real new cost is simply that **Texture is a second full-image
convolution**: with both sliders active the render is roughly the sum of
each (92.7ms vs 48.9ms for Clarity alone). That is inherent to shipping
two independent local-contrast controls and is exactly what the existing
`ProxyScale` interactive-proxy path already exists to absorb; no new
mitigation was added, and none looks warranted.

**Exact next step (superseded — see the Dehaze section at the end of
this file)**: Dehaze — the remaining third of the Texture/Dehaze
split, and the obvious continuation. Needs its own Plan Mode session; see
CLAUDE.md's "Dehaze — WANTED, still outstanding" bullet for the
constraint already identified (this project's `CIColorKernel(source:)` is
per-pixel and cannot sample neighbours, so a dark-channel-prior approach
needs its spatial part from a built-in such as `CIMorphologyMinimum`).
There is NO Dehaze UI in the app today — no field, no stage, no control;
the Effects section simply runs Texture -> Clarity -> Sharpen, with the
gap where Dehaze would sit. (An earlier draft of this entry said the
panel "leaves Dehaze's slot", which the user reasonably read as a
placeholder existing. Nothing is reserved or greyed out.)

Alternatively: **Curves v2** — the interactive draggable RGB point-curve
editor — added to CLAUDE.md as user-confirmed WANTED on 2026-09-16. Note
WHY it was added late: it was tracked only in the Phase 2 backlog, never
tagged WANTED, and so did not appear when next-slice candidates were
listed; the user asked where it was. It fixes a recorded v1 defect
(`applyCurves` clamps highlight headroom above 1.0 when active) and
carries the same class of shipped-field migration this Texture/Clarity
slice just solved, so reuse the `LegacyCodingKeys` pattern.

Or another Tier-1 WANTED item (Grain, Color Grading, Point Color,
Chromatic Aberration, Manual Transform Scale/Aspect), or Phase 8 polish,
or IMPROVEMENTS.md D16 (superlinear multi-mask Clarity). Ask the user —
and read BOTH the Lightroom-gaps section AND the Phase 2 backlog when
listing candidates.

## Phase 8 / Lightroom Presence: Dehaze (2026-09-16)

**Shipped.** The Presence panel is now COMPLETE — Texture, Clarity and
Dehaze. A real DARK CHANNEL PRIOR (He, Sun & Tang, CVPR 2009), not the
"composite approximation" fallback that was on the table: Core Image
ships no dehaze filter, so it is built from two NEW custom kernels
(`DehazeDarkChannel.cikernel`, `DehazeRecover.cikernel` — the third and
fourth in this codebase) plus `CIAreaMaximum` and `CIMorphologyMinimum`.
Bipolar -1...1; negative adds haze by blending toward the same estimated
atmospheric light, which is why bipolar was nearly free to IMPLEMENT (no meaningful render-cost difference either way — see D17).

**The design problem and its solution.** A `CIColorKernel` cannot sample
neighbours, and the dark channel prior is inherently a neighbourhood
operation. Split it: the per-pixel half (cross-channel min of I/A) is a
kernel, the spatial half is `CIMorphologyMinimum` BETWEEN the two
kernels. `DehazeRecover.cikernel` is also the first kernel here to take
THREE `__sample`s (image, dark channel, atmosphere) — verified as
possible during planning before committing to the design, not assumed.
`DehazeDarkChannel.cikernel` already takes two, so it is not the first to
exceed one.

**Atmospheric light stays on the GPU**: `CIAreaMaximum` reduces a blurred
copy to 1x1 and `.clampedToExtent()` spreads it back into a constant
field usable as a sampler. Blurring FIRST is deliberate — the raw maximum
of a photo is whatever single brightest pixel exists, which is not the
atmosphere.

**Identity at 0 is exact — but because the stage is SKIPPED, not because
the maths round-trips.** Reviewer-corrected, and the correction matters:
`(I - A)/1 + A` is NOT identity in float32 (measured, 265 of 1024
components differ on a 256-value ramp, max delta 2.98e-08; a full float32
sweep mismatches ~17%). Exactness comes entirely from `dehazeActive`'s
`state.dehaze != 0` gate. That guard is load-bearing — remove it in a
future refactor and identity silently breaks. The original write-up
credited the amount fold, which was the wrong mechanism for a real
observation.

**A silent failure caught early, worth remembering.** The first probe
showed Dehaze doing NOTHING at every amount — identical output for
amounts 0 through 1. Cause: new `.cikernel` files need `xcodegen
generate` before they are bundled as resources; `Bundle.main.url` then
returns nil and `applyDehaze`'s fail-soft path silently returns the input
unchanged. The fail-soft is correct (it matches `applySelectiveColor`'s
precedent) but it means **a missing kernel looks exactly like a working
identity**. Run `xcodegen generate` after adding any shader.

**Test fixtures had to be designed, not just written.** Two iterations
were wrong before the third worked:
1. A two-level hazy step edge cannot round-trip, because A is ESTIMATED
   from the image: the bright level gets mistaken for the atmosphere. Fix:
   make the bright level actually BE the sky (0.90 = A).
2. A step edge cannot demonstrate radius scaling at all for a MIN filter
   — a patch-min over a flat region is radius-independent, and the first
   two attempts both returned identical values at every size, which would
   have "passed" while proving nothing. Fix: measure the EROSION the min
   filter cuts into the bright side, at a fixed PIXEL offset, and assert
   the same FRACTIONAL offset agrees across sizes while the same pixel
   offset does not (400/800 -> 0.900878, 1600 -> 0.900135).

A third fixture problem was reviewer-caught TWICE, and the second catch
matters more than the first. The zero-amount test was tautological as
written; the "fix" — comparing `EditState(exposureEV: 0.5, dehaze: 0)`
against `EditState(exposureEV: 0.5)` — was tautological too, because those
are the SAME VALUE (`dehaze` defaults to 0). The reviewer proved it by
commenting out the `dehazeActive` guard and watching the test still pass.
A third round then showed my disclaimer ("no assertion can detect the
gate") was ALSO wrong, and fixture-specific rather than fundamental:
Sterbenz gives that `(I - A) + A` is exact WHENEVER A/2 <= I <= 2A —
sufficient, not necessary — and with
A ~ 0.9 that window contains 0.55 but excludes 0.2. Changing the dark
level from 0.55 to 0.2 makes the test genuinely cover the gate —
fault-injection confirmed here, not just accepted: with the guard
commented out it now FAILS with "0.19999999 is not equal to 0.2".
Lesson, learned three times in one slice: when a test is called
tautological, check whether the REPLACEMENT is too — and when you write a
disclaimer explaining why something cannot be tested, check that too.

**Ordering is genuinely measured here**, unlike Texture/Clarity's
convention-only adjacency: Dehaze runs BEFORE Vignette and Clarity, and
swapping either moves the result by 0.4+ (vs Texture/Clarity's 0.00215).
Reviewer independently reproduced both deltas to 7 significant figures
(0.5227467 and 0.4278953) with a double-apply control at 0.0 confirming
the delta is ordering and not the nested `apply`.

**Domain is a PRINCIPLED choice, labelled as such, not a measured one.**
Dehaze runs in scene-linear with no perceptual sandwich because the haze
model is defined on radiance. A perceptual A/B was NOT run. An earlier
draft of `applyDehaze`'s doc comment said "MEASURED both ways — see this
stage's tests," which was a fabricated measurement with a dangling
citation (no such test exists) that also contradicted this very file.
Deleted rather than reworded: the principled framing needs no
measurement.

**PERF — read the methodology warning before quoting any number.**
The robust finding is that Dehaze is the most expensive Presence stage
and that it combines superlinearly with CLARITY specifically (Vignette
shows no excess; Texture is mild). **Absolute numbers do not reproduce**:
three methodologies gave 78.9 / 116.5 / 148.7 ms for the same
configuration at 4000x4000, with the Dehaze+Clarity excess landing at
1.7x / 2.1x / 3.7x. One run measured `dehaze+clarity+texture` as CHEAPER
than `dehaze+clarity`.

**The trap, and the reason three claims in the first draft were wrong:** a
harness sharing one `CIContext` across configurations lets later
configurations hit subgraphs earlier ones cached — and every dehaze
configuration shares the atmospheric-light blur. **Interleaving does not
fix this; it CAUSES it.** Use a fresh `CIContext` per measurement, or one
configuration per process.

Three claims withdrawn, all from that one mistake, all recorded in
IMPROVEMENTS.md D17 so they are not re-derived: negative is NOT ~4x
cheaper (within 1% with isolated contexts, and no dead-code pruning
happens); `CIAreaMaximum` IS a significant cost (~25% per the reviewer,
not "unchanged" — the substitution test was confounded, since removing
the area maximum also removes the Gaussian feeding it); and
`.insertingIntermediate()` is neutral, not a 30% regression.

**A real finding the review process produced — and it outgrew this
slice.** Round 4 caught that `ProxyScale.swift` claims downscaled
rendering is "correct, not an approximation, for every stage except Noise
Reduction", contradicting a note I had just added. Measuring it rather
than rewording invalidated the FRAMING, not just Dehaze's place in it:
that claim was wrong before Dehaze existed. Verified against HEAD with
git rather than assumed — an earlier draft of this paragraph said it
appeared in FOUR places and that `ThumbnailGenerator` was the precedent
the other three cite. Both were wrong: the exact claim was in TWO files
(`ProxyScale`, `ImageDocumentModel`), `ImageRenderer` cites `ProxyScale`,
and the other two carried weaker related overstatements. Four sites were
corrected regardless; `ThumbnailGenerator` was flagged in round 5 and
corrected in round 6.

Getting the measurement right took three attempts, and the first two
failures are the same trap this slice hit repeatedly: a step edge has a
uniform bright half (A is 0.90 at every scale by construction) and
`quadrantImage` is saturated colors with a zero dark channel (dehaze is
identity). Both returned exact zeros that proved nothing. A third probe
worked but did not match the SHIPPED path — `ProxyBuilder` clamps to
extent before Lanczos and mine did not, which overstated the 0.5 figure
by 39% (reviewer-caught). The final matrix, measured the way the app
actually downscales, is in IMPROVEMENTS.md D18.

Three conclusions the old framing did not support: all FOUR measured
stages diverge (Clarity, cited as the correct-by-construction case, is
merely smallest — texture/vignette/red-eye were not measured and nothing
is claimed about them); Noise Reduction is not uniquely bad, and diverges
for the OPPOSITE reason, having deliberately no extent term at all; and
Dehaze diverges for a reason the others do not share, since A is a
whole-frame statistic rather than extent-derived geometry. Rank swaps with
scale AND with content — on photo-like content Dehaze leads at every
scale measured, including 0.5 where NR leads on the noise fixture. Practical consequence, accepted not fixed: a
Library thumbnail of a dehazed photo can visibly differ from the Editor.

A comparative claim I made and had to withdraw twice over: "roughly 7x
Clarity, at the same scale" was BOTH scale-mismatched (it paired
dehaze@0.5 with clarity@0.25) and framed backwards — the "upper bound"
caveat covers magnitude, but the RATIO rises on photo-like content rather
than falling. The four doc sites now cite D18's matrix instead of each
carrying their own numbers, which is what made them drift apart in the
first place.

**Known limitation, now recorded**: no refinement of the transmission map
(the paper's soft matting, or the usual guided-filter substitute), so
transmission is blocky at the patch scale and will halo at sharp depth
discontinuities. A real quality gap, not a tuning choice.

Tests: 931 green.

**LIVE-VERIFIED (2026-09-17).** Driven via AX actions (synthetic
`cliclick` events still do not reach this app — confirmed again this
session, same limitation slice 5 and the Texture/Clarity slice logged).
Both test images were COPIES; the user's own files were diffed against
backups afterward and are byte-identical.

**Ground-truth test, because a real hazy photo was not available.** Built
one from a real outdoor JPEG by applying the haze model itself in numpy —
`I = J*t + A*(1-t)`, A = (0.82, 0.85, 0.90), with t ramped 1.00 -> 0.25
across the frame so transmission VARIES rather than being a flat wash.
Opened it in the app and set Dehaze +100. Measured off the rendered
window, by band:

    band            transmission    mean delta   contrast (sd)
    top             t = 1.00 clear        3.6    41.8 -> 42.3
    upper-mid                            14.7    47.0 -> 52.7
    lower-mid                            33.8    28.0 -> 40.4
    bottom          t = 0.25 hazy        51.6    11.2 -> 20.8

That is the result worth having: correction grows ~14x from the clear
band to the hazy one, and contrast nearly doubles where haze was heaviest
while the clear band is left alone. **A global contrast boost would have
moved all four bands equally** — this is genuinely depth-aware, which no
unit test in this slice demonstrates. Negative Dehaze was also confirmed
live and is unmistakable (the frame washes toward the atmospheric light).
`dehaze: 1` persisted to the sidecar; Revert to Original cleared it back
to identity, checked on disk.

**A REAL LIMITATION found live, not previously documented: Dehaze does
essentially nothing on UNDERWATER photos.** Tried first on a real diving
shot, chosen precisely because it looked hazy. At Dehaze +100 the open
water measured a delta of EXACTLY 0.00 — the region that most looks hazy
got no correction at all. This is the algorithm behaving correctly and
the PRIOR not fitting: water absorbs red, so `min(r,g,b)` is already near
zero and the dark channel reports "not hazy." It is the textbook failure
case for dark channel prior, and the reason underwater work uses modified
priors that skip the red channel. Logged as IMPROVEMENTS.md D19. Worth
knowing before anyone reports Dehaze as broken — on the scene type it was
designed for it works well, as the table above shows.

Second observation from the same photo, related and also unlogged until
now: the atmospheric light A is estimated as the area-maximum of a
blurred copy, which finds the brightest REGION — not necessarily the haze
colour. On that underwater frame negative Dehaze washed toward a warm
cream, not the scene's blue-green, because a bright warm highlight won
the maximum. `kDehazeAtmosphereBlurFraction`'s doc comment already calls
this "the cheap stand-in for the paper's own brightest-0.1%-of-the-dark-
channel selection"; this is what that shortcut costs in practice.

**Exact next step (superseded — see the Curves v2 pre-work section at
the end of this file)**: **Curves v2** — the interactive draggable RGB
point-curve editor, which the user chose as the follow-on to Dehaze when
picking this slice. See CLAUDE.md's Tier-2 entry: it fixes a recorded v1
defect (`applyCurves` clamps highlight headroom above linear 1.0 whenever
active, unlike every other stage), unblocks the pending Shadows/
Highlights split-out decision, and carries the same shipped-field
migration shape the `definition` -> `texture`/`clarity` split solved —
reuse that `LegacyCodingKeys` pattern. Needs its own Plan Mode session;
the UI is the hard part (draggable spline canvas with point hit-testing
and a channel selector), not the maths.

## Curves v2 slice 1 — pre-work: CIToneCurve fully reverse-engineered (2026-09-17)

**No code written. This section exists so the next session does not
re-derive a result that took three probes to get right.**

Curves v2 slice 1 (per its approved plan: replace `CIToneCurve` with a
custom spline kernel, editor second) rested on one unknown — the suite
hard-codes ~70 values measured off `CIToneCurve`'s undocumented spline
(`0.02534`, `0.00383`, ...) across four shipped features (global
Shadows/Highlights, Black Point, Brilliance, per-mask Shadows/Highlights),
so "behaviour-preserving" could not be assumed. It has now been measured:

    CIToneCurve = sRGB-encode
                  -> NATURAL CUBIC spline (control points live in sRGB space)
                  -> sRGB-decode

Verified to **0.00000 error** at every control point and across a
128-sample sweep, on four control configurations (shadows +/-1,
highlights +1, black point +1).

**Consequences — this is the good outcome, not the fallback:**
- A custom kernel can be BYTE-EXACT. The ~70 existing assertions pass
  untouched and become a real regression gate.
- **Saved edits render identically** — no user-visible change to anyone's
  existing photos, which was the risk that made this a user decision.
- The ONLY intended behaviour change is the headroom fix: linear
  extrapolation beyond the endpoints instead of the internal LUT clamp.
  Clamp re-confirmed live this session: inputs 1.0 / 1.2 / 1.5 / 2.0 all
  return ~1.0.

**How it was found, because two of the three probes were wrong and the
first would have led to the wrong decision.**
1. Fitted Catmull-Rom and monotone cubic against the filter sampled in
   the LINEAR working space. Errors 0.16-0.25, one absurd 11.5. Read
   naively this says "cannot replicate — accept a large behaviour change
   and re-baseline every test."
2. Instead of believing it, dumped the RAW response: at control point
   (0.25, 0.40) the filter returned 0.23731. **The filter does not pass
   through its own control points**, so the probe was wrong, not the
   conclusion. Hypothesis: it converts colour space internally.
3. Fed it the linear value whose sRGB encoding equals each control
   point's x — error 0.00000 at all five. Control points are in sRGB.
   Re-fitting the spline in THAT space: monotone cubic 0.016,
   Catmull-Rom 0.046, **natural cubic 0.00000**.

Lesson, the third time this project has hit it (see the Dehaze radius
tests and the proxy-divergence probes): **check the fixture measures what
you think before trusting what it says.** A confidently wrong probe is
worse than no probe.

**Exact next step**: implement `Sources/Rendering/Shaders/ToneCurve.cikernel`
to exactly that recipe — encode, natural cubic in sRGB, decode — with
linear extrapolation past the endpoints. `applyCurves` keeps its
signature and call sites so the four dependent features need no edits.
Then the headroom test, written so it FAILS against the old path. Run
`xcodegen generate` after adding the shader (a missing `.cikernel` fails
soft and looks exactly like a working identity — the Dehaze lesson), and
start the session from `~/photoapp-starter` so the project's own
`reviewer` agent registers.
