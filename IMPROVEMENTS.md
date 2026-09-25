# Improvement & Optimization Backlog — instructions for the implementing agent

Written 2026-08-28 after a read-through of the current codebase (all of
`Sources/`, not the diff). This is a REVIEW ARTIFACT, not a mandate: each item
below is a candidate. Before implementing anything, read `CLAUDE.md` (workflow
rules apply in full — Plan Mode per feature, ONE item per session, `reviewer`
agent on the diff before any commit) and `PROGRESS.md` (current state). Verify
every claim here against the current code first — line numbers drift.

**Verification status.** A second *analytical* pass on 2026-08-28 re-read every
claim against the source and pronounced them all confirmed. It was wrong about
P1, which a later *empirical* pass that same day disproved outright — see the
struck-through P1 below, and treat that as this file's central caution:
re-reading code is not verification of a runtime claim.

Still believed accurate (all structural, checkable by inspection): P3's
unchanged-state redraws (resize, zoom/pan, and Compare-divider drag all reach
`draw(in:)` with `image`/`editState` unchanged); P4's four-round-trip
`refresh()` per rating tap; P5's downsample genuinely sitting downstream of a
full-res `EditPipeline.apply` in BOTH `HistogramComputer` and
`ImageAverageColor`. None of those three has had its *impact* measured. P2 was
always stated as a hypothesis requiring measurement first.

**Relationship to PROGRESS.md's own "Exact next step" list:** P4 is the
concrete fix for its option (6) (overlapping `Task.detached` + `refresh()`
transiently showing stale data), and D5 restates its option (2) (Library
polish, remaining slices). Every other item here — P2, P3, P5, D1, D2, D3,
D6, D7 — is new and not on that list. Nothing here supersedes the user's
roadmap: Presets (Phase 5, shipped 2026-09-01) and Phase 6 slice 1 (RAW
decode, shipped 2026-09-02 — see PROGRESS.md) are both done; Phase 6 slice 2
(RAW-native controls) still outranks everything below until the user
either ships it or explicitly points elsewhere.

Do NOT jump the roadmap: Phase 6 slice 2 (RAW-native controls — exposure/
boost/lens correction/WB eyedropper/NR/sharpness as `EditState` fields, see
CLAUDE.md's roadmap item 6) remains the user's stated priority. Items here
are for sessions the user explicitly points at this file.

---

## Part 1 — Performance optimizations (priority order)

### ~~P1. ThumbnailCache serializes all decodes through the actor~~ — WRONG, RETIRED 2026-08-28

**This item was investigated and DISPROVED. Do not re-attempt it.** It is kept
here, struck through rather than deleted, so the theory doesn't get
independently rediscovered and re-argued from the same plausible reasoning.

The claim was that the decode's `Task { }` in `ThumbnailCache.thumbnail(for:)`,
created inside an actor-isolated method, inherits that isolation via
`@_inheritActorContext` and — having no suspension points — holds the actor's
serial executor for the whole decode, thereby (a) serializing all thumbnail
decoding and (b) stalling cache hits behind it. The argument is plausible, and
it survived a second analytical review pass. It is nonetheless false in
practice. MEASURED against the real code (see
`Tests/RenderingTests/ThumbnailCacheTests.swift`):

- 8 concurrent decodes vs the same 8 run sequentially: **ratio 0.32**, i.e.
  already ~3x parallel. Rewriting to `Task.detached` measured **0.32 as well
  — no change at all.** Reproduced across repeated full-suite runs at
  0.25–0.32.
- A cache HIT requested while 8 large decodes were in flight returned in
  **0.0 ms**, so the actor is demonstrably not held for the decode's duration
  either.

Both halves of the claim are therefore false, and `Task.detached` would be a
strict downgrade (it drops priority and task-local propagation) for zero
measured gain. The production code was left unchanged; what shipped from this
investigation was test coverage and a doc comment on `thumbnail(for:)`
recording the finding.

**Lesson for the remaining items in this file.** P1 was derived by reading the
code and reasoning about Swift's concurrency semantics, and it was wrong.
PROGRESS.md already records "verify the sign/direction/behavior empirically,
don't assume" as a pattern this project has hit six times; it applies to
performance claims too. Note that the remaining items differ in kind: P3, P4
and P5 assert *structural* facts (a graph is rebuilt, four DB round-trips are
issued, a downsample sits downstream of the pipeline) that are verifiable by
inspection and are true — but that a structural inefficiency is real does NOT
establish that fixing it is measurably faster. **Measure the impact before
implementing, not just after.**

### ~~P2. Full-resolution pipeline render on every interactive slider tick~~ — SHIPPED 2026-09-07

**Where:** `Sources/Rendering/ImageRenderer.swift` `draw(in:)` (line ~114) —
every `editState` change re-renders the FULL-RES image through the whole
pipeline, per frame, during a slider drag. On large photos (24–60MP) this is
what bounds slider smoothness, especially with convolution-backed stages
active (Sharpen, Noise Reduction, Definition — these prevent Core Image from
propagating the final fit-transform's downscale back through the graph, so
work really is done at source resolution).

**Fix (classic Lightroom-style proxy):** while an interactive gesture is in
progress, run the pipeline on a pre-downscaled input (e.g. Lanczos-scaled so
the long edge ≈ 2× the drawable's long edge), then render full-res once the
gesture settles (reuse the existing debounce idiom — the codebase already has
three: histogram 150ms, history 350ms, sidecar 1s). Pipeline geometry is
extent-relative, so a proxy is proportionally correct — the SAME argument
`ThumbnailGenerator.thumbnail(for:maxPixelSize:editState:)` already documents
and ships. Preview-vs-final will differ slightly for the resolution-dependent
stages (Sharpen's radius scales with min dimension by design); that is an
accepted preview tradeoff but MUST be documented in the code and mentioned to
the user.

**Measured (2026-09-04) — justified, proceeding.** Temporary
`CFAbsoluteTimeGetCurrent()` instrumentation (same tool as P3's own
measurement, no `os_signpost` exists in this codebase) timed the FULL
`draw(in:)` call end-to-end during an ACTUAL slider drag (Sharpen dragged
continuously) on a large photo with Sharpen+NR+Definition all active — a
different scenario from P3's static-redraw measurement, since P3's cache
does not help here (`editState` changes every frame during a drag, so
it's a cache miss every time). Result: frequently well above the 16ms/
60fps threshold (22.9ms, 40.2ms, 41.6ms, 19.3ms, 20.7ms, 40.7ms, 29.4ms,
...), with two severe outliers at **184.7ms and 279.0ms** — real,
observed stutters during interaction, not a theoretical concern. Proceeds
to its own Plan Mode session (per this file's own "one item per session"
rule) for the downscaled-proxy design below.

**Shipped and live-verified (2026-09-07).** Two Plan Mode design passes
before any code (session-default model, then an explicit Opus 5 critique
per this file's own "one item per session" discipline for the hottest
render path) caught a real units bug in the first draft: "headroom ≈2× the
drawable's long edge" was reasoned in POINTS against `MTKView.drawableSize`,
which is actually device PIXELS — at 2× this would have made the proxy
silently never engage on a Retina display. Corrected to **1.25 proxy
pixels per DRAWABLE pixel** (pixel-exact at fit zoom, no added softness).
Interaction is detected by COUNTING consecutive `editState` changes
(`ProxyInteraction`), not by timing between them — timing was proven
unsound in review: `draw(in:)` is synchronous, so slow frames (exactly the
184.7/279.0ms case above) inflate the measured gap between edits, making a
timing-based detector fail precisely when this feature is needed most. 4
commits, each reviewer-APPROVED (Opus 5): `ProxyScale`+`ProxyInteraction`
(pure geometry + detector), `ProxyBuilder` (async `CVPixelBuffer`
materializer mirroring `RawDecoder.materialize`), the `ImageRenderer`
wiring (two-check cache invalidation extending the existing P3 cache,
async generation-guarded build), then this live pass. Reviewer caught
several real bugs pre-commit, most seriously an unbounded concurrent-build
path that could spawn dozens of overlapping proxy builds during an
ordinary drag (fixed: at most one build in flight at a time) — see
PROGRESS.md's P2 section for the full list.

**Live-measured (2026-09-07), same instrumentation as the justification
above, reverted before this commit**: during a real continuous Sharpen
drag with Sharpen+NR+Definition all at 100% on a 24MP RAW (`.NEF`) photo,
proxied frames were **0.6-2ms** — the earlier 19-42ms typical / 184.7ms /
279.0ms outliers are gone while the proxy is engaged. The only remaining
slow frames (174.9ms, 203.5ms, 45.2ms) all occurred with the proxy NOT
engaged — full-res renders during idle/zoom moments or the settle frame
right after a burst, i.e. exactly the pre-existing cost those frames
always had. One caveat recorded, not chased further this slice: a single
~180ms hitch occurred on the one frame where a proxy REBUILD was
requested (not the first build) — likely GPU-level contention between the
interactive frame's own render and the concurrently-running background
build (separate `CIContext`s, same underlying device), even though the
build itself runs async and never blocks `draw(in:)` at the CPU/thread
level. Smaller than the original outliers and appears to be a rare,
one-time-per-rebuild event; worth another look if it recurs more severely
on a lower-end GPU or larger source. User confirmed live: the drag felt
smooth; undo/redo, typed-value entry, and applying a preset all rendered
sharp immediately with no soft flash, matching the "only sustained drags
engage the proxy" design. **A separate, pre-existing bug was found during
this pass in Compare Split + zoom (unrelated to this feature — ruled out
via the same instrumentation, which showed the proxy was NOT engaged for
any frame during the entire repro) — logged in PROGRESS.md as its own
future item, not fixed here.**

### ~~P3. `draw(in:)` rebuilds the pipeline graph on renders where nothing changed~~ — SHIPPED 2026-09-04

**Measured first, then fixed, matching P4's own precedent.** Before: a
resize/zoom/pan sequence on a large photo with Sharpen+Noise-Reduction+
Definition all active (the three stages that force full-resolution work)
showed per-frame `EditPipeline.apply` cost mostly in the 0.07-4.7ms range,
with real spikes up to **38.6ms and 458.9ms** — not a theoretical concern,
an actually-observed near-half-second stall on a redraw where nothing but
the fit transform changed. Temporary `CFAbsoluteTimeGetCurrent()` print
instrumentation (added, used, then fully reverted — confirmed via a clean
`git diff`) captured both the before and after numbers.

**Shipped**: a self-invalidating cache directly on `ImageRenderer`
(`cachedSourceImage`/`cachedEditState`/`cachedEdited`/`cachedOriginalState`/
`cachedOriginal`), re-checked at the top of every `draw(in:)` call, keyed
on `image` identity (`!==`) plus each output's own `EditState` value —
`EditPipeline.apply` is a pure `(EditState, CIImage) -> CIImage`, so that
pair is a complete, correct key. **Deliberately did NOT reuse
`MetalImageView.updateNSView`'s existing equality guard**, as originally
suggested here — investigation found two real problems with that approach:
it's one fused `||` across all five of ITS fields (doesn't distinguish
cache-invalidating changes from cache-preserving ones, and `compare` would
need decomposing into `originalState` vs. `mode`), and more importantly a
resize redraw (`ResizingMTKView.setFrameSize`) calls `setNeedsDisplay`
directly and reaches `draw(in:)` WITHOUT ever going through `updateNSView`
— a cache dependent on that method having run first would be stale on
every resize. The cache is fully self-contained inside `draw(in:)` instead.

After: the same resize/zoom/pan exercise measured ~0.002-0.008ms per
frame — just the cache-key comparison — with both large spikes completely
gone. A cache hit returns the EXACT SAME `CIImage` instance a miss would
freshly compute (not an approximation), so there is no possible visual
difference, only fewer redundant rebuilds — reviewer confirmed this
reasoning holds and traced the identity-key premise (`currentImage` is
only ever reassigned wholesale, never mutated in place) against the actual
write sites in `ImageDocumentModel.swift`, not just the doc comment's
claim. Reviewer APPROVE on the first pass, two non-blocking notes (a
retained-but-harmless stale `cachedOriginal` after Compare is toggled off;
a reminder that the cache key's correctness depends on `EditPipeline.apply`'s
signature staying exactly `(EditState, CIImage) -> CIImage`, already
documented at the cache's own declaration). No new automated tests —
`ImageRenderer`/`draw(in:)` has zero existing test precedent in this
codebase (Metal-coupled rendering glue); the existing 465 tests pass
unchanged. Full write-up in PROGRESS.md.

### ~~P4. `CatalogModel.refresh()` refetches the whole library on every rating/flag/membership tap~~ — SHIPPED 2026-08-28

Measured first, then fixed. The four queries `refresh()` issued cost **6.45 ms
per tap at 1,000 photos and 30.37 ms at 5,000** on an on-disk catalog, scaling
linearly, before the wholesale `photos` republish re-rendered the grid — so
unlike P1 this was a real performance problem as well as a correctness one.

The three tap mutators now update local state synchronously on `@MainActor` and
then write, instead of writing and re-reading the entire catalog. That also
fixes the documented Phase 4 slice 3 stale-rating bug (PROGRESS.md's deferred
option 6), since taps now land in tap order by construction. `CatalogModel`
gained an `init(database:)` testing seam and its first 7 tests, each verified to
fail against the old implementation. A narrower write-ordering window remains
and is recorded as a known limitation. Full write-up in PROGRESS.md.

### ~~P5. Histogram / average-color renders: verify the downsample position~~ — SHIPPED 2026-09-07

**Where:** `Sources/Rendering/Histogram.swift`, `ImageAverageColor.swift`,
called from `ImageDocumentModel.recomputeHistogram()` /`fixColorCast()`.
Both apply the FULL pipeline to the FULL-RES image first, then downsample
inside the computer. Same convolution caveat as P2: with Sharpen/NR/
Definition active, the "downsample happens at render so it's cheap" argument
breaks. Verify by measuring `recomputeHistogram` with those stages active on
a big photo; if slow, downscale the input BEFORE `EditPipeline.apply` (the
histogram is statistical — proxy input is unambiguously fine here, more so
than for P2's on-screen preview).

**Scope correction found while investigating**: the convolution caveat only
applies to `recomputeHistogram()`. `fixColorCast()`'s own sampling state
starts from a fresh `EditState()`, whose defaults (`sharpness`/`definition`/
`noiseReduction` all `0`) mean `EditPipeline` never activates a convolution
stage there regardless of resolution — structurally exempt, not measured
and found fast.

**Measured (2026-09-07) — justified, shipped.** Temporary
`CFAbsoluteTimeGetCurrent()` instrumentation around `recomputeHistogram()`'s
two lines: `EditPipeline.apply` (graph construction) was ~free, 0.0-5.7ms;
`HistogramComputer.histogram(of:)` (the actual render) ranged
**24.6-399.9ms** on a 24MP source with Sharpen/NR/Definition all active —
real, felt lag for what's meant to be live histogram feedback, not a
theoretical concern.

**Shipped**: a pre-pipeline downscale, sized against the DISPLAYED extent
(post-crop/straighten/perspective, via a cheap `EditPipeline.apply(...)
.extent.size` probe — not the raw source extent, which a reviewer caught
would size the headroom wrong on any cropped photo) via a new pure,
unit-tested `HistogramComputer.inputDownscale(forDisplayedSize:)`, matching
the `ProxyScale`/`AspectFit` convention. **Live-measured after**: a steady
**13-68ms** (one 220ms outlier on the apparent first call of the session,
not recurring). The one accepted, explicitly-not-measured divergence:
Noise Reduction is resolution-independent, so downscaling before it runs
changes the histogram's noise-driven tonal spread in an unasserted
direction whenever NR is active — accepted for this coarse, debounced
statistical display. Two reviewer rounds (Opus 5) — round 1 caught the
crop-sizing bug, an unmeasured NR-divergence-direction claim, a wrong
"aliasing doesn't matter" justification, a misattributed `RawDecoder`
precedent, and a resolution-independence test that could only ever pass
(a solid color trivially resamples to itself) — all fixed. 510 tests (5
new), 0 regressions.

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

## Part 2 — Design improvements (UX, then code design)

### ~~D1. Editor has no way to move between photos (biggest UX gap)~~ — (a) SHIPPED 2026-08-28, (b) SHIPPED 2026-08-28

Currently: edit one photo → toolbar back to Library → click the next photo.
Lightroom/Photos solve this with a filmstrip. Recommend, in ascending scope:
(a) ⌘←/⌘→ prev/next commands in the Editor stepping through
`catalog.displayedPhotos` order (respects current sort/filter — decide and
document whether filter applies), reusing the exact load path
`ContentView` already wires for Library → Editor opens (which flushes
sidecar saves correctly); (b) a collapsible bottom filmstrip reusing
`LibraryThumbnailCell`'s thumbnail fetch (cache is shared via `CatalogModel`,
so this is cheap). Do (a) first — one small session. Note: prev/next must
respect `ImageDocumentModel.load(from:)`'s existing flush-outgoing-sidecar
behavior — it already does this; don't build a parallel load path.

**(a) shipped 2026-08-28** as a `CommandMenu("Photo")` in `PhotoAppApp`, ⌘←/⌘→,
walking `displayedPhotos` (so it follows the grid's current sort/filter/search),
through the existing `load(from:)` exactly as instructed above. Decisions taken:
no wraparound, and both items disable when the open photo isn't in the displayed
set or while the Library is showing. New pure `LibraryNavigation` type in
`Sources/Catalog` with 10 tests; `currentURL` is now `@Published`; `showLibrary`
lifted to `PhotoAppApp`.

**(b) shipped 2026-08-28** as `Sources/UI/EditorFilmstripView.swift` — a
collapsible horizontal strip below the Editor's `HSplitView`, reusing
`CatalogModel.thumbnail(for:)` (the same cache `LibraryThumbnailCell`
uses, exactly as recommended above) and the exact same `load(from:)` call
(a) already uses, so the existing tab/crop-aspect/WB/red-eye/Compare/
zoom/pan reset applies to filmstrip taps for free. A real, unplanned
compiler-limits detour: adding one more toolbar button tipped the whole
`.toolbar { }` closure into "unable to type-check in reasonable time";
fixed by splitting it into five named `@ToolbarContentBuilder`
properties (root-caused to total statement count in one builder closure,
not any single expression's complexity — confirmed by testing that
extracting only the new button did NOT fix it). Reviewer APPROVE, one
non-blocking doc-comment fix (an overclaimed invalidation-scope
guarantee, corrected to state the honest reasoning — see PROGRESS.md).
No new tests, same precedent as Crop v2/Compare divider/D7. 374 tests
unchanged. NOT yet verified live — full detail in PROGRESS.md.

One measurement worth carrying to P6: the menu's enabled state re-derives
`displayedPhotos` on every Scene body pass, i.e. every slider tick.
`LibraryFilterSort.apply` costs **0.37 ms at 1,000 photos, 3.61 ms at 10,000,
18.50 ms at 50,000** (measured 2026-08-28). The commands resolve both
neighbours in ONE pass behind cheap disqualifiers, so the cost is paid once, but
this is the first thing to put real main-thread pressure on that computed
property.

### ~~D2. Library thumbnails don't scale with the grid~~ — SHIPPED 2026-08-31

`GridItem(.adaptive(minimum: 140))` lets columns grow, but cells hardcode
140×140 (`LibraryThumbnailCell`, load-bearing frame — read its long comment
first!). Wide windows get dead space per cell. Add a thumbnail-size slider
(Photos convention, bottom-right of the grid) driving ONE value used by both
the `GridItem` minimum and the cell frame. `ThumbnailCache.maxPixelSize` is
240 — sizes beyond ~240pt will look soft; either cap the slider or bump
`maxPixelSize` (cost: cache memory per entry grows quadratically — adjust
`totalCostLimit` reasoning in the same change).

**Shipped**: capped the slider at 100...240 (didn't bump `maxPixelSize` —
`ThumbnailCache` stayed completely untouched, avoiding both the quadratic
memory cost AND the cache's own documented instance-capture/parallel-decode
hazard). `@AppStorage`, not `@State` — `LibraryGridView` is torn down and
recreated on every Editor↔Library switch, which would otherwise silently
reset the slider. Reviewer APPROVE. Full write-up in PROGRESS.md.

### ~~D3. No indication in the Library of which photos have edits~~ — SHIPPED 2026-08-31

Lightroom shows a badge. The cheap version: a `FileManager.fileExists` check
on `ImageDocumentModel.sidecarURL(for:)` per cell (fast, but N stat calls per
grid render — do it inside the existing thumbnail `.task`, returning a
`(image, hasEdits)` pair, so it's amortized with the decode and cached).
Small overlay glyph (e.g. `slider.horizontal.3`) bottom-trailing on the cell.

**Shipped**: NOT as a `(image, hasEdits)` pair out of `ThumbnailCache` as
originally suggested here — that would have widened a return type shared
with `EditorFilmstripView`'s `FilmstripCell` and every `ThumbnailCacheTests`
call site. Instead the stat check rides along in `LibraryThumbnailCell`'s
own `.task`, via `async let` so it runs concurrent with (not serialized
behind) the decode. Reviewer's one non-blocking correction: `.task` actually
inherits the view's `@MainActor` isolation, so the stat does run on the main
actor (negligible for local volumes; revisit if network-volume libraries
are ever supported). Filmstrip deliberately untouched. Full write-up in
PROGRESS.md.

### D4. Library keyboard support

Everything in the grid is mouse-only. Already on PROGRESS.md's deferred list.
Add: 0–5 sets rating of the photo under selection focus, `.` or `f` toggles
flag, arrows move focus, Return opens in Editor. Requires introducing a
focused-photo concept (distinct from the export checkbox set — keep them
separate; Lightroom does). This is a real feature with design decisions —
Plan Mode, confirm scope with the user first.

**Shipped 2026-09-08, live-verified by the user 2026-09-09.** See
`PROGRESS.md`'s own D4 section for what shipped, what the reviewer
caught across 3 rounds, and the live verification (including why an
AX-driven automated pass couldn't fully confirm it — synthetic keyboard
events don't reach the app in this environment — and the manual check
that did).

### D5. Library management gaps — part 1 of 3 (remove photos from catalog) SHIPPED 2026-08-31

Three separate items, each its own session: rename/delete collections
(sidebar has no context menu at all today); remove photos from catalog;
detect files deleted on disk since import (show as missing rather than
broken thumbnails). `Migrations/` are append-only per CLAUDE.md; deletes
need FK-cascade thinking — collections already cascade (003), verify
photo-delete paths.

**Remove-from-catalog shipped 2026-08-31** as `CatalogDatabase.deletePhoto(id:)`
(the project's first live row-DELETE) + `CatalogModel.removePhoto(_:)`
(the first PERMANENT local-first mutator) + a destructive Menu item and
confirmation alert in `LibraryGridView.swift`. Catalog-only — the file on
disk is never touched, exactly as this entry's own wording anticipated by
listing missing-file detection as a separate concern. The `collection_photo`
cascade (003) was verified against GRDB's vendored source, not just
trusted, and is now the subject of a real passing test
(`testDeletePhotoCascadeDeletesCollectionMemberships`) — the first time it's
actually been exercised by a live DELETE since it shipped in Phase 4.
Reviewer APPROVE, two non-blocking notes (silent reappear on a DB-write
failure; removing the Editor's currently-open photo doesn't force-close
that session) — full write-up in PROGRESS.md. 380 tests (6 new). NOT yet
verified live. **Rename/delete collections and missing-file detection are
still open**, each still its own session.

**Rename/delete collections shipped 2026-09-08** as
`CatalogDatabase.renameCollection(id:to:)` (the project's first `UPDATE` on
any table other than `photo`) + `deleteCollection(id:)` (the first DELETE
on `collection`, relying on the already-shipped `ON DELETE CASCADE` for
membership cleanup) + a `.contextMenu` on flat "Collections" sidebar rows
(the codebase's first use of that modifier) — "Rename…" and a destructive
"Delete", mirroring the confirmation-alert shape "Remove from Library?"
already established. Deliberately excludes "Folders" rows (folder-tree
collections): deleting one would recursively delete its whole subtree, and
both rename and delete interact oddly with re-import (folder-tree import
matches by disk path, not name) — out of scope this slice, matching this
project's own prior exclusion when folder collections first shipped.
`CatalogModel.deleteCollection` also falls back `selectedFilter` to
`.allPhotos` when the deleted collection was the one being viewed.
Reviewer (Opus 5) caught a real race in the first draft — setting
`selectedFilter` synchronously before the delete write lands triggers its
own `didSet`-driven refresh, which could re-fetch the still-present row
and silently undo the local removal — fixed by deferring the filter reset
until the write is confirmed, then verified empirically (reviewer rebuilt
a scratch copy with the synchronous version reverted and confirmed the new
regression test fails against it). `isFolder` guards added to both new
`CatalogModel` methods as defense-in-depth beyond the UI-level scope
exclusion. 517 tests (7 new), live-verified by the user. **Missing-file
detection is still open**, its own session.

**Batch-add-to-collection shipped 2026-09-08** (feature request that came
directly out of live-testing rename/delete above, outside the original
3-part D5 scope): a new toolbar `Menu("Add to Collection")`, visible when
the Library grid's multi-select has 1+ photos checked, adds all of them to
a chosen collection in one action — previously one photo at a time via
each cell's own membership menu. `CatalogDatabase.addPhotos(_:toCollection:)`
is a new batched write (one `dbQueue.write` looping an
`insert(db, onConflict: .ignore)` per photo ID, mirroring
`importFolderTree`'s "one transaction, many rows" shape).
`CatalogModel.addSelectedPhotos(to:)` always ADDS, never toggles — a
mixed selection has no unambiguous toggle semantic. Reviewer (Opus 5)
caught two real bugs in the first draft: acting on raw `selectedPhotoIDs`
directly, which can contain a photo that silently vanished from the grid
(`toggleMembership` doesn't prune the selection when a photo is toggled
out of the collection being viewed) and would then get invisibly
re-added — fixed by intersecting the selection against `photos` first,
reusing `ContentView.photosToExport`'s existing pattern; and a
captured-before-the-write `affectsCurrentFilter` flag that could go stale
during a large batch if the user switches filters mid-write — fixed with
a new `refreshIfViewingCollection(_:)`, re-checking `selectedFilter` at
completion instead, mirroring `deleteCollection`'s own race-avoidance
shape. 2 rounds, FIX FIRST → APPROVE. 522 tests (3 new). **Live-verified
by the user** — the toolbar menu appears once photos are checked in the
Library grid and adding to a collection works as expected.

**Missing-file detection (D5's remaining 3rd part) shipped 2026-09-08**,
closing out D5 entirely. View-layer only, computed live per cell-appearance
— deliberately no DB migration/persisted `isMissing` column (a persisted
flag would need unsettled answers to "when is it re-verified, who clears
it," and would make a false positive permanent across relaunches instead
of scoped to one cell). `LibraryThumbnailCell` and `FilmstripCell` (the
Editor's own filmstrip — fixed too, since it shares the identical
"spins forever on a permanent decode failure" bug) now show a "Missing"
placeholder instead of an indefinite spinner once a thumbnail decode is
confirmed permanently failed. The core design risk: this app is fully
sandboxed, and a folder's security-scoped bookmark can fail to
(re-)activate SILENTLY — from the process's point of view, "file exists
but sandbox access isn't active" and "file genuinely deleted" are
indistinguishable, so a naive `fileExists` check would flag an entire
folder of present photos as missing the moment its bookmark has any
hiccup. Mitigated with a new `PhotoImporter.confirmedActiveFolderRoot(forPhotoAt:activeFolders:)`
(pure, unit-tested) gating on `CatalogModel.activeFolders`, plus a new
`CatalogModel.isPhotoConfirmedMissing(_:)` that ALSO reverifies the
matched root itself is still reachable (not just that it was activated at
some point) before trusting a negative result on the photo — both
filesystem checks run off the main actor via `Task.detached`, since the
one case they run is exactly the slow-filesystem path (a stalled network
mount or spun-down external drive). Reviewer (Opus 5): 2 rounds, FIX FIRST
→ APPROVE. Round 1 caught the real gap in the design — `activeFolders` is
insert-only and never pruned, so a root that WAS active but later became
unreachable (ejected volume, deleted/renamed import folder) would read as
"confirmed access" when it no longer holds, flagging that entire folder's
photos as missing; fixed by having the pure gate return the matched root
itself (not just a `Bool`) so the caller can reverify it. Also caught the
main-thread `stat` risk and a stale-`isMissing`-on-cell-reuse bug, both
fixed. Small non-blocking polish applied after APPROVE: fail-closed
operand order (checks the photo first, short-circuiting the extra root
stat in the common present-file case), and deterministic longest-prefix-match
when multiple active roots nest (was `Set.first`, undefined iteration
order). 530 tests (11 new). **Live-caught bug, fixed same session**: the
user's first test showed no placeholder at all — root cause was
`ThumbnailCache` serving an already-cached thumbnail forever with no
freshness check, so the missing-check (gated on decode failure) never
ran for any previously-viewed photo. Fixed by running the check
unconditionally on every cell appearance and letting it override a
cached thumbnail, not just a failed decode; 2 more reviewer rounds (FIX
FIRST → FIX FIRST → APPROVE) caught a dropped reset/cancellation guard
and a stale doc comment along the way. See PROGRESS.md for full detail,
including the confirmed (not a bug) scope boundary: detection happens on
a cell's next appearance, not via live filesystem monitoring.
**Live-verified by the user**: after navigating away and back, a
deleted file correctly shows "Missing" while sibling photos render
normally.

**Relocate missing photos (single + batch) shipped 2026-09-08**, a direct
follow-up requested right after live-verifying missing-file detection: a
new per-cell "Locate…" menu item (shown only when that cell's `isMissing`)
and a toolbar "Locate Selected…" batch action, both pointing the catalog
at a moved photo's new location instead of leaving it permanently
"Missing". New `CatalogDatabase.relocatePhotos(_:)` (one transaction,
many `(photoID, newPath)` pairs, skips — doesn't abort the batch on — a
destination already claimed by a DIFFERENT row, since that's a plausible
outcome of a batch move, unlike `addPhotos`' rare FK-violation precedent)
and `PhotoImporter.matchByFilename(_:in:)` (matches selected/single
missing photos to same-named files in one picked folder — filename only,
not content, flagged not solved).

Reviewer (Opus 5) caught the session's most significant sandbox bug so
far in the first draft: relocating via a single-FILE picker, then trying
to derive and grant security-scoped access to that file's PARENT folder,
is very likely a silent no-op under this app's sandbox entitlement —
Powerbox only grants a scope for the exact item picked, never its
parent, and every other folder-access grant in this app already picks a
folder directly for exactly this reason
(`ImageDocumentModel.requestFolderAccess`'s own doc comment documents
the same limitation). Fixed by making single-photo relocate use the same
folder-picker + filename-match approach as the batch flow (accepting the
same tradeoff: a renamed, not just moved, file won't be found). Two more
real bugs caught in the same round: a false "already catalogued
elsewhere" collision when relocating a photo back to its own current
path (the collision probe didn't exclude the photo's own row), and a
synchronous directory scan on the main actor (fixed with `Task.detached`,
matching `importFolder`'s existing discipline). 2 rounds, FIX FIRST →
APPROVE — round 2 reviewer independently reverted the collision-probe fix
in a scratch copy and confirmed the new regression test genuinely fails
without it. Known, documented (not solved) gaps: a relocate doesn't move
the photo's edit sidecar (surfaced in the result summary message instead)
or update folder-mirrored collection membership; and — inherited from
missing-file detection itself — a photo can only be located once it
reads as "Missing", which requires its ORIGINAL folder root to still
exist, so moving/renaming an entire containing folder (not just one file
out of an intact folder) isn't covered by this slice. 538 tests (10 new).
NOT yet live-verified by the user.

### D6. Accessibility pass over custom controls

Past reviews repeatedly caught accessibility nits (ThinSlider, Adjust
sections). Do one dedicated pass: `StarRatingRow` (needs a value +
adjustable action, not 5 unlabeled buttons), the selection checkbox
(state), `CompareDividerOverlay` (adjustable), crop handles. VoiceOver-walk
the Editor and Library once each.

**Shipped 2026-09-08.** See `PROGRESS.md`'s own D6 section for what
shipped, what the reviewer caught across 3 rounds, and the live AX-tree
verification results (via the real Accessibility API, not System Events —
see that section for why).

### D8. Keyboard/AT paths for the three mouse-only spatial overlays (deferred from D6)

D6's accessibility pass explicitly scoped these OUT as new interaction
design, not labeling — each is currently `.accessibilityHidden(true)`
with a doc comment naming this entry:
- WB eyedropper tap-to-pick (`ContentView.swift`'s WB tap-capture overlay)
- Red-Eye tap-to-place/tap-to-remove (`RedEyeOverlayView.swift`)
- Click-drag-to-pan and double-tap-to-reset-zoom (`PanOverlay.swift`)

Each needs its own interaction design (e.g. a keyboard-driven crosshair
for WB/red-eye placement, arrow-key panning, a dedicated reset-zoom
action) before it can get real accessibility support — there's no
existing "point on the image" AT-accessible pattern in this codebase to
extend, unlike the labeling-only fixes D6 itself shipped.

**Shipped and live-verified 2026-09-09.** See `PROGRESS.md`'s own D8
section for what shipped, what the reviewer caught across 2 rounds, and
the live confirmation that the parent-`TapGesture`-alongside-child-
spatial-gesture composition — the one thing neither review round could
confirm via static analysis or an empirical probe — caused no
regression.

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

### D14. No keyboard/AT path to pick a Color Range mask's target color (Phase 7 slice 5, second half)

**Update (Point Color Slice B, 2026-09-18):** the routing this entry
describes was built, but for Point Color's OWN eyedropper, not this
one — Point Color's picker is wired into the exact crosshair machinery
named below (`isPickingPointColor` alongside `isPickingWhiteBalance`/
`isPlacingRedEyeCorrections`, cyan `EditorCrosshairOverlay` tint,
`ImageDocumentModel.pickPointColorTarget` from `commitPointPlacement`),
confirming this entry's own "mostly a routing change" prediction. The
Color Range mask eyedropper this entry is actually about is still
mouse-only — not touched, still open below.

`ColorRange` mask's Tolerance/Feather are labeled, AT-adjustable
`EditSliderRow`s exactly like `.luminanceRange`'s own params — but
PICKING the color itself (`ContentView.pointAndZoomOverlays`'s new
tap-capture branch) is a bare `SpatialTapGesture` with no keyboard/AT
path at all, the same category of gap D8 closed for the WB eyedropper
and Red-Eye placement, and the same one `MaskDetailView`'s own class
doc comment now names explicitly for this kind.

Unlike D11 (`.brush`'s stroke shape — no slider equivalent, no obvious
keyboard generalization), this one is a CHEAP future win: D8's
crosshair-nudge machinery (`ContentView.crosshairPosition`/
`handlePointPlacementKeyPress`/`commitPointPlacement`/
`EditorCrosshairOverlay`) already exists and already handles exactly
this shape (arrow keys move a normalized-position crosshair, Return
commits, Escape disarms) — wiring a third "mode" into that existing
dispatch (alongside `isPickingWhiteBalance`/`isPlacingRedEyeCorrections`)
is mostly a routing change: extend `handleImagePaneKeyPress`'s mode
check, extend `commitPointPlacement` with an `isPickingColorRange`
branch calling `document.pickColorRangeTarget(maskID:normalizedX:normalizedY:)`,
draw `EditorCrosshairOverlay` while armed. Not built this slice —
logged as the next candidate D8-style follow-up, not forgotten.

**Two smaller follow-ups noted while building this slice, neither
built:**
- **A shared mutual-exclusion mode enum is now genuinely worth it.**
  `AdjustTabView`/`ContentView` hand-roll WB/Red-Eye/mask-selection/
  brush-paint/color-pick/point-color-pick mutual exclusion at 6 separate
  sites (`select(_:)`, the WB button, the Red-Eye button,
  `beginBrushStroke`, `beginColorPick`, `beginPointColorPick`) — each one
  individually clearing the other five's armed state (Point Color Slice
  B, 2026-09-18, added the 6th without building the enum, per this
  entry's own prediction). A sixth copy of the same pattern is the point
  where a `enum EditorInteractionMode { case none, pickingWhiteBalance,
  placingRedEye, editingMask(UUID), paintingBrush(UUID),
  pickingColorRange(UUID), pickingPointColor(UUID) }` (one piece of state
  instead of six booleans/optionals that must always agree) would
  measurably simplify this file — a real refactor, not a rename, so
  scoped as its own future session rather than folded into this one.
  Reviewer-caught (Point Color Slice B round 2, 2026-09-18): the
  DETAIL-PANEL SELECTION half of this same state (`selectedMaskID`/
  `selectedPointColorID`, distinct from the PICKING-armed half above) is
  now a three-valued mix across the 6 sites — WB/Red-Eye clear BOTH
  selections, mask `select(_:)` clears the point-color PICKING id but not
  its SELECTION, `selectPointColor` clears the mask's picking id
  (`colorPickingMaskID`) but not `selectedMaskID`. No functional
  consequence found (both are presentation-only, and Escape already
  routes mask-first then point-color, so a double-Escape is the worst
  case) — but it's the same underlying disease the enum above would cure,
  not a separate one.
- **`PixelSampler` doesn't unpremultiply, `PointColor.cikernel` does.**
  Reviewer-caught (Point Color Slice B round 2): for a sampled pixel with
  0.5 ≤ alpha < 1 (only reachable once geometry is non-identity and a
  transform reveals a partial-alpha edge — already inside that eyedropper's
  own documented "identity-geometry only" caveat), hue survives the
  mismatch but saturation and the `max(maxChannel,1)` headroom scale
  diverge from what the kernel actually sees. Pre-existing class, shared
  with the WB and Color Range eyedroppers (same gap, same root cause,
  never fixed there either) — noted for completeness, not a new hazard.
- **`SelectiveColor.cikernel`'s `rgb2hsl` has no negative-channel
  clamp.** `ColorRangeSelection.hueSaturation(forLinearRGB:_:_:)`
  (this slice) clamps negative channels to 0 before headroom-
  normalizing, an improvement over the older `SelectiveColor.cikernel`
  kernel it was modeled on, which normalizes headroom but never clamps
  negatives — a real, if narrow, gap (a pixel with a negative channel,
  e.g. from an aggressive prior color-matrix operation, could still
  misbehave in Selective Color's own HSL math the same way the
  positive-headroom bug once did). Not touched this slice — that file
  is already shipped and reviewed independently; fixing it is its own
  small future session, not a drive-by edit bundled into an unrelated
  feature.

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

### D20. Color Grading Slice B's wheel has no keyboard/AT path AND no numeric readout for 2 of its 3 axes (reviewer-caught, Slice B)

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

### D23. Transform Scale/Stretch has no minification prefiltering (reviewer-caught)

`EditPipeline.applyTransformScale` uses a plain `.transformed(by:)`
affine resample — no `CILanczosScaleTransform`-style prefiltering.
Straighten and Perspective never minify (rotation/taper only ever
moves content, never shrinks the sampling density below 1:1), so this
is the FIRST stage in the Transform/Distort group that can. At the
clamp extremes (`transformScale: 0.5, transformAspect: 1`, i.e. the
maximum simultaneous zoom-out plus maximum Stretch compression on one
axis) `sx = 0.3125` at the current `kMaxTransformAspectStretch = 0.6`
— a ~3.2x minification on that axis with no prefiltering, a real
aliasing risk on high-frequency content (fine texture, a brick wall,
moiré-prone fabric). UPDATE (2026-09-21): `kMaxTransformAspectStretch`
was live-tuned from `0.3` to `0.6` after live user feedback that
Stretch felt too weak at the original value — this WORSENED the worst
case from ~2.6x (`sx ≈ 0.385` at `0.3`) to ~3.2x, the opposite
direction from what this entry would want; worth weighing against the
prefiltering fix below sooner rather than later if Stretch gets tuned
stronger again.

Not fixed here: the common real-world case (Scale near 1.0, nudged up
just enough to clear a modest keystone wedge) is a mild zoom, not a
strong minify, so this was scoped as a documented limitation
(`EditPipeline.applyTransformScale`'s own doc comment) rather than
blocking v1. Worth a prefiltered resample (or at minimum measuring how
bad the aliasing actually looks at the clamp extremes on real photo
content) before this feature is considered fully polished.

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

### D25. `ImageAverageColor`/`PixelSampler` read `CIContext.render`'s premultiplied output as if it were straight (reviewer-caught, Auto Tone planning session)

Found while building `ImageToneStatistics` (Auto Tone's own statistics
sampler, `Sources/Rendering/ImageToneStatistics.swift`): `CIContext.
render(_:toBitmap:...)` returns PREMULTIPLIED RGBA, and a resample's edge
row/column commonly lands at a fractional alpha (still passing a
`>= 0.5` qualifying guard) whose RGB has therefore been scaled down by
that alpha. `ImageToneStatistics` now divides by alpha before use (see
its own doc comment for the measured before/after numbers) — `Sources/
Rendering/ImageAverageColor.swift:70-85` (the gray-world mean behind Fix
Color Cast) and `Sources/Rendering/PixelSampler.swift:50-59` (the WB
eyedropper's box sample) read the same premultiplied buffer without
un-premultiplying first, and share the identical latent bug.

Not fixed here — out of scope for the diff that found it, and likely
low real-world impact for both: `ImageAverageColor`'s own 0.05...0.95
luma exclusion band already throws out most near-edge/near-transparent
readings this would affect, and `PixelSampler`'s tiny 5x5 box sample is
rarely centered exactly on a resampled edge. Worth a real measurement
(the same "temporary harness, deleted" technique `ImageToneStatistics`'s
own fix used) before deciding whether either is worth fixing — a
plausible v1 read is "real but small," not "definitely fine."

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

### ~~D7. Code design: split ContentView.swift (1352 lines)~~ — SHIPPED 2026-08-28

It currently holds: tab state, crop/aspect logic, zoom/pan gesture math
call-throughs, compare config, export progress HUD, the whole Adjust tab
(6 sections), the Crop tab, and 3 private reusable views. Extract along
existing seams, behavior-preserving, no logic changes: `AdjustTabView`,
`CropTabView`, `EditorChromeViews` (HUD/progress), keeping `ContentView` as
the coordinator. Do this BEFORE any of D1–D4 lands if possible — every one
of those touches ContentView, and the file is already at the size where
merge pain and accidental coupling start. Pure-refactor sessions still get
a reviewer pass per CLAUDE.md (it verifies behavior-preservation).

**Shipped 2026-08-28** exactly as described, as a pure move: `ContentView.swift`
1352 -> 766 lines, with `AdjustTabView` (482), `CropTabView` (88),
`EditorChromeViews` (54) and `EditControlRows` (48) alongside it in
`Sources/UI/` (note: this item said `Sources/App/`, which was wrong -- the file
has always been under `Sources/UI/`). The one non-obvious constraint found while
doing it: the Adjust tab's eight presentation states (6 section-expansion bools,
`histogramDisplayMode`, `selectedSelectiveColorBand`) CANNOT become the child's
own `@State`, because `editControls` picks the tab body with a `switch` and the
subtree is destroyed on each switch to Crop. They are grouped into
`AdjustPanelState` but still owned by `ContentView`. Build clean, 364 tests
passing, reviewer APPROVE (with one non-blocking note: one struct binding
instead of eight coarsens SwiftUI invalidation granularity -- no observable
behavior change at this panel's scale).

---

## Working agreements for whichever agent implements

1. One item per session, smallest viable slice, Plan Mode first (CLAUDE.md).
2. For every performance item: MEASURE before and after (os_signpost or
   simple timing), on a real large photo / real library, and record numbers
   in PROGRESS.md. No speculative optimization lands without a number.
3. P1 is retired (disproved), P4/P3/P2/P5 have all shipped, D7, D1 (both
   halves), D2, D3, D5 part 1 have all shipped. Of what remains, D4/D5
   (remaining 2 parts)/D6 need their own Plan Mode scoping, and P6 needs
   its own measurement first. Note P4, P3, P2, and P5 are the four items
   so far whose measurement DID justify the fix; P1's did not. Measure,
   don't assume.
4. D7 (split ContentView) and D1 (⌘←/⌘→ + the filmstrip) were the best
   first sessions and are now both done — see their own struck-through
   entries above for what shipped.
5. Verify each item's factual claims against the code before acting — this
   file describes the code as of 2026-08-28.
6. Update PROGRESS.md when an item ships; strike it through here.
