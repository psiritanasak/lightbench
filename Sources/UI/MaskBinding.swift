import SwiftUI

extension Binding where Value == EditState {
    /// A binding to the mask with `id`, resolved by IDENTITY on every
    /// access — never a captured array index, since array position shifts
    /// whenever an EARLIER mask is deleted. Returns `nil` if no such mask
    /// currently exists, so call sites gate with `if let` rather than build
    /// a dependent view (`MaskDetailView`/`MaskOverlayView`) against a mask
    /// that's gone — the same "compute the truth, don't trust the caller"
    /// shape `ContentView.isEditingMask` uses one level up.
    func mask(id: UUID) -> Binding<Mask>? {
        guard wrappedValue.masks.contains(where: { $0.id == id }) else { return nil }
        return Binding<Mask>(
            get: {
                // The `?? Mask(id: id)` fallback is only reachable in the
                // one-frame window between a delete and the parent's
                // `if let` re-evaluating (e.g. an in-flight drag gesture
                // reading through a binding it already captured) — it
                // renders default values in a view that's about to
                // disappear, and can never be written back (the setter
                // below no-ops for a missing id).
                wrappedValue.masks.first(where: { $0.id == id }) ?? Mask(id: id)
            },
            set: { newValue in
                guard let index = wrappedValue.masks.firstIndex(where: { $0.id == id }) else { return }
                wrappedValue.masks[index] = newValue
            }
        )
    }
}
