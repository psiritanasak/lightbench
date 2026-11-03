import Foundation

/// Which faces an action in the People grid applies to.
enum FaceMarking {
    /// The faces an action on `clicked` (a right-click, a menu) applies to: every MARKED face when `clicked` is one of them (the Finder
    /// rule: acting on a face inside the selection acts on the whole selection), otherwise just `clicked`. In `shownOrder`, so the result
    /// is deterministic; a marked id that is not shown any more is dropped (a stale mark must never be acted on).
    static func targets(clicked: Int64, marked: Set<Int64>, shownOrder: [Int64]) -> [Int64] {
        guard marked.contains(clicked) else { return [clicked] }
        return shownOrder.filter { marked.contains($0) }
    }
}
