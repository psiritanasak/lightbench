/// The top-level editing tool. The tab bar started as a mirror of Apple Photos' Adjust/Filters/Crop/Clean Up; `.looks` takes the
/// Filters slot — it holds the "pick a starting point" controls (Looks, Style, Presets) — and `.cleanUp` stays an inert placeholder.
/// `.retouch`, `.redEye` and `.masks` are the point tools that used to be sections of the Adjust scroll; each is its own rail entry.
enum EditorTab: CaseIterable {
    case adjust, looks, retouch, redEye, masks, crop, cleanUp

    var label: String {
        switch self {
        case .adjust: return "Adjust"
        case .looks: return "Looks"
        case .retouch: return "Retouch"
        case .redEye: return "Red-Eye"
        case .masks: return "Masks"
        case .crop: return "Crop"
        case .cleanUp: return "Clean Up"
        }
    }

    /// Whether Compare mode and the zoom/pan state survive switching TO this tab. Every tab that shows the live image keeps them
    /// (Retouch on purpose: spots are placed zoomed in; the point tools were Adjust sections, which kept both); Crop changes the frame
    /// and Clean Up has nothing built, so they reset both.
    var keepsCompareAndZoom: Bool { self != .crop && self != .cleanUp }

    // MARK: - Point-tool ownership

    /// What a switch TO this tab does to the point tools. Each tool belongs to ONE tab: an armed mode is disarmed, and a selection
    /// cleared, unless the destination tab owns it — otherwise its on-image overlay would stay live on a tab with no way to turn it
    /// off. (Before the split only Adjust owned any, so every other tab cleared them all.)
    struct SwitchEffects: Equatable {
        var disarmsMode: Bool
        var clearsMaskSelection: Bool
        var clearsPointColorSelection: Bool
        var clearsRetouchSelection: Bool
    }

    func switchEffects(armed mode: EditorInteractionMode) -> SwitchEffects {
        SwitchEffects(
            disarmsMode: mode.ownerTab.map { $0 != self } ?? false,
            clearsMaskSelection: self != .masks,
            clearsPointColorSelection: self != .adjust,
            clearsRetouchSelection: self != .retouch
        )
    }

    // MARK: - Tool rail

    /// The tabs the right-hand tool rail shows, top to bottom. `.cleanUp` is an inert placeholder with nothing to show, so it has
    /// no rail entry (the case stays so existing switch statements keep compiling).
    static let railTabs: [EditorTab] = [.adjust, .looks, .retouch, .redEye, .masks, .crop]

    /// The rail's caption ("Edit" for Adjust, as the rail names its tools by what you do).
    var railTitle: String {
        switch self {
        case .adjust: return "Edit"
        case .looks: return "Looks"
        case .retouch: return "Retouch"
        case .redEye: return "Red-eye"
        case .masks: return "Masks"
        case .crop: return "Crop"
        case .cleanUp: return "Clean Up"
        }
    }

    /// The rail's SF Symbol.
    var railSymbol: String {
        switch self {
        case .adjust: return "slider.horizontal.3"
        case .looks: return "camera.filters"
        case .retouch: return "bandage"
        case .redEye: return "eye"
        case .masks: return "circle.dashed"
        case .crop: return "crop"
        case .cleanUp: return "sparkles"
        }
    }
}
