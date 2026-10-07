import CoreImage
import Foundation

/// Owns the thumbnail previews for the Looks tab's two grids (Looks, Style presets): one small realized base of the open photo,
/// and a preview per cell rendered from it (`LookPreviewRenderer`). Owned by `ContentView` (like `adjustPanel`) because
/// `LooksTabView` is torn down on every tab switch.
///
/// Each grid is refreshed independently and is stale exactly when its key changes (`LookPreviewItem.looksGridKey` /
/// `stylesGridKey`): picking a Look re-renders only the Style grid, and vice versa. A refresh renders the cells one after another
/// off the main actor, publishing each as it finishes. A newer refresh (or a photo switch) CANCELS the older pass: the pass
/// checks `Task.isCancelled` on the main actor before every publish, and `cancel()` itself runs on the main actor, so a
/// cancelled pass can never publish after `cancel()` returns — no generation counter is needed (removing the `cancel()` call
/// fails a test; a counter on top changed no test result). Cell renders are structured children (`renderCell`), so one that has
/// not started when the pass is cancelled is skipped; the render already running finishes and is discarded. Previews of a
/// PREVIOUS photo are cleared the moment the image revision changes (placeholders show meanwhile); previews of the same
/// photo stay on screen while a refresh is running. `revision` says which image the published previews belong to, so a view
/// returning to the tab can hide a stale set before the next refresh clears it. The `render`/`makeBase` closures are
/// injectable so tests stay deterministic.
@MainActor
final class LookPreviewModel: ObservableObject {
    /// Cell id ("" = None) -> preview.
    @Published private(set) var looks: [String: CGImage] = [:]
    @Published private(set) var styles: [String: CGImage] = [:]

    private enum Grid { case looks, styles }

    private let makeBase: @Sendable (CIImage) async -> CIImage?
    private let render: @Sendable (EditState, CIImage) -> CGImage?
    private let releaseCaches: @Sendable () -> Void

    /// The image revision the published previews and the base belong to; nil until the first refresh (or after no image).
    @Published private(set) var revision: Int?
    private var currentRevision: Int? {
        get { revision }
        set { revision = newValue }
    }
    private var baseCache: (revision: Int, image: CIImage)?
    private var baseInFlight: (revision: Int, task: Task<CIImage?, Never>)?

    private var looksKey: LooksInput?
    private var stylesKey: StylesInput?
    private var looksTask: Task<Void, Never>?
    private var stylesTask: Task<Void, Never>?

    /// The previews, but only if they belong to `imageRevision` (empty otherwise): a hidden Looks tab never refreshes, so after a
    /// photo switch the old photo's previews can still be published until the next refresh clears them.
    func looks(forRevision imageRevision: Int) -> [String: CGImage] { revision == imageRevision ? looks : [:] }
    func styles(forRevision imageRevision: Int) -> [String: CGImage] { revision == imageRevision ? styles : [:] }

    /// How long the view waits before asking for a refresh: none when this photo has no previews yet (the grid should fill as soon
    /// as the tab opens), a short debounce when previews already exist and an edit changed their inputs (so dragging the
    /// Intensity or Strength slider does not start a pass per tick). A UI policy value, not a measurement.
    static func refreshDelayNanoseconds(hasPreviewsForThisPhoto: Bool) -> UInt64 { hasPreviewsForThisPhoto ? 250_000_000 : 0 }

    /// What the Looks grid was last (or is being) rendered from.
    private struct LooksInput: Equatable { let state: EditState; let userLookIDs: [String] }
    private struct StylesInput: Equatable { let state: EditState }

    init(
        makeBase: @escaping @Sendable (CIImage) async -> CIImage? = { await LookPreviewRenderer.makeBase(from: $0) },
        render: @escaping @Sendable (EditState, CIImage) -> CGImage? = { LookPreviewRenderer.render($0, base: $1) },
        releaseCaches: @escaping @Sendable () -> Void = { LookPreviewRenderer.releaseCaches() }
    ) {
        self.makeBase = makeBase
        self.render = render
        self.releaseCaches = releaseCaches
    }

    /// Re-renders the Looks grid if its inputs changed. `image` is the document's current image, `imageRevision` its revision.
    func refreshLooks(state: EditState, image: CIImage?, imageRevision: Int, userLooks: [LookLibrary.UserLook]) {
        guard noteImage(image, revision: imageRevision), let image else { return }
        let input = LooksInput(state: LookPreviewItem.looksGridKey(for: state), userLookIDs: userLooks.map(\.id))
        guard input != looksKey else { return }
        looksKey = input
        looksTask?.cancel()
        looksTask = start(.looks, items: LookPreviewItem.looks(userLooks: userLooks), state: state,
                          image: image, revision: imageRevision)
    }

    /// Re-renders the Style grid if its inputs changed.
    func refreshStyles(state: EditState, image: CIImage?, imageRevision: Int) {
        guard noteImage(image, revision: imageRevision), let image else { return }
        let input = StylesInput(state: LookPreviewItem.stylesGridKey(for: state))
        guard input != stylesKey else { return }
        stylesKey = input
        stylesTask?.cancel()
        stylesTask = start(.styles, items: LookPreviewItem.styles(), state: state,
                           image: image, revision: imageRevision)
    }

    // MARK: - Internals

    /// Records which photo the previews belong to. Returns false (after clearing everything and cancelling running passes) when
    /// there is no image; clears everything when the revision CHANGED (the old photo's previews must not linger).
    private func noteImage(_ image: CIImage?, revision: Int) -> Bool {
        guard image != nil else {
            clearAll()
            currentRevision = nil
            return false
        }
        if currentRevision != revision {
            clearAll()
            currentRevision = revision
        }
        return true
    }

    private func clearAll() {
        looksTask?.cancel(); stylesTask?.cancel()
        looksTask = nil; stylesTask = nil
        looksKey = nil; stylesKey = nil
        baseCache = nil
        baseInFlight?.task.cancel()
        baseInFlight = nil
        if !looks.isEmpty { looks = [:] }
        if !styles.isEmpty { styles = [:] }
    }

    private func start(
        _ grid: Grid, items: [LookPreviewItem], state: EditState, image: CIImage, revision: Int
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            guard let base = await self.ensureBase(image: image, revision: revision), !Task.isCancelled else {
                // A failed base build must not wedge the grid: forget the key so the next refresh retries.
                if !Task.isCancelled { self.forgetKey(grid) }
                return
            }
            let render = self.render
            let previewState = LookPreviewItem.previewState(from: state)
            for item in items {
                guard !Task.isCancelled else { return }
                let cell = item.applying(to: previewState)
                let rendered = await Self.renderCell(render, cell, base)
                guard !Task.isCancelled else { return }
                if let rendered { self.publish(grid, id: item.id, rendered) }
            }
            self.releaseCaches()
        }
    }

    /// One cell's render, off the main actor (`@concurrent`, so it holds even if the build later enables NonisolatedNonsendingByDefault) but still a STRUCTURED
    /// child of the pass: its cancellation is visible here, so a render that has not started yet is skipped.
    @concurrent private nonisolated static func renderCell(
        _ render: @Sendable (EditState, CIImage) -> CGImage?, _ state: EditState, _ base: CIImage
    ) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return render(state, base)
    }

    private func forgetKey(_ grid: Grid) {
        switch grid {
        case .looks: looksKey = nil
        case .styles: stylesKey = nil
        }
    }

    private func publish(_ grid: Grid, id: String, _ image: CGImage) {
        switch grid {
        case .looks: looks[id] = image
        case .styles: styles[id] = image
        }
    }

    /// The small base for `revision`, built once and shared by both grids (a second caller awaits the first's build). A result
    /// for a revision that is no longer current is returned to its caller but never cached.
    private func ensureBase(image: CIImage, revision: Int) async -> CIImage? {
        if let cached = baseCache, cached.revision == revision { return cached.image }
        if let inFlight = baseInFlight, inFlight.revision == revision { return await inFlight.task.value }
        let makeBase = self.makeBase
        let task = Task { await makeBase(image) }
        baseInFlight = (revision, task)
        let result = await task.value
        if baseInFlight?.revision == revision { baseInFlight = nil }
        if let result, currentRevision == revision { baseCache = (revision, result) }
        return result
    }
}
