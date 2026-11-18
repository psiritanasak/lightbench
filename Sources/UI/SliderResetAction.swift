import SwiftUI

/// How an `EditSliderRow` performs its reset: through the open photo's model as ONE labelled undo step. The default (`.plain`, used
/// by previews and tests with no injected model) just runs the write, which is what the row did before this existed.
struct SliderResetAction: Sendable {
    let perform: @MainActor @Sendable (_ summary: String, _ write: () -> Void) -> Void

    static let plain = SliderResetAction { _, write in write() }
}

private struct SliderResetActionKey: EnvironmentKey {
    static let defaultValue = SliderResetAction.plain
}

extension EnvironmentValues {
    var sliderResetAction: SliderResetAction {
        get { self[SliderResetActionKey.self] }
        set { self[SliderResetActionKey.self] = newValue }
    }
}

extension View {
    /// Every `EditSliderRow` below resets through `document.performLabelledEdit`. Injected once on the Edit panel's content.
    func editSliderResets(_ document: ImageDocumentModel) -> some View {
        environment(\.sliderResetAction, SliderResetAction { summary, write in
            document.performLabelledEdit(summary, write)
        })
    }
}
