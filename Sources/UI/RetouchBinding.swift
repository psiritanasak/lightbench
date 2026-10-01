import SwiftUI

extension Binding where Value == EditState {
    /// A binding to the retouch spot with `id`, resolved by IDENTITY on every access (array positions shift when an
    /// earlier spot is deleted) — `Binding.mask(id:)`'s shape. `nil` if no such spot exists, so call sites gate with
    /// `if let` instead of building views against a spot that is gone.
    func retouchSpot(id: UUID) -> Binding<RetouchSpot>? {
        guard wrappedValue.retouchSpots.contains(where: { $0.id == id }) else { return nil }
        return Binding<RetouchSpot>(
            get: { wrappedValue.retouchSpots.first(where: { $0.id == id }) ?? RetouchSpot() },
            set: { newValue in
                guard let index = wrappedValue.retouchSpots.firstIndex(where: { $0.id == id }),
                      newValue.isFinite // a NaN in EditState would make every sidecar write throw
                else { return }
                wrappedValue.retouchSpots[index] = newValue
            }
        )
    }
}
