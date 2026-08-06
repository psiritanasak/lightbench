# Progress

## Current phase
**Phase 2 (Edit engine) is COMPLETE. Phase 3 (non-destructive pipeline) has
STARTED — first slice (in-memory Undo/Redo) shipped, see below; disk
persistence of edit state/history is still deferred.** The original six
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

### Sidebar content-shift-on-scroll bug + HSplitView divider drift (complete, verified live) — the deferred cosmetic item revisited
- User asked to revisit the `HSplitView` divider drift previously logged as
  low-priority/deferred. Live investigation (many rounds of build → relaunch
  → user tests → report back, the established pattern for UI bugs this
  session) revealed it was actually TWO separate, unrelated bugs conflated
  under one symptom description:
  1. **Divider drift on first photo load** — the ACTUAL divider position
     issue originally deferred. Root cause: `MetalImageView`'s underlying
     `MTKView` wasn't opting out of intrinsic content sizing, so `HSplitView`
     could pick up a content-dependent sizing signal from it the FIRST time
     it had a real drawable/texture, differing from its signal while empty —
     a one-time settling event (never recurs after the first photo). Fixed
     by overriding `intrinsicContentSize` on `ResizingMTKView` to always
     report `NSView.noIntrinsicMetric` on both axes — the view's layout is
     now governed purely by its SwiftUI-provided frame, never by content.
  2. **A completely different bug, initially mistaken for the same thing**:
     sidebar CONTENT (not the divider) shifting left by a few points,
     specifically the first time the user actually SCROLLS the sidebar
     (not on photo-open at all — that red herring cost several rounds
     before the user pinned down the real trigger via direct testing).
- **This second bug is a genuinely hard-won diagnosis** — five different
  plausible-sounding fixes were tried and FAILED before the real cause was
  found: matching padding to measured tab-bar height (already shipped for a
  different bug, didn't touch this one), forcing `.frame(maxWidth: .infinity)`
  on the content, hiding scroll indicators (`.scrollIndicators(.hidden)`,
  later removed again — never the actual fix), and a first attempt at
  forcing `scrollerStyle = .overlay` ONCE at view creation (insufficient,
  see below). Standard SwiftUI-level tools were exhausted without success.
- **Root cause only found by dropping to REAL measurement** — a temporary
  `.onGeometryChange`-based diagnostic (logging to a file, since sandboxed
  apps can't write outside their container: `NSTemporaryDirectory()`
  resolves to a writable path inside the sandbox that's still readable from
  outside it) proved the sidebar's own frame WIDTH never actually changed;
  a follow-up `CGRect`-based probe caught the content's X-ORIGIN shifting by
  exactly 8pt, and — critically — a probe logging `NSScrollView.scrollerStyle`
  directly caught it MOMENTARILY REVERTING to `.legacy` (raw value 0)
  DURING an active scroll gesture, even after being explicitly set to
  `.overlay` at view creation. AppKit's `NSScrollView.automaticallyAdjustsContentInsets`
  (default `true`) and `scrollerStyle` get lazily RE-ASSERTED mid-scroll,
  not just once at initial layout — a one-time override doesn't survive that.
- `Sources/UI/ContentView.swift` — new `StableScrollInsets: NSViewRepresentable`,
  a zero-size AppKit probe placed in the sidebar's `ScrollView` content that
  walks up to the enclosing `NSScrollView` (SwiftUI's `ScrollView` doesn't
  expose it directly) and CONTINUOUSLY re-applies zero content insets +
  `.overlay` scroller style on every scroll event (via the clip view's
  `boundsDidChangeNotification`), not just once — that continuous
  reapplication, not the setting itself, is what actually fixes it.
- **First reviewer pass was FIX FIRST — four real AppKit-interop hygiene
  gaps**, all fixed: (1) the notification observer was never torn down —
  added a `Coordinator` + `dismantleNSView`; (2) the one-shot registration
  attempt could silently never activate if `enclosingScrollView` was still
  nil on the first tick — now retried from `updateNSView` (fires on every
  `EditState` change) guarded by a `didRegister` flag; (3) `updateNSView`
  unconditionally rewrote three AppKit properties on every call, including
  during rapid slider-drag re-renders (this app's hottest UI path) — added
  equality guards (manual field-by-field comparison for `NSEdgeInsets`,
  which isn't `Equatable`) so it's a cheap no-op once already correct;
  (4) hardcoding `.overlay` silently overrides a user's system "Always show
  scroll bars" preference for this one view — now explicitly documented as
  a deliberate trade-off (reviewer agreed: honoring that preference here
  would literally reintroduce the bug for exactly the affected users, since
  legacy style reserving space IS the mechanism causing the shift). Second
  pass independently verified all four fixes (including confirming
  `NSEdgeInsets()` actually compiles to a zero-valued struct rather than
  assuming it) and APPROVEd.
- All temporary diagnostic instrumentation (the file-logging helper, the
  `.onGeometryChange` probes, verbose per-call diagnostic logging inside the
  scroll-view fix itself) was removed before commit — only the clean,
  minimal, hardened fix shipped.
- 226 tests unchanged (pure AppKit-interop/layout code, no `EditState`/
  `EditPipeline`/color-math touched). 1 commit (both fixes + the FIX FIRST
  hardening together, after user confirmed each fix live across several
  separate rebuild-and-relaunch rounds).

## Open reviewer issues
None — last reviewer verdict was APPROVE (sidebar content-shift-on-scroll +
HSplitView divider drift fixes, second pass after one FIX FIRST round of
AppKit-interop hygiene fixes — see "Sidebar content-shift-on-scroll bug +
HSplitView divider drift" above). The previously-deferred divider-drift
item is now fixed, not deferred. One non-blocking observation carried
forward from the Undo/Redo review (still not required to fix): the global
⌘Z toolbar shortcut may intercept a focused text field's native undo;
worth a manual check, not a correctness bug. Also non-blocking, noted by
the reviewer during the scroll-fix pass: for users with "Always show
scroll bars" configured system-wide, a MORE robust future fix might give
the sidebar a stable, never-toggling reserved inset from the start
(avoiding both the shift bug AND the accessibility trade-off of forcing
overlay style) — a design improvement, not required now.

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

## In progress / blocked
Nothing blocked. Nice-to-have not yet eyeballed (low risk, not required):
window-resize re-fit behavior, opened-file mtime check.

## Exact next step
**Phase 2 is COMPLETE** (every backlog item ✅, see above). **Phase 3 has
STARTED**: in-memory Undo/Redo (first slice) is done — see the "Undo/Redo"
section above. **RGB channel histograms are also done** — see "RGB channel
histograms" above. **All known sidebar layout bugs are now fixed** —
top-clearance padding, scroll-anchor, the sidebar content-shift-on-scroll
bug, AND the previously-deferred HSplitView divider drift (revisited and
fixed, not deferred anymore — see "Sidebar content-shift-on-scroll bug +
HSplitView divider drift" above). 226 tests passing, last reviewer verdict
APPROVE (second pass, after one FIX FIRST round of AppKit-interop hygiene
fixes on the scroll-insets fix).

**Nothing is currently planned.** The sidebar-regrouping idea (Apple-
Photos-style labeled sections — Light/Color/B&W/etc — vs. today's flat
slider list) remains confirmed NOT built and explicitly deferred (was
offered as an alternative to the RGB histogram, not picked) — don't start
it without the user asking again.

**Still outstanding — Undo/Redo functional manual verification, not yet
done** (flagged when the slice shipped; only the toolbar-crowding VISUAL
bug got checked/fixed so far during this pass, not the undo/redo mechanics
themselves): this environment has no GUI automation tool for a native
macOS app, so live interactive testing of the undo/redo feature could not
be completed here. Confirm live:
- A continuous slider or crop drag coalesces into exactly ONE undo step
  (not hundreds) — drag Exposure, pause, drag Contrast → ⌘Z should revert
  Contrast as one step, ⌘Z again should revert Exposure.
- ⇧⌘Z redoes each step correctly; Undo/Redo toolbar buttons enable/disable
  correctly as history changes.
- A crop drag, a toggle (B&W), a red-eye tap, an aspect-preset snap, and a
  per-slider "Reset" each become exactly one undoable step.
- The WB eyedropper and "Fix Color Cast" results are each undoable as one
  step.
- Opening a NEW photo clears history (can't undo into the previous photo).
- Undo/redo correctly updates the live histogram.
- Check the reviewer's one non-blocking note: does the global ⌘Z shortcut
  interfere with a focused crop-inset numeric text field's own native
  undo? (Not expected to be an issue, but unverified.)

**After that's confirmed, remaining options for what's next** (ask the user
which, don't guess): (1) continue Phase 3 — a standalone "Revert to
Original" button (trivial, `EditState()` reset already exists on load) was
explicitly deferred as its own small item during this slice's scoping, or
Edit-menu `CommandGroup(replacing: .undoRedo)` integration (would need
lifting `@StateObject document` to `PhotoAppApp`) as a documented v1 gap
from this slice; (2) disk persistence of edit state/history — explicitly
deferred pending the Phase 4 catalog DB (`Sources/Catalog/` is still empty);
(3) Phase 4+ (Library/import/catalog, Presets+export, RAW support, Polish)
per CLAUDE.md's roadmap. Lens distortion correction remains explicitly OUT
of scope (needs camera-profile data, a separate concern) unless the user
asks for it specifically. Starting Phase 4 (a new phase) needs its own
explicit go-ahead and Plan Mode session per CLAUDE.md's roadmap-order rule;
continuing within Phase 3 (revert button, persistence, menu integration)
is more of the same phase but each is still its own feature/session per the
"one feature per session" rule.

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
