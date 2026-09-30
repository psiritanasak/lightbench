import Darwin
import Foundation

/// Moves photo files (and their `.photoapp.json` sidecars) to new names —
/// the file half of the Library's batch rename and of its Undo. Filesystem
/// only: no catalog, no UI, no security-scope handling (the caller must
/// already hold write access to every folder involved).
///
/// SAFETY MODEL — a rename must never lose or overwrite a photo:
///
/// 1. **No-overwrite moves.** Every move goes through `exclusiveMove`
///    (`renamex_np(..., RENAME_EXCL)`), which FAILS with `EEXIST` rather than
///    replacing an existing file — unlike plain `rename(2)`/`moveItem`, which
///    silently clobber. So even a race with another process (or a stale
///    preview) can only make a move fail, never destroy a file.
/// 2. **Two phases.** Phase 1 moves every source (photo, then its sidecar if
///    present) to a unique hidden temp name in the SAME folder; phase 2 moves
///    the temps to their final names. That is what makes a chain (a→b while
///    b→c), a swap (a↔b), and a case-only rename (`IMG.jpg`→`img.jpg` on a
///    case-insensitive volume) all safe: no final name is claimed while a
///    source still holds it.
/// 3. **All-or-nothing.** Every completed move is journaled; on any failure the
///    journal is replayed backwards, restoring every original name. If a
///    rollback step itself fails, the error names the file that is stuck and
///    where it is.
///
/// Known, accepted limitation (IMPROVEMENTS.md D40): the journal lives in memory
/// only. A crash or force-quit BETWEEN the phases leaves the batch's photos under
/// hidden `.photoapp-rename-<token>-<n>-<original name>` names in their folder —
/// ALL of the batch's photos are hidden from the end of phase 1 until phase 2
/// finishes (typically well under a second for tens of photos, but not
/// per-file). Nothing is deleted, and the original name is kept at the end of
/// each temp name so they can be renamed back by hand.
///
/// A sidecar is only ever moved WITH its photo, and a destination sidecar that
/// already exists (an orphan, or one a stale Editor save just wrote) is
/// refused — otherwise the photo would silently adopt someone else's edits.
enum RenameEngine {
    typealias MoveFunction = (URL, URL) throws -> Void

    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Applies `moves` (photo id ignored — only paths matter) as one
    /// all-or-nothing batch. `move` is injectable so tests can force a failure
    /// at an exact step and verify the rollback.
    static func apply(
        _ moves: [RenameMove],
        move: MoveFunction = exclusiveMove,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws {
        func somethingExists(at url: URL) -> Bool { fileExists(url.path) || RenameEngine.itemExists(url) }
        var journal: [(from: URL, to: URL)] = []
        func step(_ from: URL, _ to: URL) throws {
            try move(from, to)
            journal.append((from, to))
        }

        let token = UUID().uuidString.prefix(8)
        do {
            // Phase 1: park every source (and its sidecar) under a temp name.
            var staged: [(move: RenameMove, tempPhoto: URL, tempSidecar: URL?)] = []
            for (index, item) in moves.enumerated() {
                let old = URL(fileURLWithPath: item.oldPath)
                let folder = old.deletingLastPathComponent()
                let tempPhoto = folder.appendingPathComponent(
                    tempName(token: String(token), index: index, original: old.lastPathComponent, reserve: ".sidecar".utf8.count)
                )
                try step(old, tempPhoto)
                var tempSidecar: URL?
                let oldSidecar = SidecarStore.sidecarURL(for: old)
                if somethingExists(at: oldSidecar) { // lstat-aware, same as phase 2: a dangling symlink here moves with its photo
                    let temp = folder.appendingPathComponent(tempPhoto.lastPathComponent + ".sidecar")
                    try step(oldSidecar, temp)
                    tempSidecar = temp
                }
                staged.append((item, tempPhoto, tempSidecar))
            }
            // Phase 2: temps → final names.
            for entry in staged {
                let new = URL(fileURLWithPath: entry.move.newPath)
                // A photo with NO sidecar of its own must not land next to an existing one at
                // its new name (every sidecar this batch frees is already parked under a temp
                // name, so anything found here is foreign). Also what protects Undo, which
                // has no planner.
                if entry.tempSidecar == nil, somethingExists(at: SidecarStore.sidecarURL(for: new)) {
                    throw Failure(message: "an edit file already exists next to \"\(new.lastPathComponent)\"")
                }
                try step(entry.tempPhoto, new)
                if let tempSidecar = entry.tempSidecar {
                    try step(tempSidecar, SidecarStore.sidecarURL(for: new))
                }
            }
        } catch {
            var stuck: [String] = []
            for (from, to) in journal.reversed() {
                do { try move(to, from) } catch {
                    stuck.append("\"\(to.lastPathComponent)\" (should be \"\(from.lastPathComponent)\") in \(to.deletingLastPathComponent().path)")
                }
            }
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            if stuck.isEmpty {
                throw Failure(message: "Renaming failed (\(reason)). Every file was put back — nothing was renamed.")
            }
            throw Failure(message: "Renaming failed (\(reason)) and \(stuck.count) file(s) could not be put back: "
                + stuck.joined(separator: "; ") + ". They are not lost — rename them back by hand.")
        }
    }

    /// A hidden temp name that still identifies the photo: `.photoapp-rename-<token>-<n>-<original>`,
    /// keeping the END of the original name (its extension) if it must be shortened to fit 255 bytes
    /// (`reserve` = extra bytes a caller appends, e.g. the sidecar's `.sidecar`).
    static func tempName(token: String, index: Int, original: String, reserve: Int) -> String {
        let prefix = ".photoapp-rename-\(token)-\(index)-"
        let available = 255 - prefix.utf8.count - reserve
        var kept = original
        while kept.utf8.count > available, !kept.isEmpty { kept.removeFirst() }
        return prefix + kept
    }

    /// True if ANYTHING is at `url`, including a dangling symlink (`FileManager.fileExists` follows
    /// symlinks and reports a dangling one as absent — a plain `rename(2)` would then replace it).
    static func itemExists(_ url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return lstat(path, &info) == 0
        }
    }

    /// Moves `from` to `to`, FAILING (never replacing) if `to` already exists.
    /// `renamex_np(RENAME_EXCL)` on APFS/HFS+. On a volume without support for
    /// it (`ENOTSUP`/`EINVAL`, e.g. some exFAT/FAT setups) it falls back to
    /// check-then-`rename` — that fallback has a tiny race window (documented,
    /// same trade-off as `PhotoEnhancer.commitExclusively`'s reserve-then-rename
    /// path) but still never overwrites a file that exists when it checks.
    static func exclusiveMove(_ from: URL, _ to: URL) throws {
        let result = from.withUnsafeFileSystemRepresentation { source -> Int32 in
            to.withUnsafeFileSystemRepresentation { destination -> Int32 in
                guard let source, let destination else { return -1 }
                return renamex_np(source, destination, UInt32(RENAME_EXCL))
            }
        }
        if result == 0 { return }
        let code = errno
        guard code == ENOTSUP || code == EINVAL else {
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard !itemExists(to) else { throw POSIXError(.EEXIST) }
        let fallback = from.withUnsafeFileSystemRepresentation { source -> Int32 in
            to.withUnsafeFileSystemRepresentation { destination -> Int32 in
                guard let source, let destination else { return -1 }
                return rename(source, destination)
            }
        }
        if fallback != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
