import CoreImage
import Darwin
import Foundation

/// The outcome of a successful `PhotoEnhancer.enhance` call: the new
/// file's URL, and which upscale method actually produced it — surfaced
/// so `EnhanceModel` can report an honest summary (e.g. "MetalFX" vs.
/// "Lanczos — MetalFX unavailable: device unsupported") rather than
/// silently claiming one method when the other actually ran.
struct EnhanceOutcome: Sendable {
    let url: URL
    let method: SuperResolutionUpscaler.Method
    let fallbackReason: SuperResolutionUpscaler.FallbackReason?
}

enum PhotoEnhanceError: LocalizedError {
    case unreadableSource(String)
    case upscaleFailed

    var errorDescription: String? {
        switch self {
        case .unreadableSource(let path):
            return "Couldn't read \"\(path)\" — the app may not currently have permission to access it."
        case .upscaleFailed:
            return "Couldn't upscale this photo."
        }
    }
}

/// Renders a photo's current edits at full resolution, upscales the
/// result 2x (`SuperResolutionUpscaler`), and writes it as a NEW file
/// next to the original — the Enhance/Super Resolution feature's own
/// engine. No UI import, safe to call off-main (in fact required to be
/// called off-main — see below). Mirrors `PhotoExporter.export`'s own
/// shape closely, reusing its shared `context`/`renderDevice`/`write`/
/// `uniqueFileURL` rather than duplicating them, but is NOT a variant of
/// `PhotoExporter.export`: it always produces a NEW catalog entry (never
/// overwrites/replaces the source), and its output format is fixed —
/// always JPEG, regardless of the source's own format (a deliberate v1
/// scope decision, confirmed with the user: a RAW source upscaled 2x and
/// written as 16-bit TIFF would be several hundred MB for one click,
/// with no options dialog to warn about it first).
///
/// The original file is NEVER opened for writing and its sidecar is
/// NEVER touched — the non-destructive invariant this whole app is built
/// around (`CLAUDE.md`: "original files are never modified") applies
/// here exactly as it does to Export.
///
/// Edits are BAKED into the output; the new file gets no sidecar of its
/// own (a fresh, untouched photo from this app's own point of view) —
/// matches `PhotoExporter.export`'s existing behavior exactly, and
/// avoids inventing a second hand-maintained RAW-field-exclusion list
/// for fields (`rawExposureEV`, `rawWhiteBalanceNeutralPoints`, etc.)
/// that mean nothing on a flattened JPEG.
enum PhotoEnhancer {
    /// Appended to the source's own base filename before the extension —
    /// e.g. `IMG_1234.jpg` -> `IMG_1234-Enhanced-SR.jpg`. Distinct from
    /// `PhotoExporter`'s own bare `" (2)"` collision suffix (that one
    /// only ever fires on a re-export into the same folder; this one is
    /// this feature's own self-describing naming convention, matching
    /// Lightroom's own `-Enhanced`/`-Enhanced-SR` naming for its Enhance
    /// feature).
    static let filenameSuffix = "-Enhanced-SR"

    /// Slightly above `PhotoExporter`'s own JPEG default (0.9) — an
    /// upscaled image re-compressed at the SAME quality as an
    /// unscaled export would stack two lossy steps' worth of visible
    /// artifacts; a higher quality here keeps the enhanced copy closer
    /// to what the upscale step itself actually produced.
    static let jpegQuality: CGFloat = 0.95

    /// `source`'s own base filename plus `filenameSuffix`, always with a
    /// `.jpg` extension (v1's output is always JPEG — see this type's own
    /// doc comment), in `folder`. Delegates to `PhotoExporter.uniqueFileURL`
    /// for the collision-suffix behavior (including that function's own
    /// orphan-sidecar check), so Enhance and Export share exactly one
    /// naming/collision implementation. Internal (not `private`) for the
    /// same testability reason as `PhotoExporter.resized`/
    /// `uniqueDestinationURL`.
    static func destinationURL(forSource source: URL, in folder: URL) -> URL {
        let baseName = (source.lastPathComponent as NSString).deletingPathExtension + filenameSuffix
        return PhotoExporter.uniqueFileURL(baseName: baseName, fileExtension: ExportFormat.jpeg.fileExtension, in: folder)
    }

    /// Decodes `sourceURL` (RAW or otherwise, via `RawDecoder`'s shared
    /// chokepoint), renders `editState`'s edits at full resolution,
    /// upscales 2x, and writes the result as a new JPEG in `folder`,
    /// returning the outcome. Never overwrites an existing file — see
    /// `destinationURL`.
    ///
    /// MUST NOT be called on the main thread: `SuperResolutionUpscaler
    /// .upscale`'s MetalFX path blocks synchronously on
    /// `waitUntilCompleted()`. The whole upscale-and-write step (not just
    /// the write, unlike `PhotoExporter.export`) runs inside
    /// `RawDecoder.RenderGate` for a RAW source — with MetalFX, the Core
    /// Image render into the input texture is the FIRST real render of
    /// the lazy `CIRAWFilter` graph, exactly the situation `RenderGate`
    /// exists to serialize app-wide against a real deadlock risk (see
    /// `SuperResolutionUpscaler`'s own doc comment on this precondition).
    static func enhance(sourceURL: URL, editState: EditState, into folder: URL) async throws -> EnhanceOutcome {
        guard let oriented = await RawDecoder.decode(contentsOf: sourceURL, editState: editState) else {
            throw PhotoEnhanceError.unreadableSource(sourceURL.path)
        }
        let edited = EditPipeline.apply(editState, to: oriented)

        // Lives IN `folder` (a hidden dot-prefixed name), not the system
        // temp directory — reviewer-caught, round 2: `commitExclusively`
        // below uses `FileManager.linkItem`, a hard link, which requires
        // the source and destination to be on the SAME volume. Hidden so
        // it doesn't show up in the user's folder during the brief window
        // it exists. Known, accepted trade-off (reviewer-noted, round 3):
        // unlike the system temp directory, the OS never sweeps this
        // location — if the process is killed between this write and the
        // `defer` below (e.g. a crash, a force-quit), a hidden full-size
        // JPEG can be left behind indefinitely. Not fixed here (a stale-
        // temp-file sweep is a natural, isolated follow-up); logged in
        // IMPROVEMENTS.md.
        let tempURL = folder
            .appendingPathComponent(".\(UUID().uuidString)")
            .appendingPathExtension(ExportFormat.jpeg.fileExtension)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let upscaleAndWrite: @Sendable () throws -> (SuperResolutionUpscaler.Method, SuperResolutionUpscaler.FallbackReason?) = {
            guard let result = SuperResolutionUpscaler.upscale(edited, device: PhotoExporter.renderDevice, context: PhotoExporter.context) else {
                throw PhotoEnhanceError.upscaleFailed
            }
            try PhotoExporter.write(result.image, format: .jpeg, quality: jpegQuality, to: tempURL)
            return (result.method, result.fallbackReason)
        }

        let (method, fallbackReason): (SuperResolutionUpscaler.Method, SuperResolutionUpscaler.FallbackReason?)
        if RawDecoder.isRaw(sourceURL) {
            (method, fallbackReason) = try await RawDecoder.RenderGate.shared.run(upscaleAndWrite)
        } else {
            (method, fallbackReason) = try upscaleAndWrite()
        }

        // The destination name is picked, and committed, HERE — AFTER the
        // (multi-second, full-resolution) upscale ran, not up front —
        // reviewer-caught, round 1: picking it early left a real window
        // where two concurrent Enhance calls on the same photo (or an
        // Enhance racing a leftover call from a prior click) could both
        // land on the SAME name and silently clobber each other.
        //
        // Round 1's own first fix (narrow the window, then write with
        // `.withoutOverwriting` + retry) introduced a NEW regression,
        // reviewer-caught in round 2: `.withoutOverwriting` writes
        // directly to the final path, so a crash or a disk-full error
        // partway through could leave a truncated file at the real
        // destination name — exactly the corruption `.atomic` used to
        // rule out. `commitExclusively` below restores atomicity AND
        // no-overwrite together via `FileManager.linkItem` (a hard link
        // — atomic by construction, and fails outright rather than
        // partially succeeding if the name is already taken), or
        // reserve-then-rename on filesystems without hard-link support
        // (exFAT/FAT32 — see `link`'s own doc comment), rather than
        // trading one guarantee for the other.
        let outputURL = try Self.commitExclusively(tempURL) { destinationURL(forSource: sourceURL, in: folder) }

        return EnhanceOutcome(url: outputURL, method: method, fallbackReason: fallbackReason)
    }

    /// Publishes `tempURL` (an already-fully-written temp file, in the
    /// SAME folder as the eventual destination — a hard link requires
    /// same-volume) under `nextCandidate()`'s name, retrying with a NEW
    /// candidate (never the same one) on a naming collision, up to
    /// `maxRetries` times beyond the first attempt, before giving up and
    /// letting the collision error propagate. `nextCandidate` is a
    /// closure (not a single upfront `URL`) specifically so each retry
    /// re-checks the folder's current state via `destinationURL` (which
    /// itself calls `PhotoExporter.uniqueFileURL`) rather than replaying
    /// a stale candidate list computed before any write happened.
    ///
    /// Not `private`: unlike the actual filesystem race this exists to
    /// close (which needs no real test — a wrong assumption here fails
    /// SAFE, as a thrown error, never a silent clobber — reviewer's own
    /// assessment, round 2), the RETRY logic itself is fully
    /// deterministic and worth testing directly, by handing it a
    /// `nextCandidate` closure that simulates a collision without any
    /// actual concurrency.
    ///
    /// `FileManager.linkItem(at:to:)` (`link(2)`) is the primary
    /// mechanism: it creates a new directory entry pointing at
    /// `tempURL`'s SAME underlying data — a single atomic metadata
    /// operation (no partial-write window at the destination path,
    /// unlike a direct `.withoutOverwriting` write of a fresh copy) —
    /// and fails outright, leaving nothing at the destination, if a file
    /// is already there. The caller's own `defer` still removes
    /// `tempURL`'s OWN directory entry afterward; the destination's
    /// entry (and the underlying data) is unaffected by that removal.
    static func commitExclusively(_ tempURL: URL, nextCandidate: () -> URL, maxRetries: Int = 5) throws -> URL {
        var candidate = nextCandidate()
        var retriesRemaining = maxRetries
        while true {
            do {
                try Self.link(tempURL: tempURL, to: candidate)
                return candidate
            } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError && retriesRemaining > 0 {
                retriesRemaining -= 1
                candidate = nextCandidate()
            }
        }
    }

    /// Links `tempURL` to `candidate`, falling back to a reserve-then-
    /// rename sequence on filesystems that don't support hard links —
    /// reviewer-caught, round 3, verified against real exFAT/FAT32 disk
    /// images: `linkItem` fails outright (ENOTSUP) on those filesystems,
    /// which are common on SD cards and external drives — exactly the
    /// kind of volume a photo library folder is likely to live on.
    /// `.withoutOverwriting`-alone (round 1's own original fix) doesn't
    /// have this problem, but reintroduces round 2's truncation risk;
    /// this fallback keeps both guarantees on every filesystem EXCEPT
    /// for the crash window described below:
    /// `Data().write(to: candidate, options: .withoutOverwriting)`
    /// exclusively reserves the name (failing the SAME
    /// `NSFileWriteFileExistsError` a real collision would, so it
    /// naturally joins `commitExclusively`'s own existing retry path),
    /// then `atomicRename` replaces THIS PROCESS'S OWN just-created
    /// empty placeholder — never a stranger's file — with `tempURL`'s
    /// real contents. `rename(2)` is POSIX-guaranteed atomic WITH
    /// RESPECT TO OTHER PROCESSES (no observer ever sees a half-done
    /// rename) — it says nothing about surviving a crash, and exFAT/FAT
    /// drivers have no journal, unlike a hard link's own single-metadata-
    /// operation guarantee.
    ///
    /// Not airtight against every failure mode — a crash or kill in the
    /// microseconds-wide window BETWEEN the reserve and the rename (not
    /// during either individually, which stay atomic) leaves a visible,
    /// permanently-empty `<name>.jpg` at the real destination name; see
    /// IMPROVEMENTS.md D29 for this and the hidden-temp-file case it sits
    /// alongside. Narrower than round 2's original truncation risk (a
    /// zero-byte file is obviously broken, not silently corrupt-looking),
    /// but not eliminated.
    private static func link(tempURL: URL, to candidate: URL) throws {
        do {
            try FileManager.default.linkItem(at: tempURL, to: candidate)
        } catch let error as NSError where Self.isUnsupportedByFilesystem(error) {
            try Data().write(to: candidate, options: .withoutOverwriting)
            do {
                try Self.atomicRename(from: tempURL, to: candidate)
            } catch {
                // Reviewer-caught, round 4: the placeholder just reserved
                // above is ALWAYS ours (created with `.withoutOverwriting`
                // a few lines up, never a stranger's file), so removing it
                // on a rename failure is always safe — without this, a
                // failed rename would leave a visible, permanently-empty
                // `<name>-Enhanced-SR.jpg` at the real destination name, a
                // smaller-scale recurrence of the exact corrupt-file-at-
                // the-final-name problem round 2 already fixed once.
                try? FileManager.default.removeItem(at: candidate)
                throw error
            }
        }
    }

    /// True for the specific "this filesystem doesn't support hard
    /// links" failure (ENOTSUP, and EPERM as an observed variant on some
    /// filesystem drivers) — NOT true for an ordinary name collision
    /// (EEXIST), which must keep propagating to `commitExclusively`'s
    /// own retry logic unchanged.
    private static func isUnsupportedByFilesystem(_ error: NSError) -> Bool {
        guard error.domain == NSCocoaErrorDomain,
              let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
              underlying.domain == NSPOSIXErrorDomain
        else {
            return false
        }
        return underlying.code == Int(ENOTSUP) || underlying.code == Int(EPERM)
    }

    /// A direct POSIX `rename(2)` call — deliberately NOT
    /// `FileManager.replaceItemAt`, which layers additional safe-save
    /// behavior (backup files, etc.) beyond what's needed here and whose
    /// own atomicity guarantee on exFAT/FAT32 specifically wasn't
    /// independently verified. `rename(2)` is the primitive the reviewer
    /// actually measured working atomically on both filesystems.
    private static func atomicRename(from source: URL, to destination: URL) throws {
        // No force-unwraps (CLAUDE.md: none outside tests) —
        // `withUnsafeFileSystemRepresentation` hands back `nil` for a
        // path it genuinely can't represent on disk, which must throw,
        // not crash. `errno` is captured INSIDE the innermost closure,
        // immediately after `rename` returns — reviewer-caught, round 4:
        // reading it later, outside the closures, and reading it TWICE
        // (once for the code, once for `strerror`), both risk an
        // intervening call clobbering the thread-local value first.
        var capturedErrno: Int32 = 0
        let result: Int32? = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return nil }
                let status = rename(sourcePath, destinationPath)
                if status != 0 { capturedErrno = errno }
                return Int32?(status)
            }
        }
        guard let result else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(capturedErrno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(capturedErrno))]
            )
        }
    }
}
