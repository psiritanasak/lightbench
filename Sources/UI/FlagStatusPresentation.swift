import SwiftUI

/// Presentation-only helpers for `FlagStatus` (the enum itself lives in the
/// Catalog module, which has no UI imports).
extension FlagStatus {
    /// What a click on the cell's single flag icon (or `.`/`f`) does:
    /// unflagged becomes Picked; Picked and Rejected both clear back to
    /// unflagged.
    var toggledPick: FlagStatus {
        self == .none ? .picked : .none
    }

    var symbolName: String {
        switch self {
        case .picked: return "flag.fill"
        case .rejected: return "xmark.circle.fill"
        case .none: return "flag"
        }
    }

    var tint: Color {
        switch self {
        case .picked: return Theme.markOn
        case .rejected: return .red
        case .none: return Theme.textSecondary
        }
    }

    var accessibilityValue: String {
        switch self {
        case .picked: return "Picked"
        case .rejected: return "Rejected"
        case .none: return "Unflagged"
        }
    }

    var menuTitle: String {
        switch self {
        case .picked: return "Pick"
        case .rejected: return "Reject"
        case .none: return "Unflag"
        }
    }

    static let menuOrder: [FlagStatus] = [.picked, .rejected, .none]
}
