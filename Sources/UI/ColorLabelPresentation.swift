import SwiftUI

/// Presentation-only helpers for `ColorLabel` (the enum itself lives in the
/// Catalog module, which has no UI imports).
extension ColorLabel {
    var color: Color {
        switch self {
        case .none: return .clear
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }

    var menuTitle: String {
        switch self {
        case .none: return "No Label"
        case .red: return "Red"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }

    /// Spoken/accessibility name of the label itself ("Red label").
    var accessibilityName: String {
        self == .none ? "No label" : "\(menuTitle) label"
    }

    /// Lightroom's 6-9 shortcuts; purple is menu-only.
    static func forKey(_ character: Character) -> ColorLabel? {
        switch character {
        case "6": return .red
        case "7": return .yellow
        case "8": return .green
        case "9": return .blue
        default: return nil
        }
    }

    /// Applying the label a photo already has clears it (a keyboard toggle).
    func toggled(to target: ColorLabel) -> ColorLabel {
        self == target ? .none : target
    }

    static let menuOrder: [ColorLabel] = [.none, .red, .yellow, .green, .blue, .purple]
}
