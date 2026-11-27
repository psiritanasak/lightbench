import AppKit
import UniformTypeIdentifiers

/// The AppKit drag source for library thumbnails. SwiftUI's `.draggable` and `.onDrag` both hand the payload to EVERY app, and Finder
/// accepted it and wrote it as an unopenable file on the Desktop (`{"photoIDs":[2]}`; found by hand 2026-11-27, three times, also with
/// `.visibility(.ownProcess)`). A real `NSDraggingSource` can say what a drag may do OUTSIDE this app: nothing. Then no other app is ever
/// offered the drop, and the cursor shows "not allowed" over Finder.
final class LibraryPhotoDragSource: NSObject, NSDraggingSource, @unchecked Sendable {
    static let shared = LibraryPhotoDragSource()

    /// Copy (add to a collection) inside this app, nothing anywhere else. Pure so a test can pin it.
    static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operationMask(for: context)
    }

    /// True from the moment a drag session starts until it ends: the detecting gesture fires on every mouse move, and a move already queued
    /// must not start a SECOND session.
    @MainActor private(set) static var isDragging = false

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Task { @MainActor in Self.isDragging = false }
    }

    /// Test seam: the guards `begin` applies before it touches AppKit. A drag only starts from a mouse-dragged event while none is running.
    @MainActor static func canBegin(eventType: NSEvent.EventType?, isDragging: Bool = LibraryPhotoDragSource.isDragging) -> Bool {
        eventType == .leftMouseDragged && !isDragging
    }

    /// The pasteboard item: the JSON of `LibraryPhotoDrag` under our own type, exactly what `.dropDestination(for: LibraryPhotoDrag.self)`
    /// reads. Nothing else is offered (no URL, file URL, image or text).
    static func pasteboardItem(for photoIDs: [Int64]) -> NSPasteboardItem? {
        guard let data = try? JSONEncoder().encode(LibraryPhotoDrag(photoIDs: photoIDs)) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.lightbenchLibraryPhotos.identifier))
        return item
    }

    /// Starts the drag from the mouse-dragged event that is being handled right now. Returns false when there is nothing to drag from.
    @MainActor @discardableResult
    static func begin(photoIDs: [Int64], image: NSImage?) -> Bool {
        guard !photoIDs.isEmpty, let event = NSApp.currentEvent, canBegin(eventType: event.type), let view = event.window?.contentView, let item = pasteboardItem(for: photoIDs) else { return false }
        let side: CGFloat = 72
        let point = view.convert(event.locationInWindow, from: nil)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let preview = image ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage()
        dragging.setDraggingFrame(NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side), contents: preview)
        isDragging = true
        view.beginDraggingSession(with: [dragging], event: event, source: shared)
        return true
    }
}
