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

/// How the pass shows photos. `loupe` is the original single big photo. `compare` shows a fixed "select" next to the current photo (the
/// candidate): arrows move the candidate and skip the select. `survey` shows a page of photos at once; arrows move the focus among them.
/// Photo keys always act on `currentID` — the candidate in Compare, the focused cell in Survey.
enum CullViewMode: Equatable { case loupe, compare, survey }

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

    /// Compare / Survey state (`mode == .loupe` leaves every original behaviour untouched).
    private(set) var mode: CullViewMode = .loupe
    /// Compare: the photo that stays on the left while the candidate (`currentID`) changes.
    private(set) var selectID: Int64?
    /// Survey: the photos on the page, in list order (a subset of `ids`). The focused one is `currentID`.
    private(set) var surveyIDs: [Int64] = []
    /// A survey page holds at most this many photos (the grid stays readable and the preview cache bounded).
    static let surveyLimit = 12

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
    var isAtStart: Bool { !canStep(-1) }
    var isAtEnd: Bool { !canStep(1) }
    /// "37 of 412" in the loupe; "Candidate 37 of 412" in Compare; "Survey 3 of 12" (the focused cell) in Survey.
    var positionText: String {
        switch mode {
        case .loupe: return "\(index + 1) of \(ids.count)"
        case .compare: return "Candidate \(index + 1) of \(ids.count)"
        case .survey: return "Survey \((currentID.flatMap { surveyIDs.firstIndex(of: $0) } ?? 0) + 1) of \(surveyIDs.count)"
        }
    }

    /// The photos on screen: the one photo, the select and the candidate, or the survey page.
    var visibleIDs: [Int64] {
        switch mode {
        case .loupe: return currentID.map { [$0] } ?? []
        case .compare: return [selectID, currentID].compactMap { $0 }
        case .survey: return surveyIDs
        }
    }

    /// The list index `step` (+1 / -1) away from the current photo under the current mode's rule, or nil at the edge.
    private func steppedIndex(_ step: Int) -> Int? {
        switch mode {
        case .loupe:
            let target = index + step
            return ids.indices.contains(target) ? target : nil
        case .compare:
            var target = index + step
            while ids.indices.contains(target) {
                if ids[target] != selectID { return target }
                target += step
            }
            return nil
        case .survey:
            guard let current = currentID, let at = surveyIDs.firstIndex(of: current), surveyIDs.indices.contains(at + step) else { return nil }
            return ids.firstIndex(of: surveyIDs[at + step])
        }
    }

    private func canStep(_ step: Int) -> Bool { steppedIndex(step) != nil }

    /// The ids worth keeping decoded around the current photo, nearest first, next before previous at each distance.
    func neighborIDs(radius: Int) -> [Int64] {
        var result: [Int64] = []
        guard radius > 0, mode == .loupe else { return result } // Compare / Survey load exactly their visible photos
        for distance in 1...radius {
            for target in [index + distance, index - distance] where ids.indices.contains(target) { result.append(ids[target]) }
        }
        return result
    }

    @discardableResult
    mutating func next() -> Bool {
        guard let target = steppedIndex(1) else { return false }
        index = target
        return true
    }

    @discardableResult
    mutating func previous() -> Bool {
        guard let target = steppedIndex(-1) else { return false }
        index = target
        return true
    }

    @discardableResult
    mutating func jump(toID id: Int64) -> Bool {
        guard let target = ids.firstIndex(of: id) else { return false }
        index = target
        return true
    }

    // MARK: View modes

    /// Back to the single big photo (the current photo stays current).
    mutating func enterLoupe() {
        mode = .loupe
        selectID = nil
        surveyIDs = []
    }

    /// Compare: the current photo becomes the select and the candidate moves to the next photo (the previous one at the end of the list).
    /// False (unchanged) when there is only one photo.
    @discardableResult
    mutating func enterCompare() -> Bool {
        guard ids.count >= 2, let current = currentID else { return false }
        enterLoupe()
        let candidate = index + 1 < ids.count ? index + 1 : index - 1
        mode = .compare
        selectID = current
        index = candidate
        return true
    }

    /// Survey: a page of up to `surveyLimit` photos containing the current one (starting at it, shifted back so the page is full near the end
    /// of the list). False (unchanged) when there is only one photo.
    @discardableResult
    mutating func enterSurvey() -> Bool {
        guard ids.count >= 2 else { return false }
        enterLoupe()
        let size = min(Self.surveyLimit, ids.count)
        let start = min(index, ids.count - size)
        surveyIDs = Array(ids[start..<(start + size)])
        mode = .survey
        return true
    }

    /// Compare: the candidate and the select trade places (the old select becomes the candidate).
    @discardableResult
    mutating func swapCompare() -> Bool {
        guard mode == .compare, let select = selectID, let current = currentID, let target = ids.firstIndex(of: select) else { return false }
        selectID = current
        index = target
        return true
    }

    /// Compare: the candidate becomes the select, and a new candidate (the next photo, else the previous) takes its place.
    /// False (unchanged) when there is no other photo to compare against.
    @discardableResult
    mutating func makeSelect() -> Bool {
        guard mode == .compare, let current = currentID else { return false }
        let previousSelect = selectID
        selectID = current
        if let target = steppedIndex(1) ?? steppedIndex(-1) {
            index = target
            return true
        }
        selectID = previousSelect
        return false
    }

    /// Survey: takes the focused photo off the page (it stays in the pass); focus moves to the next one on the page, else the previous.
    /// Refuses to empty the page. Not undoable: N twice rebuilds the page.
    @discardableResult
    mutating func removeFromSurvey() -> Bool {
        guard mode == .survey, surveyIDs.count > 1, let current = currentID, let at = surveyIDs.firstIndex(of: current) else { return false }
        let nextFocus = surveyIDs.indices.contains(at + 1) ? surveyIDs[at + 1] : surveyIDs[at - 1]
        surveyIDs.remove(at: at)
        if let target = ids.firstIndex(of: nextFocus) { index = target }
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
        // Undo returns to the photo it changed; if Compare / Survey is not showing it, fall back to the loupe so it is on screen.
        if mode != .loupe, !visibleIDs.contains(action.photoID) { enterLoupe() }
        if mode == .compare, action.photoID == selectID {
            // The undone photo is the select: trade places so the candidate never becomes the SAME photo as the select (both cells would show it
            // and keys would act on the select).
            swapCompare()
        } else if let target = ids.firstIndex(of: action.photoID) {
            index = target
        }
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
