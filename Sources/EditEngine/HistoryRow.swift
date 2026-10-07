import Foundation

/// One row of the History list, as the UI shows it: newest first, with where it sits relative to the undo cursor. Pure — the
/// list view (`HistoryPopoverView`) only draws these, so the ordering and the accessibility strings are unit-testable.
struct HistoryRow: Identifiable, Equatable, Sendable {
    enum Position: Equatable, Sendable {
        /// The state the photo is in right now.
        case current
        /// At or before the cursor but not the current one (an older state the user can jump back to).
        case past
        /// AFTER the cursor: the redo branch the next edit would abandon.
        case undone
    }

    let id: UUID
    let summary: String
    let position: Position

    var isCurrent: Bool { position == .current }

    /// VoiceOver text: the summary, plus ", current" or ", undone".
    var accessibilityText: String {
        switch position {
        case .current: return "\(summary), current"
        case .undone: return "\(summary), undone"
        case .past: return summary
        }
    }

    /// The rows for `entries` with the cursor at `currentIndex`, NEWEST FIRST (the opposite of `EditHistory.entries`' storage
    /// order, matching Lightroom's History panel). An index outside the list marks no row current: negative = every row is
    /// undone, past the end = every row is past.
    static func rows(entries: [HistoryEntry], currentIndex: Int) -> [HistoryRow] {
        entries.enumerated().reversed().map { index, entry in
            let position: Position = index == currentIndex ? .current : (index > currentIndex ? .undone : .past)
            return HistoryRow(id: entry.id, summary: entry.summary, position: position)
        }
    }
}
