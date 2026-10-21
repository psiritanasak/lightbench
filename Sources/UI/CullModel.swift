import CoreGraphics
import Foundation

/// A key the cull view understands, independent of SwiftUI's `KeyPress` so the mapping is unit-tested.
enum CullKey: Equatable {
    case leftArrow, rightArrow, upArrow, downArrow, space, escape, returnKey
    case character(Character)
}

/// What a cull key does. Photo keys use the SAME table as the Library grid and the Editor (`PhotoKeyCommand`), with `0` allowed (it
/// clears the rating — there is no "reset zoom" here).
enum CullKeyAction: Equatable {
    case previous, next, exit, openInEditor
    /// C / N toggle Compare / Survey; ↑ swaps select and candidate (Compare), ↓ makes the candidate the select; `/` takes the focused photo off the survey page.
    case toggleCompare, toggleSurvey, swapCompare, makeSelect, removeFromSurvey
    case command(PhotoKeyCommand)

    static func action(for key: CullKey) -> CullKeyAction? {
        switch key {
        case .leftArrow: return .previous
        case .rightArrow, .space: return .next
        case .upArrow: return .swapCompare
        case .downArrow: return .makeSelect
        case .escape: return .exit
        case .returnKey: return .openInEditor
        case .character(let character):
            switch character {
            case "c", "C": return .toggleCompare
            case "n", "N": return .toggleSurvey
            case "/": return .removeFromSurvey
            default: return PhotoKeyCommand.command(for: character, allowsZero: true).map { .command($0) }
            }
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
    /// Compare / Survey: one picture per visible photo (the single `image` above belongs to the loupe). Each slot is gated exactly like the loupe's
    /// picture: a photo key acts on `currentID` only once ITS slot holds its picture (or it failed to decode).
    @Published private(set) var slots: [Int64: CullSlot] = [:]
    /// A transient confirmation of the last key ("Picked", "★★★", "End of list").
    @Published private(set) var note: String?
    @Published private(set) var endReached = false
    @Published private(set) var onlyUnflagged = true
    /// The Preferences window's culling defaults, read when a pass begins (a test injects its own suite).
    var preferences = AppPreferences.shared

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
    var showsCurrentPhoto: Bool {
        guard let s = session, let id = s.currentID else { return false }
        return s.mode == .loupe ? imagePhotoID == id : slots[id]?.image != nil
    }

    /// Whether photo keys may act: the picture on screen is the current photo's, or the photo could not be decoded at all (a broken file
    /// is often exactly the one to reject — there is no other picture it could be confused with).
    var canActOnCurrent: Bool { showsCurrentPhoto || decodeFailed }

    /// True when the CURRENT photo is the one that failed to decode.
    var decodeFailed: Bool {
        guard let s = session, let id = s.currentID else { return false }
        return s.mode == .loupe ? (failedPhotoID != nil && failedPhotoID == id) : (slots[id]?.failed ?? false)
    }

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
        // "Unflagged only" starts on when there is anything unflagged AND the preference allows it.
        let unflagged = preferences.cullStartUnflaggedOnly && photos.contains { $0.flagStatus == .none }
        var startID = path.flatMap { path in photos.first { $0.editKey == path }?.id }
        // Focused on a flagged photo while only unflagged ones are listed: start at the next unflagged photo after it.
        if unflagged, let id = startID, let at = photos.firstIndex(where: { $0.id == id }), photos[at].flagStatus != .none {
            startID = photos[at...].first { $0.flagStatus == .none }?.id ?? photos.first { $0.flagStatus == .none }?.id
        }
        guard var fresh = CullSession(photos: photos, onlyUnflagged: unflagged, startingAt: startID) else { return false }
        fresh.autoAdvance = preferences.cullAutoAdvance
        session = fresh
        slots = [:]
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
        slots = [:]
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
            if !move({ $0.next() }) { flash(endText) }
        case .exit:
            // Esc leaves Compare / Survey first (back to the loupe on the same photo), and only then the pass.
            if let s = session, s.mode != .loupe { setMode(.loupe); return .done }
            return .exit
        case .toggleCompare:
            setMode(session?.mode == .compare ? .loupe : .compare)
        case .toggleSurvey:
            setMode(session?.mode == .survey ? .loupe : .survey)
        case .swapCompare:
            modeEdit({ $0.swapCompare() }, refused: "Swap works in Compare")
        case .makeSelect:
            modeEdit({ $0.makeSelect() }, refused: "Make Select works in Compare")
        case .removeFromSurvey:
            modeEdit({ $0.removeFromSurvey() }, refused: "Remove works in Survey, and keeps one photo")
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

    /// A click on a cell: the keys now act on that photo. Compare: only the candidate can be focused (the select stays put; click it to swap).
    func focus(on id: Int64) {
        guard var s = session, s.currentID != id, s.visibleIDs.contains(id) else { return }
        switch s.mode {
        case .loupe: return
        case .survey: s.jump(toID: id)
        case .compare: if id == s.selectID { s.swapCompare() }
        }
        session = s
        endReached = false
        loadCurrent()
    }

    /// Switches the view mode (the toolbar picker and the C / N keys). A mode that cannot start (one photo) says so and changes nothing.
    func setMode(_ mode: CullViewMode) {
        guard var s = session, s.mode != mode else { return }
        let ok: Bool
        switch mode {
        case .loupe: s.enterLoupe(); ok = true
        case .compare: ok = s.enterCompare()
        case .survey: ok = s.enterSurvey()
        }
        guard ok else { flash("Needs at least two photos"); return }
        session = s
        endReached = false
        loadCurrent()
    }

    private func modeEdit(_ edit: (inout CullSession) -> Bool, refused: String) {
        guard var s = session else { return }
        if edit(&s) {
            session = s
            endReached = false
            loadCurrent()
        } else {
            flash(refused)
        }
    }

    /// "End of list", or "End of page" on the last cell of a survey page (the pass itself may continue).
    private var endText: String { session?.mode == .survey ? "End of page" : "End of list" }

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
        flash(reachedEnd ? endText : Self.noteText(for: command, photo: photo, change: change))
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

    /// The photo area's size: previews are decoded at the screen's resolution for the loupe and at one cell's size for Compare / Survey.
    func setViewArea(width: Double, height: Double, scale: Double) {
        let area = CGSize(width: width, height: height)
        let changed = area != areaSize || scale != areaScale
        areaSize = area
        areaScale = scale
        setViewSize(longEdge: max(width, height), scale: scale)
        if changed, let s = session, s.mode != .loupe, cellPixelSize != lastCellPixelSize { loadCurrent() }
    }

    private var areaSize = CGSize(width: 1200, height: 800)
    private var areaScale = 2.0
    private var lastCellPixelSize = 0

    /// Long-edge pixel size of one Compare / Survey cell, from the area and the number of visible photos.
    var cellPixelSize: Int {
        let count = session?.visibleIDs.count ?? 1
        // Compare is always two cells side by side (an HStack); only Survey uses the aspect-aware grid.
        let edge = session?.mode == .compare ? Double(max(areaSize.width / 2, areaSize.height)) : CullLayout.cellLongEdge(area: areaSize, count: count)
        return CullPreviewCache.targetPixelSize(viewLongEdge: edge, scale: areaScale)
    }

    /// The view's size, so previews are decoded at the screen's resolution (rounded to steps, see `CullPreviewCache.targetPixelSize`).
    func setViewSize(longEdge: Double, scale: Double) {
        let size = CullPreviewCache.targetPixelSize(viewLongEdge: longEdge, scale: scale)
        guard size != pixelSize else { return }
        pixelSize = size
        if isActive { loadCurrent() }
    }

    // MARK: Loading

    /// Compare / Survey: drops the slots of photos that left the screen, then loads the visible ones (see `loadVisibleSlots`).
    private func loadVisible(_ s: CullSession, token: Int) {
        let visible = Set(s.visibleIDs)
        slots = slots.filter { visible.contains($0.key) }
        lastCellPixelSize = cellPixelSize
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.clearTask?.value
            guard self.loadToken == token else { return }
            await self.cache.cancelPrefetch() // the loupe's neighbour prefetch is not wanted while the cells load
            await self.loadVisibleSlots(s, token: token)
        }
    }

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
        if let s = session, s.mode != .loupe { loadVisible(s, token: token); return }
        slots = [:] // back in the loupe: the cells' pictures are no longer needed (memory), and the loupe gate does not read them
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
            guard self.loadToken == token else { return }
            await self.cache.setCountLimit(0) // back to the loupe's own resident count
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

/// One Compare / Survey cell's picture. `image` is the grid thumbnail while `isPlaceholder`, then the real preview.
struct CullSlot {
    var image: CGImage?
    var isPlaceholder = false
    var failed = false
}

/// Pure layout maths for Compare / Survey, shared by the view and the preview sizing.
enum CullLayout {
    /// Columns x rows for `count` cells in an `area` (aspect-aware, never fewer cells than photos, at most 4 columns).
    static func grid(count: Int, area: CGSize) -> (columns: Int, rows: Int) {
        guard count > 0 else { return (1, 1) }
        let aspect = area.height > 0 ? Double(area.width / area.height) : 1.5
        var best = (columns: count, rows: 1)
        var bestWaste = Double.infinity
        for columns in 1...min(4, count) {
            let rows = (count + columns - 1) / columns
            // Closeness of one cell's shape to a 3:2 photo, plus a penalty for empty cells.
            let cellAspect = (aspect / Double(columns)) * Double(rows)
            let waste = abs(log(cellAspect / 1.5)) + Double(columns * rows - count) * 0.15
            if waste < bestWaste { bestWaste = waste; best = (columns, rows) }
        }
        return best
    }

    /// The longer edge, in points, of one cell.
    static func cellLongEdge(area: CGSize, count: Int) -> Double {
        let g = grid(count: count, area: area)
        return Double(max(area.width / CGFloat(g.columns), area.height / CGFloat(g.rows)))
    }
}

extension CullModel {
    /// Loads one picture per visible photo (the current one first): the cached preview at once, or the grid thumbnail while the real one decodes.
    /// A newer load (`loadToken`) supersedes this one, and each slot write re-checks it, so a stale result never lands in the wrong layout.
    fileprivate func loadVisibleSlots(_ s: CullSession, token: Int) async {
        let ids = s.visibleIDs
        let order = ([s.currentID].compactMap { $0 } + ids).reduce(into: [Int64]()) { if !$0.contains($1) { $0.append($1) } }
        let size = cellPixelSize
        await cache.setCountLimit(ids.count + 4)
        for id in order {
            guard loadToken == token, let photo = environment.rows()[id] else { continue }
            if let hit = await cache.cached(for: photo, pixelSize: size) {
                guard loadToken == token else { return }
                slots[id] = CullSlot(image: hit)
                continue
            }
            let placeholder = await environment.thumbnail(photo)
            guard loadToken == token else { return }
            if let placeholder { slots[id] = CullSlot(image: placeholder, isPlaceholder: true) }
            let full = await cache.preview(for: photo, pixelSize: size)
            guard loadToken == token else { return }
            if let full {
                slots[id] = CullSlot(image: full)
            } else if placeholder == nil {
                slots[id] = CullSlot(image: nil, failed: true)
            }
        }
    }
}
