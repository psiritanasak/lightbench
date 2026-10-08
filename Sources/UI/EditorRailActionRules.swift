import Foundation

/// When each Editor rail action is available. These are the SAME expressions the top toolbar used before the actions moved into the
/// rail, moved here verbatim so each term can be tested on its own. Pure: callers pass the facts.
enum EditorRailActionRules {
    /// Revert to Original. `isEffectivelyIdentity`, not `== .identity`: a RAW photo's `rawDecoderVersionPin` is invisible bookkeeping
    /// set on every open, not a user edit (see `EditState.isEffectivelyIdentity`).
    static func canRevert(hasImage: Bool, isEffectivelyIdentity: Bool) -> Bool {
        hasImage && !isEffectivelyIdentity
    }

    /// Enhance is blocked while a photo load, another enhance, or a batch rename is in flight (a second click must not start a second
    /// one on top of it).
    static func canEnhance(hasImage: Bool, isLoadInFlight: Bool, isEnhancing: Bool, isRenameWorking: Bool) -> Bool {
        hasImage && !isLoadInFlight && !isEnhancing && !isRenameWorking
    }

    /// Compare is off the Crop tab and while any point-interaction mode is armed (the one-at-a-time invariant the WB / red-eye buttons
    /// keep too). Brush painting and mask editing are deliberately NOT here: masks stay applied and Compare is the way to see them.
    struct ArmedModes: Equatable {
        var whiteBalance = false
        var redEye = false
        var colorRange = false
        var pointColor = false
        var subject = false
        var retouchSpot = false

        var any: Bool { whiteBalance || redEye || colorRange || pointColor || subject || retouchSpot }
    }

    static func canCompare(hasImage: Bool, isCropping: Bool, armed: ArmedModes) -> Bool {
        hasImage && !isCropping && !armed.any
    }

    /// History needs an open photo.
    static func canShowHistory(hasImage: Bool) -> Bool { hasImage }
}
