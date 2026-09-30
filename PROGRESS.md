# Progress

Resumption state only. Full session-by-session history (write-ups, reviewer
rounds, live-verification detail, measured numbers) lives in
`docs/PROGRESS_HISTORY.md` — the pre-2026-09-30 contents of this file are
archived at its end under "Archived from PROGRESS.md on 2026-09-30". Shipped
improvement entries live in `docs/IMPROVEMENTS_HISTORY.md`. When a slice ships,
add a 2-4 line summary here, and move older entries to the history file.

## Current phase
Phases 1-7 complete; Phase 8 (Polish) not started. Working tree clean.

Recently shipped (newest first; details in history):
- **D34 (2026-09-30)** — test host no longer opens the real catalog or prunes
  real folder bookmarks. 1375 tests pass.
- **Pick/Reject flags (2026-09-29)** — `FlagStatus`, Migration 007, P/X/U keys,
  Flag filter. Live-verified 2026-09-30 on the real catalog (all changes undone).
  NOT verified: the cell flag-icon click, the P/X/U keys (synthetic key events
  don't reach the app), quit/relaunch (DB-level persistence confirmed instead).
- **D23 / D25 (2026-09-29)** — Transform Scale minification via Lanczos plus an
  asymmetric colorClamp; un-premultiply in `ImageAverageColor`/`PixelSampler`.
- **D20 numeric wheel readout, `EditorInteractionMode` refactor, D33** (2026-09-28/29).
- Earlier: Enhance/Super Resolution, Library open-access fix, History panel,
  Copy/Paste Settings, Auto Tone, Defringe, Transform Scale/Aspect, Point Color.

Unverified, not known-broken:
- Enhance: MetalFX vs Lanczos visual comparison, a RAW (D610) source, thumbnail
  persistence across relaunch.
- Library double-click-open fix: the original "fails right after import"
  trigger was never separately reproduced; if it recurs, check that first.

## Open reviewer issues
None. Every reviewer round on record ended in APPROVE before its commit.

Process note: the `reviewer` agent only registers when the session starts from
`~/photoapp-starter`, not `~` — start sessions from the project root. Always
pass `model: "opus"` when invoking it.

## In progress / blocked
None.

## Exact next step
Pick a new feature with the user (one per session): CLAUDE.md's roadmap gaps
list (Tier 1 / Tier 2), Phase 8 polish, or an open item in `IMPROVEMENTS.md`.
Candidate suggested last review: **D28** (pre-existing `saveSidecarNow`
load-during-save race onto the wrong sidecar — a data-integrity hazard on every
debounced save). Also open there: D31/D32 (security-scope gaps), D13 (phantom
brush mask on photo switch), D22/D24/D26 (design gaps), D20 keyboard half.
