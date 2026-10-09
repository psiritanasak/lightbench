import AppKit
import SwiftUI
import XCTest
@testable import PhotoApp

/// Retouch, Red-Eye and Masks are their own rail tabs now: each scope of `AdjustTabView` renders ITS tool, and the Adjust scope no
/// longer carries those sections. Clicks are not driven (manual checklist in PROGRESS.md).
@MainActor
final class PointToolTabsTests: XCTestCase {
    private let size = CGSize(width: 360, height: 700)

    private func render(_ scope: AdjustTabView.Scope) -> NSBitmapImageRep {
        let view = AdjustTabView(
            document: ImageDocumentModel(), panel: .constant(AdjustPanelState()), interactionMode: .constant(.none),
            onEnterRetouchEditing: { _ in }, onEnterPointPickingMode: {}, scope: scope
        )
        .environment(\.colorScheme, .dark).frame(width: size.width, height: size.height, alignment: .top).background(Theme.panel)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    /// Pixels brighter than the panel (text, buttons, sliders).
    private func litPixels(_ rep: NSBitmapImageRep) -> Int {
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > 0.4 { n += 1 }
            }
        }
        return n
    }

    private func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        var n = 0
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(a.pixelsWide, b.pixelsWide) {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(p.redComponent - q.redComponent) > 0.1 { n += 1 }
            }
        }
        return n
    }

    func testEveryScopeRendersItsOwnNonEmptyContent() {
        let scopes: [AdjustTabView.Scope] = [.retouch, .redEye, .masks] // .adjust is heavy to render (45 s measured); the source scan below covers it
        let reps = scopes.map(render)
        for (scope, rep) in zip(scopes, reps) { XCTAssertGreaterThan(litPixels(rep), 300, "\(scope) draws something") }
        for i in 0..<reps.count {
            for j in (i + 1)..<reps.count {
                XCTAssertGreaterThan(differing(reps[i], reps[j]), 300, "\(scopes[i]) and \(scopes[j]) are different tabs")
            }
        }
    }

    /// The Adjust scroll (`adjustBody`) no longer holds the three point tools, and the old per-section expanded flags are gone.
    func testAdjustBodyNoLongerContainsThePointToolSections() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/UI/AdjustTabView.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private var adjustBody"))
        let end = try XCTUnwrap(text.range(of: "resetAdjustmentsButton\n        }", range: start.upperBound..<text.endIndex))
        let body = String(text[start.lowerBound..<end.upperBound])
        for moved in ["redEyeSection", "retouchSection", "masksSection", "\"Masks\"", "\"Red-Eye\"", "\"Remove\""] {
            XCTAssertFalse(body.contains(moved), "adjustBody still contains \(moved)")
        }
        XCTAssertTrue(body.contains("lightSection"), "the sliders are still there")
        for flag in ["isRedEyeSectionExpanded", "isRetouchSectionExpanded", "isMasksSectionExpanded"] {
            XCTAssertFalse(text.contains(flag), "\(flag) is obsolete")
        }
    }
}
