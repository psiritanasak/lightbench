# Progress

## Current phase
Phase 2 (Edit engine) — the original six roadmap items, five backlog
tone/color additions (Brightness, Black Point, Brilliance, Vibrance,
Vignette), Crop v2's drag-handle rectangle, Flip, Straighten,
Vertical/Horizontal perspective correction, and a grid guideline overlay
are shipped, each reviewer-approved and manually verified live. The roadmap
in CLAUDE.md was expanded three times at the user's request to spell out
the fuller scope: first adding Transform/Distort and v2 notes for
curves/HSL/crop, then using Apple Photos' adjustment panel (screenshots the
user shared) as a completeness reference, then again refining
Transform/Distort and Crop v2 against Photos' specific Crop-panel controls
(Straighten, Vertical/Horizontal perspective, Flip, concrete aspect-ratio
preset list). Full detail lives in CLAUDE.md's "Phase 2 edit engine
backlog" section — do not duplicate it here, just read it there. Summary of
what's NOT built yet: Cast (deliberately deferred — see below), Black &
White mode, Red-Eye removal, a WB neutral-gray eyedropper, Levels,
Definition/Clarity, Selective Color (= HSL v2, per-band panel), Noise
Reduction, Sharpen, and Crop v2's aspect-ratio presets.

**User has explicitly requested the FULL feature set** to match an Apple
Photos Crop-tool screenshot they shared (dark theme, top tab bar —
Adjust/Filters/Crop/Clean Up — right-side per-tool panel with
Straighten/Vertical/Horizontal/Flip/Aspect controls, Auto/Reset/Done
buttons) — not just a visual restyle. Sequenced as separate features (one
Plan Mode session/reviewer pass/commit each, per CLAUDE.md's one-feature-
per-session rule), cheapest/foundational first:
1. ✅ Flip — done (see below).
2. ✅ Straighten (rotation angle) — done (see below).
3. ✅ Vertical + Horizontal perspective correction (keystone) — done (see below).
4. ✅ Grid guideline overlay for Straighten/Vertical/Horizontal — done (see
   below), including a follow-up contrast fix (dark shadow stroke under the
   white lines so they stay legible over bright image content). User asked
   whether the grid should also warp/rotate to follow the photo's
   transformed shape — checked against the real Apple Photos app and
   confirmed the grid stays static while the photo moves underneath it, so
   no additional geometry work was needed.
5. **Crop v2 aspect-ratio presets — NEXT.** User shared a second Photos
   screenshot (the Crop panel with Straighten/Vertical/Horizontal/Flip/
   Aspect all visible, "Freeform" checked) and asked to match that look AND
   switch the app to dark mode. This bundles TWO remaining queued features —
   the aspect-ratio preset list needs to actually work (Original, Freeform,
   Square, 16:9, 4:5, 5:7, 4:3, 3:5, 3:2, Custom, constraining the existing
   `CropOverlayView` drag rectangle to a fixed ratio) before the dark-theme
   layout can meaningfully display it. Doing presets first, then the layout.
6. Layout redesign (dark theme + tab bar shell) — once presets exist to
   display; the immediate trigger for tackling this now was the user's
   screenshot + explicit "change app color to dark mode" request.
Lens distortion correction (also listed under Transform/Distort in
CLAUDE.md's backlog) is explicitly OUT of this batch — it wasn't in the
screenshot and needs camera-profile data, a much bigger, separate concern;
flag to the user if they want it included later.

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

## Open reviewer issues
None — last reviewer verdict was APPROVE (grid guideline overlay + contrast
fix, first pass, no issues found). Every shipped Phase 2 feature and
backlog addition has a clean final reviewer verdict.

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
**User chose option 3 (full feature parity) for the Apple Photos-style
layout request.** Flip, Straighten, Vertical/Horizontal perspective
correction, and the grid guideline overlay are all done (see "Current
phase" above for the full sequence). **NEXT: Crop v2 aspect-ratio
presets — feature 5.** Triggered by the user sharing a second Photos
screenshot (the full Crop panel: Straighten/Vertical/Horizontal/Flip/Aspect,
"Freeform" checked) and asking to match that look plus switch the app to
dark mode. Not yet planned. Needs a real design session: how a preset
constrains the ALREADY-SHIPPED `CropOverlayView` drag rectangle (locking
the aspect ratio while still allowing drag-to-resize/reposition — e.g.
dragging a corner handle should resize proportionally rather than freely),
the exact preset list (Original, Freeform, Square, 16:9, 4:5, 5:7, 4:3,
3:5, 3:2, Custom — concrete list already pinned in CLAUDE.md's backlog),
and how "Original" should behave when the photo has already been rotated/
keystoned (constrain to the CURRENT displayed aspect ratio, not the raw
file's). UI-only, no color-math risk, but real interaction-design work —
likely direct-design like Flip/Crop v1 (closed-form geometry: constraining
a drag rectangle to a fixed ratio), not needing a Plan agent dispatch.

**Then: the dark theme + tab-bar layout redesign — feature 6, the
immediate trigger for revisiting this area was the user's explicit "change
app color to dark mode" + screenshot request.** Once aspect presets exist
to actually populate the Crop panel shown in the screenshot.

Beyond this batch, remaining not-yet-built backlog: Cast (deliberately
deferred — see below), Black & White mode, Red-Eye removal, WB
neutral-gray eyedropper, Levels, Definition/Clarity, Selective Color (HSL
v2), Noise Reduction, Sharpen, and lens distortion correction (explicitly
left out of the current batch — wasn't in the user's screenshot, needs
camera-profile data, a separate concern).

Cast was deliberately passed over (not forgotten) when picking a feature
after Vibrance: it's the one remaining backlog item that breaks the
established pure-per-pixel-filter architecture — its distinction from White
Balance is *content-awareness* (neutralizing a DETECTED cast, needing
per-image statistics like a gray-world average, not just a stateless
per-pixel transform), which deserves its own deliberate design pass rather
than reusing the existing pattern. Still not built; pick it up when ready to
design that content-aware machinery properly.

Do not start Phase 3 (non-destructive pipeline: param serialization, edit
history, undo) without the user's explicit go-ahead — starting a new phase
always needs its own Plan Mode session per CLAUDE.md's roadmap-order rule.

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
