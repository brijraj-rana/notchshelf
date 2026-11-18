import AppKit
import Carbon.HIToolbox
import NotchshelfCore
import Quartz

// MARK: Global shortcut

/// One system-wide shortcut, registered through Carbon so it needs no accessibility permission.
@MainActor
final class HotKey {
    var onPress: () -> Void = {}

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// Replaces whatever was registered. Passing nil turns the shortcut off. False means the system refused it.
    @discardableResult
    func register(_ shortcut: Shortcut?) -> Bool {
        unregister()
        guard let shortcut else { return true }
        installHandler()

        let id = EventHotKeyID(signature: 0x4E_53_48_46, id: 1)    // "NSHF"
        var registered: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.modifiers.carbonFlags, id,
                                         GetApplicationEventTarget(), 0, &registered)
        guard status == noErr, let registered else { return false }
        ref = registered
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // A C callback cannot capture, so the object travels through the user data pointer. It lives as long as the app.
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.onPress() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}

// MARK: Keyboard focus

/// An invisible panel that holds keyboard focus on the shelf's behalf.
///
/// The shelf itself never becomes key: it is always on screen, and a window has to leave the screen to hand
/// focus back. This one is ordered in to take the keys and ordered out to return them to whichever window
/// had them, and because it is a non-activating panel the app in front stays in front throughout.
final class KeyPanel: NSPanel {
    weak var controller: ShelfController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    // Keys the shelf has no use for end here quietly instead of beeping.
    override func keyDown(with event: NSEvent) {}

    // Quick Look looks for its controller along the responder chain of the key window, which is this one.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { controller != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { controller?.previewBegan(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { controller?.previewControlEnded(panel) }
}

extension ShelfController {
    /// Held open by something other than the pointer being over it.
    var heldOpen: Bool { keyboardOpen || previewing || recording }

    /// The item a key acts on right now.
    var targetID: UUID? {
        let known = Set(store.items.map(\.id))
        return ShelfSelection.target(selected: state.selection.flatMap { known.contains($0) ? $0 : nil },
                                     hovered: hoveredID.flatMap { known.contains($0) ? $0 : nil })
    }

    private var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    func makeKeyPanel() -> KeyPanel {
        let keys = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        keys.controller = self
        keys.level = panel.level
        keys.collectionBehavior = panel.collectionBehavior
        keys.alphaValue = 0
        keys.isOpaque = false
        keys.backgroundColor = .clear
        keys.hasShadow = false
        keys.hidesOnDeactivate = false
        keys.ignoresMouseEvents = true
        keys.isReleasedWhenClosed = false
        keys.setAccessibilityLabel("Notchshelf")
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: keys, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyFocusLost() }
        }
        return keys
    }

    /// Takes the keyboard while the shelf can use it and gives it back the moment it cannot.
    ///
    /// That is: while it was opened from the keyboard, while a shortcut is being recorded, or while it is open
    /// with the pointer resting inside. Never during a drag in either direction, so the app being dragged
    /// into keeps its focus, and never again after focus was taken away until the pointer has left and come back.
    func updateKeyFocus() {
        guard !previewing else { return }       // Quick Look has the keys
        let hovering = isOpen && pointerInside && !incomingDrag && !draggingOut && !keyYielded
        let want = recording || keyboardOpen || hovering
        hasKeyFocus = want
        if want {
            guard !keyPanel.isKeyWindow else { return }
            keyPanel.orderFrontRegardless()
            keyPanel.makeKey()
        } else {
            if keyPanel.isVisible { keyPanel.orderOut(nil) }
            // Quick Look made this app active; hand that back too, unless the user has already gone elsewhere.
            if let app = previousApp {
                previousApp = nil
                if isFrontmost, !app.isTerminated {
                    NSApp.yieldActivation(to: app)
                    app.activate()
                }
            }
        }
    }

    /// Another window took the keys without being asked to: a click elsewhere, Command-Tab, a new window.
    private func keyFocusLost() {
        // A menu of ours may borrow the keys while it is up; that is not the user leaving.
        guard hasKeyFocus, !previewing, !menuOpen else { return }
        hasKeyFocus = false
        keyYielded = true
        if recording {
            endRecording(instant: false)
        } else if keyboardOpen {
            closeShelf(instant: false)
        }
    }

    // MARK: Opening and closing

    func setOpen(_ open: Bool, after delay: Double) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.heldOpen else { return }
                self.isOpen = open
                if !open {
                    self.state.selection = nil
                    self.state.notice = nil
                }
                self.state.instant = false
                self.apply()
                self.updateKeyFocus()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Once nothing holds the shelf open any more, it goes back to following the pointer.
    func settle() {
        guard !heldOpen, isOpen, !pointerInside else { return }
        setOpen(false, after: 0.35)
    }

    func toggleFromShortcut() {
        guard !recording else { return }
        if isOpen || previewing {
            closeShelf(instant: true)
        } else {
            openFromKeyboard(instant: true)
        }
    }

    func openFromKeyboard(instant: Bool) {
        pending?.cancel()
        keyboardOpen = true
        isOpen = true
        keyYielded = false
        state.instant = instant
        apply()
        state.selection = store.items.first?.id
        updateKeyFocus()
    }

    func closeShelf(instant: Bool) {
        if previewing { QLPreviewPanel.shared().orderOut(nil) }
        pending?.cancel()
        keyboardOpen = false
        isOpen = false
        state.selection = nil
        state.notice = nil
        state.instant = instant
        apply()
        updateKeyFocus()
        pointerMoved()      // the closed shape is smaller; stop taking clicks outside it
    }

    // MARK: Keys

    /// Every key press that reaches this app passes through here first. True means it was used.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = ShortcutModifiers(cocoaFlags: event.modifierFlags.rawValue)
        if recording {
            if event.type == .flagsChanged {
                if state.recorder.phase != .saved { state.recorder.held = modifiers.glyphs }
                return false
            }
            record(event, modifiers: modifiers)
            return true
        }
        // With Quick Look up the keys arrive on its panel; otherwise only the ones meant for the shelf count.
        guard event.type == .keyDown, previewing || event.window === keyPanel else { return false }

        let stroke = KeyStroke(keyCode: event.keyCode, modifiers: modifiers,
                               character: event.charactersIgnoringModifiers?.lowercased() ?? "", isRepeat: event.isARepeat)
        let context = ShelfKeys.Context(isOpen: isOpen, previewing: previewing, hasTarget: targetID != nil, count: store.items.count)
        guard let command = ShelfKeys.command(for: stroke, in: context) else { return false }
        state.instant = true
        perform(command)
        return true
    }

    private func perform(_ command: ShelfCommand) {
        let items = store.items
        let target = targetID
        let index = target.flatMap { id in items.firstIndex { $0.id == id } }

        switch command {
        case .preview:
            if let target { showPreview(of: target) }
        case .closePreview:
            QLPreviewPanel.shared().orderOut(nil)
        case .move(let step, let held):
            if previewing {
                let panel = QLPreviewPanel.shared()!
                guard let next = ShelfSelection.move(from: panel.currentPreviewItemIndex, by: step, count: items.count, isRepeat: held) else { return }
                previewStart = next
                panel.currentPreviewItemIndex = next
                state.selection = items[next].id
            } else if let next = ShelfSelection.move(from: index, by: step, count: items.count, isRepeat: held) {
                state.selection = items[next].id
            }
        case .open:
            guard let target else { return }
            previousApp = nil       // the app that opens the file comes forward instead
            openItem(target)
            closeShelf(instant: true)
        case .copy:
            guard let target else { return }
            copyItem(target)
            flash("Copied")
        case .paste:
            switch shelve(from: .general, acceptingPromises: false) {
            case .added:
                if keyboardOpen { state.selection = store.items.first?.id }
            case .alreadyHere:
                flash("Already here")
            case .waiting, .nothing:
                flash("Nothing to paste")
            }
        case .remove:
            guard let target, let index else { return }
            let follow = keyboardOpen || state.selection == target
            store.remove([target])
            if follow {
                state.selection = ShelfSelection.afterRemoval(at: index, remaining: store.items.count).map { store.items[$0].id }
            }
        case .close:
            closeShelf(instant: true)
        }
    }

    /// The pointer moved onto or off a tile.
    func hover(_ id: UUID, _ inside: Bool) {
        if inside {
            hoveredID = id
            if !previewing { state.selection = ShelfSelection.afterHover(over: id, keyboardOpen: keyboardOpen) }
        } else if hoveredID == id {
            hoveredID = nil
        }
    }

    func flash(_ notice: String) {
        noticeTimer?.cancel()
        state.notice = notice
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.state.notice = nil }
        }
        noticeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    // MARK: Recording a shortcut

    var shortcutSetting: ShortcutSetting {
        get { ShortcutSetting(stored: UserDefaults.standard.string(forKey: ShortcutSetting.defaultsKey)) }
        set { UserDefaults.standard.set(newValue.stored, forKey: ShortcutSetting.defaultsKey) }
    }

    func beginRecording() {
        guard !recording else { return }
        if isOpen || previewing { closeShelf(instant: false) }
        pending?.cancel()
        recording = true
        keyYielded = false
        hotKey.unregister()     // so pressing the shortcut in use records it again instead of firing it
        state.recorder = RecorderState(keys: shortcutSetting.shortcut?.parts ?? [])
        state.instant = false
        apply()
        updateKeyFocus()
    }

    private func record(_ event: NSEvent, modifiers: ShortcutModifiers) {
        guard event.type == .keyDown, !event.isARepeat, state.recorder.phase != .saved else { return }
        let typed = event.charactersIgnoringModifiers ?? ""
        let printable = typed.count == 1 && typed.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0xF700 && $0.value != 0x7F }

        switch ShortcutRecorder.result(keyCode: event.keyCode, modifiers: modifiers, label: printable ? typed : nil) {
        case .cancel:
            endRecording(instant: true)
        case .needsModifier:
            state.recorder.phase = .rejected("Add Control or Command")
        case .accept(let shortcut):
            guard hotKey.register(shortcut) else {
                state.recorder.phase = .rejected("That one is taken. Try another")
                return
            }
            shortcutSetting = .on(shortcut)
            state.recorder = RecorderState(keys: shortcut.parts, phase: .saved)
            // Long enough to read it back, then the panel leaves by itself.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.endRecording(instant: false) }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
        }
    }

    func endRecording(instant: Bool) {
        guard recording else { return }
        pending?.cancel()
        recording = false
        hotKey.register(shortcutSetting.shortcut)
        state.instant = instant
        apply()
        updateKeyFocus()
        pointerMoved()
    }

    // MARK: Quick Look

    func showPreview(of id: UUID) {
        guard !previewing, let index = store.items.firstIndex(where: { $0.id == id }) else { return }
        pending?.cancel()
        previewing = true
        previewStart = index
        state.selection = id
        if !isOpen {
            isOpen = true
            apply()
        }

        // Quick Look's panel can only take the keys in an active app, so step forward for as long as it is up.
        if !isFrontmost, previousApp == nil { previousApp = NSWorkspace.shared.frontmostApplication }
        NSApp.activate(ignoringOtherApps: true)
        let preview = QLPreviewPanel.shared()!
        if previewClose == nil {
            previewClose = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: preview, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.previewEnded() }
            }
        }
        preview.makeKeyAndOrderFront(nil)
        if preview.currentController == nil {
            // Nothing along the responder chain claimed the panel, so claim it directly.
            previewBegan(preview)
        }
    }

    /// Quick Look hands control over more than once in one showing: first to the key panel that had the keys,
    /// then, once its own panel has them, to the app delegate. Each time it starts from the item last shown.
    func previewBegan(_ preview: QLPreviewPanel) {
        guard previewing else { return }
        preview.dataSource = self
        preview.delegate = self
        preview.reloadData()
        if previewStart < store.items.count { preview.currentPreviewItemIndex = previewStart }
        // The panel has its own next and previous buttons; keep the shelf's selection in step with them.
        previewIndex = preview.observe(\.currentPreviewItemIndex) { [weak self] preview, _ in
            MainActor.assumeIsolated {
                guard let self, self.previewing else { return }
                let index = preview.currentPreviewItemIndex
                guard self.store.items.indices.contains(index) else { return }
                self.previewStart = index
                self.state.selection = self.store.items[index].id
            }
        }
    }

    /// Either a handover (see above) or the panel closing. Only the second ends the preview.
    func previewControlEnded(_ preview: QLPreviewPanel) {
        previewIndex = nil      // the panel goes back to its first item as it lets go, which is not a selection
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if !preview.isVisible { self?.previewEnded() }
            }
        }
    }

    func previewEnded() {
        guard previewing else { return }
        previewing = false
        previewIndex = nil
        if !keyboardOpen { state.selection = nil }
        updateKeyFocus()
        settle()
    }

    /// The shelf changed underneath an open preview.
    func previewItemsChanged() {
        guard previewing else { return }
        if store.items.isEmpty {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            QLPreviewPanel.shared().reloadData()
        }
    }

    /// Where a tile's thumbnail sits on screen, or an empty rect when it cannot be seen.
    private func thumbnailFrame(of item: ShelfItem) -> NSRect {
        guard isOpen, state.mode == .open, let root = panel.contentView,
              let tile = Self.tile(for: item.id, in: root), let window = tile.window else { return .zero }
        let frame = window.convertToScreen(tile.convert(tile.bounds, to: nil))
        // The thumbnail is fitted into a 62 by 54 box, 6 points down from the top of the tile.
        let box = NSRect(x: frame.midX - 31, y: frame.maxY - 6 - 54, width: 62, height: 54)
        guard openRect.contains(NSPoint(x: box.midX, y: box.midY)) else { return .zero }     // scrolled out of sight

        let size = (Thumbnailer.cached(item.url) ?? Thumbnailer.icon(for: item.url)).size
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    static func tile(for id: UUID, in view: NSView) -> InteractionNSView? {
        if let tile = view as? InteractionNSView, tile.ids == [id] { return tile }
        for child in view.subviews {
            if let found = tile(for: id, in: child) { return found }
        }
        return nil
    }

    fileprivate func shelfItem(for preview: QLPreviewItem?) -> ShelfItem? {
        guard let url = (preview as? NSURL) as URL? else { return nil }
        return store.items.first { $0.url == url }
    }
}

extension ShelfController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        store.items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        store.items.indices.contains(index) ? store.items[index].url as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        shelfItem(for: item).map(thumbnailFrame) ?? .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        shelfItem(for: item).map { Thumbnailer.cached($0.url) ?? Thumbnailer.icon(for: $0.url) }
    }
}
