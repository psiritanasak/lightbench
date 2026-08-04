import Foundation

/// The top-level editing tool, matching Apple Photos' own tab bar
/// (Adjust/Filters/Crop/Clean Up). `.filters` and `.cleanUp` are inert
/// placeholders — selectable so their existence is visible, matching the
/// reference, but neither has any built functionality yet.
enum EditorTab: CaseIterable {
    case adjust, filters, crop, cleanUp

    var label: String {
        switch self {
        case .adjust: return "Adjust"
        case .filters: return "Filters"
        case .crop: return "Crop"
        case .cleanUp: return "Clean Up"
        }
    }
}
