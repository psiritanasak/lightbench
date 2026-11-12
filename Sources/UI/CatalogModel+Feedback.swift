import Foundation

// MARK: - Relocate results

/// How a single-photo relocate ended (after a matching file was found in the chosen folder).
enum RelocateOneResult: Equatable, Sendable {
    case relocated
    /// A different photo is already catalogued at the new location.
    case conflict
    case failed
}

/// The text and kind of the Library's relocate results. Pure statics so the texts and kinds are testable without a catalog.
extension CatalogModel {
    /// A relocated photo is a `.notice` (the user must move its sidecar file by hand, so it is read, not a passing toast); with an access
    /// warning it is `.incomplete`; a conflict or failure is an `.error`.
    nonisolated static func relocateOneFeedback(filename: String, result: RelocateOneResult, accessWarning: String?) -> Feedback {
        var message: String
        switch result {
        case .relocated:
            message = "Relocated \"\(filename)\". If it had saved edits, move its sidecar file too to keep them."
        case .conflict:
            message = "Couldn't relocate \"\(filename)\" — a different photo is already catalogued at that location."
        case .failed:
            message = "Couldn't relocate \"\(filename)\"."
        }
        if let accessWarning { message += " \(accessWarning)" }
        switch result {
        case .relocated:
            return Feedback(kind: accessWarning == nil ? .notice : .incomplete, title: feedbackTitle, message: message)
        case .conflict, .failed:
            return .error(feedbackTitle, message)
        }
    }

    /// `relocated` of `missing` photos were moved; `unmatched` had no file in the folder and `conflicts` were already catalogued there.
    /// `failed` = the database write threw. Anything not relocated, or an access warning, makes it `.incomplete`; a clean result is a
    /// `.notice` because the sidecar files must still be moved by hand.
    nonisolated static func relocateBatchFeedback(
        relocated: Int, missing: Int, unmatched: Int, conflicts: Int, failed: Bool, accessWarning: String?
    ) -> Feedback {
        if failed {
            var message = "Couldn't relocate the selected photos."
            if let accessWarning { message += " \(accessWarning)" }
            return .error(feedbackTitle, message)
        }
        var message = "Relocated \(relocated) of \(missing) photo(s)."
        if unmatched > 0 { message += " \(unmatched) not found in that folder." }
        if conflicts > 0 { message += " \(conflicts) skipped (already catalogued at that location)." }
        if relocated > 0 { message += " Move any saved-edit sidecar files too, to keep their edits." }
        if let accessWarning { message += " \(accessWarning)" }
        let notWritten = unmatched + conflicts + (accessWarning == nil ? 0 : 1)
        if notWritten > 0 { return Feedback(kind: .incomplete, title: feedbackTitle, message: message) }
        return Feedback(kind: relocated > 0 ? .notice : .nothingToDo, title: feedbackTitle, message: message)
    }
}
