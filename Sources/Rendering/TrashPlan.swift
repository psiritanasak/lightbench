import Foundation

/// "Move to Trash": which files go to the Trash for a set of photos, decided WITHOUT touching anything (`TrashPlan`), and the loop that moves
/// them (`TrashEngine`). This is the one place the app ever moves an original out of its folder, and only on an explicit request.
///
/// Rules that are the point of the design (all unit-tested):
///  - Nothing is ever permanently deleted: the only file operation in this file is a `trashItem` (the Finder's Trash), reached through an
///    injectable mover. There is no `removeItem` here (a test pins that).
///  - Only regular files (or symlinks) are ever planned: a folder that was catalogued as a photo because its name ends in `.jpg`, or any
///    other kind of file-system object, is reported and left alone.
///  - A photo travels with the files that belong to it alone: its edit file (`.photoapp.json`) and a darktable-style `<file>.xmp`, unless that
///    `<file>.xmp` is ALSO the shared sidecar of a sibling called `<file>.<ext>` that stays. The shared Adobe `<base>.xmp` belongs to every
///    file with that base name (`IMG_1.CR2`, `IMG_1.JPG`, `IMG_1.MOV`, …), so the plan only CLAIMS it when nothing else with that base stays
///    (on disk, in the catalog, skipped or open) and the folder could be listed; the ENGINE then moves it last, and only if every photo
///    that shares it really reached the Trash (and not at all after a stop).
///  - Never trashed: the photo that is open in the Editor (compared by resolved path, case-insensitively), a photo whose file is not on disk.
///  - Virtual copies (several catalog rows over ONE file, each with its own `<file>.<versionKey>.photoapp.json`): trashing a MASTER takes all
///    its copies' rows and edit files with it (the file is gone for them too); trashing only a COPY removes that copy's row and edit file
///    and NEVER the shared image file (`Item.isVersionOnly`: the engine has no path to the file for it at all). A copy of the open photo is
///    skipped like the open photo itself (conservative: the open version's edit file could be among them).
///  - In the engine a companion is moved only AFTER its photo moved successfully, so a photo that fails to move keeps its edit file and XMP.
struct TrashPlan: Equatable, Sendable {
    enum CompanionKind: Equatable, Sendable { case editSidecar, alternateXMP, sharedXMP }

    struct Companion: Equatable, Sendable {
        let url: URL
        let kind: CompanionKind
    }

    struct Item: Equatable, Sendable {
        let photoID: Int64
        let photoURL: URL
        /// Other catalog rows that point at the SAME file: they go with it (their file is gone too).
        var alsoIDs: [Int64] = []
        var companions: [Companion]
        /// A virtual copy trashed on its own: `photoURL` names the SHARED file (display/open-photo checks only) and is never moved; only
        /// the copy's edit file (its sole companion, if present) goes to the Trash, and the copy's row is removed once that succeeded.
        var isVersionOnly = false
    }

    struct Skipped: Equatable, Sendable {
        enum Reason: Equatable, Sendable { case openInEditor, missingOnDisk, notAFile }
        let photoID: Int64?
        let name: String
        let reason: Reason
    }

    /// What the file system holds at a path (lstat-based: a symlink is its own kind, a dangling one still counts as present).
    enum FileKind: Equatable, Sendable { case missing, file, symlink, directory, other }

    var items: [Item] = []
    var skipped: [Skipped] = []

    var companionCount: Int { items.reduce(0) { $0 + $1.companions.count } }
    var isEmpty: Bool { items.isEmpty }

    static let systemFileKind: @Sendable (URL) -> FileKind = { url in
        guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { return .missing }
        switch type {
        case .typeRegular: return .file
        case .typeSymbolicLink: return .symlink
        case .typeDirectory: return .directory
        default: return .other
        }
    }

    /// Every entry in `folder` except hidden ones, or nil when the folder cannot be listed (then nothing about it can be assumed).
    static let systemFolderListing: @Sendable (URL) -> [URL]? = { folder in
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.filter { !$0.hasPrefix(".") }.map { folder.appendingPathComponent($0) }
    }

    /// Two paths that name the same photo for the purpose of "is it open": resolved symlinks, compared without regard to case.
    static func samePhoto(_ a: String, _ b: String) -> Bool {
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path.lowercased() }
        return canonical(a) == canonical(b)
    }

    /// `cataloguedPaths`: every photo in the catalog (a catalogued photo that stays keeps a shared `.xmp` alive).
    static func make(
        photos: [Photo],
        openPhotoPath: String?,
        cataloguedPaths: [String],
        copiesOfMasters: [Int64: [Photo]] = [:],
        fileKind: (URL) -> FileKind = systemFileKind,
        folderListing: (URL) -> [URL]? = systemFolderListing
    ) -> TrashPlan {
        var plan = TrashPlan()

        // 1. Which photos are moved at all.
        var moving: [(id: Int64, url: URL, also: [Int64])] = []
        var indexByPath: [String: Int] = [:]
        let selectedCopies = photos.filter(\.isVirtualCopy)
        for photo in photos where !photo.isVirtualCopy {
            let url = URL(fileURLWithPath: photo.path)
            let path = url.standardizedFileURL.path
            guard let id = photo.id else { continue }
            if let existing = indexByPath[path] {   // a second catalog row for the same file
                // -1 marks the open photo (skipped): its duplicate row is skipped with it, never planned.
                if existing >= 0, !moving[existing].also.contains(id), moving[existing].id != id { moving[existing].also.append(id) }
                continue
            }
            if let openPhotoPath, samePhoto(openPhotoPath, path) {
                plan.skipped.append(Skipped(photoID: id, name: photo.filename, reason: .openInEditor))
                indexByPath[path] = -1
                continue
            }
            switch fileKind(url) {
            case .missing: plan.skipped.append(Skipped(photoID: id, name: photo.filename, reason: .missingOnDisk))
            case .directory, .other: plan.skipped.append(Skipped(photoID: id, name: photo.filename, reason: .notAFile))
            case .file, .symlink:
                indexByPath[path] = moving.count
                moving.append((id, url, []))
            }
        }
        let movingPaths = Set(moving.map { $0.url.standardizedFileURL.path })

        // 1b. Virtual copies. One whose MASTER is moving rides along with it (row + edit file); any other is trashed on its own and never
        // touches the file. `copiesByMaster` is every known copy of a moving master, selected or not.
        let movingMasterIDs = Set(moving.map(\.id))
        var copiesByMaster: [Int64: [Photo]] = [:]
        for master in moving {
            var known = copiesOfMasters[master.id] ?? []
            for copy in selectedCopies where copy.masterId == master.id && !known.contains(where: { $0.id == copy.id }) { known.append(copy) }
            copiesByMaster[master.id] = known
        }
        var versionOnly: [Photo] = []
        for copy in selectedCopies {
            guard let id = copy.id else { continue }
            if let masterID = copy.masterId, movingMasterIDs.contains(masterID) { continue }
            let path = URL(fileURLWithPath: copy.path).standardizedFileURL.path
            if let openPhotoPath, samePhoto(openPhotoPath, path) {
                plan.skipped.append(Skipped(photoID: id, name: copy.versionName ?? copy.filename, reason: .openInEditor))
                continue
            }
            versionOnly.append(copy)
        }

        // 2. What stays behind, by shared base name: every catalogued photo not being moved, plus EVERYTHING else in the folders involved
        // that is not an .xmp sidecar (a `.mov` or `.psd` next to the JPEG shares the base name just as a RAW does).
        var staying: [String: [String]] = [:]
        func noteStaying(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !movingPaths.contains(path) else { return }
            staying[XMPSidecarOwnership.key(for: url), default: []].append(path)
        }
        for path in cataloguedPaths { noteStaying(URL(fileURLWithPath: path)) }
        var unlistable = Set<String>()
        var listed = Set<String>()
        var listingNames: [String: [String]] = [:] // file names per folder, to find a trashed file's version edit files on disk
        for entry in moving {
            let folder = entry.url.deletingLastPathComponent()
            let folderPath = folder.standardizedFileURL.path
            guard listed.insert(folderPath).inserted else { continue }
            guard let entries = folderListing(folder) else { unlistable.insert(folderPath); continue }
            listingNames[folderPath] = entries.map(\.lastPathComponent)
            for url in entries where url.pathExtension.lowercased() != "xmp" { noteStaying(url) }
        }

        // 3. Companions.
        // ONE set for both kinds of xmp: `a.jpg.xmp` is `a.jpg`'s darktable file AND `a.jpg.dng`'s shared sidecar; it is planned once.
        var claimedXMP = Set<String>()
        for entry in moving {
            var companions: [Companion] = []
            let folderPath = entry.url.deletingLastPathComponent().standardizedFileURL.path
            func present(_ url: URL) -> Bool { [.file, .symlink].contains(fileKind(url)) }

            let edit = SidecarStore.sidecarURL(for: entry.url)
            if present(edit) { companions.append(Companion(url: edit, kind: .editSidecar)) }

            // `<file>.xmp` is darktable's sidecar for THIS photo, but it is also the shared sidecar of a sibling named `<file>.<ext>`.
            let alternate = XMPSidecarStore.alternateSidecarURL(for: entry.url)
            if present(alternate), !unlistable.contains(folderPath), staying[XMPSidecarOwnership.key(for: alternate)]?.isEmpty != false,
               claimedXMP.insert(alternate.standardizedFileURL.path.lowercased()).inserted {
                companions.append(Companion(url: alternate, kind: .alternateXMP))
            }

            let shared = XMPSidecarStore.sidecarURL(for: entry.url)
            // Symmetric with the alternate: for `a.jpg.dng` the shared sidecar `a.jpg.xmp` is ALSO darktable's file for a staying `a.jpg` (whose
            // base key is the shared file's own key). For an ordinary `IMG_1.xmp` both keys are the same.
            if present(shared), !unlistable.contains(folderPath), staying[XMPSidecarOwnership.key(for: entry.url)]?.isEmpty != false,
               staying[XMPSidecarOwnership.key(for: shared.deletingPathExtension())]?.isEmpty != false,
               claimedXMP.insert(shared.standardizedFileURL.path.lowercased()).inserted {
                companions.append(Companion(url: shared, kind: .sharedXMP))
            }
            var also = entry.also
            var versionKeys = Set<String>()
            for copy in copiesByMaster[entry.id] ?? [] {
                guard let copyID = copy.id else { continue }
                if !also.contains(copyID) { also.append(copyID) }
                if let key = copy.versionKey { versionKeys.insert(key) }
            }
            // Also any version edit file lying beside the file that no catalog row names (an orphan): it belongs to this file and goes with it.
            versionKeys.formUnion(SidecarStore.versionSidecarKeys(inNames: listingNames[folderPath] ?? [], forFileNamed: entry.url.lastPathComponent))
            for key in versionKeys.sorted() {
                let versionFile = SidecarStore.sidecarURL(for: entry.url, versionKey: key)
                if present(versionFile) { companions.append(Companion(url: versionFile, kind: .editSidecar)) }
            }
            plan.items.append(Item(photoID: entry.id, photoURL: entry.url, alsoIDs: also, companions: companions))
        }
        for copy in versionOnly {
            guard let id = copy.id else { continue }
            let file = URL(fileURLWithPath: copy.path)
            let versionFile = SidecarStore.sidecarURL(for: copy)
            let companions = [.file, .symlink].contains(fileKind(versionFile)) ? [Companion(url: versionFile, kind: .editSidecar)] : []
            plan.items.append(Item(photoID: id, photoURL: file, companions: companions, isVersionOnly: true))
        }
        return plan
    }
}

enum TrashEngine {
    /// Moves one file to the Trash and returns where it went (nil if the system does not say). The only way anything leaves a folder here.
    typealias Mover = @Sendable (URL) throws -> URL?

    /// The real mover. Under XCTest it refuses: the test host is the real app, and a test must never put a file in a real Trash.
    static let systemTrash: Mover = { url in
        if CatalogDatabase.isRunningUnderXCTest {
            throw NSError(domain: "TrashEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Moving to the Trash is disabled in the test host."])
        }
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    /// Asked right before EACH photo moves (on the main actor, where the open photo and the busy state live).
    enum Gate: Equatable, Sendable {
        case proceed
        /// Leave this photo alone (it became the open one).
        case skipOpen
        /// Stop the whole run (something started that must not overlap a move); everything not yet moved stays.
        case stop(String)
    }

    struct Failure: Equatable, Sendable {
        let photoID: Int64
        let name: String
        let message: String
    }

    struct Outcome: Equatable, Sendable {
        /// Catalog rows whose FILE reached the Trash (a photo's aliases included): exactly these lose their row.
        var trashedIDs: [Int64] = []
        var failures: [Failure] = []
        var companionsTrashed = 0
        var companionsFailed = 0
        /// Photos left alone at the last moment because they became the open photo.
        var lateSkippedOpen: [String] = []
        /// Set when the gate stopped the run; `notAttempted` photos were not touched.
        var stoppedBecause: String?
        var notAttempted = 0
    }

    /// Photo first; its own edit file only after it succeeded; every `.xmp` (the shared `<base>.xmp` and the darktable `<file>.xmp`) is DEFERRED to
    /// the end and moved only if the photo it was planned for AND every other planned photo that could own the same file reached the Trash (one
    /// that failed, was skipped late or was never reached keeps it). A stopped run moves no `.xmp` at all (an orphan is the conservative
    /// outcome). A failed photo keeps its row, edit file and XMP.
    static func apply(
        _ plan: TrashPlan, mover: Mover = systemTrash,
        gate: @MainActor (TrashPlan.Item) -> Gate = { _ in .proceed }
    ) async -> Outcome {
        var outcome = Outcome()
        var trashedKeys = Set<String>()
        var notTrashedKeys = Set<String>()
        // `ownerKey` must have been trashed; every key in `mustNotStay` (the photos that may share the file) must not be in `notTrashedKeys`.
        var deferredXMP: [(url: URL, ownerKey: String, keys: [String])] = []

        for (index, item) in plan.items.enumerated() {
            let key = XMPSidecarOwnership.key(for: item.photoURL)
            switch await gate(item) {
            case .stop(let message):
                outcome.stoppedBecause = message
                outcome.notAttempted = plan.items.count - index
                return outcome
            case .skipOpen:
                outcome.lateSkippedOpen.append(item.photoURL.lastPathComponent)
                if !item.isVersionOnly { notTrashedKeys.insert(key) }
                continue
            case .proceed: break
            }
            if item.isVersionOnly {
                // A virtual copy on its own: ONLY its edit file may move; the shared image file (`photoURL`) is never handed to the mover.
                var moved = true
                for companion in item.companions where companion.kind == .editSidecar {
                    do {
                        _ = try mover(companion.url)
                        outcome.companionsTrashed += 1
                    } catch {
                        moved = false
                        outcome.companionsFailed += 1
                        outcome.failures.append(Failure(photoID: item.photoID, name: companion.url.lastPathComponent, message: error.localizedDescription))
                    }
                }
                if moved { outcome.trashedIDs.append(item.photoID) }
                continue
            }
            do {
                _ = try mover(item.photoURL)
            } catch {
                outcome.failures.append(Failure(photoID: item.photoID, name: item.photoURL.lastPathComponent, message: error.localizedDescription))
                notTrashedKeys.insert(key)
                continue
            }
            outcome.trashedIDs.append(item.photoID)
            outcome.trashedIDs.append(contentsOf: item.alsoIDs)
            trashedKeys.insert(key)
            for companion in item.companions {
                switch companion.kind {
                case .sharedXMP:
                    // `a.jpg.xmp` (the shared sidecar of `a.jpg.dng`) is also darktable's file for `a.jpg`, whose key is the shared file's own key.
                    deferredXMP.append((companion.url, key, [key, XMPSidecarOwnership.key(for: companion.url.deletingPathExtension())]))
                case .alternateXMP:
                    // `a.jpg.xmp` may also be the shared sidecar of a sibling `a.jpg.<ext>` (whose base key is the alternate's own key).
                    deferredXMP.append((companion.url, key, [key, XMPSidecarOwnership.key(for: companion.url)]))
                case .editSidecar:
                    do {
                        _ = try mover(companion.url)
                        outcome.companionsTrashed += 1
                    } catch {
                        outcome.companionsFailed += 1
                    }
                }
            }
        }
        for entry in deferredXMP where trashedKeys.contains(entry.ownerKey) && entry.keys.allSatisfy({ !notTrashedKeys.contains($0) }) {
            do {
                _ = try mover(entry.url)
                outcome.companionsTrashed += 1
            } catch {
                outcome.companionsFailed += 1
            }
        }
        return outcome
    }
}
