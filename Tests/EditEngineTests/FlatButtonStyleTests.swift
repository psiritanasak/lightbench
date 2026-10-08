import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

@MainActor
final class FlatButtonStyleTests: XCTestCase {
    // MARK: Pure colour rules

    func testFillAndOutlineRules() {
        XCTAssertEqual(FlatButtonStyle.fill(isOn: false, prominent: false, pressed: false), Theme.raised)
        XCTAssertEqual(FlatButtonStyle.fill(isOn: false, prominent: false, pressed: true), Color(white: 0.23))
        XCTAssertEqual(FlatButtonStyle.fill(isOn: true, prominent: false, pressed: false), Theme.accent.opacity(0.22))
        XCTAssertEqual(FlatButtonStyle.fill(isOn: false, prominent: true, pressed: false), Theme.accent)
        XCTAssertEqual(FlatButtonStyle.fill(isOn: true, prominent: true, pressed: false), Theme.accent, "prominent wins over on")
        XCTAssertEqual(FlatButtonStyle.outline(isOn: false, prominent: false), Theme.hairline)
        XCTAssertEqual(FlatButtonStyle.outline(isOn: true, prominent: false), Theme.accent)
        XCTAssertEqual(FlatButtonStyle.outline(isOn: false, prominent: true), Color.clear)
    }

    // MARK: Rendered

    private let size = CGSize(width: 160, height: 40)

    private func render<V: View>(_ content: V) -> NSBitmapImageRep {
        let view = content.environment(\.colorScheme, .dark).frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private func button(_ style: FlatButtonStyle, disabled: Bool = false) -> NSBitmapImageRep {
        render(Button("Reset Adjustments") {}.buttonStyle(style).disabled(disabled))
    }

    /// The chip fills the 160-pt frame (fullWidth); (6, 20) is inside it, left of the text.
    private func sample(_ rep: NSBitmapImageRep) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / size.width
        return try XCTUnwrap(rep.colorAt(x: Int(6 * scale), y: Int(20 * scale))?.usingColorSpace(.sRGB))
    }

    private func count(_ rep: NSBitmapImageRep, _ predicate: (NSColor) -> Bool) -> Int {
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5, predicate(c) { n += 1 }
            }
        }
        return n
    }

    func testANormalButtonIsTheRaisedGreyWithWhiteText() throws {
        let rep = button(FlatButtonStyle(fullWidth: true))
        let reference = render(Theme.raised)
        let got = try sample(rep), want = try sample(reference)
        XCTAssertEqual(got.redComponent, want.redComponent, accuracy: 0.015)
        XCTAssertEqual(got.blueComponent, want.blueComponent, accuracy: 0.015)
        XCTAssertGreaterThan(count(rep) { $0.redComponent > 0.85 && $0.greenComponent > 0.85 && $0.blueComponent > 0.85 }, 20, "white text")
        XCTAssertEqual(count(rep) { $0.blueComponent > 0.45 && $0.blueComponent > $0.redComponent + 0.25 }, 0, "no blue anywhere")
    }

    func testAnArmedButtonIsTintedWithTheAccent() throws {
        let normal = try sample(button(FlatButtonStyle(fullWidth: true)))
        let armed = try sample(button(FlatButtonStyle(isOn: true, fullWidth: true)))
        XCTAssertGreaterThan(armed.blueComponent - armed.redComponent, normal.blueComponent - normal.redComponent + 0.05,
                             "armed is bluer than normal")
    }

    func testAProminentButtonIsSolidAccentBlue() throws {
        let rep = button(FlatButtonStyle(prominent: true, fullWidth: true))
        let c = try sample(rep)
        XCTAssertGreaterThan(c.blueComponent, c.redComponent + 0.5)
        XCTAssertEqual(c.alphaComponent, 1, accuracy: 0.001)
        XCTAssertGreaterThan(count(rep) { $0.redComponent > 0.85 && $0.greenComponent > 0.85 && $0.blueComponent > 0.85 }, 20, "white text")
    }

    func testADisabledButtonIsDimmer() throws {
        let enabled = try sample(button(FlatButtonStyle(fullWidth: true)))
        let disabled = try sample(button(FlatButtonStyle(fullWidth: true), disabled: true))
        let a = enabled.redComponent * enabled.alphaComponent, b = disabled.redComponent * disabled.alphaComponent
        XCTAssertLessThan(b, a - 0.02, "the chip fades when disabled")
    }

    // MARK: No system bordered styles left

    func testNoSystemBorderedButtonStylesAreUsedInTheUISources() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                for word in [".buttonStyle(.bordered", ".buttonStyle(.borderedProminent"] where code.contains(word) {
                    XCTFail("\(file.lastPathComponent):\(number + 1) uses \(word) — use FlatButtonStyle")
                }
            }
        }
    }
}
