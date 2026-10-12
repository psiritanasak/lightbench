import CoreImage
import SwiftUI

/// While click-on-image subject picking is armed: a red tint over the displayed photo wherever the CHOSEN subjects are
/// (the union of the mask's included subjects, feathered, via `EditPipeline.subjectMaskPreviewImage`). It shows the
/// chosen set, NOT the final effect: the mask's Invert and its combine mode are applied later in the pipeline and are
/// deliberately not reflected here (red always sits on the subjects you have ticked). Rendered small (<= 512px) off the main thread and re-rendered whenever the
/// edit state changes (toggling a subject, undo, a crop/flip tweak).
struct SubjectMaskTintOverlay: View {
    @ObservedObject var document: ImageDocumentModel
    let maskID: UUID
    let fitRect: CGRect
    /// Builds the selection image to tint (default: the `.subject` mask's; the Depth Range overlay passes its own).
    var preview: @Sendable (EditState, UUID, CIImage) -> CIImage? = { EditPipeline.subjectMaskPreviewImage($0, maskID: $1, source: $2) }
    var color = CIColor(red: 1, green: 0.1, blue: 0.1, alpha: 1)

    @State private var tint: CGImage?

    private static let context = CIContext(options: [.workingColorSpace: NSNull()])
    private static let maxSide: CGFloat = 512

    var body: some View {
        ZStack {
            if let tint {
                Image(decorative: tint, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .opacity(0.45)
            }
        }
        .frame(width: fitRect.width, height: fitRect.height)
        .position(x: fitRect.midX, y: fitRect.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Keyed on the whole edit state: it is Equatable, and any geometry/mask change must re-render (a hand-picked
        // field list would go stale — this codebase's recurring bug class). A burst of slider drags cancels the
        // previous task before it finishes.
        .task(id: document.editState) {
            // Debounce: a detached task does not inherit cancellation, so without this every frame of a slider drag
            // would queue a render that finishes (and is discarded) anyway.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            guard let source = document.currentImage else { tint = nil; return }
            let state = document.editState
            let id = maskID, build = preview, tintColor = color
            let image = await Task.detached(priority: .userInitiated) { Self.render(state: state, maskID: id, source: source, preview: build, color: tintColor) }.value
            if !Task.isCancelled { tint = image }
        }
    }

    /// Red where the mask selects (premultiplied alpha = coverage), transparent elsewhere. nil when nothing is selected.
    nonisolated private static func render(state: EditState, maskID: UUID, source: CIImage, preview: @Sendable (EditState, UUID, CIImage) -> CIImage?, color: CIColor) -> CGImage? {
        guard let mask = preview(state, maskID, source) else { return nil }
        let extent = mask.extent
        guard extent.width > 0, extent.height > 0, !extent.isInfinite else { return nil }
        let scale = min(1, maxSide / max(extent.width, extent.height))
        let small = mask
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = CGRect(x: 0, y: 0, width: (extent.width * scale).rounded(), height: (extent.height * scale).rounded())
        let red = CIImage(color: color).cropped(to: rect)
        let blend = CIFilter(name: "CIBlendWithAlphaMask")
        blend?.setValue(red, forKey: kCIInputImageKey)
        blend?.setValue(CIImage(color: .clear).cropped(to: rect), forKey: kCIInputBackgroundImageKey)
        blend?.setValue(small.cropped(to: rect), forKey: kCIInputMaskImageKey)
        guard let tinted = blend?.outputImage else { return nil }
        return context.createCGImage(tinted, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
