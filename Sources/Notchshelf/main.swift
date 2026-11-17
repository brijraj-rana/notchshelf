import AppKit
import Combine
import NotchshelfCore
import ServiceManagement
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // AppKit normally pushes windows below the menu bar; this one has to reach the top edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Lets other notch apps know when the space under the notch is taken, so they can stay closed.
enum Presence {
    static let covering = Notification.Name("com.brijraj.notchshelf.covering")
    static let clear = Notification.Name("com.brijraj.notchshelf.clear")
    static let notchloadID = "com.brijraj.notchload"

    static func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

@MainActor
final class ShelfController: NSObject, NSDraggingSource, NSMenuDelegate {
    let store: ShelfStore
    let state = PanelState()
    let actions = ShelfActions()

    private var panel: NotchPanel!
    private var statusItem: NSStatusItem?
    private var subscriptions: Set<AnyCancellable> = []

    // Hit areas in screen coordinates.
    private var hoverRect = NSRect.zero      // opens the shelf while it is holding files
    private var dropZone = NSRect.zero       // opens the shelf while a file is being dragged
    private var openRect = NSRect.zero       // keeps it open

    private var pointerInside = false
    private var isOpen = false
    private var pending: DispatchWorkItem?
    private var pollTimer: Timer?
    private var menuOpen = false
    private var announcedCovering = false

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragChangeCount = 0
    private var incomingDrag = false         // someone is dragging files around the screen
    private var draggingOut = false          // the drag in progress started on the shelf
    private var draggedIDs: Set<UUID> = []
    private let promiseQueue = OperationQueue()

    private var keepAfterDragOut: Bool {
        get { UserDefaults.standard.bool(forKey: "keepAfterDragOut") }
        set { UserDefaults.standard.set(newValue, forKey: "keepAfterDragOut") }
    }

    init(store: ShelfStore) {
        self.store = store
        super.init()
        actions.remove = { [weak self] id in self?.store.remove([id]) }
        actions.clear = { [weak self] in self?.store.clear() }
        actions.open = { [weak self] id in self?.openItem(id) }
        actions.beginDrag = { [weak self] ids, view, event in self?.beginDrag(ids, from: view, event: event) }
    }

    func start() {
        store.refresh()

        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // One above Notchload, so the shelf covers its tab when both are open.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false

        let host = FirstMouseHostingView(rootView: RootView(state: state, store: store, actions: actions))
        host.safeAreaRegions = []
        let drop = DropView(frame: .zero)
        drop.allows = { [weak self] in self?.dropAllowed() ?? false }
        drop.onTargeted = { [weak self] targeted in
            guard let self, self.state.targeted != targeted else { return }
            self.state.targeted = targeted
        }
        drop.onDrop = { [weak self] info in self?.receive(info) ?? false }
        drop.onMove = { [weak self] in self?.pointerMoved() }
        host.frame = drop.bounds
        host.autoresizingMask = [.width, .height]
        drop.addSubview(host)
        panel.contentView = drop

        layout()
        apply()
        panel.orderFrontRegardless()
        installStatusItem()

        // Published values arrive before they are stored, so read them on the next turn.
        store.$items
            .map(\.isEmpty)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &subscriptions)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layout() }
            }
        }

        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            // Right-clicks elsewhere in the app (the menu bar icon) are not ours to handle.
            let onPanel = MainActor.assumeIsolated { self?.panel != nil && event.window === self?.panel }
            guard onPanel else { return event }
            MainActor.assumeIsolated { self?.showMenu(for: event) }
            return nil
        }
    }

    func stop() {
        if announcedCovering { Presence.post(Presence.clear) }
    }

    // MARK: Layout

    private func layout() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        var geo = NotchGeometry()
        var top = screen.frame.maxY

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            geo.notchHeight = screen.safeAreaInsets.top
            geo.notchWidth = max(120, right.minX - left.maxX)
        } else {
            // No notch (external display, lid closed): hang from the bottom of the menu bar instead.
            geo.notchHeight = 0
            geo.notchWidth = 150
            top = screen.visibleFrame.maxY
        }
        state.geo = geo

        let size = geo.windowSize
        let midX = screen.frame.midX
        panel.setFrame(NSRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: true)

        let nw = geo.notchWidth, nh = geo.notchHeight
        if geo.hasNotch {
            // Notchload opens when its tab under the notch is hovered, so with it running only the ear is ours.
            let notchloadRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Presence.notchloadID).isEmpty
            let ear = NSRect(x: midX + nw / 2, y: top - nh, width: geo.earWidth, height: nh + 2)
            hoverRect = notchloadRunning ? ear : ear.union(NSRect(x: midX - nw / 2, y: top - nh, width: nw, height: nh + 2))
        } else {
            hoverRect = NSRect(x: midX - nw / 2, y: top - geo.lipHeight, width: nw, height: geo.lipHeight + 2)
        }
        let reach = nh + geo.lipHeight + 18
        dropZone = NSRect(x: midX - nw / 2 - 30, y: top - reach, width: nw + 60, height: reach + 2)
        openRect = NSRect(x: midX - geo.openWidth / 2, y: top - nh - geo.openHeight, width: geo.openWidth, height: nh + geo.openHeight + 2)
        pointerMoved()
    }

    // MARK: Pointer and drags

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragChangeCount = dragPasteboard.changeCount
        case .leftMouseDragged:
            // A drag session writes to the drag pasteboard as it starts; a plain click-and-move does not.
            if !incomingDrag, !draggingOut, dragPasteboard.changeCount != dragChangeCount {
                dragChangeCount = dragPasteboard.changeCount
                if carriesFiles(dragPasteboard) {
                    incomingDrag = true
                    apply()
                }
            }
        case .leftMouseUp:
            // Let the drop itself land first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.endIncomingDrag() }
            }
        default:
            break
        }
        pointerMoved()
    }

    private func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: DropView.acceptedTypes) != nil
    }

    private func endIncomingDrag() {
        guard incomingDrag else { return }
        incomingDrag = false
        state.targeted = false
        apply()
        pointerMoved()
    }

    private func pointerMoved() {
        guard !menuOpen, panel != nil else { return }
        let point = NSEvent.mouseLocation
        let inside: Bool
        if isOpen {
            inside = openRect.contains(point)
        } else if incomingDrag {
            inside = dropZone.contains(point)
        } else {
            inside = !store.items.isEmpty && hoverRect.contains(point)
        }

        // Outside the visible shape the window must not swallow clicks or drops meant for whatever is underneath.
        panel.ignoresMouseEvents = !inside
        guard inside != pointerInside else { return }
        pointerInside = inside

        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.isOpen = inside
                self?.apply()
            }
        }
        pending = work
        // A short dwell before opening so passing by doesn't trigger it; none of that patience while carrying a file.
        let delay = inside ? (incomingDrag ? 0.04 : 0.12) : 0.35
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Settles the visible mode from what is known right now.
    private func apply() {
        let mode: Mode
        if isOpen {
            mode = .open
        } else if incomingDrag {
            mode = .hint
        } else {
            mode = store.items.isEmpty ? .hidden : .ear
        }

        if mode != state.mode {
            if mode == .open { store.refresh() }
            state.mode = mode
        }

        let covering = mode == .open || mode == .hint
        if covering != announcedCovering {
            announcedCovering = covering
            Presence.post(covering ? Presence.covering : Presence.clear)
        }

        // Mouse-moved events aren't guaranteed while the pointer rests over our own panel or during a drag session.
        let needsPolling = isOpen || incomingDrag || draggingOut
        if needsPolling, pollTimer == nil {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !needsPolling {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func poll() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            // The button is up, so any drag is over even if its ending was never reported.
            endIncomingDrag()
            if draggingOut {
                draggingOut = false
                apply()
            }
        }
        pointerMoved()
    }

    // MARK: Dropping in

    private func dropAllowed() -> Bool {
        guard !draggingOut else { return false }
        return (isOpen ? openRect : dropZone).contains(NSEvent.mouseLocation)
    }

    private func receive(_ info: NSDraggingInfo) -> Bool {
        let pasteboard = info.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            store.add(urls)
            return true
        }

        // No file on disk yet: ask the source to write one into the shelf's own folder.
        guard let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
              !receivers.isEmpty else { return false }
        let destination = store.makeDropDirectory()
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: promiseQueue) { [weak self] url, error in
                guard error == nil else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { _ = self?.store.add([url], owned: true) }
                }
            }
        }
        return true
    }

    // MARK: Dragging out

    private func beginDrag(_ ids: [UUID], from view: NSView, event: NSEvent) {
        let items = store.items.filter { ids.contains($0.id) }
        guard !items.isEmpty, !draggingOut else { return }
        let origin = view.convert(event.locationInWindow, from: nil)

        let dragItems = items.enumerated().map { index, item -> NSDraggingItem in
            let dragItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let icon = Thumbnailer.cached(item.url) ?? Thumbnailer.icon(for: item.url)
            let step = CGFloat(min(index, 4)) * 5
            dragItem.setDraggingFrame(NSRect(x: origin.x - 24 + step, y: origin.y - 24 - step, width: 48, height: 48), contents: icon)
            return dragItem
        }

        draggingOut = true
        draggedIDs = Set(items.map(\.id))
        apply()
        let session = view.beginDraggingSession(with: dragItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        if dragItems.count > 1 { session.draggingFormation = .pile }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Finder decides between move and copy the way it would for any file; inside the shelf there is nowhere to drop.
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggingOut = false
        if !operation.isEmpty, !keepAfterDragOut {
            store.remove(draggedIDs)
        }
        draggedIDs = []
        // The file may have just been moved; pick up its new place.
        store.refresh()
        apply()
        pointerMoved()
    }

    // MARK: Item actions

    private func item(_ id: UUID) -> ShelfItem? {
        store.items.first { $0.id == id }
    }

    private func openItem(_ id: UUID) {
        guard let item = item(id) else { return }
        NSWorkspace.shared.open(item.url)
    }

    @objc private func menuOpenItem(_ sender: NSMenuItem) {
        (sender.representedObject as? UUID).map(openItem)
    }

    @objc private func menuReveal(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let item = item(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let item = item(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item.url as NSURL])
    }

    @objc private func menuRemove(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        store.remove([id])
    }

    // MARK: Menus

    private func installStatusItem() {
        // An empty shelf shows nothing at the notch, so the menu bar is the one place the app can always be reached.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "tray", accessibilityDescription: "Notchshelf")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        fillAppMenu(menu)
    }

    private func fillAppMenu(_ menu: NSMenu) {
        let count = store.items.count
        let summary = NSMenuItem(title: count == 0 ? "Shelf is empty" : (count == 1 ? "1 file on the shelf" : "\(count) files on the shelf"),
                                 action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        let clear = NSMenuItem(title: "Clear Shelf", action: count == 0 ? nil : #selector(clearShelf), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())

        let keep = NSMenuItem(title: "Keep Files After Dragging Out", action: #selector(toggleKeep), keyEquivalent: "")
        keep.target = self
        keep.state = keepAfterDragOut ? .on : .off
        menu.addItem(keep)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Notchshelf", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    private func itemMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, Selector)] = [
            ("Open", #selector(menuOpenItem(_:))),
            ("Show in Finder", #selector(menuReveal(_:))),
            ("Copy", #selector(menuCopy(_:))),
        ]
        for (title, action) in entries {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.representedObject = id
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove from Shelf", action: #selector(menuRemove(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = id
        menu.addItem(remove)
        return menu
    }

    private func showMenu(for event: NSEvent) {
        guard let view = panel.contentView else { return }
        let point = view.convert(event.locationInWindow, from: nil)

        let menu: NSMenu
        if let tile = view.hitTest(point) as? InteractionNSView, tile.ids.count == 1, item(tile.ids[0]) != nil {
            menu = itemMenu(for: tile.ids[0])
        } else {
            menu = NSMenu()
            fillAppMenu(menu)
        }

        menuOpen = true
        menu.popUp(positioning: nil, at: point, in: view)
        menuOpen = false
        pointerMoved()
    }

    @objc private func clearShelf() {
        store.clear()
    }

    @objc private func toggleKeep() {
        keepAfterDragOut.toggle()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: ShelfController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        if let directory = value(after: "--snapshot") {
            Snapshot.render(to: directory, scale: value(after: "--scale").flatMap(Double.init).map { CGFloat($0) } ?? 2)
            return
        }

        // --store keeps a development run away from the real shelf.
        let store = value(after: "--store").map { ShelfStore(directory: URL(fileURLWithPath: $0)) } ?? ShelfStore()
        if let i = args.firstIndex(of: "--add") {
            store.add(args[(i + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) })
        }
        let controller = ShelfController(store: store)
        self.controller = controller
        controller.start()
    }

    // Files dropped on the app icon, or sent with `open -a Notchshelf <file>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        controller?.store.add(urls.filter(\.isFileURL))
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
