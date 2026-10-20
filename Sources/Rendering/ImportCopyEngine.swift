import Foundation

/// Runs an `ImportCopyPlan`. In `.copy` mode the SOURCE is only ever read. In `.move` mode an original (and the companions whose copies
/// landed) leaves the source folder ONLY through the injected `mover` — the Finder's Trash, never a permanent delete — and only after its
/// copy is verified AGAIN on the destination disk (uncached read) and the original is confirmed unchanged. This file itself never calls
/// `trashItem`, `moveItem` or removes anything but its own hidden temp files (a source-text test pins that).
///
/// Per photo: copy → hidden temp file in the destination folder → verify (size, then SHA-256 against the source) → publish under the final
/// name with the same never-overwrite commit `PhotoEnhancer` uses (`commitExclusively`: a hard link, with a reserve+rename fallback for
/// exFAT/FAT cards) → companions (edit file, XMP) LAST and only after the photo itself is in place. A photo that fails verification leaves
/// nothing at its final name; the run continues with the next one.
enum ImportCopyEngine {
    struct Outcome: Equatable, Sendable {
        /// Final URLs of the photos now in the destination.
        var copied: [URL] = []
        /// Sources skipped because an identical file (same content) was already in the destination (under the planned name or a " (2)" one).
        var skippedIdentical: [URL] = []
        /// Where those identical files are, so the Library can register any of them an earlier, interrupted run never added.
        var skippedDestinations: [URL] = []
        var failed: [Failure] = []
        /// Companion files that could not be copied (the photo itself is fine).
        var companionFailures: [Failure] = []
        /// Planned-but-blocked photos from the plan (not regular files, name too long...).
        var blocked: [Failure] = []
        /// True when the run ended early (gate said stop, or the task was cancelled); the rest was left untouched.
        var stoppedEarly = false
        /// `.move` only: originals now in the Trash (the photo itself; companions are counted below).
        var movedToTrash: [URL] = []
        /// `.move` only: copied (or already there) but the original was NOT moved — it is still on the card — with the reason.
        var notMoved: [Failure] = []
        /// `.move` only: edit / XMP files of moved photos that went to the Trash with them, and those that could not.
        var companionsTrashed = 0
        var companionsNotTrashed = 0
    }

    struct Failure: Equatable, Sendable {
        let source: URL
        let reason: String
    }

    /// Disk operations, injectable so tests can corrupt a copy or fail the Nth file.
    struct Environment: Sendable {
        var copy: @Sendable (_ source: URL, _ temp: URL) throws -> Void
        var hash: @Sendable (URL) -> String?
        var fileSize: @Sendable (URL) -> Int64?
        var availableBytes: @Sendable (URL) -> Int64?
        /// `.move`: the digest of a COMMITTED copy read back from the disk (uncached), to prove the bytes are really there.
        var hashUncached: @Sendable (URL) -> String? = { FileHasher.sha256Hex(ofFileAt: $0, uncached: true) }
        /// `.move`: forces a committed copy out to the destination disk (`F_FULLFSYNC`, else `fsync`) BEFORE its original may leave. False means
        /// "not confirmed": the original stays.
        var flush: @Sendable (URL) -> Bool = { FileHasher.flushToDisk($0) }
        /// `.move`: the entries of a source folder (nil when it cannot be listed), to see whether a staying sibling still needs a shared xmp.
        var folderListing: @Sendable (URL) -> [URL]? = TrashPlan.systemFolderListing

        static let live = Environment(
            copy: { try FileManager.default.copyItem(at: $0, to: $1) },
            hash: { FileHasher.sha256Hex(ofFileAt: $0) },
            fileSize: { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int64 },
            availableBytes: { url in
                let keys = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
                let posix = (try? FileManager.default.attributesOfFileSystem(forPath: url.path))?[.systemFreeSize] as? Int64
                return bestAvailable(important: keys?.volumeAvailableCapacityForImportantUsage, plain: keys.flatMap { $0.volumeAvailableCapacity }.map(Int64.init), posix: posix)
            }
        )
    }

    /// The largest free-space figure any source reports, or nil when none does. The "important usage" key reads 0 on some volumes (an
    /// exFAT disk image, found live 2026-10-19: "The destination has Zero KB free" on an empty volume), so a single source cannot be trusted;
    /// a genuinely full volume reports 0 from all of them.
    static func bestAvailable(important: Int64?, plain: Int64?, posix: Int64?) -> Int64? {
        [important, plain, posix].compactMap { $0 }.max()
    }

    /// A message when the destination volume cannot hold the copies (with 5% + 10 MB headroom); nil when it can or the space is unknown.
    static func spaceProblem(plan: ImportCopyPlan, destination: URL, environment: Environment = .live) -> String? {
        let needed = plan.totalBytes
        // `destination` may not exist yet; ask its nearest existing ancestor (the same volume).
        var probe = destination
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        guard needed > 0, let available = environment.availableBytes(probe) else { return nil }
        let required = needed + needed / 20 + 10_000_000
        guard available < required else { return nil }
        let format = ByteCountFormatter()
        format.countStyle = .file
        return "The destination has \(format.string(fromByteCount: available)) free; the copies need about \(format.string(fromByteCount: required))."
    }

    /// `gate` runs on the main actor before EACH photo and returns false to stop the run (a tool became busy, the photo library changed
    /// under it...); the photos not yet reached are left alone. `progress(done, total)` counts planned copies.
    static func apply(
        plan: ImportCopyPlan,
        skipAlreadyCopied: Bool,
        mode: ImportCopyOptions.Mode = .copy,
        environment: Environment = .live,
        mover: @escaping TrashEngine.Mover = TrashEngine.systemTrash,
        isProtected: @MainActor @Sendable (URL) -> Bool = { _ in false },
        gate: @MainActor @Sendable () -> Bool = { true },
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> Outcome {
        var outcome = Outcome()
        for blocked in plan.blockedItems {
            if case .blocked(let reason) = blocked.kind { outcome.blocked.append(Failure(source: blocked.source, reason: reason)) }
        }
        let work = plan.copyItems
        // Which source pair wrote each base name in the destination during THIS run: a RAW+JPG pair from one source folder legitimately
        // shares a base name and one `<base>.xmp`, so its second member may use it; every other photo or xmp already carrying that base
        // name belongs to someone else and sends the new photo to a " (2)" name.
        var runOwners: [String: String] = [:]
        var move = MoveState(mode: mode, mover: mover, groupTotals: Dictionary(grouping: work, by: \.group).mapValues(\.count))
        for (index, item) in work.enumerated() {
            if Task.isCancelled { outcome.stoppedEarly = true; break }
            let proceed = await MainActor.run { gate() }
            guard proceed else { outcome.stoppedEarly = true; break }
            let pending = copyOne(
                item, skipAlreadyCopied: skipAlreadyCopied, mode: mode, environment: environment, runOwners: &runOwners, into: &outcome
            )
            // `.move` only: an original that is the photo OPEN in the Editor is copied but never trashed (its debounced save would recreate an
            // edit file next to a trashed photo). Asked NOW, after the copy, so a photo opened while it was being copied is caught too.
            if let pending {
                let openNow = await MainActor.run { isProtected(pending.item.source) }
                trashOriginal(pending, protected: openNow, environment: environment, move: &move, into: &outcome)
            }
            progress(index + 1, work.count)
        }
        // A shared `<base>.xmp` is moved last, and never by a run that was stopped (an orphan xmp is the conservative outcome).
        if mode == .move {
            if outcome.stoppedEarly { outcome.companionsNotTrashed += move.sharedXMPs.count } else { trashSharedXMPs(move: move, environment: environment, into: &outcome) }
        }
        return outcome
    }

    /// What a `.move` run tracks across photos.
    private struct MoveState {
        let mode: ImportCopyOptions.Mode
        let mover: TrashEngine.Mover
        let groupTotals: [String: Int]
        /// Photos of each source pair whose copy is in place AND whose original reached the Trash.
        var groupDone: [String: Int] = [:]
        /// Shared xmps whose copy landed, waiting for the end of the run.
        var sharedXMPs: [(group: String, source: URL)] = []
    }

    /// Everything needed to trash one original once it is safe (`.move` only); built by `copyOne`, acted on by `apply` after a FRESH
    /// open-photo check (a photo opened while its own copy was running must still stay).
    private struct PendingMove {
        let item: ImportCopyPlan.Item
        let committed: URL
        let sourceHash: String
        let sourceSize: Int64
        let landedCompanions: [ImportCopyPlan.Companion]
        let companionProblem: String?
    }

    @discardableResult
    private static func copyOne(
        _ item: ImportCopyPlan.Item, skipAlreadyCopied: Bool, mode: ImportCopyOptions.Mode, environment: Environment,
        runOwners: inout [String: String], into outcome: inout Outcome
    ) -> PendingMove? {
        let fm = FileManager.default
        let folder = item.destination.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            outcome.failed.append(Failure(source: item.source, reason: "Could not create the folder: \(error.localizedDescription)"))
            return nil
        }

        guard let sourceHash = environment.hash(item.source), let sourceSize = environment.fileSize(item.source) else {
            outcome.failed.append(Failure(source: item.source, reason: "Could not read the file"))
            return nil
        }

        let base = item.destination.deletingPathExtension().lastPathComponent
        let ext = item.destination.pathExtension

        // Already copied? Walk the SAME name sequence the copy would use (the planned name, then " (2)", " (3)"…): an earlier run may have put
        // the photo under a later one (its planned name was taken, or blocked by someone's sidecar), and a repeat import must not add
        // another copy each time. Stop at the first name the copy itself would accept.
        func name(_ attempt: Int) -> URL {
            let text = attempt == 0 ? base : PhotoExporter.baseNameFitting(base, suffix: " (\(attempt + 1))", fileExtension: ext)
            return ext.isEmpty ? folder.appendingPathComponent(text) : folder.appendingPathComponent(text).appendingPathExtension(ext)
        }
        if skipAlreadyCopied {
            for attempt in 0..<1000 {
                let candidate = name(attempt)
                if RenameEngine.itemExists(candidate) {
                    // Only a REGULAR file that is not the source itself can be "the copy": a symlink (even to the source) or the source file
                    // (a destination that is, or contains, the source's own folder) must never count — Move would trash the only copy.
                    if TrashPlan.systemFileKind(candidate) == .file, !sameFile(candidate, item.source),
                       environment.fileSize(candidate) == sourceSize, environment.hash(candidate) == sourceHash {
                        outcome.skippedIdentical.append(item.source)
                        outcome.skippedDestinations.append(candidate)
                        // It is byte-identical to this pair's own member, so the shared xmp beside it is this pair's: the pair's other
                        // member (if not yet copied) must keep the same base name, and any companion an interrupted run never wrote is
                        // filled in (never overwriting).
                        if runOwners[baseKey(candidate)] == nil { runOwners[baseKey(candidate)] = item.group }
                        var landed: [ImportCopyPlan.Companion] = []
                        var companionProblem: String?
                        for companion in item.companions {
                            let target = companion.destination(forPhotoAt: candidate)
                            if RenameEngine.itemExists(target) {
                                // Already there: only the same bytes count as "landed" (a newer edit file on the card must not be orphaned).
                                if companionLanded(companion, at: target, mode: mode, environment: environment) {
                                    landed.append(companion)
                                } else {
                                    companionProblem = "a different or unverifiable \(companion.source.lastPathComponent) is already at the destination"
                                }
                            } else if copyCompanion(companion, to: target, photoAt: candidate, environment: environment, into: &outcome),
                                      companionLanded(companion, at: target, mode: mode, environment: environment) {
                                landed.append(companion)
                            } else {
                                companionProblem = "\(companion.source.lastPathComponent) could not be copied and verified"
                            }
                        }
                        return mode == .move
                            ? PendingMove(item: item, committed: candidate, sourceHash: sourceHash, sourceSize: sourceSize,
                                          landedCompanions: landed, companionProblem: companionProblem)
                            : nil
                    }
                } else if isFree(candidate, group: item.group, runOwners: runOwners) {
                    break
                }
            }
        }

        let tempURL = folder.appendingPathComponent(".\(UUID().uuidString).importcopy.tmp")
        defer { try? fm.removeItem(at: tempURL) }
        do {
            try environment.copy(item.source, tempURL)
        } catch {
            outcome.failed.append(Failure(source: item.source, reason: "Copy failed: \(error.localizedDescription)"))
            return nil
        }
        guard environment.fileSize(tempURL) == sourceSize, environment.hash(tempURL) == sourceHash else {
            outcome.failed.append(Failure(source: item.source, reason: "The copy did not match the original and was discarded"))
            return nil
        }

        let final: URL
        do {
            // The first free name starting at the planned one: nothing there, and no edit file, `<file>.xmp` or someone else's shared
            // `<base>.xmp` that the new photo would silently adopt. Retried (next free name) if a name is taken between check and commit.
            var attempt = 0
            func nextFree() -> URL {
                while attempt < 1000 {
                    let candidate = name(attempt)
                    attempt += 1
                    if isFree(candidate, group: item.group, runOwners: runOwners) { return candidate }
                }
                // No free name in 1000 tries: hand the commit a name that cannot be created (the temp file itself), so it fails cleanly.
                return tempURL
            }
            final = try PhotoEnhancer.commitExclusively(tempURL, nextCandidate: nextFree)
        } catch {
            outcome.failed.append(Failure(source: item.source, reason: "Could not save the copy: \(error.localizedDescription)"))
            return nil
        }
        outcome.copied.append(final)
        runOwners[baseKey(final)] = item.group

        var copiedCompanions: [ImportCopyPlan.Companion] = []
        var companionProblem: String?
        for companion in item.companions {
            let target = companion.destination(forPhotoAt: final)
            if copyCompanion(companion, to: target, photoAt: final, environment: environment, into: &outcome),
               companionLanded(companion, at: target, mode: mode, environment: environment) {
                copiedCompanions.append(companion)
            } else {
                companionProblem = "\(companion.source.lastPathComponent) could not be copied and verified"
            }
        }
        return mode == .move
            ? PendingMove(item: item, committed: final, sourceHash: sourceHash, sourceSize: sourceSize,
                          landedCompanions: copiedCompanions, companionProblem: companionProblem)
            : nil
    }

    /// Whether a companion's copy at `target` really holds the source's bytes. In `.copy` mode a copy that landed is enough (nothing leaves the
    /// card); in `.move` the companion — the user's whole edit — gets the photo's proof: a separate regular file, a readable source (two unreadable
    /// files are NOT "identical"), the same size and SHA-256, flushed to the destination disk.
    private static func companionLanded(_ companion: ImportCopyPlan.Companion, at target: URL, mode: ImportCopyOptions.Mode, environment: Environment) -> Bool {
        guard mode == .move else { return true }
        guard TrashPlan.systemFileKind(target) == .file, !sameFile(target, companion.source),
              let sourceHash = environment.hash(companion.source), let size = environment.fileSize(companion.source),
              environment.fileSize(target) == size, environment.hash(target) == sourceHash else { return false }
        return environment.flush(target)
    }

    /// True when both paths are the same file (same device and inode) or resolve to the same path.
    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        if a.withUnsafeFileSystemRepresentation({ $0.map { stat($0, &sa) == 0 } ?? false }),
           b.withUnsafeFileSystemRepresentation({ $0.map { stat($0, &sb) == 0 } ?? false }), sa.st_dev == sb.st_dev, sa.st_ino == sb.st_ino {
            return true
        }
        return a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Move (originals to the Trash)

    /// `.move` only. The original goes to the Trash only if: it is not the photo open in the Editor; every companion it travels with landed (or was
    /// already identical at the destination); the committed copy is a regular file other than the original, was flushed to the destination disk
    /// (`F_FULLFSYNC`), and has the original's size and SHA-256 when read back; and the original still has the digest it had when it was copied
    /// (a camera or another app did not change it meanwhile). Then its companions follow (photo first, so a photo that cannot move keeps its edit
    /// file and XMP); the shared `<base>.xmp` is deferred to the end of the run. Anything that fails leaves the original on the card and says why.
    private static func trashOriginal(
        _ pending: PendingMove, protected: Bool, environment: Environment, move: inout MoveState, into outcome: inout Outcome
    ) {
        let item = pending.item, committed = pending.committed, sourceHash = pending.sourceHash, sourceSize = pending.sourceSize
        func keep(_ reason: String) { outcome.notMoved.append(Failure(source: item.source, reason: reason)) }
        if protected { keep("It is open in the Editor, so the original was left where it is"); return }
        if let companionProblem = pending.companionProblem { keep("\(companionProblem), so the original was left with its edit / XMP files"); return }
        guard TrashPlan.systemFileKind(committed) == .file, !sameFile(committed, item.source) else {
            keep("The copy is not a separate file, so the original was left where it is")
            return
        }
        guard environment.flush(committed) else {
            keep("The copy could not be flushed to the destination disk, so the original was left where it is")
            return
        }
        guard environment.fileSize(committed) == sourceSize, environment.hashUncached(committed) == sourceHash else {
            keep("The copy could not be confirmed on the destination disk, so the original was left where it is")
            return
        }
        guard environment.fileSize(item.source) == sourceSize, environment.hash(item.source) == sourceHash else {
            keep("The original changed while it was being copied, so it was left where it is")
            return
        }
        do {
            _ = try move.mover(item.source)
        } catch {
            keep("Could not move the original to the Trash: \(error.localizedDescription)")
            return
        }
        // A mover that reports success but left the file in place has not moved anything.
        guard !RenameEngine.itemExists(item.source) else {
            keep("The Trash did not take the original, so it is still where it was")
            return
        }
        outcome.movedToTrash.append(item.source)
        move.groupDone[item.group, default: 0] += 1
        for companion in pending.landedCompanions {
            if companion.kind == .sharedXMP {
                move.sharedXMPs.append((item.group, companion.source))
            } else if trashCompanion(companion.source, mover: move.mover) {
                outcome.companionsTrashed += 1
            } else {
                outcome.companionsNotTrashed += 1
            }
        }
    }

    /// True when the file really left its place.
    private static func trashCompanion(_ url: URL, mover: TrashEngine.Mover) -> Bool {
        // Success is "did not throw" (the system may report no destination URL), and the file must really be gone.
        do { _ = try mover(url) } catch { return false }
        return !RenameEngine.itemExists(url)
    }

    /// The shared `<base>.xmp` of a source pair goes only when EVERY photo of the pair has been copied and trashed, its own copy landed, and no
    /// other file with that base name (a video, a thumbnail) is staying in the folder to need it. A folder that cannot be listed keeps it.
    private static func trashSharedXMPs(move: MoveState, environment: Environment, into outcome: inout Outcome) {
        let moved = Set(outcome.movedToTrash.map { $0.standardizedFileURL.path })
        for entry in move.sharedXMPs {
            guard move.groupDone[entry.group] == move.groupTotals[entry.group] else { outcome.companionsNotTrashed += 1; continue }
            let key = XMPSidecarOwnership.key(for: entry.source)
            guard let listing = environment.folderListing(entry.source.deletingLastPathComponent()) else {
                outcome.companionsNotTrashed += 1
                continue
            }
            let staying = listing.contains { url in
                url.pathExtension.lowercased() != "xmp" && XMPSidecarOwnership.key(for: url) == key && !moved.contains(url.standardizedFileURL.path)
            }
            guard !staying else { outcome.companionsNotTrashed += 1; continue }
            if trashCompanion(entry.source, mover: move.mover) { outcome.companionsTrashed += 1 } else { outcome.companionsNotTrashed += 1 }
        }
    }

    /// How the file system compares names: case- and Unicode-normalisation-insensitively.
    private static func baseKey(_ url: URL) -> String {
        url.deletingPathExtension().path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// True when `candidate` can take a new photo of source pair `group` without it silently adopting anyone's sidecar or becoming half of a
    /// pair it is not part of: nothing at the name, no edit file or `<file>.xmp` for it, and — unless THIS run already wrote that base name
    /// for the same source pair — no other photo with the same base name (a different extension) and no shared `<base>.xmp`.
    private static func isFree(_ candidate: URL, group: String, runOwners: [String: String]) -> Bool {
        // `itemExists` is an lstat: a dangling symlink counts as taken (`FileManager.fileExists` would call it absent).
        if RenameEngine.itemExists(candidate) { return false }
        if RenameEngine.itemExists(SidecarStore.sidecarURL(for: candidate)) { return false }
        if RenameEngine.itemExists(XMPSidecarStore.alternateSidecarURL(for: candidate)) { return false }
        // Another photo with the same base name (compared normalisation- and case-insensitively), or a shared `<base>.xmp`.
        let key = baseKey(candidate)
        let sameBase = RenameEngine.photoFiles(inFolder: candidate.deletingLastPathComponent()).contains { baseKey($0) == key }
            || RenameEngine.itemExists(XMPSidecarStore.sidecarURL(for: candidate))
        return !sameBase || runOwners[key] == group
    }

    /// Never overwrites: an existing file at the companion's name is left alone and reported. Returns whether it was copied.
    @discardableResult
    private static func copyCompanion(
        _ companion: ImportCopyPlan.Companion, to target: URL, photoAt final: URL, environment: Environment, into outcome: inout Outcome
    ) -> Bool {
        let fm = FileManager.default
        let tempURL = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).importcopy.tmp")
        defer { try? fm.removeItem(at: tempURL) }
        do {
            try environment.copy(companion.source, tempURL)
            _ = try PhotoEnhancer.commitExclusively(tempURL, nextCandidate: { target }, maxRetries: 0)
            return true
        } catch {
            outcome.companionFailures.append(Failure(
                source: companion.source, reason: "Not copied next to \(final.lastPathComponent): \(error.localizedDescription)"
            ))
            return false
        }
    }
}
