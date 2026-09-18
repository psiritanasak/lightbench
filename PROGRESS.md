# Progress

Full session-by-session history (every completed feature/slice, reviewer
rounds, live-verification detail, measured numbers) lives in
`docs/PROGRESS_HISTORY.md`. This file is deliberately short — see CLAUDE.md's
"Quota / safe-pause discipline" section for why: it should always be readable
in one pass when resuming after a cutoff, not accumulate into another log.

## Current phase
Phase 2 (Edit engine) through Phase 7 (Local Adjustments/Masking) are all
✅ FULLY COMPLETE, Curves v2 (Tier-2 Lightroom gap) is fully shipped,
reviewed, and live-verified, and **Grain** (Tier-1 Lightroom gap) is
shipped. **Color Grading (Tier-1 Lightroom gap) is now FULLY SHIPPED** —
both Slice A (backend: 9 `EditState` fields, `ColorGrading.cikernel`, the
`applyColorGrading` pipeline stage) and Slice B (the color-wheel UI:
`ColorWheelGeometry`, `ColorGradingWheelView`, `ColorGradingRange`, wired
into a new "Color Grading" section in `AdjustTabView`) are committed,
reviewed (Slice A: 2 rounds; Slice B: 3 rounds, FIX FIRST → FIX FIRST →
APPROVE), and all 1088 tests pass. See CLAUDE.md's Color Grading entry for
the full reviewer-round write-up. NOT yet live-verified — the
`AngularGradient` painted-wheel convention is DERIVED from documentation,
not confirmed on screen; see IMPROVEMENTS.md D20 for the separately-logged
keyboard/AT/numeric-readout gap (Hue/Saturation are pointer-only with no
value display; only Luminance has a real slider). See CLAUDE.md's roadmap
for the full phase list and `docs/ROADMAP_HISTORY.md` for detail on
anything already shipped.

## Open reviewer issues
None currently open or blocking. Every reviewer round on record ended in
APPROVE before its commit, per this project's workflow rule. A handful of old,
explicitly non-blocking nits (pre-Phase-6 era — e.g. `selectedPhotoIDs` not
pruned on every `refresh()`, no index on `collection.folderPath`, no
symlink-loop guard in `PhotoImporter.scanNode`) were carried forward for a
long time without being escalated or acted on; see `docs/PROGRESS_HISTORY.md`
if picking up cheap cleanup work, but none of them block anything current.

**Process note**: the project's `reviewer` agent only registers when the
session is started from `~/photoapp-starter`, not `~` — this has caused a
review to silently fall back to a general-purpose agent twice. Start sessions
from the project root.

## Done
Phases 1–7 (Foundation, Edit engine, Non-destructive pipeline, Library,
Presets + export, RAW support, Local Adjustments/Masking) are all shipped,
reviewed, and live-verified — see CLAUDE.md's roadmap for the one-line
summary of each and `docs/ROADMAP_HISTORY.md` for full detail. Also shipped:
all of the Phase 2 edit-engine backlog, the Tier-1 Lightroom gaps
Texture/Clarity and Dehaze, and all of Curves v2 (slices 1, 2A, 2B, and 3 —
backend and UI, fully shipped and live-verified). Every numbered
IMPROVEMENTS.md item marked SHIPPED there is also done — that file is the
source of truth for the perf/polish backlog, not duplicated here.

**Grain (2026-09-17)**: single Amount slider, the pipeline's new true
final stage (after Sharpen and Noise Reduction — see below). New
`FilmGrain.cikernel` (7th custom kernel in this codebase) blends a
`CIRandomGenerator` noise field, monochrome by construction (same delta on
r/g/b), weighted by a principled `4*L*(1-L)` tonal curve that vanishes at
pure black/white and above highlight headroom.

This slice went through TWO full reviewer rounds because the first round's
own FIX FIRST fixes shipped a genuine, more serious bug than the one being
fixed — worth recording in full since the failure mode is subtle and
could recur. Round 1 (self-caught before any review): `CIRandomGenerator`
fed through `CIColorClamp` then `CIColorMatrix` (to force the noise
opaque) appeared to blow up into runaway values (~90588 on a 64x64
sample), "fixed" by measuring the kernel's zero-point on that
clamped-and-matrixed noise (0.7439). Round 2 (an ADVERSARIAL reviewer
re-measurement, not this suite): that "fix" was itself wrong. Both
`CIColorClamp` and `CIColorMatrix` — MEASURED, not documented anywhere
found — treat their input as PREMULTIPLIED regardless of the actual data;
routing `CIRandomGenerator`'s independent per-channel randoms through them
performs an unwanted implicit unpremultiply/repremultiply that reshapes
the distribution into `min(channel,alpha)/alpha` (mean 0.7439, not the
raw generator's own genuine 0.5, with 24.6% of pixels pinned exactly at
1.0 — matching the analytic probability all three of r/g/b independently
exceed the same shared alpha). That distorted 0.7439 zero-point was ALSO
measured only on a 64px test fixture, where the noise's later affine
scale floors to a 1px no-op — real photos (`min(extent)` > 500px) hit a
SECOND, independent distortion from the default bilinear resampler,
drifting the mean further to ~0.82. Net effect of the two compounding
bugs: mid-gray at slider 1.0 rendered at ~0.62 (~+0.31 EV) at real
resolutions, not the intended few-percent Jensen's-inequality artifact.
**Actual fix**: remove `CIColorClamp`/`CIColorMatrix` entirely — verified
directly that a kernel sampling `CIRandomGenerator`'s raw output
reproduces its true, undistorted 0.4994 mean — and simply never read the
noise argument's alpha channel in the kernel (the generator's own
independent random alpha is irrelevant, not something to force or
correct). `kGrainZeroPoint` is 0.5 (confirmed both analytically — the
theoretical mean of a uniform-0...1 field — and empirically). Add
`.samplingNearest()` before the noise's affine scale: MEASURED, the
default bilinear resampler leaves the mean alone on this corrected
construction but still shrinks the noise's STD by ~34% once the cell
exceeds 1px (adjacent random samples get averaged together), which
`.samplingNearest()` holds flat across a 4x resolution range.

Stage order (after Sharpen, after Noise Reduction) is MEASURED on both
sides via a temporary swap-rebuild-measure-revert harness, re-confirmed
after the fix above: grain-before-sharpen amplifies noise ~2.4x (std
0.23888 vs. shipped 0.09936), grain-before-NR gets ~35% of it silently
eaten (std 0.06439 vs. 0.09936) — Sharpen's own "true final stage" claim
(in two places: the `EditPipeline` type header and its own doc comment)
was corrected rather than left stale. Lower bound IS clamped in the
kernel (unlike Dehaze's deliberately-unclamped result) — a real,
re-measured necessity even with the corrected SYMMETRIC noise: near
black, `w` is small but non-zero, so an unlucky sample can still push
output to -0.0083 before the clamp. `pickColorRangeTarget` in
`ImageDocumentModel.swift` needed `grain` added to its hand-maintained
post-mask-stage field list (the same list that was missing Dehaze once
before). `ImageRenderer.swift`'s own proxy-divergence stage list (a
STRUCTURAL claim) needed `grain` added too — and Grain is the MOST
proxy-divergent stage of all, since its noise pattern (not just its
amplitude) is coordinate-locked and differs completely between a proxy
and a full-res render, a nuance now recorded on `EditState.grain`'s own
doc comment and in IMPROVEMENTS.md. 1049 tests (16 new, `EditPipelineTests`'
new `// MARK: - Grain math` block, plus plumbing across Codable/Preset/
ComparisonOriginal/RawRedecode/Catalog tests following the `dehaze`
pattern). Reviewer: FIX FIRST (the adversarial re-measurement that caught
the CIColorClamp/CIColorMatrix premultiply bug — see above) → FIX FIRST (3
blocking + 3 nits, all doc-comment consistency: an inverted stage-order
claim and a stale figure in CLAUDE.md, a missing-`grain`-from-a-hand-
maintained-list gap in `ImageDocumentModel.swift`, a stale "Sharpen is
final" claim in `docs/ROADMAP_HISTORY.md`'s original Sharpen entry, a test
mis-citation, an over-tight measurement band) → FIX FIRST (one of those doc
fixes had only been applied in one of two files carrying the same stale
band) → **APPROVE**. Committed in 4 logical commits (state field, kernel +
pipeline stage, UI slider, docs), WITHOUT live verification, by explicit
user choice (asked; user chose to skip it and commit now rather than grant
screen-automation permission for this task). NOT live-verified: the
slider's visual effect across its range, whether it reads as photographic
grain rather than digital noise (a subjective judgment, deliberately not
unit-tested), and — the actual payoff of the resolution-independence
design decision — whether dragging the slider on a large photo shows any
visible grain-size pop when the interactive downscaled proxy is dropped
and the full-res frame settles. Worth live-verifying in a future session;
not currently blocking anything.

**Color Grading Slice A / backend (2026-09-18)**: 9 new `EditState` fields
(Shadows/Midtones/Highlights × Hue/Saturation/Luminance), `ColorGrading.
cikernel` (8th custom kernel), `EditPipeline.applyColorGrading`. Selects by
each pixel's own LUMINANCE (raised-cosine falloff over 3 fixed anchors —
the same mathematical form `SelectiveColor.cikernel`'s hue-band falloff
already uses, applied to a different axis), unlike Selective Color's
per-hue targeting. Needs no on-GPU `rgb2hsl`/`hsl2rgb` at all — each
wheel's Hue/Saturation converts to a signed RGB tint delta ONCE per render
in Swift (`ColorGradingTint.swift`, new, pure), reusing
`ColorRangeSelection.rgb(forHue:saturation:lightness:)` rather than
duplicating that math (its doc comment was corrected for the new caller).

Two independent, both-measured reasons `applyColorGrading` runs LAST
inside `applyPerceptualAdjustments`'s sandwich, found during planning and
confirmed during implementation: (1) it must survive Black & White's
forced desaturation, or the single most common real Color Grading use —
tinting a monochrome photo for a sepia/split-tone look — would be
silently dead; live-confirmed via a real render, not just reasoned about.
(2) MEASURED (temporary swap-rebuild-remeasure harness) not to commute
with Vibrance/Saturation either — swapping the order moved a colored
patch's red channel by 0.0105, ~5.2x this suite's 0.002 tolerance.

Constants (width 0.4, tint strength 0.8, luminance strength 0.5) are v1's
principled defaults for what Lightroom exposes as "Blending" (deferred),
all MEASURED via a temporary spike (swept each in turn, printed real
numbers, deleted before the final doc comments were written) — not
guessed. One real correction mid-spike: the weight function operates on
PERCEPTUAL (gamma-encoded) luma since the stage runs inside the perceptual
sandwich, and a first attempt at choosing sample points used naive
evenly-spaced LINEAR values (0/0.25/0.5/0.75/1.0), which was misleading —
gamma encoding compresses shadow detail into a much larger share of the
perceptual range, so linear 0.25 is already just past perceptual midtone.
Corrected to sample points chosen so their perceptual encoding lands at
~0.1/0.3/0.5/0.7/0.9 instead, cross-checked against this file's own
established "linear 0.214 ≈ perceptual middle gray" figure.

Full write-up with all the real measured numbers in
`docs/ROADMAP_HISTORY.md`. 1069 tests (20 new: 6 pure-math in
`ColorGradingTintTests.swift`, 12 in `EditPipelineTests`' new Color Grading
math block, 2 in `EditStateCodableTests`; plumbing-only additions to
`EditStatePresetTests`/`EditStateComparisonOriginalTests`/
`CatalogDatabaseTests`' own fixtures). `AdjustTabView.
isAdjustTabAtIdentity`/`resetAdjustmentsButton` extended despite no UI
existing yet — same precedent Curves v2 slice 3 backend's own round-1
reviewer catch established.

Reviewer round 1: FIX FIRST. Caught 2 real kernel-math bugs (see
`docs/ROADMAP_HISTORY.md` for the full story): the kernel's first draft
copied `SelectiveColor.cikernel`'s normalize-by-max-channel/rescale
technique before adding its tint/luminance delta, which silently amplified
the grade by the pixel's own headroom (wrong for this kernel's ABSOLUTE
additive deltas, unlike SelectiveColor's RELATIVE operations); the same
normalize also misclassified bright saturated pixels into the wrong tonal
range. Both fixed by removing the normalize/rescale entirely and computing
luminance/adding the delta directly on the raw pixel — the two bugs turned
out to be the same root cause. Also fixed: 3 doc-honesty issues (stale
"same technique as SelectiveColor" claim, "linear luminance" wording that
contradicted the correct "perceptual luma" description elsewhere in the
same file, a test doc comment that pre-emptively excused the amplification
bug as "not a bug") and 4 minor items (saturation/luminance clamping in
the Swift wrapper since no UI exists yet to enforce range, a vacuous
zero-state test's doc comment corrected for honesty about what it actually
verifies, the alpha-preservation test strengthened to actually exercise
the premultiply round trip — caught along the way that this suite's
`CIContext.render` returns PREMULTIPLIED not straight alpha, a real thing
to know for any future test in this file — and `ImageRenderer.swift`'s
structural stage list extended). All 1069 tests still pass after the
fixes. **Reviewer round 2: APPROVE.** Committed in 4 logical commits
(state field, tint helper, kernel + pipeline stage + tests, docs).

**Color Grading Slice B / the wheel UI (2026-09-18)**: `ColorWheelGeometry.swift`
(pure polar<->screen-point math — `screenPoint`/`polarValue`, a true polar
radial clamp, a center snap zeroing Hue AND Saturation together, and
`angularGradientFraction` for the painted wheel's `AngularGradient` stops),
`ColorGradingWheelView.swift` (the draggable wheel, this app's first
continuous-hue rendering UI), `ColorGradingRange.swift` (presentation-only
Shadows/Midtones/Highlights selector), wired into a new "Color Grading"
section in `AdjustTabView` (segmented picker with an edited-state dot,
shared wheel, Luminance slider, per-range Reset). 1088 tests (19 new, all
in `ColorWheelGeometryTests`).

Reviewer: 3 rounds, FIX FIRST → FIX FIRST → APPROVE. Round 1 caught a wrong
`AngularGradient` fraction-convention assumption that rotated the whole
painted wheel 90° from the puck's actual position (the "color under the
puck never matches the actual tint" bug — the one thing this control
exists to communicate), a missing wrap-around gradient stop (a flat,
hard-edged wedge), an unrelated hardcoded `RadialGradient` radius (the
wheel rendered washed-out everywhere, unrelated to where Saturation 1
actually sits), a center-snap epsilon that was both an absolute
point-distance (too tight for real cursor input to ever trigger) and
incomplete (zeroed Hue but not Saturation), three mutually-disagreeing
"is this range edited" definitions across the segment-label dot/per-range
Reset/top-level identity check, and a `.id()` doc comment overclaiming
"load-bearing" for a view with no persistent `@State` to protect. Round 2
caught a residual doc-comment contradiction (one file's comment still said
"load-bearing" after the other's was fixed) and a test that computed both
its expected and actual values from the same function under test, so it
passed trivially without cross-checking anything — rewritten to derive the
expected value independently via `atan2` on `screenPoint`'s own output.
Also relabeled a doc comment from MEASURED to DERIVED (it was a claim read
from SwiftUI's documentation, not an actual run — this codebase's own
CLAUDE.md convention reserves MEASURED for the latter). Round 3: APPROVE.

**Not yet live-verified**: the `AngularGradient` convention itself (fraction
0 at the wheel's right edge, sweeping clockwise) rests on reading SwiftUI's
documented behavior, not on-screen confirmation that the painted color
under the puck actually matches the tint being applied — flagged in both
`ColorWheelGeometry.angularGradientFraction`'s and
`ColorGradingWheelView.hueGradientStops`'s own doc comments for a future
session. Also not built: keyboard/VoiceOver support and a numeric Hue/
Saturation readout (only Luminance has a real accessible slider) — logged
as IMPROVEMENTS.md D20, matching the WB-eyedropper/Red-Eye placement
precedent for deferring pointer-only interaction accessibility to its own
session. Committed in 4 logical commits (geometry + tests, wheel view +
range selector, `AdjustTabView` wiring, docs).

**Curves v2 slice 3 UI (2026-09-17)**: the per-channel Red/Green/Blue tone
curve editor, built on the backend shipped earlier this session (commit
`d9a4d21`). New `ToneCurveChannel` enum (`Sources/UI/ToneCurveChannel.swift`
— `.composite/.red/.green/.blue`, `String, CaseIterable, Identifiable`,
matching `HistogramDisplayMode`'s shape rather than `SelectiveColorBand`'s
because it drives a segmented `Picker`, not a swatch row) and new
`HistogramChannelOverlay` enum replacing `HistogramBars`'/`HistogramView`'s
old `showChannels: Bool` — a bool could only mean "all three RGB channels
or none," which stopped being enough once the editor needed to show exactly
ONE channel's own histogram while that channel's curve is being edited
(showing all three additively overlaid while editing Green tells the user
nothing about Green specifically — that overlay is designed so individual
channels can't be read out of it). `curveSection` gained a 4-segment
picker (`RGB | Red | Green | Blue`, each labeled with a trailing "•" when
that channel's curve is non-empty, so an edited-but-not-currently-shown
channel isn't invisible state) driving a new `toneCurvePointsBinding(for:)`
dispatch helper (structurally identical to the existing
`selectiveColorHueBinding(for:)` pattern). `ToneCurveEditorView` gained a
`channel: ToneCurveChannel` parameter tinting the curve stroke and
histogram backdrop and driving a channel-aware accessibility label;
handles stay deliberately UNtinted (handle color already encodes
selection, and `Color.accentColor` over a pure-blue stroke/histogram would
be a real contrast loss — see that view's `handles(plotRect:)` doc
comment). `ImageDocumentModel.resetToneCurve()` → `resetToneCurve(_
channel:)`, clearing exactly one channel's array. The `ToneCurveEditorView`
instantiation is `.id(panel.selectedToneCurveChannel)` — argued and
reviewer-CONFIRMED as load-bearing, not decoration: that view owns
view-identity-scoped `@State`/`@FocusState` including two array indices,
and without a distinct identity per channel, the pre-existing
`dragStartLocation` self-heal's own documented gap (a dropped `onEnded`
followed by a same-pixel restart) could misapply an index from one
channel's array to a different one after a channel switch — bounded to a
silent no-op/wrong-selection by `ToneCurveEditing`'s existing
`indices.contains` guards, never a crash, but worth closing structurally
rather than arguing safe. Direct precedent for this exact `.id()` pattern
already existed in this file (`maskDetail`'s own `.id(id)`, for an
analogous per-mask `EditSliderRow` click-to-type-state reason). No new unit
tests — `ToneCurveEditing.swift` is unchanged and already
channel-agnostic, the three new `EditState` fields' Codable/preset/
`comparisonOriginal`/identity plumbing was already covered by the backend
slice's own tests, and `toneCurvePointsBinding(for:)`/`resetToneCurve(_:)`
have the same untested-by-precedent profile as their existing Selective-
Color/`revertToOriginal()` siblings with a reviewer-confirmed bounded (undo-
recoverable) blast radius if ever wrong. Suite stayed at exactly 1030 tests,
0 new — predicted before implementation, confirmed after. Reviewer: 2
rounds, FIX FIRST → APPROVE — round 1 caught a doc-comment misattribution
(a NaN/crash-guard comment left orphaned next to the wrong property after
an insertion) and one now-stale structural claim ("no per-channel UI exists
yet," written before this was that UI); both fixed and confirmed in round 2.

**Live-verified (2026-09-17)**, with explicit user permission for this
session to drive the app via synthetic mouse/keyboard events
(`cliclick`/`CGEvent`/AX), against `stepwedge.jpg` — a neutral gray-gradient
scratch fixture in a `livetest` folder from a prior session (NOT the user's
real photo library; confirmed by diffing `IMG_6564.jpeg.photoapp.json`
byte-for-byte before/after this session — untouched). A neutral test image
turned out to be an especially clean isolation check: since input R=G=B
everywhere, a single-channel curve immediately shows up as a color TINT
(confirmed: Red-only lift → red tint; Red+Green-cut → magenta; Red+Blue-cut
→ orange/yellow; RGB composite on top → uniformly lifted). Confirmed, each
cross-checked against the saved sidecar JSON, not just visually: per-channel
isolation on all 4 channels (each edit landed in exactly its own
`EditState` field, others provably untouched); the picker's "•"
edited-marker appearing/persisting independently per channel; channel-aware
stroke tint (white/red/green/blue) and Reset-button label; stale-index
safety across channel switches (switching to an empty channel showed no
leaked selection or stale highlight — the `.id()`/`.onChange` fix works);
keyboard arrow-nudge (Out 30→31, exactly `nudgeStep`); Option-click delete
on a non-composite channel (slice 2B's own round-1/round-2 regression
class — no crash, no multi-delete, correct single-channel isolation);
point drag-to-move without the sidebar's `ScrollView` hijacking the
gesture (re-confirms slice 2B's original blocking gate still holds with
per-channel `.id()` recreation); Reset-one-channel leaving the other three
untouched, undone in exactly one atomic Undo step. Not separately
re-verified live: drag-off-canvas delete and the top-level "Reset
Adjustments" button (both reuse already-tested, channel-agnostic code
paths at low incremental risk) and VoiceOver's actual spoken output
(the label string was verified only by reading `accessibilityChannelLabel`
in code, not by running VoiceOver itself). Cleaned up after: "Revert to
Original" on the test photo, confirmed via the sidecar that all four
tone-curve fields returned to `[]`, then quit the app.

**Curves v2 slice 3 backend (2026-09-17)**: per-channel Red/Green/Blue
tone-curve stages, additive to the existing composite `toneCurvePoints`.
`EditState.toneCurvePointsRed/Green/Blue` (5th-7th variable-length fields,
same tolerant-Codable/preset-copy/`comparisonOriginal`-clear/
`requiresRawRedecode`-excluded contract as `toneCurvePoints`).
`PointToneCurve.cikernel` gained a `vec3 channelMask` argument — a ternary
select, not `mix()`, so the pre-existing composite curve's render stays
byte-exact and an untouched channel skips `pointCurveValue`'s pow chain
entirely rather than computing and discarding it. `EditPipeline` now runs up
to 4 point-curve passes (composite, then R, G, B, each only when its own
array is non-empty). Two stage-order facts, both actually measured via a
temporary swap-rebuild-rerun-revert (not assumed): composite-before-channel
is a real REQUIREMENT (reversing it moved the render 0.04702, ~23.5x this
suite's 0.002 tolerance); R/G/B mutual order is NOT a requirement (measured
bit-identical regardless of order, since each pass writes only its own
channel). `AdjustTabView`'s `isAdjustTabAtIdentity`/`resetAdjustmentsButton`
extended to the three new fields (round-1 reviewer catch — without this, a
photo with only a per-channel edit read as "at identity" with no way to
clear it via Reset Adjustments). No editor UI yet — nothing in this app can
set these fields except a preset or a hand-edited sidecar; the "Curve"
sidebar section still only edits the composite curve. Reviewer: 3 rounds,
FIX FIRST → FIX FIRST → APPROVE. Round 1 caught the `AdjustTabView` identity/
reset gap plus two vacuous/mis-scoped tests (one compared a state to a copy
of itself, one asserted pinned constants under only one pipeline stage order
without ever swapping it) and two unverifiable-looking measurement claims in
a doc comment. Round 2 confirmed all of those fixed but caught a real
measured surprise along the way — an identity-SHAPED per-channel curve is
NOT bit-exact to an empty one (still runs the full sRGB-encode/pow/decode
chain rather than the ternary's zero-computation skip, ~1e-6 off, not a bug)
— plus two remaining doc nits (a wrong field-ordinal claim, a dangling
renamed-test reference), both fixed and confirmed in round 3. 1030 tests (17 new, up from 1013 after slice 2B: 6 in
`EditPipelineTests`, 4 in `PointToneCurveKernelTests`, 6 in
`EditStateCodableTests`, 1 in `EditStateRawRedecodeTests`; `EditStatePresetTests`
and `EditStateComparisonOriginalTests` only extended existing tests with the
three new fields, adding no new test functions).

**Curves v2 slice 2B (2026-09-17)**: the interactive point-curve editor —
`Sources/UI/ToneCurveEditing.swift` (pure screen-space geometry: add/move/
nudge/remove, hit-testing, endpoints pinned in x), `Sources/UI/
ToneCurveEditorView.swift` (the square canvas: histogram backdrop, grid +
dashed diagonal + curve stroke, drag-to-add/move, Option-click and drag-off-
canvas delete, keyboard nudging, VoiceOver custom actions), `HistogramBars`
split out of `HistogramView`, a new "Curve" section in `AdjustTabView`
between Light and Color, and `ImageDocumentModel.resetToneCurve()`. The
plan's one blocking gate — vertical drag inside the sidebar's vertically-
scrolling `ScrollView`, the first of its kind in this app — was live-verified
with REAL synthetic mouse/scroll events (`CGEvent`/`cliclick`, not just AX
actions): dragging moves a point without scrolling the sidebar, wheel-scroll
over the canvas still scrolls normally, and a point lands exactly under the
cursor after scrolling. Notably, this contradicts earlier sessions' finding
that synthetic mouse/scroll/keyboard events don't reach this app at all
(Phase 7 slices 3-5, Library grid D4) — true there, evidently not universal;
don't assume either finding transfers to a new gesture without checking.
Reviewer: 3 rounds, FIX FIRST → FIX FIRST → APPROVE — round 1 caught a
crash (`Int(round(...))` on a non-finite/huge coordinate reachable from a
corrupt sidecar, outside the `isGeometryFinite` guard's actual scope) and a
fragile `SpatialTapGesture.exclusively(before: DragGesture)` composition for
Option-click delete (a `minimumDistance: 0` drag always recognizes first in
practice, so the "exclusive" tap could never cleanly win — replaced with a
single `DragGesture` checking `NSEvent.modifierFlags` directly). Round 2
caught a genuinely destructive residual bug in that same rewrite: one
Option-click-drag could delete MORE THAN ONE point, because the delete
branch didn't mark its gesture as "already consumed a discrete action," so
a later `onChanged` callback (any mouse movement, even one pixel) could
re-hit and delete a second nearby point — real and reachable since two
points can legally sit within `minimumXSeparation`, well inside the 16pt hit
threshold. Fixed with a dedicated `didConsumeGestureAsDiscreteAction` flag,
live-reverified against the built binary with a tight 3-point cluster and a
multi-callback drag: exactly one point deleted, selection correctly shifted
to keep tracking the surviving point it had been on. 1013 tests (36 new, all
in `ToneCurveEditingTests` — `ToneCurveEditorView` itself is SwiftUI
interaction glue with no unit-test precedent, per this codebase's own
convention; verified live instead).

## In progress / blocked
None. Color Grading (both Slice A backend and Slice B UI) is fully shipped,
reviewed (APPROVE both), and committed — see the "Done" entries above.

## Exact next step
Pick the next Lightroom gap and enter Plan Mode first, per this project's
workflow rules. Point Color, Chromatic Aberration removal, and Manual
Transform Scale/Aspect are the remaining unstarted Tier-1 gaps; Auto Tone/
Auto Settings, Enhance/Super Resolution, History panel, and Copy/Paste-and-
Sync are unstarted Tier-2 items. Also worth considering: Color Grading
Slice B's own follow-ups logged this session — live-verifying the
`AngularGradient` painted-wheel convention on screen (flagged DERIVED, not
measured, in `ColorWheelGeometry.angularGradientFraction`'s doc comment),
and IMPROVEMENTS.md D20 (a numeric Hue/Saturation readout, which would also
double as the wheel's first AT-accessible path to those two axes).
