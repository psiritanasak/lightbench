import Foundation

/// One thing a cull key did to a photo, with what it replaced — enough to put the photo back and return to it (⌘Z while culling).
/// Only the fields the action CHANGED are recorded, so undoing a flag never overwrites a rating set a moment later.
struct CullAction: Equatable {
    let photoID: Int64
    var previousRating: Int?
    var previousFlag: FlagStatus?
    var previousLabel: ColorLabel?
}

/// The values a cull key wants written to the catalog (`nil` = leave unchanged).
struct CullChange: Equatable {
    /// The photo the values belong to: the session has already moved on by the time `apply` returns when it auto-advanced.
    var photoID: Int64?
    var rating: Int?
    var flag: FlagStatus?
    var label: ColorLabel?
    /// True when the session moved on to the next photo (auto-advance).
    var advanced = false
}

/// The pure state of a culling pass: an ordered SNAPSHOT of photo ids taken when the pass starts (so a photo that leaves an "Unflagged"
/// filter the moment it is flagged does not break next / previous), a position, the auto-advance rule and an undo stack. No UI, no
/// catalog calls — the caller applies each `CullChange` through the usual catalog setters.
///
/// Auto-advance: after a FLAG command (Pick / Reject / Unflag / toggle) the session moves to the next photo when `autoAdvance` is on —
/// even if the flag did not change (the user has decided this photo). Rating and label commands never advance.
struct CullSession: Equatable {
    static let undoLimit = 50

    private(set) var ids: [Int64]
    private(set) var index: Int
    var autoAdvance = true
    private(set) var undoStack: [CullAction] = []

    /// A session over `photos` (in the order given — pass `displayedPhotos`). `onlyUnflagged` keeps just the photos with no flag yet.
    /// Starts at `startingAt` if that photo is in the list, else at the first. `nil` when the list is empty.
    init?(photos: [Photo], onlyUnflagged: Bool, startingAt id: Int64? = nil) {
        let list = photos.compactMap { photo -> Int64? in
            guard let photoID = photo.id else { return nil }
            return (!onlyUnflagged || photo.flagStatus == .none) ? photoID : nil
        }
        guard !list.isEmpty else { return nil }
        ids = list
        index = id.flatMap { list.firstIndex(of: $0) } ?? 0
    }

    // MARK: Position

    var count: Int { ids.count }
    var currentID: Int64? { ids.indices.contains(index) ? ids[index] : nil }
    var isAtStart: Bool { index == 0 }
    var isAtEnd: Bool { index >= ids.count - 1 }
    /// "37 of 412".
    var positionText: String { "\(index + 1) of \(ids.count)" }

    /// The ids worth keeping decoded around the current photo, nearest first, next before previous at each distance.
    func neighborIDs(radius: Int) -> [Int64] {
        var result: [Int64] = []
        guard radius > 0 else { return result }
        for distance in 1...radius {
            for target in [index + distance, index - distance] where ids.indices.contains(target) { result.append(ids[target]) }
        }
        return result
    }

    @discardableResult
    mutating func next() -> Bool {
        guard !isAtEnd else { return false }
        index += 1
        return true
    }

    @discardableResult
    mutating func previous() -> Bool {
        guard !isAtStart else { return false }
        index -= 1
        return true
    }

    @discardableResult
    mutating func jump(toID id: Int64) -> Bool {
        guard let target = ids.firstIndex(of: id) else { return false }
        index = target
        return true
    }

    // MARK: Progress

    struct Counts: Equatable {
        var picked = 0
        var rejected = 0
        var unflagged = 0
    }

    /// Flag counts over the snapshot, read from the live rows (ids with no row, e.g. removed meanwhile, are skipped).
    func counts(rows: [Int64: Photo]) -> Counts {
        var result = Counts()
        for id in ids {
            switch rows[id]?.flagStatus {
            case .picked?: result.picked += 1
            case .rejected?: result.rejected += 1
            case FlagStatus.none?: result.unflagged += 1
            case nil: break
            }
        }
        return result
    }

    // MARK: Commands

    /// Applies a photo key to the CURRENT photo (`photo` must be that row): returns what to write, records an undo entry when something
    /// actually changes, and auto-advances after a flag command. `nil` when `photo` is not the current photo.
    mutating func apply(_ command: PhotoKeyCommand, to photo: Photo) -> CullChange? {
        guard let current = currentID, photo.id == current else { return nil }
        var change = CullChange()
        switch command {
        case .rating(let value):
            if value != photo.rating { change.rating = value }
        case .label:
            if let label = command.label(from: photo.colorLabel), label != photo.colorLabel { change.label = label }
        case .flag:
            if let flag = command.flagStatus(from: photo.flagStatus), flag != photo.flagStatus { change.flag = flag }
        }
        change.photoID = current
        if change.rating != nil || change.flag != nil || change.label != nil {
            undoStack.append(CullAction(photoID: current,
                                        previousRating: change.rating == nil ? nil : photo.rating,
                                        previousFlag: change.flag == nil ? nil : photo.flagStatus,
                                        previousLabel: change.label == nil ? nil : photo.colorLabel))
            if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        }
        if case .flag = command, autoAdvance { change.advanced = next() }
        return change
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// Pops the last action and returns to its photo when that photo is still in the list (after a rebuild it may not be: the position
    /// then stays where it is); the caller writes the recorded previous values back. `nil` when there is nothing to undo.
    mutating func undo() -> CullAction? {
        guard let action = undoStack.popLast() else { return nil }
        if let target = ids.firstIndex(of: action.photoID) { index = target }
        return action
    }

    /// Rebuilds the snapshot (the "Unflagged only" toggle) keeping the auto-advance setting and the undo stack; stays on the current
    /// photo if it is still in the new list, else starts at the first. Returns false (the session is unchanged) when the new list would be empty.
    mutating func rebuild(photos: [Photo], onlyUnflagged: Bool) -> Bool {
        guard var fresh = CullSession(photos: photos, onlyUnflagged: onlyUnflagged, startingAt: currentID) else { return false }
        fresh.autoAdvance = autoAdvance
        fresh.undoStack = undoStack
        self = fresh
        return true
    }
}
