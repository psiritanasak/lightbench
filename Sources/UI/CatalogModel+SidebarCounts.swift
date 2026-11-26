import Foundation

extension CatalogModel {
    /// Debounce before a recount. By eye, not measured: it only has to outlast the bursts the camera-data scan and bulk
    /// writes publish in.
    private static let smartCountDebounce: Duration = .milliseconds(150)

    /// What the counts run over, as cheap copies for the detached task: the whole-catalog `base` (when `refresh()` read one) and
    /// the live `photos` whose rows replace the base's. Nil when no complete list is known (a collection is shown and the base
    /// read failed): the counts are then cleared, never computed over the collection alone.
    private func smartCountInputs() -> (base: [Photo]?, photos: [Photo])? {
        if let base = smartCountBasePhotos { return (base, photos) }
        return photosAreWholeCatalog ? (nil, photos) : nil
    }

    /// `base` with every row of `photos` (same id) put in its place, so local-first edits show at once.
    nonisolated static func mergedSmartCountPhotos(base: [Photo]?, photos: [Photo]) -> [Photo] {
        guard let base else { return photos }
        let current = Dictionary(photos.compactMap { photo in photo.id.map { ($0, photo) } }, uniquingKeysWith: { _, new in new })
        return base.map { $0.id.flatMap { current[$0] } ?? $0 }
    }

    /// Recounts every smart collection off the main thread. Cancels a pending or running recount; publishes only if not
    /// cancelled and changed. No smart collections: clears the map and starts no task.
    func scheduleSmartCollectionCounts() {
        smartCountTask?.cancel()
        smartCountTask = nil
        guard !smartCollections.isEmpty else {
            if !smartCollectionCounts.isEmpty { smartCollectionCounts = [:] }
            return
        }
        smartCountTask = Task { [weak self] in
            try? await Task.sleep(for: Self.smartCountDebounce)
            guard !Task.isCancelled, let self else { return }
            guard let inputs = smartCountInputs() else {
                if !smartCollectionCounts.isEmpty { smartCollectionCounts = [:] }
                return
            }
            // Value copies taken on the main actor (all of these types are Sendable); the merge happens off it.
            let smart = smartCollections, keywords = keywords
            let links = keywordIDsByPhotoID, metadata = metadataByPhotoID, info = infoByPhotoID
            let work = Task.detached(priority: .utility) {
                let merged = CatalogModel.mergedSmartCountPhotos(base: inputs.base, photos: inputs.photos)
                return SmartCollectionCounts.counts(
                    smartCollections: smart, photos: merged, keywords: keywords, keywordIDsByPhotoID: links,
                    metadataByPhotoID: metadata, infoByPhotoID: info, isCancelled: { Task.isCancelled })
            }
            let counts = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, counts != smartCollectionCounts else { return }
            smartCollectionCounts = counts
        }
    }
}
