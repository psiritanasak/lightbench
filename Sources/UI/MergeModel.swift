import AppKit
import Foundation
import ImageIO

/// The UI-facing coordinator for Photo Merge (HDR bracket now; panorama later) — kept in `Sources/UI` while `PhotoMerger` stays UI-free,
/// mirroring `EnhanceModel`/`PhotoEnhancer`. Owned by `CatalogModel` (like `faces` / `duplicates`) so the Scene-level Photo menu and the
/// selection menu can reach it without `ContentView` growing; `MergeDialogModifier` presents its confirmation, progress and result.
///
/// Flow: a menu item REQUESTS a merge of the selected, visible photos -> `pending` is set and a confirmation dialog explains what will happen
/// (frame count, output size, tripod vs auto-align) -> `confirm` resolves write access to the output folder (the first selected photo's folder),
/// runs `PhotoMerger` detached, and registers the new file with the catalog. Nothing is written if any step is refused. Originals and sidecars
/// are never touched.
@MainActor
final class MergeModel: ObservableObject {
    enum Kind: Equatable {
        case hdr
        case panorama
    }

    /// What the confirmation dialog's button chose.
    enum Option: Equatable {
        /// `align: false` is for a tripod bracket (frames already in register).
        case hdr(align: Bool)
        /// `crop: true` trims the ragged edges to the largest valid rectangle.
        case panorama(crop: Bool)
    }

    struct Request: Equatable {
        let kind: Kind
        let photos: [Photo]
        /// Approximate size of the output file (about 8 bytes per pixel, half-float RGBA), when the first photo's dimensions could be read.
        let estimatedBytes: Int64?
    }

    @Published var pending: Request? { didSet { publishBusy() } }
    @Published private(set) var isMerging = false { didSet { publishBusy() } }
    @Published var statusMessage: String?

    var isBusy: Bool { isMerging || pending != nil }

    /// Mirrors `isBusy` into the catalog (a plain `@Published` there), so views that only observe `CatalogModel` — the Photo menu, the other
    /// sheets' `blocked` flags — see it change.
    private weak var catalog: CatalogModel?
    private func publishBusy() { catalog?.mergeBusy = isBusy }

    /// Injectable so tests never open a real `NSOpenPanel` (the app always uses the real `SidecarFolderAccess`).
    private let folderAccess: SidecarFolderAccessing

    init(folderAccess: SidecarFolderAccessing = SidecarFolderAccess()) {
        self.folderAccess = folderAccess
    }

    // MARK: - Request

    /// Asks for a merge of `photos` (already filtered to what the Library shows). Refuses with a message rather than opening a dialog that
    /// could not succeed.
    func request(_ kind: Kind, photos: [Photo], catalog: CatalogModel) {
        self.catalog = catalog
        guard !isBusy else { return }
        guard !catalog.isRenameInProgress else { statusMessage = CatalogModel.renameInProgressMessage; return }
        if let problem = Self.selectionProblem(kind, count: photos.count) { statusMessage = problem; return }
        pending = Request(kind: kind, photos: photos, estimatedBytes: Self.estimatedOutputBytes(forFileAt: URL(fileURLWithPath: photos[0].path)))
    }

    func cancel() { pending = nil }

    // MARK: - Run

    /// Runs `request` (the value the confirmation dialog handed its button, NOT `pending`: SwiftUI does not document whether it clears the
    /// dialog's `isPresented` binding before or after a button's action, and `pending` may already be nil by then).
    func confirm(_ request: Request, option: Option, catalog: CatalogModel) {
        self.catalog = catalog
        guard !isMerging else { return }
        pending = nil
        isMerging = true
        Task {
            defer { isMerging = false }
            guard !catalog.isRenameInProgress else { statusMessage = CatalogModel.renameInProgressMessage; return }
            let urls = request.photos.map { URL(fileURLWithPath: $0.path) }
            let folder = urls[0].deletingLastPathComponent()
            switch folderAccess.resolveOrRequest(
                for: folder,
                message: "Allow access to “\(folder.lastPathComponent)” so the merged photo can be saved next to the first selected photo."
            ) {
            case .declined:
                return // silent, like Enhance: every attempt is an explicit new one
            case .failed(let error):
                statusMessage = error.localizedDescription
            case .granted(let grantedFolder):
                guard grantedFolder.coversAccess(to: folder) else {
                    statusMessage = "Photo Merge needs access to “\(folder.lastPathComponent)” (or a parent folder containing it) — try again."
                    return
                }
                await run(urls: urls, option: option, accessScope: grantedFolder, destinationFolder: folder, catalog: catalog)
            }
        }
    }

    private func run(urls: [URL], option: Option, accessScope: URL, destinationFolder: URL, catalog: CatalogModel) async {
        guard accessScope.startAccessingSecurityScopedResource() else {
            statusMessage = "Couldn't get access to the destination folder."
            return
        }
        defer { accessScope.stopAccessingSecurityScopedResource() }

        let outcome: MergeOutcome
        do {
            outcome = try await Task.detached {
                switch option {
                case .hdr(let align): return try await PhotoMerger.mergeHDR(sourceURLs: urls, align: align, into: destinationFolder)
                case .panorama(let crop): return try await PanoramaMerger.mergePanorama(sourceURLs: urls, cropToFill: crop, into: destinationFolder)
                }
            }.value
        } catch {
            statusMessage = "Photo Merge failed: \(error.localizedDescription)"
            return
        }
        // The file is on disk by now: a registration failure must say so rather than claim the merge failed.
        do {
            _ = try await catalog.registerEnhancedPhoto(at: outcome.url)
            statusMessage = Self.summary(outcome)
        } catch let error as CatalogDatabaseError {
            statusMessage = "Created “\(outcome.url.lastPathComponent)”, but couldn't add it to the Library: \(error.message)"
        } catch {
            statusMessage = "Created “\(outcome.url.lastPathComponent)”, but couldn't add it to the Library: \(error.localizedDescription)"
        }
    }

    // MARK: - Pure text and limits (testable)

    /// Why a merge of `count` photos cannot start, or nil.
    nonisolated static func selectionProblem(_ kind: Kind, count: Int) -> String? {
        switch kind {
        case .hdr:
            if count < 2 { return "Select at least two photos taken at different exposures to merge to HDR." }
            if count > HDRMergeFilter.maxFrames { return "HDR merge supports at most \(HDRMergeFilter.maxFrames) photos; \(count) are selected." }
            return nil
        case .panorama:
            if count < 2 { return "Select at least two overlapping photos to make a panorama." }
            if count > PanoramaPlan.maxFrames { return "A panorama supports at most \(PanoramaPlan.maxFrames) photos; \(count) are selected." }
            return nil
        }
    }

    nonisolated static func confirmationTitle(_ request: Request) -> String {
        switch request.kind {
        case .hdr: return "Merge \(request.photos.count) photos to HDR?"
        case .panorama: return "Stitch \(request.photos.count) photos into a panorama?"
        }
    }

    nonisolated static func confirmationMessage(_ request: Request) -> String {
        let first = request.photos.first?.filename ?? "the first photo"
        switch request.kind {
        case .hdr:
            var text = "The photos are combined into one new high-dynamic-range file saved next to “\(first)”. "
                + "The originals are not changed. The result is a floating-point TIFF so highlights above white stay editable"
            if let bytes = request.estimatedBytes {
                text += " — roughly \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
            }
            return text + ". Choose “Tripod” only if the camera did not move between shots."
        case .panorama:
            var text = "The photos are joined, in the order they were taken, into one new panorama saved next to “\(first)”. "
                + "The originals are not changed. Neighbouring photos need to overlap by about half and be taken from one spot; very wide sweeps are refused. "
                + "The result is a floating-point TIFF"
            if let bytes = request.estimatedBytes {
                // About (n + 1) / 2 frames' worth for a level sweep with half overlap; a sweep that drifts up or down, or "Keep Edges", can be larger.
                text += " — roughly \(ByteCountFormatter.string(fromByteCount: bytes * Int64(request.photos.count + 1) / 2, countStyle: .file)) for a level sweep"
            }
            return text + "."
        }
    }

    nonisolated static func summary(_ outcome: MergeOutcome) -> String {
        let name = outcome.url.lastPathComponent
        var text: String
        switch outcome.mode {
        case .hdr:
            text = "Created “\(name)” from \(outcome.frameCount) photos (exposure reference: \(outcome.referenceName))"
            text += outcome.alignment.isEmpty ? ", without alignment." : ", aligned."
        case .panorama:
            text = "Created “\(name)” (\(Int(outcome.size.width)) × \(Int(outcome.size.height))) from \(outcome.frameCount) photos"
            text += outcome.cropped ? ", edges cropped." : ", edges kept."
        }
        if let weakest = outcome.alignment.min(by: { $0.inlierRatio < $1.inlierRatio }), weakest.inlierRatio < 0.5 {
            text += outcome.mode == .panorama
                ? " The join at “\(weakest.name)” was uncertain (\(weakest.inlierCount) of \(weakest.matchCount) matches agreed) — check the seam."
                : " Alignment of “\(weakest.name)” was uncertain (\(weakest.inlierCount) of \(weakest.matchCount) matches agreed) — check the result for ghosting."
        }
        if let biggest = outcome.gains.max(by: { abs($0.correction) < abs($1.correction) }), abs(biggest.correction) >= 0.05 {
            text += " The exposure of “\(biggest.name)” was measured \(Int((abs(biggest.correction) * 100).rounded()))% "
                + (biggest.correction > 0 ? "brighter" : "darker") + " than its camera data implied and was corrected."
        }
        return text
    }

    /// About 8 bytes per pixel (half-float RGBA) for the pixel size ImageIO reports for `url`; nil if it can't be read.
    nonisolated static func estimatedOutputBytes(forFileAt url: URL) -> Int64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value, w > 0, h > 0
        else { return nil }
        return w * h * 8
    }
}

extension MergeOutcome.FrameAlignment {
    var inlierRatio: Double { matchCount == 0 ? 0 : Double(inlierCount) / Double(matchCount) }
}
