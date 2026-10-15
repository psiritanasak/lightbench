import AppKit
import SwiftUI

/// The standard About panel's credits text: what the app is, the promise that matters, and a link to the bundled licence notices.
enum AboutPanelContent {
    static let notices = "ThirdPartyNotices"

    /// The bundled notices file (nil outside an app bundle, e.g. in a unit test host without the resource).
    static func noticesURL(in bundle: Bundle = .main) -> URL? { bundle.url(forResource: notices, withExtension: "md") }

    static func credits(noticesURL: URL?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor.withAlphaComponent(0.6), .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(
            string: "A non-destructive photo editor and library for the Mac. Your original files are never modified and nothing is uploaded.\n\n"
                + "Includes GRDB (MIT) and, optionally, Depth Anything V2 Small (Apache-2.0).\n",
            attributes: base)
        var link = base
        if let noticesURL { link[.link] = noticesURL }
        text.append(NSAttributedString(string: "Third-party licences", attributes: link))
        return text
    }

    @MainActor
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits(noticesURL: noticesURL())])
    }
}

/// The app-info and Help menu items. Help has no online manual to open, so it offers what exists: the shortcut list and the licences.
struct AboutAndHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppInfo.name)") { AboutPanelContent.show() }
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: Self.shortcutsWindowID) }
                .keyboardShortcut("/", modifiers: .command)
            Button("Third-Party Licences") {
                if let url = AboutPanelContent.noticesURL() { NSWorkspace.shared.open(url) }
            }
            .disabled(AboutPanelContent.noticesURL() == nil)
        }
    }

    static let shortcutsWindowID = "keyboard-shortcuts"
}
