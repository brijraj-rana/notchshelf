import AppKit
import NotchshelfCore
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
/// Text, links and bare images come in the same way and are written out as files by the store.
final class DropView: NSView {
    var allows: () -> Bool = { false }
    var onTargeted: (Bool) -> Void = { _ in }
    var onDrop: (NSDraggingInfo) -> Bool = { _ in false }
    var onMove: () -> Void = {}

    /// The title a browser sends along with a link.
    static let urlName = NSPasteboard.PasteboardType("public.url-name")

    static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        + [.URL, .string] + ImageChoice.types.map { NSPasteboard.PasteboardType($0) }

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
    static func thumbnail(for url: URL, snippet: Bool = false) async -> NSImage? {
        if let hit = cache[url] { return hit }
        if snippet, let image = page(for: url) {
            cache[url] = image
            return image
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 62, height: 54), scale: scale, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = representation.nsImage
        cache[url] = image
        return image
    }

    /// Quick Look draws a text file as a whole page, which leaves a few shelved words too small to read.
    /// This is the same white page with only the opening lines on it, at a size that can be read on a tile.
    private static func page(for url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let opening = String(decoding: data.prefix(600), as: UTF8.self)
        let lines = opening.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = 2
        let text = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: 7.5, weight: .medium),
            .foregroundColor: NSColor(white: 0.16, alpha: 1),
            .paragraphStyle: paragraph,
        ])
        return NSImage(size: NSSize(width: 54, height: 54), flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            text.draw(with: rect.insetBy(dx: 5, dy: 5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }
}
