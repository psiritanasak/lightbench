import Foundation

/// Why one photo can't be renamed. ANY blocked photo makes the whole batch
/// inapplicable (all-or-nothing): a batch that renames some photos and skips
/// others would leave a half-renumbered folder.
enum RenameBlock: Equatable, Sendable {
    case notCatalogued
    /// The same photo appears more than once in the selection.
    case selectedTwice
    case template(NamingError)
    /// Two photos in the batch would end up with the same name (compared
    /// case-insensitively and ignoring NFC/NFD differences). Carries the OTHER
    /// photo's current file name.
    case collidesWithBatch(String)
    /// A file that is NOT part of this batch already has the target name.
    case targetExists
    /// The target's `.photoapp.json` sidecar already exists (possibly an
    /// orphan) — adopting it would silently apply someone else's edits.
    case targetSidecarExists
    /// Another catalogued photo (not in this batch) already points at the target path.
    case targetCatalogued
    /// The source file isn't on disk (deleted, moved, or no folder access).
    case sourceMissing
    /// This photo is open in the Editor — its debounced sidecar save would
    /// write to the OLD sidecar path after the rename (IMPROVEMENTS.md D28's hazard class).
    case openInEditor
    /// The rename's TARGET path is the photo open in the Editor (e.g. that file was deleted on disk):
    /// its next debounced sidecar save would land beside the renamed photo and hand it the wrong edits.
    case targetIsOpenInEditor

    var message: String {
        switch self {
        case .notCatalogued: return "Not in the catalog."
        case .selectedTwice: return "Selected more than once."
        case .template(let error): return error.errorDescription ?? "Invalid name."
        case .collidesWithBatch(let other): return "Same new name as \"\(other)\"."
        case .targetExists: return "A file with that name already exists."
        case .targetSidecarExists: return "A leftover edit file with that name already exists."
        case .targetCatalogued: return "Another photo in the library uses that name."
        case .sourceMissing: return "The file is missing or can't be accessed."
        case .openInEditor: return "Loaded in the Editor — open a different photo first."
        case .targetIsOpenInEditor: return "The Editor has a photo at that name — open a different photo first."
        }
    }
}

enum RenameDecision: Equatable, Sendable {
    case rename(RenameMove)
    case unchanged
    case blocked(RenameBlock)
}

struct RenamePlanEntry: Equatable, Sendable {
    var photo: Photo
    /// The rendered new file name, when the template produced one.
    var newName: String?
    var decision: RenameDecision
}

/// What the planner needs to know about the outside world — injected so the
/// planning rules are pure and unit-tested (the live values come from
/// `FileManager` and the in-memory catalog).
struct RenameEnvironment: Sendable {
    var fileExists: @Sendable (String) -> Bool
    /// The id of the catalogued photo currently at `path`, if any.
    var catalogPhotoID: @Sendable (String) -> Int64?
    /// The path of the photo open in the Editor, if any.
    var openPhotoPath: String?
}

/// The result of planning a batch rename: one entry per selected photo, in
/// the order given (the Library grid's displayed order, which is also the
/// `{seq}` order).
struct RenamePlan: Equatable, Sendable {
    var entries: [RenamePlanEntry]

    var renames: [RenameMove] {
        entries.compactMap { if case .rename(let move) = $0.decision { return move } else { return nil } }
    }

    var hasBlocked: Bool {
        entries.contains { if case .blocked = $0.decision { return true } else { return false } }
    }

    /// True only when nothing is blocked and at least one photo actually changes name.
    var isApplicable: Bool { !hasBlocked && !renames.isEmpty }

    /// Case-insensitive, normalization-insensitive comparison key for a file
    /// name. Deliberately conservative: it also refuses names that differ only
    /// by case on a case-SENSITIVE volume (an over-refusal, never an
    /// overwrite). Swift's `String ==` already treats canonically-equivalent
    /// NFC/NFD text as equal; APFS is case-insensitive by default, which
    /// `==` is not.
    static func key(forFileName name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// True when two path strings name the same file: same (case/normalization-folded) file name AND
    /// the same location once symlinks and `.`/`..` are resolved — so `/tmp/x.jpg` vs
    /// `/private/tmp/x.jpg`, or a differently-cased spelling from File > Open…, still match. (The
    /// file-name check runs first so the symlink resolution — file I/O — only happens for candidates.)
    static func isSamePath(_ a: String, _ b: String) -> Bool {
        guard key(forFileName: URL(fileURLWithPath: a).lastPathComponent)
            == key(forFileName: URL(fileURLWithPath: b).lastPathComponent)
        else { return false }
        return canonicalPath(a) == canonicalPath(b)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func key(folder: String, name: String) -> String {
        folder.lowercased() + "\u{0}" + key(forFileName: name)
    }

    static func make(
        photos allPhotos: [Photo],
        template: CompiledNamingTemplate,
        sequenceStart: Int,
        captureDates: [Int64: Date],
        environment: RenameEnvironment
    ) -> RenamePlan {
        // Renaming acts on MASTERS: a virtual copy shares its master's file (and its row follows the master's path in the catalog), so a
        // selected copy is simply left out of the batch rather than planned.
        let photos = allPhotos.filter { !$0.isVirtualCopy }
        struct Draft {
            var photo: Photo
            var folder: String
            var oldName: String
            var newName: String?
            var block: RenameBlock?
        }

        // 1. Render every name.
        var drafts: [Draft] = []
        var seenIDs: Set<Int64> = []
        for (index, photo) in photos.enumerated() {
            let url = URL(fileURLWithPath: photo.path)
            var draft = Draft(
                photo: photo, folder: url.deletingLastPathComponent().path,
                oldName: url.lastPathComponent, newName: nil, block: nil
            )
            if photo.id == nil {
                draft.block = .notCatalogued
            } else if let id = photo.id, !seenIDs.insert(id).inserted {
                draft.block = .selectedTwice
            } else {
                let context = NamingContext(
                    baseName: url.deletingPathExtension().lastPathComponent,
                    fileExtension: url.pathExtension,
                    sequenceIndex: index,
                    sequenceStart: sequenceStart,
                    captureDate: photo.id.flatMap { captureDates[$0] } ?? photo.importedAt,
                    rating: photo.rating,
                    colorLabel: photo.colorLabel,
                    flagStatus: photo.flagStatus
                )
                switch template.render(context: context) {
                case .success(let name): draft.newName = name
                case .failure(let error): draft.block = .template(error)
                }
            }
            drafts.append(draft)
        }

        // A photo whose name doesn't change is "unchanged" (`==` is canonical
        // equivalence, so an NFC/NFD-only difference is also a no-op).
        func isUnchanged(_ d: Draft) -> Bool { d.newName == d.oldName }
        func isRenaming(_ d: Draft) -> Bool { d.block == nil && d.newName != nil && !isUnchanged(d) }

        // 2. Final-name occupancy across the whole batch: every non-failed
        //    photo ends up with newName (renamed) or oldName (unchanged).
        var occupants: [String: [Int]] = [:]
        for (index, d) in drafts.enumerated() where d.block == nil {
            let finalName = d.newName ?? d.oldName
            occupants[key(folder: d.folder, name: finalName), default: []].append(index)
        }
        for (_, indices) in occupants where indices.count > 1 {
            for index in indices {
                let other = indices.first(where: { $0 != index }).map { drafts[$0].oldName } ?? ""
                drafts[index].block = .collidesWithBatch(other)
            }
        }

        // 3. Names the batch itself vacates (a chain a→b, b→c, or a swap, is legal).
        var vacatedKeys: Set<String> = []
        var vacatedSidecarKeys: Set<String> = []
        var renamingIDs: Set<Int64> = []
        for d in drafts where isRenaming(d) {
            vacatedKeys.insert(key(folder: d.folder, name: d.oldName))
            vacatedSidecarKeys.insert(key(folder: d.folder, name: d.oldName + ".photoapp.json"))
            if let id = d.photo.id { renamingIDs.insert(id) }
        }

        // 4. Per-photo checks against disk, the catalog and the Editor.
        for index in drafts.indices where isRenaming(drafts[index]) && drafts[index].block == nil {
            let d = drafts[index]
            guard let newName = d.newName, let id = d.photo.id else { continue }
            let newPath = URL(fileURLWithPath: d.folder).appendingPathComponent(newName).path
            let sameFileCaseOnly = key(forFileName: newName) == key(forFileName: d.oldName)

            if !environment.fileExists(d.photo.path) {
                drafts[index].block = .sourceMissing
            } else if let open = environment.openPhotoPath, isSamePath(open, d.photo.path) {
                drafts[index].block = .openInEditor
            } else if let open = environment.openPhotoPath, isSamePath(open, newPath), !sameFileCaseOnly {
                drafts[index].block = .targetIsOpenInEditor
            } else if !sameFileCaseOnly { // (a case-only rename's target checks are the engine's job: RENAME_EXCL + its sidecar check)
                let targetKey = key(folder: d.folder, name: newName)
                let sidecarKey = key(folder: d.folder, name: newName + ".photoapp.json")
                let sidecarPath = SidecarStore.sidecarURL(for: URL(fileURLWithPath: newPath)).path
                if environment.fileExists(newPath) && !vacatedKeys.contains(targetKey) {
                    drafts[index].block = .targetExists
                } else if environment.fileExists(sidecarPath) && !vacatedSidecarKeys.contains(sidecarKey) {
                    drafts[index].block = .targetSidecarExists
                } else if let owner = environment.catalogPhotoID(newPath), owner != id, !renamingIDs.contains(owner) {
                    drafts[index].block = .targetCatalogued
                }
            }
        }

        // 5. Assemble.
        let entries = drafts.map { d -> RenamePlanEntry in
            if let block = d.block {
                return RenamePlanEntry(photo: d.photo, newName: d.newName, decision: .blocked(block))
            }
            guard let newName = d.newName, let id = d.photo.id else {
                return RenamePlanEntry(photo: d.photo, newName: nil, decision: .blocked(.notCatalogued))
            }
            if isUnchanged(d) {
                return RenamePlanEntry(photo: d.photo, newName: newName, decision: .unchanged)
            }
            let newPath = URL(fileURLWithPath: d.folder).appendingPathComponent(newName).path
            return RenamePlanEntry(
                photo: d.photo, newName: newName,
                decision: .rename(RenameMove(photoID: id, oldPath: d.photo.path, newPath: newPath))
            )
        }
        return RenamePlan(entries: entries)
    }
}
