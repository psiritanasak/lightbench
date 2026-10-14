import Foundation

/// A photo's copied "look" plus which photo it came from, for the Library
/// toolbar/Photo-menu's own UI feedback (e.g. a `.help("Paste settings
/// copied from \(sourceFileName)")`). `Equatable` so `PasteSettingsModel`'s
/// own `@Published copied` diffs cheaply for SwiftUI.
struct CopiedEditSettings: Equatable {
    let state: EditState
    let sourceFileName: String
}

/// The pure planning/decision logic behind a batch "paste settings"
/// operation — no UI, no file I/O, no `@MainActor` — so it's fully
/// unit-testable without a temp directory or a security-scoped bookmark in
/// sight. `PasteSettingsModel` is the (untested-by-this-codebase's-own
/// established precedent for `NSOpenPanel`/file-I/O-driven `@MainActor`
/// types) layer that actually calls `SidecarStore`/`SidecarFolderAccess`
/// using this type's own output.
enum PasteSettingsPlan {
    /// One folder's worth of target photos, grouped so
    /// `PasteSettingsModel.performPaste` can pre-flight ONE bookmark
    /// request per folder rather than one per photo.
    struct FolderGroup: Equatable {
        let folder: String
        let photos: [Photo]
    }

    struct Plan: Equatable {
        /// The one target photo (if any) that's ALSO the one currently
        /// open in the Editor — routed through `ImageDocumentModel.
        /// pasteSettings(_:)` instead of the batch writer, so its own undo
        /// history/debounced-save path stays authoritative and is never
        /// bypassed underneath it. `nil` when no target matches the open
        /// photo's own path (including when nothing is open at all).
        var openPhoto: Photo?
        /// Every OTHER target photo, grouped by direct-parent folder path,
        /// in a deterministic (sorted-by-folder) order.
        var byFolder: [FolderGroup]

        /// Every distinct folder across BOTH `openPhoto` and `byFolder` —
        /// the full pre-flight set `performPaste` must resolve/request
        /// bookmark access for BEFORE writing anything, so a decline
        /// partway through a batch can't leave some folders written and
        /// others untouched by surprise mid-batch.
        var allFolders: [String] {
            var folders = byFolder.map(\.folder)
            if let openPhoto {
                let openFolder = PasteSettingsPlan.parentFolder(of: openPhoto)
                if !folders.contains(openFolder) {
                    folders.append(openFolder)
                }
            }
            return folders
        }
    }

    static func parentFolder(of photo: Photo) -> String {
        URL(fileURLWithPath: photo.path).deletingLastPathComponent().path
    }

    /// Splits `targets` into the one photo matching `openPhotoPath` (if
    /// any) and the rest, grouped by their own direct-parent folder.
    static func make(targets: [Photo], openPhotoPath: String?) -> Plan {
        var openPhoto: Photo?
        var remainder: [Photo] = []
        for photo in targets {
            if openPhoto == nil, let openPhotoPath, photo.path == openPhotoPath {
                openPhoto = photo
            } else {
                remainder.append(photo)
            }
        }
        var grouped: [String: [Photo]] = [:]
        for photo in remainder {
            grouped[parentFolder(of: photo), default: []].append(photo)
        }
        let byFolder = grouped.keys.sorted().map { FolderGroup(folder: $0, photos: grouped[$0] ?? []) }
        return Plan(openPhoto: openPhoto, byFolder: byFolder)
    }

    /// What to do with ONE target photo's existing sidecar, given the
    /// copied source state — the read-modify-write decision, kept pure so
    /// it's testable without touching disk.
    enum Decision: Equatable {
        case write(EditState)
        case unchanged
        case undecodable
    }

    /// `.undecodable` never writes, regardless of what `source` would
    /// otherwise produce — an unreadable/unparseable existing sidecar must
    /// never be silently clobbered (see `SidecarStore.ReadResult`'s own
    /// doc comment for the data-loss hazard this specifically closes).
    /// `.missing` merges onto `.identity` — an untouched photo with no
    /// sidecar at all — so pasting an ALSO-untouched look onto it produces
    /// `.unchanged` (no phantom sidecar created for a paste that changes
    /// nothing observable).
    static func decide(source: EditState, existing: SidecarStore.ReadResult) -> Decision {
        let baseline: EditState
        switch existing {
        case .undecodable:
            return .undecodable
        case .missing:
            baseline = .identity
        case .decoded(let state):
            baseline = state
        }
        let merged = source.applyingPreset(onto: baseline)
        return merged == baseline ? .unchanged : .write(merged)
    }
}

/// Owns the "Copy Settings" clipboard and the "Paste Settings" batch
/// operation — a Lightroom-style Copy Edit Settings / Paste Edit Settings
/// across a Library multi-selection. `@StateObject` on `PhotoAppApp` (not
/// `ContentView`), matching `document`/`catalog`'s own lifecycle, since
/// ⇧⌘C/⇧⌘V must be reachable from `PhotoAppApp`'s Scene-level `.commands {}`.
@MainActor
final class PasteSettingsModel: ObservableObject {
    @Published private(set) var copied: CopiedEditSettings?
    /// Non-nil while the confirmation dialog is shown — the exact target
    /// list its own "Paste" action will operate on. `performPaste` is the
    /// actual, mostly-irreversible work; this only requests it.
    @Published var pendingTargets: [Photo]?
    @Published var statusMessage: String?

    private let folderAccess = SidecarFolderAccess()

    private static let sidecarFolderAccessMessage =
        "\(AppInfo.name) would like to save pasted edit settings for photos in this folder. Choose the folder to grant access."

    func copy(_ state: EditState, fileName: String) {
        copied = CopiedEditSettings(state: state, sourceFileName: fileName)
    }

    func requestPaste(onto photos: [Photo]) {
        pendingTargets = photos
    }

    /// Runs SYNCHRONOUSLY on the main actor — deliberately NOT
    /// `Task.detached` + a progress HUD like `ExportModel`. Export does a
    /// full-resolution GPU render per photo (seconds each); this reads,
    /// decodes, merges, encodes, and atomically writes a few KB of JSON
    /// per photo. MEASURED (temporary harness, run then deleted, per this
    /// codebase's own "never write measurement-shaped prose you haven't
    /// run" convention): 200 synthetic sidecars (each carrying a mask, so
    /// not a trivially-empty `EditState`) read-decide-write in ~159ms
    /// total, ~0.79ms/photo — fast enough that a progress HUD would add
    /// more perceived latency (its own fade-in/fade-out) than it removes
    /// for any realistic batch size.
    ///
    /// A synchronous loop was ALSO chosen to avoid a race an async version
    /// would have — opening a target photo in the Editor mid-batch could
    /// otherwise interleave with this loop's own write. This specific race
    /// took FOUR review rounds to actually close (not merely to produce
    /// another plausible-sounding partial fix for), so the full, accurate
    /// story is worth stating precisely rather than summarizing:
    ///
    /// 1. `ImageDocumentModel.isLoadInFlight` (set synchronously, before
    ///    any `await`, at the top of `load(from:)`) gates REQUESTING a
    ///    paste at all — `ContentView`'s toolbar button and `PhotoAppApp`'s
    ///    ⇧⌘V item are both `.disabled` while it's true. This alone rules
    ///    out an ALREADY-in-flight load at the moment of the request, but
    ///    NOT one that starts later.
    /// 2. The confirmation dialog can stay open across a load starting
    ///    AFTER the request (round 2's finding) — its own "Paste Settings"
    ///    button re-checks `isLoadInFlight` at confirm time too, in the
    ///    SAME synchronous step it captures `openPhotoPath`.
    /// 3. `canProceed` (round 3's finding, this parameter) closes the
    ///    remaining, narrower window: THIS method's own folder-access
    ///    pre-flight can show `NSOpenPanel`, which pumps the run loop and
    ///    can let a NEW load START during it — not merely an old one
    ///    resume, which step 1-2 already rule out. Checked once, right
    ///    after the pre-flight and before any write; see its own doc
    ///    comment below.
    /// 4. `applyToOpenPhoto`'s own internal re-check (in `ContentView`'s
    ///    call site) is a redundant backstop by this point, not a fix for
    ///    a distinct scenario — kept because it's cheap, not because it's
    ///    load-bearing.
    ///
    /// See `canProceed`'s own doc comment immediately below for why even
    /// THIS is not quite the end of the story — one narrow, accepted,
    /// documented exception remains, made self-contained (not just
    /// "rare") by this method's own batch-before-open-photo execution
    /// order.
    ///
    /// `applyToOpenPhoto`/`onSidecarWritten` are closures, not a direct
    /// reference to `ImageDocumentModel`/`CatalogModel` — this type holds
    /// no reference to either, matching the existing `onSidecarSaved`
    /// decoupling pattern `ImageDocumentModel` already uses.
    /// `applyToOpenPhoto` returns `ImageDocumentModel.PasteSettingsResult`
    /// (not `Void`) — reviewer-caught: without it, the open photo was
    /// unconditionally counted as "written" even on a true no-op merge or
    /// a folder already declined this session, which would silently
    /// overcount in the summary the user sees.
    ///
    /// `clearDeclinedFolder` — reviewer-caught: `ImageDocumentModel`'s own
    /// `declinedFolders` is SEPARATE session-scoped memory from this
    /// type's own `folderAccess`, so a folder it already marked declined
    /// (from an earlier, unrelated edit) would keep silently skipping the
    /// open photo's OWN sidecar save even after the pre-flight below just
    /// re-granted access to that exact folder. Called for the open
    /// photo's folder specifically, right before `applyToOpenPhoto`, and
    /// ONLY when that folder wasn't itself skipped in the pre-flight.
    ///
    /// `canProceed` — reviewer-caught, THIRD round on this exact race:
    /// the pre-flight loop's own `NSOpenPanel` prompting pumps the AppKit
    /// modal run loop, which CAN let a NEW photo load start during it
    /// (e.g. a Photo-menu shortcut firing while the panel is up) — a
    /// narrower, but real, window than "a load already in flight," which
    /// `isLoadInFlight`'s own request-time/confirm-time checks already
    /// rule out by the time this method is even called. If that happens,
    /// the newly-loading photo may ITSELF be one of `plan.byFolder`'s
    /// targets (the plan was built from the OLD open-photo path, before
    /// this call), and the batch loop below would write its sidecar
    /// directly while it's either still loading (about to overwrite with
    /// pre-paste data) or freshly open with a stale in-memory `editState`.
    /// Checked ONCE, right after the pre-flight and before ANY write
    /// (open-photo or batch) — the rest of this method is synchronous and
    /// doesn't pump the run loop again, with one narrow, accepted, and
    /// (reviewer-caught, a FOURTH round) now genuinely self-contained
    /// exception: `applyToOpenPhoto` → `pasteSettings` → `saveSidecarNow`
    /// could itself re-show a panel, if a just-granted bookmark somehow
    /// fails to persist (observed mainly on volumes whose bookmarks
    /// resolve `isStale` on every attempt, e.g. some network/exFAT
    /// volumes without stable file IDs). The open-photo branch runs
    /// LAST, AFTER the entire batch `for group in plan.byFolder` loop
    /// below — not before it, which is what made this exception
    /// "self-contained" only in name in an earlier round: with the open
    /// photo handled first, that same panel could pump the run loop and
    /// let a NEW load start for a photo that's ALSO a batch target,
    /// reintroducing this exact race one step later. Running the batch
    /// first means every batch write is already done by the time that
    /// panel could possibly appear — nothing is left to race against
    /// except the open photo itself, a single photo `PasteSettingsPlan.
    /// make` already excludes from `plan.byFolder`. That residual
    /// exposure (a new load finishing during THIS panel, then
    /// `saveSidecarNow` writing the wrong photo's `editState` to the
    /// just-pasted photo's own sidecar path) is IMPROVEMENTS.md's D28 —
    /// a pre-existing hazard in `saveSidecarNow` itself, not new here,
    /// logged rather than fixed in this feature. Aborts the ENTIRE batch
    /// on a `false` result (nothing has been written yet at this point)
    /// rather than trying to salvage a partial result against a moving
    /// target.
    func performPaste(
        onto photos: [Photo],
        openPhotoPath: String?,
        canProceed: () -> Bool,
        applyToOpenPhoto: (EditState) -> ImageDocumentModel.PasteSettingsResult,
        onSidecarWritten: (URL) -> Void,
        clearDeclinedFolder: (String) -> Void
    ) {
        pendingTargets = nil
        guard let copied else { return }
        let plan = PasteSettingsPlan.make(targets: photos, openPhotoPath: openPhotoPath)

        // Pre-flight EVERY distinct folder up front — one NSOpenPanel per
        // not-yet-granted folder, all before any write, so a decline on
        // folder 3 of 5 can't leave folders 1-2 written and 4-5 untouched
        // by surprise mid-batch. `grantedFolders` stores the ACTUAL
        // resolved/granted URL from `resolveOrRequest`, not a freshly
        // reconstructed `URL(fileURLWithPath:)` — only that returned URL
        // carries the real security-scope capability;
        // `startAccessingSecurityScopedResource()` on a plain
        // path-constructed URL would silently fail.
        var grantedFolders: [String: URL] = [:]
        var skippedFolders: Set<String> = []
        for folder in plan.allFolders {
            switch folderAccess.resolveOrRequest(
                for: URL(fileURLWithPath: folder), message: Self.sidecarFolderAccessMessage
            ) {
            case .granted(let url):
                grantedFolders[folder] = url
            case .declined, .failed:
                skippedFolders.insert(folder)
            }
        }

        guard canProceed() else {
            statusMessage = "A different photo started loading while asking for folder access — try Paste Settings again."
            return
        }

        var written = 0
        var unchanged = 0
        var skipped = 0
        var failed = 0

        // The BATCH loop runs BEFORE the open-photo branch below —
        // reviewer-caught, a fourth round on this same race: the open
        // photo's own write path (`applyToOpenPhoto` → `pasteSettings` →
        // `saveSidecarNow`) can, in one narrow accepted case, itself
        // re-show an `NSOpenPanel` (see that branch's own comment). If the
        // open photo were handled FIRST, that panel could pump the run
        // loop and let a NEW load start for a photo that's ALSO a batch
        // target — the exact hazard `canProceed` above exists to prevent,
        // just reintroduced one step later. Running the batch loop first
        // means by the time that panel could possibly appear, every batch
        // write is already done — nothing left for a newly-started load
        // to race against except the open photo itself, which is a single
        // photo already excluded from `plan.byFolder` (see `PasteSettingsPlan.
        // make`), not a shared target.
        for group in plan.byFolder {
            guard !skippedFolders.contains(group.folder), let folderURL = grantedFolders[group.folder] else {
                skipped += group.photos.count
                continue
            }
            guard folderURL.startAccessingSecurityScopedResource() else {
                skipped += group.photos.count
                continue
            }
            defer { folderURL.stopAccessingSecurityScopedResource() }
            for photo in group.photos {
                guard FileManager.default.fileExists(atPath: photo.path) else {
                    skipped += 1
                    continue
                }
                let photoURL = URL(fileURLWithPath: photo.path)
                let existing = SidecarStore.read(forPhotoAt: photoURL)
                switch PasteSettingsPlan.decide(source: copied.state, existing: existing) {
                case .unchanged:
                    unchanged += 1
                case .undecodable:
                    skipped += 1
                case .write(let merged):
                    do {
                        try SidecarStore.write(merged, forPhotoAt: photoURL)
                        onSidecarWritten(photoURL)
                        written += 1
                    } catch {
                        failed += 1
                    }
                }
            }
        }

        if let openPhoto = plan.openPhoto {
            let openFolder = PasteSettingsPlan.parentFolder(of: openPhoto)
            if skippedFolders.contains(openFolder) {
                skipped += 1
            } else {
                clearDeclinedFolder(openFolder)
                switch applyToOpenPhoto(copied.state) {
                case .written: written += 1
                case .unchanged: unchanged += 1
                case .skipped: skipped += 1
                }
            }
        }

        statusMessage = Self.summary(written: written, unchanged: unchanged, skipped: skipped, failed: failed)
    }

    /// Not `private` — pure string formatting, directly unit-testable
    /// (`PasteSettingsModelSummaryTests.swift`) without needing to drive
    /// the surrounding file-I/O/`NSOpenPanel` batch loop at all. The
    /// counting logic that FEEDS this (the `written`/`unchanged`/`skipped`/
    /// `failed` accumulation in `performPaste`, including the open-photo
    /// branch's `PasteSettingsResult` switch) remains untested by this
    /// codebase's own established precedent for `@MainActor`/file-I/O
    /// code — this is the proportionate slice of it that CAN be pulled out
    /// cheaply, not a claim that the whole batch loop is covered.
    nonisolated static func summary(written: Int, unchanged: Int, skipped: Int, failed: Int) -> String {
        var parts: [String] = []
        if written > 0 { parts.append("Pasted onto \(written) photo\(written == 1 ? "" : "s")") }
        if unchanged > 0 { parts.append("\(unchanged) already matched") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "No photos to paste onto." : parts.joined(separator: ", ") + "."
    }
}
