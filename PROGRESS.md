# Progress

## Current phase
Phase 2 (Edit engine) — the original six roadmap items plus four backlog
additions (Brightness, Black Point, Brilliance, Vibrance) are shipped, each
reviewer-approved and manually verified live. The roadmap in CLAUDE.md was
expanded three times at the user's request to spell out the fuller scope:
first adding Transform/Distort and v2 notes for curves/HSL/crop, then using
Apple Photos' adjustment panel (screenshots the user shared) as a
completeness reference, then again refining Transform/Distort and Crop v2
against Photos' specific Crop-panel controls (Straighten, Vertical/Horizontal
perspective, Flip, concrete aspect-ratio preset list). Full detail lives in
CLAUDE.md's "Phase 2 edit engine backlog" section — do not duplicate it here,
just read it there. Summary of what's NOT built yet: Cast, Black & White
mode, Red-Eye removal, a WB neutral-gray eyedropper, Levels,
Definition/Clarity, Selective Color (= HSL v2, per-band panel), Noise
Reduction, Sharpen, Vignette, Transform/Distort (straighten +
vertical/horizontal perspective + lens distortion), Flip, and Crop v2
(interactive overlay + concrete aspect presets).

Not yet decided which to build next — needs a Plan Mode session per feature
as usual, one at a time. Phase 3 (non-destructive pipeline: param
serialization, edit history, undo) remains after Phase 2's expanded scope is
done, and also needs its own explicit go-ahead when reached.

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

## Open reviewer issues
None — last reviewer verdict was APPROVE (Vibrance, second pass after one
FIX FIRST round). Every shipped Phase 2 feature and backlog addition has a
clean final reviewer verdict.

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
**The original six Phase 2 roadmap items are done; backlog work continues.**
Brightness, Black Point, Brilliance, and Vibrance have since shipped (see
above). Remaining not-built backlog: Cast, Black & White mode, Red-Eye
removal, WB neutral-gray eyedropper, Levels, Definition/Clarity, Selective
Color (HSL v2), Noise Reduction, Sharpen, Vignette, Transform/Distort, Flip,
Crop v2 — no next item chosen yet, needs the user's pick each time. Do not
start Phase 3 (non-destructive pipeline: param serialization, edit history,
undo) without the user's explicit go-ahead — starting a new phase always
needs its own Plan Mode session per CLAUDE.md's roadmap-order rule.

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
