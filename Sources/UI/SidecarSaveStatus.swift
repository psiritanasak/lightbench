import Foundation

/// Whether the open photo's edits are reaching their sidecar file. Published by `ImageDocumentModel.sidecarSaveStatus`; anything
/// other than `.ok` means the edits on screen live only in memory. Unlike the once-per-load alert, this stays until the problem is
/// gone.
enum SidecarSaveStatus: Equatable {
    case ok
    /// D81: the photo already has an edit file this Editor session did not load (written behind its back).
    case refusedNotLoaded
    /// D81: the photo's edit file exists but cannot be read, so it is never overwritten.
    case refusedUnreadable
    /// The user cancelled the folder-access panel this session.
    case folderDeclined
    /// The write itself failed (the message is the system's reason).
    case writeFailed(String)
}

/// What the Editor bar shows for a `SidecarSaveStatus`: the chip's title, its tooltip and the one action it offers. Pure.
struct SidecarSaveStatusPresentation: Equatable {
    enum Action: Equatable {
        case reload, showInFinder, grantAccess, tryAgain

        /// Reload throws away the edits made since the photo was opened, so it is confirmed first.
        var discardsEdits: Bool { self == .reload }
    }

    let title: String
    let help: String
    let action: Action
    let actionTitle: String

    /// nil when there is nothing to show (`.ok`).
    static func make(for status: SidecarSaveStatus, sidecarFileName: String) -> SidecarSaveStatusPresentation? {
        let title = "Edits not saved"
        switch status {
        case .ok:
            return nil
        case .refusedNotLoaded:
            return SidecarSaveStatusPresentation(
                title: title,
                help: "\(sidecarFileName) changed on disk after this photo was opened, so it was left untouched. "
                    + "Reload to bring in the saved edits (edits made since opening are discarded).",
                action: .reload, actionTitle: "Reload")
        case .refusedUnreadable:
            return SidecarSaveStatusPresentation(
                title: title,
                help: "\(sidecarFileName) can't be read, so it was left untouched and your edits are not being saved. "
                    + "Fix or remove it, then reopen the photo.",
                action: .showInFinder, actionTitle: "Show in Finder")
        case .folderDeclined:
            return SidecarSaveStatusPresentation(
                title: title,
                help: "You declined access to this photo's folder, so edits to this photo aren't being saved (any you make stay in memory only). "
                    + "Grant access to the folder to save them.",
                action: .grantAccess, actionTitle: "Grant Access…")
        case .writeFailed(let reason):
            return SidecarSaveStatusPresentation(
                title: title,
                help: "Saving \(sidecarFileName) failed (\(reason)). Your edits are only kept in memory until it succeeds.",
                action: .tryAgain, actionTitle: "Try Again")
        }
    }
}
