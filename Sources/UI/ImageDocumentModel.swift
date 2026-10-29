import AppKit
import CoreImage
import UniformTypeIdentifiers

/// Owns the currently displayed image state. Only ever reads image files —
/// never writes to originals, preserving the app's non-destructive invariant.
@MainActor
final class ImageDocumentModel: ObservableObject {
    @Published private(set) var currentImage: CIImage? {
        didSet { imageRevision += 1 }
    }

    /// Bumped every time `currentImage` is replaced (a photo load, a RAW re-decode). Consumers that cache something derived
    /// from the pixels — the Looks tab's preview base — compare it to know their cache is stale.
    @Published private(set) var imageRevision = 0
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
    /// Which VERSION of `currentURL`'s file is open: nil for the master (its edits live in `<file>.photoapp.json`, exactly as before virtual
    /// copies), a copy's `versionKey` otherwise (`<file>.<versionKey>.photoapp.json`). Set together with `currentURL`, in `load`.
    @Published private(set) var currentVersionKey: String?
    /// `Photo.editKey` of the open version (the path for a master): what "which edit set is open" comparisons must use instead of the path.
    var currentEditKey: String? { currentURL.map { Photo.editKey(path: $0.path, versionKey: currentVersionKey) } }
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
    /// The same notification for a virtual COPY's sidecar (the file URL and the copy's version key), so the Library can invalidate that
    /// version's thumbnail only. `onSidecarSaved` stays master-only: its callers (and tests) predate versions.
    var onVersionSidecarSaved: ((URL, String) -> Void)?

    /// Called at the very start of `load(from:)`, BEFORE the outgoing photo's pending edits are flushed and before `editState` is replaced, so the
    /// Editor can drop an unfinished placeholder (an armed, never-painted Brush mask, an unpicked Color Range mask or Point Color instance) from
    /// the OUTGOING photo instead of leaving it in that photo's sidecar (IMPROVEMENTS.md D13). Every route that opens a photo goes through
    /// `load(from:)` (grid, filmstrip, ⌘←/⌘→, Open…, culling), so this one hook covers them all.
    var willSwitchPhoto: (() -> Void)?
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
    /// refreshed after every history operation. Drives the rail's Undo/Redo
    /// entries' enabled state.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Mirrors `EditHistory`'s own `entries`/`currentIndex` as `@Published`
    /// properties, for the History panel (`HistoryPopoverView`, opened
    /// from the toolbar) — same reasoning as `canUndo`/`canRedo` just above: SwiftUI
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
    /// Shown by the Crop tab's own alert — `autoStraighten` outcomes that changed nothing (no horizon, already level, failure).
    @Published var straightenMessage: String?
    /// True while Vision is looking for the horizon (single-flight: disables the Crop tab's Auto button).
    @Published private(set) var isAutoStraightening = false
    /// Shown by its own alert — `generateDepth` outcomes (Depth Range mask).
    @Published var depthMaskMessage: String?
    /// True while a depth map is being read or computed (single-flight: disables the Depth buttons).
    @Published private(set) var isGeneratingDepth = false
    /// Which depth sources exist for the open photo (embedded iPhone depth in its file; the bundled model). Refreshed when a photo loads.
    @Published private(set) var depthAvailability = DepthMapGenerator.Availability(embedded: false, model: DepthModelRunner.isInstalled)

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

    /// Shown by the Crop tab's own alert: `autoCrop` outcomes that changed nothing (no empty corners, too large, failure).
    @Published var autoCropMessage: String?
    /// True while the empty corners are being measured (single-flight: disables the Crop tab's Auto Crop, Auto and Upright buttons).
    @Published private(set) var isAutoCropping = false

    /// Shown by the Crop tab's own alert: Upright outcomes that changed nothing (no lines, already upright, failure).
    @Published var uprightMessage: String?
    /// The Upright mode being measured right now (nil when idle): the pressed button shows its progress label.
    @Published private(set) var runningUprightMode: UprightMode?
    var isAutoUprighting: Bool { runningUprightMode != nil }
    /// Test seam: the Upright line detector, run off the main actor on the photo's UNEDITED, oriented source image.
    var uprightDetector: @Sendable (CIImage) -> UprightDetector.Result = { UprightDetector.detect(in: $0) }

    // MARK: - Undo/Redo state

    private var history = EditHistory()
    /// Whose history `history` is (the photo it was reset/restored for) — so a save can never embed one photo's history in
    /// ANOTHER photo's sidecar (the one window where they differ: `load(from:)` between `currentURL = url` and the reset).
    private var historyEditKey: String?

    /// D81: the edit key (`Photo.editKey`) of the open photo whose on-disk sidecar THIS load decoded or this model has
    /// since written. `saveSidecarNow` refuses to replace an existing sidecar unless this matches: a sidecar the Editor
    /// never loaded (unreachable at open, undecodable, written by someone else meanwhile) must never be overwritten.
    /// Reset on every successful `load`. Consequence (accepted): a photo whose sidecar could not be loaded (undecodable, or
    /// unreadable at open) stays UNSAVEABLE until it is reopened and the file loads; the user is told once per load.
    /// Narrow, accepted window (pre-existing): the file is read at the START of a load, before its decode awaits, so a
    /// foreign write inside that gap is still overwritable. A save also re-checks ownership after the access panel (a
    /// same-photo reload inside it clears ownership), but a reload that wins the race against the save is the only
    /// residual stale window.
    private var sidecarOwnedEditKey: String?
    /// Test seam for `sidecarOwnedEditKey` (simulates a load finishing while the folder-access panel is up). Never call
    /// from production code.
    var sidecarOwnedEditKey_forTesting: String? {
        get { sidecarOwnedEditKey }
        set { sidecarOwnedEditKey = newValue }
    }
    /// Test seam: what a finished `load` of `url` leaves behind (current photo + ownership). Never call from production code.
    func simulateLoadFinishedForTesting(url: URL, ownedKey: String?) {
        currentURL = url
        currentVersionKey = nil
        sidecarOwnedEditKey = ownedKey
    }
    /// Test seam: settles any pending history burst, then saves immediately (what `flushPendingSidecarSave` does).
    func saveSidecarNowForTesting(suppressErrorMessage: Bool = false) {
        finalizePendingCommit()
        saveSidecarNow(suppressErrorMessage: suppressErrorMessage)
    }
    /// The edit key whose save was already refused this load: the alert is shown ONCE; later saves for that key stay
    /// silent and skip the write (and the disk re-read). Cleared on every successful `load`.
    private var refusedEditKey: String?
    /// Whether the open photo's edits are reaching disk — the persistent counterpart of the once-per-load alert. Set wherever a
    /// save fails to land (both D81 refusals, silent or not; a declined folder; a write error) and cleared by the next successful
    /// write for the open photo or a load, which recomputes it for the NEW photo (`declinedFolders` outlives photo switches).
    @Published private(set) var sidecarSaveStatus: SidecarSaveStatus = .ok
    /// Sets the status only while `url`/`versionKey` is still the open photo: a save snapshot can outlive a photo switch (the
    /// access panel pumps the run loop), and its outcome must not overwrite the NEW photo's status.
    private func publishSaveStatus(_ status: SidecarSaveStatus, forPhotoAt url: URL, versionKey: String?) {
        guard currentURL == url, currentVersionKey == versionKey else { return }
        sidecarSaveStatus = status
    }
    /// The status a freshly opened (or re-granted) photo starts with: only a declined folder is known without attempting a save.
    private func baselineSaveStatus() -> SidecarSaveStatus {
        guard let currentURL, declinedFolders.contains(currentURL.deletingLastPathComponent().path) else { return .ok }
        return .folderDeclined
    }
    /// The open photo's edit file (master or virtual copy), for the status chip's help and Show in Finder.
    var currentSidecarURL: URL? {
        currentURL.flatMap { SidecarStore.versionedSidecarURL(for: $0, versionKey: currentVersionKey) }
    }
    /// The chip's "Try Again": settles any pending burst and saves now (a pending debounced save is superseded).
    func retrySidecarSave() {
        endTargetedDrag() // may schedule a save: do it BEFORE cancelling so no redundant delayed save fires afterwards
        sidecarSaveWorkItem?.cancel()
        sidecarSaveWorkItem = nil
        finalizePendingCommit()
        saveSidecarNow()
    }
    /// The chip's "Grant Access…": forgets this session's decline for the open photo's folder, then saves (which asks again).
    func grantAccessAndRetrySidecarSave() {
        if let currentURL { clearDeclinedFolder(currentURL.deletingLastPathComponent().path) }
        retrySidecarSave()
    }
    /// The chip's "Reload": re-reads the open photo's edit file, discarding in-memory edits made since it was opened.
    func reloadCurrentPhotoFromSidecar() async {
        guard let url = currentURL else { return }
        await load(from: url, versionKey: currentVersionKey)
    }
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

    /// Shows the file panel and returns the chosen photo, or nil on Cancel. Split from the load so the caller can switch to the
    /// Editor BEFORE the (possibly slow, RAW) load starts and its loading indicator is visible: `Open…` lives in the Library
    /// toolbar, and without that switch the photo opened into the hidden Editor while the Library grid stayed on screen, which
    /// looked like nothing had happened.
    func chooseImageURL() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .heic, .rawImage]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// Chooses a photo and loads it (kept for callers that do not need to switch views first).
    func openImage() async {
        guard let url = chooseImageURL() else { return }
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

    /// Opens one catalog row: the master, or a virtual copy (the same file with that copy's own edits).
    func load(photo: Photo) async {
        await load(from: URL(fileURLWithPath: photo.path), versionKey: photo.versionKey)
    }

    func load(from url: URL, versionKey: String? = nil) async {
        endTargetedDrag() // commit to the photo being left, before its state is replaced
        willSwitchPhoto?()
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
        let existingSidecarState = loadSidecarIfReachable(for: url, versionKey: versionKey)
        // The photo's persisted edit history (sidecar `_history`), if any and still consistent with its edits. Read OFF the
        // main thread (decoding re-serialises every entry — hundreds of ms with a big mask).
        let persistedHistory = existingSidecarState == nil ? nil : await loadPersistedHistory(for: url, versionKey: versionKey)
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
        currentVersionKey = versionKey
        refusedEditKey = nil
        sidecarOwnedEditKey = existingSidecarState == nil ? nil : Photo.editKey(path: url.path, versionKey: versionKey)
        sidecarSaveStatus = baselineSaveStatus()
        refreshDepthAvailability()
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

        let samplingState = editState.geometryOnlySamplingState()

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
        // The Style's texture/grain are detail stages too: left on they would put noise/blur into the eyedropper sample.
        samplingState.styleTexture = ""
        samplingState = samplingState.zeroingGrain() // the Grain slider, the Style's Grain toggle and B&W Grain
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

    // MARK: - Targeted adjustment

    /// What a Targeted adjustment drag needs, fixed at drag start (the sample is read ONCE: no per-move render). Only the fields the
    /// tool touches are ever written, always onto the CURRENT `editState`, so no other edit is ever overwritten by a stale snapshot.
    private struct TargetedDrag {
        let tool: TargetedTool
        var curve: TargetedAdjustmentMath.CurveDrag?
        var bandWeights: [Double] = []
        var bandKeyPaths: [WritableKeyPath<EditState, Double>] = []
        /// The touched bands' values when the drag began.
        var startBandValues: [Double] = []
        /// What the last update wrote into the touched fields (nil until the first write): `cancelTargetedDrag` restores the
        /// start values only while the fields still hold exactly this.
        var lastWrittenPoints: [ToneCurvePoint]?
        var lastWrittenBands: [Double]?
        var hasWritten: Bool { lastWrittenPoints != nil || lastWrittenBands != nil }
    }

    /// While non-nil, mid-drag history coalescing is suppressed (`recordEditChange`). Cleared by `endTargetedDrag`,
    /// `cancelTargetedDrag`, `resetHistory` and, through `finalizePendingCommit`, by every other edit path.
    private var targetedDrag: TargetedDrag?

    /// True from a successful `beginTargetedDrag` until `endTargetedDrag`/`cancelTargetedDrag`.
    var isTargetedDragActive: Bool { targetedDrag != nil }

    /// Test seam: replaces the pixel read of `beginTargetedDrag`. Receives the stage to stop at and the normalized tap
    /// (fractions of the displayed photo, y top-down, like every other sampler here); returns the PERCEPTUAL sample or nil.
    var targetSampler: ((EditPipeline.ColorSampleTruncation, Double, Double) -> (r: Double, g: Double, b: Double)?)?

    /// Starts a Targeted adjustment drag at a normalized point of the displayed photo. Samples once, through the real pipeline
    /// stopped at the target stage's own input (exact only at identity geometry, so it refuses otherwise), and chooses what the
    /// drag will change. Returns false (and changes nothing) when there is no photo, a load is in flight, a drag is already
    /// running, the geometry is not identity, B&W Mix is asked for while Black & White is off, the pixel can't be read, or
    /// (colour tools) the pixel is neutral so no band owns it. A refused start is silent: there is no lightweight status channel
    /// here (`whiteBalanceSampleMessage` is a modal alert, too heavy to raise on every press).
    ///
    /// Any pending coalesced burst is committed first so it stays its own undo step, and mid-drag history coalescing is
    /// suppressed so a slow drag is exactly ONE step (`endTargetedDrag`).
    @discardableResult
    func beginTargetedDrag(tool: TargetedTool, normalizedX u: Double, normalizedY v: Double) -> Bool {
        guard targetedDrag == nil, !isLoadInFlight, editState.isGeometryAtIdentity else { return false }
        if tool == .grayMix, !editState.blackAndWhite { return false }
        let sample: (r: Double, g: Double, b: Double)?
        if let targetSampler {
            sample = targetSampler(tool.sampleTruncation, u, v)
        } else {
            sample = sampleForTargetedDrag(tool: tool, normalizedX: u, normalizedY: v)
        }
        guard let sample, sample.r.isFinite, sample.g.isFinite, sample.b.isFinite else { return false }

        finalizePendingCommit()
        // A coalescing item scheduled before this drag must not fire into it.
        historyCommitWorkItem?.cancel()
        var drag = TargetedDrag(tool: tool)
        switch tool {
        case .curve:
            let x = TargetedAdjustmentMath.curveX(forPerceptualRGB: sample.r, sample.g, sample.b)
            guard let curve = TargetedAdjustmentMath.CurveDrag(points: editState.toneCurvePoints, x: x) else { return false }
            drag.curve = curve
        case .selectiveColor(let property):
            let (hue, saturation) = PointColorSelection.hueSaturation(forPerceptualRGB: sample.r, sample.g, sample.b)
            guard hue.isFinite, saturation.isFinite else { return false }
            drag.bandWeights = SelectiveColorBandWeights.selectiveColorWeights(
                hue: hue, saturation: saturation, range: editState.selectiveColorRange)
            drag.bandKeyPaths = SelectiveColorBandWeights.selectiveColorKeyPaths(for: property)
        case .grayMix:
            let (hue, saturation) = PointColorSelection.hueSaturation(forPerceptualRGB: sample.r, sample.g, sample.b)
            guard hue.isFinite, saturation.isFinite else { return false }
            drag.bandWeights = SelectiveColorBandWeights.grayMixWeights(hue: hue, saturation: saturation)
            drag.bandKeyPaths = SelectiveColorBandWeights.grayMixKeyPaths
        }
        if tool != .curve {
            guard TargetedAdjustmentMath.bandDeltas(weights: drag.bandWeights, delta: 1) != nil else { return false }
            drag.startBandValues = drag.bandKeyPaths.map { editState[keyPath: $0] }
        }
        targetedDrag = drag
        return true
    }

    /// Real sampling for `beginTargetedDrag`: the same truncated render and 5x5 average `pickPointColorTarget` uses.
    private func sampleForTargetedDrag(tool: TargetedTool, normalizedX u: Double, normalizedY v: Double) -> (r: Double, g: Double, b: Double)? {
        guard let currentImage else { return nil }
        let sampled = EditPipeline.apply(editState, to: currentImage, truncatingColorAt: tool.sampleTruncation)
        let extent = sampled.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let point = CGPoint(x: extent.minX + CGFloat(u) * extent.width, y: extent.minY + CGFloat(1 - v) * extent.height)
        guard let color = PixelSampler.averageColor(in: sampled, at: point) else { return nil }
        return (Double(color.r), Double(color.g), Double(color.b))
    }

    /// Applies a drag of `delta` (upward positive, in the control's own units: curve y or a -1...1 slider). The result depends
    /// only on the current delta and the values the touched fields had at drag start (not on the path), and ONLY those fields
    /// are written, onto the current `editState`. No history entry is made here.
    func updateTargetedDrag(delta: Double) {
        guard var drag = targetedDrag, delta.isFinite else { return }
        var next = editState
        switch drag.tool {
        case .curve:
            guard let curve = drag.curve else { return }
            let points = curve.points(forDelta: delta)
            next.toneCurvePoints = points
            drag.lastWrittenPoints = points
        case .selectiveColor, .grayMix:
            guard let deltas = TargetedAdjustmentMath.bandDeltas(weights: drag.bandWeights, delta: delta) else { return }
            let values = TargetedAdjustmentMath.bandValues(start: drag.startBandValues, deltas: deltas)
            for (keyPath, value) in zip(drag.bandKeyPaths, values) { next[keyPath: keyPath] = value }
            drag.lastWrittenBands = values
        }
        targetedDrag = drag
        if next != editState { editState = next }
    }

    /// Ends the drag with ONE labelled history step ("Targeted Curve", "Targeted Saturation", ...), or none when it netted no
    /// change, and schedules the sidecar save so the persisted `_history` includes the step. Every other edit path (undo, redo,
    /// History jump, Revert, preset, paste, Auto Tone, photo switch, flush) ends an active drag first through
    /// `finalizePendingCommit`/`load`/`flushPendingSidecarSave`, so a drag never straddles another edit.
    ///
    /// The step holds ONLY the drag's own fields: a change to any other field that landed mid-drag without passing through
    /// `finalizePendingCommit` (an async writer such as Fix Color Cast) is not folded into the "Targeted ..." row; it is left as
    /// a pending burst and committed as its own step.
    func endTargetedDrag() {
        guard let drag = targetedDrag else { return }
        targetedDrag = nil
        if drag.hasWritten {
            var dragOnly = history.current
            copyTargetedFields(of: drag, from: editState, to: &dragOnly)
            if dragOnly != history.current {
                history.commit(dragOnly, summary: drag.tool.historySummary)
                refreshHistoryState()
                scheduleSidecarSave()
            }
        }
        recordUncommittedChangeIfAny()
    }

    /// Abandons the drag (Esc is NOT this: it ends the drag; this is for callers that must discard it): puts the touched fields
    /// back to their drag-start values with no history step, but ONLY while they still hold what the drag last wrote. Anything
    /// else changed them since, so the later edit wins and nothing is restored. The other fields are never touched. Whatever
    /// differs from the history afterwards (a later edit made while the drag suppressed coalescing) is recorded as its own burst.
    func cancelTargetedDrag() {
        guard let drag = targetedDrag else { return }
        targetedDrag = nil
        defer { recordUncommittedChangeIfAny() }
        var restored = editState
        switch drag.tool {
        case .curve:
            guard let written = drag.lastWrittenPoints, editState.toneCurvePoints == written, let curve = drag.curve else { return }
            restored.toneCurvePoints = curve.startPoints
        case .selectiveColor, .grayMix:
            guard let written = drag.lastWrittenBands, drag.bandKeyPaths.map({ editState[keyPath: $0] }) == written else { return }
            for (keyPath, value) in zip(drag.bandKeyPaths, drag.startBandValues) { restored[keyPath: keyPath] = value }
        }
        isApplyingHistoryChange = true
        editState = restored
        isApplyingHistoryChange = false
    }

    /// Copies the fields a drag touches (and only those) between two states.
    private func copyTargetedFields(of drag: TargetedDrag, from source: EditState, to target: inout EditState) {
        switch drag.tool {
        case .curve:
            target.toneCurvePoints = source.toneCurvePoints
        case .selectiveColor, .grayMix:
            for keyPath in drag.bandKeyPaths { target[keyPath: keyPath] = source[keyPath: keyPath] }
        }
    }

    /// While a drag runs, `recordEditChange` is suppressed, so an edit that landed meanwhile has no pending burst. Once the drag
    /// is over, make sure any state that differs from the history is committed (as its own step) instead of being left unrecorded.
    private func recordUncommittedChangeIfAny() {
        if editState != history.current, !isBurstPending {
            recordEditChange()
            scheduleSidecarSave()   // so the later commit of this change is saved WITH its history
        }
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

    // MARK: - Auto Straighten

    /// Test seam: the horizon detector, run off the main actor on the photo's UNEDITED, oriented source image.
    var horizonDetector: @Sendable (CIImage) -> HorizonDetector.Result = { HorizonDetector.detect(in: $0) }

    /// Detects the horizon with Vision and sets `straightenAngle` as ONE undo step ("Auto Straighten").
    /// Vision sees `currentImage` itself, with NO edit geometry: Straighten is the pipeline's FIRST geometry
    /// stage, so the angle must be measured on the source (a flip would negate the tilt, Stretch would change
    /// slopes, perspective/crop would distort them). Because the measurement never includes the current angle,
    /// a second press gives the same result rather than a doubled correction. Same stale-result guard as
    /// `autoTone()`. Returns the work for tests; the UI ignores it.
    @discardableResult
    func autoStraighten() -> Task<Void, Never>? {
        guard !isAutoStraightening, !isAutoUprighting, !isAutoCropping else { return nil }
        guard let currentImage, !isLoadInFlight else {
            straightenMessage = "Wait for the photo to finish loading, then try again."
            return nil
        }
        isAutoStraightening = true
        let detector = horizonDetector
        let myGeneration = analysisGeneration
        // Straighten acts on the ROTATED frame, so the horizon is measured there (a 90° turn swaps the axes).
        let measuredTurns = editState.rotationQuarterTurns
        let source = QuarterTurn.apply(measuredTurns, to: currentImage)
        return Task { @MainActor [weak self] in
            let detection = await Task.detached(priority: .userInitiated) { () -> HorizonDetector.Result in
                detector(source)
            }.value
            guard let self else { return }
            self.isAutoStraightening = false
            // A photo load in flight means `currentImage`/`editState` are about to be replaced (the generation only
            // bumps when the load finishes), so this result belongs to the outgoing photo.
            guard self.analysisGeneration == myGeneration, !self.isLoadInFlight else { return }
            guard self.editState.rotationQuarterTurns == measuredTurns else {
                self.straightenMessage = StraightenMessages.rotatedMeanwhile
                return
            }
            let outcome: StraightenSolver.Outcome
            switch detection {
            case .failed(let reason):
                self.straightenMessage = reason
                return
            case .none:
                outcome = .noHorizon
            case .angle(let radians):
                outcome = StraightenSolver.solve(visionHorizonAngle: radians)
            }
            let target: Double
            switch outcome {
            case .noHorizon:
                self.straightenMessage = StraightenMessages.noHorizon
                return
            case .alreadyLevel:
                target = 0 // measured on the uncorrected source, so "level" means Straighten should be 0
            case .angle(let degrees):
                target = degrees
            }
            self.finalizePendingCommit()
            guard self.editState.straightenAngle != target else {
                self.straightenMessage = target == 0 ? StraightenMessages.alreadyLevel : StraightenMessages.alreadyApplied
                return
            }
            var next = self.editState
            next.straightenAngle = target
            self.history.commit(next, summary: "Auto Straighten")
            self.applyHistoryState(self.history.current)
        }
    }

    // MARK: - Auto Crop

    /// Test seam: measures which pixels of the photo's post-geometry frame are opaque. Runs off the main actor on the
    /// photo's UNEDITED source (`currentImage`) with the edit state at the press (only its geometry matters).
    var autoCropMaskProvider: @Sendable (CIImage, EditState) async -> AutoCropMask? = { await AutoCropMaskRenderer.measure(image: $0, state: $1) }

    /// Sets the four crop insets to the largest axis-aligned rectangle that contains no transparent pixel after the photo's
    /// current geometry (rotation, straighten, perspective, scale / stretch, flip), as ONE undo step ("Auto Crop"). It REPLACES
    /// any existing crop (the measurement ignores it). `aspectRatio` (width / height of the post-geometry frame) fits that ratio
    /// centred inside the found rectangle. Never automatic: only the Crop tab's button calls it. Same guards as
    /// `autoStraighten()`: single-flight (also against Auto Straighten / Upright), `analysisGeneration` and `isLoadInFlight`
    /// staleness, plus: nothing changes if the geometry was edited while measuring. Returns the work for tests.
    @discardableResult
    func autoCrop(aspectRatio: Double?) -> Task<Void, Never>? {
        guard !isAutoCropping, !isAutoStraightening, !isAutoUprighting else { return nil }
        guard let currentImage, !isLoadInFlight else {
            autoCropMessage = "Wait for the photo to finish loading, then try again."
            return nil
        }
        isAutoCropping = true
        let provider = autoCropMaskProvider
        let myGeneration = analysisGeneration
        let measuredState = editState
        let measuredGeometry = AutoCropMaskRenderer.measuringState(for: measuredState)
        return Task { @MainActor [weak self] in
            let measured = await Task.detached(priority: .userInitiated) { () -> AutoCropMask? in
                await provider(currentImage, measuredState)
            }.value
            guard let self else { return }
            self.isAutoCropping = false
            guard self.analysisGeneration == myGeneration, !self.isLoadInFlight else { return }
            guard AutoCropMaskRenderer.measuringState(for: self.editState) == measuredGeometry else {
                self.autoCropMessage = AutoCropMessages.changedMeanwhile
                return
            }
            guard let measured else {
                self.autoCropMessage = AutoCropMessages.unmeasurable
                return
            }
            let insets: AutoCropSolver.Insets
            switch AutoCropSolver.solve(measured, aspectRatio: aspectRatio) {
            case .nothingToCrop:
                self.autoCropMessage = AutoCropMessages.nothingToCrop
                return
            case .tooLarge:
                self.autoCropMessage = AutoCropMessages.tooLarge
                return
            case .empty:
                self.autoCropMessage = AutoCropMessages.unmeasurable
                return
            case .cropped(let found):
                insets = found
            }
            self.finalizePendingCommit()
            var next = self.editState
            next.cropInsetTop = insets.top
            next.cropInsetBottom = insets.bottom
            next.cropInsetLeft = insets.left
            next.cropInsetRight = insets.right
            guard next != self.editState else {
                self.autoCropMessage = AutoCropMessages.alreadyApplied
                return
            }
            self.history.commit(next, summary: "Auto Crop")
            self.applyHistoryState(self.history.current)
        }
    }

    // MARK: - Rotate 90°

    enum RotateDirection { case left, right }

    /// One-line note after a rotation that is only approximate for perspective / Stretch (they act on the rotated
    /// picture; radial / linear / brush masks and red-eye points DO turn with it). Nil otherwise.
    @Published var rotationHint: String?

    /// Rotate Left / Rotate Right: ONE undo step ("Rotate Left" / "Rotate Right"), saved like every direct commit.
    /// The turn count, the crop insets, radial / linear / brush masks and red-eye points (they follow the content)
    /// and — when exactly one flip is on — the stored direction are all handled by `EditState.rotated(byQuarterTurns:)`.
    /// Refused (no step) with no photo or while a load is in flight (the step would land on the outgoing photo). Four
    /// presses return the same turn count and crop; masks / points return to within floating point.
    func rotate(_ direction: RotateDirection) {
        guard currentImage != nil, !isLoadInFlight else { return }
        finalizePendingCommit()
        let next = editState.rotated(byQuarterTurns: direction == .right ? 1 : -1)
        history.commit(next, summary: direction == .right ? "Rotate Right" : "Rotate Left")
        applyHistoryState(history.current)
        var notes: [String] = []
        if next.verticalPerspective != 0 || next.horizontalPerspective != 0 || next.transformAspect != 0 {
            notes.append("Perspective and Stretch now act on the rotated picture.")
        }
        rotationHint = notes.isEmpty ? nil : notes.joined(separator: " ")   // after applyHistoryState, which clears it
    }

    // MARK: - Spot removal

    /// Shown by the Retouch tab's own alert (placement refusals, a failed auto-source).
    @Published var retouchMessage: String?

    /// Appends a spot in the middle of the frame (the "Add Spot" button; later ones spiral outward) and finds its source in the
    /// background. Refused (with a message) unless the geometry is at identity — spots live in the unedited source frame and the
    /// on-image editing math only holds there (see `RetouchSpot`) — and at the 50-spot cap. Returns the new spot's id.
    @discardableResult
    func addRetouchSpot() -> UUID? {
        guard currentImage != nil else { return nil }
        guard checkCanPlaceRetouchSpot() else { return nil }
        guard let spot = RetouchOverlayGeometry.newSpot(existingCount: editState.retouchSpots.count) else { return nil }
        return commitNewRetouchSpot(spot)
    }

    /// Adds a spot where the user clicked or dragged on the photo with the Place Spots tool: `point` is a normalized position
    /// (x right, y UP) in the unedited frame, `radius` a fraction of the short side. Both are clamped to their legal ranges;
    /// non-finite input is refused (a NaN in `EditState` would make every sidecar write throw). Same refusals as the button
    /// (no image, geometry not at identity, the 50 cap). Returns the new spot's id.
    @discardableResult
    func addRetouchSpot(atNormalized point: (x: Double, y: Double), radius: Double) -> UUID? {
        guard currentImage != nil, point.x.isFinite, point.y.isFinite, radius.isFinite else { return nil }
        guard checkCanPlaceRetouchSpot() else { return nil }
        var spot = RetouchSpot()
        spot.x = min(max(point.x, 0), 1)
        spot.y = min(max(point.y, 0), 1)
        spot.radius = min(max(radius, RetouchSpot.radiusRange.lowerBound), RetouchSpot.radiusRange.upperBound)
        return commitNewRetouchSpot(spot)
    }

    /// Removes the spot `id` as its own labelled undo step ("Delete Spot"). A no-op (no history step) if there is no such spot.
    func deleteRetouchSpot(id: UUID) {
        finalizePendingCommit()
        guard editState.retouchSpots.contains(where: { $0.id == id }) else { return }
        var next = editState
        next.retouchSpots.removeAll { $0.id == id }
        history.commit(next, summary: "Delete Spot")
        applyHistoryState(history.current)
    }

    /// The placement refusals shared by every way of adding a spot; sets `retouchMessage` and returns false when refused.
    private func checkCanPlaceRetouchSpot() -> Bool {
        // A click during an async photo load would commit the spot onto the OUTGOING photo's history and sidecar.
        guard !isLoadInFlight else {
            retouchMessage = "Wait for the photo to finish loading, then try again."
            return false
        }
        guard editState.isGeometryAtIdentity else {
            retouchMessage = "Reset crop, straighten, rotation, perspective, scale and flip to add or move spots. Existing spots still apply."
            return false
        }
        guard editState.retouchSpots.count < EditState.maxRetouchSpots else {
            retouchMessage = "A photo can have at most \(EditState.maxRetouchSpots) spots."
            return false
        }
        return true
    }

    /// Appends `spot` as ONE labelled undo step ("Add Spot") — committed directly, not through the debounced `editState` path, so
    /// two clicks within the 350 ms coalescing window stay two undo steps — then starts the background source search. The search
    /// result lands later as its own "Find Source" step (`findRetouchSource`).
    private func commitNewRetouchSpot(_ spot: RetouchSpot) -> UUID? {
        guard spot.isFinite else { return nil }
        finalizePendingCommit()
        var next = editState
        next.retouchSpots.append(spot)
        history.commit(next, summary: "Add Spot")
        applyHistoryState(history.current)
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
            // Its own labelled undo step, committed directly like every other retouch action: written through `editState` it would be
            // a debounced burst with a generic summary that a following coalesced edit (a spot drag, a slider) could MERGE into.
            self.finalizePendingCommit()
            // A commit drops everything after the cursor. If the user has undone or jumped back since the search began, the redo
            // branch (e.g. the NEXT spot they clicked) must not be wiped by a background result: drop it instead. (A pending burst
            // flushed just above already truncated redo the way any user edit does, so this only bites when the user stepped back.)
            guard !self.history.canRedo else {
                if reportFailure {
                    self.retouchMessage = "Redo is available, so the source was not changed. Press Find Source again after redoing or editing."
                }
                return
            }
            var next = self.editState
            guard let current = next.retouchSpots.firstIndex(where: { $0.id == id }) else { return }
            next.retouchSpots[current].sourceDX = found.dx
            next.retouchSpots[current].sourceDY = found.dy
            self.history.commit(next, summary: "Find Source")
            self.applyHistoryState(self.history.current)
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

    // MARK: - Depth Range mask

    /// Re-reads which depth sources the open photo offers. Cheap metadata read, done off the main thread; a result for a photo that is no longer open is dropped.
    func refreshDepthAvailability() {
        let url = currentURL
        Task { @MainActor [weak self] in
            let availability = await Task.detached(priority: .utility) { DepthMapGenerator.availability(forFileAt: url) }.value
            guard let self, self.currentURL == url else { return }
            self.depthAvailability = availability
        }
    }

    /// Reads or computes the depth map of the UNEDITED current photo and commits ONE undo step: appends a new `.depthRange` mask (adjustments 0 — the
    /// user dials them in), or, when `maskID` names an existing depth mask, replaces that mask's raster ("Regenerate Depth"; its window, feather, invert
    /// and adjustments are kept). `preference` defaults to the mask's own current source when regenerating, else automatic. `completion` gets the
    /// affected mask's id on success, `nil` otherwise. Same shape as `selectSubject`: detached work, single-flight, `analysisGeneration` stale guard.
    func generateDepth(replacing maskID: UUID? = nil, preference: DepthSourceResolver.Preference? = nil, completion: ((UUID?) -> Void)? = nil) {
        guard !isGeneratingDepth else { completion?(nil); return }
        guard let currentImage, !isLoadInFlight else {
            depthMaskMessage = "Wait for the photo to finish loading, then try again."
            completion?(nil)
            return
        }
        let existing = maskID.flatMap { id in editState.masks.first(where: { $0.id == id && $0.kind == .depthRange }) }
        let chosen = preference ?? existing.map { DepthSourceResolver.preference(forTag: $0.depthSource) } ?? .automatic
        isGeneratingDepth = true
        let myGeneration = analysisGeneration
        let url = currentURL
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                await DepthMapGenerator.generate(from: currentImage, fileURL: url, preference: chosen)
            }.value
            do { // (scope only: keeps the `self` unwrap local to the main-actor continuation)
                guard let self else { return }
                self.isGeneratingDepth = false
                // The photo changed while the depth was being computed: drop the result rather than land it on another photo.
                guard self.analysisGeneration == myGeneration else { completion?(nil); return }
                switch outcome {
                case .failed(let reason):
                    self.depthMaskMessage = reason
                    completion?(nil)
                case .generated(let generated):
                    self.finalizePendingCommit()
                    var next = self.editState
                    var affected: UUID?
                    if let maskID, let index = next.masks.firstIndex(where: { $0.id == maskID && $0.kind == .depthRange }) {
                        next.masks[index].depthRasterPNG = generated.png
                        next.masks[index].depthSource = generated.sourceTag
                        affected = maskID
                    } else if maskID == nil {
                        var mask = Mask()
                        mask.kind = .depthRange
                        mask.depthRasterPNG = generated.png
                        mask.depthSource = generated.sourceTag
                        next.masks.append(mask)
                        affected = mask.id
                    }
                    guard let affected else { // the mask being regenerated was deleted while the depth was computed
                        self.depthMaskMessage = "That mask was deleted before its depth was ready."
                        completion?(nil)
                        return
                    }
                    self.history.commit(next, summary: maskID == nil ? "Generate Depth" : "Regenerate Depth")
                    self.applyHistoryState(self.history.current)
                    completion?(affected)
                }
            }
        }
    }

    // MARK: - Upright

    /// Detects line families on the UNEDITED source (`currentImage`, no edit geometry: Straighten and Perspective
    /// would change the very tilt and convergence being measured, and a repeat press must not double the
    /// correction) and applies the solved Straighten (and, for `.vertical`, Vertical / Horizontal perspective = 0)
    /// onto the CURRENT edit state as ONE undo step ("Upright Level" / "Upright Vertical"). Same guards as
    /// `autoTone()`: single-flight, `analysisGeneration` and `isLoadInFlight` staleness. Returns the work for tests.
    @discardableResult
    func autoUpright(_ mode: UprightMode) -> Task<Void, Never>? {
        guard !isAutoUprighting, !isAutoStraightening, !isAutoCropping else { return nil }
        guard let currentImage, !isLoadInFlight else {
            uprightMessage = "Wait for the photo to finish loading, then try again."
            return nil
        }
        runningUprightMode = mode
        let detector = uprightDetector
        let myGeneration = analysisGeneration
        // Straighten / perspective act on the ROTATED frame, so the lines are measured there.
        let measuredTurns = editState.rotationQuarterTurns
        let source = QuarterTurn.apply(measuredTurns, to: currentImage)
        return Task { @MainActor [weak self] in
            let detection = await Task.detached(priority: .userInitiated) { () -> UprightDetector.Result in
                detector(source)
            }.value
            guard let self else { return }
            self.runningUprightMode = nil
            guard self.analysisGeneration == myGeneration, !self.isLoadInFlight else { return }
            guard self.editState.rotationQuarterTurns == measuredTurns else {
                self.uprightMessage = StraightenMessages.rotatedMeanwhile
                return
            }
            let lines: UprightLineDetector.Lines
            switch detection {
            case .failed(let reason):
                self.uprightMessage = reason
                return
            case .lines(let found):
                lines = found
            }
            var straighten = 0.0
            var wasSolved = false
            var vertical: Double? = mode == .vertical ? 0 : nil
            switch UprightSolver.solve(lines, mode: mode) {
            case .noLines:
                self.uprightMessage = mode == .level ? UprightMessages.noLevelLines : UprightMessages.noLines
                return
            case .unmeasurable:
                self.uprightMessage = UprightMessages.unmeasurable
                return
            case .noAgreement:
                self.uprightMessage = UprightMessages.noAgreement
                return
            case .tiltTooLarge:
                self.uprightMessage = UprightMessages.tiltTooLarge
                return
            case .alreadyUpright:
                break // measured on the uncorrected source: the sliders it controls belong at 0
            case .solved(let correction):
                wasSolved = true
                straighten = correction.straightenAngle
                if mode == .vertical { vertical = correction.verticalPerspective ?? 0 }
            }
            self.finalizePendingCommit()
            var next = self.editState
            next.straightenAngle = straighten
            if let vertical {
                next.verticalPerspective = vertical
                next.horizontalPerspective = 0
            }
            guard next != self.editState else {
                self.uprightMessage = wasSolved ? UprightMessages.alreadyApplied : UprightMessages.alreadyUpright
                return
            }
            self.history.commit(next, summary: mode.historyLabel)
            self.applyHistoryState(self.history.current)
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
        // A Targeted drag is committed as ONE step by `endTargetedDrag`; a slow drag must not coalesce into several.
        guard targetedDrag == nil else { return }
        isBurstPending = true

        historyCommitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.finalizePendingCommit(endsTargetedDrag: false) }
        historyCommitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.historyCoalesceInterval, execute: workItem)
    }

    /// Settles the in-progress burst (if any) into one `EditHistory` commit.
    /// `EditHistory.commit`'s own `== current` guard drops a burst that
    /// netted no actual change (e.g. a slider dragged back to its start).
    /// `endsTargetedDrag`: every edit path funnels through here first, so an active Targeted drag is committed before it can
    /// straddle another edit; only the debounce timer (which can fire during a drag by design) opts out.
    private func finalizePendingCommit(endsTargetedDrag: Bool = true) {
        if endsTargetedDrag { endTargetedDrag() }
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
    /// `canUndo`/`canRedo` (the rail's Undo/Redo entries) and `historyEntries`/
    /// `currentHistoryIndex` (the History panel) — from the current
    /// `history`. Named for what it now covers as a whole, not just the
    /// undo/redo flags it originally published alone; called after every
    /// operation that can change `history`'s shape or cursor (`commit` via
    /// `finalizePendingCommit`, `applyHistoryState`, `resetHistory`).
    private func refreshHistoryState() {
        rotationHint = nil   // a note about the last rotate press; any load, revert, undo, redo or jump makes it stale
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
        targetedDrag = nil
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
        historyEditKey = currentEditKey
        refreshHistoryState()
        analysisGeneration += 1
        subjectMaskMessage = nil // a late "no subject" must not pop up about the NEXT photo
        depthMaskMessage = nil // likewise a late depth message
        retouchMessage = nil // likewise a late "no good source"
        straightenMessage = nil // and a late "no horizon found"
        skinProtectionMessage = nil // and a late "no people found"
        uprightMessage = nil // and a late "no lines found"
        autoCropMessage = nil // and a late "nothing to crop"
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
    /// relative to what the rail's Undo/Redo entries show.
    func revertToOriginal() {
        cancelPendingSkinDetection() // a still-running detection must not land its raster on the reverted photo
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

    /// Applies imported Lightroom / Camera Raw settings (`LightroomMapping.plan`) as ONE undo step, committed exactly like
    /// `applyPreset`. Only the fields the file carries change (`LightroomMapping.merge`); geometry, masks, spots and the RAW-decode
    /// fields stay (an imported rotation turns masks and red-eye points with the picture), and the crop changes only when
    /// the plan includes it. False (and no history step) when nothing would change.
    @discardableResult
    func applyLightroomSettings(_ plan: LightroomMapping.Plan) -> Bool {
        finalizePendingCommit()
        let merged = LightroomMapping.merge(plan, onto: editState)
        guard merged != editState else { return false }
        history.commit(merged, summary: "Lightroom Settings")
        applyHistoryState(history.current)
        return true
    }

    /// Picks a Style preset (`""` = None). Its own atomic, labelled undo step (`applyPreset`'s reasoning: the debounced
    /// `editState` path could merge a follow-up pad drag into the same step). Choosing None restores the strength to its
    /// identity (1) ONLY when that leaves the style contributing nothing (pad at the centre): then a leftover
    /// `styleStrength != 1` would be an invisible edit. With the pad off-centre strength is kept, because it still scales the
    /// pad — resetting it would silently change how the photo renders when the user only asked to drop the preset. The pad
    /// itself is left where it is: it is usable without a preset.
    func selectStyle(_ id: String) {
        finalizePendingCommit()
        var next = editState
        guard next.styleID != id else { return }
        next.styleID = id
        if id.isEmpty, StyleMath.isIdentity(id: "", tone: next.styleTone, color: next.styleColor) { next.styleStrength = 1 }
        let name = StyleLibrary.preset(for: id)?.name ?? (id.isEmpty ? "None" : id)
        history.commit(next, summary: "Style: \(name)")
        applyHistoryState(history.current)
    }

    /// Picks a Style texture (`""` = None; `StyleTexture` ids). Its own labelled undo step. Choosing None restores the texture
    /// strength to its identity (1) — ALWAYS, unlike `selectStyle`'s strength: the texture strength scales only the texture
    /// (the Grain toggle is independent of it), so once the texture is gone a leftover amount is an invisible edit.
    func selectStyleTexture(_ id: String) {
        finalizePendingCommit()
        var next = editState
        guard next.styleTexture != id else { return }
        next.styleTexture = id
        if id.isEmpty { next.styleTextureAmount = 1 }
        let name = StyleTexture(rawValue: id)?.title ?? (id.isEmpty ? "None" : id)
        history.commit(next, summary: "Style Texture: \(name)")
        applyHistoryState(history.current)
    }

    /// Turns the Style's Grain toggle on or off as its own labelled undo step.
    func setStyleGrain(_ on: Bool) {
        finalizePendingCommit()
        var next = editState
        guard next.styleGrain != on else { return }
        next.styleGrain = on
        history.commit(next, summary: "Style Grain: \(on ? "On" : "Off")")
        applyHistoryState(history.current)
    }

    // MARK: - Protect skin (Styles v3)

    /// True while Vision is finding people for "Protect skin" (the toggle shows busy and refuses a second request).
    @Published private(set) var isDetectingSkin = false

    /// The last detection's outcome when it did NOT turn protection on ("No people found…", a failure reason, "wait for the
    /// photo to load"); cleared on a photo switch, like `subjectMaskMessage`.
    @Published private(set) var skinProtectionMessage: String?

    /// The detector. A property so model tests can inject a deterministic one instead of running Vision.
    var skinMaskGenerator: @Sendable (CIImage) -> SkinMaskGenerator.Result = { SkinMaskGenerator.generate(from: $0) }

    /// Bumped whenever protection is switched off or reset, so a detection that was still running cannot switch it back on.
    private var skinDetectionGeneration = 0

    /// Drops the result of a skin detection that is still running (its raster would otherwise land on top of a reset). Called by
    /// every action that clears protection without going through `setProtectSkin`/`resetStyle`: Revert to Original and the
    /// Looks tab's Reset Look & Style (`resetLookAndStyle`).
    func cancelPendingSkinDetection() { skinDetectionGeneration += 1 }

    /// Turns "Protect skin" on or off as its own labelled undo step.
    /// ON runs the detector once on the UNEDITED current image (off the main thread, like `selectSubject`) and, only if it found
    /// skin, commits the toggle together with the raster and its Vision revision in ONE step; "no people" / a failure leaves
    /// protection off and says why in `skinProtectionMessage`. A result for a photo that was switched away from meanwhile
    /// (`analysisGeneration`) is dropped.
    /// OFF clears the raster, its revision and the amount (back to 1) in one step — a stranded raster would make the photo
    /// look edited — and re-enabling re-detects.
    func setProtectSkin(_ on: Bool) {
        if !on {
            skinDetectionGeneration += 1
            finalizePendingCommit()
            var next = editState
            guard next.styleProtectSkin || next.styleSkinMaskPNG != nil || next.styleSkinMaskRevision != nil else { return }
            next.styleProtectSkin = false; next.styleProtectAmount = 1; next.styleSkinMaskPNG = nil; next.styleSkinMaskRevision = nil
            history.commit(next, summary: "Protect Skin: Off")
            applyHistoryState(history.current)
            return
        }
        guard !isDetectingSkin, !editState.styleProtectSkin else { return }
        guard let currentImage, !isLoadInFlight else {
            skinProtectionMessage = "Wait for the photo to finish loading, then try again."
            return
        }
        skinProtectionMessage = nil
        isDetectingSkin = true
        let myGeneration = analysisGeneration
        let myDetection = skinDetectionGeneration
        let generate = skinMaskGenerator
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { generate(currentImage) }.value
            guard let self else { return }
            self.isDetectingSkin = false
            guard self.analysisGeneration == myGeneration, self.skinDetectionGeneration == myDetection else { return }
            switch result {
            case .noPeople:
                self.skinProtectionMessage = "No people found in this photo — nothing to protect."
            case .failed(let reason):
                self.skinProtectionMessage = reason
            case .mask(let png, let revision):
                self.finalizePendingCommit()
                var next = self.editState
                next.styleProtectSkin = true; next.styleSkinMaskPNG = png; next.styleSkinMaskRevision = revision
                self.history.commit(next, summary: "Protect Skin: On")
                self.applyHistoryState(self.history.current)
            }
        }
    }

    /// The Looks tab's reset: clears the Look and the whole Style (`EditState.resettingLookAndStyle()`) as ONE atomic, labelled
    /// undo step, and cancels a skin detection that is still running so its raster cannot land on the reset photo. Does nothing
    /// (no history step) when both are already at their defaults.
    func resetLookAndStyle() {
        cancelPendingSkinDetection()
        finalizePendingCommit()
        let next = editState.resettingLookAndStyle()
        guard next != editState else { return }
        history.commit(next, summary: "Reset Look & Style")
        applyHistoryState(history.current)
    }

    /// Clears the preset, the pad, the strength, the texture, the Grain toggle and skin protection in one step.
    func resetStyle() {
        skinDetectionGeneration += 1 // a detection still running must not switch protection back on
        finalizePendingCommit()
        // The Style section's own reset: everything `resettingLookAndStyle()` clears EXCEPT the Look (one shared field list).
        var next = editState.resettingLookAndStyle()
        next.lookID = editState.lookID; next.lookIntensity = editState.lookIntensity
        guard next != editState else { return }
        history.commit(next, summary: "Reset Style")
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
    /// text from before the extraction (apart from the app name, which now comes from `AppInfo.name`).
    private static let sidecarFolderAccessMessage =
        "\(AppInfo.name) would like to save your edits for photos in this folder. Choose the folder to grant access."

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
        // The status is deliberately NOT recomputed here: forgetting a decline writes nothing, so only an actual save outcome
        // (`publishSaveStatus`) or a load may clear a problem. An unchanged paste right after this call flushes nothing.
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
    private func loadSidecarIfReachable(for url: URL, versionKey: String? = nil) -> EditState? {
        // D81: no sidecar-save bookmark does NOT mean unreachable — a folder imported by drop / Finder-open / Import only
        // has the catalog's bookmark, whose scope is already active for a catalog-driven load. Read silently, without
        // starting a scope: it succeeds when some scope covers the folder and fails harmlessly otherwise.
        let folderURL = folderAccess.resolvedURL(for: url.deletingLastPathComponent())
        let scoped = folderURL?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { folderURL?.stopAccessingSecurityScopedResource() } }
        guard case .decoded(let state) = SidecarStore.read(forPhotoAt: url, versionKey: versionKey) else { return nil }
        return state
    }

    /// `SidecarStore.readHistory` for `url`, run off the main thread (inside the folder's security scope when a sidecar
    /// bookmark resolves; otherwise silently without one, see `loadSidecarIfReachable`). nil when the photo has no usable
    /// persisted history or the folder cannot be read (load must stay silent).
    private func loadPersistedHistory(for url: URL, versionKey: String? = nil) async -> (archive: HistoryArchive, encoder: HistoryArchive.Encoder)? {
        let folderURL = folderAccess.resolvedURL(for: url.deletingLastPathComponent())
        let scoped = folderURL?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { folderURL?.stopAccessingSecurityScopedResource() } }
        return await Task.detached(priority: .userInitiated) {
            guard let archive = SidecarStore.readHistory(forPhotoAt: url, versionKey: versionKey) else { return nil }
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
        endTargetedDrag() // schedules the save below when it committed a step
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
        let versionKey = currentVersionKey
        let editKey = Photo.editKey(path: url.path, versionKey: versionKey)
        let snapshot = editState
        // Ownership is captured WITH the snapshot: a load of another photo finishing while the access panel is up must not
        // make this photo's own last save look foreign (D81 x D28).
        let ownsTarget = sidecarOwnedEditKey == editKey
        // The history rides in the same snapshot (a value type): written only when it belongs to THIS photo and is exactly
        // in step with the saved state — otherwise the sidecar is written without `_history` (never a stale one).
        let historySnapshot = history
        let historyBelongsHere = historyEditKey == editKey && historySnapshot.entries.count > 1 && historySnapshot.current == snapshot
        let folder = url.deletingLastPathComponent()
        guard !declinedFolders.contains(folder.path) else {
            publishSaveStatus(.folderDeclined, forPhotoAt: url, versionKey: versionKey)
            return
        }
        let folderURL: URL
        switch folderAccess.resolveOrRequest(for: folder, message: Self.sidecarFolderAccessMessage) {
        case .granted(let granted):
            folderURL = granted
        case .declined:
            declinedFolders.insert(folder.path)
            publishSaveStatus(.folderDeclined, forPhotoAt: url, versionKey: versionKey)
            return
        case .failed(let error):
            // Matches the original `requestFolderAccess`'s own behavior:
            // this surfaces UNCONDITIONALLY, not gated by
            // `suppressErrorMessage` — a genuine bookmark-creation failure
            // AFTER the user already granted access is a real, unexpected
            // error, not the "opening a photo shouldn't itself produce an
            // error" case `suppressErrorMessage` exists for.
            sidecarSaveErrorMessage = "Couldn't save edits: \(error.localizedDescription)"
            publishSaveStatus(.writeFailed(error.localizedDescription), forPhotoAt: url, versionKey: versionKey)
            return
        }
        guard folderURL.startAccessingSecurityScopedResource() else {
            if !suppressErrorMessage {
                sidecarSaveErrorMessage = "Couldn't save edits: access to the containing folder is no longer available."
            }
            publishSaveStatus(.writeFailed("access to the containing folder is no longer available"), forPhotoAt: url, versionKey: versionKey)
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        // D81 guard: never replace a sidecar this model did not load (or write itself). Read AFTER the scope started.
        // A reload of the SAME photo inside the panel may have cleared ownership (its file could not be decoded): then the
        // captured value is stale, so re-evaluate. Another photo's load (D28) leaves this photo's captured ownership alone.
        let stillOwned = ownsTarget
            && !(currentURL == url && currentVersionKey == versionKey && sidecarOwnedEditKey != editKey)
        if !stillOwned {
            if refusedEditKey == editKey { return } // the user was already told this load
            let message: String
            switch SidecarStore.read(forPhotoAt: url, versionKey: versionKey) {
            case .missing:
                message = ""
            case .decoded:
                publishSaveStatus(.refusedNotLoaded, forPhotoAt: url, versionKey: versionKey)
                message = "Couldn't save edits: this photo already has a saved edit file that wasn't loaded. "
                    + "Close and reopen the photo, then edit again."
            case .undecodable:
                publishSaveStatus(.refusedUnreadable, forPhotoAt: url, versionKey: versionKey)
                let name = SidecarStore.versionedSidecarURL(for: url, versionKey: versionKey)?.lastPathComponent ?? "its edit file"
                message = "Couldn't save edits: this photo's saved edit file can't be read, so it was left untouched. "
                    + "Fix or remove \(name), then reopen the photo."
            }
            if !message.isEmpty {
                // Deliberately not `declinedFolders` (that would also silence every later save in the folder). A silent
                // (automatic) save neither alerts nor arms the once-flag, so the user's own next edit still tells them.
                if !suppressErrorMessage {
                    sidecarSaveErrorMessage = message
                    refusedEditKey = editKey
                }
                return
            }
        }
        do {
            if historyBelongsHere, let historyObject = historyEncoder.jsonObject(for: HistoryArchive(historySnapshot)) {
                try SidecarStore.write(snapshot, historyObject: historyObject, forPhotoAt: url, versionKey: versionKey)
            } else {
                try SidecarStore.write(snapshot, forPhotoAt: url, versionKey: versionKey)
            }
            if currentURL == url, currentVersionKey == versionKey { sidecarOwnedEditKey = editKey }
            publishSaveStatus(.ok, forPhotoAt: url, versionKey: versionKey)
            if let versionKey { onVersionSidecarSaved?(url, versionKey) } else { onSidecarSaved?(url) }
        } catch {
            if !suppressErrorMessage {
                sidecarSaveErrorMessage = "Couldn't save edits: \(error.localizedDescription)"
            }
            publishSaveStatus(.writeFailed(error.localizedDescription), forPhotoAt: url, versionKey: versionKey)
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
        // D81: a save the guard refused wrote nothing (and does not decline the folder) — never report it as written.
        if let currentURL, refusedEditKey == Photo.editKey(path: currentURL.path, versionKey: currentVersionKey) {
            return .skipped
        }
        return .written
    }
}
