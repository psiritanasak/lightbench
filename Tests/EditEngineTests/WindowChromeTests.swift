import AppKit
import XCTest
@testable import PhotoApp

@MainActor
private final class SpyActions: WindowActions {
    var closes = 0, minimizes = 0
    var zooms: [Bool] = []
    func close() { closes += 1 }
    func minimize() { minimizes += 1 }
    func zoom(optionHeld: Bool) { zooms.append(optionHeld) }
}

@MainActor
final class WindowChromeTests: XCTestCase {
    private let frames = [
        CGRect(x: 10, y: 4, width: 14, height: 14), CGRect(x: 30, y: 4, width: 14, height: 14), CGRect(x: 50, y: 4, width: 14, height: 14)
    ]

    // MARK: Layout and hit-testing (pure)

    func testLayoutPutsEachDotAtTheMiddleOfItsButtonAndShrinksSlightly() {
        let layout = TrafficLightLayout.from(frames: frames)
        XCTAssertEqual(layout.centers, [CGPoint(x: 17, y: 11), CGPoint(x: 37, y: 11), CGPoint(x: 57, y: 11)])
        XCTAssertEqual(layout.radius, 5.5, accuracy: 0.001, "7 - 1.5")
        XCTAssertEqual(layout.bounds, CGRect(x: 11.5, y: 5.5, width: 51, height: 11))
    }

    func testTinyOrEmptyFramesAreHandled() {
        XCTAssertEqual(TrafficLightLayout.from(frames: [.zero, .zero, .zero]).centers.count, 3, "fallback frames")
        XCTAssertEqual(TrafficLightLayout.from(frames: []).centers.count, 3)
        let tiny = TrafficLightLayout.from(frames: frames.map { $0.insetBy(dx: 5, dy: 5) })
        XCTAssertEqual(tiny.radius, 5, "never under 5 pt")
    }

    func testTranslatedLayoutStartsAtTheOrigin() {
        let t = TrafficLightLayout.from(frames: frames).translatedToOrigin()
        XCTAssertEqual(t.bounds.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(t.bounds.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(t.centers[1].x - t.centers[0].x, 20, accuracy: 0.001, "spacing is preserved")
    }

    func testHitTestFindsTheDotUnderThePointOnly() {
        let layout = TrafficLightLayout.from(frames: frames)
        XCTAssertEqual(layout.kind(at: CGPoint(x: 17, y: 11)), .close)
        XCTAssertEqual(layout.kind(at: CGPoint(x: 37, y: 11)), .minimize)
        XCTAssertEqual(layout.kind(at: CGPoint(x: 57, y: 11)), .zoom)
        XCTAssertEqual(layout.kind(at: CGPoint(x: 17 + 7, y: 11)), .close, "within the 2 pt slop")
        XCTAssertNil(layout.kind(at: CGPoint(x: 27, y: 11)), "the gap between dots belongs to the title bar")
        XCTAssertNil(layout.kind(at: CGPoint(x: 17, y: 11 + 12)), "outside the radius")
        XCTAssertNil(layout.kind(at: CGPoint(x: CGFloat.nan, y: 11)))
    }

    // MARK: Colours (pure)

    func testActiveColoursAreTheThreeFlatHues() throws {
        func rgb(_ k: TrafficLightKind) throws -> (CGFloat, CGFloat, CGFloat) {
            let c = try XCTUnwrap(TrafficLightAppearance.fill(k, isWindowActive: true, isEnabled: true).usingColorSpace(.sRGB))
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        let close = try rgb(.close), minimize = try rgb(.minimize), zoom = try rgb(.zoom)
        XCTAssertGreaterThan(close.0, close.1 + 0.4)
        XCTAssertGreaterThan(minimize.0, minimize.2 + 0.4)
        XCTAssertGreaterThan(minimize.1, minimize.2 + 0.4)
        XCTAssertGreaterThan(zoom.1, zoom.0 + 0.3)
    }

    func testInactiveAndDisabledDotsAreNeutralGrey() throws {
        for kind in TrafficLightKind.allCases {
            for (active, enabled) in [(false, true), (true, false), (false, false)] {
                let c = try XCTUnwrap(TrafficLightAppearance.fill(kind, isWindowActive: active, isEnabled: enabled).usingColorSpace(.sRGB))
                XCTAssertEqual(c.redComponent, c.greenComponent, accuracy: 0.001)
                XCTAssertEqual(c.greenComponent, c.blueComponent, accuracy: 0.001)
            }
        }
        let a = TrafficLightAppearance.fill(.close, isWindowActive: false, isEnabled: true)
        let b = TrafficLightAppearance.fill(.zoom, isWindowActive: false, isEnabled: true)
        XCTAssertEqual(a, b, "one grey for all three when inactive")
    }

    // MARK: Drawing

    private func render(_ view: FlatTrafficLightsView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func color(_ rep: NSBitmapImageRep, _ view: FlatTrafficLightsView, dot index: Int, dx: CGFloat = 0) throws -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let c = view.layoutModel.centers[index]
        // NSView is not flipped: the bitmap's row 0 is the TOP, i.e. view y = height.
        let x = Int((c.x + dx) * scale), y = Int((view.bounds.height - c.y) * scale)
        return try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    func testTheViewDrawsRedYellowGreenDotsAtTheirCentres() throws {
        let view = FlatTrafficLightsView(layout: .from(frames: frames), actions: SpyActions())
        let rep = render(view)
        let close = try color(rep, view, dot: 0), minimize = try color(rep, view, dot: 1), zoom = try color(rep, view, dot: 2)
        XCTAssertGreaterThan(close.redComponent, close.greenComponent + 0.4)
        XCTAssertGreaterThan(minimize.redComponent, minimize.blueComponent + 0.4)
        XCTAssertGreaterThan(minimize.greenComponent, minimize.blueComponent + 0.4)
        XCTAssertGreaterThan(zoom.greenComponent, zoom.redComponent + 0.3)
        let gap = try color(rep, view, dot: 0, dx: 10)
        XCTAssertEqual(gap.alphaComponent, 0, accuracy: 0.01, "the gap between dots is transparent")
    }

    func testAnInactiveWindowGreysTheDots() throws {
        let view = FlatTrafficLightsView(layout: .from(frames: frames), actions: SpyActions())
        view.isWindowActive = false
        let rep = render(view)
        for i in 0..<3 {
            let c = try color(rep, view, dot: i)
            XCTAssertEqual(c.redComponent, c.greenComponent, accuracy: 0.02, "dot \(i)")
            XCTAssertEqual(c.greenComponent, c.blueComponent, accuracy: 0.02, "dot \(i)")
        }
    }

    func testHoveringDrawsTheGlyphsOverTheDots() throws {
        let view = FlatTrafficLightsView(layout: .from(frames: frames), actions: SpyActions())
        let plain = render(view)
        view.setHoveringForTesting(true)
        let hover = render(view)
        for i in 0..<3 {
            let a = try color(plain, view, dot: i), b = try color(hover, view, dot: i)
            XCTAssertNotEqual(a.redComponent + a.greenComponent + a.blueComponent, b.redComponent + b.greenComponent + b.blueComponent,
                              accuracy: 0.05, "the glyph crosses the centre of dot \(i)")
        }
    }

    // MARK: Clicks

    func testActivatingADotCallsItsWindowActionOnce() {
        let spy = SpyActions()
        let view = FlatTrafficLightsView(layout: .from(frames: frames), actions: spy)
        view.activate(.close)
        view.activate(.minimize)
        view.activate(.zoom)
        view.activate(.zoom, optionHeld: true)
        XCTAssertEqual(spy.closes, 1)
        XCTAssertEqual(spy.minimizes, 1)
        XCTAssertEqual(spy.zooms, [false, true], "Option-click is passed through to the zoom action")
    }

    func testADisabledButtonDoesNothing() {
        let spy = SpyActions()
        let view = FlatTrafficLightsView(layout: .from(frames: frames), actions: spy)
        view.enabledKinds = [.minimize, .zoom]
        view.activate(.close)
        XCTAssertEqual(spy.closes, 0)
        view.activate(.minimize)
        XCTAssertEqual(spy.minimizes, 1)
    }

    func testOnlyPointsOnADotAreHitByTheView() {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        let view = FlatTrafficLightsView(layout: .from(frames: frames), actions: SpyActions())
        container.addSubview(view)
        XCTAssertTrue(view.hitTest(CGPoint(x: 17, y: 11)) === view)
        XCTAssertNil(view.hitTest(CGPoint(x: 27, y: 11)), "gap: falls through so the window can be dragged")
        XCTAssertNil(view.hitTest(CGPoint(x: 150, y: 30)))
        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }

    // MARK: Installing on a real window

    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    }

    private func standardButtons(_ window: NSWindow) -> [NSButton] {
        TrafficLightKind.allCases.compactMap { window.standardWindowButton($0.windowButtonType) }
    }

    func testInstallHidesTheSystemButtonsAndAddsExactlyOneView() throws {
        let window = makeWindow()
        let first = try XCTUnwrap(FlatTrafficLights.install(in: window, actions: SpyActions()))
        let second = try XCTUnwrap(FlatTrafficLights.install(in: window, actions: SpyActions()))
        XCTAssertTrue(first === second, "installing twice reuses the view")
        let container = try XCTUnwrap(standardButtons(window).first?.superview)
        XCTAssertEqual(container.subviews.filter { $0 is FlatTrafficLightsView }.count, 1)
        for button in standardButtons(window) { XCTAssertTrue(button.isHidden, "system button hidden") }
    }

    func testTheSystemButtonsStayHiddenWhenAppKitShowsThemAgain() throws {
        let window = makeWindow()
        _ = try XCTUnwrap(FlatTrafficLights.install(in: window, actions: SpyActions()))
        let button = try XCTUnwrap(standardButtons(window).first)
        button.isHidden = false
        let hidden = expectation(description: "re-hidden")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { hidden.fulfill() }
        wait(for: [hidden], timeout: 2)
        XCTAssertTrue(button.isHidden)
    }

    func testInstallCopiesTheOriginalButtonsDisabledState() throws {
        let window = makeWindow()
        standardButtons(window)[0].isEnabled = false
        let spy = SpyActions()
        let view = try XCTUnwrap(FlatTrafficLights.install(in: window, actions: spy))
        view.activate(.close)
        XCTAssertEqual(spy.closes, 0, "the close button was disabled on the system window")
        view.activate(.minimize)
        XCTAssertEqual(spy.minimizes, 1)
    }

    func testABorderlessWindowGetsNothing() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        XCTAssertNil(FlatTrafficLights.install(in: window))
    }

    // MARK: Mouse handling, resync, accessibility

    private final class MouseDownSpyContainer: NSView {
        var mouseDowns = 0
        override func mouseDown(with event: NSEvent) { mouseDowns += 1 }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testMouseDownIsSwallowedSoTheTitleBarDoesNotAlsoHandleIt() throws {
        let window = makeWindow()
        let container = MouseDownSpyContainer(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(container)
        let view = FlatTrafficLightsView(layout: .from(frames: frames), actions: SpyActions())
        container.addSubview(view)
        let down = try mouseEvent(.leftMouseDown, at: view.convert(view.layoutModel.centers[0], to: nil), in: window)
        view.mouseDown(with: down)
        XCTAssertEqual(container.mouseDowns, 0, "the default would forward mouseDown to the title bar behind")
        XCTAssertTrue(view.acceptsFirstMouse(for: nil), "works on the first click of an inactive window, like the system buttons")
    }

    func testMouseUpOnADotPerformsItAndOnTheGapDoesNot() throws {
        let window = makeWindow()
        let spy = SpyActions()
        let view = try XCTUnwrap(FlatTrafficLights.install(in: window, actions: spy))
        let dot = view.convert(view.layoutModel.centers[1], to: nil)
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: dot, in: window))
        XCTAssertEqual(spy.minimizes, 1)
        let gap = view.convert(CGPoint(x: (view.layoutModel.centers[0].x + view.layoutModel.centers[1].x) / 2, y: view.layoutModel.centers[0].y), to: nil)
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: gap, in: window))
        XCTAssertEqual(spy.closes + spy.minimizes + spy.zooms.count, 1, "a click in the gap performs nothing")
    }

    /// AppKit moves the buttons with `setFrameOrigin`, which KVO on `frame` never sees (measured with a unified toolbar attaching), so
    /// this test moves them that way.
    func testTheDotsFollowTheSystemButtonsWhenTheTitleBarMovesThem() throws {
        let window = makeWindow()
        let view = try XCTUnwrap(FlatTrafficLights.install(in: window, actions: SpyActions()))
        let before = view.frame
        for button in standardButtons(window) { button.setFrameOrigin(CGPoint(x: button.frame.origin.x, y: button.frame.origin.y + 9)) }
        XCTAssertEqual(view.frame.origin.y, before.origin.y + 9, accuracy: 0.001, "the dots moved with the buttons")
        XCTAssertEqual(view.frame.origin.x, before.origin.x, accuracy: 0.001)
    }

    /// In full screen AppKit moves the title-bar container into another window; the dots must still resync against the ORIGINAL window.
    func testResyncUsesTheOriginalWindowEvenIfTheDotsEndUpInAnotherWindow() throws {
        let window = makeWindow(), other = makeWindow()
        let view = try XCTUnwrap(FlatTrafficLights.install(in: window, actions: SpyActions()))
        let container = try XCTUnwrap(standardButtons(window).first?.superview)
        other.contentView?.addSubview(view)
        XCTAssertTrue(view.window === other)
        let first = try XCTUnwrap(standardButtons(window).first)
        first.setFrameOrigin(CGPoint(x: first.frame.origin.x + 1, y: first.frame.origin.y))
        XCTAssertTrue(view.superview === container, "resynced against the original window's buttons, not the other window's")
    }

    func testTheDotsAreReparentedIfTheButtonsMoveToAnotherContainer() throws {
        let window = makeWindow()
        let view = try XCTUnwrap(FlatTrafficLights.install(in: window, actions: SpyActions()))
        let newContainer = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        window.contentView?.addSubview(newContainer)
        for button in standardButtons(window) { newContainer.addSubview(button) }
        FlatTrafficLights.resync(view, in: window)
        XCTAssertTrue(view.superview === newContainer)
    }

    func testTheDotsAreRealPressableAccessibilityButtons() throws {
        let spy = SpyActions()
        let view = FlatTrafficLightsView(layout: .from(frames: frames), actions: spy)
        let first = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        let second = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(first.map { $0.accessibilityLabel() }, ["Close", "Minimize", "Zoom"])
        XCTAssertEqual(first.map { $0.accessibilityRole() }, [.button, .button, .button])
        XCTAssertTrue(zip(first, second).allSatisfy { $0 === $1 }, "the same elements every time, so VoiceOver keeps its place")
        XCTAssertTrue(first[1].accessibilityPerformPress())
        XCTAssertTrue(first[0].accessibilityPerformPress())
        XCTAssertEqual(spy.minimizes, 1)
        XCTAssertEqual(spy.closes, 1)
        view.enabledKinds = [.minimize, .zoom]
        XCTAssertFalse(first[0].accessibilityPerformPress(), "a disabled button reports that it could not be pressed")
        XCTAssertEqual(spy.closes, 1)
    }
}
