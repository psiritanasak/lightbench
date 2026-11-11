import Foundation

/// The clock of the one visible toast, as pure state: callers pass the time in, so tests need no real waiting. A toast has a duration
/// that runs only while nothing pauses it (pointer over it, a sheet up, the app inactive). Every scheduled wake carries the toast's id and
/// a generation number, and any change that moves the deadline (a pause, a resume, a replacement) bumps the generation, so a stale timer
/// can never remove a newer toast or fire early.
struct ToastTimeline: Equatable {
    struct Entry: Equatable, Identifiable {
        let id: Int
        let feedback: Feedback
        let duration: TimeInterval
    }

    /// A request to call `wake(_:now:)` after `after` seconds.
    struct Wake: Equatable {
        let id: Int
        let generation: Int
        let after: TimeInterval
    }

    enum PauseReason: Hashable {
        case hover, sheet, appInactive
    }

    enum WakeResult: Equatable {
        case ignored
        case expired
        case again(Wake)
    }

    /// Display durations: conventions chosen by eye, not measurements.
    static let standardDuration: TimeInterval = 4
    static let voiceOverDuration: TimeInterval = 10
    /// The least time left after a pause ends, so a toast never vanishes the instant the pointer leaves (a convention, by eye).
    static let minimumAfterResume: TimeInterval = 1.5

    private static let expiryTolerance: TimeInterval = 0.01

    private(set) var current: Entry?
    private(set) var pauseReasons: Set<PauseReason> = []

    private var remainingSeconds: TimeInterval = 0
    private var runningSince: Date?
    private var generation = 0
    private var nextID = 1

    // MARK: Showing

    /// Shows a toast, replacing any current one. Refuses (nil, nothing changed) a feedback that is an alert. Returns the wake to arm, or nil
    /// while paused.
    mutating func show(_ feedback: Feedback, now: Date, voiceOver: Bool) -> Wake? {
        guard feedback.presentation == .toast else { return nil }
        let duration = voiceOver ? Self.voiceOverDuration : Self.standardDuration
        let entry = Entry(id: nextID, feedback: feedback, duration: duration)
        nextID += 1
        current = entry
        pauseReasons.remove(.hover)
        generation += 1
        remainingSeconds = duration
        if pauseReasons.isEmpty {
            runningSince = now
            return Wake(id: entry.id, generation: generation, after: duration)
        }
        runningSince = nil
        return nil
    }

    // MARK: Pausing

    /// Sets or clears one pause reason. Returns the wake to arm when the last reason clears.
    mutating func setPaused(_ reason: PauseReason, _ paused: Bool, now: Date) -> Wake? {
        guard let entry = current else {
            if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
            return nil
        }
        let wasPaused = !pauseReasons.isEmpty
        if paused { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        let isPaused = !pauseReasons.isEmpty
        if !wasPaused && isPaused {
            if let since = runningSince { remainingSeconds = max(0, remainingSeconds - now.timeIntervalSince(since)) }
            runningSince = nil
            generation += 1
            return nil
        }
        if wasPaused && !isPaused {
            remainingSeconds = max(remainingSeconds, Self.minimumAfterResume)
            runningSince = now
            generation += 1
            return Wake(id: entry.id, generation: generation, after: remainingSeconds)
        }
        return nil
    }

    // MARK: Ending

    /// Removes the toast with this id (a stale id does nothing). A dismiss also clears the hover pause: the pointer was over the toast that
    /// is now gone.
    mutating func dismiss(id: Int) {
        guard current?.id == id else { return }
        current = nil
        runningSince = nil
        remainingSeconds = 0
        generation += 1
        pauseReasons.remove(.hover)
    }

    mutating func wake(_ wake: Wake, now: Date) -> WakeResult {
        guard let entry = current, entry.id == wake.id, generation == wake.generation, runningSince != nil else { return .ignored }
        let left = remaining(now: now) ?? 0
        if left <= Self.expiryTolerance {
            current = nil
            runningSince = nil
            remainingSeconds = 0
            generation += 1
            return .expired
        }
        return .again(Wake(id: entry.id, generation: generation, after: left))
    }

    /// Seconds left on the current toast, or nil with none.
    func remaining(now: Date) -> TimeInterval? {
        guard current != nil else { return nil }
        guard let since = runningSince else { return remainingSeconds }
        return max(0, remainingSeconds - now.timeIntervalSince(since))
    }
}
