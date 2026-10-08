import SwiftUI

/// One cell of the Looks tab's grids: the photo with a Look or Style applied (or a neutral placeholder until its preview is
/// ready), the name underneath, a white ring when it is the current choice. Presentation only — the caller supplies the
/// image and the action (`selectLook` / `ImageDocumentModel.selectStyle`).
struct LookThumbnailCell: View {
    let name: String
    let image: CGImage?
    let isSelected: Bool
    /// VoiceOver label, e.g. "Look Warm Film" / "No look".
    let accessibilityText: String
    let action: () -> Void
    /// Present only for imported looks: offered in the context menu and as a VoiceOver action.
    var onRemove: (() -> Void)?

    /// Width : height of the preview area. Photos of any aspect are cropped to fill it (the preview itself already has the
    /// state's own crop applied).
    private static let aspect: CGFloat = 4.0 / 3.0

    var body: some View {
        let cell = Button(action: action) {
            VStack(spacing: 3) {
                Color.primary.opacity(0.08)
                    .aspectRatio(Self.aspect, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Theme.selectedOutline : Color.clear, lineWidth: 2))
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // Only imported looks can be removed: a built-in cell must not offer an empty menu or a do-nothing VoiceOver action.
        if let onRemove {
            cell
                .contextMenu { Button("Remove \(name)", role: .destructive, action: onRemove) }
                .accessibilityActions { Button("Remove", action: onRemove) }
        } else {
            cell
        }
    }
}
