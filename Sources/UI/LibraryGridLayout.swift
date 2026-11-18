import Foundation

/// The Library grid's layout choice, stored in `UserDefaults` under ONE key that the grid, its bottom bar and the View menu all use.
enum LibraryGridLayout {
    static let storageKey = "PhotoApp.libraryGridLayout"
    static let square = "square"
    static let justified = "justified"
}
