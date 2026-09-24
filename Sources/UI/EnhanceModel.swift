import AppKit
import Foundation

/// The UI-facing coordinator for the Enhance/Super Resolution feature —
/// deliberately kept in `Sources/UI`, not `Sources/Rendering` (the actual
/// engine, `PhotoEnhancer`, stays UI-free), mirroring `ExportModel`'s own
/// split from `PhotoExporter`.
///
/// Follows `ExportModel.runExport`'s own `Task.detached` + `MainActor.run`
/// shape, NOT `PasteSettingsModel.performPaste`'s synchronous-on-MainActor
/// one — `PasteSettingsModel` runs synchronously specifically because its
/// own per-photo work is cheap (read/merge/encode/write a few KB of JSON);
/// Enhance does a full-resolution GPU render plus, on the MetalFX path, a
/// genuinely blocking `waitUntilCompleted()` (see `SuperResolutionUpscaler`'s
/// own doc comment) — running that on the main thread would freeze the UI
/// for the whole render, exactly what `ExportModel`'s own `Task.detached`
/// exists to avoid.
@MainActor
final class EnhanceModel: ObservableObject {
    @Published private(set) var isEnhancing = false
    @Published var statusMessage: String?

    /// `SidecarFolderAccess`'s third caller (after `ImageDocumentModel` and
    /// `PasteSettingsModel`) — reused exactly as-is, no new bookmark
    /// mechanism. A separate instance from either of those two is fine:
    /// the only real state is `UserDefaults`, which all instances share
    /// correctly (see `SidecarFolderAccess`'s own doc comment).
    private let folderAccess = SidecarFolderAccess()

    /// Enhances `sourceURL` (the currently-open photo's file, snapshotted
    /// by the caller at click time — see `ContentView`'s own toolbar
    /// action) using `editState` (also snapshotted at click time, so this
    /// reflects exactly what's on screen, including an edit still inside
    /// its debounce window, the same way Copy Settings already reads it),
    /// writing the result next to the original and registering it with
    /// `catalog`.
    ///
    /// Guards, in order: not already enhancing; `sourceURL` non-nil (no
    /// photo open); the photo must already be CATALOGUED — a photo opened
    /// via `Open…` rather than imported has no `Photo` row, and enhancing
    /// it would produce a file `CatalogModel`'s own browsing security
    /// scope was never granted for (see `CatalogModel.registerEnhancedPhoto`'s
    /// own doc comment on why that's a safe assumption ONLY when this
    /// guard holds). No race-guard analogous to Paste Settings' own
    /// `canProceed` is needed here: unlike Paste, Enhance only ever reads
    /// immutable snapshots (`sourceURL`, `editState`) taken synchronously
    /// at click time and never writes back into the open document's live
    /// state, so a photo switch mid-render can't corrupt anything this
    /// call touches — the ENTIRE method body, after this point, never
    /// reads `document` again.
    ///
    /// `isEnhancing` is set HERE, synchronously, before the `Task` even
    /// starts — reviewer-caught: an earlier version set it only inside
    /// the later `runEnhance` helper, leaving a real window (the
    /// `catalogedPhoto` await, plus the synchronous-but-potentially-slow
    /// folder-access resolution) where the guard/toolbar `.disabled`
    /// still passed, so a fast double-click (or a second click while the
    /// catalog read was suspended) could start a SECOND full-resolution
    /// render concurrently — two GPU renders at once, two registered
    /// output files, and potentially two `NSOpenPanel`s back to back.
    func enhance(sourceURL: URL?, editState: EditState, catalog: CatalogModel) {
        guard !isEnhancing, let sourceURL else { return }
        isEnhancing = true

        Task {
            defer { isEnhancing = false }

            do {
                guard try await catalog.catalogedPhoto(atPath: sourceURL.path) != nil else {
                    statusMessage = "Enhance works on photos in your Library — import this photo's folder first."
                    return
                }
            } catch let error as CatalogDatabaseError {
                // `CatalogDatabaseError` is plain `Error`, not
                // `LocalizedError` — `.localizedDescription` on it would
                // show Foundation's generic fallback text, not the actual
                // message `catalogedPhoto` constructed (e.g. "isn't ready
                // yet"). Read `.message` directly instead.
                statusMessage = error.message
                return
            } catch {
                statusMessage = error.localizedDescription
                return
            }

            let folder = sourceURL.deletingLastPathComponent()
            let outcome = folderAccess.resolveOrRequest(
                for: folder,
                message: "Allow access to “\(folder.lastPathComponent)” so the enhanced copy can be saved next to the original."
            )
            switch outcome {
            case .declined:
                // Silent, matching Paste Settings' own precedent — no
                // decline memory, since every click is an explicit new
                // attempt and re-prompting on the next one is correct,
                // not annoying (see `SidecarFolderAccess`'s own doc
                // comment on this policy choice).
                return
            case .failed(let error):
                statusMessage = error.localizedDescription
            case .granted(let grantedFolder):
                // Reviewer-caught: `NSOpenPanel` (inside `resolveOrRequest`,
                // on a first-time grant) lets the user navigate to and pick
                // a DIFFERENT folder than the one being requested — nothing
                // forces them to stay in `folder`. Writing into whatever
                // they actually picked would silently target a folder that
                // may never have been imported, breaking
                // `registerEnhancedPhoto`'s own documented precondition
                // (that folder's browsing scope is already active) and
                // producing an unreachable thumbnail/a "missing" photo on
                // next launch. Refuse rather than silently writing to the
                // wrong place.
                //
                // Uses `grantedFolder.coversAccess(to: folder)`, NOT an
                // exact-match comparison — reviewer-caught:
                // an earlier version required `grantedFolder` to BE
                // `folder` exactly, but granting a PARENT folder (e.g. the
                // whole library root, once) is a real, already-working,
                // already-shipped pattern for `ImageDocumentModel`'s own
                // sidecar saves — macOS security scoping correctly extends
                // a folder's own grant to its entire subtree. Requiring an
                // exact match broke that pattern for Enhance specifically
                // (a granted ancestor would fail this guard on every
                // single attempt). `coversAccess(to:)` accepts `folder`
                // itself OR any ancestor of it, matching
                // `resolveOrRequest`'s own persistence decision exactly so
                // the two checks can't silently disagree.
                guard grantedFolder.coversAccess(to: folder) else {
                    statusMessage = "Enhance needs access to “\(folder.lastPathComponent)” (or a parent folder containing it) — try again."
                    return
                }
                // `grantedFolder` (the SCOPE to hold) and `folder` (the
                // ACTUAL destination to write into) are deliberately kept
                // as two separate values from here on — reviewer-caught:
                // an earlier version passed a single `folder` parameter
                // used for BOTH, which was fine only in the exact-match
                // case. When `grantedFolder` is an ANCESTOR of `folder`,
                // security scope must be started/stopped on the ancestor
                // (that's what was actually granted), while the file
                // itself must still be written into `folder` — the
                // original, specific directory next to the source photo,
                // never the ancestor itself.
                await runEnhance(sourceURL: sourceURL, editState: editState, accessScope: grantedFolder, destinationFolder: folder, catalog: catalog)
            }
        }
    }

    private func runEnhance(sourceURL: URL, editState: EditState, accessScope: URL, destinationFolder: URL, catalog: CatalogModel) async {
        guard accessScope.startAccessingSecurityScopedResource() else {
            statusMessage = "Couldn't get access to the destination folder."
            return
        }
        defer { accessScope.stopAccessingSecurityScopedResource() }

        let outcome: EnhanceOutcome
        do {
            // `Task.detached` for the actual render/upscale/write — the
            // blocking part this whole class exists to keep off the main
            // thread. Writes into `destinationFolder` (never `accessScope`
            // — see this function's own call site for why those two can
            // differ).
            outcome = try await Task.detached {
                try await PhotoEnhancer.enhance(sourceURL: sourceURL, editState: editState, into: destinationFolder)
            }.value
        } catch {
            // Never a `CatalogDatabaseError` here (reviewer-noted, round
            // 2, cleanup) — `PhotoEnhancer.enhance` is a `Rendering`-layer
            // type with no `Catalog` dependency, so it can only throw
            // `PhotoEnhanceError` or a filesystem-level `NSError`; that
            // catch arm belongs on `registerEnhancedPhoto`'s own call
            // below, not here.
            statusMessage = "Enhance failed: \(error.localizedDescription)"
            return
        }

        // A SEPARATE do/catch from the render above — reviewer-caught: by
        // this point the enhanced file is already successfully ON DISK.
        // If registration fails, "Enhance failed" would be actively
        // misleading (the user has a real, usable file they'd be told
        // doesn't exist) — this needs its own, honest message. Still
        // inside the security scope started above (belt-and-braces, not a
        // measured requirement — `CatalogDatabase.insertPhotoIfNeeded`'s
        // own file-size lookup likely already works via `CatalogModel
        // .activeFolders`' own separate, already-active browsing scope
        // for this same folder, since the catalogued-photo guard in
        // `enhance` implies it; keeping the sidecar scope active too costs
        // nothing and removes any doubt).
        do {
            _ = try await catalog.registerEnhancedPhoto(at: outcome.url)
            statusMessage = Self.summary(outcome)
        } catch let error as CatalogDatabaseError {
            statusMessage = "Created “\(outcome.url.lastPathComponent)”, but couldn't add it to the Library: \(error.message)"
        } catch {
            statusMessage = "Created “\(outcome.url.lastPathComponent)”, but couldn't add it to the Library: \(error.localizedDescription)"
        }
    }

    /// Pure string formatting, pulled out of `runEnhance`'s own file-I/O
    /// flow specifically so this slice is directly testable — matching
    /// `PasteSettingsModel.summary`'s own precedent (that type's doc
    /// comment explains why the surrounding I/O stays untested by this
    /// codebase's established convention). Not `private`, same reason.
    nonisolated static func summary(_ outcome: EnhanceOutcome) -> String {
        let name = outcome.url.lastPathComponent
        switch outcome.method {
        case .metalFX:
            return "Created “\(name)” (2x, MetalFX)."
        case .lanczos:
            let reasonText = outcome.fallbackReason.map { ": \(describe($0))" } ?? ""
            return "Created “\(name)” (2x, Lanczos — MetalFX unavailable\(reasonText))."
        }
    }

    /// A short, human-readable phrase for each `FallbackReason` — the
    /// enum's own case names (`noMetalDevice`, `exceedsMaxTextureSize`,
    /// …) are fine for logs/doc comments but not for a user-facing
    /// summary string. Not `private`, same testability reason as `summary`.
    nonisolated static func describe(_ reason: SuperResolutionUpscaler.FallbackReason) -> String {
        switch reason {
        case .noMetalDevice:
            return "no Metal device"
        case .deviceUnsupported:
            return "device unsupported"
        case .exceedsMaxTextureSize:
            return "photo too large"
        case .scalerConstructionFailed:
            return "couldn't start"
        case .textureAllocationFailed:
            return "out of memory"
        case .encodeFailed(let message):
            return message
        }
    }
}
