import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// System controls drawn under the app's REAL root tint must contain no blue (a checked Toggle, a native Slider).
/// The active state is forced with `controlActiveState = .key` (measured: the offscreen host window never becomes key, and an
/// inactive control draws grey, which would hide the tint entirely). The per-control `Theme.accent` render proves the detector can see
/// blue; the root-tint mutation only proves the source test bites.
@MainActor
final class QuietControlsRenderTests: XCTestCase {
    private let size = CGSize(width: 260, height: 150)

    private func render<V: View>(_ content: V) -> NSBitmapImageRep {
        let view = content.environment(\.colorScheme, .dark).environment(\.controlActiveState, .key).frame(width: size.width, height: size.height).background(Theme.panel)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private func bluePixels(_ rep: NSBitmapImageRep) -> Int {
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.blueComponent - c.redComponent > 0.25 { n += 1 }
            }
        }
        return n
    }

    /// One control per case. Each is checked SEPARATELY: under the blue accent tint it must show blue (so the detector is meaningful for
    /// THAT control), under `Theme.controlTint` it must show none. A segmented Picker and a linear ProgressView are deliberately absent:
    /// measured offscreen, neither shows blue even under the accent tint, so a zero for them would prove nothing (manual check in PROGRESS.md).
    private enum Kind: String, CaseIterable { case checkedToggle, nativeSlider }

    private struct One: View {
        let kind: Kind
        var body: some View {
            Group {
                switch kind {
                case .checkedToggle: Toggle("Watermark", isOn: .constant(true))
                case .nativeSlider: Slider(value: .constant(0.6), in: 0...1)
                }
            }.padding(12)
        }
    }

    func testEachControlHasNoBlueUnderTheRootTintButDoesUnderTheAccent() {
        for kind in Kind.allCases {
            let blue = bluePixels(render(One(kind: kind).tint(Theme.accent)))
            let grey = bluePixels(render(One(kind: kind).tint(Theme.controlTint)))
            XCTAssertGreaterThan(blue, 5, "\(kind): the detector sees the blue-tinted control")
            XCTAssertEqual(grey, 0, "\(kind): no blue under the grey control tint")
        }
    }

    /// The app really applies that tint at its root (the render tests above use `Theme.controlTint` directly).
    func testTheAppRootAppliesTheControlTint() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/PhotoAppApp.swift")
        let code = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { $0.components(separatedBy: "//").first ?? "" }
        XCTAssertTrue(code.contains { $0.contains(".tint(Theme.controlTint)") }, "root tint is the grey control tint")
        XCTAssertFalse(code.contains { $0.contains(".tint(Theme.accent)") }, "root tint is not the blue accent")
    }
}
