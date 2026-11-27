import XCTest
@testable import PhotoApp

/// Source lint for the Editor's tool panels (slice B5): every panel group uses the one shared header (`AdjustSectionContainer`), and
/// no code in `Sources/UI` uses a system `DisclosureGroup` (its header toggles only from the chevron and cannot carry the edited dot).
final class ToolPanelsLintTests: XCTestCase {
    private var uiSources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI")
    }

    /// The file's code with each line's `//` comment removed (doc comments may still name the old type).
    private func code(of name: String) throws -> String {
        let text = try String(contentsOf: uiSources.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    func testNoUISourceUsesDisclosureGroup() throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: uiSources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "found the UI sources")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let stripped = line.components(separatedBy: "//").first ?? ""
                XCTAssertFalse(stripped.contains("DisclosureGroup"), "\(file.lastPathComponent):\(number + 1) uses DisclosureGroup — use AdjustSectionContainer")
            }
        }
    }

    func testEveryToolPanelGroupUsesTheSharedHeader() throws {
        for name in ["CropTabView.swift", "MaskDetailView.swift", "LooksTabView.swift"] {
            XCTAssertTrue(try code(of: name).contains("AdjustSectionContainer("), "\(name) groups its content with AdjustSectionContainer")
        }
        // The Masks tab's list and tiles sit under AdjustTabView's own tool header; its Edit-tab sections use the container too.
        XCTAssertTrue(try code(of: "AdjustTabView.swift").contains("AdjustSectionContainer("))
    }

    func testCropGroupsAreAllWiredToToolSections() throws {
        let crop = try code(of: "CropTabView.swift")
        for section in ["cropAuto", "cropStraighten", "cropRotate", "cropAspect", "cropInsets"] {
            XCTAssertTrue(crop.contains(".\(section))"), "Crop tab group \(section) has its open flag")
        }
        let detail = try code(of: "MaskDetailView.swift")
        for section in ["maskAdjustments", "maskShape", "maskCombine"] {
            XCTAssertTrue(detail.contains(".\(section))"), "Mask detail group \(section) has its open flag")
        }
    }

    func testToolSectionStateIsNotAnEditStateOrAdjustSection() throws {
        // UI-only: the groups' open flags must not become part of the persisted edit or of Reset Adjustments' section list.
        let section = try String(contentsOf: uiSources.deletingLastPathComponent().appendingPathComponent("EditEngine/AdjustSection.swift"), encoding: .utf8)
        XCTAssertFalse(section.contains("ToolSection"))
    }
}

/// The open state of the Masks / Crop groups is remembered across launches (`AppPreferences.toolPanelOpenSections`).
final class ToolSectionPersistenceTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suiteNames = []
    }

    /// A throwaway suite per test; never falls back to the developer's real defaults.
    private func makePreferences() throws -> AppPreferences {
        let name = "ToolSectionPersistenceTests-\(UUID().uuidString)"
        suiteNames.append(name)
        return AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
    }

    func testFirstRunHasEveryGroupOpen() throws {
        XCTAssertEqual(ToolSection.stored(try makePreferences()), Set(ToolSection.allCases))
    }

    func testTheOpenSetRoundTrips() throws {
        let preferences = try makePreferences()
        ToolSection.store(Set<ToolSection>([.cropAuto, .maskShape]), preferences)
        XCTAssertEqual(ToolSection.stored(preferences), Set<ToolSection>([.cropAuto, .maskShape]))
    }

    func testAllClosedIsRememberedAndNotTreatedAsFirstRun() throws {
        let preferences = try makePreferences()
        ToolSection.store(Set<ToolSection>(), preferences)
        XCTAssertEqual(ToolSection.stored(preferences), Set<ToolSection>())
    }

    func testUnknownNamesAreIgnored() throws {
        let preferences = try makePreferences()
        preferences.toolPanelOpenSections = ["cropAuto", "someFutureGroup"]
        XCTAssertEqual(ToolSection.stored(preferences), Set<ToolSection>([.cropAuto]))
    }
}
