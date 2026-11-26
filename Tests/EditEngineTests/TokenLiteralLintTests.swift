import XCTest
@testable import PhotoApp

/// C3: the UI sources take spacing, corner radii and type sizes from `Theme.Space` / `Theme.Radius` / `Theme.Font` (or a named
/// `Theme.Metrics` value) instead of raw numbers, so a retune is one edit. This guard bans the raw forms outside a short allow-list.
/// `spacing: 0` (no gap) is legitimate and allowed.
final class TokenLiteralLintTests: XCTestCase {
    /// Files that may keep raw numbers, each for a reason. Keep this short.
    private static let allowList: [String: String] = [
        "Theme.swift": "defines the tokens",
        "ThinSlider.swift": "slider geometry (focus ring outset, track metrics)",
        "ToneCurveEditorView.swift": "curve editor geometry",
        "HistogramView.swift": "histogram geometry",
        "FlatButtonStyle.swift": "the button style owns its own metrics",
        "StylePadGeometry.swift": "style-pad geometry",
        // TODO(C3 part 2): the Edit-panel tool files were being rebuilt by B5 while part 1 ran; sweep them and delete these entries.
        "AdjustTabView.swift": "TODO(C3 part 2)",
        "CropTabView.swift": "TODO(C3 part 2)",
        "LooksTabView.swift": "TODO(C3 part 2)",
        "StyleSectionView.swift": "TODO(C3 part 2)",
        "MaskDetailView.swift": "TODO(C3 part 2)",
        "EditorToolRail.swift": "TODO(C3 part 2)",
    ]

    /// (what to report, pattern) — applied to each line with its `//` comment removed.
    private static let banned: [(String, String)] = [
        ("a raw `.font(.system(size:` — use Theme.Font", #"\.font\(\.system\(size:"#),
        ("a raw `cornerRadius:` number — use Theme.Radius", #"cornerRadius: *-?\d"#),
        ("a raw `.padding(<number>)` — use Theme.Space", #"\.padding\((?:[^()]*,\s*)?-?\d"#),
        ("a raw number in a `.padding(… ? n : n)` — use Theme.Space", #"\.padding\([^()]*\?\s*\d"#),
        ("a raw non-zero `spacing:` number — use Theme.Space (`spacing: 0` is fine)", #"[sS]pacing: *(?:[1-9]|0\.\d)"#),
    ]

    func testUISourcesUseTokensNotRawNumbers() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "found the UI sources")
        for file in files where Self.allowList[file.lastPathComponent] == nil {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                for (what, pattern) in Self.banned where code.range(of: pattern, options: .regularExpression) != nil {
                    XCTFail("\(file.lastPathComponent):\(number + 1) has \(what)")
                }
            }
        }
    }

    /// The allow-list cannot rot: every entry names a file that still exists.
    func testEveryAllowListEntryExists() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI")
        for name in Self.allowList.keys {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sources.appendingPathComponent(name).path), "\(name) is allow-listed but missing")
        }
    }
}
