import Foundation

/// The top-level editing tool. The tab bar started as a mirror of Apple Photos' (Adjust/Filters/Crop/Clean Up); `.looks` takes
/// the Filters slot — it holds the "pick a starting point" controls (Looks, Style, Presets) — and `.cleanUp` stays an inert
/// placeholder, selectable so its existence is visible but with no built functionality yet.
enum EditorTab: CaseIterable {
    case adjust, looks, crop, cleanUp

    var label: String {
        switch self {
        case .adjust: return "Adjust"
        case .looks: return "Looks"
        case .crop: return "Crop"
        case .cleanUp: return "Clean Up"
        }
    }

    /// Whether Compare mode and the zoom/pan state survive switching TO this tab. Adjust and Looks both show the live image, and
    /// before/after is wanted while browsing looks; Crop changes the frame and Clean Up has nothing built, so they reset both.
    var keepsCompareAndZoom: Bool { self == .adjust || self == .looks }

    /// Whether switching TO this tab disarms the point-interaction modes (white-balance/red-eye/brush/colour-picking) and clears
    /// the mask / Point Color / retouch selections. Only Adjust has controls for those, so every other tab disarms them —
    /// otherwise their overlays would stay live on a tab with no way to turn them off.
    var disarmsPointModes: Bool { self != .adjust }
}
