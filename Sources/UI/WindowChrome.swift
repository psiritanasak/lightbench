import AppKit
import SwiftUI

// MARK: - Pure pieces (layout, colours, hit-testing)

/// The three window buttons, in their on-screen order.
enum TrafficLightKind: CaseIterable, Hashable {
    case close, minimize, zoom

    var title: String {
        switch self {
        case .close: return "Close"
        case .minimize: return "Minimize"
        case .zoom: return "Zoom"
        }
    }

    var windowButtonType: NSWindow.ButtonType {
        switch self {
        case .close: return .closeButton
        case .minimize: return .miniaturizeButton
        case .zoom: return .zoomButton
        }
    }
}

/// Where the three flat dots sit, in the coordinates of the view that draws them. Built from the REAL window buttons' frames, so the
/// dots land where the system's buttons were. Pure: no AppKit views.
struct TrafficLightLayout: Equatable {
    var centers: [CGPoint]
    var radius: CGFloat

    /// The classic left-aligned spacing, used only if the real buttons have no frames yet (a window that was never laid out).
    static let fallbackFrames: [CGRect] = [
        CGRect(x: 7, y: 6, width: 14, height: 14), CGRect(x: 27, y: 6, width: 14, height: 14), CGRect(x: 47, y: 6, width: 14, height: 14)
    ]

    /// The rectangle that contains all three dots; the drawing view is sized to it.
    var bounds: CGRect {
        guard let first = centers.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for c in centers {
            minX = min(minX, c.x); maxX = max(maxX, c.x); minY = min(minY, c.y); maxY = max(maxY, c.y)
        }
        return CGRect(x: minX - radius, y: minY - radius, width: maxX - minX + 2 * radius, height: maxY - minY + 2 * radius)
    }

    /// Dots at the middle of each frame (close, minimize, zoom order), slightly smaller than the system's, never under 5 pt. Empty
    /// or non-finite frames fall back to `fallbackFrames`.
    static func from(frames: [CGRect]) -> TrafficLightLayout {
        let usable = frames.count == 3 && frames.allSatisfy { !$0.isEmpty && $0.origin.x.isFinite && $0.origin.y.isFinite }
        let source = usable ? frames : fallbackFrames
        let radius = max(5, (source.map { min($0.width, $0.height) }.min() ?? 14) / 2 - 1.5)
        return TrafficLightLayout(centers: source.map { CGPoint(x: $0.midX, y: $0.midY) }, radius: radius)
    }

    /// The same layout expressed relative to `bounds.origin` (what the drawing view uses as its own coordinates).
    func translatedToOrigin() -> TrafficLightLayout {
        let b = bounds
        return TrafficLightLayout(centers: centers.map { CGPoint(x: $0.x - b.minX, y: $0.y - b.minY) }, radius: radius)
    }

    /// Which dot a point is on, or nil between / outside the dots (so a click in the gaps still drags the window). `slop` forgives a
    /// slightly off click.
    func kind(at point: CGPoint, slop: CGFloat = 2) -> TrafficLightKind? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        var best: (kind: TrafficLightKind, distance: CGFloat)?
        for (index, kind) in TrafficLightKind.allCases.enumerated() where index < centers.count {
            let d = hypot(point.x - centers[index].x, point.y - centers[index].y)
            if d <= radius + slop, d < (best?.distance ?? .infinity) { best = (kind, d) }
        }
        return best?.kind
    }
}

/// The flat dots' colours. The conventional red / yellow / green when the window is active, one neutral grey when it is not or the
/// button is disabled (a taste call, kept in one place).
enum TrafficLightAppearance {
    static func fill(_ kind: TrafficLightKind, isWindowActive: Bool, isEnabled: Bool) -> NSColor {
        guard isWindowActive, isEnabled else { return NSColor(white: isEnabled ? 0.36 : 0.28, alpha: 1) }
        switch kind {
        case .close: return NSColor(srgbRed: 1.0, green: 0.373, blue: 0.341, alpha: 1)     // #FF5F57
        case .minimize: return NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1) // #FEBC2E
        case .zoom: return NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)     // #28C840
        }
    }

    static let glyph = NSColor(white: 0, alpha: 0.55)
}

// MARK: - What a click does

/// The window actions behind the dots, behind a protocol so a test can watch them.
@MainActor
protocol WindowActions: AnyObject {
    func close()
    func minimize()
    /// Green: toggles full screen like the system button; with Option held, zooms (resizes) instead.
    func zoom(optionHeld: Bool)
}

@MainActor
final class NSWindowActions: WindowActions {
    private weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
    func close() { window?.performClose(nil) }
    func minimize() { window?.performMiniaturize(nil) }
    func zoom(optionHeld: Bool) {
        if optionHeld { window?.performZoom(nil) } else { window?.toggleFullScreen(nil) }
    }
}

// MARK: - The view

/// Three flat circles in place of the system's window buttons. Draws only the dots (glyphs while the pointer is over the group, like
/// the system), turns grey when the window is not active, ignores a disabled button, and lets clicks in the gaps fall through to
/// the title bar so the window can still be dragged.
@MainActor
final class FlatTrafficLightsView: NSView {
    private(set) var layoutModel: TrafficLightLayout
    private let actions: WindowActions
    var isWindowActive = true { didSet { if isWindowActive != oldValue { needsDisplay = true } } }
    var enabledKinds: Set<TrafficLightKind> = Set(TrafficLightKind.allCases) { didSet { needsDisplay = true } }
    private(set) var isHovering = false { didSet { if isHovering != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    init(layout: TrafficLightLayout, actions: WindowActions) {
        // Own coordinates start at the dots' bounding box.
        self.layoutModel = layout.translatedToOrigin()
        self.actions = actions
        super.init(frame: CGRect(origin: layout.bounds.origin, size: layout.bounds.size))
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The system buttons work with the first click on an inactive window; so do these.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Swallowed on purpose: the default forwards to the title bar behind, which would start a window drag or run its double-click
    /// zoom / minimise on top of the dot's own action. The click is performed on `mouseUp`.
    override func mouseDown(with event: NSEvent) {}

    /// Moves / resizes the dots to a new layout (the title bar re-laid out the system buttons).
    func apply(layout: TrafficLightLayout) {
        guard layout.translatedToOrigin() != layoutModel || frame != layout.bounds else { return }
        layoutModel = layout.translatedToOrigin()
        frame = layout.bounds
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Only a point on a dot belongs to this view; the gaps belong to the title bar behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return layoutModel.kind(at: local) == nil ? nil : self
    }

    func setHoveringForTesting(_ hovering: Bool) { isHovering = hovering }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func mouseUp(with event: NSEvent) {
        guard let kind = layoutModel.kind(at: convert(event.locationInWindow, from: nil)) else { return }
        activate(kind, optionHeld: event.modifierFlags.contains(.option))
    }

    /// What a click on `kind` does. A disabled button does nothing.
    func activate(_ kind: TrafficLightKind, optionHeld: Bool = false) {
        guard enabledKinds.contains(kind) else { return }
        switch kind {
        case .close: actions.close()
        case .minimize: actions.minimize()
        case .zoom: actions.zoom(optionHeld: optionHeld)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, kind) in TrafficLightKind.allCases.enumerated() where index < layoutModel.centers.count {
            let c = layoutModel.centers[index], r = layoutModel.radius
            let enabled = enabledKinds.contains(kind)
            TrafficLightAppearance.fill(kind, isWindowActive: isWindowActive, isEnabled: enabled).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
            if isHovering, enabled { drawGlyph(kind, at: c, radius: r) }
        }
    }

    private func drawGlyph(_ kind: TrafficLightKind, at c: CGPoint, radius r: CGFloat) {
        let h = r * 0.45
        let path = NSBezierPath()
        switch kind {
        case .close:
            path.move(to: CGPoint(x: c.x - h, y: c.y - h)); path.line(to: CGPoint(x: c.x + h, y: c.y + h))
            path.move(to: CGPoint(x: c.x - h, y: c.y + h)); path.line(to: CGPoint(x: c.x + h, y: c.y - h))
        case .minimize:
            path.move(to: CGPoint(x: c.x - h, y: c.y)); path.line(to: CGPoint(x: c.x + h, y: c.y))
        case .zoom:
            path.move(to: CGPoint(x: c.x - h, y: c.y)); path.line(to: CGPoint(x: c.x + h, y: c.y))
            path.move(to: CGPoint(x: c.x, y: c.y - h)); path.line(to: CGPoint(x: c.x, y: c.y + h))
        }
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        TrafficLightAppearance.glyph.setStroke()
        path.stroke()
    }

    // MARK: Accessibility

    /// No accessibility elements of its own: the system buttons underneath stay laid out (measured: a HIDDEN button drops out of
    /// accessibility, an invisible-but-laid-out one does not), are fully functional and sit exactly under the dots, so VoiceOver,
    /// Switch Control and AX automation (`AXCloseButton`, ...) use them. Elements here would duplicate them.
    override func accessibilityChildren() -> [Any]? { [] }

    override func isAccessibilityElement() -> Bool { false }
}

// MARK: - Installing it on a window

@MainActor
enum FlatTrafficLights {
    static let identifier = NSUserInterfaceItemIdentifier("FlatTrafficLights")

    /// Makes the window's three system buttons invisible (but still laid out) and puts ONE `FlatTrafficLightsView` where they were. Safe to call repeatedly (the
    /// existing view is reused). Returns nil if the window has no standard buttons (e.g. a borderless window).
    @discardableResult
    static func install(in window: NSWindow, actions: WindowActions? = nil) -> FlatTrafficLightsView? {
        let buttons = TrafficLightKind.allCases.compactMap { window.standardWindowButton($0.windowButtonType) }
        guard buttons.count == 3, let container = buttons[0].superview else { return nil }

        if let existing = container.subviews.compactMap({ $0 as? FlatTrafficLightsView }).first(where: { $0.identifier == identifier }) {
            keepButtonsInvisible(buttons)
            return existing
        }
        let layout = TrafficLightLayout.from(frames: buttons.map(\.frame))
        let view = FlatTrafficLightsView(layout: layout, actions: actions ?? NSWindowActions(window))
        view.identifier = identifier
        view.autoresizingMask = buttons[0].autoresizingMask
        view.enabledKinds = Set(zip(TrafficLightKind.allCases, buttons).filter { $0.1.isEnabled }.map(\.0))
        view.isWindowActive = window.isMainWindow
        container.addSubview(view)
        keepButtonsInvisible(buttons)
        Observers.attach(to: view, window: window, buttons: buttons)
        return view
    }

    /// The alpha the system buttons are left at. NOT 0 and NOT `isHidden`: AppKit lays the window title out after the buttons that are
    /// VISIBLE, and measured on a titled window with a toolbar, hidden buttons (or alpha 0) moved the title 70 pt to the left, under
    /// the dots, while alpha 0.01 + `isTransparent` kept it at its normal position (106 pt) and draws nothing.
    static let invisibleAlpha: CGFloat = 0.01

    /// Whether a system button is in the "invisible but still laid out" state.
    static func isInvisible(_ button: NSButton) -> Bool {
        !button.isHidden && button.alphaValue > 0 && button.alphaValue <= 0.05 && button.isTransparent
    }

    static func restore(_ button: NSButton) { keepButtonsInvisible([button]) }

    private static func keepButtonsInvisible(_ buttons: [NSButton]) {
        for button in buttons where !isInvisible(button) {
            button.isHidden = false
            button.alphaValue = invisibleAlpha
            button.isTransparent = true
        }
    }

    /// AppKit moves the standard buttons itself when the title bar re-lays out (a toolbar appearing or changing height, full screen,
    /// a different container): follow them. Re-parents the dots if the buttons moved to another container, and refreshes which
    /// buttons are enabled. Looks the buttons up from the window each time, so nothing here retains them.
    static func resync(_ view: FlatTrafficLightsView, in window: NSWindow) {
        let buttons = TrafficLightKind.allCases.compactMap { window.standardWindowButton($0.windowButtonType) }
        guard buttons.count == 3, let container = buttons[0].superview else { return }
        if view.superview !== container {
            view.removeFromSuperview()
            container.addSubview(view)
        }
        view.apply(layout: TrafficLightLayout.from(frames: buttons.map(\.frame)))
        view.enabledKinds = Set(zip(TrafficLightKind.allCases, buttons).filter { $0.1.isEnabled }.map(\.0))
        keepButtonsInvisible(buttons)
    }

    /// Window / button notifications and a KVO on each button's `isHidden`: AppKit re-shows its buttons now and then, MOVES them when the
    /// title bar re-lays out (a toolbar attaching, full screen), and the dots must follow the window's main state like the system's.
    ///
    /// - Frame changes come from `NSView.frameDidChangeNotification` (`postsFrameChangedNotifications`), NOT KVO on `frame`: KVO only
    ///   sees the `frame =` setter, while AppKit moves the buttons with `setFrameOrigin` (measured: a unified toolbar attaching moved
    ///   the close button with zero KVO callbacks and one frame-changed notification).
    /// - The ORIGINAL window is captured weakly instead of read from `view.window`: in full screen AppKit moves the title-bar container
    ///   (buttons and dots) into a separate toolbar window, where `standardWindowButton` finds nothing and `isMainWindow` is false.
    ///   A weak capture creates no retain cycle with the title bar.
    private final class Observers: @unchecked Sendable {
        private var tokens: [NSObjectProtocol] = []
        private var kvo: [NSKeyValueObservation] = []

        @MainActor
        static func attach(to view: FlatTrafficLightsView, window: NSWindow, buttons: [NSButton]) {
            let holder = Observers()
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
                holder.tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak view, weak window] _ in
                    MainActor.assumeIsolated { view?.isWindowActive = window?.isMainWindow ?? false }
                })
            }
            holder.tokens.append(center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) {
                [weak view, weak window] _ in
                MainActor.assumeIsolated { if let view, let window { FlatTrafficLights.resync(view, in: window) } }
            })
            for button in buttons {
                button.postsFrameChangedNotifications = true
                // Synchronous (no queue): the buttons move on the main thread, and the dots should move in the same layout pass.
                holder.tokens.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: nil) {
                    [weak view, weak window] _ in
                    MainActor.assumeIsolated { if let view, let window { FlatTrafficLights.resync(view, in: window) } }
                })
                // AppKit hides / re-shows / re-fades its buttons now and then: put them back in the invisible-but-laid-out state.
                holder.kvo.append(button.observe(\.isHidden, options: [.new]) { button, _ in
                    MainActor.assumeIsolated { if !FlatTrafficLights.isInvisible(button) { DispatchQueue.main.async { FlatTrafficLights.restore(button) } } }
                })
                holder.kvo.append(button.observe(\.alphaValue, options: [.new]) { button, _ in
                    MainActor.assumeIsolated { if !FlatTrafficLights.isInvisible(button) { DispatchQueue.main.async { FlatTrafficLights.restore(button) } } }
                })
            }
            // The holder lives as long as the view does.
            objc_setAssociatedObject(view, &Observers.key, holder, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        nonisolated(unsafe) private static var key: UInt8 = 0

        deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}

// MARK: - SwiftUI hook

/// Put as a `.background` on a window's root view: installs the flat dots on that view's window once it has one.
struct WindowChromeInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { InstallerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class InstallerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // One run-loop turn later: the window's title bar views are laid out by then.
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = FlatTrafficLights.install(in: window) } }
        }
    }
}
