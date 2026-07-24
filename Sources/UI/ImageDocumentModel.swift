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
    @Published var editState = EditState()

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
}
