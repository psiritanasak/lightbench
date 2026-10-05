import AppKit
import CoreImage
import UniformTypeIdentifiers

/// Owns the currently displayed image state. Only ever reads image files —
/// never writes to originals, preserving the app's non-destructive invariant.
@MainActor
final class ImageDocumentModel: ObservableObject {
    @Published private(set) var currentImage: CIImage?
    /// True while `load(from:)` is awaiting a RAW photo's one-time
    /// `RawDecoder.materialize` (see that function's own doc comment) —
    /// distinct from the pre-existing, private `isLoadingPhoto` below,
    /// which only guards against a spurious sidecar autosave and was never
    /// UI-facing. Drives a loading indicator in the Editor so the async
    /// gap reads as "working," not as a second freeze.
    @Published private(set) var isLoadingImage = false
    @Published private(set) var currentFileName: String?
    /// The full URL of the currently-open photo. Originally kept purely so a
    /// sidecar path could be derived from it (before sidecar persistence,
    /// `load(from:)` never retained anything beyond the bare filename
    /// string), and therefore NOT `@Published`. It is now published, because
    /// the Photo menu's ⌘←/⌘→ commands locate this photo in
    /// `CatalogModel.displayedPhotos` by its path, and their enabled state has
    /// to track it — the same reason `canUndo`/`canRedo` are published for the
    /// Edit menu. Writes stay internal; `load(from:)` is the only one.
    @Published private(set) var currentURL: URL?
    /// Whether `currentURL`'s file EXIF orientation was CONFIRMED `.up` at
    /// load time (`RawDecoder.confirmedOrientation`) — always `false` for
    /// non-RAW photos and for a RAW photo whose orientation is non-`.up`
    /// OR unreadable (deliberately NOT defaulting an unreadable read to
    /// `true` — see `RawDecoder.confirmedOrientation`'s own doc comment).
    /// Cached here, rather than re-read at tap time, so
    /// `pickWhiteBalance`'s RAW-native fast-path eligibility check is a
    /// free synchronous read with no redundant main-actor file I/O —
    /// reviewer-caught: an earlier draft re-opened the file synchronously
    /// at tap time, reintroducing a defect class (`decode(contentsOf:)`'s
    /// own doc comment records this exact function being caught ungated
    /// on the main actor once before) this cache avoids entirely. Not
    /// `@Published` — nothing in the UI displays it.
    private(set) var currentRawOrientationIsUp = false
    /// Which RAW-native NR/Sharpness/Contrast/Detail/Moiré-Reduction
    /// adjustments `CIRAWFilter` actually supports for `currentURL` (see
    /// `RawDecoder.confirmedAdjustmentSupport`'s own doc comment) —
    /// `.unsupported` for non-RAW photos. `@Published`, unlike
    /// `currentRawOrientationIsUp` above: `AdjustTabView` reads this
    /// directly to disable each of the six gated RAW rows individually,
    /// so SwiftUI needs to observe it. Cached at load time for the same
    /// reason as `currentRawOrientationIsUp` — constructing a
    /// `CIRAWFilter` to read these flags must go through `RenderGate`,
    /// not be re-done synchronously per UI update.
    @Published private(set) var currentRawAdjustmentSupport = RawDecoder.RawAdjustmentSupport.unsupported
    @Published var loadErrorMessage: String?
    /// User-facing feedback when saving a sidecar fails (folder-bookmark
    /// resolution or the write itself) — mirrors `whiteBalanceSampleMessage`'s
    /// alert-binding pattern. NOT set when the user simply declines a
    /// folder-access prompt — that's an ordinary, silent choice, not an
    /// error condition.
    @Published var sidecarSaveErrorMessage: String?
    /// Fired after a REAL, successful sidecar write (not on a decline/skip/
    /// error) — lets `ContentView` bridge this otherwise fully-decoupled
    /// model to `CatalogModel`, so the Library grid's thumbnail cache can
    /// be invalidated for the edited photo. A plain closure, not a direct
    /// reference to `CatalogModel`, keeps these two sibling models (both
    /// owned by `PhotoAppApp`, with no existing relationship to each
    /// other) decoupled — `ContentView` does the wiring, same as it
    /// already bridges the opposite direction (Library selection →
    /// `document.load(from:)`).
    var onSidecarSaved: ((URL) -> Void)?
    @Published var editState = EditState() {
        didSet {
            scheduleHistogramUpdate()
            // Skip re-recording a write WE made while applying an undo/redo
            // (`applyHistoryState`) — otherwise undoing would immediately
            // re-commit the very state it just restored.
            if !isApplyingHistoryChange { recordEditChange() }
            // Skip scheduling a save for the write `load(from:)` itself
            // makes to apply a restored (or identity) state — auto-save
            // must stay LAZY: opening/viewing a photo should never trigger
            // a folder-access prompt on its own, only a REAL subsequent
            // edit should. Undo/redo/revert writes are NOT guarded here —
            // those represent real, intentional state changes and should
            // still get saved.
            if !isLoadingPhoto { scheduleSidecarSave() }
            // Phase 6 slice 2: RAW-native fields configure `CIRAWFilter`
            // itself, not `EditPipeline`, so they only take effect by
            // re-decoding the file — see `EditState.requiresRawRedecode`'s
            // doc comment. `isLoadingPhoto` excludes `load(from:)`'s own
            // restore-from-sidecar write, which is ALREADY decoded with
            // the correct value (see `load(from:)` above) and would
            // otherwise fire a redundant second decode whenever the
            // incoming photo's RAW-native fields differ from the outgoing
            // photo's. Undo/redo/revert/preset writes are NOT excluded —
            // those are real changes and must re-decode, same reasoning
            // as `scheduleSidecarSave` just above.
            if !isLoadingPhoto, editState.requiresRawRedecode(comparedTo: oldValue) {
                scheduleRawRedecode()
            }
        }
    }

    /// Whether an undo/redo step is available — mirrors `EditHistory`'s own
    /// `canUndo`/`canRedo` as `@Published` properties, since SwiftUI can't
    /// observe mutation of a plain (non-`ObservableObject`) struct property;
    /// refreshed after every history operation. Drives the toolbar buttons'
    /// enabled state.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Mirrors `EditHistory`'s own `entries`/`currentIndex` as `@Published`
    /// properties, for the History panel (`AdjustTabView`'s "History"
    /// section) — same reasoning as `canUndo`/`canRedo` just above: SwiftUI
    /// can't observe mutation of a plain struct property, so every history
    /// operation republishes a fresh copy here too. Refreshed in the same
    /// place `canUndo`/`canRedo` are, `refreshHistoryState()`.
    @Published private(set) var historyEntries: [HistoryEntry] = []
    @Published private(set) var currentHistoryIndex = 0

    /// Live Levels histogram — luminance plus per-channel R/G/B, each
    /// `HistogramComputer.binCount` values normalized 0...1. Empty (`.empty`)
    /// until the first debounced recompute finishes (or if no image is
    /// loaded). See `recomputeHistogram()` for what state it actually
    /// reflects.
    @Published private(set) var histogramData = HistogramData.empty

    /// User-facing feedback for a WB eyedropper tap that couldn't fully do
    /// its job (too dark to sample, or a cast too strong to fully correct)
    /// — mirrors `loadErrorMessage`'s alert-binding pattern.
    @Published var whiteBalanceSampleMessage: String?
    /// Shown by its own alert (not `whiteBalanceSampleMessage`'s "Color Sample" one) — `selectSubject` outcomes.
    @Published var subjectMaskMessage: String?
    /// True while a Vision subject pass is running (disables the Subject buttons: single-flight).
    @Published private(set) var isSelectingSubject = false

    private var histogramWorkItem: DispatchWorkItem?
    /// Guards against an out-of-order background histogram result (an OLDER
    /// in-flight computation finishing after a NEWER one) overwriting fresher
    /// data — `DispatchWorkItem.cancel()` (used for the debounce below)
    /// reliably stops a not-yet-started item, but `Task` cancellation is only
    /// cooperative and `EditPipeline.apply`/`HistogramComputer` don't check
    /// for it, so a simple monotonic generation counter is the correct
    /// "only the latest result wins" mechanism here, not task cancellation.
    private var histogramGeneration = 0

    /// Guards a whole-image statistical analysis's background result
    /// (`fixColorCast`/`autoTone`) against landing on a DIFFERENT photo than
    /// the one it analyzed — bumped once per successful photo switch, in
    /// `resetHistory()` (the one place already documented as "undo history
    /// is per-photo too"; this token is the same idea applied to an
    /// in-flight analysis instead of undo state). Deliberately NOT
    /// `loadGeneration`: that one is also bumped by a RAW-native re-decode
    /// (`redecodeForRawNativeChange`), which must NOT invalidate an
    /// in-flight tone/cast analysis of the same photo — see that function's
    /// own doc comment for why it shares `loadGeneration` with `load(from:)`
    /// for a DIFFERENT reason (both write `currentImage`) that doesn't apply
    /// here.
    private var analysisGeneration = 0

    // MARK: - Undo/Redo state

    private var history = EditHistory()
    /// Whose history `history` is (the photo it was reset/restored for) — so a save can never embed one photo's history in
    /// ANOTHER photo's sidecar (the one window where they differ: `load(from:)` between `currentURL = url` and the reset).
    private var historyURL: URL?
    /// Caches each history entry's encoded form across saves (see `HistoryArchive.Encoder`).
    private var historyEncoder = HistoryArchive.Encoder()

    /// Set while `applyHistoryState` is assigning `editState` as the result
    /// of an undo/redo — makes the resulting `didSet` skip re-recording
    /// (which would otherwise immediately re-commit the state undo/redo just
    /// restored), while still letting `scheduleHistogramUpdate()` run
    /// unconditionally (the histogram must update on undo/redo too).
    private var isApplyingHistoryChange = false

    /// How long a pause in `editState` changes must last before the
    /// in-progress burst is considered "settled" and committed as one undo
    /// step. A slider or crop drag fires many writes per second; without
    /// this, every intermediate value would become its own undo step. A UX
    /// "feel" constant, not a measured filter value — tuned by feel, not a
    /// probe.
    private static let historyCoalesceInterval: TimeInterval = 0.35

    private var historyCommitWorkItem: DispatchWorkItem?
    /// Whether a burst of `editState` changes is currently in progress
    /// (waiting out the coalesce interval before committing). The actual
    /// "before" value doesn't need to be captured separately — `history`'s
    /// own `current` already IS the last settled/committed value, so
    /// `finalizePendingCommit` just commits the current `editState` on top
    /// of it once the burst settles.
    private var isBurstPending = false

    func openImage() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .heic, .rawImage]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        await load(from: url)
    }

    /// Bumped at the start of every `load(from:)` call; each call captures
    /// its own value and re-checks it after every `await` before touching
    /// any `@Published` state. Reviewer-caught real bug: `load(from:)`
    /// becoming `async` (see below) means a SLOWER-finishing RAW load and a
    /// FASTER-finishing later load (rapid Library/filmstrip taps, or
    /// Cmd-Left/Right pressed again during a RAW photo's materialize) can
    /// resume out of order — without this guard, the slower one would
    /// resume AFTER the faster one already committed and silently stomp
    /// `currentImage`/`currentURL`/`editState` with its own (now stale)
    /// data. Concretely: open RAW A (suspends mid-decode) → open JPEG B
    /// (completes immediately, no suspension) → user edits B → A resumes
    /// and overwrites everything with A's data, discarding B's in-memory
    /// edits with no error and no trace — a real non-destructive-editing
    /// integrity bug, not a cosmetic one. Every guard below is a "this
    /// load has been superseded, abandon it silently" check, not an error
    /// path.
    private var loadGeneration = 0

    /// True from the top of `load(from:)` until the load that still owns
    /// `loadGeneration` finishes. Distinct from `isLoadingImage` (UI-facing,
    /// only covers the RAW materialize step) and `isLoadingPhoto` (only
    /// brackets one `editState` assignment). Exists so a debounced
    /// RAW-native re-decode (Phase 6 slice 2 — see
    /// `redecodeForRawNativeChange`) can't fire mid-photo-switch: the
    /// Adjust sidebar stays interactive while a photo loads (only the
    /// image pane shows the spinner), so the user CAN drag the Boost
    /// Amount slider while a different photo is still loading. Without
    /// this guard, the debounced re-decode would fire against the
    /// OUTGOING photo's now-stale `currentURL` and, worse, bump
    /// `loadGeneration` out from under the still-in-flight `load(from:)`
    /// — which then silently abandons itself via its own generation
    /// guard, so the tapped photo would simply never open.
    ///
    /// `@Published`, not plain `private`, since Reviewer-caught: a batch
    /// settings-paste (`PasteSettingsModel`) needs to know a load is
    /// in-flight too, for exactly the same reason `redecodeForRawNativeChange`
    /// does — `currentURL` still points at the OUTGOING photo for the
    /// whole span this flag covers, so a paste confirmed during that
    /// window would see the incoming target as an ordinary batch target
    /// (not the special-cased "this is the open photo" one), write its
    /// sidecar directly, and then have `load(from:)`'s own completion
    /// silently overwrite the Editor's in-memory state with the
    /// PRE-paste data moments later — the exact non-destructive-editing
    /// integrity hazard this property's own doc comment already
    /// describes for a different caller. `ContentView` disables
    /// requesting a paste while this is true, which narrows the window
    /// but is only one of several layers `PasteSettingsModel.performPaste`
    /// needs — see that method's own doc comment for the complete story
    /// (this alone does not close it: a load can still start AFTER a
    /// paste is requested, while its confirmation dialog is open).
    @Published private(set) var isLoadInFlight = false

    func load(from url: URL) async {
        loadGeneration += 1
        let myGeneration = loadGeneration
        isLoadInFlight = true
        defer {
            // Only the load that still OWNS the generation token clears
            // this — a superseded load must not clear it out from under
            // the newer one that superseded it.
            if myGeneration == loadGeneration { isLoadInFlight = false }
        }
        // Unconditionally cleared for EVERY new load, not just RAW ones —
        // otherwise a superseded RAW load's `isLoadingImage = true` (below)
        // could be left stuck on forever if the load that supersedes it is
        // non-RAW and never touches this flag itself.
        isLoadingImage = false
        // A pending RAW-native re-decode (Phase 6 slice 2) is now aimed at
        // whatever photo ends up open after THIS load — cancel it rather
        // than let it fire against the wrong file, or redundantly, once
        // `editState` below is restored from the incoming photo's own
        // sidecar.
        rawRedecodeWorkItem?.cancel()

        // Phase 6 slice 2: both of these MOVED above the decode, and must
        // stay in this order relative to each other.
        // - The flush runs FIRST, so re-opening the CURRENTLY-OPEN photo
        //   (a filmstrip tap on itself, or a ⌘←/⌘→ round-trip) reads back
        //   its own just-written edits rather than a sidecar still ~1s
        //   stale — reading the sidecar before the flush would silently
        //   discard that pending edit.
        // - The sidecar read runs SECOND, because `RawDecoder.decode`
        //   below now needs the INCOMING photo's own RAW-native fields to
        //   configure `CIRAWFilter` (those fields only take effect at
        //   decode time — see `EditState.boostAmount`'s own doc comment).
        //   Reading it at the OLD position (after the decode, near the
        //   bottom of this function) would decode every newly-opened RAW
        //   photo with the OUTGOING photo's RAW-native fields — a real
        //   bug, not hypothetical: nothing downstream would ever correct
        //   it, so the panel and the pixels would silently disagree until
        //   the user manually nudged a slider.
        // Moving the flush earlier is safe on its own terms: it only ever
        // saves the OUTGOING photo (`currentURL` is untouched until
        // below), it's a no-op unless a save is actually pending, and it
        // now also runs when the decode subsequently fails — strictly
        // better than dropping the outgoing photo's pending edits on a
        // bad file.
        flushPendingSidecarSave()
        // `var`, not `let` — Phase 6 slice 7's decoder-version pin (below)
        // mutates this in place before it's committed to `editState` at
        // the bottom of this function.
        let existingSidecarState = loadSidecarIfReachable(for: url)
        // The photo's persisted edit history (sidecar `_history`), if any and still consistent with its edits. Read OFF the
        // main thread (decoding re-serialises every entry — hundreds of ms with a big mask).
        let persistedHistory = existingSidecarState == nil ? nil : await loadPersistedHistory(for: url)
        var restoredState = existingSidecarState ?? EditState()
        // Set below only when this load backfills a decoder-version pin
        // into a photo that ALREADY had a sidecar on disk — see the
        // pin-capture block's own comment for why that specific case
        // needs an immediate, explicit save rather than waiting on the
        // normal `editState` `didSet` → `scheduleSidecarSave()` path.
        var shouldPersistBackfilledDecoderPin = false

        // `await`ed even for non-RAW (which has no internal suspension
        // point) because Swift requires one signature — see `RawDecoder.decode`'s
        // own doc comment for why the RAW branch needs to be gated all the
        // way through construction, not just `materialize`'s render step.
        guard let raw = await RawDecoder.decode(contentsOf: url, editState: restoredState) else {
            guard myGeneration == loadGeneration else { return }
            loadErrorMessage = "Couldn't open \"\(url.lastPathComponent)\". The file may be missing, unreadable, or not a supported image format."
            return
        }
        guard myGeneration == loadGeneration else { return }
        // RAW only: `RawDecoder.materialize` renders the RAW demosaic ONCE
        // here rather than leaving `raw` as CIRAWFilter's own lazy graph —
        // `ImageRenderer.draw(in:)` re-runs `EditPipeline.apply` on
        // `currentImage` on every redraw (every slider tweak), and without
        // this, that meant re-running the ENTIRE full-resolution RAW
        // demosaic from scratch on every single one, synchronously, on the
        // main thread — a real, live-caught freeze on a 24MP NEF. This
        // still costs one bounded, one-time pause here at load time (unlike
        // thumbnails/export, which each render exactly once and don't need
        // this), but no longer repeats per interaction. Non-RAW skips this:
        // `CIImage(contentsOf:)`'s own re-decode is already cheap to
        // re-run, so paying materialize's own cost would be pure overhead.
        //
        // `await`ed rather than run synchronously on the main actor — a
        // SECOND live-caught freeze (this one an apparent deadlock inside
        // Apple's private RawCamera framework, not just a slow render — see
        // `RawDecoder.RenderGate`'s doc comment) happened when this ran
        // synchronously here WHILE the Library grid was concurrently
        // decoding RAW thumbnails in the background. `RawDecoder.materialize`
        // now routes its actual render through `RenderGate`, so this
        // `await` both gets the heavy work off the main thread AND
        // guarantees it never overlaps another RAW render anywhere in the
        // app. `isLoadingImage` covers the visible gap so the UI reads as
        // "working" instead of unresponsive.
        let resolvedImage: CIImage
        let isRawOrientationUp: Bool
        let rawAdjustmentSupport: RawDecoder.RawAdjustmentSupport
        if RawDecoder.isRaw(url) {
            isLoadingImage = true
            resolvedImage = await RawDecoder.materialize(raw)
            guard myGeneration == loadGeneration else { return }
            // Cached once here, at load time, rather than re-read at
            // WB-eyedropper tap time — see `currentRawOrientationIsUp`'s
            // own doc comment.
            let orientation = await RawDecoder.confirmedOrientation(of: url)
            guard myGeneration == loadGeneration else { return }
            isRawOrientationUp = orientation == .up
            // Same caching rationale as orientation just above — see
            // `currentRawAdjustmentSupport`'s own doc comment.
            rawAdjustmentSupport = await RawDecoder.confirmedAdjustmentSupport(of: url)
            guard myGeneration == loadGeneration else { return }
            // Phase 6 slice 7: pin the decoder version on this photo's
            // FIRST decode only — `.isEmpty` is the entire mechanism
            // that makes this a one-time, never-overwritten capture, not
            // a re-pin-on-every-open. Harmless that this runs after the
            // FIRST `RawDecoder.decode` call above already happened: an
            // empty pin makes `applyRawNativeSettings` skip the
            // assignment entirely, so that first decode already used
            // exactly the value we're about to capture — see
            // `EditState.rawDecoderVersionPin`'s own doc comment.
            //
            // Reviewer-caught: capturing it into `restoredState` alone is
            // NOT enough to actually persist it — the assignment to
            // `editState` further below happens inside the
            // `isLoadingPhoto` bracket, which deliberately SKIPS
            // `scheduleSidecarSave()` (that's the same mechanism that
            // keeps merely OPENING a photo from ever prompting for folder
            // access). For a genuinely never-edited photo that's correct:
            // nothing worth persisting exists yet, and this backfill stays
            // in memory only until a real edit eventually saves it. But
            // for a photo that already has a sidecar on disk (from a
            // session before this slice shipped), silently doing nothing
            // would leave it permanently unpinned unless the user happens
            // to make another real edit — defeating this field's entire
            // purpose for exactly the photos it matters most for. So this
            // one case is flagged here and persisted explicitly, further
            // below, once `currentURL` is set — folder access is already
            // known-resolvable at this point (an existing sidecar was
            // just read from it), so this never introduces a NEW access
            // prompt.
            if restoredState.rawDecoderVersionPin.isEmpty,
               let version = await RawDecoder.currentDefaultDecoderVersion(of: url) {
                guard myGeneration == loadGeneration else { return }
                restoredState.rawDecoderVersionPin = version
                shouldPersistBackfilledDecoderPin = existingSidecarState != nil
            }
            isLoadingImage = false
        } else {
            resolvedImage = raw
            isRawOrientationUp = false
            rawAdjustmentSupport = .unsupported
        }
        // Reviewer-caught: the early flush above only covers edits made
        // BEFORE this function's first `await`. The Adjust sidebar stays
        // interactive for the OUTGOING photo throughout both awaits above
        // (only `currentImage == nil` disables it — see `ContentView`'s
        // `editControls`), so a slider drag DURING either await would
        // otherwise be silently discarded the moment `editState` below
        // overwrites it with the incoming photo's `restoredState` — with
        // no further `await` between this flush and that overwrite, this
        // one closes that gap completely. (Residual, deliberately not
        // engineered around: reopening the SAME already-open photo mid-
        // drag can still commit a `restoredState` snapshot older than a
        // drag captured between the two flushes — narrow enough, and this
        // flush still saves it correctly to disk, so only the in-memory
        // `editState` would transiently lag, not the sidecar.)
        flushPendingSidecarSave()
        currentImage = resolvedImage
        currentFileName = url.lastPathComponent
        currentURL = url
        currentRawOrientationIsUp = isRawOrientationUp
        currentRawAdjustmentSupport = rawAdjustmentSupport
        isLoadingPhoto = true
        editState = restoredState
        isLoadingPhoto = false
        // Persist the decoder-version pin backfilled above, for the one
        // case (an already-existing sidecar) where leaving it in memory
        // only isn't enough — see the pin-capture block's own comment.
        // Must run AFTER `currentURL = url` above, since `saveSidecarNow()`
        // reads it; must run OUTSIDE the `isLoadingPhoto` bracket, since
        // that bracket's whole purpose is to suppress exactly this kind
        // of save for a normal load. A direct call, not
        // `scheduleSidecarSave()`'s debounce — nothing else is pending
        // for this freshly-opened photo, so there's no coalescing benefit
        // to waiting.
        // A RAW-native re-decode debounced during either await above is
        // now stale — `editState` was just overwritten with the INCOMING
        // photo's own already-correct `restoredState`, so firing it would
        // be a guaranteed-no-op full re-decode of the photo just opened.
        rawRedecodeWorkItem?.cancel()
        // Undo history is per-photo: the incoming photo's own persisted history when it is still consistent with its edits
        // (the decoder-pin backfill CHANGES the state, which makes the persisted history stale — dropped), else a fresh one.
        resetHistory(restoring: restoredState == existingSidecarState ? persistedHistory : nil)
        // Must come AFTER the history reset: a save embeds `history`, which until now was the OUTGOING photo's.
        if shouldPersistBackfilledDecoderPin {
            saveSidecarNow(suppressErrorMessage: true)
        }
    }

    // MARK: - RAW-native re-decode (Phase 6 slices 2-3)

    /// How long a pause in a RAW-native field's changes (see
    /// `EditState.requiresRawRedecode` for the current full list) must
    /// last before a re-decode actually fires. A dragged slider writes
    /// `editState` many times per second; without
    /// this, every intermediate value would trigger its own full RAW
    /// demosaic — exactly the per-frame-decode freeze `RawDecoder.materialize`
    /// exists to prevent, one level up. Slightly longer than
    /// `historyCoalesceInterval` since the cost being coalesced here is far
    /// higher (a full re-decode, not an undo-step commit) — tuned by feel,
    /// not measured, same honesty precedent as that constant's own comment.
    private static let rawRedecodeCoalesceInterval: TimeInterval = 0.4

    private var rawRedecodeWorkItem: DispatchWorkItem?

    private func scheduleRawRedecode() {
        rawRedecodeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.redecodeForRawNativeChange() }
        rawRedecodeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rawRedecodeCoalesceInterval, execute: workItem)
    }

    /// Re-decodes the current photo because a RAW-native `EditState` field
    /// changed (debounced via `scheduleRawRedecode` above). Unlike every
    /// other adjustment, this can't be applied by re-running `EditPipeline`
    /// against `currentImage`: `currentImage` is the already-baked buffer
    /// `RawDecoder.materialize` produced, and these fields live on the
    /// `CIRAWFilter` that produced it. So this redoes exactly what
    /// `load(from:)` does for the IMAGE (decode + materialize) and nothing
    /// else — no sidecar read, no history reset, no `currentURL` change;
    /// `editState` is already correct, this only catches the pixels up to it.
    ///
    /// Shares `loadGeneration` with `load(from:)` DELIBERATELY, not
    /// accidentally: both write `currentImage`/`isLoadingImage`, so they
    /// must be able to supersede each other — toggling/dragging this
    /// slider then immediately switching photos must leave the new
    /// photo's pixels on screen, not a late re-decode of the old one, the
    /// exact stomp `loadGeneration` exists to prevent (see its own doc
    /// comment).
    ///
    /// `isLoadInFlight` guards a real bug, not a theoretical one: the
    /// Adjust sidebar stays interactive during a photo load (only the
    /// image pane shows the spinner), so the user CAN drag this slider
    /// while a different photo is still loading. At that moment
    /// `currentURL` still names the OUTGOING photo — without this guard
    /// we'd re-decode the wrong file and bump `loadGeneration` out from
    /// under the in-flight load, which would then silently abandon itself.
    private func redecodeForRawNativeChange() {
        guard !isLoadInFlight else { return }
        // Defense in depth: with every RAW-native field excluded from
        // `applyingPreset`, the RAW-only UI is the sole writer, so this
        // shouldn't be reachable for a non-RAW photo.
        guard let url = currentURL, RawDecoder.isRaw(url) else { return }

        // Captured as a value-type snapshot on the main actor before the
        // hop below — a mid-decode edit can't tear it, unlike reading
        // `self.editState` again inside the `Task`.
        let state = editState
        loadGeneration += 1
        let myGeneration = loadGeneration
        isLoadingImage = true
        Task { [weak self] in
            guard let decoded = await RawDecoder.decode(contentsOf: url, editState: state) else {
                guard let self, myGeneration == self.loadGeneration else { return }
                self.isLoadingImage = false
                self.loadErrorMessage = "Couldn't re-read \"\(url.lastPathComponent)\" to apply that RAW setting. The photo on screen is unchanged."
                return
            }
            // Reviewer-caught: without this check, a superseded re-decode
            // (the user switched photos while this one was still in
            // flight) would still run a full-res `materialize` — a real
            // cost inside the app-wide serialized `RenderGate` — only to
            // throw the result away at the guard below. Bailing here
            // means it never enters the gate at all, so it can't delay
            // whatever DID supersede it (a photo switch, or a newer drag).
            guard let self, myGeneration == self.loadGeneration else { return }
            let materialized = await RawDecoder.materialize(decoded)
            guard myGeneration == self.loadGeneration else { return }
            self.currentImage = materialized
            self.isLoadingImage = false
            // `load(from:)` gets its post-decode histogram refresh for
            // free from the `editState` assignment that follows it;
            // there's no such assignment here (the state is what STARTED
            // this), so it has to be asked for explicitly or the
            // histogram would keep describing the pre-re-decode pixels.
            self.scheduleHistogramUpdate()
        }
    }


    // MARK: - Histogram

    /// Debounces histogram recomputation (~150ms) so a fast slider drag
    /// doesn't trigger a background render on every intermediate value —
    /// matches CLAUDE.md's "DB access never blocks main thread... thumbnails
    /// generate on a background queue" principle, applied here to a UI
    /// computation for the first time in this codebase. Fires on EVERY
    /// `editState` change (not just Levels' own sliders): `load(from:)`
    /// resets `editState` right after setting `currentImage`, so opening a
    /// new photo also correctly triggers a recompute against the new image.
    private func scheduleHistogramUpdate() {
        histogramWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.recomputeHistogram() }
        histogramWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    /// Computes the histogram from the CURRENT edit state with the user's
    /// own not-yet-applied Levels adjustment neutralized to identity — a
    /// deliberate v1 scope decision, not a literal "state before Levels"
    /// (which would need `EditPipeline` API surface to expose a true
    /// pre-Levels intermediate). This shows "the final image's tonal
    /// distribution as it stands, holding your own Levels tweak out of the
    /// picture so it doesn't conflate the reference" — stays stable while
    /// dragging the Levels sliders themselves (since those are zeroed for
    /// this computation) and correctly updates for every OTHER edit (crop,
    /// exposure, contrast, etc.), matching what a real Levels histogram is
    /// for without new pipeline surface.
    private func recomputeHistogram() {
        guard let currentImage else {
            histogramData = .empty
            return
        }
        var referenceState = editState
        referenceState.levelsBlackPoint = 0
        referenceState.levelsWhitePoint = 1
        referenceState.levelsGamma = 1

        histogramGeneration += 1
        let generation = histogramGeneration

        // Downscale BEFORE the pipeline runs, not after (IMPROVEMENTS.md P5)
        // — measured live: on a 24MP source with Sharpen/Noise Reduction/
        // Clarity all active, HistogramComputer.histogram(of:)'s render
        // alone ranged 24.6-399.9ms, because those convolution stages
        // executed at full source resolution before HistogramComputer's OWN
        // downsample-to-256 ever got a chance to shrink the graph. Every
        // extent-dependent EditPipeline stage derives its geometry as a
        // FRACTION of the current extent (the same argument `ProxyScale` and
        // `ThumbnailGenerator.thumbnail(for:maxPixelSize:editState:)` already
        // document and ship), so downscaling first is APPROXIMATELY correct.
        // It is not exact — measured, all four stages TESTED (dehaze, noise
        // reduction, sharpen, clarity) diverge under downscale, by amounts
        // that swap rank with both scale and image content. Texture,
        // vignette and red-eye were not measured. Noise Reduction diverges
        // for the opposite reason to the radius-based ones, being
        // resolution-INDEPENDENT by design (`kNoiseReductionSpan`).
        // See IMPROVEMENTS.md D18 for the measured matrix — indicative only
        // here, since D18 measured a Lanczos downscale while this path uses a
        // plain affine one (which aliases where Lanczos averages, as this
        // comment notes further down). Accepted regardless, because this is a
        // HISTOGRAM: a small tonal shift does not change what the histogram is
        // for. The same approximation would matter on a rendered pixel path.
        //
        // Downscaling first DOES
        // mean the histogram's noise-driven tonal spread can diverge from a
        // full-resolution computation whenever NR is active — the direction
        // isn't asserted here (a plain affine minification can alias rather
        // than average; see `ProxyBuilder`'s own note that a plain scale
        // aliases visibly at aggressive ratios, unlike Lanczos, and this
        // call site's ratio is more aggressive still). Accepted as a known,
        // reviewer-flagged divergence for this coarse, debounced statistical
        // display, not a precise per-pixel readout — not independently
        // measured in which direction it moves.
        //
        // Plain affine, not Lanczos/`ProxyBuilder`: this matches
        // `HistogramComputer`'s own existing plain-affine resample exactly
        // (see its `histogram(of:)` implementation), so this introduces no
        // NEW class of resampling error — it only moves an equivalent one
        // earlier, ahead of the convolutions. `ProxyBuilder`'s async/
        // `RenderGate`/`CVPixelBuffer` machinery was built for a different
        // call site (`ImageRenderer`'s live on-screen render) and would add
        // real coupling/cost for no benefit here.
        //
        // Sized against the DISPLAYED extent (post-crop/straighten/
        // perspective), not `currentImage`'s own raw extent — reviewer-
        // caught: crop alone can shrink the displayed extent to ~10% per
        // side, so sizing against the uncropped source could still hand
        // `HistogramComputer` a near-degenerate input on a cropped photo,
        // exactly the case the headroom exists to prevent. The probe itself
        // is cheap (`EditPipeline.apply` only builds a lazy graph — no
        // pixels render to report `.extent`), the same argument
        // `ImageRenderer.choosePipelineSource` already relies on.
        let displayedExtentSize = EditPipeline.apply(referenceState, to: currentImage).extent.size
        let downscale = HistogramComputer.inputDownscale(forDisplayedSize: displayedExtentSize)
        let histogramInput = downscale < 1
            ? currentImage.transformed(by: CGAffineTransform(scaleX: downscale, y: downscale))
            : currentImage

        Task.detached(priority: .userInitiated) { [weak self] in
            let edited = EditPipeline.apply(referenceState, to: histogramInput)
            let data = HistogramComputer.histogram(of: edited)
            await MainActor.run {
                guard let self, self.histogramGeneration == generation else { return }
                self.histogramData = data
            }
        }
    }

    // MARK: - White Balance Eyedropper

    /// Samples the point at normalized `(u, v)` (0...1, SwiftUI-local
    /// space — the same convention `ContentView.currentFitRect` establishes)
    /// and sets `editState`'s Temperature/Tint to neutralize it.
    ///
    /// Samples a GEOMETRY-ONLY render — an `EditState()` with every color/
    /// tone field (including WB itself) left at identity, only straighten/
    /// perspective/transformScale/transformAspect/flip/crop copied from the
    /// real `editState` — rather than
    /// "the displayed image with just WB reset." White balance is pipeline
    /// stage 1, so what matters for neutralizing it is the RAW
    /// front-of-pipeline chromaticity at that point, not what it looks like
    /// after exposure/contrast/curves/etc have already reshaped it (those
    /// stages don't commute with WB). Since color stages don't change
    /// extent, this render still shares `currentFitRect`'s exact coordinate
    /// space, so no geometric-transform inversion is needed to map a tap
    /// back to a pixel.
    /// Phase 6 slice 4: for RAW photos with no geometry edits applied yet
    /// AND a CONFIRMED (not merely unreadable — see `currentRawOrientationIsUp`'s
    /// own doc comment) EXIF orientation of `.up`, a tap maps 1:1 onto
    /// `CIRAWFilter`'s own native pixel grid with no inverse-geometry or
    /// inverse-orientation transform needed — so this writes
    /// `rawWhiteBalanceNeutralPoints` directly (plus resetting
    /// `whiteBalanceTemperature`/`whiteBalanceTint` to identity, matching
    /// the slow path's own always-overwrite behavior below — otherwise a
    /// stale non-identity value left over from a manual nudge, a preset,
    /// or an earlier slow-path tap would still apply on top, post-decode)
    /// and lets the existing RAW-native re-decode machinery (`editState`'s
    /// `didSet` → `EditState.requiresRawRedecode` → `scheduleRawRedecode`)
    /// take it from there, entirely bypassing `WhiteBalanceSolver`'s
    /// search — see `EditState.rawWhiteBalanceNeutralPoints`'s own doc
    /// comment for the two live-measured reasons this exact gate exists.
    /// Every other case (non-RAW, any geometry edit, a non-`.up` or
    /// unreadable orientation) falls through unchanged to the existing
    /// search-based path below.
    func pickWhiteBalance(normalizedX u: Double, normalizedY v: Double) {
        guard let currentImage else { return }

        if let url = currentURL,
           RawDecoder.isRaw(url),
           editState.isGeometryAtIdentity,
           currentRawOrientationIsUp {
            editState.rawWhiteBalanceNeutralPoints = [
                RawNeutralPoint(x: min(1, max(0, u)), y: min(1, max(0, 1 - v)))
            ]
            // Reviewer-caught: the slow path ALWAYS overwrites both these
            // fields (see below), fully determining the WB result on its
            // own. The fast path must do the same — otherwise a stale
            // non-identity `whiteBalanceTemperature`/`whiteBalanceTint`
            // (left over from a manual slider nudge, "Fix Color Cast", a
            // preset, or an earlier slow-path tap before a crop was
            // removed) would still apply ON TOP of the RAW-native
            // neutralization post-decode, silently leaving the tapped
            // pixel non-neutral with no message explaining why.
            editState.whiteBalanceTemperature = 6500
            editState.whiteBalanceTint = 0
            // Clear any stale message from a PRIOR slow-path attempt on
            // this same photo — the fast path always succeeds
            // deterministically (no dark-sample rejection, no
            // partial-solve case), so a leftover message here would
            // misleadingly imply this attempt had a problem too.
            whiteBalanceSampleMessage = nil
            return
        }

        var samplingState = EditState()
        samplingState.straightenAngle = editState.straightenAngle
        samplingState.verticalPerspective = editState.verticalPerspective
        samplingState.horizontalPerspective = editState.horizontalPerspective
        samplingState.transformScale = editState.transformScale
        samplingState.transformAspect = editState.transformAspect
        samplingState.flipHorizontal = editState.flipHorizontal
        samplingState.flipVertical = editState.flipVertical
        samplingState.cropInsetTop = editState.cropInsetTop
        samplingState.cropInsetBottom = editState.cropInsetBottom
        samplingState.cropInsetLeft = editState.cropInsetLeft
        samplingState.cropInsetRight = editState.cropInsetRight

        let geometryOnly = EditPipeline.apply(samplingState, to: currentImage)
        let extent = geometryOnly.extent
        guard extent.width > 0, extent.height > 0 else { return }

        // y-flip: SwiftUI-local space is top-left-origin/y-down; `CIImage`'s
        // own space is bottom-left-origin/y-up — the same convention already
        // established and tested elsewhere in this codebase (see
        // `EditPipelineTests`'s `quadrantImage` doc comment on "high-y =
        // visual top").
        let point = CGPoint(
            x: extent.minX + CGFloat(u) * extent.width,
            y: extent.minY + CGFloat(1 - v) * extent.height
        )

        guard let sample = PixelSampler.averageColor(in: geometryOnly, at: point) else {
            whiteBalanceSampleMessage = "Couldn't read a color sample at that point."
            return
        }

        // MEASURED: the solver's search (~52 filter evaluations) takes
        // ~13-30ms on real hardware — enough of a main-thread-hitch risk
        // that, like the histogram, it runs off the main thread. Unlike the
        // histogram (which recomputes on every edit and needs a generation
        // counter to discard stale in-flight results), this is a discrete,
        // one-shot tap that disarms eyedropper mode immediately afterward —
        // the chance of two overlapping solves is low enough that a
        // generation guard is deliberately skipped for v1 scope.
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = WhiteBalanceSolver.solve(sampleLinearRGB: sample)
            await MainActor.run {
                guard let self else { return }
                switch outcome {
                case .solved(let temperature, let tint):
                    self.editState.whiteBalanceTemperature = temperature
                    self.editState.whiteBalanceTint = tint
                case .solvedPartially(let temperature, let tint):
                    self.editState.whiteBalanceTemperature = temperature
                    self.editState.whiteBalanceTint = tint
                    self.whiteBalanceSampleMessage = "Couldn't fully correct this area — it may have too strong a color cast, or not be truly neutral."
                case .rejectedTooDark:
                    self.whiteBalanceSampleMessage = "Pick a brighter neutral area — this spot is too dark to read a color cast."
                }
            }
        }
    }

    // MARK: - Color Range mask eyedropper

    /// Phase 7 slice 5 (second half): the `.colorRange` mask's eyedropper
    /// — picks a color from the CURRENT render at a tapped point and
    /// writes it into the mask identified by `maskID`'s 5 `.colorRange`
    /// scalar fields. Three deliberate differences from `pickWhiteBalance`
    /// above:
    /// 1. No RAW fast path — unlike `rawWhiteBalanceNeutralPoints`, there
    ///    is no decoder-level equivalent for a per-mask color target;
    ///    `CIRAWFilter` has no concept of "masks" at all.
    /// 2. No `Task.detached`/solver — converting one sampled color to hue/
    ///    saturation/luminance is a single closed-form calculation
    ///    (`ColorRangeSelection.hueSaturation`/`.luminance`), synchronous,
    ///    microseconds, unlike `WhiteBalanceSolver`'s ~52-evaluation search.
    /// 3. Samples the image `ColorRange.cikernel` will ACTUALLY compare
    ///    against inside `EditPipeline.applyMasks`, not the naive fully-
    ///    edited display: `applyMasks` reads the running `img` — the
    ///    result of every EARLIER mask in the array, but BEFORE the later
    ///    global stages (Dehaze, Vignette, Clarity, Texture, Noise Reduction,
    ///    Sharpen, Defringe, Grain)
    ///    that run AFTER it in the fixed pipeline order. Sampling the
    ///    fully-edited image would record a color the kernel never
    ///    actually sees there (e.g. under a vignette, a tapped dark
    ///    corner would read darker than what the kernel measures),
    ///    misaligning the selection. So this zeros out `vignetteStrength`/
    ///    `clarity`/`texture`/`dehaze`/`noiseReduction`/`sharpness`/
    ///    `defringePurple`/`defringeGreen`/`grain`
    ///    and truncates `masks`
    ///    to only those BEFORE this one in the array, then renders exactly
    ///    that truncated state — structurally guaranteed to match what
    ///    `applyMasks`'s own loop sees at this mask's own position (both
    ///    read the identical prefix of `editState.masks` through the
    ///    identical earlier pipeline stages), not merely assumed to.
    ///
    /// Reviewer-caught: every early-return below used to fail SILENTLY —
    /// `ContentView`'s tap handler unconditionally disarms
    /// `colorPickingMaskID` right after calling this, and the resulting
    /// `.onChange` then deletes the still-unpicked mask via
    /// `discardUnpickedColorRangeMask`, with no feedback at all for why. The
    /// direct precedent, `pickWhiteBalance`, always surfaces
    /// `whiteBalanceSampleMessage` for its own equivalent failure — reused
    /// here (not a new message property) for the one failure a user can
    /// actually cause (tapping a transparent/out-of-bounds point); the
    /// `currentImage`/`maskIndex` guards stay silent since neither is
    /// reachable from a real tap (no image loaded means no tap-capture
    /// layer exists at all; a vanished mask means `colorPickingMaskID`
    /// itself would already have been cleared by `isEditingMask`'s own
    /// `.onChange`, per `ContentView.swift`).
    ///
    /// FIXED by D25 (2026-09-29): `PixelSampler.averageColor` previously
    /// returned PREMULTIPLIED values (verified: a 0.6-alpha sample read
    /// ~0.6x too low) while `ColorRange.cikernel` unpremultiplies
    /// (`s.rgb / s.a`) before its own HSL/luma math — so a tap on a
    /// semi-transparent region (alpha in `[minAlpha, 1)`, e.g. a corner a
    /// straighten/perspective transform partially reveals) recorded a
    /// LUMINANCE target the kernel could never exactly match.
    /// `PixelSampler.averageColor` now divides by alpha before returning
    /// (the same fix `ImageAverageColor.compute`/`ImageToneStatistics`
    /// already applied for their own samplers), so this call site — and
    /// `pickWhiteBalance`'s identical call — now agree with the kernel.
    func pickColorRangeTarget(maskID: UUID, normalizedX u: Double, normalizedY v: Double) {
        guard let currentImage else { return }
        guard let maskIndex = editState.masks.firstIndex(where: { $0.id == maskID }) else { return }

        var samplingState = editState
        samplingState.vignetteStrength = 0
        samplingState.texture = 0
        samplingState.clarity = 0
        samplingState.dehaze = 0
        samplingState.noiseReduction = 0
        samplingState.sharpness = 0
        samplingState.defringePurple = 0
        samplingState.defringeGreen = 0
        samplingState.grain = 0
        samplingState.masks = Array(editState.masks[..<maskIndex])

        let sampled = EditPipeline.apply(samplingState, to: currentImage)
        let extent = sampled.extent
        guard extent.width > 0, extent.height > 0 else { return }

        // y-flip: the same `1 - v` convention `pickWhiteBalance` uses —
        // SwiftUI-local space is top-left-origin/y-down, `CIImage`'s own
        // space is bottom-left-origin/y-up.
        let point = CGPoint(
            x: extent.minX + CGFloat(u) * extent.width,
            y: extent.minY + CGFloat(1 - v) * extent.height
        )
        guard let sample = PixelSampler.averageColor(in: sampled, at: point) else {
            whiteBalanceSampleMessage = "Couldn't read a color sample at that point."
            return
        }
        whiteBalanceSampleMessage = nil

        let (hue, saturation) = ColorRangeSelection.hueSaturation(forLinearRGB: sample.r, sample.g, sample.b)
        let luminance = ColorRangeSelection.luminance(forLinearRGB: sample.r, sample.g, sample.b)

        // One `editState` assignment, not 4 sequential writes — each write
        // is a candidate undo-history/sidecar-debounce entry.
        var mask = editState.masks[maskIndex]
        mask.colorRangeTargetHue = hue
        mask.colorRangeTargetSaturation = saturation
        mask.colorRangeTargetLuminance = luminance
        mask.colorRangeHasTarget = true
        editState.masks[maskIndex] = mask
    }

    /// Point Color's own eyedropper. Same shape as `pickColorRangeTarget`
    /// just above (guards, `1 - v` y-flip, `PixelSampler.averageColor`, one
    /// batched `editState` write, the shared `whiteBalanceSampleMessage`
    /// failure surface) but with a structurally different sampling
    /// technique: `pickColorRangeTarget` hand-zeroes a maintained list of
    /// downstream fields, which only works because every one of those
    /// fields is INDEPENDENT of what runs before the sampling point. That
    /// does not hold here — `EditPipeline.effectiveTone(_:)` blends
    /// `brilliance` into BOTH the upstream contrast/shadows/highlights Point
    /// Color's own position sits after AND the downstream saturation, so no
    /// assignment of `EditState` fields can neutralize the downstream half
    /// while preserving the upstream one. Instead this calls `EditPipeline
    /// .apply(_:to:truncatingColorAt:)`, which stops the pipeline exactly at
    /// this instance's own kernel invocation from INSIDE the real
    /// `applyPerceptualAdjustments` — structurally guaranteed to match, not
    /// a hand-maintained list that can go stale (that list has already gone
    /// stale twice for `pickColorRangeTarget`, see PROGRESS.md).
    ///
    /// `PointColor` stores no target luminance (IMPROVEMENTS.md D22), so
    /// only `PointColorSelection.hueSaturation(forPerceptualRGB:)` is
    /// needed — NOT `ColorRangeSelection.hueSaturation(forLinearRGB:)`,
    /// which operates on the wrong domain (scene-linear, not this stage's
    /// own perceptual/headroom-normalized one — see `PointColorSelection`'s
    /// own doc comment).
    func pickPointColorTarget(pointColorID: UUID, normalizedX u: Double, normalizedY v: Double) {
        guard let currentImage else { return }
        guard let index = editState.pointColors.firstIndex(where: { $0.id == pointColorID }) else { return }

        let sampled = EditPipeline.apply(editState, to: currentImage, truncatingColorAt: .pointColor(index: index))
        let extent = sampled.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let point = CGPoint(
            x: extent.minX + CGFloat(u) * extent.width,
            y: extent.minY + CGFloat(1 - v) * extent.height
        )
        guard let sample = PixelSampler.averageColor(in: sampled, at: point) else {
            whiteBalanceSampleMessage = "Couldn't read a color sample at that point."
            return
        }
        whiteBalanceSampleMessage = nil

        let (hue, saturation) = PointColorSelection.hueSaturation(forPerceptualRGB: sample.r, sample.g, sample.b)
        // Reviewer-caught: `PointColorSelection.hueSaturation` deliberately
        // mirrors the kernel's own non-clamping of negative channels (see
        // its own doc comment) — correct for matching the kernel, but its
        // result is PERSISTED here, unlike the kernel's own transient one.
        // A sampled pixel with a negative channel and `L` landing at
        // exactly 0 or 1 with nonzero chroma makes `saturation` `+inf`;
        // writing that into `EditState` would make it un-round-trippable
        // (`JSONEncoder` throws on non-finite `Double`, failing every
        // sidecar/catalog write from this point on). Guarded HERE, not
        // inside `PointColorSelection` itself — a clamp there would break
        // the intentional kernel-parity this type exists for.
        guard hue.isFinite, saturation.isFinite else {
            whiteBalanceSampleMessage = "Couldn't read a color sample at that point."
            return
        }

        var pointColor = editState.pointColors[index]
        pointColor.targetHue = hue
        pointColor.targetSaturation = saturation
        pointColor.hasTarget = true
        editState.pointColors[index] = pointColor
    }

    // MARK: - Color Cast

    /// Analyzes the WHOLE image's gray-world average color and sets
    /// `editState`'s Temperature/Tint to neutralize it — architecturally
    /// different from `pickWhiteBalance` (whole-image statistics vs a
    /// single tapped pixel) but reuses everything else about it almost
    /// unchanged: the same geometry-only sampling render (WB is pipeline
    /// stage 1, so the raw front-of-pipeline chromaticity is what needs to
    /// average to neutral), the same `WhiteBalanceSolver`, the same
    /// `Outcome` handling and `whiteBalanceSampleMessage` alert. No new
    /// `EditState` fields — Cast, like the eyedropper, is a new UI-driven
    /// WAY to set fields that already exist, not a new adjustment.
    func fixColorCast() {
        guard let currentImage else { return }

        let samplingState = editState.geometryOnlySamplingState()
        // Captured before the hop below — see `analysisGeneration`'s own
        // doc comment. If the user switches to a different photo while this
        // is in flight, every write below is silently dropped instead of
        // landing on the new photo.
        let myGeneration = analysisGeneration

        // Unlike `pickWhiteBalance`'s trivial 5x5-pixel box sample, this is a
        // full-image 256px render plus a whole-buffer CPU scan — the same
        // cost profile `recomputeHistogram` already backgrounds for
        // `HistogramComputer.histogram(of:)`, so the render itself (not just
        // the solve) must happen inside the detached task, not on the main
        // actor before it.
        Task.detached(priority: .userInitiated) { [weak self] in
            let geometryOnly = EditPipeline.apply(samplingState, to: currentImage)
            guard let sample = ImageAverageColor.compute(of: geometryOnly) else {
                await MainActor.run {
                    guard let self, self.analysisGeneration == myGeneration else { return }
                    self.whiteBalanceSampleMessage = "Couldn't analyze this image's colors."
                }
                return
            }

            let outcome = WhiteBalanceSolver.solve(sampleLinearRGB: sample)
            await MainActor.run {
                guard let self, self.analysisGeneration == myGeneration else { return }
                switch outcome {
                case .solved(let temperature, let tint):
                    self.editState.whiteBalanceTemperature = temperature
                    self.editState.whiteBalanceTint = tint
                case .solvedPartially(let temperature, let tint):
                    self.editState.whiteBalanceTemperature = temperature
                    self.editState.whiteBalanceTint = tint
                    self.whiteBalanceSampleMessage = "Couldn't fully correct this image's color cast — it may be unusually strong."
                case .rejectedTooDark:
                    self.whiteBalanceSampleMessage = "This image is too dark overall to read a color cast."
                }
            }
        }
    }

    // MARK: - Auto Tone

    /// Analyzes the whole image's tonal distribution and sets Exposure,
    /// Black Point, Highlights, Shadows, Contrast and Vibrance in one shot
    /// — a heuristic v1 "sensible starting point," not ML (see CLAUDE.md's
    /// own Auto Tone roadmap entry and `AutoToneSolver`'s own doc comment
    /// for the full design, including two genuinely serious reviewer-caught
    /// bugs in that solver's own Contrast/Black Point/Shadows interaction).
    ///
    /// Structurally mirrors `fixColorCast()`: the same geometry-only
    /// sampling render, the same `analysisGeneration` stale-write guard.
    /// Two real differences:
    /// - The sampling state ALSO copies Temperature/Tint (not just
    ///   geometry) — Auto Tone solves against the image as WB already
    ///   corrects it, since WB is pipeline stage 1 and runs before every
    ///   field this solves for, but Auto Tone itself never writes WB
    ///   (Fix Color Cast stays its own separate button — user-confirmed
    ///   scope decision, matching Lightroom's own Auto/WB-Auto split).
    /// - The result commits as ONE atomic undo step, like
    ///   `applyPreset(_:)`/`revertToOriginal()`, NOT through the debounced
    ///   `editState` `didSet` path `fixColorCast()` uses. `fixColorCast()`
    ///   can get away with the debounced path because it only ever writes
    ///   2 fields that logically belong together (Temperature+Tint); Auto
    ///   Tone writes 6, and letting them merge into whatever burst happens
    ///   to be in flight (or split across two separate commits if a slider
    ///   drag lands in the debounce's own ~350ms window) would make a
    ///   single ⌘Z behave inconsistently depending on timing.
    ///
    /// Idempotent by construction, not by any special-case logic: the
    /// sampling state excludes every field this method itself writes (via
    /// `geometryOnlySamplingState()`), so pressing Auto Tone again samples
    /// the SAME underlying image and solves to the SAME result — see
    /// `AutoToneEndToEndTests.testSolvingTwiceInARowGivesTheSameResult`.
    func autoTone() {
        guard let currentImage else { return }

        var samplingState = editState.geometryOnlySamplingState()
        samplingState.whiteBalanceTemperature = editState.whiteBalanceTemperature
        samplingState.whiteBalanceTint = editState.whiteBalanceTint
        // Captured before the hop below — see `analysisGeneration`'s own
        // doc comment. If the user switches to a different photo while
        // this is in flight, the write below is silently dropped instead
        // of landing on the new photo.
        let myGeneration = analysisGeneration

        // Same cost-profile reasoning as `fixColorCast()`: a full-image
        // 256px render plus a whole-buffer CPU scan (here, a full sort for
        // percentiles, not just a running sum) must happen inside the
        // detached task, not on the main actor before it.
        Task.detached(priority: .userInitiated) { [weak self] in
            let sampled = EditPipeline.apply(samplingState, to: currentImage)
            guard let stats = ImageToneStatistics.compute(of: sampled) else {
                await MainActor.run {
                    guard let self, self.analysisGeneration == myGeneration else { return }
                    self.whiteBalanceSampleMessage = "Couldn't analyze this image's tones."
                }
                return
            }

            let result = AutoToneSolver.solve(stats)
            await MainActor.run {
                guard let self, self.analysisGeneration == myGeneration else { return }
                self.finalizePendingCommit()
                var next = self.editState
                next.exposureEV = result.exposureEV
                next.blackPoint = result.blackPoint
                next.curvesHighlights = result.curvesHighlights
                next.curvesShadows = result.curvesShadows
                next.contrast = result.contrast
                next.vibrance = result.vibrance
                self.history.commit(next, summary: "Auto Tone")
                self.applyHistoryState(self.history.current)
            }
        }
    }

    // MARK: - Spot removal

    /// Shown by the Remove section's own alert (placement refusals, a failed auto-source).
    @Published var retouchMessage: String?

    /// Appends a spot in the middle of the frame and finds its source in the background. Refused (with a message)
    /// unless the geometry is at identity — spots live in the unedited source frame and the on-image editing math
    /// only holds there (see `RetouchSpot`) — and at the 50-spot cap. Returns the new spot's id.
    @discardableResult
    func addRetouchSpot() -> UUID? {
        guard currentImage != nil else { return nil }
        guard editState.isGeometryAtIdentity else {
            retouchMessage = "Reset crop, straighten, perspective, scale and flip to add or move spots. Existing spots still apply."
            return nil
        }
        guard let spot = RetouchOverlayGeometry.newSpot(existingCount: editState.retouchSpots.count) else {
            retouchMessage = "A photo can have at most \(EditState.maxRetouchSpots) spots."
            return nil
        }
        editState.retouchSpots.append(spot)
        findRetouchSource(for: spot.id, reportFailure: false)
        return spot.id
    }

    /// Searches (off the main thread) for a good source for the spot `id` and writes the offset if the spot still
    /// exists and the photo has not changed meanwhile (`analysisGeneration`). The search is a convenience that works
    /// on smooth content and is unreliable on strong texture (docs/ROADMAP_HISTORY.md spike): when it finds nothing
    /// the existing offset is kept and — only for an explicit "Find Source" press — the user is told to drag the
    /// source circle.
    func findRetouchSource(for id: UUID, reportFailure: Bool = true) {
        guard let currentImage, let spot = editState.retouchSpots.first(where: { $0.id == id }), spot.isFinite else { return }
        let obstacles = editState.retouchSpots.filter { $0.id != id }
            .map { RetouchSourceSearch.Obstacle(x: $0.x, y: $0.y, radius: $0.radius) }
        let myGeneration = analysisGeneration
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> RetouchSourceSearch.Result? in
                guard let bitmap = RetouchSourceBitmap.make(from: currentImage) else { return nil }
                return RetouchSourceSearch.bestSource(
                    in: bitmap, x: spot.x, y: spot.y, radius: spot.radius, avoiding: obstacles)
            }.value
            guard let self, self.analysisGeneration == myGeneration else { return }
            // Write only if the spot is STILL what the search was run for: the next thing a user does after Add Spot is
            // drag it onto the blemish, or set the source by hand — an offset computed for the old centre/radius would
            // overwrite that choice or point at an unchecked place (another spot, off-frame).
            guard let index = self.editState.retouchSpots.firstIndex(where: { $0.id == id }) else { return }
            let live = self.editState.retouchSpots[index]
            guard live.x == spot.x, live.y == spot.y, live.radius == spot.radius,
                  live.sourceDX == spot.sourceDX, live.sourceDY == spot.sourceDY else { return }
            guard let found else {
                if reportFailure {
                    self.retouchMessage = "No good source was found automatically — drag the dashed circle to choose one."
                }
                return
            }
            self.editState.retouchSpots[index].sourceDX = found.dx
            self.editState.retouchSpots[index].sourceDY = found.dy
        }
    }

    // MARK: - Subject mask (AI)

    /// Toggles the subject under a click (`normalizedX/Y`: fractions of the displayed photo, top-left origin) in or
    /// out of the `.subject` mask `maskID` — click-on-image picking. One history step ("Toggle Subject N"). A click that
    /// lands on no subject changes nothing and says so; a legacy union-only mask has no instances to pick.
    /// `reportMiss: false` for the persistent on-image picker: a miss there is a harmless stray click, and an alert per
    /// miss would interrupt a click-click-click workflow (the red overlay already shows what is selected).
    func toggleSubjectInstance(maskID: UUID, normalizedX: Double, normalizedY: Double, reportMiss: Bool = true) {
        guard let currentImage, !isLoadInFlight else { return }
        // A Recompute on this mask would replace its instances and reset `subjectInstanceEnabled`, silently wiping a
        // toggle made while it runs.
        guard !isSelectingSubject else {
            subjectMaskMessage = "Wait for subject detection to finish, then click again."
            return
        }
        guard let mask = editState.masks.first(where: { $0.id == maskID && $0.kind == .subject }) else { return }
        guard !mask.subjectInstancePNGs.isEmpty else {
            subjectMaskMessage = "This mask has no separate subjects to pick — use Recompute to detect them."
            return
        }
        guard let index = SubjectInstancePicker.hit(
            state: editState, maskID: maskID, source: currentImage, normalizedX: normalizedX, normalizedY: normalizedY
        ) else {
            if reportMiss { subjectMaskMessage = "No subject at that point." }
            return
        }
        finalizePendingCommit()
        var next = editState
        guard let maskIndex = next.masks.firstIndex(where: { $0.id == maskID }) else { return }
        var enabled = next.masks[maskIndex].subjectInstanceEnabled
        // A missing entry means "enabled" (see `Mask.subjectInstanceEnabled`): materialize to the instance count first
        // so flipping ONE entry cannot disable the others.
        while enabled.count < next.masks[maskIndex].subjectInstancePNGs.count { enabled.append(true) }
        enabled[index].toggle()
        next.masks[maskIndex].subjectInstanceEnabled = enabled
        history.commit(next, summary: "Toggle Subject \(index + 1)")
        applyHistoryState(history.current)
    }

    /// Runs Vision on the UNEDITED current image and commits ONE undo step: appends a new `.subject`
    /// mask (all adjustments 0 — the user then dials them in), or, when `maskID` names an existing
    /// subject mask, replaces that mask's raster ("Recompute Subject"). Same shape as `autoTone()`:
    /// detached work, `analysisGeneration` stale-write guard. `completion` gets the affected mask's id
    /// on success, `nil` otherwise (no subject / failed / refused / stale). A recompute that yields the
    /// identical raster still reports success but adds no undo step (`EditHistory` drops an unchanged state).
    func selectSubject(replacing maskID: UUID? = nil, completion: ((UUID?) -> Void)? = nil) {
        guard !isSelectingSubject else { completion?(nil); return } // double click: the first run is still going
        guard let currentImage, !isLoadInFlight else {
            subjectMaskMessage = "Wait for the photo to finish loading, then try again."
            completion?(nil)
            return
        }
        isSelectingSubject = true
        let myGeneration = analysisGeneration
        // The completion stays on the main actor (it is never captured by the detached work).
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                SubjectMaskGenerator.generate(from: currentImage)
            }.value
            do { // (scope only: keeps the `self` unwrap local to the main-actor continuation)
                guard let self else { return }
                self.isSelectingSubject = false
                // The photo changed while Vision ran: drop the result rather than land it on another photo.
                guard self.analysisGeneration == myGeneration else { completion?(nil); return }
                switch result {
                case .noSubject:
                    self.subjectMaskMessage = "No subject was found in this photo."
                    completion?(nil)
                case .failed(let reason):
                    self.subjectMaskMessage = reason
                    completion?(nil)
                case .mask(let instances, let revision):
                    self.finalizePendingCommit()
                    var next = self.editState
                    var affected: UUID?
                    if let maskID, let index = next.masks.firstIndex(where: { $0.id == maskID && $0.kind == .subject }) {
                        // Replace the whole selection set: the instance count/order can change, so the old
                        // enabled flags (and any legacy union PNG, which instances would not override
                        // the other way round) must not survive. Feather/invert are kept.
                        next.masks[index].subjectInstancePNGs = instances
                        next.masks[index].subjectMaskPNG = nil
                        next.masks[index].subjectInstanceEnabled = []
                        next.masks[index].subjectMaskRevision = revision
                        affected = maskID
                    } else if maskID == nil {
                        var mask = Mask()
                        mask.kind = .subject
                        mask.subjectInstancePNGs = instances
                        mask.subjectMaskRevision = revision
                        next.masks.append(mask)
                        affected = mask.id
                    }
                    guard let affected else { // the mask being recomputed was deleted while Vision ran
                        self.subjectMaskMessage = "That mask was deleted before its subject was found."
                        completion?(nil)
                        return
                    }
                    self.history.commit(next, summary: maskID == nil ? "Select Subject" : "Recompute Subject")
                    self.applyHistoryState(self.history.current)
                    completion?(affected)
                }
            }
        }
    }

    // MARK: - Undo/Redo

    /// Called from `editState`'s `didSet` for every write that ISN'T an
    /// undo/redo replay. A slider/crop drag fires many writes per second, so
    /// this doesn't commit immediately — it just marks a burst as in
    /// progress (if one isn't already) and (re)schedules a debounced
    /// `finalizePendingCommit()` after `historyCoalesceInterval` of
    /// inactivity, coalescing the whole burst into one undo step.
    private func recordEditChange() {
        isBurstPending = true

        historyCommitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.finalizePendingCommit() }
        historyCommitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.historyCoalesceInterval, execute: workItem)
    }

    /// Settles the in-progress burst (if any) into one `EditHistory` commit.
    /// `EditHistory.commit`'s own `== current` guard drops a burst that
    /// netted no actual change (e.g. a slider dragged back to its start).
    private func finalizePendingCommit() {
        guard isBurstPending else { return }
        isBurstPending = false
        history.commit(editState)
        refreshHistoryState()
    }

    /// Applies `state` as the result of an undo/redo/jump step. Guarded by
    /// `isApplyingHistoryChange` so the resulting `editState` `didSet`
    /// doesn't re-record this as a new burst (which would immediately
    /// re-commit the very state just restored) — `scheduleHistogramUpdate()`
    /// still runs unconditionally, so the live histogram updates correctly.
    private func applyHistoryState(_ state: EditState) {
        isApplyingHistoryChange = true
        editState = state
        isApplyingHistoryChange = false
        refreshHistoryState()
    }

    /// Republishes every `EditHistory`-derived `@Published` property —
    /// `canUndo`/`canRedo` (the toolbar buttons) and `historyEntries`/
    /// `currentHistoryIndex` (the History panel) — from the current
    /// `history`. Named for what it now covers as a whole, not just the
    /// undo/redo flags it originally published alone; called after every
    /// operation that can change `history`'s shape or cursor (`commit` via
    /// `finalizePendingCommit`, `applyHistoryState`, `resetHistory`).
    private func refreshHistoryState() {
        canUndo = history.canUndo
        canRedo = history.canRedo
        historyEntries = history.entries
        currentHistoryIndex = history.currentIndex
    }

    /// Resets undo/redo history to empty — called on `load(from:)` since
    /// edits (and their history) are per-photo; also cancels/discards any
    /// burst that was mid-flight for the PREVIOUS photo so it can't leak a
    /// stray commit into the new photo's fresh history. Also bumps
    /// `analysisGeneration` — same "per-photo, not per-load-attempt" timing
    /// this function already provides for undo history: only a SUCCESSFUL
    /// photo switch should invalidate an in-flight `fixColorCast`/`autoTone`
    /// analysis of the photo being left, not a failed load that leaves the
    /// current photo on screen.
    ///
    /// `initialSummary: "Opened"` is passed explicitly (it's also
    /// `EditHistory.init`'s own default) because the state being loaded
    /// here is frequently RESTORED from a photo's own sidecar, not literal
    /// identity — labeling that first History row "Original" would
    /// misdescribe an already-edited photo's own starting point.
    private func resetHistory(restoring persisted: (archive: HistoryArchive, encoder: HistoryArchive.Encoder)? = nil) {
        historyCommitWorkItem?.cancel()
        historyCommitWorkItem = nil
        isBurstPending = false
        if let persisted, let restored = EditHistory(restoring: persisted.archive.entries, currentIndex: persisted.archive.currentIndex),
           restored.current == editState {
            history = restored
            historyEncoder = persisted.encoder // already warmed off-main, so the first save re-encodes nothing
        } else {
            history = EditHistory(editState, initialSummary: "Opened")
            historyEncoder = HistoryArchive.Encoder()
        }
        historyURL = currentURL
        refreshHistoryState()
        analysisGeneration += 1
        subjectMaskMessage = nil // a late "no subject" must not pop up about the NEXT photo
        retouchMessage = nil // likewise a late "no good source"
    }

    /// Undoes the most recent undo step. First flushes any in-progress burst
    /// (so ⌘Z during an active drag undoes the drag-in-progress edit, not
    /// some older already-committed one), then steps `history` back and
    /// applies the result.
    func undo() {
        finalizePendingCommit()
        history.undo()
        applyHistoryState(history.current)
    }

    /// Redoes the most recently undone step. Same finalize-first reasoning
    /// as `undo()` — though in practice a redo is only available when no
    /// burst is pending (any new edit clears the redo stack), flushing first
    /// keeps the two methods symmetric and safe regardless.
    func redo() {
        finalizePendingCommit()
        history.redo()
        applyHistoryState(history.current)
    }

    /// Jumps directly to an arbitrary past (or redone-but-not-yet-abandoned)
    /// entry — the History panel's own row tap, unlike `undo()`/`redo()`'s
    /// one-step-at-a-time moves. Flushes any in-progress burst FIRST, same
    /// reasoning as `undo()`/`redo()`, and for the same reason must look the
    /// entry up by `id` rather than a row index captured before the flush:
    /// `finalizePendingCommit()` can itself trim the oldest entry or drop
    /// every entry after the cursor, either of which would silently
    /// invalidate an index captured beforehand.
    ///
    /// The `guard history.jump(to: id) else { return }` is load-bearing,
    /// not decoration: every History row is tappable, including the
    /// CURRENT one (unlike the toolbar's Undo/Redo buttons, already
    /// disabled when unavailable) — `EditHistory.jump(to:)` returns `false`
    /// for a tap on the already-current row specifically so this method can
    /// skip `applyHistoryState`'s `editState` write. Without the guard, a
    /// no-op tap would still fire `editState`'s `didSet` →
    /// `scheduleSidecarSave()`, a real, user-visible bug (a spurious save,
    /// possibly even a folder-access permission prompt, for a click that
    /// changed nothing).
    func jumpToHistory(id: HistoryEntry.ID) {
        finalizePendingCommit()
        guard history.jump(to: id) else { return }
        applyHistoryState(history.current)
    }

    /// Resets the current photo's edits back to identity ("Revert to
    /// Original") — the SAME value `load(from:)` already resets to when a
    /// new photo opens. Flushes any in-progress burst FIRST (same reasoning
    /// as `undo()`/`redo()`): a drag already in progress when Revert is
    /// clicked becomes its own undo step, not silently discarded together
    /// with the revert. Commits `history` DIRECTLY (like `undo()`/`redo()`
    /// do, not via the debounced `editState` `didSet` path `recordEditChange`
    /// normally uses) so the revert is always its own atomic, immediately-
    /// committed step — going through the debounce instead would leave a
    /// ~350ms window where a follow-up edit could merge into the same
    /// commit as the revert, and where `canUndo`/`canRedo` would be stale
    /// relative to what the toolbar buttons show.
    func revertToOriginal() {
        finalizePendingCommit()
        // Every other RAW-native field is correctly cleared by the literal
        // `EditState()` below — revert legitimately means "discard this
        // photo's edit history." `rawDecoderVersionPin` is the one
        // exception: it isn't a creative adjustment, it's bookkeeping for
        // which decoder algorithm produced the pixels the RAW file has
        // been decoded with all along. Losing it here would mean revert
        // both writes an unpinned sidecar to disk AND immediately
        // re-decodes with "whatever's currently newest" instead of the
        // photo's original pin — silently reintroducing the exact
        // non-determinism this field exists to close, on every revert
        // after any future OS/Core Image update. So it's carried forward
        // explicitly instead of reset.
        var identity = EditState()
        identity.rawDecoderVersionPin = editState.rawDecoderVersionPin
        history.commit(identity, summary: "Revert to Original")
        applyHistoryState(history.current)
    }

    /// Applies a saved preset's color/tone "look" to the current photo
    /// (Phase 5 slice 2) — structurally identical to `revertToOriginal()`
    /// just above, for the exact same reason: flush any in-progress burst
    /// first, then commit `history` DIRECTLY so this is always its own
    /// atomic, immediately-committed undo step rather than risking a merge
    /// with a same-instant follow-up edit. `EditState.applyingPreset(onto:)`
    /// is what actually does the field-by-field merge — this method only
    /// wires that into the undo/sidecar-save machinery.
    func applyPreset(_ preset: Preset) {
        finalizePendingCommit()
        history.commit(preset.editState.applyingPreset(onto: editState), summary: "Preset: \(preset.name)")
        applyHistoryState(history.current)
    }

    /// Curves v2 slice 2B's "Reset Curve", extended in slice 3 to take
    /// WHICH curve — clears exactly `channel`'s own point array, leaving
    /// the other three (and the parametric Shadows/Highlights/Black Point
    /// layer) untouched. "Reset Adjustments" remains the clear-everything
    /// route. Structurally identical to `revertToOriginal()`/
    /// `applyPreset(_:)` just above, for the same reason: going through
    /// the debounced `editState` `didSet` path instead would leave a
    /// ~350ms window where a follow-up drag could merge into the same undo
    /// step as the reset.
    func resetToneCurve(_ channel: ToneCurveChannel) {
        finalizePendingCommit()
        var next = editState
        switch channel {
        case .composite: next.toneCurvePoints = []
        case .red: next.toneCurvePointsRed = []
        case .green: next.toneCurvePointsGreen = []
        case .blue: next.toneCurvePointsBlue = []
        }
        // Matches AdjustTabView's own "Reset Curve"/"Reset <Channel> Curve"
        // button label phrasing exactly, so the History row reads as the
        // same action the user just clicked.
        let summary = "Reset \(channel == .composite ? "Curve" : "\(channel.rawValue) Curve")"
        history.commit(next, summary: summary)
        applyHistoryState(history.current)
    }

    // MARK: - Sidecar Persistence

    /// Whether the current `editState` assignment is `load(from:)` applying
    /// a restored (or identity) state, not a real user edit — set/cleared
    /// around that one assignment. Keeps auto-save LAZY: opening a photo
    /// must never trigger a folder-access prompt on its own.
    private var isLoadingPhoto = false

    /// How long a pause in `editState` changes must last before the
    /// sidecar actually gets (re)written. Longer than `historyCoalesceInterval`
    /// (0.35s) — disk I/O doesn't need the same sub-second responsiveness
    /// undo-step boundaries or the live histogram redraw do. A UX "feel"
    /// constant, not a measured value.
    private static let sidecarSaveCoalesceInterval: TimeInterval = 1.0

    private var sidecarSaveWorkItem: DispatchWorkItem?

    /// The bookmark-resolve-or-request+`NSOpenPanel` logic this property
    /// used to own directly now lives in `SidecarFolderAccess`
    /// (`Sources/UI/`) — extracted so a planned batch paste feature can
    /// request/reuse the SAME persisted per-folder grants (`UserDefaults`
    /// key `"PhotoApp.sidecarFolderBookmarks"`, unchanged) for photos it
    /// writes that were never opened here. This is a behavior-preserving
    /// lift, not a rewrite — see that type's own doc comment.
    private let folderAccess: SidecarFolderAccessing

    /// `folderAccess` is injectable only so tests can model the modal folder-access panel (see
    /// `SidecarFolderAccessing`); the app always uses the real `SidecarFolderAccess`.
    init(folderAccess: SidecarFolderAccessing = SidecarFolderAccess()) {
        self.folderAccess = folderAccess
    }

    /// The exact panel message `SidecarFolderAccess.resolveOrRequest`
    /// shows on behalf of a save triggered from THIS type — unchanged
    /// text from before the extraction, since live-verification of the
    /// refactor depends on it staying byte-identical.
    private static let sidecarFolderAccessMessage =
        "PhotoApp would like to save your edits for photos in this folder. Choose the folder to grant access."

    /// Folders (by path) where the user CANCELLED a folder-access prompt
    /// this session — in-memory only, deliberately NOT persisted. Without
    /// this, every subsequent edit in a declined folder would re-prompt
    /// (a live-tested, genuinely bad UX: five slider drags means five
    /// dialogs) since a decline leaves no bookmark to short-circuit on.
    /// Suppresses re-prompting for the REST OF THIS SESSION only — a fresh
    /// launch asks again, giving the user another chance rather than
    /// permanently blocking a folder from one accidental cancel.
    private var declinedFolders: Set<String> = []

    /// Reviewer-caught: a batch settings-paste's own pre-flight uses a
    /// SEPARATE `SidecarFolderAccess` instance from this one (see that
    /// type's own doc comment for why sharing an instance isn't
    /// necessary — the persisted bookmark store is the same either way).
    /// But `declinedFolders` itself is NOT shared — it's this instance's
    /// own session-scoped memory. Without this escape hatch, a folder
    /// this instance already marked declined (from an earlier, unrelated
    /// edit) would keep silently skipping THIS photo's own sidecar save
    /// in `saveSidecarNow` even after the user just re-granted access to
    /// that exact folder during the paste's own pre-flight prompt —
    /// called from `PasteSettingsModel.performPaste` right before it
    /// applies a paste to the currently-open photo, for exactly that
    /// folder.
    func clearDeclinedFolder(_ folderPath: String) {
        declinedFolders.remove(folderPath)
    }

    /// The sidecar path for a given photo URL — same directory, original
    /// filename with `.photoapp.json` appended. Forwards to
    /// `SidecarStore.sidecarURL(for:)` (`Sources/Rendering/`), where the
    /// actual logic now lives — this one-line forwarder exists so
    /// `LibraryGridView`, `PhotoExporter`, and every existing test that
    /// calls this exact entry point keep working unchanged. `nonisolated`
    /// since it touches no actor-isolated state, so tests don't need
    /// `@MainActor` context to call it.
    nonisolated static func sidecarURL(for url: URL) -> URL {
        SidecarStore.sidecarURL(for: url)
    }

    /// Loads a photo's sidecar, if one exists AND we can currently reach
    /// it. Deliberately does NOT prompt for folder access — load must stay
    /// silent; only a real save attempt (via `saveSidecarNow`) may prompt.
    /// A missing bookmark, missing sidecar, or undecodable sidecar are all
    /// treated identically here: no saved edits to restore, not an error.
    /// A read-modify-WRITE caller cannot collapse them the same way,
    /// though — it must NOT treat "undecodable" as "identity," since that
    /// would silently clobber an existing sidecar it couldn't parse; see
    /// `SidecarStore.ReadResult`'s own doc comment.
    private func loadSidecarIfReachable(for url: URL) -> EditState? {
        guard let folderURL = folderAccess.resolvedURL(for: url.deletingLastPathComponent()) else { return nil }
        guard folderURL.startAccessingSecurityScopedResource() else { return nil }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        guard case .decoded(let state) = SidecarStore.read(forPhotoAt: url) else { return nil }
        return state
    }

    /// `SidecarStore.readHistory` for `url`, run off the main thread inside the folder's security scope. nil when the folder
    /// is not reachable (load must stay silent) or the photo has no usable persisted history.
    private func loadPersistedHistory(for url: URL) async -> (archive: HistoryArchive, encoder: HistoryArchive.Encoder)? {
        guard let folderURL = folderAccess.resolvedURL(for: url.deletingLastPathComponent()),
              folderURL.startAccessingSecurityScopedResource() else { return nil }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        return await Task.detached(priority: .userInitiated) {
            guard let archive = SidecarStore.readHistory(forPhotoAt: url) else { return nil }
            // Warm the encoder's per-entry cache HERE: a fresh one would re-encode (base64 + SHA-256 of every mask blob) the
            // whole restored timeline on the MAIN thread at the first save after the user's next edit.
            let encoder = HistoryArchive.Encoder()
            _ = encoder.jsonObject(for: archive)
            return (archive, encoder)
        }.value
    }

    private func scheduleSidecarSave() {
        sidecarSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            // Clear FIRST — without this, `flushPendingSidecarSave()`'s
            // `sidecarSaveWorkItem != nil` guard stays true forever after
            // the very first edit of the session (this work item firing on
            // its own never resets it), making every later `load(from:)`
            // redundantly re-invoke `saveSidecarNow()` even for an
            // untouched photo — silently breaking the "auto-save only
            // happens after a real edit" contract.
            self?.sidecarSaveWorkItem = nil
            self?.saveSidecarNow()
        }
        sidecarSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidecarSaveCoalesceInterval, execute: workItem)
    }

    /// Called from `load(from:)` before switching to a new photo, so the
    /// OUTGOING photo's last ~1s of unsaved edits aren't dropped. Not
    /// `private` — `ContentView` also calls this when leaving the Editor
    /// for the Library, so a just-undone/edited photo's sidecar (and
    /// therefore its Library thumbnail, via `onSidecarSaved`) is actually
    /// up to date by the time the grid appears, rather than possibly
    /// still sitting in the ~1s debounce window.
    func flushPendingSidecarSave() {
        guard sidecarSaveWorkItem != nil else { return }
        sidecarSaveWorkItem?.cancel()
        sidecarSaveWorkItem = nil
        // End a burst still inside its ~350ms coalescing window FIRST, so the history this save embeds is not one step behind
        // the edits it saves (a save whose history lags the state is written without history — the trail would be lost).
        finalizePendingCommit()
        saveSidecarNow()
    }

    /// Resolves (or lazily requests) folder access, then encodes and writes
    /// the current `editState` to its sidecar. Declining a folder-access
    /// prompt is silent (not an error); a resolution or write FAILURE after
    /// access was actually granted surfaces via `sidecarSaveErrorMessage`
    /// — unless `suppressErrorMessage` is set, for the one caller
    /// (the Phase 6 slice 7 decoder-version-pin backfill in `load(from:)`)
    /// where the save is an automatic side effect of merely OPENING a
    /// photo, not a user-initiated edit; surfacing "Couldn't save edits"
    /// from just viewing a never-touched RAW photo on a read-only volume
    /// would violate this app's own "opening a photo should never itself
    /// produce an error/prompt" invariant. Skips re-prompting entirely for
    /// a folder already declined this session (see `declinedFolders`).
    private func saveSidecarNow(suppressErrorMessage: Bool = false) {
        // Snapshot the (photo, edits) PAIR together, FIRST, before anything below can yield to the run loop.
        // `resolveOrRequest` may show a modal `NSOpenPanel`, which pumps the run loop, so `currentURL`/`editState`
        // could change while it is up (IMPROVEMENTS.md D28: a photo load finishing there). The old code read
        // `editState` AFTER that step and would have written the NEW state into the OLD photo's sidecar. The
        // snapshot writes the old photo's own state to the old photo's own sidecar — what the user meant to save.
        // Whether a real `load(from:)` can finish inside the panel is UNDETERMINED (see `SaveSidecarRaceTests`'
        // header for what was and was not reproduced), so this is hardening, not a fix for an observed corruption.
        guard let url = currentURL else { return }
        let snapshot = editState
        // The history rides in the same snapshot (a value type): written only when it belongs to THIS photo and is exactly
        // in step with the saved state — otherwise the sidecar is written without `_history` (never a stale one).
        let historySnapshot = history
        let historyBelongsHere = historyURL == url && historySnapshot.entries.count > 1 && historySnapshot.current == snapshot
        let folder = url.deletingLastPathComponent()
        guard !declinedFolders.contains(folder.path) else { return }
        let folderURL: URL
        switch folderAccess.resolveOrRequest(for: folder, message: Self.sidecarFolderAccessMessage) {
        case .granted(let granted):
            folderURL = granted
        case .declined:
            declinedFolders.insert(folder.path)
            return
        case .failed(let error):
            // Matches the original `requestFolderAccess`'s own behavior:
            // this surfaces UNCONDITIONALLY, not gated by
            // `suppressErrorMessage` — a genuine bookmark-creation failure
            // AFTER the user already granted access is a real, unexpected
            // error, not the "opening a photo shouldn't itself produce an
            // error" case `suppressErrorMessage` exists for.
            sidecarSaveErrorMessage = "Couldn't save edits: \(error.localizedDescription)"
            return
        }
        guard folderURL.startAccessingSecurityScopedResource() else {
            if !suppressErrorMessage {
                sidecarSaveErrorMessage = "Couldn't save edits: access to the containing folder is no longer available."
            }
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        do {
            if historyBelongsHere, let historyObject = historyEncoder.jsonObject(for: HistoryArchive(historySnapshot)) {
                try SidecarStore.write(snapshot, historyObject: historyObject, forPhotoAt: url)
            } else {
                try SidecarStore.write(snapshot, forPhotoAt: url)
            }
            onSidecarSaved?(url)
        } catch {
            if !suppressErrorMessage {
                sidecarSaveErrorMessage = "Couldn't save edits: \(error.localizedDescription)"
            }
        }
    }

    /// What `pasteSettings(_:)` actually did, so a batch-paste summary can
    /// count this photo accurately instead of assuming every call wrote.
    /// Reviewer-caught: the ORIGINAL version returned `Void`, so
    /// `PasteSettingsModel.performPaste` unconditionally counted the open
    /// photo as "written" — wrong both for a true no-op merge (should
    /// count as `unchanged`, same as any other target) and for a folder
    /// already in `declinedFolders` this session (the in-memory edit still
    /// applies, matching ordinary editing's own "declining persistence
    /// doesn't block editing" behavior, but nothing reaches disk, so it
    /// should count as `skipped`, not `written`). Does NOT distinguish a
    /// genuine write failure after a GRANTED folder access from a real
    /// success — those are rare, already surfaced separately via
    /// `sidecarSaveErrorMessage`, and folding them in here would need
    /// deeper plumbing than this fix's own scope; a documented, accepted
    /// imprecision, not silently ignored.
    enum PasteSettingsResult {
        case written
        case unchanged
        case skipped
    }

    /// Merges a copied photo's "look" onto the current `editState`
    /// (`EditState.applyingPreset(onto:)` — the SAME merge Presets already
    /// use, deliberately not a second hand-maintained field list) and
    /// commits the result as one atomic, immediately-saved undo step —
    /// this is the "Paste Settings" path for whichever target photo is
    /// ALSO the one currently open here, kept structurally identical to
    /// `applyPreset(_:)` for exactly the same reason: an in-progress burst
    /// must be flushed first, and the paste must be its own atomic commit,
    /// not merged into a same-instant follow-up edit.
    ///
    /// Unlike `applyPreset(_:)`, this ALSO guards against a no-op
    /// (`merged == editState`, e.g. pasting a photo's own copied settings
    /// back onto itself): `EditHistory.commit`'s own no-op guard already
    /// prevents a phantom UNDO step, but `applyHistoryState` unconditionally
    /// assigns `editState`, firing `didSet` → a scheduled sidecar save even
    /// when nothing actually changed — the exact spurious-write hazard
    /// `EditHistory.jump(to:)`'s own doc comment already documents for the
    /// History panel's no-op-tap case. Explicitly NEVER called by the
    /// batch paste path for any OTHER target photo — those are written
    /// directly to disk via `SidecarStore`/`SidecarFolderAccess` instead,
    /// precisely so this photo's own undo history/debounced-save path
    /// stays authoritative and never gets bypassed underneath it.
    ///
    /// Callers (`ContentView`'s confirmation-dialog button, via
    /// `PasteSettingsModel.performPaste`'s own `canProceed`/
    /// `applyToOpenPhoto` checks) re-verify this IS still the open photo
    /// (`document.currentURL?.path ==` the path captured at confirm-time)
    /// before calling this — a NEW load can start during `performPaste`'s
    /// own folder-access `NSOpenPanel` prompting (which pumps the modal
    /// run loop) even though `isLoadInFlight` was confirmed false at
    /// confirm-time. See `PasteSettingsModel.performPaste`'s own doc
    /// comment for the full, three-round story of this specific race.
    @discardableResult
    func pasteSettings(_ source: EditState) -> PasteSettingsResult {
        finalizePendingCommit()
        let merged = source.applyingPreset(onto: editState)
        guard merged != editState else {
            // Reviewer-caught: even on this no-op-merge path, a burst still
            // in flight just before this call (a slider drag settling)
            // could have already scheduled its OWN ~1s-debounced sidecar
            // save via `editState`'s own `didSet` — `finalizePendingCommit()`
            // above only moves that burst into `history`, it does NOT
            // itself write or reschedule a save. Flush now rather than
            // silently leaving that earlier save sitting in its debounce
            // window, since this whole method's own point is "write now,
            // don't make the caller wait."
            flushPendingSidecarSave()
            return .unchanged
        }
        history.commit(merged, summary: "Paste Settings")
        applyHistoryState(history.current)
        // Write NOW, not after the usual ~1s debounce — intended for a
        // Library batch-paste action the caller is actively watching for a
        // result (its own summary alert/thumbnail refresh should reflect
        // this photo's state immediately, not up to a second later).
        flushPendingSidecarSave()
        if let currentURL, declinedFolders.contains(currentURL.deletingLastPathComponent().path) {
            return .skipped
        }
        return .written
    }
}
