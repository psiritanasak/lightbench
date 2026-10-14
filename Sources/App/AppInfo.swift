import Foundation

/// The app's user-facing name, read from the bundle (`CFBundleDisplayName`, set in project.yml) so text shown to people — folder-access
/// prompts, the window-title fallback — follows the product name instead of repeating a hard-coded one. The internal names (module,
/// bundle identifier, `PhotoAppApp`) are deliberately unchanged: the bundle identifier owns the user's sandbox container.
enum AppInfo {
    static let name: String = {
        let dict = Bundle.main.infoDictionary
        return (dict?["CFBundleDisplayName"] as? String) ?? (dict?["CFBundleName"] as? String) ?? "PhotoApp"
    }()
}
