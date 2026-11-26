import Foundation

/// Pure rules for dragging library thumbnails onto a sidebar collection. No SwiftUI, no database.
enum SidebarDrop {
    /// What a drag that starts on `item` carries. A cell that is selected (a collapsed stack only when ALL its visible members are) drags the
    /// whole selection, sorted; any other cell drags only what it stands for (a collapsed stack: all its visible members). A partly
    /// selected collapsed stack therefore counts as unselected, like `PhotoActionMenu.clickTarget`. A drag never changes the selection.
    static func draggedIDs(for item: StackGridItem, selection: Set<Int64>) -> [Int64] {
        if StackSelection.isSelected(item, in: selection) { return selection.sorted() }
        return StackSelection.ids(for: item)
    }

    /// Only a plain (non-folder) collection accepts photos. All Photos, smart collections, folders, headers and draft rows do not.
    static func accepts(_ row: SidebarRow) -> Bool {
        guard row.filter != nil, case .collection? = row.source else { return false }
        return true
    }

    struct Result: Equatable {
        var added: [Int64]
        var alreadyIn: Int
        var missing: Int
    }

    /// Splits `dragged` into the photos to add, those already in the collection, and those the catalog no longer knows.
    static func result(dragged: [Int64], existingMembers: Set<Int64>, knownIDs: Set<Int64>) -> Result {
        var seen = Set<Int64>()
        var result = Result(added: [], alreadyIn: 0, missing: 0)
        for id in dragged where seen.insert(id).inserted {
            if !knownIDs.contains(id) { result.missing += 1 }
            else if existingMembers.contains(id) { result.alreadyIn += 1 }
            else { result.added.append(id) }
        }
        return result
    }

    /// The result a drop reports once its write has landed. Anything not written is an alert (`.incomplete`), never a toast.
    static func feedback(_ result: Result, collectionName: String) -> Feedback {
        func photos(_ n: Int) -> String { "\(n) photo\(n == 1 ? "" : "s")" }
        let kind = FeedbackClassifier.batch(written: result.added.count, unchanged: result.alreadyIn, notWritten: result.missing)
        switch kind {
        case .incomplete:
            var message = "\(photos(result.missing)) could not be added because they are no longer in the Library."
            if !result.added.isEmpty { message += " \(photos(result.added.count)) added to \u{201C}\(collectionName)\u{201D}." }
            return Feedback(kind: .incomplete, title: "Some photos were not added", message: message)
        case .nothingToDo:
            return Feedback(kind: .nothingToDo, title: "Already in the collection",
                            message: "These photos are already in \u{201C}\(collectionName)\u{201D}.")
        default:
            var message = "Added \(photos(result.added.count)) to \u{201C}\(collectionName)\u{201D}."
            if result.alreadyIn > 0 { message += " (\(result.alreadyIn) \(result.alreadyIn == 1 ? "was" : "were") already in it)" }
            return Feedback(kind: .done, title: "Added to collection", message: message)
        }
    }
}
