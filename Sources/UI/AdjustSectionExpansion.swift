import Foundation

/// Which Edit-tab sections are open. Pure (no SwiftUI), like `TabMemory`.
///
/// First run (nothing stored) opens Light and Color; after that the stored set is used exactly, including "all closed".
struct AdjustSectionExpansion: Equatable, Sendable {
    static let firstRunOpen: Set<AdjustSection> = [.light, .color]

    private(set) var open: Set<AdjustSection>

    init(open: Set<AdjustSection> = AdjustSectionExpansion.firstRunOpen) {
        self.open = open
    }

    /// nil = never stored (first run) -> `firstRunOpen`. Otherwise exactly the stored names; unknown names are dropped; `[]` = all closed.
    init(stored: [String]?) {
        guard let stored else {
            self.open = Self.firstRunOpen
            return
        }
        self.open = Set(stored.compactMap { AdjustSection(rawValue: $0) })
    }

    /// Raw values in `AdjustSection.allCases` order (deterministic).
    var stored: [String] {
        AdjustSection.allCases.filter { open.contains($0) }.map(\.rawValue)
    }

    func isOpen(_ section: AdjustSection) -> Bool { open.contains(section) }

    mutating func set(_ section: AdjustSection, open isOpen: Bool) {
        if isOpen { open.insert(section) } else { open.remove(section) }
    }

    /// Opens `section` and closes every other one (RAW too, even when it is not shown). Idempotent.
    mutating func solo(_ section: AdjustSection) {
        open = [section]
    }
}
