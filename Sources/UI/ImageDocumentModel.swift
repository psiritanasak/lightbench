import AppKit
import CoreImage
import UniformTypeIdentifiers

/// Owns the currently displayed image state. Only ever reads image files —
/// never writes to originals, preserving the app's non-destructive invariant.
@MainActor
final class ImageDocumentModel: ObservableObject {
    @Published private(set) var currentImage: CIImage?
    @Published private(set) var currentFileName: String?
    /// The full URL of the currently-open photo — NOT `@Published` (no UI
    /// reads it directly), kept purely so a sidecar path can be derived
    /// from it. Before sidecar persistence, `load(from:)` never retained
    /// anything beyond the bare filename string.
    private var currentURL: URL?
    @Published var loadErrorMessage: String?
    /// User-facing feedback when saving a sidecar fails (folder-bookmark
    /// resolution or the write itself) — mirrors `whiteBalanceSampleMessage`'s
    /// alert-binding pattern. NOT set when the user simply declines a
    /// folder-access prompt — that's an ordinary, silent choice, not an
    /// error condition.
    @Published var sidecarSaveErrorMessage: String?
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
        }
    }

    /// Whether an undo/redo step is available — mirrors `EditHistory`'s own
    /// `canUndo`/`canRedo` as `@Published` properties, since SwiftUI can't
    /// observe mutation of a plain (non-`ObservableObject`) struct property;
    /// refreshed after every history operation. Drives the toolbar buttons'
    /// enabled state.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

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

    private var histogramWorkItem: DispatchWorkItem?
    /// Guards against an out-of-order background histogram result (an OLDER
    /// in-flight computation finishing after a NEWER one) overwriting fresher
    /// data — `DispatchWorkItem.cancel()` (used for the debounce below)
    /// reliably stops a not-yet-started item, but `Task` cancellation is only
    /// cooperative and `EditPipeline.apply`/`HistogramComputer` don't check
    /// for it, so a simple monotonic generation counter is the correct
    /// "only the latest result wins" mechanism here, not task cancellation.
    private var histogramGeneration = 0

    // MARK: - Undo/Redo state

    private var history = EditHistory()

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

    func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(from: url)
    }

    func load(from url: URL) {
        guard let raw = CIImage(contentsOf: url) else {
            loadErrorMessage = "Couldn't open \"\(url.lastPathComponent)\". The file may be missing, unreadable, or not a supported image format."
            return
        }
        flushPendingSidecarSave() // save the OUTGOING photo's edits before switching away from it
        currentImage = raw.oriented(Self.exifOrientation(of: url))
        currentFileName = url.lastPathComponent
        currentURL = url
        // Restore saved edits if we can currently reach this photo's
        // sidecar (needs a resolvable folder bookmark, same as saving —
        // see `// MARK: - Sidecar Persistence`). No bookmark yet, or no
        // sidecar at that path, both fall back to identity exactly like
        // before this feature existed — neither is an error.
        isLoadingPhoto = true
        editState = loadSidecarIfReachable(for: url) ?? EditState()
        isLoadingPhoto = false
        resetHistory() // undo history is per-photo too — can't undo into the previous photo
    }

    /// `nonisolated` (not `private`) since `Sources/Rendering/PhotoExporter.swift`
    /// (Phase 5 batch export) needs to reproduce `load(from:)`'s own
    /// orientation handling from off-main code — same treatment already
    /// given to `sidecarURL(for:)` above, for the same reason (a pure,
    /// non-actor-isolated helper another type needs to call). No behavior
    /// change to this method itself or to `load(from:)`'s existing use of it.
    nonisolated static func exifOrientation(of url: URL) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let raw = properties[kCGImagePropertyOrientation as String] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else {
            return .up
        }
        return orientation
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

        Task.detached(priority: .userInitiated) { [weak self] in
            let edited = EditPipeline.apply(referenceState, to: currentImage)
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
    /// perspective/flip/crop copied from the real `editState` — rather than
    /// "the displayed image with just WB reset." White balance is pipeline
    /// stage 1, so what matters for neutralizing it is the RAW
    /// front-of-pipeline chromaticity at that point, not what it looks like
    /// after exposure/contrast/curves/etc have already reshaped it (those
    /// stages don't commute with WB). Since color stages don't change
    /// extent, this render still shares `currentFitRect`'s exact coordinate
    /// space, so no geometric-transform inversion is needed to map a tap
    /// back to a pixel.
    func pickWhiteBalance(normalizedX u: Double, normalizedY v: Double) {
        guard let currentImage else { return }

        var samplingState = EditState()
        samplingState.straightenAngle = editState.straightenAngle
        samplingState.verticalPerspective = editState.verticalPerspective
        samplingState.horizontalPerspective = editState.horizontalPerspective
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

        var samplingState = EditState()
        samplingState.straightenAngle = editState.straightenAngle
        samplingState.verticalPerspective = editState.verticalPerspective
        samplingState.horizontalPerspective = editState.horizontalPerspective
        samplingState.flipHorizontal = editState.flipHorizontal
        samplingState.flipVertical = editState.flipVertical
        samplingState.cropInsetTop = editState.cropInsetTop
        samplingState.cropInsetBottom = editState.cropInsetBottom
        samplingState.cropInsetLeft = editState.cropInsetLeft
        samplingState.cropInsetRight = editState.cropInsetRight

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
                    self?.whiteBalanceSampleMessage = "Couldn't analyze this image's colors."
                }
                return
            }

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
                    self.whiteBalanceSampleMessage = "Couldn't fully correct this image's color cast — it may be unusually strong."
                case .rejectedTooDark:
                    self.whiteBalanceSampleMessage = "This image is too dark overall to read a color cast."
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
        refreshUndoRedoFlags()
    }

    /// Applies `state` as the result of an undo/redo step. Guarded by
    /// `isApplyingHistoryChange` so the resulting `editState` `didSet`
    /// doesn't re-record this as a new burst (which would immediately
    /// re-commit the very state just restored) — `scheduleHistogramUpdate()`
    /// still runs unconditionally, so the live histogram updates correctly.
    private func applyHistoryState(_ state: EditState) {
        isApplyingHistoryChange = true
        editState = state
        isApplyingHistoryChange = false
        refreshUndoRedoFlags()
    }

    private func refreshUndoRedoFlags() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    /// Resets undo/redo history to empty — called on `load(from:)` since
    /// edits (and their history) are per-photo; also cancels/discards any
    /// burst that was mid-flight for the PREVIOUS photo so it can't leak a
    /// stray commit into the new photo's fresh history.
    private func resetHistory() {
        historyCommitWorkItem?.cancel()
        historyCommitWorkItem = nil
        isBurstPending = false
        history = EditHistory(editState)
        refreshUndoRedoFlags()
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
        history.commit(EditState())
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

    /// One resolvable, persisted security-scoped bookmark per folder the
    /// user has granted sidecar access to — keyed by the folder's own path.
    /// Backed by `UserDefaults` (small, simple; `Data` is a valid property-
    /// list type, no new storage format needed for this). Not `@Published`
    /// — purely internal bookkeeping, no UI reads it.
    private var folderBookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: Self.folderBookmarksDefaultsKey) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.folderBookmarksDefaultsKey) }
    }
    private static let folderBookmarksDefaultsKey = "PhotoApp.sidecarFolderBookmarks"

    /// Folders (by path) where the user CANCELLED a folder-access prompt
    /// this session — in-memory only, deliberately NOT persisted. Without
    /// this, every subsequent edit in a declined folder would re-prompt
    /// (a live-tested, genuinely bad UX: five slider drags means five
    /// dialogs) since a decline leaves no bookmark to short-circuit on.
    /// Suppresses re-prompting for the REST OF THIS SESSION only — a fresh
    /// launch asks again, giving the user another chance rather than
    /// permanently blocking a folder from one accidental cancel.
    private var declinedFolders: Set<String> = []

    /// The sidecar path for a given photo URL — same directory, original
    /// filename with `.photoapp.json` appended (e.g. `MyPhoto.jpg` →
    /// `MyPhoto.jpg.photoapp.json`). Pure and directly unit-testable;
    /// `nonisolated` since it touches no actor-isolated state, so tests
    /// don't need `@MainActor` context to call it.
    nonisolated static func sidecarURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".photoapp.json")
    }

    /// Resolves an EXISTING bookmark for `folder`, if one is stored and
    /// still valid. Drops (and returns `nil` for) a stale or unresolvable
    /// entry rather than surfacing an error — the next save attempt will
    /// simply re-prompt, self-healing rather than getting stuck. Never
    /// prompts — that's `requestFolderAccess`'s job.
    private func resolvedBookmarkURL(for folder: URL) -> URL? {
        guard let data = folderBookmarks[folder.path] else { return nil }
        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
              !isStale
        else {
            folderBookmarks.removeValue(forKey: folder.path)
            return nil
        }
        return resolved
    }

    /// Shows a directory-mode `NSOpenPanel` asking the user to grant access
    /// to `folder` (pre-navigated there for convenience), and persists a
    /// security-scoped bookmark for it on success. Returns `nil` if the
    /// user cancels/declines — a normal, silent outcome, not an error —
    /// and records the decline in `declinedFolders` so `saveSidecarNow`
    /// doesn't re-show this same prompt on the next edit. If the user
    /// GRANTS access but `bookmarkData(options:)` itself then fails (a
    /// genuine, unexpected error, not a decline), that's surfaced via
    /// `sidecarSaveErrorMessage` — silently returning `nil` here would
    /// otherwise let an edit fail to save with zero feedback despite the
    /// user having just said yes.
    private func requestFolderAccess(for folder: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.message = "PhotoApp would like to save your edits for photos in this folder. Choose the folder to grant access."
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK, let grantedURL = panel.url else {
            declinedFolders.insert(folder.path)
            return nil
        }
        do {
            let bookmarkData = try grantedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            folderBookmarks[folder.path] = bookmarkData
            return grantedURL
        } catch {
            sidecarSaveErrorMessage = "Couldn't save edits: \(error.localizedDescription)"
            return nil
        }
    }

    /// Loads a photo's sidecar, if one exists AND we can currently reach
    /// it. Deliberately does NOT prompt for folder access — load must stay
    /// silent; only a real save attempt (via `saveSidecarNow`) may prompt.
    /// A missing bookmark, missing sidecar, or undecodable sidecar are all
    /// treated identically: no saved edits to restore, not an error.
    private func loadSidecarIfReachable(for url: URL) -> EditState? {
        guard let folderURL = resolvedBookmarkURL(for: url.deletingLastPathComponent()) else { return nil }
        guard folderURL.startAccessingSecurityScopedResource() else { return nil }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: Self.sidecarURL(for: url)) else { return nil }
        return try? JSONDecoder().decode(EditState.self, from: data)
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
    /// OUTGOING photo's last ~1s of unsaved edits aren't dropped.
    private func flushPendingSidecarSave() {
        guard sidecarSaveWorkItem != nil else { return }
        sidecarSaveWorkItem?.cancel()
        sidecarSaveWorkItem = nil
        saveSidecarNow()
    }

    /// Resolves (or lazily requests) folder access, then encodes and writes
    /// the current `editState` to its sidecar. Declining a folder-access
    /// prompt is silent (not an error); a resolution or write FAILURE after
    /// access was actually granted surfaces via `sidecarSaveErrorMessage`.
    /// Skips re-prompting entirely for a folder already declined this
    /// session (see `declinedFolders`).
    private func saveSidecarNow() {
        guard let currentURL else { return }
        let folder = currentURL.deletingLastPathComponent()
        guard !declinedFolders.contains(folder.path) else { return }
        guard let folderURL = resolvedBookmarkURL(for: folder) ?? requestFolderAccess(for: folder) else {
            return
        }
        guard folderURL.startAccessingSecurityScopedResource() else {
            sidecarSaveErrorMessage = "Couldn't save edits: access to the containing folder is no longer available."
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        do {
            let data = try JSONEncoder().encode(editState)
            try data.write(to: Self.sidecarURL(for: currentURL), options: .atomic)
        } catch {
            sidecarSaveErrorMessage = "Couldn't save edits: \(error.localizedDescription)"
        }
    }
}
