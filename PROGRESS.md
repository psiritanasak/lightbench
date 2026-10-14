# Progress

Resumption state only. Full session-by-session history (write-ups, reviewer
rounds, live-verification detail, measured numbers) lives in
`docs/PROGRESS_HISTORY.md`; everything that used to be in this file before the
2026-10-14 cleanup is archived at its end under "Archived from PROGRESS.md on
2026-10-14". Shipped improvement entries live in `docs/IMPROVEMENTS_HISTORY.md`.
When a slice ships, put a 2-4 line summary here and move older entries to the
history file.

## Current state (2026-10-14)
- master is clean apart from the untracked `.Rhistory` (never stage it). Last
  commits: `Open…` fix (0aa676e) + progress note (9a49e32). Full suite 2797 green.
- The user's live pass (2026-10-14) confirmed: Color Grading Global wheel,
  per-mask Whites/Blacks, Vignette Softness, B&W Mix, save/restore.
- Bolivia `raw_files` access granted (camera data 1086 rows).
- `Open…` is only in the Library toolbar; it now switches to the Editor before
  loading. Opening a file from Finder / `open -a` is still unsupported (no `onOpenURL`).
- Recently shipped (2026-10-09..12, all in `docs/ROADMAP_HISTORY.md` /
  `docs/PROGRESS_HISTORY.md`): Faces v1, Culling v1, Photo Merge (HDR + panorama),
  Depth Range mask, field-based search, Smart Collections saving the query, B&W Mix,
  Color Grading Blending/Balance/Global, Vignette Softness, per-mask Whites/Blacks,
  minimal-look pass, editor tool rail, tab memory.

## UNATTENDED RUN (started 2026-10-14; plan: /Users/praween/.claude/plans/squishy-wandering-minsky.md) — order #4 XMP → #1 Whites → #2 D64 curve → #3 B&W extras → #5 Culling Compare/Survey → #6 robustness
- **#4 XMP interop — SHIPPED in code (commits 84b0c84, 9b811ec, e5b14ed, 2ebff69 + docs), full suite 2871 green, NOT live-verified.** Photo ▸ Write / Read Metadata to XMP… (rating, reject, label, keywords; write only on request; merge keeps foreign tags), fill-defaults read after import, rename moves an owned `.xmp`. Reviewer: engine 3 rounds, UI/rename 5 rounds (the last blockers-only APPROVE); every fix mutation-checked. Limits: IMPROVEMENTS.md D65. MANUAL CHECKLIST: Write on 3 scratch photos incl. a CR2+JPG pair, open the `.xmp` text; hand-made `.xmp` with `crs:Exposure2012` keeps it after a write; Read on a fresh import restores values; Rename + Undo Rename move the `.xmp`; originals byte-identical.
- Test-suite note: the first full run after a rebuild twice showed 2 failures of unknown identity (a rerun of the same tree was green both times); cold-start flake suspected, not investigated.

## Open reviewer issues
None. Every reviewer round on record ended in APPROVE before its commit.

## In progress / blocked
None.

## Not live-verified (low priority)
- Photo Merge: panorama and a real 3+ frame HDR bracket (only a real D610 pair was run).
- B&W Mix: undo / Compare / foliage. Touchpad behaviour of the UI polish passes.
- Enhance: MetalFX-vs-Lanczos comparison, a RAW source.

## Exact next step
None required. Pick a feature with the user (one per session, Plan Mode first).
Candidates: global Whites slider, B&W Mix extras (Intensity/Neutrals/Tone/Grain),
culling Compare/Survey, XMP interop spike (IMPROVEMENTS.md D57/D63/D64);
Lightroom parity list D35; open design/robustness items D28, D31/D32, D13,
D22/D24/D26, D20 keyboard half, D61/D62 (merge/depth limits), D60 (faces nits).

Process note: the `reviewer` agent only registers when the session starts from
`~/photoapp-starter`, not `~`. Always pass `model: "opus"` when invoking it.
