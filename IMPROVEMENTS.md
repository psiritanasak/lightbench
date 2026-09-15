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
  `AdjustTabView` hand-rolls WB/Red-Eye/mask-selection/brush-paint/
  color-pick mutual exclusion at 5 separate sites (`select(_:)`, the WB
  button, the Red-Eye button, `beginBrushStroke`, `beginColorPick`) —
  each one individually clearing the other four's armed state. A fifth
  copy of the same pattern is the point where a `enum EditorInteractionMode
  { case none, pickingWhiteBalance, placingRedEye, editingMask(UUID),
  paintingBrush(UUID), pickingColorRange(UUID) }` (one piece of state
  instead of five booleans/optionals that must always agree) would
  measurably simplify this file — a real refactor, not a rename, so
  scoped as its own future session rather than folded into this one.
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

### D15. Combine-masks (intersect/subtract) v1 scope cuts (Phase 7 slice 6, Session A) — deferred, not forgotten

Session A shipped the data model (`Mask.combineMode`/`combineWithMaskID`,
`MaskCombineMode`) and the `EditPipeline.applyMasks` combine block
(intersect via `CIMinimumCompositing`, subtract via `CIMinimumCompositing`
against a Porter-Duff-inverted operand) with no UI at all — reachable only
via a hand-authored sidecar until Session B. Known v1 scope cuts, each
already named at its own load-bearing doc comment rather than silently
assumed:

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
- **No on-image indication of the clipped/combined shape.** Session B's
  planned overlay work (see `~/.claude/plans/merry-questing-gizmo.md`) covers the mode/
  target pickers in `MaskDetailView`, not a visual outline of the
  resulting intersected/subtracted region on the canvas itself — a user
  has to infer the combined shape from the rendered adjustment, the same
  way `.luminanceRange`/`.colorRange` already have no on-image shape
  outline of their own selection either.
- **No reference scrubbing on delete.** Deleting a mask does not clear
  other masks' `combineWithMaskID` pointing at it — left dangling on
  purpose (see `Mask.combineWithMaskID`'s own doc comment): fail-open
  renders a dangling reference as `.none`, so this is harmless by design,
  not an oversight, and Undo restores the relationship for free.
- **`Mask.id`'s own decode is still bare-`try`, not `try?`.** Unrelated to
  this slice's own two new fields (both correctly `try?`, see their decode
  site's own comments) but noted here since combine references are the
  first place a MALFORMED `id`-shaped value (not just a missing one)
  would actually matter end-to-end (a hand-edited `combineWithMaskID`
  pointing at a syntactically-invalid UUID already degrades safely via
  `try?`, but a malformed `id` on the mask itself does not) — a candidate
  for a future small session, not touched here.

Session B will additionally need the `LibraryFilter`-style coercing
`Binding` fix for the combine-target picker (an `Optional<UUID>`-shaped
`Picker` selection can silently make a "None" row unselectable once a
real target is chosen, the same class of bug that one already fixed) —
tracked in the slice's own plan file, not re-logged here as a separate item.

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
