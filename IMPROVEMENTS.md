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

### P2. Full-resolution pipeline render on every interactive slider tick

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

**Measure first:** instrument `draw(in:)` (os_signpost) with a large photo and
Sharpen+NR+Definition active. If frame time is already <16ms at full res on
real photos, skip this item entirely — it adds real complexity.

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

### P5. Histogram / average-color renders: verify the downsample position

**Where:** `Sources/Rendering/Histogram.swift`, `ImageAverageColor.swift`,
called from `ImageDocumentModel.recomputeHistogram()` /`fixColorCast()`.
Both apply the FULL pipeline to the FULL-RES image first, then downsample
inside the computer. Same convolution caveat as P2: with Sharpen/NR/
Definition active, the "downsample happens at render so it's cheap" argument
breaks. Verify by measuring `recomputeHistogram` with those stages active on
a big photo; if slow, downscale the input BEFORE `EditPipeline.apply` (the
histogram is statistical — proxy input is unambiguously fine here, more so
than for P2's on-screen preview).

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
3. P1 is retired (disproved), P4 has shipped, D7, D1 (both halves), D2, D3,
   D5 part 1, and now P3 have all shipped. Of what remains, D4/D5(remaining
   2 parts)/D6 need their own Plan Mode scoping. P2 is the biggest
   potential win but the most complex — its own measurement (a genuinely
   different scenario: cost during an ACTIVE slider drag, not a
   static-content redraw like P3's) is the required next step before any
   P2 code, since P3's cache does NOT help P2's scenario (editState
   changes every frame during a drag, so it's a cache miss every time).
   Note P4 and P3 are the two items so far whose measurement DID justify
   the fix; P1's did not. Measure, don't assume.
4. D7 (split ContentView) and D1 (⌘←/⌘→ + the filmstrip) were the best
   first sessions and are now both done — see their own struck-through
   entries above for what shipped.
5. Verify each item's factual claims against the code before acting — this
   file describes the code as of 2026-08-28.
6. Update PROGRESS.md when an item ships; strike it through here.
