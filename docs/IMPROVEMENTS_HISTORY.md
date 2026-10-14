# Improvements History

Full text of every shipped/retired entry moved out of `IMPROVEMENTS.md` on 2026-09-30 (original IDs and wording preserved; cross-references elsewhere still resolve by ID). `IMPROVEMENTS.md` keeps only open items plus a one-line index of these.

Central caution carried over from the original preamble: re-reading code is not verification of a runtime claim (P1 was 'confirmed' by two analytical passes and disproved by measurement). Measure before implementing.

---

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

### D14. No keyboard/AT path to pick a Color Range mask's target color (Phase 7 slice 5, second half) — SHIPPED 2026-09-25

**Update (2026-09-25): the Color Range eyedropper's own keyboard/AT path
is now shipped**, closing this entry's own long-open half (Point Color's
side was closed back in Slice B, 2026-09-18 — see the update below).
Exactly the "mostly a routing change" this entry's own text predicted:
`isPickingColorRange` was added to `handleImagePaneKeyPress`'s
point-placement arm-check, `handlePointPlacementKeyPress`'s `.escape`
case and `commitPointPlacement`'s if/else-if chain both gained a
`colorPickingMaskID` branch, `EditorCrosshairOverlay` gained a 4th
(green) tint, and the mouse tap-capture layer now syncs
`crosshairPosition` too (the same D4-class staleness bug WB's own path
already guards against). One small piece of genuinely NEW logic, not
just routing: `handleMaskKeyPress`'s own bespoke `isPickingColorRange`
Escape branch (this mode's original, pre-D14 two-stage Escape, built
entirely inside mask-key handling since it had no point-placement
dispatch to join) became dead code once the point-placement dispatch
started intercepting Escape first, and was removed rather than left as
unreachable cruft. Reviewer: 3 rounds, FIX FIRST → FIX FIRST → APPROVE —
round 1 found no logic bugs at all, only stale doc comments elsewhere in
the codebase this change made false (`PointColorDetailView`/
`MaskDetailView`/two `ContentView` comments all still described Color
Range as mouse-only or Point Color as the only kind with keyboard
support) — fixed; round 2 caught two more of the SAME class in this very
entry (the paragraph below still described the eyedropper as
present-tense mouse-only, pointing readers at a `MaskDetailView` comment
that by then said the opposite) — fixed by putting the original text in
the past tense, see the note directly below it.
1329 tests pass unchanged (no new automated tests — this is `ContentView`
UI-glue code with no existing test precedent, matching D8/Point Color
Slice B's own "verified live, not unit-tested" convention).

**Update (2026-09-28): the shared `EditorInteractionMode` mode-enum
follow-up below is now SHIPPED**, closing the armed-mode half of this
entry's own longstanding follow-up. `Sources/UI/EditorInteractionMode.swift`
is one enum (`.none`/`.pickingWhiteBalance`/`.placingRedEye`/
`.paintingBrush(maskID:)`/`.pickingColorRange(maskID:)`/
`.pickingPointColor(pointColorID:)`) replacing the 5 separate properties
(2 bools + 3 `UUID?`s) the 6 arm sites below used to keep mutually
exclusive by hand. `ContentView`'s old properties survive as read-only
computed projections under their original names, so every READ site
(`canZoom`, the overlay gates, `.onChange` handlers, the crosshair tint
switch) is unchanged; only the write sites converted, each to either
`interactionMode = .none` (only where the old code cleared all 5, or a
guard in scope proves nothing else could be armed) or a targeted
`interactionMode.disarm(_:)`/`disarmMaskModes()`/`disarmPointColorPick()`
otherwise — a deliberate rule to avoid the type's own central hazard: a
blanket `.none` inside a handler meant to clear only ONE mode would
silently disarm whatever else is armed. 2 commits (the enum + its tests,
then the `ContentView`/`AdjustTabView` wiring), each independently
reviewed (`model: "opus"`) — APPROVE on both, no correctness issues found
in the wiring commit (traced every guarded/one-shot disarm site for
behavioral equivalence, confirmed no old writes remained, ran the full
suite independently). 1355 tests, no existing test changed — this is a
pure UI-state refactor with no user-visible change.

Deliberately does NOT fold in mask/point-color SELECTION
(`AdjustPanelState.selectedMaskID`/`selectedPointColorID`), despite this
entry's own original sketch including an `editingMask(UUID)` case —
selection survives tab switches and legitimately coexists with an armed
mode today (brush painting always has its mask selected; arming Point
Color does not clear a selected radial mask). The separately-noted
3-way selection-half inconsistency below is UNCHANGED by this shipment —
it was never part of the armed-mode state this enum covers, and remains
open.

**Live-verified (2026-09-28)**, alongside this entry's own 2026-09-25
Color Range keyboard/AT path update above (neither had been live-verified
on screen until now), against a scratch synthetic JPEG and a real Release
build. Directly exercised the type's own documented central hazard — WB
armed while a mask was selected stayed armed through the
`disarmMaskModes()` call its own deselection triggers — plus Point
Color → WB (unpicked instance discarded, WB wins), Brush → Escape
(discarded when never painted) and Brush → Color Range (unpainted brush
discarded in the same coalesced action that arms Color Range), Color
Range's own single-Escape discard-when-unpicked, and Red-Eye
toggle-off + a WB arm/Crop-tab/Adjust-tab round trip (WB correctly
cleared by the tab switch). No regressions found; see `PROGRESS.md`'s own
entry for the full scenario-by-scenario write-up, including one
automation-only gotcha (`BrushMaskOverlayView`'s
`DragGesture(minimumDistance: 0)` turns even a zero-movement synthetic
click into a real stroke point) worth remembering for the next
live-verification session in this area.

**Update (Point Color Slice B, 2026-09-18):** the routing this entry
describes was built, but for Point Color's OWN eyedropper, not this
one — Point Color's picker is wired into the exact crosshair machinery
named below (`isPickingPointColor` alongside `isPickingWhiteBalance`/
`isPlacingRedEyeCorrections`, cyan `EditorCrosshairOverlay` tint,
`ImageDocumentModel.pickPointColorTarget` from `commitPointPlacement`),
confirming this entry's own "mostly a routing change" prediction. The
Color Range mask eyedropper this entry is actually about was still
mouse-only at that point — see the 2026-09-25 update above for the rest.

*(Original text below, as of Phase 7 slice 5 — describes the state BEFORE
the 2026-09-25 update above; the gap it describes is now closed, and
`MaskDetailView`'s own class doc comment now says so rather than the
opposite.)*

`ColorRange` mask's Tolerance/Feather were labeled, AT-adjustable
`EditSliderRow`s exactly like `.luminanceRange`'s own params — but
PICKING the color itself (`ContentView.pointAndZoomOverlays`'s new
tap-capture branch) was a bare `SpatialTapGesture` with no keyboard/AT
path at all, the same category of gap D8 closed for the WB eyedropper
and Red-Eye placement.

Unlike D11 (`.brush`'s stroke shape — no slider equivalent, no obvious
keyboard generalization), this was a CHEAP future win: D8's
crosshair-nudge machinery (`ContentView.crosshairPosition`/
`handlePointPlacementKeyPress`/`commitPointPlacement`/
`EditorCrosshairOverlay`) already existed and already handled exactly
this shape (arrow keys move a normalized-position crosshair, Return
commits, Escape disarms) — wiring a third "mode" into that existing
dispatch (alongside `isPickingWhiteBalance`/`isPlacingRedEyeCorrections`)
was mostly a routing change, confirmed by the 2026-09-25 update above.

**Two smaller follow-ups noted while building this slice, neither
built:**
- **A shared mutual-exclusion mode enum — SHIPPED 2026-09-28.** See the
  2026-09-28 update at the top of this entry for the full write-up.
  `EditorInteractionMode` covers exactly the PICKING-armed half described
  below (WB/Red-Eye/brush-paint/color-pick/point-color-pick); it
  deliberately does NOT fold in `editingMask(UUID)` the way this bullet's
  original sketch proposed — see that update for why.

  *(Original text below, describing the state BEFORE the 2026-09-28
  update — the armed-mode half it describes is now closed.)*

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
  not a separate one. **STILL OPEN as of 2026-09-28**: the shipped enum
  deliberately excludes selection, so this three-way inconsistency is
  unchanged by that shipment.
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

### D23. Transform Scale/Stretch has no minification prefiltering (reviewer-caught) — SHIPPED 2026-09-29

**Update: fixed, with a real measurement, not just the fix.**
`applyTransformScale`'s middle step now runs through
`CIFilter.lanczosScaleTransform()` instead of a raw
`CGAffineTransform(scaleX:y:)` — the SAME translate-to-origin/translate-
back sandwich as before wraps it (a throwaway probe script, run and
deleted, confirmed the filter scales about the absolute origin `(0,0)`
exactly like the raw affine did, so the sandwich itself needed no
change), and everything after (`.cropped(to:)` then
`.composited(over:)` the transparent canvas) is untouched. The filter's
own `scale`/`aspectRatio` parameters were verified empirically (same
probe) to give `outputWidth = inputWidth * scale * aspectRatio`,
`outputHeight = inputHeight * scale` — so this function's own
independently-derived `sx`/`sy` map onto them as `scale = sy`,
`aspectRatio = sx / sy`, for any `sx`/`sy`, not just this function's own
specific formula.

**Self-caught, pre-review, test-suite-measured deviations**: Lanczos's
wider sampling kernel measurably shifted 2 existing hard-alpha
assertions right at the shrunk-content boundary
(`testTransformScaleBelowOneExposesTransparentMargin`: `1.0000012`
instead of exactly `1.0`; `testTransformScaleClearsPerspectiveWedges`:
`0.99999994` instead of `1.0`). First characterized as "floating-point
kernel-weight summation noise... not a real correctness regression" and
fixed by loosening both to `accuracy:` — **review pass 1 (below) found
this explanation was INCOMPLETE**: the first of the two was actually the
SAME ringing/overshoot mechanism that pass identifies as a real bug, not
mere noise, and is now fixed at the SOURCE (see that section's own
write-up) — re-measured afterward as reading back EXACTLY `1.0` again,
so that assertion is back to exact equality, not `accuracy:`. Only the
SECOND assertion's own residual (mutation-tested: still fails even with
that fix in place, since it's already below 1.0 and an upper clamp can't
pull a value UP) is genuine sub-1.0 floating-point summation noise,
correctly still using `accuracy:` (the file's own existing `0.002`
constant).

**A real, measured aliasing comparison** (temporary harness in
`EditPipelineTests.swift`, run once, transcribed here, then fully
reverted — `git diff` confirmed clean, matching the D16/D17 convention
for this exact file): a fine 3px-period black/white stripe pattern
(chosen to alias under the documented ~3.2x worst-case minification),
rendered through BOTH the OLD plain-affine mechanism (reproduced
standalone in the harness, not by reverting production code) and the
NEW Lanczos one at `transformScale: 0.5, transformAspect: 1`, sampling
an 80-pixel row well inside the shrunk content's own span (away from
the transparent-margin edge entirely). Measured standard deviation
across that row, as an honest proxy for "how much of the fine stripe
pattern survived as visible banding rather than blending into a smooth
average":

    old (plain affine):  stddev 0.2513
    new (Lanczos):        stddev 0.1188

**Roughly HALVED (~2.1x lower), a real and meaningful reduction — but
not a complete elimination.** The raw sampled rows show why: the OLD
row swings across nearly the FULL black-to-white range (0.16 to 0.96),
while the NEW row is compressed toward mid-gray (0.55 to 0.88) but still
shows a repeating pattern, not a flat blend. Reported at the confidence
this one data point supports: prefiltering is a genuine, measured
improvement at this specific severe combination (3.2x minification, a
3px period near the limit of what any reasonable resample could fully
resolve), not a complete fix for arbitrarily fine content — which
matches ordinary expectations for ANY prefilter (a wider blur/sinc
kernel reduces but cannot perfectly eliminate aliasing at frequencies
right at the resample's own limit). Not measured at gentler,
more-realistic minification levels (e.g. near the "common case" this
entry itself already named as low-risk) — the harness was scoped to the
documented worst case specifically, per the plan's own "measure the
worst case, not the average case" framing.

**Reviewer-caught (review pass 1): the ringing was a real correctness bug,
not just a test-assertion nuisance.** `CILanczosScaleTransform`'s windowed-
sinc kernel has negative side lobes — at a hard alpha/color edge (the
transparent-margin boundary this stage's own shrink creates, or any hard
edge in the source content) it genuinely RINGS, not just rounds. This
first surfaced as the self-caught (pre-reviewer) "floating-point noise"
characterization above, which was wrong for one of the two shifted
assertions.

**The real figure needed reconciling TWICE before it stabilized** — 3
earlier drafts of it disagreed with each other (the `EditPipeline.swift`
doc comment's own first draft said 1.064/-0.057, PROGRESS.md said
1.196/-0.072, and an independent reviewer probe said 1.093/-0.062, none
naming the same fixture/sweep), and a first reconciliation attempt (a
single unified
"1.0864/-0.0739" figure, from a sparse per-pixel-call scan) ALSO didn't
reproduce once re-checked with a dense, every-pixel scan — the real
figure depends on the hard edge's own sub-pixel phase relative to the
resample grid, which shifts with fixture size, so there is no single
fixed number. The figure below is the final, dense-scan reconciliation
(`EditPipelineTests.testD23DenseRingingReconciliation`, a temporary
harness swept over the 4 worst-case `(scale, aspect)` corners of the
clamped range on 2 hard-edge fixtures — a solid opaque square isolating
the ALPHA edge, a pure color step edge isolating COLOR ringing — at 3
fixture sizes, run once, transcribed here, then deleted), reported as a
RANGE, not one number:

    WITHOUT the clamp: alpha overshoot 1.06-1.10, color undershoot
    roughly -0.06 to -0.063, color overshoot 1.09-1.12 (all across
    64/100/200px fixtures)

Alpha above 1 breaks `over` compositing math and corrupts export
clamping differently than the live preview; negative linear color feeds
directly into every downstream perceptual stage (Dehaze/Vignette/
Clarity/NR/Sharpen/Grain).

**Fix**: `CIFilter.colorClamp()` immediately after the Lanczos filter,
BEFORE the translate-back/crop/composite. My first attempt clamped both
bounds on color (`minComponents`/`maxComponents` both `(0,0,0,0)`/
`(1,1,1,1)`) — self-caught immediately via `testTransformScalePreservesHighlightHeadroom`
failing: this stage is explicitly required to preserve linear-light
values above 1.0 (highlight headroom), so a full `[0,1]` clamp on color
silently destroys that. Corrected to an ASYMMETRIC clamp: `minComponents
= (0,0,0,0)`, `maxComponents = (1e6,1e6,1e6,1)` — both bounds on alpha
(`[0,1]`, since alpha above 1 breaks compositing either direction, though
only the UPPER bound is ever actually exercised on these fixtures —
negative alpha never appeared, so the lower bound is defensive, not
proven necessary by measurement), only the LOWER bound on color (no
negative linear light, upper bound left open so headroom survives).
With the clamp applied, alpha reads back EXACTLY 1.0 and color's lower
bound reads back EXACTLY 0.0 in every case tried. A residual IS left ON
PURPOSE: the bright-side overshoot on color (not alpha) can still read
up to a CONSTANT ~1.06 after the clamp (vs. 1.09-1.12 pre-clamp) at a
hard 1.0/0.0 edge — a faint Lanczos halo on SDR content, the accepted
tradeoff for preserving headroom, not a bug. The post-clamp figure being
LOWER than the pre-clamp color overshoot has a real, verified mechanism:
`CIColorClamp` operates on UNPREMULTIPLIED values (divide by alpha,
clamp, multiply back), so clamping alpha down to 1 also removes the
portion of color's own overshoot that was riding on alpha's overshoot —
what's left is only the color channel's own genuine ringing.

Also caught and fixed: `lanczos.outputImage ?? centered` silently
skipped scaling entirely if the filter ever returned `nil` — changed to
`?? plainAffineFallback`, a raw affine scale built from the same `sx`/
`sy`, so the fallback reproduces the PRE-fix mechanism rather than a
no-op; and a stale doc comment left over from before the mechanism
change, still describing it as "combined into ONE `CGAffineTransform`".

**New permanent regression** (there was none before review pass 1 — the
only thing that caught the clamp's removal was an incidental 1.2e-6
alpha overshoot at one interior pixel of
`testTransformScaleBelowOneExposesTransparentMargin`, fragile, and
color undershoot had no guard at all):
`testTransformScaleClampBoundsRingingAtHardEdges`, asserting the clamp's
own bounds (alpha `[0,1]`, color's lower bound at 0) hold across the 4
worst-case corners on both hard-edge fixtures, run through the real
`EditPipeline.apply` — a DENSE full-frame scan (via a new
`renderFullFrame` helper, no pixel skipped; an earlier strided-sampling
draft only ever grazed a -0.0002-magnitude color residual, nowhere near
the real undershoot, and was barely exercising the guard at all), plus
an explicit non-vacuousness check: the identical corners/fixtures run
through `rawTransformScaleNoClamp` (the pre-clamp reference geometry,
kept PERMANENTLY as a test helper, not deleted as a "temporary" harness)
must show a real violation SOMEWHERE across the 4-corner sweep —
aggregated, not asserted per-corner, since one individual corner
(`(1.5, 1)`) alone only reaches about -0.0054, well under a strict
per-corner threshold, even though the worst corner in the same sweep
reaches roughly -0.06; a per-corner assertion would be a false negative
on the milder corners. Mutation-tested: a blanket `[0,1]` clamp breaks
`testTransformScalePreservesHighlightHeadroom` as expected; removing the
clamp entirely breaks this new test, reproducing violations in the
ranges documented above.

**Performance, re-measured honestly.** The FIRST performance pass (this
entry's own original, pre-review numbers — superseded below, kept in
PROGRESS.md's own history for the record, not deleted) had no warm-up
before timing and used a lazy solid-color fixture — reviewer-caught as
implausible (it reported full-res as FASTER than proxy-scale, a
~9x-larger render). Re-measured with a proper fix: an untimed warm-up
render per variant per size before timing (Metal/kernel first-compile
cost, not image size, was almost certainly what the old numbers actually
captured), a random-noise bitmap fixture (not a lazy solid color Core
Image can special-case), and an average of 5 timed renders each via a
forced `createCGImage` call (temporary harness, run once, transcribed,
then deleted):

    proxy (2000x1333):    old 1.38ms, new 1.31ms (0.94x — NOT slower)
    full-res (6016x4016): old 4.72ms, new 4.64ms (0.98x — NOT slower)

On this Metal-backed `CIContext` (Apple M1), the Lanczos + colorClamp
path is NOT measurably slower than the old plain affine at either size
— both are comfortably within noise of each other. This supersedes and
corrects the earlier (flawed) "1.58x slower at proxy scale" claim
entirely; there is no proxy-scale performance regression to weigh
against the aliasing improvement.

**Non-destructive-invariant note (pass 4)**: swapping the resample
mechanism changes how any ALREADY-SAVED edit with `transformScale != 1`
or `transformAspect != 0` renders — slightly softer at minification, plus
the accepted ~1.06 color halo at a hard highlight edge that didn't exist
under the old plain-affine resample. This is the same class of change
CLAUDE.md already records for `kMaxTransformAspectStretch`'s own live
retune (2026-09-21): intended, not a bug, and not replay-identical for a
photo whose sidecar already used this stage — worth knowing so a visual
difference on an old edit isn't mistaken for a regression.

1359 tests (2 assertions updated with a measured, documented reason,
1 new permanent regression test; all temporary measurement harnesses —
the initial sparse ringing probe, the corrective dense re-scan, and both
performance passes — were run once each and fully reverted, matching
this file's own convention). Reviewer: 4 passes, FIX FIRST × 3 →
APPROVE — pass 1 caught the ringing bug, the fallback bug, the stale
doc comment, and the missing regression test (fixed in this entry's
first half above); pass 2 caught that pass 1's OWN reconciled
1.0864/-0.0739 figure didn't reproduce under a dense re-scan, plus the
new regression test's own color check being fragile (fixed in this
entry's second half above); pass 3 caught that the dense-scan figure
still hadn't replaced the stale 1.0864/-0.0739 numbers in THIS entry's
own text, a self-contradictory "corrected to the range above" pointing
at no such range, inconsistent round/pass labeling across files (this
entry now uses "review pass N" consistently instead of an overloaded
"round"), a wrong doc-comment constant value, an unaggregated per-pixel
assertion loop, and a missing non-vacuousness check on alpha's own upper
bound (all fixed in `EditPipeline.swift`/`EditPipelineTests.swift`);
pass 4 independently re-verified every pass-3 fix (including its own
mutation tests of the new alpha non-vacuousness check and a fresh
geometry-shift probe of its own, finding no new correctness bugs) and
found only 3 residual doc nits — 2 more stray "round N" labels, and a
factual mismatch in `applyTransformScale`'s own doc comment about
exactly which prior measurement the dense re-scan found irreproducible
(it named the wrong one, the original 3-way-disagreeing figures rather
than the intermediate "1.0864/-0.0739" reconciliation attempt that
actually failed) — plus this non-destructive-invariant note being
missing entirely. All 4 fixed; APPROVE.

*(Original entry below, describing the gap before this update.)*

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

### D25. `ImageAverageColor`/`PixelSampler` read `CIContext.render`'s premultiplied output as if it were straight (reviewer-caught, Auto Tone planning session) — FIXED 2026-09-29

Found while building `ImageToneStatistics` (Auto Tone's own statistics
sampler, `Sources/Rendering/ImageToneStatistics.swift`): `CIContext.
render(_:toBitmap:...)` returns PREMULTIPLIED RGBA, and a resample's edge
row/column commonly lands at a fractional alpha (still passing a
`>= 0.5` qualifying guard) whose RGB has therefore been scaled down by
that alpha. `ImageToneStatistics` now divides by alpha before use (see
its own doc comment for the measured before/after numbers) — `Sources/
Rendering/ImageAverageColor.swift`'s `compute(of:)` (the gray-world mean
behind Fix Color Cast) and `Sources/Rendering/PixelSampler.swift`'s
`averageColor(in:at:radius:minAlpha:)` (the WB eyedropper's box sample)
read the same premultiplied buffer without un-premultiplying first, and
shared the identical latent bug.

**Fixed**: both now divide R/G/B by alpha (after the existing alpha
threshold guard, before any downstream use — in `ImageAverageColor`
specifically before the luma exclusion gate, so that gate also sees the
corrected value) — the same pattern `ImageToneStatistics` already
established. One new bitmap-backed test per file
(`testPremultipliedAlphaDoesNotBiasTheAverage`/
`testPremultipliedAlphaDoesNotBiasTheSample`), since every existing
fixture in both files was a `CIImage(color:).cropped(to:)` constant
generator — Core Image can fold those through rendering without ever
exercising a real premultiply/unpremultiply round trip, so none of them
could have caught this bug (the same gap `ImageToneStatisticsTests
.bitmapGrayImage`'s own doc comment already documents for its sibling
sampler). The new `bitmapColorImage` helper takes the INTENDED STRAIGHT
color/alpha but stores PREMULTIPLIED bytes — verified empirically during
implementation, not assumed: an initial attempt storing straight values
directly produced doubled output, because `CIImage(bitmapData:...)`
round-trips its raw buffer through `render(_:toBitmap:...)` UNCHANGED,
with no premultiply/unpremultiply conversion of its own, so only
premultiplied input actually reproduces a real premultiplied-source
scenario. Both fixes mutation-tested (reverting each, confirming its own
new test fails, reproducing the halved premultiplied values). 1361 tests
(2 new).

This also retroactively closes a narrower, previously-accepted gap in
`ImageDocumentModel.pickColorRangeTarget`'s own doc comment (a
semi-transparent Color Range tap recording a luminance target
`ColorRange.cikernel`'s own unpremultiplied math could never exactly
match) — that doc comment is now updated to point here instead of
describing the gap as open.

Reviewer (Opus, color-math change): FIX FIRST → APPROVE. Round 1 caught
a stale doc comment in `ImageDocumentModel.pickColorRangeTarget` that
this same fix had made false (it described the premultiplied-read gap as
an accepted, unfixed limitation needing a future return-type change —
now fixed, so rewritten to say so) and a defensive hardening gap: no
current caller passes `PixelSampler.averageColor`'s `minAlpha` below its
0.5 default, but the parameter is public, and `minAlpha <= 0` would let
`a == 0` through the guard into the new division, producing a NaN that
could reach `WhiteBalanceSolver` or a persisted Color Range/Point Color
target and silently fail every later sidecar write — fixed with an
`a > 0` guard ahead of the existing threshold check.

### D33. Ghost selection IDs make Export/Add-to-Collection UI silently misleading (reviewer-caught while correcting a stale nit, 2026-09-29) — SHIPPED 2026-09-29

**Update: fixed, after a reviewer-caught regression in the first attempt.**
The first draft made BOTH sites — the menu's own outer visibility gate
AND `exportButtonTitle` — key off `ContentView.selectedPhotosVisibleInGrid`
(a thin forward to `CatalogModel.selectedPhotos`, the ghost-filtered
accessor). Reviewer-caught: the menu's own "Clear Selection" button
(`catalog.clearSelection()`'s ONLY call site anywhere in this app) lives
INSIDE that menu — gating the whole menu on the filtered set hid the one
way to clear a selection the moment every selected id became a ghost,
trapping the user (switching Collection/Folder still clears it via
`selectedFilter`'s own `didSet`, but that's not always where the user
wants to go). Fixed: the menu's own outer gate stays on the RAW
`catalog.selectedPhotoIDs`, matching `photosToExport`'s own guard exactly
— only the label's COUNT inside the menu (already correct, unchanged by
either draft) and `exportButtonTitle`'s count (once something IS
selected) use the ghost-filtered accessor. `exportButtonTitle` itself
also needed the same "raw set decides IF, filtered set decides the
NUMBER" split — the first draft's fully-filtered version could show a
plain "Export…" (which reads as "will export everything," normally
enabled) on a `.disabled` button for an all-ghost selection, with no
visible reason why; it now shows "Export Selected (0)…" instead, honestly
reflecting the disabled state.

A second reviewer-caught issue in the first draft: its own write-up here
claimed `CatalogModel.selectedPhotos` "already has its own test
coverage" — false, nothing under `Tests/` called it at the time. Fixed
both the claim and the gap: `CatalogModelTests.
testSelectedPhotosExcludesAGhostID` now pins the exact accessor both
`ContentView` sites depend on, reusing the identical ghost-selection setup
`testAddSelectedPhotosExcludesAPhotoNoLongerVisibleInTheGrid` (right above
it) already established. 1358 tests (1 new).

*(Original finding below, describing the gap before this update.)*

Found while investigating whether `CatalogModel.selectedPhotoIDs` not
being pruned in `refresh()` was a real gap (it isn't — see PROGRESS.md's
"Open reviewer issues" for the full story: this is a deliberate design,
pinned by `CatalogModelTests.
testAddSelectedPhotosExcludesAPhotoNoLongerVisibleInTheGrid`, and the 3
actual consumers — `addSelectedPhotos`, `relocateSelectedPhotos`,
`selectedPhotos` — all correctly intersect against `photos` before acting).

But 2 UI sites read the RAW, unintersected `catalog.selectedPhotoIDs`
directly, not through one of those safe consumers:
- `ContentView.exportButtonTitle` (`Sources/UI/ContentView.swift`, ~1406)
  shows `"Export Selected (\(catalog.selectedPhotoIDs.count))…"` — if
  every ID in the selection has since become a ghost (toggled out of the
  currently-viewed collection, same mechanism the pinned test exercises),
  the button shows a nonzero count with nothing actually checked in the
  grid. The button itself stays SAFE (`.disabled(photosToExport.isEmpty
  || …)`, line ~1349, and `photosToExport`, lines ~41-42, correctly
  filters ghosts out via `catalog.isSelected($0)`, leaving it empty) — so
  it's disabled, not clickable-but-silently-empty. The actual gap is
  narrower than "exports nothing": a misleading nonzero count on a
  DISABLED button, with no fallback to "export the current filtered set"
  the way a genuinely-empty selection gets.
- The "Add to Collection" toolbar menu's own gate (`ContentView.swift`,
  ~1352) is `if !catalog.selectedPhotoIDs.isEmpty` — same raw check, so
  the menu can appear with nothing visibly checked in the grid.

Narrow: only reachable via the exact "toggle a photo out of the
currently-viewed collection while it's selected, don't touch the grid
selection again" sequence the pinned test itself constructs, not
ordinary use. Not fixed here (docs-only session); a real fix would
route both sites through the same `photos`-intersected count/check the 3
real consumers already use, rather than reading `selectedPhotoIDs` raw.

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

### D34. `xcodebuild test` ran migrations against the user's REAL catalog (found 2026-09-30, Pick/Reject live check) — SHIPPED 2026-09-30

The unit-test bundle's host is the app itself; `CatalogModel.init()` opened
the on-disk catalog (`~/Library/Containers/com.photoapp.PhotoApp/Data/Library/
Application Support/PhotoApp/catalog.sqlite`) at launch, so running the test
suite applied any pending migration (007 there) to the developer's real
catalog before a backup could be taken. Harmless for Migration 007 (verified
against a Time Machine snapshot: 1094 photos / 0 flagged before and after),
but a destructive future migration would have run unattended.

**Fixed:** `CatalogDatabase.isRunningUnderXCTest` (OR of the three XCTest
environment markers — a missing marker fails OPEN, back to the real catalog)
and `catalogDirectoryURL`/`defaultCatalogDirectory`, which return a
per-process, never-deleted temp directory under XCTest and the unchanged
Application Support directory otherwise. `CatalogModel.init()` also skips
`activateKnownFolders()` under XCTest — reviewer-caught: it deletes
unresolvable bookmarks from the real `UserDefaults.standard`, so every test
run could prune the developer's real library-folder bookmarks. Mutation-
tested both ways (broken detection; broken branch): tests fail, and a
mutation run wrote a stray file into the real container once, which is why
the tests that write now skip unless the directory is provably under temp.

Still open, out of scope: Xcode Previews (`XCODE_RUNNING_FOR_PREVIEWS`) also
open the real catalog; Swift Testing and non-`xcodebuild` test plans were not
verified to set the markers.

### D37. A truncated JPEG/PNG exported or enhanced without any warning (Phase 8 audit, 2026-09-30) — SHIPPED 2026-09-30

`SourceIntegrity` (`Sources/Rendering/SourceIntegrity.swift`) now makes
`PhotoExporter.export` and `PhotoEnhancer.enhance` refuse a source whose JPEG
never reaches its EOI marker / PNG never reaches IEND (`incompleteSource`
errors; nothing written). Measured first: ImageIO's `CGImageSourceGetStatus`
says `complete` for every truncated JPEG/PNG/TIFF cut, so it could not be
used; a truncated TIFF already fails to decode. The Editor and thumbnails
deliberately still open a damaged photo. Validated read-only against the
developer's real 1094-photo library: 0 false refusals (95 JPEG + 49 PNG
complete; RAW/HEIC/TIFF left alone).

Known, accepted: a JPEG/PNG with COMPLETE pixel data but no final EOI/IEND is
also refused (indistinguishable from a cut without decoding every MCU) —
pinned by a test, absent from the real library. Not atomic with the decode
that follows. Other formats (HEIC/WebP/GIF/BMP/TIFF/RAW) are unchecked.


---

# Archived from IMPROVEMENTS.md on 2026-10-14

### D39. A collision suffix " (N)" can push a file name past 255 bytes (found reviewing Export naming, 2026-09-30) — FIXED in batch-rename commit 3 (`PhotoExporter.baseNameFitting`: trims whole characters off the base so `base + " (N)" + ext` fits; shared by Export and Enhance via `uniqueFileURL`)

`PhotoExporter.uniqueFileURL` (shared by Export and Enhance) appends " (2)", " (3)"…
to a base name that already passed the 255-byte check WITHOUT the suffix. A base within a few
bytes of the limit then produces a path `fileExists` can't resolve (ENAMETOOLONG reads as "no
such file"), the loop returns that candidate, and the write fails with a generic Cocoa error;
nothing is overwritten and the temp file is cleaned up, so it is safe but the message is poor.
Pre-existing (the old default naming had it too). Cleanest fix: trim the base to fit BEFORE adding
the suffix, in the one shared function.

---

# Archived from IMPROVEMENTS.md on 2026-10-14 (robustness session)

**Status (D13): FIXED 2026-10-14: `ImageDocumentModel.willSwitchPhoto` runs at the start of `load(from:)` (before the flush and the state swap) and `ContentView.discardUnfinishedPlaceholders` drops an armed unpainted Brush mask / unpicked Color Range mask / unpicked Point Color from the OUTGOING photo; covers every route that opens a photo. Not covered: entering the Library with a tool armed (unchanged).**

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

**Status (D28): CLOSED 2026-10-14: the (photo, edits, history) snapshot taken before the modal folder step (a8dd564) closes the hazard whether or not the interleave is reachable. Two cosmetic leftovers stay as nits: `pasteSettings` reads the live `currentURL` after its flush (its own path-match guard covers it) and a `.failed` result can show its error message while a different photo is open.**

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

**Status (D31): FIXED 2026-10-14 (narrower form): a thumbnail decode that returns nil probes the file (`FileReadability`); on a SANDBOX denial the folder's stored bookmark is re-resolved silently (never a panel), once per root per session, and the grid's thumbnail revisions are bumped. Correction to the entry's wording: `isPhotoConfirmedMissing` is not affected (it reports Missing only when the file is absent); stale access shows as "not missing" plus a thumbnail that never appears.**

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

**Status (D32): FIXED 2026-10-14: `FileReadability.classify/probe` separates a sandbox denial (open fails although the POSIX bits allow reading) from a plain chmod (bits forbid), a missing file and other failures; `ensureAccessActive` recovers only on `.sandboxDenied`, injectable via `CatalogModel.readabilityProbe`. LIMIT: a real sandbox denial could not be produced in the test host (it reads files outside its container), so the errno behaviour is by design/documentation; the verdict deliberately does not depend on EPERM vs EACCES.**

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

