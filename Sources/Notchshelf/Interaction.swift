import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: Dragging out

/// A transparent AppKit layer over a tile. SwiftUI's own drag support cannot report where a drag ended,
/// and the shelf needs to know so it can let go of files that were dropped somewhere.
struct Interaction: NSViewRepresentable {
    let ids: [UUID]
    let actions: ShelfActions
    var onHover: (Bool) -> Void = { _ in }
    var onPress: (Bool) -> Void = { _ in }
    var onOpen: () -> Void = {}

    func makeNSView(context: Context) -> InteractionNSView {
        InteractionNSView()
    }

    func updateNSView(_ view: InteractionNSView, context: Context) {
        view.ids = ids
        view.actions = actions
        view.onHover = onHover
        view.onPress = onPress
        view.onOpen = onOpen
    }
}

final class InteractionNSView: NSView {
    var ids: [UUID] = []
    var actions: ShelfActions?
    var onHover: (Bool) -> Void = { _ in }
    var onPress: (Bool) -> Void = { _ in }
    var onOpen: () -> Void = {}

    private var downPoint: NSPoint?
    private var tracking: NSTrackingArea?

    // The panel never becomes key and the app is rarely active, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onHover(false) }
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        onPress(true)
        if event.clickCount == 2 {
            downPoint = nil
            onPress(false)
            onOpen()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downPoint else { return }
        let point = event.locationInWindow
        guard hypot(point.x - down.x, point.y - down.y) > 3 else { return }
        downPoint = nil
        onPress(false)
        actions?.beginDrag(ids, self, event)
    }

    override func mouseUp(with event: NSEvent) {
        downPoint = nil
        onPress(false)
    }
}

// MARK: Dropping in

/// Wraps the SwiftUI content and receives drops. AppKit is used here because file promises
/// (photos, images dragged out of a browser) are not reachable through SwiftUI's onDrop.
final class DropView: NSView {
    var allows: () -> Bool = { false }
    var onTargeted: (Bool) -> Void = { _ in }
    var onDrop: (NSDraggingInfo) -> Bool = { _ in false }
    var onMove: () -> Void = {}

    static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Self.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func evaluate() -> NSDragOperation {
        onMove()
        let ok = allows()
        onTargeted(ok)
        return ok ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { evaluate() }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { evaluate() }
    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { allows() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted(false)
        return onDrop(sender)
    }
}

/// Clicks on buttons should land even though the app is in the background.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: Thumbnails

@MainActor
enum Thumbnailer {
    static var scale: CGFloat = 2
    private static var cache: [URL: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    static func cached(_ url: URL) -> NSImage? {
        cache[url]
    }

    /// A Quick Look preview of the file's contents, or nil for things that only have an icon (folders, apps).
    static func thumbnail(for url: URL) async -> NSImage? {
        if let hit = cache[url] { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 62, height: 54), scale: scale, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = representation.nsImage
        cache[url] = image
        return image
    }
}
