import Foundation

/// What to do with a set of URLs that arrived by drag-and-drop or from Finder / the Dock ("Open With").
///
/// Pure decision logic: no UI, no database. A dropped FOLDER is imported (as a nested tree when any subfolder holds photos, otherwise flat);
/// a dropped PHOTO opens in the Editor (the same as `Open…`); anything else is ignored. Several photos open only the first — importing a
/// loose file would need a folder grant the drop does not give — and the rest are counted so the message can suggest dropping the folder.
struct DroppedItemsPlan: Equatable, Sendable {
    struct FolderImport: Equatable, Sendable {
        var url: URL
        var asTree: Bool
    }

    var folders: [FolderImport] = []
    /// The photo to open in the Editor, if any file was a supported image.
    var photoToOpen: URL?
    /// Supported images beyond the first one, which are not opened.
    var skippedPhotoCount = 0
    /// Folders with no photos anywhere inside them.
    var emptyFolders: [URL] = []
    /// Items that were neither a folder nor a supported image.
    var ignoredCount = 0
    /// Packages (a Photos library, an app bundle): never imported from the inside.
    var packages: [URL] = []

    var isEmpty: Bool { folders.isEmpty && photoToOpen == nil && emptyFolders.isEmpty && packages.isEmpty }
}

enum DroppedItems {
    /// Classifies `urls` in the order given. Reads the file system (blocking), so call it off the main thread for large folders.
    static func classify(_ urls: [URL]) -> DroppedItemsPlan {
        var plan = DroppedItemsPlan()
        var seen = Set<String>()
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isPackage == true {
                // A package (Photos library, app bundle, …) is not a folder of photos: importing its insides would mirror its private layout.
                plan.packages.append(url)
            } else if values?.isDirectory ?? false {
                guard let node = PhotoImporter.scanFolderTree(at: url) else {
                    plan.emptyFolders.append(url)
                    continue
                }
                plan.folders.append(.init(url: url, asTree: !node.children.isEmpty))
            } else if PhotoImporter.isSupportedImage(url) {
                if plan.photoToOpen == nil { plan.photoToOpen = url } else { plan.skippedPhotoCount += 1 }
            } else {
                plan.ignoredCount += 1
            }
        }
        // A folder dropped together with one of its own subfolders is imported once (the tree import already covers the subfolder).
        let roots = plan.folders.map { $0.url.standardizedFileURL.path }
        plan.folders.removeAll { folder in
            let path = folder.url.standardizedFileURL.path
            return roots.contains { $0 != path && path.hasPrefix($0 + "/") }
        }
        return plan
    }

    /// The message for whatever the plan leaves out (nil when nothing was left out).
    static func leftOutMessage(for plan: DroppedItemsPlan) -> String? {
        var parts: [String] = []
        if plan.skippedPhotoCount > 0 {
            let n = plan.skippedPhotoCount
            parts.append("Opened one photo; \(n) other photo\(n == 1 ? " was" : "s were") not opened. To add several photos to the Library, drop their folder.")
        }
        if !plan.emptyFolders.isEmpty {
            let names = plan.emptyFolders.map { "\"\($0.lastPathComponent)\"" }.joined(separator: ", ")
            parts.append("No photos found in \(names).")
        }
        if !plan.packages.isEmpty {
            let names = plan.packages.map { "\"\($0.lastPathComponent)\"" }.joined(separator: ", ")
            parts.append("\(names) \(plan.packages.count == 1 ? "is a package, not a folder" : "are packages, not folders") — the contents were not imported. Choose a folder of photos instead.")
        }
        if plan.ignoredCount > 0, plan.isEmpty, plan.packages.isEmpty {
            parts.append("Nothing to open: Lightbench opens photos and folders of photos.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Why a drop / Finder open is refused right now, mirroring what the menus disable (nil = go ahead).
    static func refusal(renameWorking: Bool, renameInProgress: Bool, culling: Bool, loadInFlight: Bool, toolSheetBusy: Bool) -> String? {
        if culling { return "Finish culling first (press Esc), then try again." }
        if renameWorking || renameInProgress { return "A rename is in progress. Try again when it finishes." }
        if loadInFlight { return "A photo is still loading. Try again in a moment." }
        if toolSheetBusy { return "Close the open sheet or wait for the running task, then try again." }
        return nil
    }
}
