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
shape. 2 rounds, FIX FIRST → APPROVE. 522 tests (3 new). NOT yet
live-verified by the user.

### D6. Accessibility pass over custom controls

Past reviews repeatedly caught accessibility nits (ThinSlider, Adjust
sections). Do one dedicated pass: `StarRatingRow` (needs a value +
adjustable action, not 5 unlabeled buttons), the selection checkbox
(state), `CompareDividerOverlay` (adjustable), crop handles. VoiceOver-walk
the Editor and Library once each.

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
