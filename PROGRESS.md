# Progress

Resumption state only. Full session-by-session history (write-ups, reviewer
rounds, live-verification detail, measured numbers) lives in
`docs/PROGRESS_HISTORY.md` — the pre-2026-09-30 contents of this file are
archived at its end under "Archived from PROGRESS.md on 2026-09-30". Shipped
improvement entries live in `docs/IMPROVEMENTS_HISTORY.md`. When a slice ships,
add a 2-4 line summary here, and move older entries to the history file.

## Current phase
**PHASE 8 COMPLETE (2026-09-30) — ALL ROADMAP ITEMS 1-8 ARE NOW DONE.** Closed by
a measured large-image + edge-case audit (no code change needed; see
CLAUDE.md item 8 and `docs/ROADMAP_HISTORY.md` "Phase 8 close-out" for the
numbers). Two recorded findings, deliberately unfixed: D36 (heavy edits export
superlinearly slowly on very large images) and D37 (a truncated JPEG exports without
warning). Live check not verified: pan/zoom and clean slider-drag latency at
96/200MP. Nothing is in progress; the working tree was clean after the
temporary harness was deleted.

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
No roadmap items remain (Phase 8 closed 2026-09-30). Pick a new feature with the
user (one per session, Plan Mode first): CLAUDE.md's roadmap gaps list (Tier 1 /
Tier 2) or an open item in `IMPROVEMENTS.md` (incl. the Phase 8 findings D36/D37).
Feature-gap roadmap vs. Lightroom: **IMPROVEMENTS.md D35** (prioritized list). Other candidate: **D28** (pre-existing `saveSidecarNow`
load-during-save race onto the wrong sidecar — a data-integrity hazard on every
debounced save). Also open there: D31/D32 (security-scope gaps), D13 (phantom
brush mask on photo switch), D22/D24/D26 (design gaps), D20 keyboard half.

### Planned next slices (from IMPROVEMENTS.md D35, one per session, Plan Mode first)
1. **Color labels + batch rename** (Library; cheap wins, new migration 008) — or, if preferring AI, the **Vision subject-mask feasibility spike** (`VNGenerateForegroundInstanceMaskRequest`, probe test like the MetalFX one).
2. **Profiles / LUTs** + small Develop gaps (Vignette Softness, B&W panel, Color Grading Blending, Point Color Variance).
3. **Spot removal**: manual heal/clone, then automatic dust detection (no ML).
4. **AI masks** (Subject/Sky/Background/People, mask Feather/Edge refine) after the spike.
5. **Library metadata**: keywords, IPTC/EXIF, Smart Collections, stacks, duplicate detection, whole-folder relocate.
6. **Export upgrades** (metadata, watermark, color space, sharpening, naming templates).
7. **HDR/EDR display path**, HDR/Panorama merge, Enhance Denoise, persisted edit history.
Side track when a small session is wanted: D28 (sidecar save race).
