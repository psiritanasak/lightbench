# Progress

Full session-by-session history (every completed feature/slice, reviewer
rounds, live-verification detail, measured numbers) lives in
`docs/PROGRESS_HISTORY.md`. This file is deliberately short — see CLAUDE.md's
"Quota / safe-pause discipline" section for why: it should always be readable
in one pass when resuming after a cutoff, not accumulate into another log.

## Current phase
**Copy/Paste Settings (Tier-2 Lightroom gap) is now FULLY SHIPPED
(2026-09-24)** — `PasteSettingsModel` owns "Copy Settings" (Editor
toolbar + ⇧⌘C) and "Paste Settings" (Library toolbar + ⇧⌘V, batch onto
the current selection). New `Sources/Rendering/SidecarStore.swift` +
`Sources/UI/SidecarFolderAccess.swift` (sidecar file I/O + bookmark
access extracted out of `ImageDocumentModel`'s own previously-private
methods, behavior-preserving) and `PasteSettingsPlan` (pure planning
logic, fully unit-tested). The merge reuses `EditState.
applyingPreset(onto:)` unchanged — no new field-exclusion list. 3 code
commits (sidecar extraction, Library grid live-refresh, the feature
itself), each its own reviewer round — the feature commit alone took 6
rounds (FIX FIRST × 5) to close a real async-load-vs-batch-write race;
see CLAUDE.md's own roadmap entry for the full story, including
IMPROVEMENTS.md D28 (one accepted, pre-existing, narrow residual
exposure in `saveSidecarNow` itself, logged not fixed). 1254 tests (19
new). **Live-verified (2026-09-24)** — see below.

Live verification (scratch synthetic JPEGs, 3 folders: FolderA/B/C, NOT
the user's real library) covered every item on the plan's own checklist:
Copy Settings (toolbar + ⇧⌘C) on an edited open photo; Paste Settings
(toolbar + ⇧⌘V) onto a 3-photo/2-folder selection, confirming ONE
bookmark prompt per not-yet-granted folder (FolderB), not one per
photo, and that an already-granted folder (FolderA, from the Copy step)
needed no re-prompt; each target's sidecar JSON showed the copied
tone/look fields while a pre-seeded target's OWN crop/mask/exposure
values survived untouched; Library grid thumbnails and edited-badges
updated live without leaving the Library (`thumbnailRevisions`); the
open-photo path — opened a photo, edited it, selected it plus others,
pasted twice (a batch paste while it was merely open, then a second
paste with it as the live editor target) — confirmed the Editor showed
the pasted look live, a "Paste Settings" row appeared in the History
panel above "Opened," clicking "Opened" undid exactly the second
paste's own field (`curvesShadows` back to 0, `exposureEV`/`contrast`
from the first paste preserved) with the disk sidecar matching, and the
two batch-only targets' own sidecars were completely unaffected by that
undo (confirmed via direct JSON diff, not just the UI). The decline
path was also verified end-to-end: pasting onto a fresh, never-granted
folder (FolderC) and clicking Cancel on the access prompt produced
"1 skipped" with no sidecar file created; a second Paste attempt on the
same photo re-prompted (confirming no session-level decline memory for
Paste, by design — distinct from `ImageDocumentModel.declinedFolders`,
which is Editor-save-specific); clicking Grant Access that second time
completed the paste and the sidecar landed on disk with the expected
values. No new bugs found during live verification — the 6-round
reviewer process had already closed the real risks.

Deliberate v1 scope cuts (all confirmed/accepted, not oversights): no
RAW-native fields carried (matches Presets' own behavior); no granular
"Sync Settings..." checkbox dialog; no copy-from-an-unopened-Library-
photo entry point; no "Undo Paste" batch restore.

**History panel (Tier-2 Lightroom gap) FULLY SHIPPED (2026-09-23)** —
a browsable/scrubbable edit list, not just linear undo. `EditHistory`
(`Sources/EditEngine/EditHistory.swift`) rewritten from a two-stack
past/future model to a single `entries: [HistoryEntry]` + `currentIndex`
timeline-with-cursor, adding `jump(to id:)` (by stable `UUID`, not array
index — `ImageDocumentModel.jumpToHistory(id:)`'s own
`finalizePendingCommit()` flush can trim/truncate the array first, which
would invalidate a captured index). New `EditStateDiff.swift`, a
`Mirror`-based generic field-differ (not a hand-maintained field list —
this codebase's own repeatedly-documented stale-enumeration bug class),
computes each row's summary from whichever fields actually changed.
`ImageDocumentModel` publishes `historyEntries`/`currentHistoryIndex`,
and the 4 pre-existing direct-commit call sites (Revert, apply Preset,
Reset Curve, Auto Tone) now pass an explicit `summary:`. New "History"
`AdjustTabView` section (after Presets): newest-first, current row bold,
abandoned-redo rows secondary-styled, a flat `ForEach` (not a nested
`ScrollView`, matching the Presets/Masks sections' own precedent).

1226 tests (27 new: `EditHistoryTests` extended, new
`EditStateDiffTests.swift`). Reviewer: 2 rounds, FIX FIRST → APPROVE.
Round 1 (scoped to the data layer only, before the UI-wiring commit
existed) caught a vacuous mask-diff test (passed from an incidental
`UUID` difference, not the field difference it claimed to test), two
doc comments describing not-yet-written UI-layer code as already
existing, a real `displayName` algorithm bug (an acronym immediately
followed by a new word stayed wrongly fused — `"rawEVBias"` would have
rendered `"Raw EVBias"` instead of `"Raw EV Bias"`; no real field was
affected, but the algorithm and its doc were both wrong), a missing
test that the diff actually agrees with `EditState`'s own `==`, a
trim-math test missing an assertion that could have let an off-by-one
in `commit`'s `currentIndex -= overflow` line pass by coincidence, and a
theoretical Unicode crash risk in `displayName`'s uppercase-casting. All
7 fixed. Round 2 (the full diff, now including the UI-wiring commit)
independently re-verified all 7 fixes and fully reviewed the two new UI
files for the first time — no correctness bugs found; APPROVE, with 3
non-blocking nits logged as IMPROVEMENTS.md D27 (a debounce-window edge
case tapping the current row mid-burst, dead "no history yet" UI code
since `entries` can never be empty, one one-sided test assertion). See
CLAUDE.md's own History panel entry for the full write-up.

**Live-verified (2026-09-24)**, with explicit user permission asked and
granted for this specific task (screen automation permission is scoped
per-task, not carried over from the earlier Auto Tone grant in this same
session), against a scratch synthetic fixture (`history_test.jpg`, a
Python/PIL-built orange-square/green-circle image in a scratch `/tmp`
folder, opened via File > Open, never imported into the catalog, deleted
afterward along with its sidecar) and a real Release build:
- Unlike the Auto Tone session's unresolved screenshot quirk, the Adjust
  sidebar — including the new "History" section — rendered correctly in
  every screenshot this session, no workaround needed.
- Made 4 distinct edits (a drag on Exposure, an interrupted then a
  completed drag on Contrast — see below, and Auto Tone) and confirmed
  the History list showed 5 sensible rows newest-first: "Opened",
  "Exposure EV", "Contrast" (×2), "Auto Tone" — the explicit label for
  Auto Tone, the generic `EditStateDiff`-derived label for the ordinary
  slider edits.
- **An unplanned real-world confirmation of the debounce/coalescing
  design**: the first Contrast drag attempt was interrupted mid-drag by
  the folder-access permission dialog (triggered by the just-prior
  Exposure edit's own debounced sidecar save), and by the time a second,
  complete Contrast drag was performed, enough wall-clock time had
  passed that the two were NOT coalesced into one commit — they show as
  two separate "Contrast" rows. Not a bug: this is exactly the debounce
  design working as intended on a real, unplanned timing gap, not a
  synthetic test of it.
- Clicked an older row ("Exposure EV"): confirmed the render AND the
  sidecar file (`exposureEV: 2.7287581699346406`, exactly matching the
  slider) both updated to that historical state; the row went bold, the
  rows above it (the abandoned Auto Tone/Contrast branch) went
  secondary-styled, and "Opened" (below current, not abandoned) stayed
  normal-styled — all three of `historySection`'s row states confirmed
  distinct on screen.
- **Tapped the now-current "Exposure EV" row a second time**: confirmed
  via the sidecar file's mtime, unchanged before and after (not just a
  visual check) — the no-op-jump guard genuinely suppresses the write
  end to end, not just in the unit tests.
- Made a NEW edit (Highlights, which writes `curvesHighlights`) from
  that jumped-to point: confirmed the abandoned Auto Tone/Contrast/
  Contrast rows disappeared from the list, replaced by a single new
  "Curves Highlights" row.
- Confirmed toolbar Undo, then Redo, correctly interleave with the
  manual History jump — Undo stepped back to "Exposure EV" 's state
  (`curvesHighlights` back to `0`), Redo stepped forward again
  (`curvesHighlights` back to its edited value), both confirmed via the
  Light section's own live slider readout.
- One automation-only false start, not a product bug: an initial attempt
  to click the toolbar's Undo/Redo buttons by their `title` AX attribute
  silently no-opped both times (found zero matching elements, so the
  clicks never landed) — these are the SAME toolbar buttons this
  project's own AX-automation notes already document as exposing their
  label via `description`, not `title`/`name`; switching to `description`
  fixed it immediately. Recorded here so a future live-verification
  session doesn't lose time rediscovering it.

**Auto Tone (Tier-2 Lightroom gap) shipped and live-verified earlier this
session (2026-09-23)**, including a real-photo check (below) beyond the
two synthetic fixtures already documented —
a one-click "Auto" button (first row of the Light section) that solves
Exposure/Black Point/Highlights/Shadows/Contrast/Vibrance from a new
whole-image tonal-statistics sampler (`ToneStatistics`/
`ImageToneStatistics`) via a new `AutoToneSolver`, all wired through
`ImageDocumentModel.autoTone()`. A heuristic v1, no ML — only Exposure
has a genuine closed-form solve. 3 commits (statistics layer, solver,
UI wiring), reviewer APPROVE on all 3 (the solver commit took 5 rounds,
the deepest review chain of this session — see CLAUDE.md's own Auto
Tone entry and `docs/ROADMAP_HISTORY.md` for the full story, including
a double-encode bug in Black Point's first-draft "closed-form inverse"
and a genuinely serious Contrast/Black-Point/Shadows interaction found
only by end-to-end tests that render through the real pipeline, not the
pure solver tests). Also shipped as part of the same session, ahead of
Auto Tone itself: a real pre-existing bug fix in `fixColorCast()` (its
background analysis had no guard against a stale result landing on the
wrong photo after a mid-analysis photo switch) plus a pure refactor
extracting `EditState.geometryOnlySamplingState()`, which Auto Tone then
reused. 1199 tests.

**Live-verified (2026-09-23)**, with explicit user permission (given
proactively for this task, not asked mid-session) to drive the app via
screen automation, against a Release build and two scratch synthetic
fixtures built with Python/PIL in a `livetest` folder (NOT the user's
real photo library; opened via File > Open, never imported into the
catalog, and deleted afterward along with their sidecars):
- **A dark fixture** (a near-black floor, a small near-true-black
  corner patch, a dim sky strip): Auto solved `exposureEV = 3` (clamped
  to the max, correct direction), `blackPoint = -0.5` (saturated,
  matching IMPROVEMENTS.md D26's own documented near-universal
  saturation), `contrast = +0.138`, `vibrance = +0.239`, and correctly
  left `curvesShadows`/`curvesHighlights` at `0` (the crushed corner is
  a small enough fraction of the frame that it triggers Black Point's
  own 0.5th-percentile threshold but not Shadows' own 5th-percentile
  one — a real, sensible distinction, not an oversight).
- **A bright fixture** (a near-white floor, a lighter near-white sky):
  Auto solved `exposureEV = -1.548` (correct direction, reducing
  exposure), `blackPoint = -0.5` again, `contrast = +0.291`,
  `vibrance = +0.239`, and again `curvesHighlights = 0` — the solved
  Exposure reduction alone already pulls the near-white content below
  the Highlights trigger threshold, so Highlights correctly has nothing
  left to do; not a bug.
- Both fixtures: `whiteBalanceTemperature`/`whiteBalanceTint`,
  `brightness`, `brilliance`, and all 3 `levels*` fields stayed exactly
  at their identity defaults — confirmed Auto Tone touches only its own
  6 documented fields.
- **Idempotence**: clicking Auto twice on the dark fixture produced
  bit-identical solved values (verified via an order-independent JSON
  comparison of the saved sidecar, since `JSONEncoder`'s key order
  itself isn't deterministic — a real, if harmless, difference between
  the two raw files that a naive text diff would have misread as a
  content change).
- **Undo**: a single ⌘Z after Auto reverted all 6 fields to exactly `0`
  in one step (confirmed via the sidecar, not just the UI), matching
  the atomic-commit design.
- **Not verified live**: the "switch photos mid-analysis" stale-write
  guard — the analysis completes in well under a second, too fast to
  reliably race via UI automation; treated as adequately covered by the
  design review (the same `analysisGeneration` mechanism `fixColorCast()`
  already uses) rather than chasing a flaky live race condition.
- The Adjust sidebar's own content did not render in `screencapture`
  output in this environment for reasons unrelated to the app itself —
  worth recording since it cost real time this session: `screencapture`
  reliably shows the window chrome and the Adjust/Filters/Crop/Clean Up
  tab bar, but the sidebar's sliders/buttons never appeared in a
  screenshot despite AX confirming they were mounted, clickable, and
  producing correct results (cross-checked directly against the sidecar
  file throughout). A SEPARATE, real finding worth its own note: this
  Mac has two displays, and the app's window opened on the SECOND one
  (`window position` returned a NEGATIVE x-coordinate) — `screencapture`
  with no display argument only captures the main display, so the first
  several screenshots this session appeared to show nothing happening
  at all until the window was explicitly repositioned onto the main
  display. Both quirks are worth remembering for the next live-
  verification session in this environment, whatever the root cause
  turns out to be.
- One incidental discovery, not a bug: this Mac's real, personal
  PhotoApp installation has previously been used on real photos outside
  any test folder (a `.photoapp.json` sidecar was visible next to a real
  file on the Desktop during this session) — untouched by this session,
  which worked exclusively in the scratch `livetest` folder throughout.

**Also tried against a real photo from the user's own library
(2026-09-23, same session)**: `~/Pictures/Bolivia_trip/group_photo/
IMG_6564.jpeg`, which already had a pre-existing sidecar from a prior
Curves v2 testing session. The existing sidecar was backed up to
`/tmp/IMG_6564_baseline.json` before touching it. Auto solved
`exposureEV = 0.200`, `blackPoint = -0.5` (saturated, matching D26),
`curvesHighlights = -0.091`, `curvesShadows = 0`, `contrast = 0.0146`,
`vibrance = 0`; White Balance was untouched, matching the design. The
app was quit and the backed-up sidecar restored via `cp`, then verified
byte-identical via `diff` — the real photo's own edit state was left
exactly as found.

See "Exact next step" below — Auto Tone's own tuning constants are
still unmeasured starting points; nothing found in this live-
verification pass (synthetic fixtures OR the real photo) currently
motivates changing any of them.

Phase 2 (Edit engine) through Phase 7 (Local Adjustments/Masking) are all
✅ FULLY COMPLETE, Curves v2 (Tier-2 Lightroom gap) is fully shipped,
reviewed, and live-verified, and **Grain** (Tier-1 Lightroom gap) is
shipped. **Chromatic Aberration removal ("Defringe") is now FULLY
SHIPPED AND LIVE-VERIFIED (2026-09-22)** — `defringePurple`/
`defringeGreen`, the 10th custom kernel, a two-part stage after Sharpen/
before Grain. 1155 tests. Reviewer: 4 rounds, FIX FIRST x3 → APPROVE —
round 1 caught a genuinely serious bug (the first ordering test's
"reversed" case never actually reversed the order, producing a false
"the two stages commute" finding that every doc comment then repeated);
round 2 caught a real image-math bug (a forced-opaque alpha bias made
Core Image report an infinite extent, silently defeating
`.clampedToExtent()` and desaturating a ring around the entire image
border) plus a second ordering overclaim (the corrected test still only
sampled 2 favorable pixels; a wider sweep showed the reversed order
actually wins in aggregate, so the Sharpen ordering is now honestly
documented as a convention, not a requirement); round 3 verified round
2's fixes by independent re-measurement and found 2 more comment-only
staleness issues; round 4 confirmed those and caught one more stale
doc paragraph in this very file. See the "Done" entry below for the
full corrected story.

**Live-verified (2026-09-22)**, with explicit user permission for this
session to drive the app via synthetic screen automation, against a
constructed `fringe_test.jpg` (a scratch synthetic image with real
lateral chromatic-aberration fringing — purple/magenta on one edge,
green on the other, built via Python/PIL and opened via File > Open,
NOT imported into the catalog; deleted afterward along with its
sidecar). Confirmed on a real Release-build render: `defringePurple`
alone cleanly removes the purple fringe while leaving the green fringe
completely untouched (independence confirmed visually, not just in
unit tests); adding `defringeGreen` removes the green fringe too, down
to a clean edge with no visible residual color on trunk/branch/wire
edges of varying widths (3-14px); the strength ramps smoothly from a
faint residual tint at 10% to full removal by ~40-100%, with no visible
over-aggressive artifacts on the flat sky background or the dark
branch cores. Unlike Transform Scale/Aspect's own live-verification
(which surfaced a real "too weak" finding needing a retune), Defringe's
"principled starting constants" (hue windows, edge threshold, radius
fraction) held up well on first try — no retune indicated at this time.

**Manual Transform Scale/Aspect (Tier-1 Lightroom gap) is FULLY SHIPPED** — Lightroom's own Transform-panel "Scale"/"Aspect"
sliders (labeled "Scale"/"Stretch" in this app's UI to avoid colliding
with the existing crop aspect-RATIO "Aspect" section), a new
`EditPipeline.applyTransformScale` stage between Perspective and Flip.
1144 tests (14 new). Reviewer: 4 rounds, FIX FIRST x4 — round 1 caught
a real extent-preservation bug self-caught via a failing test before
review even started (`.cropped(to:)` alone is not sufficient; fixed
with a composite-over-transparent-canvas technique) plus 4 stale doc
enumerations; round 2 caught, and PROVED empirically by reverting the
fix and re-running the suite, a genuinely asymmetric and completely
test-unguarded `aspectFactor` formula (fixed with a log-symmetric `pow`
formula plus magnitude-discriminating tests verified to fail under the
old one) plus more stale docs and an undocumented minification-
aliasing limitation (now IMPROVEMENTS.md D23); round 3 independently
re-ran round 2's own falsification technique to confirm it, catching
one more stale doc enumeration; round 4 caught the pipeline's own
file-header comment still describing the Transform/Distort group as 3
stages instead of 4. See CLAUDE.md's Manual Transform Scale/Aspect
entry for the full write-up. NOT yet live-verified — see "Exact next
step" below.

**Point Color (Tier-1 Lightroom gap) is FULLY SHIPPED** —
both Slice A (backend, 2026-09-18) and **Slice B (the eyedropper UI,
2026-09-18)**. Slice B needed `EditPipeline.apply(_:to:truncatingColorAt:)`,
a new pipeline-internal truncation mechanism, because the existing
`pickColorRangeTarget` "zero the downstream fields" technique cannot work
here — `EditPipeline.effectiveTone(_:)` blends `brilliance` into both the
upstream contrast/shadows/highlights (before Point Color's own pipeline
position) and the downstream saturation (after it), so no field
assignment can neutralize one half without erasing the other. New
`PointColorSelection.swift` mirrors `PointColor.cikernel`'s own headroom-
normalize + `rgb2hsl` on PERCEPTUAL (not scene-linear) RGB, matching the
domain Point Color's kernel actually selects in. See CLAUDE.md's Point
Color entry for the full write-up, including this slice's own 6th-
mutual-exclusion-site count and its keyboard-crosshair wiring (closing
this feature's own share of IMPROVEMENTS.md D14, distinct from the Color
Range mask's own still-open, still-mouse-only eyedropper). 1131 tests
(24 new). Reviewer: 2 rounds, FIX FIRST → APPROVE. Round 1 caught two
missed mutual-exclusion sites, an asymmetric Compare-mode handler, a
non-finite-target integrity gap, and (the substantive one) that the new
tests never actually exercised the real kernel — all fixed. Round 2
independently re-derived all 8 fixes (including an adversarial test —
temporarily neutering the truncation feature and confirming the new
end-to-end test actually fails without it) and logged 2 small non-
blocking follow-ups (a stale `targetSaturation` doc-comment range claim,
now fixed; a `PixelSampler`/kernel premultiply-domain nuance shared with
the WB/Color-Range eyedroppers, added to IMPROVEMENTS.md's mode-enum
entry) — see CLAUDE.md's Point Color entry for the full write-up.
Committed in 5 logical commits (pipeline truncation, selection math,
eyedropper model call + binding, sidebar UI + ContentView wiring, docs).

**Color Grading (Tier-1 Lightroom gap) is FULLY SHIPPED** —
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
value display; only Luminance has a real slider).

**A post-ship bug-fix round (2026-09-18) is also done**: the user live-tested
Slice B and found 3 real bugs (sidebar growing during a wheel drag, the
sidebar's narrow default width, the edited-indicator shifting the
segmented picker) — see IMPROVEMENTS.md D21 and the "Done" entry below
for the full story, including two disproven fix attempts caught live
before the shipped one. 4 commits, reviewer APPROVE after 4 rounds
(FIX FIRST × 3, all on doc-comment accuracy by round 3-4 — the code
itself was correct from round 3 on).

**Point Color Slice A (backend) is now SHIPPED (2026-09-18)** — the
user's selected next Tier-1 Lightroom gap after Color Grading. New
`EditState.pointColors` variable-length collection field, `PointColor.
cikernel` (9th custom kernel, generalizing Selective Color's hue-band
shape to one arbitrary picked target), `EditPipeline.applyPointColors`.
4 commits, reviewer APPROVE after 3 rounds (FIX FIRST → FIX FIRST →
APPROVE) — round 1 caught a real kernel bug (fabricated achromatic hue
falsely selecting/rejecting neutral pixels) and a pipeline-order test
that would have passed with the stage deleted entirely; round 2 caught
a doc overclaim about the missing luminance-selection axis, now logged
honestly as IMPROVEMENTS.md D22. All 1107 tests pass. Slice B (the
eyedropper UI) not started — see CLAUDE.md's Point Color entry for the
full reviewer write-up.

See CLAUDE.md's roadmap for the full phase list and
`docs/ROADMAP_HISTORY.md` for detail on anything already shipped.

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

**Auto Tone (2026-09-23)**: a one-click "Auto" button (first row of the
Light section) solving Exposure/Black Point/Highlights/Shadows/Contrast/
Vibrance from a new whole-image tonal-statistics sampler. No new
`EditState` fields — writes 6 existing ones. 3 commits, each its own
reviewer round:

1. **Statistics layer** (`ToneStatistics`/`ImageToneStatistics`) — 2
   rounds, FIX FIRST → committing (round 3 would only re-confirm an
   already-verified tolerance fix). Round 1 caught a real bug:
   `CIContext.render`'s premultiplied output was read as straight,
   skewing percentiles near a resampled edge (MEASURED: `percentile0_5`
   read 0.134 instead of 0.18 on a uniform-gray 3000x2000 bitmap) — fixed
   by dividing by alpha, plus new bitmap-backed test fixtures, since
   constant-color-generator fixtures can't exercise this bug at all.
   Logged as IMPROVEMENTS.md D25: `ImageAverageColor`/`PixelSampler`
   share the identical latent bug, not fixed there (out of scope).
2. **`AutoToneSolver`** — 5 rounds, FIX FIRST x4 → APPROVE, the deepest
   review chain of this session. Round 1 caught Black Point's
   "closed-form inverse" was wrong (a double-encode bug in
   `ToneCurve.cikernel`'s own second `srgbEncode`), which once fixed
   correctly revealed the mechanism's own narrow reach (only floors
   already very close to true black are reachable at all) — logged as
   IMPROVEMENTS.md D26. Rounds 2-4 found and fixed a genuinely serious
   full-pipeline bug, in two stages, entirely via the end-to-end tests
   (the pure solver tests never caught it): Contrast, which runs before
   Curves, could independently crush the very shadow floor Shadows was
   trying to lift — first by pushing it negative (clipping hard to 0),
   then, after a first fix, by a subtler variant on a floor just above
   Shadows' own trigger threshold. A first fix attempt (blanket-suppress
   Contrast whenever Shadows triggers) itself broke 2 pre-existing tests
   by also zeroing a genuinely beneficial NEGATIVE Contrast solve.
   Final fix: one cap, derived to keep the post-Contrast value at or
   above `kShadowFloorPerceptual` (not just non-negative), which
   subsumes the earlier override entirely. Round 5 (independent
   re-derivation plus a 95-fixture sweep through the real pipeline)
   confirmed the math and found only stale doc comments. See CLAUDE.md's
   own Auto Tone entry and `docs/ROADMAP_HISTORY.md` for the full,
   measured story.
3. **UI wiring** (`ImageDocumentModel.autoTone()` + the Light-section
   button) — reviewer APPROVE, no issues. Commits all 6 fields as one
   atomic undo step (`applyPreset(_:)`'s own pattern), not the debounced
   path `fixColorCast()` uses.

Also shipped in this same session, ahead of Auto Tone itself: a real
pre-existing bug fix in `fixColorCast()` (no guard against a stale
background-analysis result landing on the wrong photo after a
mid-analysis photo switch — fixed with a new `analysisGeneration` token
Auto Tone also uses) and a pure refactor extracting
`EditState.geometryOnlySamplingState()`. 1199 tests (55 new). NOT yet
live-verified.

**Chromatic Aberration removal / "Defringe" (2026-09-22)**: two new
`EditState` fields (`defringePurple`/`defringeGreen`, 0...1, identity 0),
the 10th custom kernel (`Defringe.cikernel`), and a new
`EditPipeline.applyDefringe` stage — see CLAUDE.md's own roadmap entry
for the shipped design. Deliberately scoped to Defringe alone, not
Lightroom's lens-profile-dependent auto-CA checkbox (no data source for
that in this app).

This slice's reviewer round caught a genuinely serious bug, worth
recording in full: the first draft of `testSharpenAndDefringeOrderIsMeasuredToNotMatter`
built its "reversed" case by nesting `EditPipeline.apply` calls in a way
that accidentally applied Sharpen before Defringe BOTH times — comparing
an order against itself. That vacuous test "measured" a false
commute, and every doc comment (`EditState.sharpness`, `EditState.
defringePurple`, `EditPipeline.applyDefringe`, the pipeline's own file
header) was written to match the false finding. Caught by an
independent reviewer re-measurement with the bug fixed, then
independently re-verified in-session with a corrected harness (deleted
before commit) before rewriting anything.

That "corrected" finding was ITSELF an overclaim, caught by a second,
independent reviewer round (see the "Round 2" write-up below for the
full story) — the version that follows is the FINAL, twice-corrected
one. Fixing the vacuous-test bug produced a test that only sampled the
2 pixels (x=400/401) where the shipped Sharpen-then-Defringe order
happens to win, and the doc comments then claimed this as a "measured
requirement." A wider 9-point sweep shows the REVERSED order actually
wins at 4 of 9 columns, shipped at 3, ties at the 2 pixels carrying
real input fringe, and leaves ~46% LESS residual chroma in AGGREGATE —
not a single outlier pixel, the reversed order is better overall on
this fixture. The mechanism claim was also wrong: at most sampled
pixels the INPUT is already perfectly neutral (chroma 0), so Sharpen's
per-channel overshoot mostly MANUFACTURES fresh colored fringing next
to a misregistered edge, rather than "shifting" an existing fringe's
hue. Per CLAUDE.md's own rule for a measurement that comes back weak,
Sharpen-before-Defringe now ships as a CONVENTION (Sharpen is a
documented fringing producer elsewhere in this codebase, so Defringe
naturally reads as the cleanup step), NOT a requirement — the test is
`testSharpenBeforeDefringeIsAConventionNotARequirement`, and it asserts
the aggregate 9-point finding directly, not just the 2 favorable pixels.

A SEPARATE, genuinely unconditional ordering requirement was found
independently while investigating item 10 of the round-1 reviewer's own
list (no Defringe/Grain ordering test existed yet): Grain's
high-frequency per-pixel noise, if it ran BEFORE Defringe, inflates the
edge gate's own `localMax - localMin` signal enough to fool it into
treating FLAT content as a real edge — breaking `defringePurple`'s
documented flat-subject-protection guarantee across the WHOLE image,
not just at real edges (measured: a large flat saturated purple region
desaturates almost to gray). Defringe running before Grain avoids this
entirely — unlike the Sharpen ordering, this one IS a real, MEASURED,
unconditional requirement, and every doc comment now keeps the two
orderings explicitly distinct rather than bundled into one "both
measured requirements" claim. Both orderings now have real, permanent
tests (`testSharpenBeforeDefringeIsAConventionNotARequirement`,
`testDefringeMustRunBeforeGrainOrTheFlatGuardBreaks`) and accurate doc
comments throughout — see the "Round 2" write-up below for the other
issues (a real image-math bug, a stale downstream-field list) that same
round caught.

Other reviewer-caught issues, all fixed: two test fixtures
(`testDefringePreservesHighlightHeadroom`, `testDefringePreservesExtentAndAlpha`)
sampled FLAT content where the kernel's edge gate never actually
engages, so they'd have passed even if the active code path were
broken — fixed to sample inside a real fringe band, with a genuine
>1.0-luma fringe color for the headroom case (found via a temporary
harness, per this codebase's own measurement convention) and a
correctly-constructed alpha<1 fixture for the alpha case (which itself
surfaced a second real finding: `CIColorMatrix`'s implicit premultiply-
on-output behavior — the same mechanism documented in this file's own
Grain entry below — means scaling ONLY `inputAVector` is the CORRECT
way to build an alpha<1 fixture; manually rescaling R/G/B too, which
looked more "obviously correct," actually double-scales and is wrong).
Also fixed: an overclaiming "two halves" comment on the radius-scaling
test (only one half was ever asserted), a 5°-off hue-label comment, two
stale pipeline-stage enumerations (the file header, and `EditState.
grain`'s own "true final stage, after Sharpen" claim, now after Sharpen
AND Defringe), and a genuine, now-documented limitation (IMPROVEMENTS.md
D24): the edge gate protects flat purple/green subjects but not
TEXTURED ones in the target hue — a real foliage-against-sky green
region desaturates too (measured: chroma 0.270 -> 0.022), inherent to
any hue-band defringe approach without a separate selection axis
(Lightroom's own Defringe has a Hue Range control for this; not built
here).

All 1154 tests passed at this point — but this was round 1 of the
reviewer's pass, not the end of the story; see the round 2 write-up
immediately below before treating any of the above as final.

**Round 2 (same session, re-review after the round-1 fixes above)**
caught three more real issues, the first genuinely serious:

1. **A real image-math bug, not just docs**: `applyDefringe`'s luma
   image is built via a `CIColorMatrix` with a forced-opaque alpha bias
   (`biasVector.w = 1`), which makes Core Image report its extent as
   INFINITE — the exact same hazard `luminanceRangeMaskImage`'s own doc
   comment already documents in detail ("re-measure the ALPHA BIAS
   specifically"). `.clampedToExtent()` on an ALREADY-infinite image is
   a no-op, so the morphology filters read true zero just outside the
   real frame, creating a spurious edge signal — and a fully
   desaturated ring, resolution-dependent width — around the ENTIRE
   border of every image. Measured before the fix: a flat saturated
   purple 400x400 desaturated to chroma ~0.015 in a border ring, vs the
   correct 0.55 in the interior. Fixed with an explicit
   `.cropped(to: extent)` before `.clampedToExtent()`; verified (temp
   harness, deleted) all border pixels now match the interior exactly,
   then locked in as a permanent test,
   `testDefringeDoesNotDesaturateTheFrameBorder`.
2. **A second, wider-reaching overclaim in the SAME ordering story round
   1 had just corrected**: fixing the vacuous test bug (see above)
   produced a test that only sampled x=400/401 — the two pixels where
   the shipped order happens to win — and the doc comments then claimed
   this as a "measured requirement." A wider 9-point sweep (independently
   reproduced in-session, not just trusted from the reviewer's report)
   shows the REVERSED order actually wins at 4 columns, shipped at 3,
   ties at the 2 real-fringe pixels, and leaves ~46% LESS residual
   chroma in AGGREGATE. Also corrected: the mechanism description itself
   was wrong — at most sampled pixels the INPUT is already perfectly
   neutral (chroma 0), so Sharpen mostly MANUFACTURES fresh fringing
   next to a misregistered edge, rather than "shifting" an existing
   fringe's hue as the round-1 doc comments claimed. Per CLAUDE.md's own
   rule for a measurement that comes back weak, this is now documented
   as a CONVENTION (Sharpen reads as a fringing producer, so Defringe
   naturally reads as the cleanup step), NOT a requirement — the test
   was renamed `testSharpenBeforeDefringeIsAConventionNotARequirement`
   and now asserts the aggregate finding directly, not just two
   favorable pixels. The Grain-ordering half
   (`testDefringeMustRunBeforeGrainOrTheFlatGuardBreaks`) is unaffected
   — that one remains a real, unconditional, MEASURED requirement, and
   every doc comment now keeps the two orderings explicitly distinct
   rather than bundled into one "both measured requirements" claim.
3. **A stale downstream-field list**: `ImageDocumentModel
   .pickColorRangeTarget` (the Color Range mask eyedropper's sampling
   helper) zeroes every global stage that runs after the mask stage so
   the sampled color matches what `ColorRange.cikernel` actually sees —
   `defringePurple`/`defringeGreen` were missing from that list, so a
   tap near a high-contrast purple/green edge would have recorded a
   wrongly-desaturated target. Fixed (both the assignment block and the
   doc comment's own enumeration) — CLAUDE.md already flags this exact
   list as having gone stale twice before; this is the third.

Also fixed: a misleading test-fixture comment (`misregisteredEdgeImage`'s
alpha-reset step does NOT leave RGB untouched — `CIColorMatrix`'s own
implicit premultiply-on-output behavior divides it by 3, so the
fixture's `lo`/`hi` arguments don't describe its actual on-screen
contrast; every numeric assertion that uses it is still correct, since
it's derived from the real render, but the comment was wrong) and three
stale structural proxy/thumbnail-divergence enumerations
(`ProxyScale.swift`, `ImageRenderer.swift` x2) that didn't yet mention
Defringe's own extent-fraction radius.

1155 tests pass (the border-bug fix added one permanent regression
test). Reviewer round 2 of 2 this paragraph describes; the full 4-round
story (rounds 3-4 were doc-comment-accuracy only) and final APPROVE are
recorded in the "Current phase" section above — this paragraph is
stale, corrected 2026-09-23: Defringe IS committed (see recent commit
log), same as CLAUDE.md's own roadmap entry and docs/ROADMAP_HISTORY.md
already say.

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

**Color Grading Slice B post-ship bug-fix round (2026-09-18)**: the user
live-tested the just-shipped wheel UI and found 3 real bugs, each fixed
and (mostly) live-verified in the same session. Full blow-by-blow,
including the two disproven fix attempts, lives in IMPROVEMENTS.md's
D21 — summarized here:

1. **Sidebar visibly grew wider while dragging the wheel's puck, then
   snapped back on release.** `ColorGradingWheelView`'s frame was
   `aspectRatio(1, .fit)` + a `min/max` range, which re-negotiates on
   every `GeometryReader` re-evaluation — i.e. every `DragGesture.
   onChanged`. Fixed with an exact, unnegotiated `.frame(width:height:)`
   (`wheelDiameter = 190`). Mechanism is a documented WORKING HYPOTHESIS
   (observed and fixed, not instrumented) per this project's own
   measurement-honesty convention.
2. **The Adjust sidebar's default width never actually widened**,
   despite two `idealWidth` bumps (300 -> 340 -> 360) earlier in this
   same session. User-caught via two side-by-side fresh-launch
   screenshots (no photo vs. photo loaded, both showing an identical,
   too-narrow sidebar) that `idealWidth` was never taking effect at
   all on `HSplitView`'s cold-start layout. Fixed by raising `minWidth`
   (260 -> 360) instead — a hard floor `HSplitView` actually respects.
3. **The edited-state indicator shifted Midtones/Highlights right the
   moment Shadows became edited.** Root cause: `.pickerStyle(.segmented)`
   is backed by a real `NSSegmentedControl`, which auto-sizes each
   segment to its own label STRING — appending `" •"` conditionally
   grew that segment and shifted every segment after it. TWO fix
   attempts were tried and DISPROVED live before the one that shipped:
   (a) keeping the dot glyph always present and only varying its COLOR
   (`.clear` vs. inherited) — a live screenshot showed all three
   segments with a permanently solid dot, since `NSSegmentedControl`
   ignores `Text` styling entirely and just draws the plain string; (b)
   a separate row of per-segment dots positioned under the picker — this
   one DID visually work in a live screenshot, but a reviewer
   re-derivation caught that its `HStack`/`Spacer` positions don't
   actually align with the native control's own (unequal, auto-sized)
   segment centers, and the screenshot only looked right because the
   one edited range (Shadows) happened to also be the row's leftmost
   dot. **Shipped fix**: segment labels are now permanently plain,
   never varying (eliminating the original bug's root cause too), and
   a separate caption below the picker — `colorGradingEditedRangesSummary`,
   e.g. "Edited: Shadows, Midtones" — names the edited ranges instead of
   marking them positionally, sidestepping the alignment problem
   entirely. Live-verified with 3 progressive user screenshots.

All fixes reviewed: 4 rounds (FIX FIRST → FIX FIRST → FIX FIRST →
APPROVE) — rounds 1-2 caught the disproven fix attempts and several
real issues (a stale cross-reference, an overclaimed layout-instability
mechanism, the alignment bug above, an unverified/overclaiming
accessibility comment); rounds 3-4 were doc-comment-accuracy only, the
code itself was correct from round 3 on. All 1088 tests pass throughout
(no test changes needed — these were pure UI-layout/rendering fixes).
Committed in 4 logical commits (wheel frame fix, sidebar width fix,
segmented-picker fix, docs).

**Point Color Slice A / backend (2026-09-18)**: the user's selected next
Tier-1 Lightroom gap after Color Grading. New `Sources/EditEngine/
PointColor.swift` (a picked target hue/saturation + Hue/Saturation/
Luminance adjustment + falloff `range`, `EditState.pointColors: [PointColor]`
— this app's THIRD variable-length collection field after `redEyePoints`
and `masks`, same treatment: cleared by `comparisonOriginal()`, not
copied by `applyingPreset`, excluded from `requiresRawRedecode`).
`init(from:)` deliberately lives in an `extension PointColor { }`, not
the primary struct body, matching `Mask`'s own file structure, so
Swift's synthesized memberwise initializer stays available alongside
the custom schema-tolerant Codable decode.

`Sources/Rendering/Shaders/PointColor.cikernel` (9th custom kernel):
generalizes `SelectiveColor.cikernel`'s proven shape (raised-cosine hue
falloff, headroom-normalize before HSL) from 8 fixed named bands to ONE
arbitrary picked target, plus a new saturation-distance axis (so a
picked pale pink and a picked saturated red are correctly treated as
different targets). Applied as N sequential kernel passes (matching
`PointToneCurve`'s "N passes of one shared kernel" precedent for a
variable/optional set of stages, not packed into fixed vec4 slots the
way Selective Color's fixed 8 bands are), immediately after Selective
Color in the perceptual sandwich — MEASURED non-commuting with it
(temporary swap-rebuild-remeasure, reverted): with Selective Color's
`redHue: 1` and a matching Point Color `hue: -1` both active on a red
test pixel, shipped order gives `(0.6, 0.05756, 0.05)`, reversed order
gives `(0.6, 0.05, 0.18564)` — a 0.13564 gap on blue, ~68x this suite's
0.002 tolerance. `PointColorTuning.swift` holds the hue/saturation
window lerp constants — an honestly-labeled principled starting point,
not yet measured (no UI exists yet to visually tune against), with
`range` clamped to 0...1 before use.

Deliberately hue+saturation selection only, no luminance-distance
axis: after headroom normalization the kernel's own L is relative, not
absolute (a 1.4-peak red and a 0.7-peak red can normalize to the same
L), so a naive luminance axis would conflate genuinely different
source brightnesses. Real, accepted consequence — a divergence from
Lightroom's own Point Color — logged as IMPROVEMENTS.md D22: a bright
highlight and a dark shadow of the same picked hue/saturation are
inseparable by this kernel.

1107 tests (19 new): kernel math measured against the real compiled
kernel (identity, hue shift, isolation, range widening, headroom
preservation both outside and inside the window, saturation
adjustment, multi-instance independence, the pipeline-order test
above), plus Codable/comparisonOriginal/preset-exclusion/catalog
JSON-column coverage extended to match `masks`' own existing tests.

Reviewer: 3 rounds, FIX FIRST → FIX FIRST → APPROVE. Round 1 caught a
real kernel bug: `rgb2hsl` returns a FABRICATED hue of 0 for any
achromatic pixel, and the kernel scored the hue axis against that
fabricated value unconditionally — a legitimately-picked desaturated
target near hue 0 falsely selected EVERY neutral pixel in the frame,
while one further away (e.g. hue 210) falsely selected NONE of the
neutral content it was picked from. Fixed by mixing the hue axis to
"irrelevant" as the pixel's own saturation approaches zero (a new
regression test, `testPointColorNeutralPixelIgnoresTargetHue`, pins
this). Round 1 also caught that the original pipeline-order test used
Selective Color's `redSaturation: -1`, which — because that stage's
own saturation delta is weighted by the pixel's own saturation —
happened to gate Point Color's own saturation-window weight to exactly
zero in the shipped order, so the test passed byte-identically even
with the Point Color stage deleted from the pipeline entirely; fixed
by switching to `redHue` (see the measured numbers above). Round 2
caught a doc overclaim that omitting the luminance axis was forced by
a "domain hazard" — corrected to the real, narrower reason (headroom
relativity) and logged honestly as D22 rather than asserting a fix
path that hasn't been designed. All 1107 tests pass throughout.
Committed in 4 logical commits (data model, kernel + pipeline stage,
tests, docs).

**Not built yet (Slice B)**: the eyedropper UI, the `AdjustTabView`
"Point Color" section, add/select/delete instance management, and
`ContentView`'s tap-capture wiring — its own future Plan Mode session.
`PointColor.swift`'s own doc comment flags a reviewer-caught hazard for
whoever builds it: the narrow saturation window (0.05...0.5) means any
upstream stage that moves a pixel's saturation (Selective Color, global
Hue, exposure/curves via headroom normalization) can silently push a
picked color out of its own instance's selection window, so the
eyedropper MUST sample at this stage's own pipeline position — the same
"sample a truncated state" technique `ImageDocumentModel.
pickColorRangeTarget` already uses for `.colorRange` masks — not from
the final displayed pixel or the decoded original.

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
None. Auto Tone is fully shipped, reviewed (3 commits, 5 review rounds
total — see the "Current phase"/"Done" entries above for the full
story), committed, AND live-verified (against a dark and a bright
scratch fixture, confirming correct Exposure direction/clamping, Black
Point's documented saturation behavior, idempotence, and one-step
undo — see the "Current phase" entry's own live-verification write-up).
Chromatic Aberration removal ("Defringe") is fully shipped,
reviewed (4 rounds, FIX FIRST x3 → APPROVE), committed, and
live-verified — see the "Current phase"/"Done" entries above. The
"principled starting constants" (hue windows, edge threshold) held up
well on a real render; no retune needed, unlike
`kMaxTransformAspectStretch`'s own live-tuning precedent. Manual Transform Scale/Aspect is fully shipped, reviewed (4
rounds, FIX FIRST x4, plus a 1-round FIX FIRST retune pass), committed,
and live-verified by the user in a Release build (including the
Stretch-strength retune) — see the "Current phase" entry above. Point
Color Slice B (the eyedropper UI) is fully shipped, reviewed (2 rounds,
FIX FIRST → APPROVE), committed in 5 logical commits, and live-verified
— see the "Done"/"Current phase" entries above. Everything else (Color
Grading in full, and Point Color Slice A) was already shipped,
reviewed, and committed.

**Live-verified (2026-09-21)**, with explicit user permission for this
session to drive the app via synthetic mouse/keyboard events, against
`pointcolor_test.jpg` — a scratch synthetic solid-red fixture created
and destroyed within this session in a `livetest` folder (NOT the
user's real photo library; opened via File > Open, never imported into
the catalog, and deleted afterward along with its sidecar). Confirmed
the exact scenario the new end-to-end unit test proves in isolation:
with Brilliance +80% and Black & White both active (image visibly
rendering as neutral gray), arming the eyedropper and picking a point
correctly read the REAL underlying color (swatch + readout: Hue 360°,
Sat 88%) rather than the neutral gray the user actually sees on
screen — the whole reason this slice's pipeline-truncation design
exists. Also confirmed: applying a nonzero Hue adjustment to the picked
target visibly changed the render (a lighter gray), matching this
codebase's own documented Hue/B&W interaction (hue rotation changes the
resulting gray VALUE even though the output stays fully desaturated).

One real, worth-recording finding along the way: the mouse tap-capture
layer (`Color.clear.gesture(SpatialTapGesture())`, `.accessibilityHidden(true)`)
did NOT respond to synthetic clicks issued via `System Events click at`
(AppleScript's UI-coordinate click) — the click was silently a no-op,
while the SAME mechanism worked reliably for every real AX control
(buttons, checkboxes, click-to-type fields). Worked around by using the
KEYBOARD crosshair path instead (arrow-key nudge + Return commit) — this
slice's own accessibility feature, and arguably a better test of it
anyway. Matches this project's own established pattern of "don't assume
one synthetic-input finding transfers to a new gesture without
checking" (Curves v2 slice 2B found the opposite result for ITS own
drag gesture) — logged here rather than in IMPROVEMENTS.md since it
didn't block verification and no code changed as a result. The
`cliclick`/raw-CGEvent path was blocked by this session's own
permission classifier before it could be tried as an alternative.

**Live-verified (2026-09-22)**, with explicit user permission for this
session to drive the app via screen automation, against a constructed
`fringe_test.jpg` — a scratch synthetic image built with Python/PIL in
a `livetest` folder (NOT the user's real photo library; opened via
File > Open, never imported into the catalog, and deleted afterward
along with its sidecar). The fixture: a bright sky gradient with dark
backlit "branch" silhouettes of varying widths (3-14px) plus a thin
wire, with real lateral chromatic aberration applied by shifting the
R and B channels together (+2,+1 px) relative to a fixed G channel —
the textbook mechanism, producing genuine purple/magenta fringe on one
edge and green fringe on the other (confirmed by sampling raw pixel
values before opening the file, not just eyeballing it). A first
attempt shifted R and B in OPPOSITE directions, which produces
yellow/blue fringing instead — not the purple/green pair Defringe's
hue bands actually target — caught by sampling pixels before trusting
the fixture, then fixed.

Confirmed on a real Release-build render, via the Effects section's
click-to-type numeric fields (the custom `ThinSlider` control doesn't
expose a standard `AXSlider` role, so the numeric text field — this
app's own "click-to-type numeric entry on sliders" feature — was the
reliable way to set values via automation): `defringePurple` alone
cleanly removes the purple fringe while leaving the green fringe
completely untouched (independence confirmed visually, not just in
unit tests); adding `defringeGreen` removes the green fringe too, down
to a clean edge with no visible residual color on ANY of the sampled
edge widths (thick trunks, thin branches, the wire); the strength
ramps smoothly (a faint residual tint still visible at 10%, fully
clean by 40-100%) rather than snapping on/off; no visible
over-aggressive artifacts on the flat sky background or the dark
branch cores at full strength. Unlike Transform Scale/Aspect's own
live-verification (which surfaced a real "too weak" finding needing a
retune), Defringe's constants held up well on first try.

One navigation finding worth recording: the app's own AdjustTabView
sections are `DisclosureGroup`s that don't mount their child content
in the accessibility tree until expanded (confirmed: expanding the
wrong section by index first, per a wrong guess at section order,
produced zero new AX elements — not a bug, just unmounted SwiftUI
content). The reliable fix was reading `AdjustTabView.swift`'s actual
`body` source to get the exact section order (Light, Curve, Color,
Selective Color, Point Color, Black & White, Color Grading, Effects,
Red-Eye, Masks, Presets — Effects is #8) rather than guessing from
icons or trial-and-error expansion, which had already produced a false
lead (accidentally landing on Masks at guessed index 10).

## Exact next step
Nothing blocking. Copy/Paste Settings is fully shipped, reviewed (3
commits, the feature commit alone 6 rounds FIX FIRST × 5 → APPROVE),
committed, AND live-verified (2026-09-24) — see the "Current phase"
entry's own write-up for the full checklist. Pick the next Lightroom
gap and enter Plan Mode first, per this project's workflow rules (see
the list at the end of this section).

History panel is ALSO fully shipped, reviewed (2 rounds, FIX FIRST →
APPROVE), committed, AND live-verified (2026-09-24) — every item on the
plan's own verification checklist passed: sensible row summaries,
correct current/abandoned/normal row styling, a jump that updates both
the render and the sidecar, a no-op tap on the current row confirmed
(via sidecar mtime) to genuinely skip the write, an abandoned-branch
discard on a new edit from a jumped-to point, and correct toolbar
Undo/Redo interleaving with a manual jump — see its own "Current phase"
entry for full detail, including one automation-only gotcha (toolbar
Undo/Redo expose their label via the `description` AX attribute, not
`title`) worth remembering for the next live-verification session.

Auto Tone is ALSO fully shipped, reviewed, committed, AND live-verified
(dark + bright synthetic fixtures, plus a real photo from the user's own
library — see the "Current phase" entry's own write-up).
`kBlackTargetPerceptual`/`kMaxAutoBlackPoint`/`kShadowFloorPerceptual`
and the other `AutoToneSolver` tuning constants are explicitly
principled-but-unmeasured starting points (per that file's own doc
comments) — live-tuning them against a wider variety of real photos, the
same process `kMaxTransformAspectStretch` went through, is a natural
future follow-up if a real photo ever produces a visually wrong-looking
result; nothing found in this session's own live-verification (2
synthetic fixtures + 1 real photo) currently motivates a retune.
IMPROVEMENTS.md D26 (Black Point saturating to its own maximum for
nearly any photo) is the one specific open design question to weigh
while doing that — all 3 of this session's own test cases independently
confirmed that saturation happening exactly as D26 describes.

Available: Enhance/Super Resolution (the one remaining unstarted
Tier-2 item); Color Grading Slice B's own follow-ups — live-verifying
the `AngularGradient` painted-wheel convention on screen (flagged
DERIVED, not measured, in `ColorWheelGeometry.angularGradientFraction`'s
doc comment) and IMPROVEMENTS.md D20 (a numeric Hue/Saturation readout);
IMPROVEMENTS.md D22 (Point Color's missing luminance-selection axis,
needs its own design pass); IMPROVEMENTS.md D23 (Transform Scale/
Aspect's minification-aliasing gap); IMPROVEMENTS.md D25 (the same
premultiplied-alpha read bug `ImageToneStatistics` fixed for itself,
still latent in `ImageAverageColor`/`PixelSampler`); IMPROVEMENTS.md D27
(the 3 History panel nits logged this session); IMPROVEMENTS.md D28 (a
pre-existing `saveSidecarNow` load-during-save race onto the wrong
sidecar, found while closing Copy/Paste Settings' own race — affects
every ordinary debounced save, not just batch paste); and the now-6-site
mutual-exclusion mode enum IMPROVEMENTS.md logs as overdue.
