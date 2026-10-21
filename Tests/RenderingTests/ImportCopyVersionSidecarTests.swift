import XCTest
@testable import PhotoApp

/// DECISION pinned (see the comment above `ImportCopyPlan`): Copy Photos never copies, moves or deletes a virtual copy's edit file
/// (`<file>.<versionKey>.photoapp.json`). Its edit-file companion is the master's `<file>.photoapp.json` only.
final class ImportCopyVersionSidecarTests: XCTestCase {
    private func code(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        // Comments legitimately talk about version files; only code counts.
        return text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    func testThePlanAndEngineNeverTouchVersionEditFiles() throws {
        for file in ["Sources/Rendering/ImportCopyPlan.swift", "Sources/Rendering/ImportCopyEngine.swift"] {
            let source = try code(file)
            for forbidden in ["versionKey", "versionedSidecarURL", "versionSidecarKeys", "versionSidecarURLs", "isVirtualCopy"] {
                XCTAssertFalse(source.contains(forbidden), "\(file) must not know about version edit files (\(forbidden)): Copy Photos leaves them behind")
            }
        }
    }

    func testTheEditFileCompanionIsOnlyTheMastersFile() throws {
        let source = try code("Sources/Rendering/ImportCopyPlan.swift")
        XCTAssertTrue(source.contains("add(.editFile, SidecarStore.sidecarURL(for: source))"))
        XCTAssertTrue(source.contains("case .editFile: return SidecarStore.sidecarURL(for: photo)"))
    }
}
