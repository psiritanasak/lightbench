import Foundation

/// The Editor tools whose finished-but-not-applied outcomes are reported through `ImageDocumentModel.postedFeedback`.
enum EditorFeedbackTool: Equatable, CaseIterable {
    case autoStraighten, upright, autoCrop, spotRemoval, subjectMask, depthMask

    /// Today's alert titles (byte-identical to the alerts these results used to open).
    var title: String {
        switch self {
        case .autoStraighten: return "Auto Straighten"
        case .upright: return "Upright"
        case .autoCrop: return "Auto Crop"
        case .spotRemoval: return "Spot Removal"
        case .subjectMask: return "Subject Mask"
        case .depthMask: return "Depth Range Mask"
        }
    }
}

/// Classifies one Editor result message. A result that says the photo is ALREADY in the requested state is a passing toast
/// (`.nothingToDo`); everything else (no horizon, failures, refusals, stale results) means what the user asked for was NOT applied, so it is
/// an alert (`.error`). The "already" texts are compared with the solvers' own constants, never copies of the strings.
enum EditorFeedback {
    static func feedback(_ tool: EditorFeedbackTool, _ message: String) -> Feedback {
        Feedback(kind: kind(tool, message), title: tool.title, message: message)
    }

    static func kind(_ tool: EditorFeedbackTool, _ message: String) -> FeedbackKind {
        let nothingToDo: [String]
        switch tool {
        case .autoStraighten: nothingToDo = [StraightenMessages.alreadyLevel, StraightenMessages.alreadyApplied]
        case .upright: nothingToDo = [UprightMessages.alreadyUpright, UprightMessages.alreadyApplied]
        case .autoCrop: nothingToDo = [AutoCropMessages.nothingToCrop, AutoCropMessages.alreadyApplied]
        case .spotRemoval, .subjectMask, .depthMask: nothingToDo = []
        }
        return nothingToDo.contains(message) ? .nothingToDo : .error
    }
}
