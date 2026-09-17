# Progress

Full session-by-session history (every completed feature/slice, reviewer
rounds, live-verification detail, measured numbers) lives in
`docs/PROGRESS_HISTORY.md`. This file is deliberately short — see CLAUDE.md's
"Quota / safe-pause discipline" section for why: it should always be readable
in one pass when resuming after a cutoff, not accumulate into another log.

## Current phase
Phase 2 (Edit engine) through Phase 7 (Local Adjustments/Masking) are all
✅ FULLY COMPLETE. Currently in **Curves v2** (Tier-2 Lightroom gap, WANTED):
slices 1, 2A, and 2B (the interactive point-curve editor UI) are all shipped.
Slice 3 (per-channel R/G/B curves)'s backend half is now shipped too — see
below. Its editor UI is next, not started. See CLAUDE.md's roadmap for the
full phase list and `docs/ROADMAP_HISTORY.md` for detail on anything already
shipped.

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
all of the Phase 2 edit-engine backlog except Curves v2 slice 3's UI (see
below), the Tier-1 Lightroom gaps Texture/Clarity and Dehaze, and Curves v2
slices 1, 2A, 2B, and slice 3's backend. Every numbered IMPROVEMENTS.md item
marked SHIPPED there is also done — that file is the source of truth for the
perf/polish backlog, not duplicated here.

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
Nothing in progress and nothing blocked.

## Exact next step
Pick the next slice: **Curves v2 slice 3's editor UI** (the backend — per-
channel `EditState` fields, pipeline stages, kernel `channelMask` — is now
shipped; nothing in the app can set these fields yet except a preset or a
hand-edited sidecar. The UI needs a plan of its own: likely a per-channel
mode switch on the existing "Curve" sidebar section/`ToneCurveEditorView`,
reusing `ToneCurveEditing.swift`'s screen-space geometry against whichever
of the four point arrays is selected, plus a channel-tinted curve stroke and
histogram overlay), or whichever WANTED Lightroom-gap item the user picks
instead (see CLAUDE.md's "Gaps vs. Adobe Lightroom Desktop" section) —
Grain, Color Grading, Point Color, Chromatic Aberration removal, and Manual
Transform Scale/Aspect are all unstarted Tier-1 items; Auto Tone/Auto
Settings, Enhance/Super Resolution, History panel, and Copy/Paste-and-Sync
are unstarted Tier-2 items. Per this project's workflow rules, enter Plan
Mode before starting either.
