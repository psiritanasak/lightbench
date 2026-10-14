# Improvement & Optimization Backlog

Open, non-blocking gaps logged during review. **Shipped/retired entries live in
`docs/IMPROVEMENTS_HISTORY.md`** (same IDs, full text); only a one-line index is
kept below. Read `CLAUDE.md` first (workflow rules apply: Plan Mode per feature,
one item per session, `reviewer` agent before any commit) and `PROGRESS.md`.
Verify every claim here against current code — line numbers drift. For
performance items, MEASURE before and after.

## Shipped / retired index (details in docs/IMPROVEMENTS_HISTORY.md)
- **P1** — ThumbnailCache serializes all decodes through the actor — WRONG, RETIRED 2026-08-28
- **P2** — Full-resolution pipeline render on every interactive slider tick — SHIPPED 2026-09-07
- **P3** — `draw(in:)` rebuilds the pipeline graph on renders where nothing changed — SHIPPED 2026-09-04
- **P4** — `CatalogModel.refresh()` refetches the whole library on every rating/flag/membership tap — SHIPPED 2026-08-28
- **P5** — Histogram / average-color renders: verify the downsample position — SHIPPED 2026-09-07
- **D1** — Editor has no way to move between photos (biggest UX gap) — (a) SHIPPED 2026-08-28, (b) SHIPPED 2026-08-28
- **D2** — Library thumbnails don't scale with the grid — SHIPPED 2026-08-31
- **D3** — No indication in the Library of which photos have edits — SHIPPED 2026-08-31
- **D4** — Library keyboard support — SHIPPED 2026-09-08
- **D5** — Library management (remove from catalog, rename/delete collections, batch add, missing-file detection, relocate) — SHIPPED 2026-08-31..09-08
- **D6** — Accessibility pass over custom controls — SHIPPED 2026-09-08
- **D8** — Keyboard/AT paths for the three mouse-only spatial overlays (deferred from D6) — SHIPPED 2026-09-09
- **D14** — No keyboard/AT path to pick a Color Range mask's target color (Phase 7 slice 5, second half) — SHIPPED 2026-09-25
- **D23** — Transform Scale/Stretch has no minification prefiltering (reviewer-caught) — SHIPPED 2026-09-29
- **D25** — `ImageAverageColor`/`PixelSampler` read `CIContext.render`'s premultiplied output as if it were straight (reviewer-caught, Auto Tone planning session) — FIXED 2026-09-29
- **D33** — Ghost selection IDs make Export/Add-to-Collection UI silently misleading (reviewer-caught while correcting a stale nit, 2026-09-29) — SHIPPED 2026-09-29
- **D7** — Code design: split ContentView.swift (1352 lines) — SHIPPED 2026-08-28
- **D34** — `xcodebuild test` ran migrations against the user's REAL catalog (found 2026-09-30, Pick/Reject live check) — SHIPPED 2026-09-30
- **D37** — A truncated JPEG/PNG exported or enhanced without any warning (Phase 8 audit, 2026-09-30) — SHIPPED 2026-09-30
- **D39** — A collision suffix " (N)" can push a file name past 255 bytes — FIXED 2026-09-30 (`PhotoExporter.baseNameFitting`)

- **Open, from the LightCraft comparison (2026-10-08):** **D57** (feature gaps) and **D58** (UI/UX) — see the end of this file.

Residual open items from shipped entries:
- **D14** — mask/point-color *selection* state (`selectedMaskID`/`selectedPointColorID`) is still a 3-way inconsistent mix across the arm sites (no functional consequence found); `SelectiveColor.cikernel`'s `rgb2hsl` has no negative-channel clamp. Full text in history.
- **D34** — Xcode Previews (`XCODE_RUNNING_FOR_PREVIEWS`) still open the real catalog; Swift Testing / non-`xcodebuild` test plans not verified to set the XCTest markers.

## Open items

### D35. Lightroom Classic parity backlog (researched 2026-09-30) — feature gaps, prioritized
Sources: Lightroom Classic releases 14.4 (Jun 2025) through 15.6 (Sep 2026) as summarized by Lightroom Queen and PhotoshopCAFE (Adobe's own release-notes pages returned 403), plus general Lightroom knowledge; items marked (R) are confirmed in those summaries, the rest are unverified. Release-note additions are in the second list below. Supersedes nothing in CLAUDE.md's "Gaps vs. Adobe Lightroom Desktop" (which covers Develop only) — this adds Library/Import/Export/multi-photo gaps. Each item is its own session (Plan Mode first). Priority order (value / effort). **Progress:** color labels shipped 2026-09-30 (item 4's first piece); batch rename (item 5/Library) not yet.

1. ~~**Profiles / LUTs** (`.cube`, Amount slider)~~ ✅ SHIPPED 2026-10-02 (built-in looks + `.cube` import + Intensity; follow-ups in D45) + small Develop gaps: Vignette Softness (✅ SHIPPED 2026-10-12), B&W Intensity/Neutrals/Tone/Grain, Color Grading Blending/Balance (✅ SHIPPED 2026-10-12, no live check yet) + Global wheel (✅ SHIPPED 2026-10-12), HSL per-band Lightness check, Calibration panel, custom crop overlays.
2. **AI masks via Apple Vision / Core ML**: Subject, Sky, Background, People parts, Landscape (R: Feather/Edge refine sliders, Aug 2026), Object Select, Depth Range, in-mask Add/Subtract/Invert layers. Subject/People: spike DONE and `.subject` mask v1 SHIPPED 2026-10-01 (Subject + Invert; cuts: Feather/edge refine, per-person pick, overlay — see docs/ROADMAP_HISTORY.md); Sky/Landscape: spiked 2026-10-05 — NEEDS-MODEL for cloud-capable quality (see docs/ROADMAP_HISTORY.md "Sky / Object mask feasibility spike"); a clear-sky-only classical v1 behind a `VNClassifyImageRequest` gate is feasible. **USER DECISION 2026-10-05: neither for now** (no bundled model, no clear-sky-only half-feature). Revisit only if a good Sky/Object mask becomes a priority; the next step would be a short model spike (licence, size, one candidate tried on the 6 hard photos in the findings).
3. **Healing / Clone spot removal** (classic patch, no ML); later Generative Remove (R: better reflection removal, Sept 2026), Generative Expand / Crop & Expand (R), Lens Blur, AI Denoise.
4. **Library basics**: ~~keywords~~ ✅ v1 shipped 2026-10-02 (D47; filter + search + sheet), ~~Smart Collections~~ ✅ v1 shipped 2026-10-02 (D49) + IPTC/EXIF metadata read/write, color labels, Smart Collections, Collection Sets, Stacks, virtual copies/snapshots, metadata filter/search, standard XMP sidecar interop (ours is proprietary `.photoapp.json`).
5. **Export / import upgrades**: metadata + watermark, color space/bit depth, output sharpening, ~~naming templates~~ (done 2026-09-30, with batch rename), export presets, HEIC/AVIF/DNG; import rename/copy/apply-preset, tethering, watched folders.
6. **Multi-photo**: HDR merge, Panorama merge, focus stacking, granular Sync Settings dialog, Survey/Reference view.
7. **Culling / faces** (duplicate detection ✅ v1 shipped 2026-10-06, see D53): Assisted Culling, duplicate detection, face detection + People view (R: Faces panel with Eye Focus / Eyes Open scores, June 2026).
8. ~~**Persist edit history** across sessions~~ ✅ shipped 2026-10-05 (see D51), Smart Previews (offline editing), folder move/rename inside the app, Soft Proofing, Print/Slideshow/Map (low value for this app).
9. ~~Phase 8 polish (tiled rendering, perf)~~ — DONE 2026-09-30 by measured audit (see D36/D38); start with the open items below (D28).

**Additions from the release-note pass (14.4 → 15.6), not covered in the list above:**
- **Retouch**: automatic Dust/sensor-spot removal (15.0), Distraction Remove for people and reflections (14.4, improved 15.0/15.6), shadow + reflection detection when removing an object (15.0). Fold into item 3 — a classic spot-detect + heal pass could cover dust without ML.
- **Point Color "Variance" slider** (15.0) — evens or increases color contrast within the picked range. Small extension of our shipped Point Color (same kernel family; own design pass).
- **HDR editing/output**: HDR Headroom / HDR Limit slider (1.0–8.0), Display P3 + HDR + video color spaces, 32-bit HDR hand-off to Photoshop, HDR panorama. Our pipeline already preserves >1.0 linear headroom; needs an EDR (extended dynamic range) display path — new architecture, own spike.
- **AI mask refinement**: Feather/Edge sliders (15.5), finer Select Subject edges (hair/feathers, 15.4), Snow landscape mask (15.0), Scene Quick Actions (14.4, e.g. Water slider), Adaptive Presets incl. seasonal Landscape (15.0), new film-inspired presets/profiles (15.3). Goes with item 2 / item 1.
- **Enhance**: Super Resolution + Denoise applied non-destructively without writing a DNG (14.4), Topaz 2x/4x generative upscale (15.2), Render to DNG (15.5), Flatten AI Edits (15.5). Our Enhance already writes a separate 2x JPEG; the gap is Denoise, non-baked/editable Enhance, and output formats.
- **Library**: Auto Stack by time (incl. millisecond precision) or visual similarity (15.0), Assisted Culling with Subject/Eye Focus + eyes-open scoring (15.0–15.4), duplicate detection incl. matching capture date/time + size (14.4/15.4), Color Labels (15.0), Batch Rename (also inside Export, 15.2), "Show photos in subfolders" (15.0), AI/edit-applied filters in metadata search and Smart Collections (14.4/15.4), natural-language search (cloud only, 15.3), keyword sync (15.4). Fold into items 4 and 7.
- **Robustness we lack**: relocating an entire missing folder (14.4) — our D5 relocate handles individual files only; in-app catalog-data corruption detection/repair (15.5); Background Activity Manager to pause face/duplicate scans (15.4); faster mask-brush painting (15.4; ours has a known perf finding for brush-∩-brush + Clarity).
- **Format/UI**: WebP import/edit (15.2), PNG export (14.4 — ours already has it), PSB (15.3), Photoshop export options for 16-bit ProPhoto (15.3), Zoom-while-cropping (Z key, 15.0/15.3), Rotate/Flip recorded in History + crop-mask opacity (15.5), 4K slideshow/video export (15.0), Leica/Canon tethering (15.0/15.4).
- **Generative/cloud, deliberately excluded**: Firefly edit/video/boards, Prompt to Edit (15.6, early access), Generative Expand (desktop app, 15.5), Edit Using Describe, Animate.

Deliberately not pursued: cloud sync, Adobe/Firefly integration, mobile.

### P6. Minor, take-if-passing-by

- `PhotoExporter.export`: `Data(contentsOf: tempURL)` + `data.write(to:)`
  loads the whole encoded file into memory to copy it. `FileManager.
  moveItem`/`replaceItemAt` avoids that. NOTE the surrounding comment — this
  exact combination was kept deliberately after a sandbox-entitlement fight;
  re-verify live in the sandbox before changing, or leave it.
- `LibraryGridView`: `displayedPhotos` (sort+filter over the whole array)
  recomputes on every body evaluation, and every `@Published` change on
  `catalog` (including each selection-checkbox tap) re-evaluates the body.
  Fine at hundreds of photos (documented reasoning in the code); if the
  library grows to tens of thousands, derive it into a cached published
  property instead. NOW PARTLY MEASURED (2026-08-28, while shipping D1(a)):
  one `LibraryFilterSort.apply` is 0.37 ms at 1,000 photos, 3.61 ms at 10,000
  and 18.50 ms at 50,000. D1(a) also put this on the EDITOR's hot path — the
  Photo menu's enabled state re-derives it on every Scene body pass, i.e. every
  slider tick — so this fix now has a measured case behind it at 10,000+
  photos, though it stays unjustified at this project's current scale.
- Grain: `PhotoExporter.export` resizes AFTER `EditPipeline.apply` runs, so
  an exported photo at a smaller-than-source output size will show
  attenuated grain relative to what the Editor previews (a downscale
  averages adjacent grain-perturbed pixels together). NOT measured — this
  is a structural observation from reading the export/pipeline call order,
  not a quantified claim; if it turns out to be visually significant, the
  fix is regenerating grain's noise field sized to the OUTPUT resolution
  rather than compensating after the fact. Related but distinct: the noise
  is locked to absolute `CIImage` coordinates (see `EditState.grain`'s own
  doc comment), so even at matching output size, an export won't
  necessarily reproduce the Editor preview's exact noise PATTERN pixel-
  for-pixel unless the render pipeline's coordinate origin matches too —
  not verified either way for this app's actual export path.
- `CIColorKernel(source:)`/`CIKernel(source:)` (Core Image Kernel Language)
  is deprecated — noticed 2026-09-18 after an Xcode 27 (Swift 6.4, macOS 27
  SDK) upgrade, at every one of this app's 7 custom `.cikernel` load sites
  in `EditPipeline.swift`. Still fully functional (BUILD SUCCEEDED, all
  1049 tests pass on the new toolchain) — a warning, not a break. The real
  fix is porting every custom kernel from CIKL source strings to Metal
  Shading Language (`CIColorKernel(functionName:fromMetalLibraryData:)`),
  which touches all 7 shaders in `Sources/Rendering/Shaders/` — a
  genuinely new architecture for this app's shader-loading path, not a
  quick suppression, so it needs its own dedicated session per this file's
  own "one item per session" discipline, not a drive-by fix.

---

### D9. Arrow-key nudge/resize for the Phase 7 mask overlay (deferred from Phase 7 slice 2 Session B)

`MaskOverlayView` (Phase 7 slice 2's UI half, shipped 2026-09-09) is
`.accessibilityHidden(true)` on the same justification D6/D8 already
established for Crop/Red-Eye/WB: every value it lets you drag (center
X/Y, radius X/Y, rotation, feather) is independently AT-adjustable via
`MaskDetailView`'s 14 labeled `EditSliderRow`s, so there is a real
keyboard/AT path to every value today — this item is about ergonomics
(nudging the overlay directly with arrow keys, the way D8 gave the pan
overlay arrow-key panning), not about closing an accessibility gap that
doesn't otherwise exist. Needs its own interaction design (which handle
is "focused" for a nudge, step size, whether Shift changes step size)
before it can be scoped — same category of work D8 required for the pan
overlay.

### D10. Compare Split's divider overlay vs. mask-drag gestures — a LATENT z-order hazard, currently unreachable (found, then corrected, live-reviewing Phase 7 slice 3 Session B)

`CompareDividerOverlay` is added AFTER both mask overlays
(`MaskOverlayView`/`LinearMaskOverlayView`) in `ContentView.swift`'s
`pointAndZoomOverlays`, and its own background layer is a full-`fitRect`
`Color.clear.contentShape(Rectangle())` capturing a jump-to-tap gesture
— later in the `ZStack` wins hit-testing ties, so IF a mask were ever
selected while `compareMode == .split`, every mask drag would be
swallowed by the divider's own gesture instead of reaching the mask
overlay underneath.

**Reviewer-corrected (this entry's own first draft got this wrong):**
that precondition cannot currently occur, so this is NOT a live bug.
`AdjustTabView.select(_:)` (the only path to a non-nil
`selectedMaskID`) calls `onEnterPointPickingMode()`, which sets
`compareMode = .off`; and `ContentView`'s own
`.onChange(of: compareMode)` clears `adjustPanel.selectedMaskID` the
moment `compareMode` becomes non-`.off`. Together these make
`isEditingMask && compareMode == .split` unreachable today — the two
states are already mutually exclusive by construction, the same
disarm-at-arm-site discipline every other mode pair in this file uses.
The z-order hazard above is real only as a LATENT risk: it would become
reachable the moment anyone relaxes that mutual disarm (e.g. to let a
user compare while a mask stays selected), and whoever does that should
either reorder the overlays or narrow the divider's hit-region at the
same time, not discover this the hard way. Logged here as a heads-up
for that future change, not as an open bug to fix now.

### D13. Switching photos with an unpainted Brush mask armed leaks a phantom mask (Phase 7 slice 4, reviewer-caught)

`ContentView.discardUnpaintedBrushMask` is wired to fire on every
disarm route EXCEPT photo switch, despite that function's own doc
comment previously (wrongly) claiming full coverage — caught by the
reviewer's second pass, not the first. Root cause:
`ImageDocumentModel.load(from:)` sets `currentURL` and `editState` to
the INCOMING photo synchronously, in the same block, so by the time
`ContentView`'s `.onChange(of: document.currentURL)` fires and clears
`brushPaintingMaskID`, `document.editState.masks` is already the NEW
photo's array — `discardUnpaintedBrushMask` looks the OLD mask's id up
in the wrong photo's masks and silently no-ops, while the OUTGOING
photo's phantom empty `.brush` mask has already been flushed to its own
sidecar by the pre-existing `flushPendingSidecarSave()` call in the same
navigation path. User-visible effect: "Add Brush" on photo A, don't
paint, switch to photo B — photo A's sidecar keeps a `Mask N` with no
points and identity adjustments, and (since a placed-but-inert mask
counts as a real edit, same as `redEyePoints`' own convention) "Revert
to Original" reads as enabled on photo A even though nothing visibly
changed.

Properly fixing this needs the cleanup to run BEFORE `load(from:)` swaps
state — either at every photo-switch call site (filmstrip, Library grid,
⌘←/⌘→) or via a hook inside `ImageDocumentModel` itself — a genuinely
different shape than `ContentView`'s existing single-`.onChange`
mechanism, which only ever sees state AFTER it's already changed.
Deliberately left as a documented gap rather than rushed:
`ContentView.discardUnpaintedBrushMask`'s own doc comment and its
`.onChange` call site's own comment (both in `ContentView.swift`) now
say so explicitly instead of claiming coverage that doesn't exist.

### D15. Combine-masks (intersect/subtract) v1 scope cuts (Phase 7 slice 6) — deferred, not forgotten

Session A shipped the data model (`Mask.combineMode`/`combineWithMaskID`,
`MaskCombineMode`) and the `EditPipeline.applyMasks` combine block
(intersect via `CIMinimumCompositing`, subtract via `CIMinimumCompositing`
against a Porter-Duff-inverted operand). Session B shipped the UI
(`MaskCombineTarget`/`CombineTargetSelection`/`combineRows` in
`MaskDetailView.swift`, wired from `AdjustTabView`) and live-verified all
of it — intersect confining to the overlap, subtract punching a hole,
undo/redo, sidecar round-trip, Revert to Original, and the fail-open path
below. Known v1 scope cuts, each already named at its own load-bearing doc
comment rather than silently assumed:

- **No transitive chaining.** `Mask.combineWithMaskID` always resolves
  against the referenced mask's own RAW, pre-combine shape — if THAT mask
  is itself combining with a third, the third is never consulted. Cycle-
  safe by construction (no recursion, nothing to cycle) and matches v1's
  real-world need (one mask cut by one shape); a real future feature, not
  a bug, if a chained/compound selection is ever requested.
- **One operand per mask, no union/OR mode.** Only `.intersect` (AND) and
  `.subtract` (AND-NOT) exist; a mask cannot combine against more than one
  other mask, and there's no way to union two masks' shapes into a single
  combined operand (each mask already compounds against the RUNNING image
  independently — see slice 2 — which covers the union-of-EFFECT case, but
  not a union-of-SHAPE used as one combine operand).
- **No on-image indication of the clipped/combined shape.** `MaskDetailView`'s
  Mode/With pickers (Session B) cover selecting a combine relationship, not
  a visual outline of the resulting intersected/subtracted region on the
  canvas itself — a user has to infer the combined shape from the rendered
  adjustment, the same way `.luminanceRange`/`.colorRange` already have no
  on-image shape outline of their own selection either.
- **No reference scrubbing on delete.** Deleting a mask does not clear
  other masks' `combineWithMaskID` pointing at it — left dangling on
  purpose (see `Mask.combineWithMaskID`'s own doc comment): fail-open
  renders a dangling reference as `.none`, so this is harmless by design,
  not an oversight, and Undo restores the relationship for free. **Live-
  confirmed (2026-09-15) real consequence of this, not just a theoretical
  one**: if the only OTHER mask on the photo is the one just deleted, the
  entire `combineRows` section hides (correctly — `combineTargets` is
  empty, nothing to combine against), which means the stale, now-dangling
  `combineMode`/`combineWithMaskID` on the surviving mask becomes
  completely INVISIBLE from the UI (not just unshown while a valid target
  exists) until a second mask is added again — at which point the picker
  correctly resolves back to "None" (verified: `Mode` stayed `Subtract`,
  `With` correctly re-showed as `None`, not the deleted mask). Harmless
  per the same fail-open reasoning, but worth knowing before someone
  "fixes" the hidden section as if it were a bug.
- **`Mask.id`'s own decode is still bare-`try`, not `try?`.** Unrelated to
  this slice's own two new fields (both correctly `try?`, see their decode
  site's own comments) but noted here since combine references are the
  first place a MALFORMED `id`-shaped value (not just a missing one)
  would actually matter end-to-end (a hand-edited `combineWithMaskID`
  pointing at a syntactically-invalid UUID already degrades safely via
  `try?`, but a malformed `id` on the mask itself does not) — a candidate
  for a future small session, not touched here.

`~/.claude/plans/merry-questing-gizmo.md` has both sessions' full design
history, not re-duplicated here.

### D16. Per-mask Clarity cost is SUPERLINEAR in mask count (found measuring the Texture/Clarity split, predates it)

**Not introduced by the Texture/Clarity split** — measured identical for
positive and negative Clarity, so it is a property of per-mask Clarity as
shipped in Phase 7 slice 2. Surfaced only because that slice's reviewer
asked for a perf number that had never been taken.

Measured at 4000x4000, full `CIContext.createCGImage` over the whole
extent, best of 3, `.radial` mask at center (0.5, 0.5), feather 0.5,
rotation 0 (synthetic test-process numbers — NOT comparable to the live
interactive figures in PROGRESS.md's P3/P4/P5 records):

    masks   r=0.25              r=0.90
    1       35.6 / 35.1 ms      82.0 / 83.5 ms      (clarity +1 / -1)
    3      312.5 / 313.5 ms   1811.7 / 1757.1 ms

That is 8.8x and 22x for 3 masks, not 3x. Two compounding causes, both
inherent to how `EditPipeline.applyMasks` composites: each mask's Clarity
radius is derived from the FULL image extent (correctly — see the
"Hazard 1" note in CLAUDE.md Phase 7), and each successive mask's
composite re-dilates the region of interest of everything before it, so
mask N pays for masks 1..N-1 again.

Mask RADIUS matters as much as count: one r=0.90 mask costs 2.3x one
r=0.25 mask, because cost tracks the ellipse's bounding-box ROI. Any
future fix or benchmark MUST state mask geometry — an earlier draft of
the PROGRESS.md entry recorded mask timings without it and was not
reproducible.

Not fixed here: it needs its own slice, and the interactive path is
already absorbed by `ProxyScale`'s downscaled proxy, so this bites
full-res export and the settled full-res frame rather than dragging.
Natural companion to `EditPipeline.swift`'s own `BrushStrokeImageCache`
(see its doc comment there, and CLAUDE.md's Phase 7 slice 6 perf
paragraph) — both are "applyMasks recomputes more than it needs to"
problems. Note that cache is documented in the source and CLAUDE.md, not
in this file; D15 above covers slice 6's scope cuts, not its perf work.

**Candidate fix investigated and MEASURED FALSE (2026-09-25, Phase 8
slice 1) — do not re-attempt this exact fix without new evidence (see
"what would count as new evidence" below).** The theory: `applyMasks`'s
per-mask loop never saves an intermediate, so `img` (the running
accumulator) is read TWICE per later mask — once through that mask's own
Clarity blur, once again as the blend's background — and since Core
Image's graph is lazy, mask N's reads re-evaluate masks 1..N-1's entire
chain again. Fix tried: `img.insertingIntermediate()` right after each
mask's blend — a CACHING HINT to Core Image's own renderer (not a
separate forced render call of its own), intended to let later masks'
two reads share one already-rendered buffer within the same
`createCGImage` call instead of re-deriving it. Caveat on the fix itself:
whether Core Image actually materialized an intermediate at that point
was NOT independently confirmed (e.g. via `CI_PRINT_TREE`) — that gap is
itself part of what "new evidence" for a retry would need to close.

Measured (temporary `CFAbsoluteTimeGetCurrent()` harness in
`EditPipelineTests.swift`, added/used/reverted per this file's own
convention; reproducing this entry's exact original methodology — 4000
×4000, full `createCGImage` over the whole extent, best of 3, `.radial`
mask center (0.5,0.5), feather 0.5, rotation 0, Clarity +1, fresh
`CIContext` per run): baseline measured once; the fix was then measured
twice (two independent runs) specifically to rule out a fluke on the fix
side. Results, 3-mask configurations (the only ones this fix could
plausibly help):
- r=0.25: consistently SLOWER — baseline 241.3ms, fix 312.4ms (+29.5%)
  and 319.9ms (+32.6%) on the two runs.
- r=0.9: never faster, noisy — baseline 1944.0ms, fix 1990.7ms (+2.4%)
  and 2416.8ms (+24.3%) on the two runs.

1-mask configurations (where the fix has no theoretical benefit at all,
since there's no second mask to share a cached read with) swung by up to
~40% in BOTH directions across the two fix runs relative to baseline —
consistent with ordinary run-to-run noise (GPU/thermal/JIT warmup) on
this measurement setup, not a real effect, and not informative either way
about the fix itself. Given that much noise floor, the 3-mask r=0.9
result (+2.4% to +24.3%) is properly read as "never measured faster,"
not as a precisely-bounded slowdown.

Conclusion, stated at the confidence the data actually supports: **this
specific fix did not recover any of the measured cost** — every
3-mask/Clarity configuration was flat-to-slower, never faster. Why is
NOT established by this measurement alone; two candidate explanations
remain open and were NOT distinguished between: (1) redundant graph
re-evaluation is a real cost but the intermediate's own price (a
full-extent buffer write, then read, per mask) exceeds whatever it saves;
(2) Core Image's own renderer may already share/reuse the relevant
subgraph within one `createCGImage` call well enough that this specific
theory's premise doesn't hold. Whether region-SIZE growth (each mask's
ROI dilating from the one before, per this entry's own "Two compounding
causes" paragraph above) is the real dominant cost is an UNVERIFIED lead,
not a separately-measured conclusion — a candidate worth measuring next,
not a fix to build on faith. Reverted in full (code and temporary
harness); `git diff` confirmed clean before committing this write-up.

**What would count as "new evidence" for a future attempt:** a render-
graph dump (e.g. `CI_PRINT_TREE`) confirming whether an inserted
intermediate is actually materialized where expected; and/or per-mask
timing broken down by each mask's own ROI size, to determine whether cost
tracks region growth independent of caching.

**Update (2026-09-28, Phase 8 slice 2) — the region-growth lead is now
MEASURED, with a genuinely bigger and more actionable discovery alongside
it.** Two separate temporary harnesses (`EditPipelineTests.swift`, added,
run, transcribed below, then fully reverted — `git diff` confirmed clean
before this write-up, same discipline as the 2026-09-25 entry above), both
using a fresh `CIContext()` per timed sample (per D17's own methodology-
trap lesson) and `precondition`-verified real (non-nil, correctly-sized)
`createCGImage` output at every size, so a silent fast-failure at a large
size couldn't masquerade as a real fast render.

**Finding 1 (unplanned, found while sizing the decisive test below): the
ENTIRE superlinear effect — not just its magnitude, its EXISTENCE — is
confined to images where BOTH dimensions are ≤ 4096px.** A size scan
(mask geometry held fixed: center 0.5,0.5, r=0.25, feather 0.5, clarity
+1) found a sharp, discrete cliff between 4096px and 4097px, not a
gradual fade:

    size        N=1        N=3 co-located   ratio
    4096x4096   16.8ms     102.5ms          6.10x
    4100x4100    4.4ms       4.4ms          1.00x

A follow-up (`testD16DimensionCliff`) confirmed the cliff is PER-DIMENSION
— either width or height alone exceeding 4096 is sufficient to collapse
the effect to flat/trivial cost, not a total-area threshold:

    config                                          N=1      N=3 co-located   ratio
    4096x4096 (both <= 4096)                        20.2ms   122.4ms          6.07x
    4097x4096 (width only over)                      4.5ms     4.4ms          0.98x
    4096x4097 (height only over)                      4.4ms     4.4ms          1.00x
    6016x4016 (this app's own D610 RAW target)        4.3ms     4.4ms          1.03x
    4016x6016 (D610, rotated)                         4.3ms     4.3ms          0.99x

The last two rows are the practically important ones: **this app's own
real RAW target, the Nikon D610 (6016x4016), already sits on the fast
side of this cliff in both orientations.** D16's own original 4000x4000
measurement, and every number in this entry until today, happened to be
taken exactly in the one size regime (both dimensions ≤ 4096) where the
problem exists at all. This does not prove the D610's own full-res
export/render is free of ALL mask-related cost — only that THIS specific
superlinear-with-mask-count behavior, as measured, does not reproduce at
that camera's actual resolution. Root cause of the cliff itself (almost
certainly a Core Image/Metal internal tiling or maximum-single-texture-
dimension threshold — 4096 is a common such limit on Apple GPUs) was not
investigated further; that would be its own separate spike, not a
prerequisite for reporting this measured fact.

**Finding 2 (the originally-planned test): geometric ROI overlap is a
real, reproducible contributor to the cost, measured inside the one size
regime where there's an effect to measure at all (4096x4096).** Three
independent process runs, same config each time (r=0.15 — chosen for
comfortable corner-to-center separation margin at this exact size, not
D16's own r=0.25 — anchor mask at center 0.5,0.5 held IDENTICAL across
"co-located" and "disjoint," only masks 1-2's position differs):

    run   N=1      N=3 co-located (ratio)   N=3 disjoint (ratio)
    1     15.9ms   67.5ms   (4.24x)         39.8ms   (2.50x)
    2     15.6ms   82.8ms   (5.30x)         42.9ms   (2.75x)
    3     30.3ms   66.3ms   (2.19x)         41.6ms   (1.37x)

Despite noisy absolute N=1 baselines (15.6-30.3ms) at this millisecond
scale, the WITHIN-RUN pattern is consistent across all 3 runs: co-located
cost is 1.6x-1.9x the disjoint cost for the exact same N=3 mask count and
per-mask work, every time. Moving masks 1-2 away from mask 3's own
dilated read region measurably and reproducibly cheapens mask 3's own
cost — direct, repeated evidence that geometric ROI overlap (mask 3's
Clarity blur re-evaluating masks 1-2's own expensive chains because their
painted regions sit inside its dilation halo) is a REAL contributor, not
merely a redundant-read/caching artifact (already ruled out on
2026-09-25) or a pure graph-depth cost independent of geometry (which
would have predicted NO gap between co-located and disjoint — not what
was measured).

**Verdict, at the confidence this data supports:** region growth via
geometric ROI overlap is CONFIRMED as a real, reproducible contributor to
per-mask Clarity's superlinear cost — but ONLY within a narrow size
window (both dimensions ≤ 4096px) that this app's own actual RAW target
does not fall into. No fix is proposed or attempted here, matching this
entry's own original scoping ("it needs its own slice") — and any future
fix attempt should first re-confirm on which real photo sizes (this
app's actual JPEG/export targets, not just the one RAW camera) the
problem is even reachable, given how narrow the affected window turned
out to be.

### D17. Dehaze combines superlinearly with Clarity (ROI dilation), found measuring the Dehaze slice

**Read the methodology warning first — three claims in this entry's original
version were wrong, and all three came from the same measurement mistake.**

The robust finding, which held under every methodology tried: **Dehaze is the
most expensive stage in the Presence group, and combining it with CLARITY
specifically costs materially more than the sum of the parts.** Vignette
(per-pixel) shows no excess at all and Texture (radius 0.01) is mild; only
Clarity's wide 0.04 radius triggers it. The driver is region-of-interest
dilation: Clarity's blur requests a dilated ROI from the stage below, forcing
`applyDehaze`'s `CIMorphologyMinimum` to run over a correspondingly larger
region. Same family as D16 — "the pipeline recomputes more than it needs to" —
but between two GLOBAL stages rather than inside `applyMasks`.

**No single figure is quoted as this stage's cost, because they do not
reproduce.** Three
methodologies produced 78.9 / 116.5 / 148.7 ms for the SAME configuration at
4000x4000, and the Dehaze+Clarity excess came out at 1.7x, 2.1x and 3.7x
depending on method. One run even measured `dehaze + clarity + texture` as
CHEAPER than `dehaze + clarity`. Anyone optimising this must re-measure first.

**The methodology trap** (this is the part worth keeping): a harness that
shares one `CIContext` across configurations lets later configurations hit
subgraphs earlier ones already cached. Every dehaze configuration shares the
atmospheric-light blur, so whichever runs second looks artificially fast.
**Interleaving does not fix this — it causes it.** Use a fresh `CIContext` per
measurement, or better, one configuration per process.

**Three claims WITHDRAWN. Do not re-derive them:**

1. ~~"Negative Dehaze is ~4x cheaper than positive, because Core Image prunes
   the dark-channel + morphology chain as dead code at a build-time-constant
   amount."~~ **FALSE.** With a fresh context per measurement, +1 and -1 are
   within 1% (148.7 vs 147.8 ms). Independently confirmed by the reviewer at
   78.9 vs 81.7 ms in isolated processes — negative marginally MORE expensive.
   No pruning happens; `amount` is a uniform, not a compile-time constant.
2. ~~"`CIAreaMaximum` is NOT the cost driver — replacing it with a constant
   left the cost unchanged."~~ **FALSE**, and it was steering future work away
   from the single largest removable cost. The reviewer measured the
   atmosphere chain at **~25% of this stage's total**. The substitution test
   behind the original claim was confounded: replacing the area maximum with a
   literal constant necessarily also prunes the 80px Gaussian that feeds it,
   so it never isolated what it claimed to.
3. ~~"`.insertingIntermediate()` is actively worse on the spread field
   (330.7 -> 428.8ms)."~~ **Not reproducible.** Re-measured as neutral/noise
   (163.0 -> 155.8ms). Not using it is still the right call, but that number
   was not evidence for it.

Not fixed, by explicit user decision when the slice was scoped: ship the
correct algorithm, record the cost, rely on `ProxyScale`'s interactive proxy
(which already absorbs Clarity/Texture). The cost lands on export and the
settled full-res frame, not on dragging.

### D18. Proxy/thumbnail downscale-correctness is a SPECTRUM, not "correct except Noise Reduction"

**TWO** doc sites carried the exact claim that running the pipeline on a
proportionally-downscaled source is "correct, not an approximation, for
every stage except Noise Reduction": `ProxyScale.swift` and
`ImageDocumentModel.swift`'s histogram path (verified against HEAD, after
an earlier draft of this entry said four). Two others carried weaker
related overstatements — `ThumbnailGenerator.swift` claimed exactness
without the NR exception, and `ImageRenderer.swift` already enumerated
five divergence sources but concluded every other stage "renders
identically."

**The claim is wrong, and was wrong before Dehaze existed.** Found while
resolving a contradiction the Dehaze slice introduced; the measurement
then invalidated the framing itself, not just the new stage's place in it.

Measured: ONE 1600px source, downscaled exactly the way `ProxyBuilder`
does (`.clampedToExtent()` then `CILanczosScaleTransform` — the clamp
matters, omitting it overstated the 0.5 figure by 39%), comparing
pipeline-on-proxy against downscale-of-pipeline-on-native. Max abs delta:

    pixel-scale noise      @0.50     @0.25     @0.16
      dehaze              0.11536   0.24059   0.20570
      noiseReduction      0.13431   0.06705   0.03740
      sharpen             0.10713   0.07390   0.07576
      clarity             0.04257   0.03040   0.02951

    band-limited (~16px structure, photo-like)
      dehaze              0.01037   0.04070   0.07093
      sharpen             0.00285   0.00309   0.00315
      noiseReduction      0.00050   0.00206   0.00436
      clarity             0.00041   0.00123   0.00123

Three conclusions, none of which the old framing supported:

1. **Every stage MEASURED here diverges** — dehaze, noise reduction,
   sharpen, clarity. Scoped deliberately: texture, vignette and red-eye
   were NOT measured, so this entry says nothing about them, and
   `ImageRenderer`'s own list still treats vignette as exactly
   extent-proportional. For the three radius-based ones the mechanism is
   an absolute-pixel radius quantizing differently at each scale; Clarity
   — cited in those same comments as the correct-by-construction case —
   is merely the SMALLEST of them, not zero.
2. **Noise Reduction is not uniquely bad**, and its mechanism is the
   OPPOSITE of the others': it has deliberately NO extent term
   (`kNoiseReductionSpan`), and that absence is why it diverges, rather
   than a radius quantizing. On the PIXEL-NOISE rows it is largest at 0.5
   (0.13431) and among the smallest by 0.16 — so singling it out was an
   artifact of whichever scale was originally looked at. **Read that rank
   with its content regime attached**: on the band-limited rows, the ones
   D18 calls photo-like, Dehaze leads at EVERY scale including 0.5
   (0.01037 vs NR's 0.00050), and NR drops to third of four. Any "NR is
   the one that matters at 0.5" reading is a noise-fixture artifact and is
   backwards for real photos.
3. **Dehaze is the worst at the most aggressive scales measured** (0.25
   and 0.16 — note these are still well short of thumbnail ratios, ~0.04;
   see the extrapolation limits below), for a reason none of the others share:
   besides its morphology radius, its atmospheric light is a whole-frame
   STATISTIC, so a proxy estimates it from a different set of pixels
   entirely. That is outside the "geometry as a fraction of extent"
   premise those comments rest on.

**Content dependence cuts BOTH ways, and the naive reading is backwards.**
Absolute deltas fall sharply on photo-like content (dehaze 0.11536 ->
0.01037 at 0.5), so the noisy numbers are an upper bound on MAGNITUDE.
Every other measured stage falls FURTHER than Dehaze does (noise ->
band-limited at 0.5: dehaze 11x, sharpen 38x, clarity 104x, noise
reduction 269x), so Dehaze's ratio rises against ALL of them, not just
Clarity — vs NR 0.86 -> 20.7, vs sharpen 1.08 -> 3.6, vs clarity
2.71 -> 25.3, and similarly at 0.25 and 0.16. An earlier draft said the
rise was "against Clarity specifically"; that is false by this table. The
one place Dehaze does sit below another stage is the PIXEL-NOISE row at
0.5, where NR leads — and that inverts on photo-like content.


**Two limits on how far these numbers may be pushed**, both worth stating
because the obvious extrapolation is unsafe. On the PIXEL-NOISE rows
Dehaze is non-monotonic in scale — 0.11536 -> 0.24059 -> 0.20570, peaking
around 0.25 and falling again — so a smaller ratio is not reliably worse.
(On the band-limited rows it is strictly monotonic, 0.01037 -> 0.04070 ->
0.07093. The regime matters here too; the extrapolation warning below
holds either way.) And the source measured
is 1600px, while `ProxyScale.minimumSourcePixels` is 8 MP, so no image
that actually gets proxied is as small as the fixture. Thumbnail ratios
(~0.04) are an order of magnitude past the last measured point, on a
curve already seen to turn: treat thumbnails as UNMEASURED.

Practical consequence, plausible but not measured at thumbnail ratios:
`ThumbnailGenerator` runs the most aggressive downscale in the app, so a
Library-grid thumbnail of a dehazed photo may visibly differ from the
Editor render. Accepted for now — the
same class as the already-documented RAW-thumbnail divergences — but it is
a real user-visible gap, not just a doc nit.

### D19. Dehaze does essentially nothing on underwater photos (dark channel prior's known failure case)

Found during the Dehaze slice's live verification, on a real diving
photo chosen precisely because it looked hazy. At Dehaze +100, sampled
off the rendered window: open-water regions measured a mean delta of
**exactly 0.00** per channel, while the divers in the foreground moved
only ~1.0. The region that most looks hazy received no correction.

**Not a bug in the implementation** — the prior does not fit the scene.
Water absorbs red strongly, so `min(r, g, b)` over any underwater patch
is already near zero, and a low dark channel is exactly what the prior
reads as "this patch is not hazy." This is the textbook failure case for
He/Sun/Tang's dark channel prior; underwater dehazing work uses modified
priors (commonly UDCP, which computes the dark channel over green and
blue only, dropping the absorbed red channel).

On atmospheric-style haze the same code works well and is depth-aware —
see PROGRESS.md's live-verification table, where correction scales ~14x
with haze density.

Fixing it would mean a channel-selection option on the dark channel
(all-channels vs green/blue), which is a small kernel change but a real
design question: it needs either a user-facing control or a heuristic to
detect underwater scenes, and a wrong auto-detection would be worse than
the current honest no-op. Not scoped.

Related, from the same session: the atmospheric light A is the
area-maximum of a blurred copy, so it finds the brightest REGION rather
than the haze colour. On that underwater frame, negative Dehaze washed
toward warm cream instead of the scene's blue-green because a bright warm
highlight won the maximum. `kDehazeAtmosphereBlurFraction` documents the
shortcut; this records what it costs.

### D11. No keyboard/AT path to paint or adjust a Brush mask's stroke shape (Phase 7 slice 4)

A REAL, named accessibility gap — unlike every other mask overlay in
this app, NOT covered by the same "the sliders ARE the accessibility
answer" justification D6/D9 established for Radial/Linear.
`MaskDetailView`'s Brush rows (Size, Feather, "Paint Stroke"/"Redraw
Stroke") cover the two SCALAR params a stroke has, but a stroke's actual
SHAPE — the path itself — has no slider equivalent at all: there is no
keyboard/AT-accessible way to paint a new stroke or adjust an existing
one's shape, only mouse drag via `BrushMaskOverlayView`
(`.accessibilityHidden(true)`, honestly documented as a real gap in that
view's own doc comment, not the D6/D9 slider-coverage claim).

Needs its own interaction design before it can be scoped — same category
of open question D9 already has for Radial/Linear's rotation handle, but
harder: a stroke has no fixed number of degrees of freedom (an arbitrary
polyline), so even a "nudge with arrow keys" affordance doesn't obviously
generalize the way it does for a handle. A discrete alternative (e.g.
placing straight-line segments between keyboard-driven points, closer to
Red-Eye's tap-to-place model than to a freehand drag) is one candidate
starting point, not a decided design.

### D20. Color Grading Slice B's wheel has no keyboard/AT path AND no numeric readout for 2 of its 3 axes (reviewer-caught, Slice B) — numeric readout SHIPPED 2026-09-29

**Update: the numeric-readout half is shipped**, exactly the cheapest fix
this entry's own text named — a small `Text` caption under the wheel
(`AdjustTabView.colorGradingWheelReadout(for:)`, called from
`colorGradingSection` right after `ColorGradingWheelView`), formatted
"H +137° / S 42%" (Hue: `"%+.0f°"`, matching the global HSL Hue slider's
own format; Saturation: an UNSIGNED `"%.0f%%"`, since Color Grading's own
Saturation field is 0...1 with no negative direction, unlike Luminance's
bipolar `"%+.0f%%"` right below it). Being ordinary, always-visible text
(not hidden), it's automatically VoiceOver-readable with no
`.accessibilityValue` plumbing needed — no code change to the wheel's own
`.accessibilityHidden(true)` at all. The keyboard/AT-DRAG half (actually
moving the puck without a mouse) remains explicitly deferred, unchanged —
this entry's own text called that "a full D8-style keyboard-driven
interaction redesign," a separate, bigger future session. No new tests
(SwiftUI glue, matching this codebase's "verified live, not unit-tested"
convention for this class of change) — build+test verified, 1358 tests
unchanged. **Not live-verified this session** — an unrelated screen-
automation incident (focus unexpectedly landed on a different app mid-
session, briefly surfacing an unrelated file dialog) cut that pass short;
the change itself is low-risk (one non-interactive `Text` view, no
gesture/interaction code touched) so this was judged not worth another
live-verification attempt in the same session.

Reviewer: APPROVE, 2 non-blocking nits logged for completeness, neither
worth their own fix: (1) the readout shows the RAW stored Saturation,
not `EditPipeline.applyColorGrading`'s own rendered/clamped value
(`clampedSaturation`) — only divergent for an out-of-range value a
hand-edited sidecar could produce, since this app's own slider/wheel
controls can't generate one; (2) Hue at exactly 0 (or a theoretical
negative zero) reads "+0°"/"-0°" — cosmetic, and the pre-existing global
HSL Hue slider already has the identical behavior, so this isn't a new
inconsistency.

`ColorGradingWheelView` is `.accessibilityHidden(true)`, matching the
established WB-eyedropper/Red-Eye/pan-overlay deferral precedent (D8) —
but unlike those, this control has no on-screen numeric value at all for
Hue or Saturation, only the puck's visual position. Only the third axis,
Luminance, has a real accessible `EditSliderRow` next to the wheel. This
is a bigger gap than the "the sliders ARE the accessibility answer"
shape D6/D9 established for Radial/Linear masks (where every dragged
value has a labeled slider equivalent) — here 2 of 3 axes are pointer-
only with no value ever displayed anywhere, sighted or not.

Cheapest fix, not yet built: a small text caption under the wheel (e.g.
"H 137° / S 0.42") that doubles as both a sighted numeric readout and,
via `.accessibilityValue`, the AT readout — cheaper than a full D8-style
keyboard-driven interaction redesign, and could ship independently of one.
Needs its own small session; not touched during Slice B itself (reviewer
flagged as non-blocking).

### D21. Curve section's channel picker has the same segment-width-shift latent risk fixed in Color Grading's picker

User-caught via screen recording, post-ship: Color Grading's Shadows/
Midtones/Highlights `.pickerStyle(.segmented)` picker conditionally
appended `" •"` to a segment's own label STRING when that range left
identity — since `NSSegmentedControl` (what `.pickerStyle(.segmented)`
is backed by) auto-sizes each segment to its own content, the string-
length change visibly shifted every segment to the right of the one
that grew (e.g. Shadows gaining its dot on the very first wheel drag
pushed Midtones and Highlights right).

**Two more attempts were also wrong before landing on the fix that
shipped — worth recording in full since each failure mode is subtle
and each was caught by a DIFFERENT method (live screenshot, then
reviewer re-derivation), not by the same check twice.**

Attempt 2 kept the dot glyph always present in each segment's `Text`
and only varied its COLOR (`.clear` vs. inherited), reasoning that a
constant-length string would keep each segment's width fixed. A live
screenshot disproved it outright: all three segments showed a solid,
fully-visible dot regardless of edited state — `NSSegmentedControl`
takes each segment's PLAIN STRING title and ignores `Text` styling
(`foregroundColor`, `opacity`, etc.) entirely when drawing it, so
`.clear` was silently a no-op and the whole indicator became
meaningless.

Attempt 3 moved the indicator out of the segmented control's own
labels entirely into a separate `HStack` of small `Circle` views
positioned under the picker, one per range, left-to-right. This was
live-screenshotted and DID visually work (only the edited range's dot
lit up) — but a reviewer re-derivation caught that the row's own
layout was still wrong: an `HStack`/`Spacer` arrangement puts dot
centers at the row's two edges and its middle, while `NSSegmentedControl`
auto-sizes each segment to its own label text (`"Highlights"` is wider
than `"Shadows"`), so the segments' TRUE centers are NOT at those same
three points. The live screenshot happened to look correct only
because the one lit dot (Shadows, the leftmost) was also at the row's
leftmost position by coincidence — the same coincidence would not hold
for Midtones or Highlights. Reproducing each segment's actual center
would need its real rendered width, which SwiftUI has no way to read
back from the native control.

**Actual fix (attempt 4)**: sidestep needing per-segment alignment at
all. Segment labels are now permanently plain (`Text(range.rawValue)`,
never varying, so the ORIGINAL string-length bug cannot recur either),
and a plain caption sentence below the picker — `colorGradingEditedRangesSummary`,
e.g. "Edited: Shadows, Midtones" — names which ranges are edited
instead of marking them positionally. Ordinary `Text`, no AppKit
control bridging involved at all, so it needs no special accessibility
handling and no color-based visibility trick — this is the same
rendering path already used by this section's own caption above it,
not a novel one. Live-verified with 3 progressive user screenshots —
editing Shadows, then also Midtones, then also Highlights — confirming
the caption read exactly "Edited: Shadows", then "Edited: Shadows,
Midtones", then "Edited: Shadows, Midtones, Highlights" at each step,
in that order.

`AdjustTabView.channelSegmentLabel(for:)` (Curve's Red/Green/Blue
channel picker, shipped earlier in Curves v2 slice 3) uses the
IDENTICAL conditional-string-append pattern this fix replaced, and so
has the identical latent risk — adding the first point to an empty
channel's curve would shift the segments after it. Not fixed here:
out of scope for a Color-Grading-reported bug, and Curve's picker
wasn't itself reported as exhibiting this — but the mechanism is now
understood and confirmed real, so this is a real bug, not a
theoretical one, the next time anyone touches that file.

### D22. Point Color has no luminance-based selection axis — a real divergence from Lightroom's own feature (Slice A, reviewer-caught)

`PointColor.cikernel` selects pixels by hue and saturation distance to
the picked target only, never luminance — a deliberate v1 scope choice
(not a domain impossibility, see the kernel's own header comment; an
earlier draft of this file mis-stated it as a hard "domain hazard"
before a reviewer corrected it). Real consequence: a bright highlight
and a dark shadow of the exact same picked hue/saturation are
INSEPARABLE by this kernel — both get selected and adjusted together,
where Lightroom's real Point Color would let a user's luminance
tolerance tell them apart.

Root reason it's not simply "add a third axis": after this kernel's
own headroom normalization (`rgb / max(maxChannel, 1)`), the resulting
`L` is RELATIVE, not absolute — a 1.4-peak red and a 0.7-peak red can
normalize to the same `L` value. A naive luminance-distance axis added
on top of that normalized `L` would conflate genuinely different
source brightnesses on any headroom content (skies, boosted
highlights), the same class of subtlety `SelectiveColor.cikernel`'s
own headroom-normalize fix had to work around once already. Note the
kernel's EXISTING Luminance ADJUSTMENT slider does NOT sidestep this —
`lumDelta` is added directly to the same normalized `hslv.z` this
paragraph says is unsuitable for selection, so it has the identical
relativity property today (a v1 scope choice for the adjustment side,
not yet examined for its own correctness). Adding a correct SELECTION
axis needs its own design pass (one candidate: comparing Rec.709 luma
computed on the UN-normalized pixel, which neither the selection nor
the adjustment side currently does) — not a same-slice addition, and
not something this entry claims already exists anywhere in this file.

Not fixed here — logged for whoever builds Slice B's UI, since a user
who picks a shadow color and expects highlights of the same hue to be
unaffected will be surprised.

### D24. Defringe's edge gate protects flat subjects, not textured ones (reviewer-caught)

`Defringe.cikernel`'s edge gate (`smoothstep` on local luma range) exists
specifically to protect a genuinely purple/green FLAT subject (a flower,
a lawn) from being desaturated. It does NOT protect a TEXTURED subject
in the target hue — a high-contrast textured area (foliage against sky
is the common real case) reads as a real edge and gets desaturated too,
same as an actual fringe would. Measured (temporary harness, deleted): foliage green `(0.08, 0.35, 0.10)`
at a high-contrast sky boundary with `defringeGreen = 1` fully
desaturates (chroma 0.270 -> 0.022, from `(0.08, 0.35, 0.10)` to
`(0.236, 0.259, 0.239)`). The `defringeGreen` hue window
(120° ± 40°, i.e. 80°-160°) covers most real foliage hues.

This is inherent to any hue-band defringe approach without a separate
selection axis — Lightroom's own Defringe exposes a Hue Range control
for exactly this reason, which this app's v1 does not build (see
`EditState.defringePurple`'s own "v1 scope" paragraph: the hue windows
are fixed tuned constants, not exposed). Not fixed here — a genuine,
known divergence from Lightroom's own feature, not a bug in this
implementation. Worth a Hue Range slider (or narrower default windows)
if foliage-adjacent false-positives turn out to matter in practice on
real photos.

### D26. Auto Tone's Black Point saturates to its own maximum for nearly every photo (reviewer-caught, design note, not blocking)

`AutoToneSolver.solveBlackPoint`'s corrected math (see that function's own
doc comment for the double-encode bug it fixes) reveals a real, accepted
structural limit: given `kBlackPointSpan` (0.20, mirrored from
`EditPipeline`, tuned for the SLIDER's own feel) and `kMaxAutoBlackPoint`
(0.5), the mechanism can only ever clip a floor whose raw linear value is
below roughly 0.000776 — i.e. already extremely close to true black.
`solveBlackPoint` now also suppresses itself whenever Shadows triggers too
(a separate, since-fixed bug — see this codebase's own Auto Tone
implementation, `Sources/EditEngine/AutoToneSolver.swift`), which narrows
Black Point's firing range further, but does NOT change this part: for any
photo whose darkest 0.5% of pixels sits above that ~0.000776 floor, WHILE
its darkest 5% is NOT itself crushed enough to trigger Shadows (i.e.
Shadows' own suppression of Black Point doesn't apply) — which is most
ordinary, well-exposed photos, since a real photo's true darkest pixel is
rarely literally that close to 0 — Black Point saturates to exactly
`-kMaxAutoBlackPoint` (currently -0.5), not a small graduated nudge.
MEASURED (reviewer's own harness): a plain 0.18-gray test fixture with no
distinct shadow region at all still solves Black Point to exactly -0.5.

Not fixed here — a genuine v1 design question, not a bug: is a
consistent, moderately strong deep-shadow crush actually a reasonable Auto
Tone default (matching how some real photo-editing "Auto" presets do add
a base contrast/black-point boost to most photos), or is it an
overreach for a feature meant to read as "sensible defaults, not a heavy
hand"? Worth live-tuning against real photos (the same process
`kMaxTransformAspectStretch` went through) rather than guessing — could
mean lowering `kMaxAutoBlackPoint` further, adding a second, gentler dead
zone, or leaving it as-is if it looks fine in practice.

### D27. History panel: 3 reviewer nits (non-blocking, all APPROVE-round observations)

From the History panel feature's own reviewer round (APPROVE, no fixes
required — these were logged as nits, not FIX FIRST items):

1. `ImageDocumentModel.jumpToHistory(id:)` calls `finalizePendingCommit()`
   before looking up `id` — correct in general (matches `undo()`/`redo()`'s
   own established pattern), but means tapping the BOLD "current" row while
   an edit is still inside its ~350ms debounce window first commits that
   pending edit, so the tapped row is no longer current by the time the
   lookup runs, and the jump then effectively undoes the edit just
   committed. Nothing is lost (it's redoable), but it's a surprising result
   for a row that visually reads as "already here." Tapping a greyed
   "undone" row in the same timing window silently does nothing at all,
   because the just-committed pending edit discards every entry after the
   old cursor, including the one just tapped. Not fixed — worth a sentence
   in `jumpToHistory`'s own doc comment if this surfaces as a real report
   rather than a theoretical timing window.
2. `AdjustTabView.historySection`'s "No history yet" empty-state branch is
   dead code: `EditHistory.entries` always has at least 1 entry (the
   `"Opened"` checkpoint from `init`), so `document.historyEntries.isEmpty`
   can never be true in practice. Harmless — costs nothing, and guards
   against a future `EditHistory` change that DID allow an empty
   `entries` — but currently unreachable.
3. `EditStateDiffTests.testChangedFieldNamesAgreesWithEditStateEquality`
   only asserts the "changed" (not-equal) side at each step after the
   first; the "equal" side is checked once, at identity. A fully two-sided
   version would also assert equality after setting a field back to its
   OLD value at each step. The separate `testNegativeZeroIsNotADifference`
   test partly covers the equal-side intent already. Not fixed — a test
   quality nit, not a correctness gap in the reviewed code.

### D28. `ImageDocumentModel.saveSidecarNow` can write a load-during-save race onto the WRONG sidecar (reviewer-caught, Paste Settings review round 4, pre-existing — not introduced by that feature)

**STATUS (2026-10-02): HARDENED, reachability UNDETERMINED.** `saveSidecarNow` now snapshots `(currentURL, editState)` together BEFORE the folder-access step and writes/reports exactly that snapshot (commit a8dd564; `SidecarFolderAccessing` protocol + `ImageDocumentModel.init(folderAccess:)` make the panel stubbable; `Tests/EditEngineTests/SaveSidecarRaceTests.swift`). The test pins the snapshot semantics by changing the live `editState` while a stubbed panel is up (mutation: write the live state -> fails). The full interleave this item describes — a whole `load(from:)` finishing inside the panel — was NEVER reproduced: probes (2026-10-02) showed a toy multi-hop main-actor Task completes inside a nested `RunLoop` spin when it starts from a run-loop TIMER callback but not from a main-queue block or a Swift job, while a REAL `load(from:)` queued before a timer-triggered save did not complete in 10s. So the original hazard may or may not be reachable from event-driven callers (ContentView's onChange flush, the paste confirmation); either way the snapshot closes it. No live check (needs a re-prompting bookmark and a photo switch inside a modal panel). Leftovers: `pasteSettings`' post-flush declined-folder check reads the live `currentURL` (the callers' `canProceed` path match covers it); a `.failed` access result would show `sidecarSaveErrorMessage` while another photo is open (cosmetic).

Found while adversarially re-verifying Paste Settings' own load/batch race
(4 review rounds on that one) — this is a SEPARATE, PRE-EXISTING hazard in
`saveSidecarNow` itself, not something Paste Settings introduced, and it
affects every ordinary debounced sidecar save, not just batch pastes.

`saveSidecarNow()` captures `currentURL` at its own top, then — if the
containing folder's bookmark needs re-resolving — can show an `NSOpenPanel`
(`SidecarFolderAccess.resolveOrRequest`), which pumps the AppKit modal run
loop. If a NEW photo's `load(from:)` starts and finishes DURING that panel
(the same "a modal panel pumps the run loop, letting an unrelated async
load interleave" mechanism Paste Settings' own `canProceed` guard was
built to close), `saveSidecarNow` resumes afterward, reads the NOW-CURRENT
`editState` (the newly-loaded photo's), but still writes it to the
ORIGINALLY-captured `currentURL`'s sidecar path — silently writing the
new photo's edit state into the OLD photo's sidecar file.

Narrow in practice (needs a folder-access prompt to actually appear at
the exact moment a photo switch is also in flight — most sessions never
re-prompt after the first grant per folder), but a real, silent data-
integrity hazard, not a theoretical one — the exact mechanism is proven
correct by this same session's own `PasteSettingsModel.performPaste`
finding. Not fixed here — out of scope for the Paste Settings feature
that surfaced it. A fix would need `saveSidecarNow` to re-capture (or
re-verify) `currentURL`/`editState` together, atomically, AFTER any
panel-showing step completes, not just at its own top.

**Specifically under Paste Settings**: this is the one documented residual
exposure `PasteSettingsModel.performPaste`'s own `canProceed` guard (see
that method's doc comment) doesn't close — reached only via the open-photo
branch's own `applyToOpenPhoto` → `pasteSettings` → `saveSidecarNow` call,
which runs LAST (after the entire batch loop, a deliberate ordering — see
that same doc comment). If this exact race fires there, the sidecar that
gets silently overwritten with a DIFFERENT (newly-loaded) photo's edit
state is the photo that was JUST pasted onto — the paste is lost, and
that photo's undo history is already gone too (the load reset it). Needs
two rare conditions at once (a bookmark that goes stale on every resolve,
right after the pre-flight just granted it, AND a photo switch that
happens to finish while that repeat panel is up) — accepted as an
extremely narrow residual, not worth a further guard layer in this
feature on top of the general `saveSidecarNow` fix this item already
describes.

### D29. `PhotoEnhancer.enhance` can leave a stale hidden temp file behind on a crash/force-quit (reviewer-noted, Enhance/Super Resolution review round 3)

`PhotoEnhancer.enhance`'s temp file lives IN the destination folder itself
(a hidden, dot-prefixed name, e.g. `.3F2A1C9B-....jpg`), not the system
temp directory — required by `commitExclusively`'s `FileManager.linkItem`
mechanism, which needs the temp file and the final destination on the
SAME volume. A `defer` removes it once `enhance` returns or throws, but if
the process is killed between the temp write and that `defer` (a crash, a
force-quit, a system restart mid-render), the hidden file is never
cleaned up — unlike the system temp directory, which the OS sweeps
periodically. The leftover is a full-size, fully-rendered 2x JPEG (easily
tens of MB), silently sitting in the user's photo folder, invisible in
Finder (dot-prefixed) and invisible to this app's own Library import
(`PhotoImporter.imageFiles`/`scanNode` both use `.skipsHiddenFiles`).

Not fixed in v1 — narrow in practice (needs a hard crash/kill at the
exact wrong moment) and each individual leftover is harmless-if-orphaned
(no risk of being silently adopted the way a leftover SIDECAR would be —
see `PhotoExporter.uniqueFileURL`'s own orphan-sidecar protection, a
different hazard class). A natural follow-up: a lightweight sweep (e.g.
at app launch, or before the next Enhance in that same folder) that
deletes any `.{uuid}.jpg` matching the exact temp-name pattern this
feature produces, older than some threshold.

**A second, narrower instance of the same class (reviewer-caught, round
4)**: on a filesystem without hard-link support (exFAT/FAT32 — see
`PhotoEnhancer.link`'s own fallback), the commit sequence is reserve
(create an empty placeholder at the REAL, visible destination name) then
`rename(2)` the temp file over it. Both steps are individually atomic,
and a failed rename is cleaned up (the placeholder is always this
process's own file, safe to remove). But a crash/kill in the
microseconds-wide window BETWEEN a successful reserve and the rename
that would have completed it — not caught by any `catch`, since nothing
threw — leaves a permanently-empty, VISIBLE `<name>-Enhanced-SR.jpg` at
the real name (unlike the hidden dot-prefixed temp file above). Narrower
than round 2's original truncation risk (obviously broken at 0 bytes,
not silently corrupt-looking) and even narrower in practice than the
hidden-temp-file case above (this window is microseconds, not the whole
upscale+render). Not fixed — the same sweep-based follow-up would cover
both cases if ever built.

### D30. `CatalogDatabase.registerPhoto`'s reuse-on-same-path can inherit a stale row's metadata (reviewer-caught, Enhance/Super Resolution review, commit 4)

`registerPhoto` (and the `insertPhotoIfNeeded` it shares with every other
import path) treats "a row already exists at this path" as reuse, not
replacement — returning the EXISTING row's `id`/`rating`/`isFlagged`/
`fileSize`/`importedAt` unchanged, never re-reading the file's current
metadata. This is the established, correct behavior for an ordinary
re-import (the same file, unchanged) — see `insertPhotoIfNeeded`'s own
doc comment — but has a narrow, real failure mode specific to Enhance:
`PhotoExporter.uniqueFileURL`'s collision check only looks at what's
ON DISK (a file, or its sidecar) at a candidate name — NOT at whether
the catalog already has a row for that exact path. If a user deletes an
enhanced output in Finder (outside this app) while its catalog row
survives, then a LATER Enhance on the same source photo happens to
collide onto that exact freed-up name again, the new image silently
inherits the old, now-stale row's rating/flag/album memberships, and its
`fileSize`/`importedAt` stop reflecting the new file at all.

Not fixed — narrow (needs an out-of-app delete at exactly the reused
name) and each individual occurrence is a metadata-staleness issue, not
a data-loss or corruption one (the new image's own PIXELS are correct;
only its catalog bookkeeping is inherited from the wrong prior file).
Possible future fixes, not chosen for v1: have `uniqueFileURL` also
check the catalog (would need `PhotoExporter`/`PhotoEnhancer`, currently
UI-free `Rendering`-layer types, to gain a `CatalogDatabase` dependency
— a real architectural cost for a narrow case); or have `registerPhoto`
reset a reused row's rating/flag/fileSize/importedAt on every call
(would also reset them on an ORDINARY harmless re-import, arguably the
wrong tradeoff the other direction).

### D31. Thumbnail decode and `isPhotoConfirmedMissing` share the same stale-security-scope gap `ensureAccessActive` just fixed for the Editor-open path — not fixed there

Fixing the "Library-driven photo open sometimes fails" bug (see
PROGRESS.md's own write-up and `CatalogModel.ensureAccessActive`'s doc
comment) only covers `ImageDocumentModel.load(from:)`'s 3 catalog-driven
call sites (Library grid, Editor filmstrip, ⌘←/⌘→). `ThumbnailCache`/
`RawDecoder.decode` read the exact same bare file paths with no scope
acquisition of their own, relying on the identical
`CatalogModel.activeFolders`/`folderBookmarks` ambient state — so a
folder whose security scope has gone stale (the same "membership alone
proves nothing" gap `isPhotoConfirmedMissing`'s own doc comment already
named) should, in principle, break thumbnail decode too. It just fails
silently there (a spinner that never resolves, or a false "Missing"
placeholder) instead of surfacing the visible "Couldn't open…" alert
that made the Editor-open case noticeable in the first place.

Not fixed this slice — `ensureAccessActive(forPhotoAt:)` could in
principle be called from `CatalogModel.thumbnail(for:)` too, but that's a
MUCH hotter path (every visible grid cell, not one explicit user action).
Beyond the NSOpenPanel re-grant fallback (the obviously expensive branch,
already flagged), even the CHEAP common-case probe would add one real
`FileHandle(forReadingAtPath:)` open/close per thumbnail request — small,
but paid on every grid scroll rather than one explicit open, so this
needs its own measurement before treating that as free, not just an
assumption that it is.

### D32. `ensureAccessActive`'s readability probe can't tell a lost security scope from an ordinary POSIX-permissions failure (reviewer-caught, round 4)

`CatalogModel.ensureAccessActive`'s recovery probe (`needsRecovery`)
correctly distinguishes "file doesn't exist" (skip recovery — see D31's
neighboring history and that method's own doc comment) from "file exists
but `FileHandle(forReadingAtPath:)` fails" (recover). It does NOT further
distinguish, within that second case, a genuinely lost security scope
from an ordinary file the user (or something else) made unreadable via
plain POSIX permissions (`chmod 000`, or similar) — both currently read
as "needs recovery." Consequence, each time such a file is opened: the
folder's root is evicted from `activeFolders` and its security scope
re-started (one more unmatched start, same cost class this method
already accepts for genuine recoveries — see `reacquireAccess`'s own doc
comment), and if no bookmark resolves, a re-grant panel appears that
cannot possibly fix an ordinary permissions problem.

A precise fix would replace the `FileHandle`-based probe with a raw
`open(2)` call and branch on `errno`: `ENOENT` → missing (already
handled), a sandbox-specific denial (`EPERM`, per Apple's own sandboxing
model) → recover, plain POSIX `EACCES` → leave alone, let `load(from:)`'s
existing error surface normally. Not built this slice — genuinely rare
in practice (a photo the user has independently chmod'd is an unusual
scenario for a photo library), and the existing `chmod 000` unit-test
fixtures (`CatalogModelTests`'s `makeUnreadableFileFixture`) would need
to become sandbox-denial fixtures instead, which the current test
suite has no way to construct deterministically (this project's own
established boundary for anything panel/sandbox-adjacent — see
`ensureAccessActive`'s own reviewer history for the same limitation
applied elsewhere).

### D12. Brush mask v1 scope cuts (Phase 7 slice 4) — deferred, not forgotten

Logged together since they're all small, independent follow-ups to the
same shipped feature, each too small to justify its own numbered item
until one is actually picked up:
- **Multi-stroke-per-mask.** One Brush `Mask` is exactly one continuous
  stroke (`Mask.brushPoints` is a flat array, not nested per-stroke
  arrays) — painting a second area today means adding another Brush
  mask, which already compounds for free but costs one extra row in the
  mask list per stroke.
- **Erase/subtract within one brush mask.** No way to paint, then remove
  part of what was painted, short of "Redraw Stroke" (replaces the
  WHOLE stroke) or deleting the mask outright.
- **Reposition/resize of an already-painted stroke.** No on-image
  handles once painting ends (`BrushMaskOverlayView` shows only the LIVE
  in-progress path) — moving or rescaling a placed stroke means
  redrawing it from scratch via "Redraw Stroke."
- **Per-point variable size (pressure).** `Mask.brushSize` is one scalar
  for the whole stroke; there's no equivalent of a pressure-sensitive
  brush that varies width along the path.


### D36. Heavy edits export superlinearly slowly on very large images (Phase 8 audit, 2026-09-30) — recorded, not fixed; PROFILED per stage 2026-09-30

Audit (8GB machine, all stages at once: Clarity+Dehaze+Texture+NR+contrast/
saturation/vibrance/curve+one mask): 1.41s @24MP, 21.81s @96MP, 405.31s @200MP
(20000x10000), 478.36s @200MP (16000x12500 — both sides under 16384, so NOT
the GPU texture limit). Exposure-only 200MP: 8.26s. Correct output every time.

**Per-stage profile (temporary harness, `PhotoExporter.export` to full-size
JPEG, one process per run, scratch fixtures; harness deleted).** Two fixture
families, because CONTENT MATTERS: "noisy" (gradient + ±12 pixel noise, JPEG
entropy-heavy) and "noiseless" (smooth gradient). Exposure-only baseline:
noisy 0.14s @24MP / 8.74s @96MP / 30.92s @200MP (RSS 1195MB); noiseless
2.02s @96MP (noiseless 96MP "everything": 18.97s) — the noisy baseline is
probably mostly JPEG decode/encode rather than the pipeline (an INFERENCE from
8.74s vs 2.02s; the codec was not timed on its own).

| noisy fixture, export seconds | 24MP | 96MP | 200MP |
|---|---|---|---|
| exposure (baseline) | 0.14 | 8.74 | 30.92 |
| Clarity alone | 0.24 | 7.47 | 33.53 |
| Texture / NR / mask alone | 0.24 / 0.15 / 0.23 | 7.31 / 8.44 / 7.53 | not run |
| Dehaze alone | 0.57 (1.82 first run) | 9.06 | 78.82 |
| Clarity + Dehaze | 0.70 (0.75 first run) | 27.09 first / 15.13 repeat | 208.84 |
| everything | 1.14 (first run) | 97.30 first / 48.19 repeat | not run |

What is MEASURED: (1) no single stage is expensive at <=96MP — every one lands
within about +-1.5s of the baseline (Texture is the extreme, 7.31 vs 8.74); (2) Dehaze alone has a cliff between 96MP
(+0.3s over baseline) and 200MP (+47.9s); Clarity alone stays cheap (+2.6s at
200MP); (3) the combination is strongly SUPER-ADDITIVE and the excess grows with
size: Clarity+Dehaze is additive at 24MP (+0.56s vs parts +0.53s), but +6.4..
+18.4s at 96MP against parts summing to about -1s (i.e. no added cost), and +177.9s at 200MP against
parts summing to +50.5s; (4) run-to-run spread is up to 2x on this machine
(4.0-4.6GB of its 8GB swap in use; the first 96MP "everything" run also
swapped out 34,540 pages), so treat single numbers as ranges; (5) RSS peaks
across all profiled runs stayed <=1195MB, and all four profiled 200MP runs had 0
swap-outs, so paging during those runs does not explain them (GPU memory, which
on unified memory is system memory, was not measured); (6) the first run of a
Dehaze config in a fresh process is slower (24MP: 1.82s vs 0.57s).

What is HYPOTHESIS (not proven): the first-run slowness in (6) is presumably
shader compilation; and the super-additive excess is D17's ROI
dilation — Clarity's wide blur requests a dilated region from Dehaze's
morphology/blur, and because the radii are extent fractions (Clarity 0.04,
Dehaze 0.0125 / atmosphere 0.02 of min(extent)) while Core Image's working
tile size does not grow, the recompute overhead grows with image size.

Decision (Phase 8 follow-up gate): NOT fixed. No single stage dominates, and a
blur-radius cap would change output for existing photos. No user-visible
workaround needed for the D610 (24MP: 1.4s all-stages). One cheap, output-
identical candidate is UNTESTED here: materializing an intermediate after
Dehaze above a size threshold (`insertingIntermediate()`; D16 measured it
flat-to-worse for masks, so it must be measured for this Dehaze->Clarity case
before anyone ships it). Also possible: a progress/cancel UI for very large
exports. Do not re-attempt as "tiled rendering" — Core Image's own tiling did
not fail. Audit table: `docs/ROADMAP_HISTORY.md` "Phase 8 close-out".

Live interactive latency (Release app, same machine; `docs/ROADMAP_HISTORY.md`
"Phase 8 follow-up"): release-to-visible-change at 96MP is ~0.5s for Contrast but
~14.6s (settled ~20.5s) for Clarity -100%; at 200MP Contrast +51% takes ~6.3s and
zoom-out ~6.6s. Heavy-combination (Dehaze) slider latency NOT measured.

### D38. Transient solid-green rectangle on the canvas at 96MP (Phase 8 live pass, 2026-09-30) — open, NOT reproduced

Once, during a 96MP session (zoom in/out + pan, then Exposure +1.58 EV,
Contrast +51%, Clarity -100% edits), a solid pure-green rectangle (bottom-right of
the canvas, roughly the last ~40% of one edge) covered part of an otherwise correct
frame — pure green is not a colour present in the source gradient, and an
uninitialized/zeroed YCbCr-style tile would look like this. The same photo with the
same SAVED edits, reopened after a relaunch at fit zoom, rendered with no artifact.
Seen only after the app had also become unresponsive behind an invisible "Open"
panel, so heavy queued renders / GPU memory pressure on the 8GB machine are
suspects, but nothing was verified. If it recurs: capture it, note zoom/pan state
and pending edits, and check whether it clears after a re-render. Not investigated.

### D40. A crash mid-rename can leave photos hidden or the catalog stale (batch-rename commit 3 review, 2026-09-30) — open, accepted for v1

`RenameEngine` journals in memory only. A crash/force-quit between its two phases leaves the
batch's photos under hidden `.photoapp-rename-<token>-<n>-<original name>` names (the original name
is kept at the end so they can be renamed back by hand; nothing is deleted). A crash AFTER the files
moved but BEFORE the catalog transaction commits leaves the catalog listing the old names, so every
photo shows as Missing and Locate… must be run per photo (or per folder via multi-select Locate…).
Recommended fix if it ever bites: a write-ahead `pending` batch row saved before any file moves,
flipped to applied in the same transaction as the path update, and reconciled on launch (roll the
files forward or back to match).

### D41. The Editor has no "close" action, so the last-opened photo blocks renaming it (batch-rename commit 4 review, 2026-09-30) — open, worked around

`ImageDocumentModel.currentURL` is never cleared, so the last photo opened stays "loaded in the
Editor" even while the Library grid is showing. `RenamePlan` (rightly) refuses to rename a photo the
Editor holds — its debounced sidecar save would otherwise write to the OLD sidecar path — so selecting a
whole folder that includes the last-edited photo makes the entire batch inapplicable, and Undo Rename
refuses the same way. Current workaround (stated in the blocked row's message): open a different photo in
the Editor first. Better fix: a real "close photo" (flush the pending save, clear `currentURL`/image) when
the user enters the Library, or retarget the document to the new path after a rename.

### D42. Rename preview does its disk checks on the main actor on every keystroke (batch-rename commit 4 review, 2026-09-30) — open, accepted

`RenamePlan.make` runs about three `fileExists` calls per photo synchronously on the main actor each
time the template or start number changes: roughly 3,000 `stat`s per keystroke at 1,000 photos — fine on
a local SSD, noticeable on a network volume or slow external drive. Not measured. If it ever hurts,
debounce `RenameModel.recomputePlan` (~150 ms) and/or move the plan build off the main actor.

### D43. The rename success alert is timed, not tied to the sheet's dismissal (batch-rename commit 4 review, 2026-09-30) — open, low

`RenameModel` dismisses the sheet, sleeps 350 ms, then raises the "Renamed N photos" alert, because macOS can
drop an alert raised in the same pass as a sheet's dismissal. That is a timing guess: on a slow machine or with
reduced-motion animations a dismissal longer than 350 ms could still swallow the alert (files, catalog and undo
log are already committed; only the message is lost, and Undo Rename is available regardless). Sturdier: hold
the message and raise it from `sheetDidDisappear`.

## Working agreements
1. One item per session, smallest viable slice, Plan Mode first (CLAUDE.md).
2. Performance items: measure before and after on a real large photo/library; record numbers in PROGRESS.md.
3. Verify each item's claims against the code before acting.
4. When an item ships: strike it, move its full text to `docs/IMPROVEMENTS_HISTORY.md`, leave a one-line index entry here, update PROGRESS.md.

### D44. Subject mask refinement follow-ups (2026-10-01) — open, low
- **All subjects unticked + Invert selects nothing** (the documented "zero rasters selects nothing" rule). A user may expect "whole frame". Decide whether Invert should treat zero enabled subjects as "everything" or the UI should disable Invert then.
- **No click-on-image subject picking** (needs the `EditorInteractionMode`/crosshair machinery and a hit test against the per-instance rasters); the list + thumbnails are the only way to choose today.
- **`kMaxSubjectFeatherFraction` (0.02) is untuned**: at Feather 100% the live halo looked fairly strong; retune like `kMaxTransformAspectStretch` (note the stored slider value is replay-affecting).
- Feather is applied in raster space before the stretch: elliptical if a stored raster's aspect ever differs from the photo's (theoretical for Vision rasters).
- Per-instance refinement costs n x ~20 ms and runs for every instance before the 8-cap.
- Subject thumbnails: the NSCache is keyed by NSData (equality is byte-exact; hash buckets collide because PNG headers are near-identical — fine at <=32 entries).
- Generator tests XCTSkip when Vision doesn't return exactly 2 instances for the synthetic two-figure fixture; they could silently stop running on another OS/Vision revision.


### D45. Looks (LUT profiles) v1 follow-ups (2026-10-02) — open, low/medium
- **A user look this Mac doesn't have renders as NO look everywhere** (fail-open by design so sidecars from other machines still open). The Editor shows "Look not found", but Export, Enhance and Library thumbnails silently produce output without it. Consider warning/refusing in Export/Enhance when `lookID` is non-empty but unresolved. User ids are content-addressed (`user:<hash>`), so importing the same `.cube` bytes on any Mac restores it.
- **Removing an imported look leaves stale Library thumbnails** for photos that used it (cache not invalidated); the open photo is switched to None explicitly.
- **Auto Tone / Fix Color Cast sample via `geometryOnlySamplingState`, which drops the look**, so Auto solves against the image BEFORE the look (Lightroom's Auto takes the profile into account).
- **No live thumbnails per look** in the picker (text rows only).
- `.cube` limits: only 0-1 domain (DOMAIN_MIN/MAX/LUT_3D_INPUT_RANGE other than 0 1 rejected), out-of-range entries clamp, 1D LUTs rejected, sizes 2-65.
- Look math is not pinned per photo: retuning a built-in look changes existing edits (same as `kMaxTransformAspectStretch`).
- `loadAll()` runs synchronously on the main thread at launch (needed for ordering); many large LUTs would slow launch.


### D46. Spot removal v1 follow-ups (2026-10-02) — open, low/medium
- **Unexplained transient seam**: in 3 early live captures a 1 px column ~3% darker appeared at the left/right edges of a spot's bounding box; not reproduced in 10 later captures or numerically (18 render configurations incl. ProxyBuilder proxies, Metal RGBAh, downscales). If seen again, capture the exact action sequence; suspect a stale-frame/overlay-layout artifact.
- **Placement/moving needs identity geometry** (spots are stored in the unedited source frame; the tap -> source inverse of straighten/perspective/scale/flip/crop is not built). A general coordinate-image inverse would lift this.
- **Click-to-place: SHIPPED 2026-10-07** (the "Place Spots" tool, see D56) — this bullet's old text ("Add Spot drops at the centre… no Escape-to-deselect, no radius handle") no longer holds; the "Add Spot" button remains as the keyboard/VoiceOver path.
- **Auto-source is unreliable on strong texture** (spike); heal vs clone is mixed on textured content; the user must drag the source.
- **Full-resolution cost** ~55-80 ms per spot per render (each spot is a full-frame merge pass; spike number, not re-measured with `RetouchMerge`); merging non-overlapping patches before compositing would cut it.
- Fractional source offsets soften the copied texture (bilinear shift); premultiplied-alpha caveat for sources with varying alpha; tiny-radius heal at thumbnail scale drifts toward a softened clone; a heal from a dark textured source into a bright destination amplifies the texture (perceptual-domain property).
- Auto Tone / Fix Color Cast sample without the spots (`geometryOnlySamplingState`).
- Not verified live: circle dragging (the automation's synthetic mouse events do not reach the app; the drag math is unit-tested; the Source X/Y sliders are the AT path) and Redo. Verified live in a second pass: Clone mode, off-centre Heal, reopen persistence, flip-following, Undo of a flip with spots intact, the 50-spot cap (button disabled, 50 saved).

### D47. Library keywords v1 follow-ups (2026-10-02) — open, low
- **Update 2026-10-06:** keywords are now EMBEDDED in exported files (IPTC + XMP `dc:subject`; see D52). Still no keyword rename, hierarchy/synonyms, or XMP/IPTC READ-in / sidecar write-out (keywords live only in the catalog: a lost catalog loses them, same as ratings/flags/labels).
- Matching uses `lowercased()` + NFC, not full case folding (İstanbul/Istanbul, Straße/STRASSE stay separate); keys depend on the OS's Unicode tables.
- `CatalogModel.keywordNamesForSearch` / `keywordPhotoCounts` rebuild dictionaries per access (O(links)); cache beside `keywordIDsByPhotoID` if catalogs grow. `refresh()` reads keywords and links in two separate reads (a deletion between them leaves a harmless transient dangling link).
- `removeKeyword`/`deleteKeyword` are local-first; an in-flight refresh that read before the write commits can briefly resurrect the removed link (same accepted class as memberships). `refresh()` deliberately does not clear a dangling `keywordFilterID` (a stale read could drop a just-chosen filter); `deleteKeyword` is the only place a keyword disappears.
- The sheet edits every SELECTED photo including ones hidden by search/filters (same `selectedPhotos` semantics as Rename/Paste); the sheet discloses the hidden count. The grid context-menu label counts only `selectedPhotosVisibleInGrid`.
- ⌘K is Library-only (it edits the Library selection, not the open Editor photo); no "tag the open photo" path from the Editor.
- Accessibility UNVERIFIED: in the live AX tree the sheet's buttons (even plain-text "Done") expose no title/description via System Events, so the `accessibilityLabel`s on the icon-only trash/chip buttons are unconfirmed for VoiceOver. The new-keywords text field's label does show. Check with VoiceOver or the Accessibility Inspector.
- A failed add reports via `importStatusMessage`, but the typed text is already cleared by then.
- Not tested: >500-id chunking at the UI level (DB level is tested with 1203 photos).

### D48. Export upgrades v1 follow-ups (2026-10-02, updated 2026-10-05) — mostly closed
**Closed 2026-10-05:** (a) the default metadata policy is now `.withoutLocation` (stored settings moved to `exportSettings.v2` with a one-time v1 migration; a deliberate v1 "All metadata" is reset because it was indistinguishable from the old default; a downgrade then re-upgrade keeps the v2 value and ignores changes made by the older build); (b) output sharpening no longer amplifies Grain (grain is added after the sharpen when both are on — measured before the fix: noise std x1.13 screen / x1.34 print through the export path, after: within the 6% test tolerance of the unsharpened export); (c) the strengths were eyeballed on two real photos and kept (see `OutputSharpen`).
**Still open:**
- A resized export WITHOUT sharpening adds grain at full size and then minifies it: exact when the downsize ratio aligns grain cells (3000 -> 1000px: identical std 0.0837) but 0.0742 (-11%) for a non-integer ratio (3000 -> 1100px), vs 0.0838 when grain is added at the output size (what the Editor shows). Sharpened exports use the output-size path; unsharpened ones keep the old one to stay byte-identical.
- Below ~500px output short side the grain cell clamps to 1px (`max(1.0, ...)` in `applyGrain`), so the deferred path's grain is coarser/stronger than the old minified one.
- Enhance runs the MetalFX spatial upscaler AFTER the whole pipeline (grain included); it may amplify grain like export sharpening did. Not measured.
- Noise left by Noise Reduction and source JPEG blocking are still sharpened with everything else.
- Sharpening strengths were judged by one reviewer on two photos only; no settings UI to adjust them.
- **Bright rim next to a transparent margin inside the frame** (e.g. `transformScale` < 1 without a crop): +44% linear at print settings fading over ~8px (reviewer measurement, not reproduced by me); only visible in PNG/TIFF. `EditPipeline.applySharpen` has the same unmeasured gap.
- The after-resize ORDER of sharpening is a convention (before/after differed by 0.0043 on a step edge); textured content was not measured.
- Watermark: text only (no image/logo); one line; the mark is silently skipped when the font would be < 1px or the text can't fit after 5 shrink attempts (export still succeeds); opacity blends in linear light (a given % looks stronger than in a gamma editor); the vertical gap follows glyph bounds, so descenders shift the baseline; emoji rely on the system font cascade.
- Metadata: `.withoutLocation` is a BLOCKLIST (GPS dictionary + IPTC place fields incl. IPTC-Ext location structs) — location hidden in maker notes or XMP-only fields is not covered; `.none` is an allowlist. RAW sources: the decoded image's `properties` (CIRAWFilter output) is UNVERIFIED (no RAW fixture), so a RAW export may carry less than "All metadata" implies. Enhance writes no metadata at all (measured: no GPS, no Orientation tag, upright).
- The editor preview is sRGB, so a Display P3 / Adobe RGB export of a wide-gamut source looks more saturated than the preview. 8-bit Adobe RGB bands a little more than sRGB.
- The source's PNG colour chunks (gAMA/cHRM/sRGB) are dropped under every policy and the writer synthesizes its own; the P3/Adobe PNG chunk output was not byte-inspected.
- ExportSettings persists ExportResize in Swift's synthesized Codable shape (`{"maxLongEdge":{"_0":N}}`) under `exportSettings.v2`; renaming that case later needs a migration like the v1 -> v2 one (the per-field fallback would just reset resize).
- Not covered by tests: the RAW branch's pass-through of colorSpace (same expression as the non-RAW branch, which a mutation does catch), and the options sheet's ViewThatFits/ScrollView fallback (UI).

### D49. Smart collections v1 follow-ups (2026-10-02) — open, low
- Criteria are only min rating, flag, label and ONE keyword. No search text, date range, folder/collection scope, multiple keywords, AND/OR groups, or per-row counts; no criteria editor (only "Update from Current Filters", which overwrites with the filter bar).
- Saving from inside a regular collection/folder creates a catalog-WIDE smart set (the dialog says so). Export with nothing checked exports the smart collection's matches over the whole catalog, and the filter bar does not narrow it (same rule as ordinary collections).
- `updateSmartCollectionCriteria` accepts criteria whose `hasUnrecognizedCriterion` is true and saves them as if that criterion were absent; a future criteria editor that loads such a collection must warn first or it will silently widen it. An out-of-range stored rating is clamped (7 -> 5), not flagged.
- One malformed `criteria` row (not a JSON object) makes `allSmartCollections()` throw for the whole list; the model reports it once and keeps the previous list (sidebar would not show new rows until fixed).
- An empty smart collection shows the "No photos match … Clear Filters" empty state, which cannot help there.
- `refresh()` reads `selectedFilter` after several awaits: an older refresh landing after a sidebar switch can briefly show the wrong source set (pre-existing for All Photos <-> collection; now also smart). A generation token would fix all of them.
- A selected photo that drops out of the smart set (rating changed) stays selected, like the filter bar. A keyword delete that empties a smart collection is silent.
- Not mutation-tested: the `.smartCollection` arm of `refresh()` (removing it is a compile error, not a failing test); the ContentView Export wiring is covered only by the live check.

### D50. Click-on-image subject picking v1 follow-ups (2026-10-05) — open, low
- NOT live-verified: the keyboard crosshair path (arrow keys + Return), picking while zoomed (zoom is reset on arm), picking with a crop/flip/straighten applied in the REAL UI (the engine's geometry cases are unit-tested through the forward path, whole-frame), and picking in Compare/Crop modes. Perspective has no dedicated hit-test case (same shared `applyGeometry` path).
- The red overlay shows the CHOSEN subjects only (not the final effect): Invert and the mask's combine mode are applied later in the pipeline and are not reflected; it appears only while the mode is armed. Rendered <= 512px through `.task(id: editState)` with a 30ms debounce.
- A click on no subject is silent in the picker (the engine reports it via `subjectMaskMessage` only when `reportMiss` is true); Vision instance masks are disjoint, so the hit rule is simply highest coverage (>= 0.5), lowest index on a tie — the planned 'smaller subject wins' tie-break was dropped as unnecessary.
- Picking needs stored instances: a legacy union-only mask says to Recompute; a mask with a single instance has no button.
- Hit test cost: N (<= 8) lazy mask builds + N 1x1 renders on the main actor per click (measured only by reading, not timed).
- Accessibility: the on-image layer is hidden from VoiceOver; the per-subject checkboxes are the equivalent path. Keyboard users have crosshair + Return (unverified live).
- Live-check technique: a two-circle fixture photo + sidecar with hand-made instance PNGs (the Vision pass is not needed); the app only reads a sidecar once the folder has a bookmark, so the first save prompts for access and OVERWRITES the crafted sidecar — grant first, restore the sidecar, reopen. Focus kept jumping to Chrome during the pass: every keystroke went through a guard that verifies PhotoApp is frontmost first.

### D51. Persisted edit history v1 follow-ups (2026-10-05)
Shipped: `_history` in the sidecar (commits 8805d76 format, c544ddf wiring). Open, none blocking:
- No "Clear History" control — a photo's trail (up to 101 rows, incl. abandoned redo rows) persists until the sidecar is rewritten without it (batch Paste does that) or Revert/new edits trim it by the 100-step limit.
- The history read in `load(from:)` runs serially BEFORE the image decode; it has no dependency on the decode, so `async let` would overlap them. Costs up to the archive decode time (documented in `HistoryArchive` tests) on photos with big mask histories.
- Two guards are untested defense in depth (mutation-checked: removing either leaves the suite green): `historyURL == url` in `saveSidecarNow` (guards the `load(from:)` window between `currentURL = url` and the history reset — same hard-to-reproduce class as D28) and the restore-time `restored.current == editState` check (the RAW pin-backfill case; the sidecar-vs-archive consistency check upstream already covers the PNG-testable cases).
- No test observes that the off-main WARMED encoder is the one adopted (only timing differs).
- Anything that rewrites a sidecar with only an `EditState` (batch Paste, Enhance-adjacent writers) silently drops the history — by design, but a user pasting onto a photo loses its trail.

### D52. Keywords embedded in exports v1 follow-ups (2026-10-06)
Shipped (d7dda03 engine, 695b120 plumbing + UI): `ExportSettings.includeKeywords` (default on, "Add Library keywords"), `KeywordEmbedding`. Open, none blocking:
- ~~No `.xmp` sidecar write-out~~ — SHIPPED 2026-10-14 (D65). Original note: no `.xmp` sidecar write-out next to the originals (deliberately cut: shared-basename collisions CR2+JPG, foreign-file merge/clobber, RenameEngine/Undo would have to move `.xmp`, folder-grant pre-flight). A Photo-menu "Write XMP Sidecars" is the next step if wanted.
- ~~No keyword READ-in from files on import~~ — SHIPPED 2026-10-14 (D65: silent fill-defaults pass after import + manual Read).
- Flat `dc:subject` only: no `lr:hierarchicalSubject`/hierarchy (the catalog has none).
- RAW sources: whether `CIRAWFilter`'s output carries the file's own IPTC/XMP keywords is UNVERIFIED (same caveat as `ExportMetadata`), so a RAW export may carry only the catalog's keywords.
- Enhance (`PhotoEnhancer`) does not embed keywords or any metadata policy (pre-existing for metadata).
- Default ON means a place-name keyword is exported under the default "All except location" policy (the caption says so); flip `includeKeywords`'s default if a privacy-first default is preferred.
- Not live-tested: toggle off / "None" through the UI (covered end to end by `KeywordEmbeddingTests`).

### D53. Duplicate detection v1 follow-ups (2026-10-06)
Shipped (ac027f3 spike, 11017d1 data layer, 20fe153 engine, 17cf473 model + sheet): Photo ▸ Find Duplicates… — exact copies (SHA-256, only for same-size files), near-identical (feature-print distance <= 0.12) and opt-in "similar shots" (<= 0.35), grouped by complete linkage, a BEST badge per group (rating, Picked, size, import order), per-group and global "reject all but best" (a Pick is never overwritten, nothing is ever deleted). Open, none blocking:
- A file the app cannot READ (no folder bookmark in the sandbox, not an image) gets no print/hash, so duplicates among those are invisible; it is only reported in the summary. Live (2026-10-06): 981 of 1,089 photos were unreadable in this install because the real library's Pictures/Desktop folders have no bookmark (only Downloads does) — import the folder again to grant access (same root cause as D31).
- Undecodable files are re-decoded every scan (no "failed at this size/mtime" marker in the cache).
- Grouping is a plain Swift loop (768 multiplies per pair); fine at ~1k photos, would want vDSP (`vDSP_distancesq`) at ~10k.
- Validity is size + mtime: a file rewritten with its mtime preserved keeps a stale hash (documented at `DuplicateGrouping.groups`).
- `FeaturePrintGenerator` regenerates a JPEG's thumbnail when the embedded one is small; NOT measured against a real camera JPEG vs its own export (only the 5571x3719 JPEG's resize was measured in the spike).
- The stale-regroup race (a regroup in flight when a new scan starts) is guarded by `groupingGeneration` but cannot be forced in a test; the cancelled-before-first-read catch likewise (both mutants survive).
- No test of the regroup toggle itself (a real-file pair that groups only as "similar" needs injected prints); no virtual `.duplicates` sidebar filter; no delete/trash, auto-stack, or metadata merge; scope is the current Library source (not search/filter); Rating/Pick are respected by BEST but the Picked-photo case (left alone) is covered by unit tests only, not live.
- The cancel button is unit-tested (scanner level) but was not exercised live (the scan finished in about 15 s, nothing to cancel).

### D54. Styles (iOS Photographic Styles-inspired) — v1 + v2 + v3 (Protect skin) SHIPPED 2026-10-07
Research (2026-10-06, web; details in docs/ROADMAP_HISTORY.md "iOS Photographic Styles research"): Apple's styles are tone presets applied selectively by scene analysis (skin/sky/hair/clothing) with skin protection, editable after capture (Apple keeps pre-style data in a file-format extension), controlled by a 2D Tone/Color pad + a Palette (intensity) slider; iOS 27 / iPhone 18 Pro adds Texture (Soft Skin, Glow, Film, Standard) + Grain applied after capture. NOT confirmed: what the textures do to pixels, the exact pad math or masking.
Plan: v1 presets + pad + strength; v2 Texture + Grain; v3 skin protection after a spike. Our own preset names, two families mirroring the roles (undertone: skin-friendly colour casts; mood: tonal looks). Open decisions for v1's plan: the stored parameter set (pad x/y + strength + preset id), whether a style stacks on or replaces Looks/Color Grading fields, and pipeline position (a measured requirement, not a convention). Estimate (not a promise): v1 ~1 session, v2 ~half, v3 ~1 + spike.

**D54 update — v1 shipped (2026-10-07; commits 47de199 library+math, ea6eb99 EditState+pipeline, 316169a UI, docs).** Open follow-ups, none blocking:
- Preset values are by-eye conventions. TUNING PASS DONE 2026-10-07: all 14 presets were rendered headlessly on four library photos (a studio portrait, a blue-sky telescope shot, a night street shot, a red-rock/blue-sky shot) as contact sheets and viewed. Skin stayed natural everywhere; two presets were retuned — Honey (its tints sat at hue 35-48 and turned a neutral grey background olive/greenish; now 28/34/40, saturations 0.05/0.09/0.12) and Cinema (contrast 0.30 -> 0.22, shadows -0.20 -> -0.12; it crushed dark clothing). The other twelve were left as they were. One viewer, four photos, no objective measure: expect further retuning. A retune restyles photos already carrying that `styleID` (renderer owns the numbers).
- No skin masking (v3). Color's Vibrance share is Apple's documented CIVibrance behaviour, unmeasured here; negative Color and the Saturation share are not skin-aware.
- A style does not reach masks (local adjustments build their own `EffectiveTone`, `vibrance: 0`) and Auto Tone solves without counting the style (it stacks on top, like Brilliance).
- Pad drags are labelled generically in History ("Style Tone, Style Color"); only preset clicks and Reset get explicit labels.
- The strength slider is disabled when no preset and the pad is centred (nothing to scale); not exercised live.
- NOT live-tested: the Strength slider, Compare, export parity vs the editor (the shared `EditPipeline.apply` path is covered by unit tests), a quit/relaunch restore of a styled photo (disk persistence and Codable are tested; persisted History restore was live-verified for the same session), the RAW (landscape NEF) path, VoiceOver actions.
- The Style section header grows the sidebar: the sidebar auto-scrolls when "Reset Style" appears, which shifted coordinate clicks during the live pass (an automation artifact, not a product bug).

**D54 update — v2 texture tuning pass (2026-10-07).** The three textures and the Grain toggle were rendered headlessly on three library photos (a studio portrait shirt/arm crop, a night street shot, a telescope shot) as contact sheets and viewed (one viewer, no objective measure). Retuned: Grain toggle 0.25 -> 0.12 (0.25 looked like coarse digital noise); Soft -0.5/-0.15 -> -0.4/-0.1 Texture/Clarity (it smeared sleeve and shirt edges). Film (+0.2 Texture, +0.15 Sharpen) and Glow (bloom, gain 0.6, threshold 0.75) were left. Soft is NOT skin-aware (it blurs everything alike, disclosed in the UI).

**D54 update — v2 shipped (2026-10-07; commits 0117f29 texture table, 55bf3a9 fields + effectiveDetail wiring, ad7ce76 Glow stage, 70bd5cc UI, 5f3aaf2 tuning, docs).** Open follow-ups, none blocking:
- Glow cost is MEASURED ONLY ON 256 px PATCHES of a synthetic scene (24MP: ~34-49 ms vs Clarity+Texture ~9-12 ms; 96MP: ~110 ms vs ~32-35 ms): ~3-4x Clarity+Texture. A FULL-FRAME render time was NOT measured (my first attempt timed a lazy render and was discarded). Slider drags go through the proxy; the cost lands on the settled full-res frame and on export.
- Glow's constants (threshold 0.75, gain 0.6, blur 0.03 of min extent) are by-eye conventions from three photos; the first tune was made while the stage was adding nothing (a premultiplied-alpha bug, caught by a pixel test) and was redone. A pale studio backdrop above ~0.75 perceptual blooms a little.
- The mask's upper clamp in `applyGlow` is not covered by any test (raising it through the real pipeline gives bit-identical output on a 40x highlight; a standalone copy without the encode step differs).
- A small alpha drift (0.5 -> 0.5025 at a bloom pixel) appears in the full pipeline on a translucent test image; `applyGlow` alone restores alpha exactly, so the source (probably the style's own Clarity nudge) is NOT isolated.
- Soft is not skin-aware. Soft/Film/Grain numbers (Soft -0.4/-0.1, Film +0.2/+0.15, Grain toggle 0.12) are by-eye conventions the renderer owns, tuned on three photos by one viewer.
- Texture/Clarity are deliberately unclamped (preserving the documented out-of-range saturation); Sharpen/Grain are now clamped to 0...1 — a replay change for a hand-edited sidecar with out-of-range values.
- Texture-strength slider drags are labelled generically in History ("Style Texture Amount"); chip and toggle clicks have explicit labels.
- NOT live-tested: the Texture strength slider, Soft, Compare, export parity of Style Grain with output sharpening (unit-tested: ratio 1.339 without the fix vs 1.0), the RAW path, VoiceOver.

**D54 update — v3 skin-protection spike done (2026-10-07), nothing shipped.** Decision: GO to a design plan. Findings and every number: docs/ROADMAP_HISTORY.md "Styles v3 skin-protection spike". Open: (1) the design plan (a "Protect skin" option blending a style's COLOUR changes back by `protection * (skin window AND person mask)`; the style's colour effect is folded into `effectiveTone` stages, so masking it means splitting those out and re-measuring order vs B&W/Vibrance/Saturation, which would change the v1 "style == manual sliders" equivalences); (2) mask persistence vs OS-revision tagging; (3) a GPU Core Image skin window instead of the Swift loop; (4) the spike's limits — no labelled ground truth, 16 photos, one viewer, a narrow skin-tone range (almost all East/Southeast Asian adults; darker skin NOT tested), arm/hand coverage unmeasured; (5) the preset TINTS' effect on skin hue was not measured.

**D54 update — v3 "Protect skin" build in progress (2026-10-07).** Found while building the generator (commit 2): Vision's person-segmentation mask is NOT empty on degenerate input — a FLAT sand-coloured 384x288 image had about 80% marked as person (mask max 255) while a flat blue one had none; on the spike's sand-gradient-plus-rock scene the raw 2016x1512 mask was max 6 / about 20-23 non-zero pixels (hence `SkinMaskBuilder.minimumPersonCoverage`, a convention above that noise). Open: large flat skin-coloured areas without a person (beige wall, sand close-up) may be marked as skin — one synthetic observation, NOT measured on real photos; it belongs in the UI help text as a limit and deserves a real-photo check in the live pass.

**D54 update — v3 Protect skin SHIPPED (2026-10-07; commits 7b9d185, ba6f690, 6f18d19, 8b8195f, 45f6e41, docs).** Numbers and the build story: docs/ROADMAP_HISTORY.md "Styles v3 Protect skin". Open follow-ups, none blocking: (1) darker skin tones, arms/hands and face-box coverage were not measured on the real-photo pass; the 36-of-80 `noPeople` photos were not labelled, so recall on photos WITH people is still only the spike's figure; (2) the monochrome exemption reads the preset only (a +1 Color pad on Silver, or a -1 pad on Hush, is not special-cased); (3) the blend runs in scene-linear after both passes (a convention — it matters wherever the weight is fractional); (4) the feather (`kSkinMaskFeatherFraction` 0.004) and the 128 person-coverage floor are conventions, not tuned on a visual A/B; protection reached some non-skin pixels near the raster on small samples; (5) a GPU Core Image skin window instead of the Swift loop in the spike was never built (the generator's Swift loop is fine at <= 1024 px); (6) a no-colour-effect style (tone only) still lets the toggle run detection and store a raster (harmless, usable later by a preset); (7) skin protection is not applied inside local-adjustment masks (they have their own perceptual sandwich) — a mask's own saturation/vibrance still colours skin.

**D54 update — v3 Protect skin, commit-5 notes (2026-10-07).** (1) [Superseded 2026-10-07 by the Looks tab slice: Reset Adjustments is now sliders-only and no longer touches protection; `ImageDocumentModel.resetLookAndStyle()` (the Looks tab's button) and `revertToOriginal` both call `cancelPendingSkinDetection()`, and both are model-tested.] (2) `CatalogModel.createPreset` stores the photo's whole `EditState`, so a preset saved from a protected photo keeps `styleSkinMaskPNG` in the presets table, unused (`applyingPreset` never reads it; subject-mask PNGs inside `masks` already behave the same way). Strip both in one place if preset rows ever matter for size. (3) `isDetectingSkin` stays true on the NEXT photo until the old detection finishes (same as `selectSubject`).

**D54 update — Looks tab (2026-10-07; commits a74e592, 615d0a9, 2b7672b, docs).** Looks, Style and Presets moved out of the Adjust tab into their own "Looks" tab (it takes the old inert "Filters" placeholder's slot; History stays at the bottom of Adjust). Behaviour changes to know about: Compare and zoom now survive Adjust <-> Looks (they still reset on Crop/Clean Up); leaving Adjust for ANY other tab disarms the point-picking modes and clears mask/Point Color/retouch selections; "Reset Adjustments" resets sliders only — after applying a Preset (which carries a Look and Style) it leaves them, and the Looks tab's "Reset Look & Style" clears Look + Style + skin protection as one undo step (`EditState.resettingLookAndStyle()` is the one field list, also used by `comparisonOriginal()` and the Style section's own Reset, which keeps the Look). The section-expanded flags are still in `AdjustPanelState` (the struct keeps its Adjust-era name). Open: the Adjust-tab -> Looks switch rebuilds the shared ScrollView (scroll position is not kept per tab, as before for Adjust <-> Crop); `lookImportMessage`/`looksRevision` are per-`LooksTabView` state (reset on a tab switch; both alerts are modal). Not built yet: a thumbnail grid for Looks/Style (planned as the next slice: small cached previews of the current photo).

**D54 update — Looks tab thumbnail grid (2026-10-07; commits f713a1f, 23c63a7, abe8f07, docs).** Design and numbers: docs/ROADMAP_HISTORY.md. Behaviour to know about: a cell's preview is what clicking it would produce (`LookPreviewItem.applying`, which reproduces `selectLook`/`selectStyle` including the None-cell strength resets); previews omit masks, retouch spots and red-eye points; a Look cell keeps the current Look intensity and Style, a Style cell keeps the current pad/strength/texture and Look; the Looks and Style sections now default EXPANDED (Presets and the Adjust sections stay collapsed) because a collapsed grid shows nothing and previews are only rendered while a section is open. Open follow-ups, none blocking: (1) previews are approximate for stages whose look depends on image size (Clarity, Dehaze, NR, Grain, Glow) — not corrected, the click result is the real render; (2) an extreme aspect ratio whose short side scales below 1 px (a 1x4000 strip) gets no previews (nil base; the refresh retries harmlessly); (3) a pass already running when the user leaves the tab finishes: it is cancelled only by a newer refresh (which is also how a photo switch cancels it, so only once the tab is open again) — leaving the tab or collapsing the section does not cancel it — and `releaseCaches()` runs only after a COMPLETED pass; (4) the old photo's previews can briefly stay published after a photo switch while the tab is hidden — views read them through `looks(forRevision:)`/`styles(forRevision:)`, which hides a mismatched set; (5) each cell render hops to the global executor; a render already running at cancel time finishes and is discarded; (6) a removed imported look's cached preview stays in the model's dictionary until the next photo switch / re-decode clears it (never shown: the cells are built from the current item list); (7) the first-fill cost on a REAL 24 MP JPEG was not measured (the base build was timed on a synthetic gradient+noise image); (8) not live-verified in the running app (only an offscreen render of the real view) — clicks, tab/photo switching, RAW, imported-look removal.

### D55. History popover (2026-10-07) — follow-ups, none blocking
The History list moved from the Adjust tab to a toolbar popover (`HistoryRow`, `HistoryPopoverView`, `ContentView.historyToolbarItem`; commit ae9a078). Open: (1) NOT verified in the running app — popover anchoring, behaviour when the toolbar item overflows into the `>>` chevron (the button becomes a menu entry with nothing to anchor to; `isHistoryPresented` could stay true and tint the button while nothing shows), whether clicking the History button while the popover is open closes AND immediately re-opens it (a known SwiftUI quirk), whether `scrollTo` on appear lands on the current row with 101 rows (deferred one run-loop turn as a precaution), focus return to the image pane (skipped when a text field has focus or in Library mode); (2) the D27 quirk is unchanged: tapping the row shown as current within the ~350 ms debounce window jumps back over the pending edit — editing in the sidebar closes the popover (click outside) so it is less reachable; (3) History is now reachable from the Looks and Clean Up tabs too: a jump while a retouch spot or mask is selected can delete the selected item (toolbar Undo already could, on every tab); (4) rows have no timestamps (`HistoryEntry` stores none); (5) no Edit-menu "Show History" command (a Scene command cannot read `ContentView`'s `@State`; it would need a request flag like `keywordSheetRequested`); (6) the pure builder has one equivalent mutant (`>` vs `>=` after the `==` check).

### D56. Multi-spot Remove ("Place Spots", Lightroom-style) — shipped 2026-10-07, follow-ups
Commits 08255ed (pure placement geometry), 72746d6 (mode + add/delete/Find Source as undo steps), 62355f3 (tool UI), docs. What it does: the Remove section's "Place Spots" toggle arms `EditorInteractionMode.placingRetouchSpot`; while armed every click on the photo adds a spot at the PRESS point (a drag sizes it; a plain click uses the last size the user dragged out/resized, `AdjustPanelState.retouchNewSpotRadius`), a press on an existing spot selects it, every spot is visible as a thin ring, the selected spot has its centre/source/radius handles, Delete removes the selected spot, Escape deselects then stops the tool. Each add/delete is its own undo step ("Add Spot"/"Delete Spot"), and the auto-source result lands as its own "Find Source" step (dropped if the user has undone since, so a background result never wipes the redo stack). Open, none blocking: (1) **the pointer gestures were NOT driven by automation** (synthetic mouse events do not reach this sandboxed app): verified by unit tests of all the maths/model/key routing and an offscreen render of the real overlays (ring positions incl. the y flip, the selected spot not drawn twice, the radius handle on the right edge), plus reading — a MANUAL checklist is in PROGRESS.md; (2) [Superseded 2026-10-07/08 by D59: zoom/pan while editing spots now works.] (3) identity geometry only (unchanged, D46); (4) hit testing picks the nearest centre (smaller circle on a tie, later spot on a full tie) rather than "topmost" so nested spots stay selectable; a 6 pt slop ring around each circle also selects it; (5) full-resolution cost is still ~55-80 ms per spot per render (spike numbers) — 20+ spots will make full-res previews/exports slower, the live editor uses the proxy; (6) the remembered click radius is not updated by the Size slider (only by drag-sizing and the radius handle); (7) a late source-search result that is dropped because redo exists is silent for the automatic search (a message is shown only for an explicit Find Source press); (8) deleting the selected spot by Undo leaves the selection id dangling in `AdjustPanelState` until the next selection (the overlay re-checks the live list, so nothing shows); (9) `hitTest` selects a spot with opacity 0 (the renderer skips it) — arguably right, the user must be able to select it to edit it.


### D59. Zoom/pan while editing spots — shipped 2026-10-08, follow-ups
Commits af72012 (pure geometry), ed9d669 (overlays), 476d31b (wiring + Space pan), docs. What it does: with the Place Spots tool armed or a spot selected, scroll-zoom (about the cursor) and arrow-key pan work; the spot overlays are positioned against `ZoomPanGeometry.displayedRect` (the zoomed, panned picture) and clip themselves to the pane; plain dragging still belongs to the tool, so panning is Space + drag (a full-pane `PanOverlay` mounted only while Space is held, `RetouchZoomRules`); picking an off-screen spot from the sidebar pans it to the centre. `ImageRenderer.fitted` now calls `ZoomPanGeometry.zoomedOriginYUp`, the single place the pan's y-flip lives (output bit-identical: `(-a)*b == -(a*b)`). Open, none blocking: (1) **NOT verified by automation — pointer gestures and KEY events do not reach this sandboxed app** (the maths, rules and offscreen renders are tested; Space-pan, scroll-zoom with the tool on, clip behaviour and hit-testing are a manual checklist, PROGRESS.md); (2) `.clipped()` clips DRAWING only, so a handle whose centre is panned off the pane is switched off for presses by its centre (`isInsidePane`) — the part of a disc overhanging the pane edge can still take a press (≤ one radius); (3) `isSpaceHeld` is reset on tool end, pane focus loss, app deactivation and any window resigning key (deliberately broad), but a Space key-up lost any other way keeps the pan layer mounted until the next Space press or Escape; (4) a scroll-zoom or pan DURING a press drops that placement/selection (`PressRecord`), by design; (5) `onHover(true)` fires only on pointer movement, so pressing Space without moving the mouse shows no hand cursor yet, and there is no closed-hand cursor while dragging; (6) the reveal-on-sidebar-pick uses a 24 pt margin and centres the spot (no animation); (7) other overlays (masks, red-eye, WB/colour pickers, crop) still block zoom — generalising `displayedRect` to them is a separate job (their capture layers frame themselves to `fitRect`, so a zoomed rect would overflow the pane; keyboard crosshair and `commitPointPlacement` use `currentFitRect`); (8) Compare modes: the retouch layers still require `compareMode == .off`.

### D57. LightCraft feature-gap list (researched 2026-10-08) — open, each its own session
Source: the README, ROADMAP and screenshots of github.com/storytold/lightcraft (an open-source pure-Rust Lightroom clone, same non-destructive concept). README only — NOT its source or `docs/parity.md`; its claims are unverified. Where we are AHEAD (don't regress): CIRAWFilter camera colour for ~784 bodies (LightCraft uses a neutral matrix for non-DNG RAW), Vision subject masks with per-subject picking, Enhance/Super Resolution, Looks/Styles with live thumbnails, skin protection. Not pursued: pure Rust/WASM/own RAW decoders (would discard CIRAWFilter), cloud generative models (ArtCraft, same org — breaks the on-device rule). Priority order (value / effort):
1. ~~**Field-based search**~~ ✅ SHIPPED 2026-10-12 (see docs/ROADMAP_HISTORY.md; open gaps below in D63) — — `rating:>3 flag:pick iso:>800 camera:x2 date:2026-04 keyword:mountains`. Needs EXIF fields (ISO, camera, lens, date) in the catalog first — check what `Photo` stores; extends `LibraryFilterSort`.
2. ~~**B&W Mix**~~ ✅ SHIPPED 2026-10-12 (see docs/ROADMAP_HISTORY.md; still open: Intensity/Neutrals/Tone/Grain, Auto mix, live tuning of kGrayMixStops) — 8-band darken/lighten per colour (skies/foliage). We only have the on/off toggle. Reuses the Selective Color band machinery; own design pass for where it sits relative to B&W's forced desaturation. Also from D35 item 1: B&W Intensity/Neutrals/Tone/Grain.
3. ~~**Whites / Blacks sliders and per-mask extras**~~ per-mask Whites/Blacks ✅ SHIPPED 2026-10-12 (a GLOBAL Whites slider and the rest of the per-mask list are still open): — they list 15 local adjustments per mask (Temp, Tint, Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Texture, Clarity, Dehaze, Hue, Saturation, Sharpness, Noise) plus an overall Amount. Check overlap with our Levels/Curves and the existing mask fields before adding anything.
4. **Standard XMP `crs:` read/write** — edits round-trip with Lightroom/Camera Raw (they read `crs:` develop settings and auto-write XMP). Ours is proprietary `.photoapp.json` (D35 item 4). Risky: our pipeline is not Adobe's, so start with a SPIKE measuring how close the mapped render is. Also `.lcpreset`/XMP preset import.
5. **Culling views** — Compare (two photos, synced zoom) and Survey (N photos) views, auto-advance after rating, Auto Stack (by time or similarity), virtual copies / versions. Builds on `CompareLayout` and duplicate detection (D53).
6. **Photo Merge: HDR (auto-align, deghost), Panorama (spherical/cylindrical/perspective, auto crop), HDR panorama** — D35 item 6. Spike first: Vision's `VNHomographicImageRegistrationRequest` / Core Image warps for alignment; measure on real brackets.
7. **Optics / geometry** — Upright (Auto/Level/Vertical/Full/Guided), auto straighten, manual lens distortion, automatic chromatic-aberration removal (we only have Defringe; lens profiles need data we lack — D35). Offset transform; "Constrain Crop".
8. **Import options** — Add in place / Copy / Move, rename and folder templates on import, device import, watched folders. `NamingTemplate` already exists.
9. **Export formats/options** — WebP, AVIF, DNG, original-file export, a file-size limit, an image watermark (we have text only). Extends `PhotoExporter` (D48).
10. **Library niceties** — Recently Deleted (soft delete) with restore, an Info panel with editable title/caption/copyright, Calibration panel, a parametric/region tone curve mode and targeted-adjustment (drag-on-image) for Curves/Color Mixer, Sky + Background masks (see D35 item 2: Sky needs a model), per-component Invert on masks.
11. **Agent/MCP control surface** — LightCraft's headline idea: every command (slider, mask, export…) has a stable id + JSON params, dispatched by UI, keyboard, CLI and an MCP server. Architectural: our actions are spread over SwiftUI views and models, so it needs a command registry first. Lowest priority; spike the registry cost before committing.
Not yet verified: whether LightCraft's claims (speed numbers, "CPU-exact within 1/255", parity %) hold — they are README statements, not measurements we made.

### D58. LightCraft UI/UX comparison (2026-10-08) — open, each its own session
Source: four LightCraft screenshots (Edit view, Masking, library grid, Presets + Color Mixer) viewed 2026-10-08. They are marketing shots on a demo library: responsiveness, keyboard behaviour and feel are NOT assessed. The comparison with OUR UI is from CLAUDE.md, NOT from a live look at our app this session — verify each item against the running app (screen automation needs user permission, see memory) before building. Priority order:
1. **Persistent rate / flag / colour-label / "Copy Edit Settings" bar** under the photo (they: 5 stars, label circle, pick/reject flags, Copy Edit Settings and a settings gear, always visible in grid and loupe). Small, high-frequency; our rating/flag/copy are toolbar buttons + shortcuts.
2. **Colour-gradient slider tracks** — Temp (blue→yellow), Tint (green→magenta), Hue (rainbow), Vibrance/Saturation (grey→colour) show what the slider does on its own track. A `ThinSlider.swift` extension: an optional gradient background; keep the VoiceOver/typed-entry behaviour.
3. **Histogram pinned at the top of the sidebar with an EXIF strip** (ISO, focal length, aperture, shutter) always visible. Check where ours sits (`HistogramView`) and whether it scrolls away.
4. **Right-hand icon rail for tools** (Presets, Edit, Crop, Retouch, Masking, Red-eye, Versions, History, Keywords, Info) instead of putting masks/retouch/red-eye inside one long Adjust scroll. Bigger restructure of `EditorTab`/`AdjustTabView`; it interacts with the `keepsCompareAndZoom`/`disarmsPointModes` tab rules (D54's Looks-tab entry) — read those first.
5. ~~**Filmstrip under the editor photo**~~ — WRONG, RETRACTED 2026-10-08: our editor already has one (seen live, bottom of the window, current photo outlined). What LightCraft's adds: the file name + type above each thumb, rating/flag overlays on the strip thumbs, and a Click 1:1 / Fit zoom dropdown beside it. Only those extras remain.
6. **Single window, grid + loupe as views of one space** (bottom-bar switch between grid / square grid / loupe) instead of Library vs Editor modes. Large; consider only after 4–5.
7. **Library grid**: a justified-rows layout that keeps aspect ratios, a zoom slider bottom-right, per-thumbnail stars/flags overlay, an "edited" badge (we have D3's badge — compare), per-folder/album counts, By Date section, Recently Deleted. Check what `LibraryGridView` does today.
8. **Masking panel layout**: an 8-tile "Create New Mask" grid with icons, a named mask list with an eye toggle, Add / Subtract / Invert / delete beside the selected mask, the mask's sliders reusing the main slider component, a red overlay with a draggable centre pin. Compare with our mask UI before changing anything — ours may already match.
9. **Collapsed sub-rows inside a section** (Curve, Color Mixer, Color Grading as one-line rows inside Light/Color) to keep the default panel short. Ours are separate DisclosureGroup sections — check section count/length.
10. **Title-bar search + filter button always visible**, plus undo/redo arrows in the title bar.
11. **Edit header row**: Auto, B&W and Reset as three buttons at the top, with a Profile picker underneath (our Auto is the first row of Light; B&W lives elsewhere).
12. **Preset list grouping** (B&W, Color, Film, Landscape, Portrait, Style; collapsible; "+" to add). Ours is user-created presets without groups — consider folders/groups. Do NOT replace our Looks/Style thumbnail grids with a name-only list — theirs is plainer than ours.
13. **Minimal design-token pass** (found 2026-10-08, from LightCraft's `crates/ui-egui/src/theme.rs`; its header says the values were measured from Lightroom's dark theme, so it is a deliberate look-alike). Their style: neutral grey only — surfaces `#0f0f0f` grid / `#1c1c1c` canvas+dividers / `#232323` inset / `#2d2d2d` panels+top bar; text `#e2e2e2` / `#bcbcbc` / `#8e8e8e` / `#5c5c5c` disabled; ONE chromatic accent `#0165dd`; colour otherwise only for meaning (reject `#e04a4a`, caution amber `#e3a83c`, translucent red mask overlay; stars and picks plain light grey); one font (Inter Regular + SemiBold); named layout metrics (top bar 42pt, bottom bar 48pt, panel 270pt, icon rail 48pt, slider row 45pt, section row 57pt); sections are text + chevron, icons only on the rail. Ours (live screenshot, 2026-10-08): per-section icons, tall bold section rows, a purple-tinted title/tab area (likely macOS vibrancy — unverified whether intended). Proposal: define one small token set for the editor (3-4 neutral surfaces, one accent, 3 text greys, row heights) and drop per-section icons when D58 item 4's rail exists. NOT checked: how our colours are defined today (system defaults vs. asset catalog); whether neutral-only is better for the user is a taste call — a convention, not a measurement.
Where ours is likely better (keep): Looks/Style live preview thumbnails, the interactive point-curve editor and colour wheels, the History popover, Compare / Split view, keyboard crosshair paths for eyedroppers.

**D58 live side-by-side (2026-10-08, screenshots of LightCraft's real window and our Release build's editor, window-only captures; nothing was clicked or changed in either app).** Observed in OUR editor: the segmented Adjust / Looks / Crop / Clean Up control sits centred above the canvas; the right sidebar is 11 collapsed sections with icons and tall rows (Remove was left expanded), History at the very bottom of the scroll; NO histogram visible at the top of the sidebar and NO rating/flag/copy-settings bar anywhere in the editor window (items 1 and 3 above confirmed for the default window size — the histogram might live inside Light, not checked); a filmstrip with a loading cell at the end. Observed in LightCraft: a real macOS traffic-light window with a global search field, a RIGHT icon rail (Presets, Edit, Crop, Retouch, Masking, Red-eye, Versions, History, More, Keywords, Info), a 5-way view-mode switch bottom-left (grid / list / loupe / compare / survey), a before/after toggle and a panel toggle bottom-right, an empty-state "No edits yet" History panel. Our window chrome here showed a purple-tinted title/tab area against LightCraft's neutral charcoal — likely vibrancy over the desktop, NOT verified whether that is intended. Not compared live: LightCraft's sliders/masking under interaction, either app's responsiveness.

**D58 live interaction pass on LightCraft (2026-10-08, user-authorized, LightCraft window only, demo library; guarded clicks via cliclick, window-only captures; the one edit made — Exposure — was reset).** Seen:
- **Library <-> editor is one window with no mode load.** Five view buttons bottom-left (grid / list / loupe / compare / survey): one click on the first showed a date-grouped grid with the SAME right rail and panel still open (Presets); double-clicking a photo opened the loupe at once with the filmstrip underneath. The double-click also landed at 100% (the second click toggles a "Click 1:1" zoom, with a navigator minimap bottom-right); one more click returned to Fit. Rating / flag / "Copy Edit Settings" bar stays at the bottom in every view.
- **Rail icons are panel toggles that stack**: Presets and Edit open side by side, the canvas re-fits to the remaining width. Edit's header (Auto / B&W / Reset), Profile picker and a histogram + EXIF strip sit above Light.
- **Sliders**: dragging Exposure 60 px right gave +2.69 and the image, histogram and the filmstrip thumbnail updated together; the thumbnail also gained an "edited" glyph. Reset (one click) restored 0.00 and the image. Nested tools (Curve) expand inline inside Light: channel dots (RGB/R/G/B), a curve box, a "Point Curve Linear" mode dropdown and its own Reset.
- NOT measured / tested: drag latency (captures were taken ~1 s after the drag), masks, undo, keyboard shortcuts, before/after (`\`, Y), RAW. The grid was a one-photo-per-date layout on this demo library, so it says nothing about their justified-row quality at scale.
Takeaway for us: the part worth copying is not any single control but that the right panel, filmstrip and rating bar never change between grid and loupe, so switching feels like changing zoom level, not changing app mode (D58 items 1, 4, 6).

**D58 item 1 shipped 2026-10-08 (Editor rating/flag/label bar + keys; see PROGRESS.md).** Follow-ups: acting on the open photo can drop it out of the filtered `displayedPhotos` (rating threshold, flag/label filter, smart collection) — the bar keeps working, but ⌘←/⌘→ and the filmstrip follow the filtered list; the lookup is path-string based; an empty bar when the catalog is not ready yet; holding F or . auto-repeats the Pick toggle (the Library grid does the same). Item 4 (right icon rail) shipped 2026-10-08 as a relocation only: splitting Retouch / Masking / Red-eye into rail entries, and the other rail entries, are still open (see PROGRESS.md).

**D58 follow-up, 2026-10-08:** the toolbar's right-hand action buttons moved into the rail (see PROGRESS.md). Open: Enhance and Revert to Original are no longer reachable from the Library (Revert has no menu item — adding a Photo-menu item would restore it); the Compare entry's disabled/active look is only manually verified (native `Menu` renders unstably offscreen); the Crop "Done" button is still a top-toolbar item.

**D58 item 13 (design tokens), status 2026-10-08:** DONE — neutral surfaces (`Theme.panel` / `raised` / `hairline`), one accent (`Theme.accent`, used directly because `Color.accentColor` is the system accent), solid HUDs / rating bar / rail, flat buttons (`FlatButtonStyle`), icon-free section headers, flat slider and style pad, no Liquid Glass (opt-out key + flat window buttons + toolbar items without backgrounds). NOT done: text-grey tokens (primary / secondary / disabled are still the system's), one font family, named layout metrics (row / section heights), plain-grey stars and Pick marks (they keep colour for meaning), a `Theme.warning` token for the scattered `.orange` warning captions, and the Library grid's cell badges / filter bar.

**D58 follow-up (2026-10-08): quiet selection done** — see CLAUDE.md "Quiet selection". Open nits: root `.tint(Theme.accent)` still turns system toggles/segmented pickers blue; the custom sidebar lacks type-to-select, drag, scroll-into-view; `moved` Up/Down from a hidden selection jumps to the first row; History chip may be faint on the popover background (judge by eye).

**D58 finishing pass (2026-10-09): items "Library marks", "text-grey tokens", "quiet system controls" done** — see CLAUDE.md. Open nits: `ThinSlider` has no keyboard focus/arrow handling (the native Slider did), so the 3 Export sliders stay native; text greys are fixed (no Increase Contrast adaptation); no font swap / no `Theme.Font` roles (only aliases would result); `Color.gray.opacity` placeholders remain; segmented-picker and progress-bar tint are not testable offscreen.

**D58 item 4 finished (2026-10-09): Retouch / Red-eye / Masks are rail tabs** (see CLAUDE.md). Open nits: after the move the cross-clears of other tools' selections inside Adjust-view select/arm sites are dead defence in depth; Crop's Done always returns to Edit; `ThinSlider` adds one Tab stop per slider (46 in Edit) with Full Keyboard Access; the new scope render test is slow (~27 s).

**D58 Library polish + tab memory done (2026-10-09).** Open nits: scroll memory is macOS 15+ only and unverified live (a remembered offset round-trip could be off by a top inset); the cell label menu has no swatch (a second image could displace the checkmark; a drawn-check swatch would fix it); dimmed cell chrome ignores Increase Contrast; `isHovered` can stick if a cell scrolls away under the pointer; the filter-pop-up swatches are AppKit-drawn (confirm colour live).

**Culling v1 follow-ups (2026-10-09):** compare-two photos (renderer: Compare only does before/after of ONE photo today), survey view, "also advance after rating" toggle, 100% zoom (zoom is relative to fit, no 1:1 concept), id->index map on `CatalogModel` so `rows` is O(1), serialise rating/flag/label DB writes per photo (separate `Task.detached` writes can reorder), exit back to the Editor when the pass started there, Increase Contrast for the cull bars.

### D60. Faces v1 follow-ups (2026-10-09) — open, none blocking
(1) Two loads for the same selection (the `selection` didSet task plus a correction's reload) can publish out of order; a per-load counter would close it. (2) Photo menu "Rename Files…"/"Undo Rename" are not disabled while a face/duplicate scan winds down after Done; the request is dropped silently by `ContentView`'s guard (the toolbar button now reports it through `RenameBusyState`). (3) Grouping cost: the `fit` check ordering and a same-photo set map could be cheaper; scale limit roughly 30k faces / 300 MB of prints before the in-memory plan hurts. (4) A photo whose detection always fails is retried every scan (no "detectionFailed" record). (5) RAW sources use the embedded preview (small): faces below the 40 px floor are missed. (6) No "might also be X" suggestions, no smart-collection person criterion, no auto-scan on import. (7) Person filter only matches photos with an ASSIGNED face; unsorted faces are in no person's results. Spike numbers and thresholds: `docs/ROADMAP_HISTORY.md`. (8) `renamePerson` normalizes the name (`KeywordName.normalize`): if the saved form differs from what was typed (trailing spaces, control characters) the name field keeps the raw text, Save Name stays enabled and the field stops following outside renames until the selection changes; fix: after `.renamed`, set `nameText` to the stored name if the field still holds the submitted text.

### D61. Photo Merge follow-ups (2026-10-09) — open, none blocking
1. **HDR merge dark-bracket precision.** `HDRAccumulate.cikernel` packs `scale * sum(w * x / g)` in an RGBAh accumulator; if Core Image stores a half-float intermediate between passes, a bracket whose BRIGHTEST frame has x below ~1e-4 is quantised (reviewer simulation with Float16 round-trips, gains 1/16..1, scale 256: radiance 1e-5 -> -100%, 3e-5 -> -100%, 1e-4 -> -8%, 3e-4 -> +0.7%; scale 1024 shipped, roughly 4x better, not a cure). Absolute error stays under ~1e-4 linear (below one 8-bit level) but shows when shadows are pushed hard after a merge. A cure is a running weighted MEAN in rgb (`mean += (w / (a + w)) * (est - mean)`), which stays radiance-scale; needs matching `HDRMergeMath` and tests.
2. `HDRMergeFilter` caps at 9 frames and gains 1/16...16 (the packed-value bounds); a wider bracket would need a different packing.
3. No deghosting yet (planned stage 2 toggle); no merge options sheet / catalog wiring yet.
4. **HDR merge has run on ONE real RAW pair (2026-10-09, see docs/ROADMAP_HISTORY.md Stage 2b: linear decode confirmed, gain measured, aligned 98%) but never on a 3+ frame bracket, real highlights above 1.0, a moving subject, or a JPEG/HEIC bracket.** `PhotoMerger.linearDecodeState` neutralises the tone-shaping RAW fields (verified by reading, not by measuring). When first checked on a D610 NEF bracket, measure: that `x_bright / x_dark` stays near the EXIF gain across tones; the clip point vs the weight tent (the tent reaches 0 at output 1.0, but a RAW's clip point is about 2^baselineExposure times the white-balance multiplier, so on a camera with NEGATIVE baseline exposure clipped pixels could land below 1.0 and keep weight); `isGamutMappingEnabled` (chroma compression, could make saturated colours slightly non-proportional); `localToneMapAmount` (unchecked on the D610). JPEG/HEIC brackets carry the camera's tone curve and any Active D-Lighting, so they are only approximately linear. The pinning test checks `EditState` fields, not the resulting `CIRAWFilter` properties.
5. Registration of the darkest frame is marginal on the synthetic fixture (13 inliers vs the floor of 12): shadows of an 8-bit dark frame, once brightened, are thin. Real brackets are untested.
6. **Panorama v1 limits** (`PanoramaMerger`, IMPROVEMENTS D61): planar (homography) projection only — a cylindrical/spherical projection would allow wide sweeps; distance-to-edge feather blend, no seam search or multi-band blend (ghosting with moving subjects, visible seams under strong vignetting); exposure compensation is first-order (median luminance ratio between neighbours, rejected beyond +-25%) and assumes the decode curve is roughly proportional; frames are registered as consecutive pairs only (no bundle adjustment, so error accumulates over long sweeps); the matcher is not scale-invariant; never run on a REAL panorama sequence; output is an uncompressed half-float TIFF (about 8 bytes/pixel: a 60 MP panorama is ~480 MB — compression or an 8/16-bit option would help); proxy-scale registration (1600 px) amplifies sub-pixel proxy error by the full/proxy ratio (up to ~2 px at 24 MP).
7. Photo Merge UI: no cancel button; no progress beyond a spinner; the HDR deghost toggle was never built; merged files get no sidecar and no link back to their sources.

### D62. Depth Range mask follow-ups (2026-10-12) — open, none blocking
1. **Never run through the live app UI**, and the model never on astronomy/night, thin structures (wires, fences), glass/reflections or macro (spike only covered a handful of D610 and iPhone photos).
2. Embedded iPhone depth is unreliable on distant scenes (two of six sample files, Spearman 0.11 and 0.33 against the model); the UI offers an explicit source choice but does not warn when embedded depth looks poor. A quality heuristic (edge agreement, low spread) could pick the source automatically.
3. The model input is a fixed 518x392: landscape photos of another aspect are stretched, square images count as landscape, the output is upsampled bilinearly (no edge-guided refinement), so depth edges are soft at full resolution (the feather hides it).
4. No click-on-image "pick a depth" eyedropper (planned optional); no spatial feather/smoothing of the depth raster itself; the hard-edged window (feather 0) shows the raster grid.
5. A combine mode is not reflected in Show Selection (window + Invert only). Holes in an embedded map (NaN/inf) become "far", so a window reaching nearness 0 or Invert selects them.
6. The model is not in git: a checkout without `scripts/fetch_depth_model.sh` only offers embedded depth (the UI says so). First use after launch pays a ~7 s model load (compile / Neural Engine specialisation); it runs on a background task but there is only a "Reading…" label.
7. `MLModel.load(contentsOf:configuration:) async` would avoid holding a cooperative-pool thread during the 7 s load (optional).

- D61 live note (2026-10-12): the first merge into a folder prompts for folder access ("Allow access to <folder> so the merged photo can be saved...") even right after importing that folder; the import's grant is not reused for merge output (Enhance reuses the sidecar grant). Harmless but a surprise; consider reusing `SidecarFolderAccess`.

### D63. Field-based search — open gaps (2026-10-12)
1. ~~Search text and fields are not saved in Smart Collections~~ ✅ SHIPPED 2026-10-12 (see docs/ROADMAP_HISTORY.md). Open from it: pre-change builds silently ignore the new `searchQuery` key and would show a BROADER collection (no version field to guard with); Export/duplicates/faces act on a query collection's current, possibly partial, set; the person filter is still not a smart-collection criterion.
2. A catalogued file that ImageIO cannot open (not an image, or no access) is re-read on every needs-scan pass (count change / retry): one stat + one failed header read each, cannot loop.
3. The scan hint line appears under the filter bar while a scan runs, which shifts the grid down one caption line; reserve the height if it bothers.
4. No autocomplete / query builder; no GPS/place fields; ISO beyond 65535 relies on `ISOSpeed` (`RecommendedExposureIndex` is not read).
5. Capture sort puts undated photos last in BOTH directions (not by import date).
6. Photos in folders this sandbox has no library access to are skipped by the scan (and by thumbnails); fixing the access fixes both.
7. Multi-word plain search is now an AND of words (was one substring): results only broaden.

### D64. Parametric curve: Shadows +1 with Highlights +1 reverses the very top (pre-existing, found 2026-10-12)
`curveControlPoints` builds a 5-point natural cubic; with both point1 and point3 raised to their maximum the end slope goes slightly negative (global path: -0.029 at sh+1 hi+1, -0.093 at hi+1 bp-1), so the brightest tones/headroom can come out marginally darker than slightly less bright ones. Not introduced by per-mask Whites/Blacks (which only scale it for a strong Whites boost). Fixing it would change the byte-exact curve pinned by ~70 assertions; a monotone-clamped variant would need those re-pinned deliberately.

### D65. XMP sidecar interop v1 — shipped 2026-10-14, open limits
Shipped: write/read of rating, reject, colour label and keywords to/from standard `.xmp` (see CLAUDE.md's XMP bullet and the history entry). Open, none blocking:
1. **Pick is not exchanged** (no standard XMP field); picks stay catalog-only. Lightroom/Bridge read `-1` as Reject only.
2. **Lightroom ignores a `<base>.xmp` next to a JPEG/TIFF/DNG** (it keeps XMP inside those files and never reads such a sidecar); the sidecar helps RAW workflows and darktable/digiKam-style tools. We never embed XMP into originals.
3. **Keywords are half-synced**: `dc:subject` is replaced, a stale `lr:hierarchicalSubject` is kept (Lightroom prefers it). No hierarchical keywords in the catalog.
4. **Empty Library values never erase** a rating/label/keywords already in the file (so removing a keyword here does not remove it from the file if the Library then has none left).
5. The merge **re-serialises through ImageIO** (not byte-preserving: the `xpacket` wrapper is dropped, attributes may become elements); **not compare-and-swap** (a concurrent write by another app between our read and write is lost; `.atomic` replaces a symlinked/hard-linked `.xmp` with a plain file and normalises `.XMP` to `.xmp`).
6. Ownership uses catalogued paths plus every supported image file found on disk in the selected photos' folders (a catalogued photo missing from disk can still own on the XMP side); a DNG counts as RAW (`RawDecoder.isRaw`) though Lightroom keeps XMP inside DNGs. An alternate-name `IMG_1.JPG.xmp` is read as a fallback and written only if it is the one that exists.
7. **Rename**: the preview does not foresee an orphan `<newbase>.xmp` at a destination, nor a rename that would change WHICH photo owns a shared `.xmp` (a RAW arriving beside a JPG's xmp, an xmp owner landing beside a RAW): the engine refuses both at apply time, before anything moves, with a message. `Locate…` (relocate) does not move `.xmp`, the same as `.photoapp.json`.
8. Cull mode does not check `xmpBusy` (a flag changed mid-run is covered by the fresh-row re-fetch after the folder prompt, not by a guard).
9. The ownership rule is "a RAW wins, otherwise the first photo by name", so adding a file can take over a shared `.xmp` (e.g. exporting `a.jpeg` next to `a.png` + `a.xmp` makes `a.jpeg` the owner). Narrow; `RenameEngine.xmpPlans` also lists a folder per call (cached per batch, not across batches).
10. Not built: automatic write on every change, `crs:` develop-setting mapping (D57 item 4), embedded-XMP write.

**2026-10-14 update — whole-curve replacement tried and NOT shipped (needs a user decision).** The plan was to render the parametric curve through `MonotoneToneCurve` + `PointToneCurve.cikernel` (which cannot reverse). It was built and run against the suite: 14 test functions / 62 assertions moved, far more than the "~0.016" earlier recorded in `MonotoneToneCurve`'s doc (that figure was a fit against `CIToneCurve`, not a slider-cube comparison). MEASURED on the real code (temporary harness, deleted): over sh/hi/bp in {-1,-0.5,0,0.5,1}, linear 0.01..1.0, the worst natural-vs-monotone gap is 0.265 (sh +1, hi -1, bp -1, at 0.1); typical single-slider moves were 0.02-0.07 (Highlights +1 lifts linear 0.5 to 0.847 with monotone vs 0.918 with the natural cubic; Black Point -1 no longer lifts mid-tones; headroom at linear 1.6 differs by ~0.2). So every existing edit using Shadows/Highlights/Black Point/Brilliance would render visibly weaker, and the slider spans would need re-tuning. Also measured: the natural cubic's reversal is NOT limited to the top — over the same cube the worst non-monotone dip inside 0..1 is 0.288 linear (sh +1, hi -1, bp -1, at 0.3), only in extreme corner combinations; with headroom (linear up to 4) a dip of 0.44 appears at sh/hi +1, bp -1. Options for the user: (a) leave as is (reversal only in extreme corners), (b) a narrow fix that keeps today's curve wherever it is already monotone (e.g. clamp the end slope / flatten reversing segments), (c) the full monotone swap WITH re-tuned `kCurvePointSpan`/`kBlackPointSpan` and a deliberate re-pin of ~70 assertions. Nothing was changed.

