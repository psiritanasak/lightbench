import SwiftUI

extension Binding where Value == EditState {
    /// A binding to the point color instance with `id`, resolved by
    /// IDENTITY on every access — never a captured array index, matching
    /// `Binding<EditState>.mask(id:)`'s own shape (array position shifts
    /// whenever an EARLIER instance is deleted). Returns `nil` if no such
    /// instance currently exists, so call sites gate with `if let` rather
    /// than build a dependent view (`PointColorDetailView`) against an
    /// instance that's gone.
    func pointColor(id: UUID) -> Binding<PointColor>? {
        guard wrappedValue.pointColors.contains(where: { $0.id == id }) else { return nil }
        return Binding<PointColor>(
            get: {
                // The `?? PointColor(id: id)` fallback is only reachable in
                // the one-frame window between a delete and the parent's
                // `if let` re-evaluating — see `mask(id:)`'s own comment.
                wrappedValue.pointColors.first(where: { $0.id == id }) ?? PointColor(id: id)
            },
            set: { newValue in
                guard let index = wrappedValue.pointColors.firstIndex(where: { $0.id == id }) else { return }
                wrappedValue.pointColors[index] = newValue
            }
        )
    }
}
