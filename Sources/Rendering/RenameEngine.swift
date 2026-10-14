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
/// The photo's standard `<base>.xmp` (see `XMPSidecarStore`) moves WITH it, but only if the photo OWNS it (`XMPSidecarOwnership`:
/// a RAW file wins over a JPG sharing the base name, judged from the folder's files BEFORE anything moves — so Undo, which has no planner,
/// decides the same way). A photo that does not own it leaves it for its owner. A photo that has no xmp to move is refused if an orphan
/// `<newbase>.xmp` (no other photo shares that base) already sits at its destination — it would silently adopt someone else's metadata.
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
        // Decided on the pristine folder, before phase 1 moves anything (see the XMP paragraph above).
        let xmpPlans = self.xmpPlans(for: moves)
        if let conflict = xmpPlans.compactMap(\.ownershipConflict).first {
            throw Failure(message: "Renaming refused (\(conflict)). Nothing was renamed.")
        }
        // Files that belong to ONE photo and always travel with it: its edit sidecar and a darktable/digiKam-style `<file>.xmp`.
        // (The shared Adobe `<base>.xmp` is handled separately below because it can belong to a RAW sibling instead.)
        struct OwnSidecar { let url: (URL) -> URL; let tag: String; let foreignMessage: String }
        let ownSidecars = [
            OwnSidecar(url: SidecarStore.sidecarURL(for:), tag: "sidecar", foreignMessage: "an edit file already exists next to"),
            OwnSidecar(url: XMPSidecarStore.alternateSidecarURL(for:), tag: "altxmp", foreignMessage: "an XMP file already exists next to")
        ]
        do {
            // Phase 1: park every source (and its sidecars) under a temp name.
            var staged: [(move: RenameMove, tempPhoto: URL, tempOwn: [URL?], tempXMP: URL?, destinationXMPShared: Bool)] = []
            for (index, item) in moves.enumerated() {
                let old = URL(fileURLWithPath: item.oldPath)
                let folder = old.deletingLastPathComponent()
                let tempPhoto = folder.appendingPathComponent(
                    tempName(token: String(token), index: index, original: old.lastPathComponent, reserve: tempReserve)
                )
                try step(old, tempPhoto)
                var tempOwn: [URL?] = []
                for kind in ownSidecars {
                    let source = kind.url(old)
                    if somethingExists(at: source) { // lstat-aware, same as phase 2: a dangling symlink here moves with its photo
                        let temp = folder.appendingPathComponent(tempPhoto.lastPathComponent + "." + kind.tag)
                        try step(source, temp)
                        tempOwn.append(temp)
                    } else {
                        tempOwn.append(nil)
                    }
                }
                var tempXMP: URL?
                if xmpPlans[index].ownsXMP {
                    let temp = folder.appendingPathComponent(tempPhoto.lastPathComponent + ".xmp")
                    try step(XMPSidecarStore.sidecarURL(for: old), temp)
                    tempXMP = temp
                }
                staged.append((item, tempPhoto, tempOwn, tempXMP, xmpPlans[index].destinationShared))
            }
            // Phase 2: temps → final names.
            for entry in staged {
                let new = URL(fileURLWithPath: entry.move.newPath)
                // A photo with NO sidecar of its own must not land next to an existing one at
                // its new name (every sidecar this batch frees is already parked under a temp
                // name, so anything found here is foreign). Also what protects Undo, which
                // has no planner.
                for (kind, temp) in zip(ownSidecars, entry.tempOwn) where temp == nil && somethingExists(at: kind.url(new)) {
                    throw Failure(message: "\(kind.foreignMessage) \"\(new.lastPathComponent)\"")
                }
                // Same rule for the shared XMP: an orphan one (no other photo shares the destination base) is foreign metadata.
                if entry.tempXMP == nil, !entry.destinationXMPShared, somethingExists(at: XMPSidecarStore.sidecarURL(for: new)) {
                    throw Failure(message: "an XMP file already exists next to \"\(new.lastPathComponent)\"")
                }
                try step(entry.tempPhoto, new)
                for (kind, temp) in zip(ownSidecars, entry.tempOwn) {
                    if let temp { try step(temp, kind.url(new)) }
                }
                if let tempXMP = entry.tempXMP {
                    try step(tempXMP, XMPSidecarStore.sidecarURL(for: new))
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

    /// Extra bytes the temp name must leave room for: the longest suffix appended to it (`.sidecar`, `.altxmp`, `.xmp`).
    static let tempReserve = ".sidecar".utf8.count

    /// What a move does about the shared `<base>.xmp`, judged from the folder's files as they are NOW.
    struct XMPPlan: Equatable {
        /// The photo owns an existing `<oldbase>.xmp`, which therefore moves with it.
        var ownsXMP: Bool
        /// Another photo shares the destination base name — one that is NOT part of this batch, or another move in this batch landing on the
        /// same base that brings an `.xmp` of its own (a RAW+JPG pair renamed together) — so an `.xmp` there is legitimately shared.
        var destinationShared: Bool
        /// Set when the move would change WHICH photo owns a shared `.xmp` (a RAW arriving next to a JPG's xmp takes it over; an xmp-owning
        /// photo landing beside a RAW hands its metadata to that RAW). Refused: the metadata would silently change hands.
        var ownershipConflict: String?
    }

    /// One plan per move. Two passes: first who owns an existing `<oldbase>.xmp`, then whether each destination base is shared — which a
    /// partner in the SAME batch only makes true if that partner actually OWNS an xmp to bring (otherwise a foreign `<newbase>.xmp` would be
    /// adopted by a pair that has none). Safe in both orders: if the owning partner lands first its xmp is legitimately shared; if it lands
    /// second its exclusive move still refuses a pre-existing orphan.
    static func xmpPlans(for batch: [RenameMove]) -> [XMPPlan] {
        var listings: [String: [URL]] = [:] // one folder listing per folder
        func photos(inFolderOf url: URL) -> [URL] {
            let folder = url.deletingLastPathComponent()
            if let cached = listings[folder.path] { return cached }
            let listed = photoFiles(inFolder: folder)
            listings[folder.path] = listed
            return listed
        }
        func siblings(of url: URL) -> [URL] {
            let key = XMPSidecarOwnership.key(for: url)
            return photos(inFolderOf: url).filter { XMPSidecarOwnership.key(for: $0) == key }
        }
        let owns: [Bool] = batch.map { move in
            let old = URL(fileURLWithPath: move.oldPath)
            guard itemExists(XMPSidecarStore.sidecarURL(for: old)) else { return false }
            return XMPSidecarOwnership.owner(of: old, among: siblings(of: old)).standardizedFileURL.path == old.standardizedFileURL.path
        }
        let movingPaths = Set(batch.map { URL(fileURLWithPath: $0.oldPath).standardizedFileURL.path })
        let newKeys = batch.map { XMPSidecarOwnership.key(for: URL(fileURLWithPath: $0.newPath)) }
        let ownedOldXMP = Set(batch.indices.filter { owns[$0] }
            .map { XMPSidecarStore.sidecarURL(for: URL(fileURLWithPath: batch[$0].oldPath)).standardizedFileURL.path })
        return batch.enumerated().map { index, move in
            let new = URL(fileURLWithPath: move.newPath)
            let partners = batch.indices.filter { $0 != index && newKeys[$0] == newKeys[index] }
            let partnerBringsXMP = partners.contains { owns[$0] }
            let stableSharers = siblings(of: new).filter { !movingPaths.contains($0.standardizedFileURL.path) }
            // After the batch: who will own `<newbase>.xmp`, and will there be one at all?
            let landing = ([index] + partners).map { URL(fileURLWithPath: batch[$0].newPath) }
            let eventualOwner = XMPSidecarOwnership.owner(of: new, among: stableSharers + landing)
            let destXMP = XMPSidecarStore.sidecarURL(for: new)
            let willExist = (itemExists(destXMP) && !ownedOldXMP.contains(destXMP.standardizedFileURL.path)) || owns[index] || partnerBringsXMP
            let takesOwnership = eventualOwner.standardizedFileURL.path == new.standardizedFileURL.path
            var conflict: String?
            if owns[index], !takesOwnership {
                conflict = "moving \"\(URL(fileURLWithPath: move.oldPath).lastPathComponent)\" next to \"\(eventualOwner.lastPathComponent)\" would hand its XMP metadata to that photo"
            } else if !owns[index], willExist, takesOwnership, !stableSharers.isEmpty || partnerBringsXMP || itemExists(destXMP) {
                conflict = "moving \"\(URL(fileURLWithPath: move.oldPath).lastPathComponent)\" to \"\(new.lastPathComponent)\" would take over an XMP file that is already there"
            }
            return XMPPlan(ownsXMP: owns[index], destinationShared: partnerBringsXMP || !stableSharers.isEmpty, ownershipConflict: conflict)
        }
    }

    /// Photo files (supported image types per `PhotoImporter.isSupportedImage`; not `.xmp`, `.photoapp.json`, hidden files, `.AAE`/`.MOV`
    /// companions or folders) directly inside `folder`.
    static func photoFiles(inFolder folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> URL? in
            guard !name.hasPrefix(".") else { return nil }
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard PhotoImporter.isSupportedImage(url),
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            return url
        }
    }

    /// Photos in `url`'s folder whose name minus extension equals `url`'s, ignoring case.
    static func siblingPhotos(sharingBaseNameWith url: URL) -> [URL] {
        let key = XMPSidecarOwnership.key(for: url)
        return photoFiles(inFolder: url.deletingLastPathComponent()).filter { XMPSidecarOwnership.key(for: $0) == key }
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
