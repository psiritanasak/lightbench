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
  loading. Finder / Dock / drag-and-drop opens shipped 2026-10-15 (feature A below), live check pending.
- Recently shipped (2026-10-09..12, all in `docs/ROADMAP_HISTORY.md` /
  `docs/PROGRESS_HISTORY.md`): Faces v1, Culling v1, Photo Merge (HDR + panorama),
  Depth Range mask, field-based search, Smart Collections saving the query, B&W Mix,
  Color Grading Blending/Balance/Global, Vignette Softness, per-mask Whites/Blacks,
  minimal-look pass, editor tool rail, tab memory.

## UNATTENDED RUN (started 2026-10-14; plan: /Users/praween/.claude/plans/squishy-wandering-minsky.md) — order #4 XMP → #1 Whites → #2 D64 curve → #3 B&W extras → #5 Culling Compare/Survey → #6 robustness
- **#4 XMP interop — SHIPPED in code (commits 84b0c84, 9b811ec, e5b14ed, 2ebff69 + docs), full suite 2871 green, NOT live-verified.** Photo ▸ Write / Read Metadata to XMP… (rating, reject, label, keywords; write only on request; merge keeps foreign tags), fill-defaults read after import, rename moves an owned `.xmp`. Reviewer: engine 3 rounds, UI/rename 5 rounds (the last blockers-only APPROVE); every fix mutation-checked. Limits: IMPROVEMENTS.md D65. MANUAL CHECKLIST: Write on 3 scratch photos incl. a CR2+JPG pair, open the `.xmp` text; hand-made `.xmp` with `crs:Exposure2012` keeps it after a write; Read on a fresh import restores values; Rename + Undo Rename move the `.xmp`; originals byte-identical.
- Test-suite note: the first full run after a rebuild twice showed 2 failures of unknown identity (a rerun of the same tree was green both times); cold-start flake suspected, not investigated.

- **#1 Global Whites — SHIPPED (018e871), reviewer APPROVE (1 round), suite green, not live-checked.** Manual: drag Whites on a bright photo, undo, relaunch (sidecar), Reset Adjustments clears it.
- **#2 D64 curve — SKIPPED; user decided 2026-10-14 to defer it past v1.** The monotone swap was built and measured: it moves renders by up to 0.265 (typical 0.02-0.07), not ~0.016, weakening Highlights/Black Point/Brilliance on every old edit; nothing committed. Numbers + options (a/b/c) in IMPROVEMENTS.md D64.

- **#3 B&W extras — SHIPPED (b1ecfd5), reviewer 2 rounds APPROVE, not live-checked.** Intensity (scales the Mix; nothing to scale when every Mix slider is 0), Neutrals/Tone (one monotone grey curve), Grain (rides the Grain stage; `EditState.zeroingGrain()` now lists every grain source for Export + the eyedropper). Manual: B&W on, drag each slider, undo, Reset Adjustments.
- **#5 Culling Compare + Survey — SHIPPED (commit after this line), reviewer 2 rounds APPROVE, suite 2926 green, not live-checked.** C = Compare (select left, candidate right; ←/→ candidate, ↑ swap, ↓ make-select), N = Survey (page of up to 12; ←/→ focus, `/` remove from page), Esc leaves the mode first, toolbar picker. Manual: run both on ~10 scratch photos, check the key gate (press P while a cell is still spinning: nothing should change), the picker does not eat arrow keys after a click, ⌘Z after a make-select.

- **#6 Robustness — D13, D31, D32 FIXED; D28 CLOSED; D29 SKIPPED (see below); reviewer rounds: 1 FIX FIRST, 2 APPROVE. Round 1: (a MainActor reentrancy in the thumbnail recovery: concurrent failures each ran their own probe/re-resolve — fixed with a per-root in-flight task, a once-per-photo verdict cache and a robust `getgroups`, 2 new concurrency tests).** D13: `willSwitchPhoto` hook before the flush (4 tests, mutation-checked). D32/D31: `FileReadability` (sandbox denial vs plain chmod vs missing), `CatalogModel.readabilityProbe` seam, silent once-per-root re-resolve after a failed thumbnail. D29 (launch sweep that DELETES stale Enhance temp files in the user's photo folders) was left out on purpose: automatic deletion in user folders is not something to ship unattended. LIMIT: a real sandbox denial could not be reproduced in the test host. MANUAL (D32, real sandbox, never run): make a folder stale (delete its bookmark from UserDefaults and relaunch), open a photo from it and confirm the re-grant panel still appears. D31's SILENT path needs a stale-but-PRESENT bookmark (not covered by that step; there is nothing to re-resolve without one) — only the unit tests cover it. Manual (D13): arm Add Brush on a photo without painting, switch photos with the filmstrip, open the first photo's `.photoapp.json` — no empty brush mask.

## RELEASE PREP (2026-10-14) — name/copyright decided; signing still needs an Apple Developer account
Done: placeholder app icon (`Sources/App/Assets.xcassets`, `scripts/make_app_icon.swift`), `MARKETING_VERSION` 1.0.0 / `CURRENT_PROJECT_VERSION` 1, photography category, bundled `ThirdPartyNotices.md` (GRDB MIT + Depth Anything V2 Small Apache-2.0 full text), `scripts/release.sh` (`--check` preflight verified; full sign/notarize/staple flow written but NEVER RUN — no Developer ID certificate on this machine), `docs/RELEASE.md`. DECIDED: name **Lightbench** (display name only; module + bundle id `com.photoapp.PhotoApp` unchanged on purpose: the bundle id owns the user's sandbox container), copyright "Copyright © 2026 Praween Siritanasak", ship the depth model, no App Store. `scripts/release.sh --check` now PASSES; `--unsigned` makes a shareable `Lightbench-<ver>-unsigned.zip` (Gatekeeper needs Open Anyway on other Macs). STILL NEEDED for a warning-free public download: Apple Developer Program account + Developer ID cert + notary profile (notarization needs it even outside the App Store), real icon artwork, a clean-Mac test.

## LIVE CHECK DONE (2026-10-14, Release build, scratch folder of 6 JPEGs + a hand-made .xmp; catalog and prefs backed up first and restored byte-identical afterwards, checksums matched; scratch folder deleted)
- **XMP**: import auto-read filled `scratch_02` (4 stars, Blue) from its `.xmp`; Write dialog + folder prompt + "Wrote XMP for 2 photos"; `scratch_02.xmp` kept foreign `crs:Exposure2012` + keywords, `scratch_03.xmp` created (Rating 3); the 6 JPEGs byte-identical; Rename (5 photos, template `lc_{seq:2}`) moved both `.xmp` files and the `.photoapp.json`; Undo Rename put everything back. NOT live: Read Metadata from XMP (manual command; the import path used the same reader), D41's rename block on the last-opened photo behaved as documented.
- **Whites**: slider between Shadows and Black Point, +40% after 4 steps, histogram stretched, Undo stepped back (+20%), value persisted in the sidecar.
- **B&W extras**: Intensity alone = no change; Blue -60% darkened; Intensity +100% darkened more; Tone +80% darkened sub-0.5 tones; Neutrals +80% lightened mids; Grain raised a 60x60 patch's std 0.005 -> 0.057 (mean unchanged); all persisted. Float residue seen: after +8/-8 steps Tone/Neutrals stored 2.8e-17 instead of 0 (cosmetic: counts as "non-identity").
- **Culling Compare/Survey**: real key presses: C (select left / candidate right, focus ring), `4` rated the candidate only, → moved the candidate, ↑ swapped; N (3x2 survey, focus ring, ratings), `/` removed from the page ("Survey 5 of 5"), Esc back to the loupe, Return opened the Editor.
- **D13**: armed an unpainted Brush mask, switched photo via the filmstrip: the first photo's sidecar had 0 masks, other edits kept.
- NOT live: D31/D32 in a real sandbox (see the #6 manual note), Photo ▸ Read Metadata from XMP, Cull key-gate under load.
- Process notes: the window moved once (user activity) and an AX press on a button without a description does not work for the access NSOpenPanel (Return confirms; verified the folder shown first); a full-suite hang (log silent 89 min, test host at ~97% CPU) happened once and was NOT reproduced — a waiter-livelock theory was fixed defensively (f7ed46c) but never proven.

## V1 READINESS RUN (2026-10-15; plan: /Users/praween/.claude/plans/squishy-wandering-minsky.md) — order C backup → A drop/open → B empty states → D Preferences → E About/Help+shortcuts → F Move to Trash
- C catalog backup + restore: SHIPPED (4 reviewer rounds, 36 tests, mutation-checked; details `docs/ROADMAP_HISTORY.md`, limits IMPROVEMENTS.md D66). Manual checks still owed (sandbox, not driven): save-panel backup over an EXISTING file, Restore on relaunch (alert text, `-before-restore` in `Application Support/PhotoApp/Backups/`), launch-backup folder contents after a normal launch.
- A drag-and-drop + open from Finder/Dock: SHIPPED (2 reviewer rounds; round 2 code APPROVE, docs fixed after). Manual checks owed: real Finder drop of a folder and of one photo, Dock-icon drop, "Open With", whether a second window appears per Finder open (no `handlesExternalEvents` is set on purpose, see D67.1), and that a cold-launch open (Dock drop while the app is not running) waits for the catalog and is not lost.
- NEXT: B (empty states), then D, E, F. One live pass at the end, only with the user's go-ahead.
- Full-suite note: use `-test-timeouts-enabled YES -default-test-execution-time-allowance 180` (`/tmp/runfull.sh`); two earlier plain runs hung forever on `SkinMaskGeneratorTests.testAnOversizedSceneIsDownscaledAndStillWorks` (passes alone in 0.6 s; cause not found, preceded by Vision `MDB_MAP_FULL` cache errors). The suite is ~2976 tests, ~6-7 min.
- Pending: new app icon from the user (`Lightbench-icons.zip`, untracked) — macOS set rendered by the rewritten `scripts/make_app_icon.swift`; install into `Sources/App/Assets.xcassets` as its own commit.

## Known flaky test
`FacesModelTests.testClearWhileAScanRunsKeepsItRunningAndItStillTellsTheLibrary` (real Vision face detection on a synthetic fixture) failed in 3 of ~9 full-suite runs this session ("the finished scan still refreshed the Library": the scan finished with no people found) and passed every time when run alone, even right after a forced rebuild. Matches the older note that the Vision-based classes misbehave under load. Not caused by the rename/release work; not investigated further. If it ever fails alone, that is a real bug.

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
