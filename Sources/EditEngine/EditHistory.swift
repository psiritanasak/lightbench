import Foundation

/// One committed checkpoint in an `EditHistory`'s own timeline — the
/// History panel's own row model, and the unit `EditHistory.jump(to:)`
/// operates on.
///
/// `id` is a stable `UUID`, NOT the entry's own array index — a real
/// requirement, not a style choice: `ImageDocumentModel.jumpToHistory(id:)`
/// must call `finalizePendingCommit()` before jumping (matching
/// `undo()`/`redo()`'s own existing pattern), and that flush can itself
/// trim the oldest entry or drop every entry after the cursor — either
/// would silently invalidate an index captured before the flush. A `UUID`
/// captured by a History row's own button closure stays valid (or safely
/// fails via `jump(to:)`'s own `false` return) regardless of what the
/// flush did in between.
struct HistoryEntry: Identifiable, Equatable {
    let id: UUID
    let state: EditState
    /// A short, human-readable description of what changed to PRODUCE this
    /// entry (e.g. `"Exposure"`, `"Revert to Original"`) — see
    /// `EditStateDiff.summary(from:to:)` for the generic, field-diff-based
    /// default, and `EditHistory.commit(_:summary:)`'s own `summary`
    /// parameter for the handful of call sites (Revert, Preset, Reset
    /// Curve, Auto Tone) that pass a more meaningful label instead of
    /// letting the diff describe itself.
    let summary: String

    init(id: UUID = UUID(), state: EditState, summary: String) {
        self.id = id
        self.state = state
        self.summary = summary
    }
}

/// A pure, timing-agnostic in-memory undo/redo/jump timeline for
/// `EditState`.
///
/// A single ordered `entries` array plus a `currentIndex` cursor — NOT the
/// two separate past/future stacks an earlier version of this type used.
/// That shape stopped being sufficient once the History panel needed to
/// jump to an ARBITRARY past (or redone-but-not-yet-abandoned) entry, not
/// just step one at a time: every entry needs its own stable identity and
/// label regardless, and a single timeline with a cursor is the standard
/// shape for "list with a cursor that can move anywhere," with none of the
/// index-translation bookkeeping two separate stacks would need. No
/// timing, no UI, no Core Image here — coalescing rapid in-progress edits
/// (a slider or crop drag) into a single `commit` is the caller's job, see
/// `ImageDocumentModel`'s debounced `recordEditChange`/
/// `finalizePendingCommit` — this type only knows about already-settled
/// checkpoints.
struct EditHistory {
    private(set) var entries: [HistoryEntry]
    private(set) var currentIndex: Int

    /// Caps how many PAST entries are retained (bounding memory), matching
    /// the exact `entries.count <= limit + 1` rule (`limit` past entries
    /// plus the current one) the original two-stack version already
    /// established and `testCommitBeyondTheLimitDropsTheOldestStep` still
    /// pins. Three `EditState` fields are unbounded in memory: `redEyePoints`,
    /// since Phase 7 slice 2 `masks`, and `retouchSpots` (capped at `maxRetouchSpots` on decode; the UI add site
    /// must enforce it too) — each `Mask` is ~14 `Double`s + a
    /// `UUID` (roughly 128 bytes), so even a worst-case 100-entry cap ×
    /// 10 masks is only ~128 KB, and Swift arrays are copy-on-write
    /// besides (an entry that didn't touch `masks` shares the same buffer
    /// as its neighbor). No change to `limit`'s own default is warranted
    /// by `masks`' existence — noting that explicitly so a future reader
    /// doesn't "fix" it unnecessarily.
    let limit: Int

    var current: EditState { entries[currentIndex].state }
    var canUndo: Bool { currentIndex > 0 }
    var canRedo: Bool { currentIndex < entries.count - 1 }

    /// `initialSummary` defaults to `"Opened"`, not `"Original"`: the
    /// `initial` state passed in is often a state RESTORED from a photo's
    /// own sidecar (see `ImageDocumentModel.resetHistory()`), not literal
    /// identity, so labeling it "Original" would misdescribe an
    /// already-edited photo's own first History row.
    init(_ initial: EditState = .identity, limit: Int = 100, initialSummary: String = "Opened") {
        self.entries = [HistoryEntry(state: initial, summary: initialSummary)]
        self.currentIndex = 0
        self.limit = limit
    }

    /// Storage-level initializer for `init?(restoring:...)` (validated by the caller).
    init(restoredEntries: [HistoryEntry], currentIndex: Int, limit: Int) {
        self.entries = restoredEntries
        self.currentIndex = currentIndex
        self.limit = limit
    }

    /// Records `newValue` as a new checkpoint, making `current` undoable
    /// back to its prior value. No-op if `newValue == current` (via
    /// `EditState`'s `Equatable`) — prevents a gesture that netted no
    /// actual change (e.g. a slider dragged back to its starting value)
    /// from creating a phantom undo step. Every entry AFTER the current
    /// cursor is discarded first, matching standard undo-stack semantics:
    /// committing a new edit after an undo (or a History-panel jump to an
    /// older entry) abandons the redone-from branch — those entries' own
    /// `id`s then correctly fail `jump(to:)`.
    ///
    /// `summary` defaults to `nil`, which computes a generic field-diff
    /// label via `EditStateDiff.summary(from:to:)` — the debounced,
    /// ordinary-slider-edit path (`ImageDocumentModel.finalizePendingCommit`)
    /// always uses this default. The handful of call sites that already
    /// know their own intent (Revert, apply Preset, Reset Curve, Auto
    /// Tone) pass an explicit, more meaningful label instead.
    mutating func commit(_ newValue: EditState, summary: String? = nil) {
        guard newValue != current else { return }
        if currentIndex + 1 < entries.count {
            entries.removeSubrange((currentIndex + 1)...)
        }
        let entrySummary = summary ?? EditStateDiff.summary(from: current, to: newValue)
        entries.append(HistoryEntry(state: newValue, summary: entrySummary))
        currentIndex = entries.count - 1
        if entries.count > limit + 1 {
            let overflow = entries.count - (limit + 1)
            entries.removeFirst(overflow)
            currentIndex -= overflow
        }
    }

    /// Moves the cursor back one entry. Safe no-op if there's nothing to
    /// undo.
    mutating func undo() {
        guard canUndo else { return }
        currentIndex -= 1
    }

    /// Moves the cursor forward one entry. Safe no-op if there's nothing
    /// to redo.
    mutating func redo() {
        guard canRedo else { return }
        currentIndex += 1
    }

    /// Moves the cursor directly to the entry with the given `id` — the
    /// History panel's own jump, unlike `undo()`/`redo()`'s one-step-at-a-
    /// time moves. Returns `false`, changing nothing, if `id` doesn't exist
    /// (already discarded by a later `commit`) OR is already the current
    /// entry.
    ///
    /// That second case is LOAD-BEARING, not a minor optimization: every
    /// History row is tappable, including the current one (unlike the
    /// toolbar's Undo/Redo buttons, which `ContentView` already disables
    /// when unavailable) — `ImageDocumentModel.jumpToHistory(id:)` relies
    /// on this `false` to skip its own `applyHistoryState` write, which
    /// would otherwise fire `editState`'s `didSet` → `scheduleSidecarSave()`
    /// for a tap that changed nothing, a real, user-visible bug (a
    /// spurious save, possibly even a folder-access permission prompt).
    @discardableResult
    mutating func jump(to id: HistoryEntry.ID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }), index != currentIndex else { return false }
        currentIndex = index
        return true
    }
}
