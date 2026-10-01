import Foundation

/// Resolves a `lookID` (as stored in `EditState`) to a `CubeLUT`. Built-in looks come from
/// `BuiltInLooks`; user-imported `.cube` looks are registered here by the layer that owns the files
/// (`LookStore` in Rendering), so `EditEngine` stays free of file I/O. An id nobody can resolve returns
/// `nil`, which the pipeline treats as "no look" — a sidecar from a machine that had a look this one
/// doesn't must still open and render.
final class LookLibrary: @unchecked Sendable {
    static let shared = LookLibrary()

    struct UserLook: Equatable, Sendable {
        let id: String
        let name: String
        let cube: CubeLUT
    }

    private let lock = NSLock()
    private var user: [String: UserLook] = [:]

    func cube(for id: String) -> CubeLUT? {
        guard !id.isEmpty else { return nil }
        if id.hasPrefix("builtin:") { return BuiltInLooks.cube(id: id) }
        lock.lock()
        defer { lock.unlock() }
        return user[id]?.cube
    }

    func displayName(for id: String) -> String? {
        if let look = BuiltInLooks.look(id: id) { return look.name }
        lock.lock()
        defer { lock.unlock() }
        return user[id]?.name
    }

    func register(_ look: UserLook) {
        // `cube(for:)` resolves "builtin:" ids from `BuiltInLooks` and never consults this dictionary, so a
        // user look squatting on that prefix would be unreachable.
        guard !look.id.hasPrefix("builtin:") else { return }
        lock.lock()
        user[look.id] = look
        lock.unlock()
    }

    func unregister(id: String) {
        lock.lock()
        user[id] = nil
        lock.unlock()
    }

    func removeAllUserLooks() {
        lock.lock()
        user.removeAll()
        lock.unlock()
    }

    /// User looks sorted by name (stable order for the UI).
    var userLooks: [UserLook] {
        lock.lock()
        defer { lock.unlock() }
        return user.values.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }
}
