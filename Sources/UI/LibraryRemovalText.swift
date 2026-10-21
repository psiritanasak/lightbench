import Foundation

/// The wording of the Library's "Remove from Library?" confirmation, which must say what a master's removal takes with it.
enum LibraryRemovalText {
    /// The copies that go with `photo` when it is removed, read through `loading` (the database); `nil` when they could not be counted,
    /// in which case the dialog must not be shown with a number that may be too small.
    @MainActor static func copyCount(for photo: Photo, loading: () async throws -> [Int64: [Photo]]) async -> Int? {
        if photo.isVirtualCopy { return 0 }
        guard let all = try? await loading() else { return nil }
        return all[photo.id ?? -1]?.count ?? 0
    }

    static func message(for photo: Photo, copyCount: Int) -> String {
        let name = photo.versionName.map { "\(photo.filename) · \($0)" } ?? photo.filename
        if photo.isVirtualCopy {
            return "\"\(name)\" will be removed from the Library. The photo file is not affected, and the copy's edit file is left next to the photo."
        }
        var text = "\"\(name)\" will be removed from the Library. The original file on disk is not affected."
        if copyCount > 0 {
            text += " Its \(copyCount) virtual cop\(copyCount == 1 ? "y" : "ies") will be removed from the Library too; their edit files are left next to the photo."
        }
        return text
    }
}
