import AppKit
import Combine
import NotchshelfCore
import Quartz
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

    var panel: NotchPanel!
    var keyPanel: KeyPanel!
    let hotKey = HotKey()
    private var statusItem: NSStatusItem?
    private var subscriptions: Set<AnyCancellable> = []

    // Hit areas in screen coordinates.
    private var hoverRect = NSRect.zero      // opens the shelf while it is holding files
    private var dropZone = NSRect.zero       // opens the shelf while a file is being dragged
    var openRect = NSRect.zero               // keeps it open

    var pointerInside = false
    var isOpen = false
    var pending: DispatchWorkItem?
    private var pollTimer: Timer?
    var menuOpen = false
    private var announcedCovering = false

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragChangeCount = 0
    var incomingDrag = false                 // someone is dragging files around the screen
    var draggingOut = false                  // the drag in progress started on the shelf
    private var draggedIDs: Set<UUID> = []
    private let promiseQueue = OperationQueue()

    // Keyboard. See Keyboard.swift.
    var keyboardOpen = false                 // opened with the shortcut: stays open until told otherwise
    var previewing = false                   // Quick Look is showing
    var recording = false                    // waiting for a new shortcut
    var hasKeyFocus = false
    var keyYielded = false                   // focus was taken away; leave it alone until the pointer comes back
    var hoveredID: UUID?
    var previousApp: NSRunningApplication?   // who to hand the front back to after Quick Look
    var previewStart = 0
    var previewIndex: NSKeyValueObservation?
    var previewClose: NSObjectProtocol?
    var noticeTimer: DispatchWorkItem?

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
        actions.hover = { [weak self] id, inside in self?.hover(id, inside) }
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
        keyPanel = makeKeyPanel()

        layout()
        apply()
        panel.orderFrontRegardless()
        installStatusItem()

        hotKey.onPress = { [weak self] in self?.toggleFromShortcut() }
        hotKey.register(shortcutSetting.shortcut)

        // Published values arrive before they are stored, so read them on the next turn.
        store.$items
            .map(\.isEmpty)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &subscriptions)
        store.$items
            .map { $0.map(\.id) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.previewItemsChanged() }
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
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return used ? nil : event
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
        hotKey.unregister()
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
        keyPanel.setFrame(NSRect(x: midX, y: top - 1, width: 1, height: 1), display: false)

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
        state.instant = false       // the pointer is driving again, so things may move
        switch event.type {
        case .leftMouseDown:
            dragChangeCount = dragPasteboard.changeCount
            // A shelf opened from the keyboard has no pointer to follow away, so a click anywhere else closes it.
            if keyboardOpen, !previewing, !openRect.contains(NSEvent.mouseLocation) {
                closeShelf(instant: false)
            }
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

    func pointerMoved() {
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
        if inside != pointerInside {
            pointerInside = inside
            if !inside { keyYielded = false }
            // While the keyboard, Quick Look or the recorder holds the shelf, the pointer coming and going changes nothing.
            if !pinned {
                // A short dwell before opening so passing by doesn't trigger it; none of that patience while carrying a file.
                setOpen(inside, after: inside ? (incomingDrag ? 0.04 : 0.12) : 0.35)
            }
        }
        updateKeyFocus()
    }

    /// Settles the visible mode from what is known right now.
    func apply() {
        let mode: Mode
        if recording {
            mode = .recording
        } else if isOpen {
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

        let covering = mode == .open || mode == .hint || mode == .recording
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
        // From here the shelf follows the pointer again, and the app being dragged into gets its keys back.
        keyboardOpen = false
        state.selection = nil
        apply()
        updateKeyFocus()
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

    func openItem(_ id: UUID) {
        guard let item = item(id) else { return }
        NSWorkspace.shared.open(item.url)
    }

    func copyItem(_ id: UUID) {
        guard let item = item(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item.url as NSURL])
    }

    @objc private func menuQuickLook(_ sender: NSMenuItem) {
        (sender.representedObject as? UUID).map(showPreview(of:))
    }

    @objc private func menuOpenItem(_ sender: NSMenuItem) {
        (sender.representedObject as? UUID).map(openItem)
    }

    @objc private func menuReveal(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let item = item(id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        (sender.representedObject as? UUID).map(copyItem)
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

        let shortcut = shortcutSetting.shortcut
        let open = NSMenuItem(title: "Open Shelf", action: #selector(openShelf), keyEquivalent: shortcut.flatMap(Self.keyEquivalent) ?? "")
        open.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: shortcut?.modifiers.cocoaFlags ?? 0)
        open.target = self
        menu.addItem(open)

        let clear = NSMenuItem(title: "Clear Shelf", action: count == 0 ? nil : #selector(clearShelf), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())

        let change = NSMenuItem(title: shortcut == nil ? "Set Shortcut…" : "Change Shortcut…", action: #selector(changeShortcut), keyEquivalent: "")
        change.target = self
        menu.addItem(change)
        if shortcut != nil {
            let off = NSMenuItem(title: "Turn Off Shortcut", action: #selector(turnOffShortcut), keyEquivalent: "")
            off.target = self
            menu.addItem(off)
        }
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
            ("Quick Look", #selector(menuQuickLook(_:))),
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

    /// What AppKit needs to draw a shortcut beside a menu item, or nil for a key it has no glyph for.
    private static func keyEquivalent(for shortcut: Shortcut) -> String? {
        func special(_ code: Int) -> String? { UnicodeScalar(code).map { String(Character($0)) } }
        if let number = KeyCode.functionNumber(shortcut.keyCode) { return special(NSF1FunctionKey + number - 1) }
        switch shortcut.keyCode {
        case KeyCode.space: return " "
        case KeyCode.returnKey: return "\r"
        case KeyCode.tab: return "\t"
        case KeyCode.delete: return "\u{8}"
        case KeyCode.forwardDelete: return special(NSDeleteFunctionKey)
        case KeyCode.left: return special(NSLeftArrowFunctionKey)
        case KeyCode.right: return special(NSRightArrowFunctionKey)
        case KeyCode.up: return special(NSUpArrowFunctionKey)
        case KeyCode.down: return special(NSDownArrowFunctionKey)
        default:
            let name = shortcut.keyName
            return name.count == 1 ? name.lowercased() : nil
        }
    }

    @objc private func openShelf() {
        guard !recording, !previewing, !keyboardOpen else { return }
        openFromKeyboard(instant: false)
    }

    @objc private func changeShortcut() {
        beginRecording()
    }

    @objc private func turnOffShortcut() {
        shortcutSetting = .off
        hotKey.register(nil)
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

    // Quick Look asks the key window first and the app delegate last. Once its own panel has the keys
    // this is the only place left for it to ask, so the shelf answers here as well as on the key panel.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { controller != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { controller?.previewBegan(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { controller?.previewControlEnded(panel) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
