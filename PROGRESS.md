# Progress

Resumption state only. Full session-by-session history (write-ups, reviewer
rounds, live-verification detail, measured numbers) lives in
`docs/PROGRESS_HISTORY.md` — the pre-2026-09-30 contents of this file are
archived at its end under "Archived from PROGRESS.md on 2026-09-30". Shipped
improvement entries live in `docs/IMPROVEMENTS_HISTORY.md`. When a slice ships,
add a 2-4 line summary here, and move older entries to the history file.

## Current phase
**BATCH RENAME — IN PROGRESS (paused on usage limit, 2026-09-30).** Commits 1-3 of 5 are on `master`
(naming engine `b4bcb3a`, Export naming `38d9c5f`, rename engine/plan/log/undo + Migration 009 `08968f5`).
Commit 4 (RenameModel + RenameSheetView + toolbar/Photo-menu wiring + CatalogModel rename methods) is committed
ONLY on branch `wip/batch-rename-commit4` — NOT reviewer-approved. It builds and the full suite passed at the last
run, but the last reviewer round was FIX FIRST with these still OPEN (plan: `~/.claude/plans/sharded-prancing-pillow.md`):
1. Gate Import Folder / Import Folder Tree, Locate (single+batch), Remove on a rename/undo in progress — plan: a
   `CatalogModel.isRenameInProgress` flag set by `RenameModel` while `isWorking`, with guards at the top of
   `importFolder`, `importFolderTree`, `relocatePhoto`, `relocateSelectedPhotos`, `removePhoto`; add an
   `isImporting` flag (none exists) and include "import in progress" in `renameProviders.busyReason`.
2. Sheet can strand `isPresentingSheet == true`: track visibility (`onAppear`/`onDisappear` -> model), treat
   presented-but-not-visible-and-not-working as stale in `begin`; add `.interactiveDismissDisabled(model.isWorking)`;
   route the `catch` in `performApply` through `report()`.
3. Photo menu "Undo Rename"/"Paste Settings": also disable while `renameModel.isPresentingSheet`; guard the Paste
   confirm button on `renameModel.isWorking`.
4. `RenamePlan`: also block a row whose TARGET path is the photo open in the Editor (new block case + test).
Then: re-run reviewer (Opus), merge the branch, do a LIVE check of the sheet/menus/undo in a Release build (back up the
real catalog first; scratch photos only; Migration 009 applies on first real launch), then commit 5 (docs: CLAUDE.md,
PROGRESS.md, IMPROVEMENTS.md D41/D42, ROADMAP_HISTORY). Not built by design: D40 crash-recovery journal, D41 Editor
"close photo" (last-opened photo blocks renaming it), D42 preview debounce.

**PHASE 8 COMPLETE (2026-09-30) — ALL ROADMAP ITEMS 1-8 ARE DONE**, closed by a measured
large-image + edge-case audit plus a follow-up (numbers: CLAUDE.md item 8,
`docs/ROADMAP_HISTORY.md` "Phase 8 close-out" and "Phase 8 follow-up"):
- **D37 SHIPPED** — export and Enhance refuse a truncated JPEG/PNG
  (`SourceIntegrity`, 1399 tests at the time; validated against the real library, 0 false refusals).
- **D36 PROFILED, not fixed** — cost is the Clarity+Dehaze combination, not any one
  stage; untested output-identical idea recorded in IMPROVEMENTS.md D36.
- **Live pass done** — zoom/pan/slider latency measured at 96MP and 200MP; Dehaze
  slider drags never registered under automation so that case is unmeasured.
- **D38 (open, unreproduced)** — one transient solid-green rectangle on the canvas.
Nothing in progress; working tree clean apart from these docs.

Recently shipped (newest first; details in history):
- **Color labels (2026-09-30)** — `ColorLabel` (red/yellow/green/blue/purple),
  Migration 008, `LibraryLabelFilter` + Label picker, colored dot on thumbnails,
  per-cell Color Label menu, keys 6-9 (red/yellow/green/blue; purple menu-only).
  Reviewer: FIX FIRST (docs/stale-comment only) → APPROVE. 1414 tests pass.
  Live-verified in a Release build against the real catalog (backed up first,
  every change undone): migration applied, menu label + dot, DB value, Label
  filter. NOT verified: keys 6-9 (need a focused grid cell; synthetic key events
  have not reached the grid before). Batch rename is NOT done (next slice).
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
Tier 2) or an open item in `IMPROVEMENTS.md` (incl. the Phase 8 findings D36/D38).
Feature-gap roadmap vs. Lightroom: **IMPROVEMENTS.md D35** (prioritized list). Other candidate: **D28** (pre-existing `saveSidecarNow`
load-during-save race onto the wrong sidecar — a data-integrity hazard on every
debounced save). Also open there: D31/D32 (security-scope gaps), D13 (phantom
brush mask on photo switch), D22/D24/D26 (design gaps), D20 keyboard half.

### Planned next slices (from IMPROVEMENTS.md D35, one per session, Plan Mode first)
1. ~~Color labels~~ ✅ shipped. **Batch rename** (Library + inside Export; next Library slice) — or, if preferring AI, the **Vision subject-mask feasibility spike** (`VNGenerateForegroundInstanceMaskRequest`, probe test like the MetalFX one).
2. **Profiles / LUTs** + small Develop gaps (Vignette Softness, B&W panel, Color Grading Blending, Point Color Variance).
3. **Spot removal**: manual heal/clone, then automatic dust detection (no ML).
4. **AI masks** (Subject/Sky/Background/People, mask Feather/Edge refine) after the spike.
5. **Library metadata**: keywords, IPTC/EXIF, Smart Collections, stacks, duplicate detection, whole-folder relocate.
6. **Export upgrades** (metadata, watermark, color space, sharpening, naming templates).
7. **HDR/EDR display path**, HDR/Panorama merge, Enhance Denoise, persisted edit history.
Side track when a small session is wanted: D28 (sidecar save race).
