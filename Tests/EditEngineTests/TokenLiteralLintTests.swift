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

    /// The patterns really catch the raw forms and let the token forms through (a broken regex would otherwise pass silently).
    func testThePatternsCatchRawLiteralsAndAllowTokens() {
        func hits(_ line: String) -> Bool {
            Self.banned.contains { line.range(of: $0.1, options: .regularExpression) != nil }
        }
        for raw in [".padding(8)", ".padding(.horizontal, 8)", "HStack(spacing: 6) {", "RoundedRectangle(cornerRadius: 6)",
                    ".font(.system(size: 9))", ".padding(.vertical, compact ? 3 : 5)", "LazyVStack(alignment: .leading, spacing: 1)"] {
            XCTAssertTrue(hits(raw), "should be banned: \(raw)")
        }
        for fine in ["VStack(spacing: 0) {", ".padding(Theme.Space.s)", ".padding(.horizontal, Theme.Space.m)", "cornerRadius: Theme.Radius.m",
                     ".font(Theme.Font.micro(.semibold))", "HStack(spacing: Theme.Space.xs) {"] {
            XCTAssertFalse(hits(fine), "should be allowed: \(fine)")
        }
    }
}
