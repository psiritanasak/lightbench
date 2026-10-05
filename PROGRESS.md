# Progress

Resumption state only. Full session-by-session history (write-ups, reviewer
rounds, live-verification detail, measured numbers) lives in
`docs/PROGRESS_HISTORY.md` — the pre-2026-09-30 contents of this file are
archived at its end under "Archived from PROGRESS.md on 2026-09-30". Shipped
improvement entries live in `docs/IMPROVEMENTS_HISTORY.md`. When a slice ships,
add a 2-4 line summary here, and move older entries to the history file.

## Current phase
**PERSISTED EDIT HISTORY — SHIPPED (2026-10-05), 2 code commits (8805d76 `HistoryArchive` format, c544ddf sidecar wiring), reviewer-approved (2 rounds on the wiring), 1890 tests, live-verified across a quit/relaunch.** The History panel's timeline is stored in each photo's sidecar under `"_history"` and restored on load only when consistent with the sidecar's own edits. Follow-ups: IMPROVEMENTS.md D51. Detail: docs/ROADMAP_HISTORY.md.

**SKY / OBJECT MASK SPIKE — DECIDED (2026-10-05): not pursuing.** Spike committed (cc859fe: permanent probe `SkyMaskProbeTests` + findings in docs/ROADMAP_HISTORY.md): a cloud-capable Sky mask needs a bundled model; a clear-sky-only classical mask works on clear/dusk skies but fails on clouds/sunsets/snow-adjacent horizons. The user chose neither (no model, no half-feature). Remaining candidates: persisted edit history, IPTC/XMP write-out of keywords, the leftover D48 items (resized-unsharpened grain smoothing, sub-500px grain cell, Enhance/MetalFX vs grain).

**D48 EXPORT FOLLOW-UPS — DONE (2026-10-05), 2 code commits (83e24ee privacy default + v2 settings migration, 360eb68 grain after output sharpening), reviewer-approved, 1861 tests.** (1) Export's default metadata policy is now "All except location" (an untouched export no longer carries GPS); stored settings migrated v1 -> v2 once, resetting only the metadata policy. (2) Output sharpening no longer sharpens Grain: with both on, export renders without grain, resizes, sharpens, then adds grain at the output size; measured through the export path the old behaviour was noise std x1.13 (screen) / x1.34 (print), now within 6% (and equal to a native-size export for resized exports, a test with a 3000 -> 1100px resize). (3) Strengths kept: two real photos (vicuña fur/sky, telescope edges) exported at 2048px, matching 1:1 crops compared at 3x zoom: screen modestly crisper, print crisper with a faint dark rim at the strongest edges, no clipping. Judged by me, one panel of one. Remaining items: IMPROVEMENTS.md D48 (resized-unsharpened grain smoothing, sub-500px grain cell clamp, Enhance/MetalFX may amplify grain, ...). No live app pass this time (export-path behaviour was measured through `PhotoExporter.export` in tests).

**CLICK-ON-IMAGE SUBJECT PICKING — SHIPPED (2026-10-05), 2 code commits (e9eef2b engine + model, d00acee UI), reviewer-approved after 2 rounds and 1 round.** In an AI Subject mask with 2+ subjects, "Pick on Image" arms a persistent mode: click a subject in the photo to include/exclude it (one undo step each, "Toggle Subject N"), a red tint shows the chosen subjects, Esc/Done ends it, a keyboard crosshair + Return is wired. The hit test pushes each instance through the existing FORWARD mask path (`EditPipeline.subjectInstanceMaskImages`) so crop/flip/straighten/scale stay consistent without a hand-written inverse. 1853 tests, 0 failures. **LIVE-VERIFIED** on a Release build with a crafted two-circle photo + sidecar: tint over both subjects, click left -> Subject 1 unchecked, its boost and tint gone, mode stayed armed; click right -> Subject 2 unchecked; Esc disarmed; Undo restored Subject 2; a background click raised a 'No subject' alert (now silenced in the picker). Review caught: a Recompute racing a toggle would wipe it (refused while it runs), edge-pixel clicks missed, mis-placed doc comment. Not live-checked: keyboard path, zoomed/cropped/flipped real-UI picking, Compare/Crop (D50). The catalog photo table was byte-identical to its backup afterwards and the temporary folder grant was removed from prefs.

**D28 (SIDECAR SAVE RACE) — HARDENED (2026-10-02), 1 code commit (a8dd564), reviewer-approved after 2 rounds.** `saveSidecarNow` snapshots (photo, edits) together before the modal folder-access step. Honest status: the exact interleave was never reproduced (a toy Task completes in a nested run loop only from a timer callback; a real `load(from:)` did not complete in 10s from one), so this is defensive hardening with a deterministic snapshot test, not a confirmed fix of an observed corruption — details in IMPROVEMENTS.md D28. 1834 tests, 0 failures. No live check possible (needs a re-prompting bookmark + a photo switch inside a modal panel).

**SMART COLLECTIONS v1 — SHIPPED (2026-10-02), 3 commits (38d69a5 data layer, 8feaf74 model + sidebar, docs), reviewer-approved after 2-3 rounds each.** Save the filter bar (min rating, flag, label, one keyword) as a named sidebar row whose contents are evaluated live. 1830 tests, 0 failures. **LIVE-VERIFIED** on a Release build with 4 scratch PNGs: saved "Top Rated" from a rating filter (row appeared, selected, bar reset, search text kept), un-rating a photo removed it from the set immediately, Export with nothing checked said "Export 2 Photos" (the smart matches — 1 scratch + 1 existing 5-star photo — not 1098), the context menu (Rename… / Update from Current Filters disabled with an empty bar / Delete) worked: rename persisted, delete removed the row, left photos intact and fell back to All Photos; the row survived quit/relaunch. Review caught a real bug: Export with nothing checked would have exported the WHOLE catalog while a smart collection was selected. Not live-checked: Update from Current Filters with a non-empty bar, keyword criteria (unit-tested). Follow-ups: IMPROVEMENTS.md D49. **Live-pass incident:** a blind import typed into a file panel without confirming the Go-to sheet imported ~/Documents (4 real photos) and persisted a Documents folder bookmark; both were reverted by hand (photo table byte-identical to the pre-pass backup, prefs key removed) and a memory note saved.

**EXPORT UPGRADES v1 — SHIPPED (2026-10-02), 5 code commits (e9cea1e remembered settings, 7ece6eb color space, 5863516 metadata policy, afef543 output sharpening, 77651b5 text watermark), each reviewer-approved after 2-3 rounds.** 1805 tests, 0 failures. **LIVE-VERIFIED** on a Release build with a scratch 2400x1600 JPEG (EXIF orientation 6, GPS, Make) imported into the real app (catalog backed up first; scratch row removed, photo table byte-identical to the backup): default export wrote Orientation=1 with stored == displayed 1600x2400 and kept GPS/Make; a Display P3 + print sharpening + no metadata + watermark + 1200px export wrote 800x1200, profile Display P3, no GPS/Make/date, upright, mark bottom-right legible; quitting and relaunching showed every option (incl. resize 1200) restored in the sheet. Found and fixed along the way: export left the source's Orientation tag on already-rotated pixels (a double-rotation bug for any camera photo), a `.none` metadata leak of PNG text chunks, and an `Int()` crash on a huge stored long edge. Limits and follow-ups: IMPROVEMENTS.md D48; details: docs/ROADMAP_HISTORY.md "Export upgrades". (Sharpening strengths have only been eyeballed on a synthetic image.)

**LIBRARY KEYWORDS v1 — SHIPPED (2026-10-02), 3 code commits (ff73792 data layer, 76fc3f4 filter/search/model, d92a0ef sheet + picker + menus), all reviewer-approved (data layer 2 rounds, model 2, UI 2).** Tag photos with free-text keywords, filter the grid by keyword, search matches keywords. 1759 tests, 0 failures. **LIVE-VERIFIED** on a Release build with 4 scratch PNGs imported into the real app (catalog backed up first; scratch rows removed afterward, counts back to baseline 1094/15/29/1, rating sum 11): add via Return, partial chips, add-existing, remove, picker with counts, keyword search, delete-everywhere confirmation, relaunch persistence, and (after the review fixes) the menu-request path. Follow-ups and the unverified VoiceOver labels: IMPROVEMENTS.md D47. Details: docs/ROADMAP_HISTORY.md "Library keywords".

**BATCH RENAME — SHIPPED (2026-09-30), 5 commits, all reviewer-approved (the engine took 2 review rounds, the UI 5).** A shared naming-template
engine (`NamingTemplate`: `{name} {seq} {seq:N} {date} {datetime} {rating} {label} {flag}`; `CaptureDate` reads EXIF)
drives (1) **Export file naming** (`ExportSettings.namingTemplate`, default `{name}` = unchanged behavior, live example +
errors in the options sheet) and (2) **Library "Rename Files…"** (selection menu + Photo menu) with a live old→new preview
that renames the ORIGINAL files, their `.photoapp.json` sidecars and the catalog rows together, all-or-nothing, with
**Undo Rename** (Migration 009 keeps the last batch). Safety model: no-overwrite `renamex_np(RENAME_EXCL)` moves, two-phase
(chains/swaps/case-only legal), journal + rollback, files-then-catalog with rollback either way, re-plan right before
applying, refusal while the photo is open in the Editor / a load, export, Enhance, import or ANY modal panel is active
(`RenameBusyState`, `CatalogModel.isRenameInProgress`), write access for every folder, single-flight. Also fixed D39
(collision suffix vs 255 bytes). 1573 tests, 0 failures at the final run. **LIVE-VERIFIED** (Release build, scratch photos, real catalog backed up
first, every change undone — catalog identical to baseline afterward except the new Migration 009): sheet from the
selection menu, live preview using each photo's EXIF date + grid-order sequence, a same-name template refused with red
reasons and Rename disabled, Apply through the attached sheet (an attached SwiftUI sheet is NOT `NSApp.modalWindow`,
verified), the folder-access prompt, the success alert, files + sidecar renamed on disk, catalog rows updated, Undo
Rename from the Photo menu restoring files/sidecar/rows and clearing the log. NOT verified live: Export naming sheet,
Photo-menu "Rename Files…", the Editor-open block, thumbnails after a rename (dimmed behind the alert), multi-folder
selections, a dropped-sheet re-present in real SwiftUI (model-tested only), alert timing on slow machines (D43).
Open, accepted: D40 (crash-recovery journal), D41 (no "close photo" — the last-opened photo blocks renaming it), D42
(preview disk checks on the main actor), D43 (alert timed, not tied to dismissal).

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
- **Batch rename (2026-09-30)** — see the paragraph above: naming templates for Export + Library "Rename Files…" with Undo Rename
  (Migration 009); live-verified on the real catalog (all changes undone).
- **Color labels (2026-09-30)** — `ColorLabel` (red/yellow/green/blue/purple),
  Migration 008, `LibraryLabelFilter` + Label picker, colored dot on thumbnails,
  per-cell Color Label menu, keys 6-9 (red/yellow/green/blue; purple menu-only).
  Reviewer: FIX FIRST (docs/stale-comment only) → APPROVE. 1414 tests pass.
  Live-verified in a Release build against the real catalog (backed up first,
  every change undone): migration applied, menu label + dot, DB value, Label
  filter. NOT verified: keys 6-9 (need a focused grid cell; synthetic key events
  have not reached the grid before).
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
1. ~~Color labels~~ ✅ shipped. ~~Batch rename~~ ✅ shipped. ~~Vision subject-mask feasibility spike~~ ✅ done — GO (see docs/ROADMAP_HISTORY.md). ~~`.subject` mask kind v1~~ ✅ shipped (2026-10-01, code + tests + live-verified on a real group photo — see docs/ROADMAP_HISTORY.md for what was and wasn't covered). ~~Subject feather + per-subject selection~~ ✅ shipped (2026-10-01, live-verified in part). ~~Profiles/LUTs ("Looks")~~ ✅ shipped 2026-10-02 (live-verified in part; see docs/ROADMAP_HISTORY.md). ~~Spot removal v1 (Clone/Heal spots)~~ ✅ shipped 2026-10-02 (live-verified in part; D46). Next candidates: click-on-image subject picking, Sky/Object masks (own spike), spot-removal follow-ups (D46), Library metadata/keywords/Smart Collections, export upgrades.
2. **Profiles / LUTs** + small Develop gaps (Vignette Softness, B&W panel, Color Grading Blending, Point Color Variance).
3. **Spot removal**: manual heal/clone, then automatic dust detection (no ML).
4. **AI masks** (Subject/Sky/Background/People, mask Feather/Edge refine) after the spike.
5. **Library metadata**: ~~keywords~~ ✅ v1 shipped 2026-10-02 (see D47), ~~Smart Collections~~ ✅ v1 shipped 2026-10-02 (see D49), IPTC/EXIF, Smart Collections, stacks, duplicate detection, whole-folder relocate.
6. **Export upgrades** ✅ shipped 2026-10-02 (D48 lists follow-ups: image watermark, IPTC write-in, export presets, grain-vs-sharpen).
7. **HDR/EDR display path**, HDR/Panorama merge, Enhance Denoise, ~~persisted edit history~~ ✅ shipped 2026-10-05 (D51).
Side track: ~~D28 (sidecar save race)~~ hardened 2026-10-02 (reachability undetermined, see IMPROVEMENTS.md D28).
