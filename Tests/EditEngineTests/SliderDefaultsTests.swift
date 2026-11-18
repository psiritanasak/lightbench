import XCTest
@testable import PhotoApp

/// Every `EditSliderRow`'s `identity:` must equal its data default, or the reset icon / double-click would "reset" to a value
/// that is not the default. A source parse over the call sites whose binding names a field directly.
final class SliderDefaultsTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func doubleField(_ name: String, of value: Any) -> Double? {
        Mirror(reflecting: value).children.first { $0.label == name }?.value as? Double
    }

    /// Returns (matches, mismatches, unresolved field names).
    private func check(files: [String], pattern: String, defaults: Any) throws -> (Int, [String], [String]) {
        let regex = try NSRegularExpression(pattern: pattern)
        var count = 0
        var mismatches: [String] = []
        var unresolved: [String] = []
        for file in files {
            let text = try source(file)
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let f = Range(match.range(at: 1), in: text), let i = Range(match.range(at: 2), in: text),
                      let identity = Double(text[i]) else { continue }
                count += 1
                let field = String(text[f])
                guard let dflt = doubleField(field, of: defaults) else { unresolved.append("\(file):\(field)"); continue }
                if dflt != identity { mismatches.append("\(file):\(field) identity \(identity) default \(dflt)") }
            }
        }
        return (count, mismatches, unresolved)
    }

    func testEditStateSliderIdentitiesMatchTheirDefaults() throws {
        let (count, mismatches, unresolved) = try check(
            files: ["Sources/UI/AdjustTabView.swift", "Sources/UI/CropTabView.swift"],
            pattern: #"value: \$document\.editState\.(\w+),\s*range: [^,]+, identity: ([-0-9.]+)"#,
            defaults: EditState())
        XCTAssertGreaterThanOrEqual(count, 54, "the parse must keep finding the rows")
        XCTAssertEqual(mismatches, [])
        XCTAssertEqual(unresolved, [])
    }

    func testMaskSliderIdentitiesMatchTheirDefaults() throws {
        let (count, mismatches, unresolved) = try check(
            files: ["Sources/UI/MaskDetailView.swift"],
            pattern: #"value: \$mask\.(\w+),\s*range: [^,]+, identity: ([-0-9.]+)"#,
            defaults: Mask())
        XCTAssertGreaterThanOrEqual(count, 19)
        XCTAssertEqual(mismatches, [])
        XCTAssertEqual(unresolved, [])
    }

    func testPointColorSliderIdentitiesMatchTheirDefaults() throws {
        let (count, mismatches, unresolved) = try check(
            files: ["Sources/UI/PointColorDetailView.swift"],
            pattern: #"value: \$pointColor\.(\w+),\s*range: [^,]+, identity: ([-0-9.]+)"#,
            defaults: PointColor())
        XCTAssertGreaterThanOrEqual(count, 4)
        XCTAssertEqual(mismatches, [])
        XCTAssertEqual(unresolved, [])
    }
}
