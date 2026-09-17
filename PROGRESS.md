# Progress

Full session-by-session history (every completed feature/slice, reviewer
rounds, live-verification detail, measured numbers) lives in
`docs/PROGRESS_HISTORY.md`. This file is deliberately short — see CLAUDE.md's
"Quota / safe-pause discipline" section for why: it should always be readable
in one pass when resuming after a cutoff, not accumulate into another log.

## Current phase
Phase 2 (Edit engine) through Phase 7 (Local Adjustments/Masking) are all
✅ FULLY COMPLETE. Currently in **Curves v2** (Tier-2 Lightroom gap, WANTED):
slice 1 (kernel swap) and slice 2A (additive point-curve data model/pipeline)
are shipped; slice 2B (the interactive curve editor UI) is next, not started.
See CLAUDE.md's roadmap for the full phase list and `docs/ROADMAP_HISTORY.md`
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
all of the Phase 2 edit-engine backlog except Curves v2 (see below), the
Tier-1 Lightroom gaps Texture/Clarity and Dehaze, and Curves v2 slices 1 and
2A. Every numbered IMPROVEMENTS.md item marked SHIPPED there is also done —
that file is the source of truth for the perf/polish backlog, not duplicated
here.

## In progress / blocked
Nothing in progress and nothing blocked. Curves v2 slice 2B has an approved
plan (see "Exact next step") but implementation hasn't started.

## Exact next step
**Curves v2 slice 2B** — the interactive point-curve editor UI. Approved plan
at `~/.claude/plans/declarative-wondering-mist.md`: a pure
`Sources/UI/ToneCurveEditing.swift` (screen-space hit-testing, endpoints
pinned in x, dragged points stop rather than reorder), a square canvas drawn
over the histogram (split `HistogramBars` out of `HistogramView` first), one
`DragGesture`, delete-on-release-outside plus Option-click plus a button,
keyboard nudging for accessibility, and a new collapsed-by-default "Curve"
section between Light and Color.

**Its blocking gate**: this is the first vertical drag inside the sidebar's
vertically-scrolling `ScrollView`. Every other shipped sidebar drag is
horizontal-only. Green tests and a reviewer APPROVE are explicitly NOT
sufficient evidence here — the StableScrollInsets regression once passed both
and then broke every slider live. A real hand must confirm drag-vs-scroll
behavior before calling this done.

After slice 2B: slice 3 (per-channel R/G/B curves), then whichever WANTED
Lightroom-gap item the user picks next (see CLAUDE.md's "Gaps vs. Adobe
Lightroom Desktop" section) — Grain, Color Grading, Point Color, Chromatic
Aberration removal, and Manual Transform Scale/Aspect are all unstarted
Tier-1 items; Auto Tone/Auto Settings, Enhance/Super Resolution, History
panel, and Copy/Paste-and-Sync are unstarted Tier-2 items.
