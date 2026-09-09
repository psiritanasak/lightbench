import Foundation

/// A pure, timing-agnostic in-memory undo/redo stack for `EditState`.
///
/// Owns the current settled state plus past/future snapshot stacks — no
/// timing, no UI, no Core Image. `EditState` is already a value type
/// (`Equatable`), so a snapshot is just a copy; the whole feature is "keep a
/// stack of past values." Coalescing rapid in-progress edits (a slider or
/// crop drag) into a single `commit` is the caller's job — see
/// `ImageDocumentModel`'s debounced `recordEditChange`/`finalizePendingCommit`
/// — this type only knows about already-settled checkpoints.
struct EditHistory {
    private(set) var current: EditState
    private var past: [EditState] = []
    private var future: [EditState] = []

    /// Caps how many past states are retained, bounding memory. Two
    /// `EditState` fields are unbounded: `redEyePoints` and, since Phase 7
    /// slice 2, `masks` — each `Mask` is ~14 `Double`s + a `UUID` (roughly
    /// 128 bytes), so even a worst-case 100-snapshot cap × 10 masks is only
    /// ~128 KB, and Swift arrays are copy-on-write besides (a snapshot that
    /// didn't touch `masks` shares the same buffer as its neighbor, so only
    /// commits that actually changed a mask allocate at all). No change to
    /// `limit`'s own default is warranted by `masks`' existence — noting
    /// that explicitly so a future reader doesn't "fix" it unnecessarily.
    let limit: Int

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    init(_ initial: EditState = .identity, limit: Int = 100) {
        self.current = initial
        self.limit = limit
    }

    /// Records `newValue` as a new checkpoint, making `current` undoable back
    /// to its prior value. No-op if `newValue == current` (via `EditState`'s
    /// `Equatable`) — prevents a gesture that netted no actual change (e.g. a
    /// slider dragged back to its starting value) from creating a phantom
    /// undo step. Any pending redo history is discarded, matching standard
    /// undo-stack semantics: committing a new edit after an undo abandons the
    /// redone-from branch.
    mutating func commit(_ newValue: EditState) {
        guard newValue != current else { return }
        past.append(current)
        if past.count > limit {
            past.removeFirst(past.count - limit)
        }
        current = newValue
        future.removeAll()
    }

    /// Moves `current` back one step. Safe no-op if there's nothing to undo.
    mutating func undo() {
        guard canUndo else { return }
        future.append(current)
        current = past.removeLast()
    }

    /// Moves `current` forward one step. Safe no-op if there's nothing to redo.
    mutating func redo() {
        guard canRedo else { return }
        past.append(current)
        current = future.removeLast()
    }
}
