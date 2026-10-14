import AppKit
import Foundation

/// Coordinates the Library's "Write Metadata to XMP…" and "Read Metadata from XMP…" commands (rating, reject, colour label,
/// keywords ⇄ standard `.xmp` sidecars). Owned by `CatalogModel` like `merge`, so the Scene-level Photo menu and the selection menu
/// reach it; `XMPDialogModifier` presents the confirmation, progress and result. Writing happens ONLY when the user asks.
///
/// Flow: a menu item REQUESTS -> `pending` + a confirmation dialog -> `confirm` resolves write access to each distinct folder (one prompt
/// per not-yet-granted folder, via `SidecarFolderAccess`), then reads or writes detached. Writes are merges (`XMPSidecarStore`): other
/// tags in an existing `.xmp` are kept and an unreadable one is never overwritten. The original photos are never modified.
@MainActor
final class XMPModel: ObservableObject {
    enum Kind: Equatable { case read, write }

    struct Request: Equatable {
        let kind: Kind
        let photos: [Photo]
    }

    /// What a run did, for the result alert.
    struct Result: Equatable {
        var kind: Kind
        /// Write: sidecars written. Read: photos whose Library data changed.
        var changed = 0
        /// Read: photos whose file said nothing new.
        var unchanged = 0
        /// Read: photos with no sidecar and no embedded XMP.
        var noXMP = 0
        /// Write: a JPEG/etc. that shares `<base>.xmp` with a RAW sibling, which owns it.
        var sharedWithRaw = 0
        /// An existing `.xmp` that could not be read or parsed (left untouched).
        var unreadable = 0
        var failed = 0
        /// Photos in folders the user did not grant access to.
        var noAccess = 0
    }

    @Published var pending: Request? { didSet { publishBusy() } }
    @Published private(set) var isWorking = false { didSet { publishBusy() } }
    @Published var statusMessage: String?

    var isBusy: Bool { isWorking || pending != nil }

    private weak var catalog: CatalogModel?
    private func publishBusy() { catalog?.xmpBusy = isBusy }

    private let folderAccess: SidecarFolderAccessing

    init(folderAccess: SidecarFolderAccessing = SidecarFolderAccess()) {
        self.folderAccess = folderAccess
    }

    // MARK: - Request

    func request(_ kind: Kind, photos: [Photo], catalog: CatalogModel) {
        self.catalog = catalog
        guard !isBusy else { return }
        guard !catalog.isRenameInProgress else { statusMessage = CatalogModel.renameInProgressMessage; return }
        guard !photos.isEmpty else { statusMessage = "Select at least one photo first."; return }
        pending = Request(kind: kind, photos: photos)
    }

    func cancel() { pending = nil }

    // MARK: - Run

    /// Runs `request` (the value the dialog handed its button, not `pending`, which may already be cleared).
    func confirm(_ request: Request, catalog: CatalogModel) {
        self.catalog = catalog
        guard !isWorking else { return }
        pending = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            guard !catalog.isRenameInProgress else { statusMessage = CatalogModel.renameInProgressMessage; return }
            await run(request, catalog: catalog)
        }
    }

    private func run(_ request: Request, catalog: CatalogModel) async {
        // 1. Folder access: one prompt per distinct folder not yet granted.
        var scopes: [String: URL] = [:]       // folder path -> granted scope
        var declinedFolders = Set<String>()
        let folders = Self.distinctFolders(of: request.photos)
        for folder in folders {
            switch folderAccess.resolveOrRequest(
                for: folder,
                message: "Allow access to “\(folder.lastPathComponent)” so XMP sidecars can be \(request.kind == .write ? "written" : "read") there."
            ) {
            case .declined: declinedFolders.insert(folder.standardizedFileURL.path)
            case .failed(let error): statusMessage = error.localizedDescription; return
            case .granted(let granted):
                if granted.coversAccess(to: folder) { scopes[folder.standardizedFileURL.path] = granted } else { declinedFolders.insert(folder.standardizedFileURL.path) }
            }
        }
        // A modal prompt above can pump the run loop: re-check before touching anything.
        guard !catalog.isRenameInProgress else { statusMessage = CatalogModel.renameInProgressMessage; return }

        var result = Result(kind: request.kind)
        // Fresh rows: the ones in `request` predate the folder prompt(s), during which the grid stayed interactive.
        let fresh = await catalog.freshPhotos(ids: request.photos.compactMap(\.id))
        let reachable = fresh.filter { scopes[Self.folderPath(of: $0)] != nil }
        result.noAccess = fresh.count - reachable.count // photos deleted from the catalog meanwhile are simply gone, not "no access"
        guard !reachable.isEmpty else { statusMessage = Self.summary(result); return }

        let started = scopes.values.filter { $0.startAccessingSecurityScopedResource() }
        defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }

        switch request.kind {
        case .write:
            let allPaths = Array(await catalog.cataloguedPathOwners().keys)
            let keywords = catalog.keywordNames(for: reachable)
            let outcome = await Task.detached { Self.writeAll(photos: reachable, allPaths: allPaths, keywords: keywords) }.value
            result.changed = outcome.written
            result.sharedWithRaw = outcome.shared
            result.unreadable = outcome.unreadable
            result.failed = outcome.failed
        case .read:
            let allPaths = Array(await catalog.cataloguedPathOwners().keys)
            let reads = await Task.detached { Self.readAll(photos: reachable, allPaths: allPaths) }.value
            result.noXMP = reads.noXMP
            result.unreadable = reads.unreadable
            do {
                let changed = try await catalog.applyXMPFields(reads.items, mode: .replace)
                result.changed = changed.count
                result.unchanged = reads.items.count - changed.count
            } catch {
                statusMessage = "Couldn't apply the XMP data to the Library: \(error.localizedDescription)"
                return
            }
        }
        statusMessage = Self.summary(result)
    }

    // MARK: - File work (off the main actor)

    struct WriteOutcome: Equatable { var written = 0, shared = 0, unreadable = 0, failed = 0 }
    struct ReadOutcome { var items: [(photoID: Int64, fields: XMPLibraryFields)] = []; var noXMP = 0; var unreadable = 0 }

    nonisolated static func writeAll(photos: [Photo], allPaths: [String], keywords: [Int64: [String]]) -> WriteOutcome {
        var out = WriteOutcome()
        let urlByPhoto = photos.map { (photo: $0, url: URL(fileURLWithPath: $0.path)) }
        let known = knownPhotos(selected: urlByPhoto.map(\.url), allPaths: allPaths)
        let split = XMPSidecarOwnership.partition(selected: urlByPhoto.map(\.url), allPhotos: known)
        out.shared = split.skipped.count
        let writers = Set(split.writers.map { $0.standardizedFileURL.path })
        for entry in urlByPhoto where writers.contains(entry.url.standardizedFileURL.path) {
            let photo = entry.photo
            let fields = libraryFields(for: photo, keywords: photo.id.flatMap { keywords[$0] } ?? [])
            do {
                if try XMPSidecarStore.write(fields, forPhotoAt: entry.url) != nil { out.written += 1 }
            } catch XMPSidecarStore.WriteError.unreadableExisting {
                out.unreadable += 1
            } catch {
                out.failed += 1
            }
        }
        return out
    }

    /// Every photo that can share a base name with the selection: the catalog's paths PLUS the image files actually on disk in the selected
    /// photos' folders (a RAW that was never imported still owns the shared `<base>.xmp`). One folder listing per folder.
    nonisolated static func knownPhotos(selected: [URL], allPaths: [String]) -> [URL] {
        var urls = allPaths.map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        for url in selected {
            let folder = url.deletingLastPathComponent()
            if seen.insert(folder.standardizedFileURL.path).inserted { urls += RenameEngine.photoFiles(inFolder: folder) }
        }
        return urls
    }

    nonisolated static func readAll(photos: [Photo], allPaths: [String]) -> ReadOutcome {
        var out = ReadOutcome()
        let index = XMPSidecarOwnership.Index(knownPhotos(selected: photos.map { URL(fileURLWithPath: $0.path) }, allPaths: allPaths))
        for photo in photos {
            guard let id = photo.id else { continue }
            let url = URL(fileURLWithPath: photo.path)
            // The shared `<base>.xmp` belongs to the RAW sibling (same rule as Write): a JPEG must not take the RAW's rating and label.
            let ownsSidecar = index.owner(of: url).standardizedFileURL.path == url.standardizedFileURL.path
            switch ownsSidecar ? XMPSidecarStore.read(forPhotoAt: url) : .missing {
            case .decoded(let fields): out.items.append((id, fields))
            case .undecodable: out.unreadable += 1
            case .missing:
                if let embedded = XMPSidecarStore.readEmbedded(forPhotoAt: url) {
                    out.items.append((id, embeddedFields(embedded)))
                } else { out.noXMP += 1 }
            }
        }
        return out
    }

    // MARK: - Pure helpers (testable)

    /// What Write sends for `photo`. An EMPTY Library value never erases what a file already holds (keywords, label, rating set in another
    /// app); a non-empty one replaces it. A Reject writes -1; an un-rejected photo clears an existing -1 marker (see `XMPSidecarStore.merge`).
    nonisolated static func libraryFields(for photo: Photo, keywords: [String]) -> XMPLibraryFields {
        let rejected = photo.flagStatus == .rejected
        return XMPLibraryFields(
            rating: (photo.rating > 0 || rejected) ? photo.rating : nil,
            isRejected: rejected,
            label: photo.colorLabel == .none ? nil : photo.colorLabel,
            keywords: keywords.isEmpty ? nil : keywords
        )
    }

    /// XMP embedded by a camera or an exporter was not written for the Library: a rating of 0 there means "unrated", not "clear the stars",
    /// so only a real rating or a Reject is taken from it.
    nonisolated static func embeddedFields(_ fields: XMPLibraryFields) -> XMPLibraryFields {
        var out = fields
        if out.isRejected != true && (out.rating ?? 0) == 0 { out.rating = nil; out.isRejected = nil }
        return out
    }

    nonisolated static func folderPath(of photo: Photo) -> String {
        URL(fileURLWithPath: photo.path).deletingLastPathComponent().standardizedFileURL.path
    }

    /// Distinct containing folders, in the order they first appear.
    nonisolated static func distinctFolders(of photos: [Photo]) -> [URL] {
        var seen = Set<String>()
        var folders: [URL] = []
        for photo in photos {
            let folder = URL(fileURLWithPath: photo.path).deletingLastPathComponent()
            if seen.insert(folder.standardizedFileURL.path).inserted { folders.append(folder) }
        }
        return folders
    }

    nonisolated static func confirmationTitle(_ request: Request) -> String {
        let n = request.photos.count
        let noun = n == 1 ? "photo" : "photos"
        switch request.kind {
        case .write: return "Write XMP sidecars for \(n) \(noun)?"
        case .read: return "Read XMP metadata for \(n) \(noun)?"
        }
    }

    nonisolated static func confirmationMessage(_ request: Request) -> String {
        switch request.kind {
        case .write:
            return "Writes each photo's rating, reject flag, colour label and keywords to a standard .xmp file next to it, "
                + "for other photo apps (darktable, digiKam, Bridge and Lightroom's RAW handling). An existing .xmp is updated in place and "
                + "its other settings are kept, and a rating, label or keywords the Library doesn't have never erase ones already in the file; one that can't be read is left alone. A JPEG next to a RAW with the same name is skipped "
                + "(the RAW owns that file). Pick flags and edits are not stored in XMP. Your photos are not changed."
        case .read:
            return "Reads rating, reject flag, colour label and keywords from the .xmp next to each photo (or the XMP inside the photo). "
                + "Ratings, labels and rejects from the file replace the Library's (a JPEG next to a RAW with the same name uses only the XMP inside the photo, since the RAW owns that file); keywords are added, never removed. Your photos and "
                + "their edits are not changed."
        }
    }

    nonisolated static func summary(_ r: Result) -> String {
        func photos(_ n: Int) -> String { "\(n) photo" + (n == 1 ? "" : "s") }
        var parts: [String] = []
        switch r.kind {
        case .write:
            parts.append(r.changed == 0 ? "No XMP files were written" : "Wrote XMP for \(photos(r.changed))")
            if r.sharedWithRaw > 0 { parts.append("\(photos(r.sharedWithRaw)) skipped because a RAW file with the same name owns the .xmp") }
        case .read:
            parts.append(r.changed == 0 ? "The Library already matched the XMP data" : "Updated \(photos(r.changed)) from XMP")
            if r.unchanged > 0 && r.changed > 0 { parts.append("\(photos(r.unchanged)) already matched") }
            if r.noXMP > 0 { parts.append("\(photos(r.noXMP)) had no XMP") }
        }
        if r.unreadable > 0 { parts.append("\(photos(r.unreadable)) have an .xmp that couldn't be read (left untouched)") }
        if r.failed > 0 { parts.append("\(photos(r.failed)) failed") }
        if r.noAccess > 0 { parts.append("\(photos(r.noAccess)) skipped (folder access not granted)") }
        return parts.joined(separator: "; ") + "."
    }
}
