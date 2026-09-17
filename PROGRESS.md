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
Slice 3 (per-channel R/G/B curves)'s backend shipped earlier this session;
its editor UI is now code-complete and reviewer-approved (see "In progress /
blocked" below for the one remaining step before it's fully done). See
CLAUDE.md's roadmap for the full phase list and `docs/ROADMAP_HISTORY.md`
for detail on anything already shipped.

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
all of the Phase 2 edit-engine backlog except Curves v2 slice 3's UI (code-
complete, reviewer-approved, not yet live-verified — see below and "In
progress / blocked"), the Tier-1 Lightroom gaps Texture/Clarity and Dehaze,
and Curves v2 slices 1, 2A, 2B, and slice 3's backend. Every numbered
IMPROVEMENTS.md item marked SHIPPED there is also done — that file is the
source of truth for the perf/polish backlog, not duplicated here.

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

**NOT yet live-verified** — this is the one gap between "code-complete,
reviewer-approved" and "done" for this entry. `ToneCurveEditorView` is
SwiftUI interaction glue with no unit-test precedent in this codebase (per
slice 2B's own entry below); its channel-switching behavior specifically
needs real synthetic-mouse/keyboard verification, not just a green build —
slice 2B's own history includes two real bugs (a crash, a multi-delete
data-loss bug) that only a live-verification pass caught across 3 reviewer
rounds. Needs, specifically: per-channel isolation (confirm each channel's
edits land in the right `EditState` field via the saved sidecar, not just
visually), the stale-index-across-channel-switch scenario `.id()` exists to
prevent, a re-run of slice 2B's two reviewer-caught regressions (option-
click multi-delete, drag-off-canvas delete) on a non-composite channel, and
a re-run of slice 2B's original ScrollView-drag blocking gate (since the
canvas now recreates on every channel switch). This session paused before
that step because live verification needs screen/mouse automation
(`cliclick`/`CGEvent`), which per this user's own standing instruction
needs to be asked for, scoped per-task, before use — and this session
fired from an unattended scheduled prompt with no one to ask.

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
**Curves v2 slice 3's editor UI** — code-complete and reviewer-APPROVED
(see the entry above), committed. Blocked on exactly one remaining step
before it can be marked fully done: **live verification**, which needs
screen/mouse automation (`cliclick`/`CGEvent`), and this user has a
standing instruction that automation needs to be asked for, scoped
per-task, before use. This session ran from an unattended scheduled
prompt with no one to ask, so it stopped here rather than run automation
without asking.

**Resuming session: ask the user for permission to drive the app with
synthetic mouse/keyboard events for this specific verification pass, then
run the live-verification checklist in the entry above, then — only if
that surfaces something that needs a code change — re-run the reviewer
and commit the fix.** If live verification passes clean with no code
changes, just update this file to move the entry from "In progress /
blocked" to fully "Done" and mark Curves v2 complete in CLAUDE.md.

## Exact next step
Finish Curves v2 slice 3's editor UI per "In progress / blocked" above:
get the reviewer to APPROVE, ask for and get screen-automation permission,
live-verify, commit. After that, Curves v2 is fully complete and the next
slice is picking a WANTED Lightroom-gap item (see CLAUDE.md's "Gaps vs.
Adobe Lightroom Desktop" section) — Grain, Color Grading, Point Color,
Chromatic Aberration removal, and Manual Transform Scale/Aspect are all
unstarted Tier-1 items; Auto Tone/Auto Settings, Enhance/Super Resolution,
History panel, and Copy/Paste-and-Sync are unstarted Tier-2 items. Per this
project's workflow rules, enter Plan Mode before starting whichever is
picked.
