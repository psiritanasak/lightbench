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

    // MARK: - Tool rail

    /// The tabs the right-hand tool rail shows, top to bottom. `.cleanUp` is an inert placeholder with nothing to show, so it has
    /// no rail entry (the case stays so existing switch statements keep compiling).
    static let railTabs: [EditorTab] = [.adjust, .looks, .crop]

    /// The rail's caption ("Edit" for Adjust, as the rail names its tools by what you do).
    var railTitle: String {
        switch self {
        case .adjust: return "Edit"
        case .looks: return "Looks"
        case .crop: return "Crop"
        case .cleanUp: return "Clean Up"
        }
    }

    /// The rail's SF Symbol.
    var railSymbol: String {
        switch self {
        case .adjust: return "slider.horizontal.3"
        case .looks: return "camera.filters"
        case .crop: return "crop"
        case .cleanUp: return "sparkles"
        }
    }
}
