import SwiftUI

/// When a "Targeted" button is usable, and what its tooltip says. Pure so each term is testable on its own.
enum TargetedAdjustmentRules {
    struct Availability: Equatable {
        var isEnabled: Bool
        var help: String
    }

    static let geometryHelp = "Reset crop, straighten, perspective, scale and flip first: the pixel under the cursor can only be matched to the "
        + "control exactly while the photo is not transformed."

    /// `isArmed` keeps the button live even when the photo has since become transformed (Undo can bring geometry back), because the
    /// button is then the way to stop.
    static func availability(
        tool: TargetedTool, hasImage: Bool, geometryAtIdentity: Bool, isArmed: Bool
    ) -> Availability {
        if isArmed { return Availability(isEnabled: true, help: "Stop the targeted adjustment tool (Esc).") }
        guard hasImage else { return Availability(isEnabled: false, help: "Open a photo to use the targeted adjustment tool.") }
        guard geometryAtIdentity else { return Availability(isEnabled: false, help: geometryHelp) }
        return Availability(isEnabled: true, help: instruction(for: tool))
    }

    /// Whether the section holding the armed tool's button is expanded (its Stop button is hidden otherwise). `true` for no tool.
    static func sectionIsOpen(tool: TargetedTool?, curveExpanded: Bool, selectiveColorExpanded: Bool, blackAndWhiteExpanded: Bool) -> Bool {
        switch tool {
        case .none: return true
        case .curve?: return curveExpanded
        case .selectiveColor?: return selectiveColorExpanded
        case .grayMix?: return blackAndWhiteExpanded
        }
    }

    /// What dragging does, per tool.
    static func instruction(for tool: TargetedTool) -> String {
        switch tool {
        case .curve:
            return "Drag up or down on the photo to move the curve at that tone. Esc stops."
        case .selectiveColor(let property):
            return "Drag up or down on a colour in the photo to change its \(property.label.lowercased()). Esc stops."
        case .grayMix:
            return "Drag up or down on a colour in the photo to lighten or darken it in the black and white mix. Esc stops."
        }
    }
}

/// The Adjust tab's "Targeted" button: arms (or disarms) `EditorInteractionMode.targeted(tool)`. One shared view so the three
/// sections word, enable and expose it identically.
struct TargetedAdjustmentButton: View {
    let tool: TargetedTool
    let hasImage: Bool
    let geometryAtIdentity: Bool
    @Binding var interactionMode: EditorInteractionMode
    /// The same callback every point tool uses on arming: leaves Compare, resets zoom/pan and takes image-pane focus.
    let onEnter: () -> Void

    var body: some View {
        let armed = interactionMode == .targeted(tool)
        let availability = TargetedAdjustmentRules.availability(
            tool: tool, hasImage: hasImage, geometryAtIdentity: geometryAtIdentity, isArmed: armed)
        Button {
            interactionMode.toggle(.targeted(tool))
            if interactionMode == .targeted(tool) { onEnter() }
        } label: {
            Label(armed ? "Stop Targeted Tool" : "Targeted", systemImage: "scope").frame(maxWidth: .infinity)
        }
        .buttonStyle(FlatButtonStyle(isOn: armed))
        .disabled(!availability.isEnabled)
        .help(availability.help)
        .accessibilityHint(availability.help)
        .accessibilityAddTraits(armed ? [.isSelected] : [])
        if armed {
            Text(TargetedAdjustmentRules.instruction(for: tool))
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}
