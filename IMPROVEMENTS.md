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

Residual open items from shipped entries:
- **D14** — mask/point-color *selection* state (`selectedMaskID`/`selectedPointColorID`) is still a 3-way inconsistent mix across the arm sites (no functional consequence found); `SelectiveColor.cikernel`'s `rgb2hsl` has no negative-channel clamp. Full text in history.
- **D34** — Xcode Previews (`XCODE_RUNNING_FOR_PREVIEWS`) still open the real catalog; Swift Testing / non-`xcodebuild` test plans not verified to set the XCTest markers.

## Open items

### D35. Lightroom Classic parity backlog (researched 2026-09-30) — feature gaps, prioritized
Sources: Lightroom Classic releases 14.4 (Jun 2025) through 15.6 (Sep 2026) as summarized by Lightroom Queen and PhotoshopCAFE (Adobe's own release-notes pages returned 403), plus general Lightroom knowledge; items marked (R) are confirmed in those summaries, the rest are unverified. Release-note additions are in the second list below. Supersedes nothing in CLAUDE.md's "Gaps vs. Adobe Lightroom Desktop" (which covers Develop only) — this adds Library/Import/Export/multi-photo gaps. Each item is its own session (Plan Mode first). Priority order (value / effort):

1. **Profiles / LUTs** (`.cube`, Amount slider) + small Develop gaps: Vignette Softness, B&W Intensity/Neutrals/Tone/Grain, Color Grading Blending/Balance + Global wheel, HSL per-band Lightness check, Calibration panel, custom crop overlays.
2. **AI masks via Apple Vision / Core ML**: Subject, Sky, Background, People parts, Landscape (R: Feather/Edge refine sliders, Aug 2026), Object Select, Depth Range, in-mask Add/Subtract/Invert layers. Start with a feasibility spike (`VNGenerateForegroundInstanceMaskRequest` gives Subject/People free; Sky/Landscape need a model) — same approach as the MetalFX probe.
3. **Healing / Clone spot removal** (classic patch, no ML); later Generative Remove (R: better reflection removal, Sept 2026), Generative Expand / Crop & Expand (R), Lens Blur, AI Denoise.
4. **Library basics**: keywords + IPTC/EXIF metadata read/write, color labels, Smart Collections, Collection Sets, Stacks, virtual copies/snapshots, metadata filter/search, standard XMP sidecar interop (ours is proprietary `.photoapp.json`).
5. **Export / import upgrades**: metadata + watermark, color space/bit depth, output sharpening, naming templates, export presets, HEIC/AVIF/DNG; import rename/copy/apply-preset, tethering, watched folders.
6. **Multi-photo**: HDR merge, Panorama merge, focus stacking, granular Sync Settings dialog, Survey/Reference view.
7. **Culling / faces**: Assisted Culling, duplicate detection, face detection + People view (R: Faces panel with Eye Focus / Eyes Open scores, June 2026).
8. **Persist edit history** across sessions (ours is in-memory), Smart Previews (offline editing), folder move/rename inside the app, Soft Proofing, Print/Slideshow/Map (low value for this app).
9. **Phase 8 polish** (tiled rendering, perf) and the open items below (start with D28).

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


## Working agreements
1. One item per session, smallest viable slice, Plan Mode first (CLAUDE.md).
2. Performance items: measure before and after on a real large photo/library; record numbers in PROGRESS.md.
3. Verify each item's claims against the code before acting.
4. When an item ships: strike it, move its full text to `docs/IMPROVEMENTS_HISTORY.md`, leave a one-line index entry here, update PROGRESS.md.
