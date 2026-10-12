import Foundation

/// Which depth source a Depth Range mask should be generated from, given what the user asked for and what exists. Pure, so the UI text and the
/// generator's choice cannot drift apart (docs/ROADMAP_HISTORY.md "Depth Range spike": embedded iPhone depth is a real stereo measurement, best for
/// close portraits and unreliable beyond a few metres; the bundled model works on any photo and is better for distant scenes).
enum DepthSourceResolver {
    enum Preference: String, CaseIterable, Equatable {
        /// Embedded depth when the photo has it, otherwise the model.
        case automatic
        case embedded
        case model
    }

    enum Source: Equatable {
        case embedded
        case model
    }

    enum Resolution: Equatable {
        case use(Source)
        /// Why nothing can be generated, as a sentence for the user.
        case unavailable(String)
    }

    static let noDepthAnywhere = "This photo has no depth data, and the depth model is not installed (run scripts/fetch_depth_model.sh, then rebuild)."
    static let noEmbedded = "This photo has no embedded iPhone depth. Choose the depth model instead."
    static let noModel = "The depth model is not installed (run scripts/fetch_depth_model.sh, then rebuild)."

    static func resolve(_ preference: Preference, embeddedAvailable: Bool, modelAvailable: Bool) -> Resolution {
        switch preference {
        case .embedded:
            return embeddedAvailable ? .use(.embedded) : .unavailable(noEmbedded)
        case .model:
            return modelAvailable ? .use(.model) : .unavailable(noModel)
        case .automatic:
            if embeddedAvailable { return .use(.embedded) }
            return modelAvailable ? .use(.model) : .unavailable(noDepthAnywhere)
        }
    }

    /// The preference a Regenerate should use: the source the mask already has, so regenerating does not silently switch sources.
    static func preference(forTag tag: String) -> Preference {
        if DepthSourceTag.isEmbedded(tag) { return .embedded }
        if DepthSourceTag.isModel(tag) { return .model }
        return .automatic
    }
}
