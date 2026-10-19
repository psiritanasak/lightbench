import Foundation

/// Runs an `ImportCopyPlan`. The SOURCE is only ever read: this file never moves, renames or deletes anything but its own hidden temp
/// files (a source-text test pins that every `removeItem` here names a temp file).
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

        static let live = Environment(
            copy: { try FileManager.default.copyItem(at: $0, to: $1) },
            hash: { FileHasher.sha256Hex(ofFileAt: $0) },
            fileSize: { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int64 },
            availableBytes: { url in
                (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage
            }
        )
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
        environment: Environment = .live,
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
        for (index, item) in work.enumerated() {
            if Task.isCancelled { outcome.stoppedEarly = true; break }
            let proceed = await MainActor.run { gate() }
            guard proceed else { outcome.stoppedEarly = true; break }
            copyOne(item, skipAlreadyCopied: skipAlreadyCopied, environment: environment, runOwners: &runOwners, into: &outcome)
            progress(index + 1, work.count)
        }
        return outcome
    }

    private static func copyOne(
        _ item: ImportCopyPlan.Item, skipAlreadyCopied: Bool, environment: Environment,
        runOwners: inout [String: String], into outcome: inout Outcome
    ) {
        let fm = FileManager.default
        let folder = item.destination.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            outcome.failed.append(Failure(source: item.source, reason: "Could not create the folder: \(error.localizedDescription)"))
            return
        }

        guard let sourceHash = environment.hash(item.source), let sourceSize = environment.fileSize(item.source) else {
            outcome.failed.append(Failure(source: item.source, reason: "Could not read the file"))
            return
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
                    if environment.fileSize(candidate) == sourceSize, environment.hash(candidate) == sourceHash {
                        outcome.skippedIdentical.append(item.source)
                        outcome.skippedDestinations.append(candidate)
                        // It is byte-identical to this pair's own member, so the shared xmp beside it is this pair's: the pair's other
                        // member (if not yet copied) must keep the same base name, and any companion an interrupted run never wrote is
                        // filled in (never overwriting).
                        if runOwners[baseKey(candidate)] == nil { runOwners[baseKey(candidate)] = item.group }
                        for companion in item.companions {
                            let target = companion.destination(forPhotoAt: candidate)
                            if !RenameEngine.itemExists(target) {
                                copyCompanion(companion, to: target, photoAt: candidate, environment: environment, into: &outcome)
                            }
                        }
                        return
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
            return
        }
        guard environment.fileSize(tempURL) == sourceSize, environment.hash(tempURL) == sourceHash else {
            outcome.failed.append(Failure(source: item.source, reason: "The copy did not match the original and was discarded"))
            return
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
            return
        }
        outcome.copied.append(final)
        runOwners[baseKey(final)] = item.group

        for companion in item.companions {
            copyCompanion(companion, to: companion.destination(forPhotoAt: final), photoAt: final, environment: environment, into: &outcome)
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
