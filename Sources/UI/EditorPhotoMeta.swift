import Foundation

/// The catalog row (rating / flag / colour label) of the photo OPEN in the Editor, for the bar under the photo and the editor's
/// rating keys. The Editor only knows a URL, so the row is looked up by path, asynchronously; no row (a photo opened with
/// File > Open that was never imported, a lookup failure) means `photo == nil` and every action is a no-op.
///
/// Two hazards it guards: a lookup that finishes AFTER the user moved on (each `sync` bumps a token; a stale result is dropped),
/// and the photo being mid-load (`currentURL` still names the OUTGOING photo for the whole load, so `photo` is cleared then and
/// actions cannot land on the wrong photo). Changes are applied to this model's own copy first (the bar never waits on the
/// database) and forwarded to the same `CatalogModel` setters the grid uses, which update the grid's rows and write the database.
@MainActor
final class EditorPhotoMeta: ObservableObject {
    @Published private(set) var photo: Photo?

    typealias Resolver = @MainActor (String) async throws -> Photo?
    private var resolve: Resolver
    private var setRatingInCatalog: (Int, Photo) -> Void
    private var setFlagInCatalog: (FlagStatus, Photo) -> Void
    private var setLabelInCatalog: (ColorLabel, Photo) -> Void
    private var token = 0

    /// The defaults resolve nothing and change nothing: `ContentView` owns this as a `@StateObject` before it has a catalog,
    /// and wires the real one with `configure` on appear.
    init(resolve: @escaping Resolver = { _ in nil },
         setRating: @escaping (Int, Photo) -> Void = { _, _ in },
         setFlagStatus: @escaping (FlagStatus, Photo) -> Void = { _, _ in },
         setColorLabel: @escaping (ColorLabel, Photo) -> Void = { _, _ in }) {
        self.resolve = resolve
        self.setRatingInCatalog = setRating
        self.setFlagInCatalog = setFlagStatus
        self.setLabelInCatalog = setColorLabel
    }

    func configure(resolve: @escaping Resolver,
                   setRating: @escaping (Int, Photo) -> Void,
                   setFlagStatus: @escaping (FlagStatus, Photo) -> Void,
                   setColorLabel: @escaping (ColorLabel, Photo) -> Void) {
        self.resolve = resolve
        self.setRatingInCatalog = setRating
        self.setFlagInCatalog = setFlagStatus
        self.setLabelInCatalog = setColorLabel
    }

    /// Call whenever the open photo's path or the load state changes. Clears `photo` while loading or with no photo; otherwise
    /// looks the row up. Returns the lookup task (nil when nothing is looked up) so tests can await it.
    @discardableResult
    func sync(path: String?, isLoading: Bool) -> Task<Void, Never>? {
        token += 1
        guard let path, !isLoading else {
            photo = nil
            return nil
        }
        // A different path than the one held must not keep acting on the old row while the lookup runs.
        if photo?.path != path { photo = nil }
        let mine = token
        return Task { [weak self] in
            guard let self else { return }
            let found = try? await self.resolve(path)
            guard mine == self.token else { return }
            self.photo = found ?? nil
        }
    }

    /// Applies a key command. Returns true if it was handled (a photo is resolved and the command is one this model applies).
    @discardableResult
    func apply(_ command: PhotoKeyCommand) -> Bool {
        guard let current = photo else { return false }
        switch command {
        case .rating(let value): setRating(value)
        case .flag: if let status = command.flagStatus(from: current.flagStatus) { setFlag(status) }
        case .label: if let label = command.label(from: current.colorLabel) { setLabel(label) }
        }
        return true
    }

    /// 0...5, clamped like `CatalogModel.setRating`.
    func setRating(_ rating: Int) {
        guard var current = photo else { return }
        let clamped = min(max(rating, 0), 5)
        token += 1 // a lookup already in flight may hold the pre-change row (the catalog writes the database later)
        current.rating = clamped
        photo = current
        setRatingInCatalog(clamped, current)
    }

    func setFlag(_ status: FlagStatus) {
        guard var current = photo else { return }
        token += 1 // a lookup already in flight may hold the pre-change row (the catalog writes the database later)
        current.flagStatus = status
        photo = current
        setFlagInCatalog(status, current)
    }

    func setLabel(_ label: ColorLabel) {
        guard var current = photo else { return }
        token += 1 // a lookup already in flight may hold the pre-change row (the catalog writes the database later)
        current.colorLabel = label
        photo = current
        setLabelInCatalog(label, current)
    }
}
