import AppKit
import CoreImage
import UniformTypeIdentifiers

/// Owns the currently displayed image state. Only ever reads image files —
/// never writes to originals, preserving the app's non-destructive invariant.
@MainActor
final class ImageDocumentModel: ObservableObject {
    @Published private(set) var currentImage: CIImage?
    @Published private(set) var currentFileName: String?
    @Published var loadErrorMessage: String?
    @Published var editState = EditState() {
        didSet { scheduleHistogramUpdate() }
    }

    /// Live Levels histogram, `HistogramComputer.binCount` values normalized
    /// 0...1. Empty until the first debounced recompute finishes (or if no
    /// image is loaded). See `recomputeHistogram()` for what state it
    /// actually reflects.
    @Published private(set) var histogramBins: [Float] = []

    private var histogramWorkItem: DispatchWorkItem?
    /// Guards against an out-of-order background histogram result (an OLDER
    /// in-flight computation finishing after a NEWER one) overwriting fresher
    /// data — `DispatchWorkItem.cancel()` (used for the debounce below)
    /// reliably stops a not-yet-started item, but `Task` cancellation is only
    /// cooperative and `EditPipeline.apply`/`HistogramComputer` don't check
    /// for it, so a simple monotonic generation counter is the correct
    /// "only the latest result wins" mechanism here, not task cancellation.
    private var histogramGeneration = 0

    func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(from: url)
    }

    func load(from url: URL) {
        guard let raw = CIImage(contentsOf: url) else {
            loadErrorMessage = "Couldn't open \"\(url.lastPathComponent)\". The file may be missing, unreadable, or not a supported image format."
            return
        }
        currentImage = raw.oriented(Self.exifOrientation(of: url))
        currentFileName = url.lastPathComponent
        editState = EditState() // edits are per-photo; don't carry over to the next one opened
    }

    private static func exifOrientation(of url: URL) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let raw = properties[kCGImagePropertyOrientation as String] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else {
            return .up
        }
        return orientation
    }

    // MARK: - Histogram

    /// Debounces histogram recomputation (~150ms) so a fast slider drag
    /// doesn't trigger a background render on every intermediate value —
    /// matches CLAUDE.md's "DB access never blocks main thread... thumbnails
    /// generate on a background queue" principle, applied here to a UI
    /// computation for the first time in this codebase. Fires on EVERY
    /// `editState` change (not just Levels' own sliders): `load(from:)`
    /// resets `editState` right after setting `currentImage`, so opening a
    /// new photo also correctly triggers a recompute against the new image.
    private func scheduleHistogramUpdate() {
        histogramWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.recomputeHistogram() }
        histogramWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    /// Computes the histogram from the CURRENT edit state with the user's
    /// own not-yet-applied Levels adjustment neutralized to identity — a
    /// deliberate v1 scope decision, not a literal "state before Levels"
    /// (which would need `EditPipeline` API surface to expose a true
    /// pre-Levels intermediate). This shows "the final image's tonal
    /// distribution as it stands, holding your own Levels tweak out of the
    /// picture so it doesn't conflate the reference" — stays stable while
    /// dragging the Levels sliders themselves (since those are zeroed for
    /// this computation) and correctly updates for every OTHER edit (crop,
    /// exposure, contrast, etc.), matching what a real Levels histogram is
    /// for without new pipeline surface.
    private func recomputeHistogram() {
        guard let currentImage else {
            histogramBins = []
            return
        }
        var referenceState = editState
        referenceState.levelsBlackPoint = 0
        referenceState.levelsWhitePoint = 1
        referenceState.levelsGamma = 1

        histogramGeneration += 1
        let generation = histogramGeneration

        Task.detached(priority: .userInitiated) { [weak self] in
            let edited = EditPipeline.apply(referenceState, to: currentImage)
            let bins = HistogramComputer.histogram(of: edited)
            await MainActor.run {
                guard let self, self.histogramGeneration == generation else { return }
                self.histogramBins = bins
            }
        }
    }
}
