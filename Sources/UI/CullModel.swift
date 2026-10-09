import CoreGraphics
import Foundation

/// A key the cull view understands, independent of SwiftUI's `KeyPress` so the mapping is unit-tested.
enum CullKey: Equatable {
    case leftArrow, rightArrow, space, escape, returnKey
    case character(Character)
}

/// What a cull key does. Photo keys use the SAME table as the Library grid and the Editor (`PhotoKeyCommand`), with `0` allowed (it
/// clears the rating — there is no "reset zoom" here).
enum CullKeyAction: Equatable {
    case previous, next, exit, openInEditor
    case command(PhotoKeyCommand)

    static func action(for key: CullKey) -> CullKeyAction? {
        switch key {
        case .leftArrow: return .previous
        case .rightArrow, .space: return .next
        case .escape: return .exit
        case .returnKey: return .openInEditor
        case .character(let character): return PhotoKeyCommand.command(for: character, allowsZero: true).map { .command($0) }
        }
    }
}

/// How the cull model reaches the catalog. Closures (like `EditorPhotoMeta`) so tests can drive the model without a database.
struct CullEnvironment {
    /// The photos in the order the Library shows them (`displayedPhotos`).
    var photos: () -> [Photo] = { [] }
    /// The live catalog rows by id (flags change in place as keys are pressed).
    var rows: () -> [Int64: Photo] = { [:] }
    var setRating: (Int, Photo) -> Void = { _, _ in }
    var setFlag: (FlagStatus, Photo) -> Void = { _, _ in }
    var setLabel: (ColorLabel, Photo) -> Void = { _, _ in }
    /// The grid thumbnail (already cached in practice): shown at once while the full preview decodes.
    var thumbnail: (Photo) async -> CGImage? = { _ in nil }
}

/// What the view should do after a key: nothing more, leave, or leave and open the photo in the Editor.
enum CullOutcome: Equatable {
    case done
    case exit
    case openInEditor(Photo)
}

/// The culling pass: `CullSession` (pure state) + the preview cache + the catalog writes. Owned at app level (like `document`) so the
/// Photo menu's ⌘Z can route to `undo()` while culling instead of reaching the Editor's edit history. A cull never loads a photo into
/// the Editor (`ImageDocumentModel.load` flushes sidecars and resets history), it only reads previews and writes rating / flag / label.
@MainActor
final class CullModel: ObservableObject {
    @Published private(set) var session: CullSession?
    /// What is on screen: the full preview, or the grid thumbnail while the preview decodes (`isPlaceholder`).
    @Published private(set) var image: CGImage?
    /// The photo `image` belongs to. While it differs from the session's current photo (the next one is still loading) the view shows
    /// the old picture dimmed with a spinner and photo keys are REFUSED, so a key can never change a photo other than the one on screen.
    @Published private(set) var imagePhotoID: Int64?
    @Published private(set) var isPlaceholder = false
    /// The photo whose preview could not be decoded at all (a broken or missing file). Tied to an id, and cleared synchronously when the
    /// current photo changes, so it can never make the NEXT photo look actable before it is on screen.
    @Published private(set) var failedPhotoID: Int64?
    /// A transient confirmation of the last key ("Picked", "★★★", "End of list").
    @Published private(set) var note: String?
    @Published private(set) var endReached = false
    @Published private(set) var onlyUnflagged = true

    private(set) var environment = CullEnvironment()
    private let cache = CullPreviewCache()
    private var pixelSize = 1536
    private var loadTask: Task<Void, Never>?
    private var loadToken = 0
    /// The cache clear started by the last `end()`; a new pass waits for it so it cannot wipe the new pass's previews.
    private var clearTask: Task<Void, Never>?
    private var noteToken = 0

    var isActive: Bool { session != nil }

    /// True once the picture on screen is the current photo's.
    var showsCurrentPhoto: Bool { imagePhotoID != nil && imagePhotoID == session?.currentID }

    /// Whether photo keys may act: the picture on screen is the current photo's, or the photo could not be decoded at all (a broken file
    /// is often exactly the one to reject — there is no other picture it could be confused with).
    var canActOnCurrent: Bool { showsCurrentPhoto || decodeFailed }

    /// True when the CURRENT photo is the one that failed to decode.
    var decodeFailed: Bool { failedPhotoID != nil && failedPhotoID == session?.currentID }

    func configure(_ environment: CullEnvironment) { self.environment = environment }

    /// The live row of the photo on screen.
    var current: Photo? { session?.currentID.flatMap { environment.rows()[$0] } }

    /// Flag counts over the photos in this pass's list (live rows).
    var counts: CullSession.Counts { session?.counts(rows: environment.rows()) ?? CullSession.Counts() }

    // MARK: Start / stop

    /// Starts a pass over the photos as the Library shows them. "Unflagged only" starts ON when anything is unflagged. `false` when
    /// there is nothing to cull.
    @discardableResult
    func begin(startingAtPath path: String?) -> Bool {
        let photos = environment.photos()
        guard !photos.isEmpty else { return false }
        let unflagged = photos.contains { $0.flagStatus == .none }
        var startID = path.flatMap { path in photos.first { $0.path == path }?.id }
        // Focused on a flagged photo while only unflagged ones are listed: start at the next unflagged photo after it.
        if unflagged, let id = startID, let at = photos.firstIndex(where: { $0.id == id }), photos[at].flagStatus != .none {
            startID = photos[at...].first { $0.flagStatus == .none }?.id ?? photos.first { $0.flagStatus == .none }?.id
        }
        guard let fresh = CullSession(photos: photos, onlyUnflagged: unflagged, startingAt: startID) else { return false }
        session = fresh
        onlyUnflagged = unflagged
        endReached = false
        note = nil
        loadCurrent()
        return true
    }

    /// Ends the pass and returns the photo it was on (the grid focuses it).
    @discardableResult
    func end() -> Photo? {
        let last = current
        loadTask?.cancel()
        loadToken += 1
        session = nil
        image = nil
        imagePhotoID = nil
        isPlaceholder = false
        failedPhotoID = nil
        note = nil
        endReached = false
        clearTask = Task { [cache] in await cache.removeAll() }
        return last
    }

    // MARK: Keys

    @discardableResult
    func handle(_ action: CullKeyAction) -> CullOutcome {
        guard session != nil else { return .done }
        switch action {
        case .previous:
            move { $0.previous() }
        case .next:
            if !move({ $0.next() }) { flash("End of list") }
        case .exit:
            return .exit
        case .openInEditor:
            if let photo = current { return .openInEditor(photo) }
        case .command(let command):
            apply(command)
        }
        return .done
    }

    @discardableResult
    private func move(_ step: (inout CullSession) -> Bool) -> Bool {
        guard var s = session else { return false }
        let moved = step(&s)
        if moved {
            session = s
            endReached = false
            loadCurrent()
        }
        return moved
    }

    private func apply(_ command: PhotoKeyCommand) {
        // Only while the picture on screen IS the current photo (see `imagePhotoID`).
        guard canActOnCurrent, var s = session, let photo = current, let change = s.apply(command, to: photo) else { return }
        session = s
        if let rating = change.rating { environment.setRating(rating, photo) }
        if let flag = change.flag { environment.setFlag(flag, photo) }
        if let label = change.label { environment.setLabel(label, photo) }
        let reachedEnd: Bool
        if case .flag = command { reachedEnd = s.autoAdvance && !change.advanced && s.isAtEnd } else { reachedEnd = false }
        endReached = reachedEnd
        flash(reachedEnd ? "End of list" : Self.noteText(for: command, photo: photo, change: change))
        if change.advanced { loadCurrent() }
    }

    private static func noteText(for command: PhotoKeyCommand, photo: Photo, change: CullChange) -> String {
        switch command {
        case .rating(let value): return value == 0 ? "Rating cleared" : String(repeating: "★", count: value)
        case .flag: return (change.flag ?? photo.flagStatus).accessibilityValue
        case .label: return (change.label ?? photo.colorLabel).menuTitle
        }
    }

    /// ⌘Z while culling: puts the last action's values back and returns to its photo.
    func undo() {
        guard var s = session, let action = s.undo() else { return }
        session = s
        endReached = false
        if let row = environment.rows()[action.photoID] {
            if let rating = action.previousRating { environment.setRating(rating, row) }
            if let flag = action.previousFlag { environment.setFlag(flag, row) }
            if let label = action.previousLabel { environment.setLabel(label, row) }
            flash("Undone")
        } else {
            flash("Can't undo — that photo was removed")
        }
        loadCurrent()
    }

    var canUndo: Bool { session?.canUndo ?? false }

    var autoAdvance: Bool {
        get { session?.autoAdvance ?? true }
        set {
            guard var s = session else { return }
            s.autoAdvance = newValue
            session = s
        }
    }

    /// The "Unflagged only" toggle: rebuilds the snapshot from the Library's current photos, staying on this photo when it is still listed.
    func setOnlyUnflagged(_ value: Bool) {
        guard var s = session else { return }
        guard s.rebuild(photos: environment.photos(), onlyUnflagged: value) else {
            flash(value ? "Nothing unflagged" : "Nothing to show")
            return
        }
        session = s
        onlyUnflagged = value
        endReached = false
        loadCurrent()
    }

    // MARK: Size

    /// The view's size, so previews are decoded at the screen's resolution (rounded to steps, see `CullPreviewCache.targetPixelSize`).
    func setViewSize(longEdge: Double, scale: Double) {
        let size = CullPreviewCache.targetPixelSize(viewLongEdge: longEdge, scale: scale)
        guard size != pixelSize else { return }
        pixelSize = size
        if isActive { loadCurrent() }
    }

    // MARK: Loading

    private func flash(_ text: String) {
        note = text
        noteToken += 1
        let mine = noteToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard let self, self.noteToken == mine else { return }
            self.note = nil
        }
    }

    /// Shows the current photo: the cached preview at once, or the grid thumbnail while the real one decodes; then warms the
    /// neighbours. A newer call (next key) supersedes this one — its result is dropped, never shown over the new photo.
    private func loadCurrent() {
        loadTask?.cancel()
        loadToken += 1
        let token = loadToken
        failedPhotoID = nil // synchronously: a failure belongs to the photo it was recorded for, never to its successor
        guard let s = session, let photo = current else {
            // The current photo's row is gone (removed meanwhile): nothing to show, and nothing may act on the old picture.
            image = nil
            imagePhotoID = nil
            return
        }
        let size = pixelSize
        let neighbors = s.neighborIDs(radius: 2)
        let currentID = s.currentID
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.clearTask?.value
            if let hit = await self.cache.cached(for: photo, pixelSize: size) {
                guard self.loadToken == token else { return }
                self.image = hit
                self.imagePhotoID = currentID
                self.isPlaceholder = false
            } else {
                let placeholder = await self.environment.thumbnail(photo)
                guard self.loadToken == token else { return }
                if let placeholder {
                    self.image = placeholder
                    self.imagePhotoID = currentID
                    self.isPlaceholder = true
                }
                let full = await self.cache.preview(for: photo, pixelSize: size)
                guard self.loadToken == token else { return }
                if let full {
                    self.image = full
                    self.imagePhotoID = currentID
                    self.isPlaceholder = false
                } else if placeholder == nil {
                    // Nothing decodable: still navigable, and `canActOnCurrent` lets the user flag it (a broken file is a reject).
                    self.image = nil
                    self.imagePhotoID = nil
                    self.failedPhotoID = currentID
                }
            }
            guard self.loadToken == token, self.session?.currentID == currentID else { return }
            let rows = self.environment.rows()
            await self.cache.setWanted(neighbors.compactMap { rows[$0] }, pixelSize: size)
        }
    }

    /// The live row of the photo on screen / the flag counts, from rows the caller already built (one dictionary per view update).
    func current(in rows: [Int64: Photo]) -> Photo? { session?.currentID.flatMap { rows[$0] } }
    func counts(in rows: [Int64: Photo]) -> CullSession.Counts { session?.counts(rows: rows) ?? CullSession.Counts() }
}
