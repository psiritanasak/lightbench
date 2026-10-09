import AppKit
import SwiftUI

/// A small coloured dot for a colour label, shown beside the Label filter's options. (Not in the grid cell's per-photo label menu: a menu
/// item keeps only its first image, so a swatch there could displace the checkmark that marks the current label — unverified, so left out.) A pre-rendered
/// NON-template `NSImage`: AppKit draws menu-item images as monochrome templates unless told otherwise, and a SwiftUI `foregroundStyle` on
/// the symbol is not guaranteed to survive that (menu colours are AppKit-drawn, so this is a live check — see PROGRESS.md).
enum LabelSwatch {
    static let diameter: CGFloat = 10

    static func image(for label: ColorLabel) -> NSImage? {
        guard label != .none else { return nil }
        let color = NSColor(label.color)
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension LibraryLabelFilter {
    /// The colour label this filter option stands for (`nil` for "All Labels" and "No Label": they have no colour).
    var colorLabel: ColorLabel? {
        switch self {
        case .all, .unlabeled: return nil
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}
