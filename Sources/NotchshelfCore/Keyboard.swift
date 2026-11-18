import Foundation

// Everything the keyboard does to the shelf, kept free of AppKit so it can be tested:
// where the selection goes, what a shortcut is and how it is stored, and which key does what.

// MARK: Selection

public enum ShelfSelection {
    /// Where the selection lands after an arrow key. `step` is -1 for left and 1 for right.
    ///
    /// With nothing selected, right starts at the first item and left at the last.
    /// A fresh press at either end wraps around; a held key stops there instead of spinning.
    public static func move(from current: Int?, by step: Int, count: Int, isRepeat: Bool = false) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else {
            return step < 0 ? count - 1 : 0
        }
        let next = current + step
        if (0..<count).contains(next) { return next }
        if isRepeat { return current }
        return step < 0 ? count - 1 : 0
    }

    /// Where the selection lands once the item at `index` has left a shelf that now holds `remaining` items:
    /// on the item that slid into its place, or on the new last item.
    public static func afterRemoval(at index: Int, remaining: Int) -> Int? {
        guard remaining > 0 else { return nil }
        return min(max(index, 0), remaining - 1)
    }

    /// The item a key acts on. A selection made with the keyboard wins over whatever the pointer rests on.
    public static func target<ID>(selected: ID?, hovered: ID?) -> ID? {
        selected ?? hovered
    }

    /// The selection after the pointer moves onto an item. A shelf opened from the keyboard keeps one item
    /// selected, so the selection follows the pointer; a shelf opened by hovering goes back to plain hover.
    public static func afterHover<ID>(over item: ID, keyboardOpen: Bool) -> ID? {
        keyboardOpen ? item : nil
    }
}

// MARK: Shortcut

public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)

    /// In the order macOS writes them.
    private static let table: [(ShortcutModifiers, name: String, glyph: String, cocoa: UInt, carbon: UInt32)] = [
        (.control, "control", "⌃", 1 << 18, 4096),
        (.option, "option", "⌥", 1 << 19, 2048),
        (.shift, "shift", "⇧", 1 << 17, 512),
        (.command, "command", "⌘", 1 << 20, 256),
    ]

    /// From `NSEvent.ModifierFlags.rawValue`. Caps Lock, Fn and the rest are ignored.
    public init(cocoaFlags: UInt) {
        self = Self.table.reduce(into: []) { result, entry in
            if cocoaFlags & entry.cocoa != 0 { result.insert(entry.0) }
        }
    }

    /// For `NSEvent.ModifierFlags(rawValue:)`.
    public var cocoaFlags: UInt {
        Self.table.reduce(UInt(0)) { contains($1.0) ? $0 | $1.cocoa : $0 }
    }

    /// For Carbon's `RegisterEventHotKey`.
    public var carbonFlags: UInt32 {
        Self.table.reduce(UInt32(0)) { contains($1.0) ? $0 | $1.carbon : $0 }
    }

    public var glyphs: [String] {
        Self.table.filter { contains($0.0) }.map(\.glyph)
    }

    var names: [String] {
        Self.table.filter { contains($0.0) }.map(\.name)
    }

    init?(names: [String]) {
        var result: ShortcutModifiers = []
        for name in names {
            guard let entry = Self.table.first(where: { $0.name == name }), !result.contains(entry.0) else { return nil }
            result.insert(entry.0)
        }
        self = result
    }
}

/// Hardware key codes, which do not change with the keyboard layout.
public enum KeyCode {
    public static let s: UInt16 = 1
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let keypadEnter: UInt16 = 76
    public static let forwardDelete: UInt16 = 117
    public static let left: UInt16 = 123
    public static let right: UInt16 = 124
    public static let down: UInt16 = 125
    public static let up: UInt16 = 126

    static let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    /// 1 for F1 up to 20 for F20, nil for any other key.
    public static func functionNumber(_ code: UInt16) -> Int? {
        functionKeys.firstIndex(of: code).map { $0 + 1 }
    }

    /// Keys that read the same on every layout.
    static let named: [UInt16: String] = [
        returnKey: "↩", tab: "⇥", space: "Space", delete: "⌫", escape: "⎋", keypadEnter: "⌤", forwardDelete: "⌦",
        left: "←", right: "→", down: "↓", up: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    /// What the key prints on a US keyboard, for when the layout's own character is not known.
    static let printed: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
    ]
}

/// A key and the modifiers held with it.
public struct Shortcut: Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers
    /// The character the key produced on the keyboard layout it was recorded with, for display only.
    public var label: String?

    public init(keyCode: UInt16, modifiers: ShortcutModifiers, label: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// Control-Option-S. Control-Option-Space would read better, but macOS gives that one to
    /// "Select next source in Input menu" on any Mac with a second keyboard layout.
    public static let standard = Shortcut(keyCode: KeyCode.s, modifiers: [.control, .option])

    public var keyName: String {
        if let name = KeyCode.named[keyCode] { return name }
        if let number = KeyCode.functionNumber(keyCode) { return "F\(number)" }
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return label.uppercased() }
        return KeyCode.printed[keyCode] ?? "Key \(keyCode)"
    }

    /// One entry per keycap: the modifiers, then the key.
    public var parts: [String] { modifiers.glyphs + [keyName] }

    // Stored as "control+option:1:S": modifier names, the key code, then the optional label.
    // The label comes last because it may itself be a colon.

    public var encoded: String {
        let names = modifiers.names
        var text = (names.isEmpty ? "none" : names.joined(separator: "+")) + ":\(keyCode)"
        if let label, !label.isEmpty { text += ":" + label }
        return text
    }

    public init?(encoded: String) {
        let fields = encoded.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2, let code = UInt16(fields[1]) else { return nil }
        let names = fields[0] == "none" ? [] : fields[0].split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let modifiers = ShortcutModifiers(names: names) else { return nil }
        let label = fields.count == 3 && !fields[2].isEmpty ? String(fields[2]) : nil
        self.init(keyCode: code, modifiers: modifiers, label: label)
    }
}

/// What the user chose for the global shortcut, as it is kept in UserDefaults.
public enum ShortcutSetting: Equatable, Sendable {
    case off
    case on(Shortcut)

    public static let defaultsKey = "shortcut"

    /// Nothing stored, or something unreadable, means the standard shortcut.
    public init(stored: String?) {
        if stored == "off" {
            self = .off
        } else {
            self = .on(stored.flatMap(Shortcut.init(encoded:)) ?? .standard)
        }
    }

    public var stored: String {
        switch self {
        case .off: return "off"
        case .on(let shortcut): return shortcut.encoded
        }
    }

    public var shortcut: Shortcut? {
        if case .on(let shortcut) = self { return shortcut }
        return nil
    }
}

/// Decides what one key press means while a new shortcut is being recorded.
public enum ShortcutRecorder {
    public enum Result: Equatable {
        case cancel
        case accept(Shortcut)
        /// A plain key, or one with only Shift or Option, would get in the way of ordinary typing.
        case needsModifier
    }

    public static func result(keyCode: UInt16, modifiers: ShortcutModifiers, label: String? = nil) -> Result {
        if keyCode == KeyCode.escape, modifiers.isEmpty { return .cancel }
        let shortcut = Shortcut(keyCode: keyCode, modifiers: modifiers, label: label)
        if KeyCode.functionNumber(keyCode) != nil { return .accept(shortcut) }
        return modifiers.isDisjoint(with: [.control, .command]) ? .needsModifier : .accept(shortcut)
    }
}

// MARK: Keys

/// One key press as the shelf sees it.
public struct KeyStroke: Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers
    /// The character the key types on the current layout, lowercased. Command-C is matched on this, not the key code.
    public var character: String
    public var isRepeat: Bool

    public init(keyCode: UInt16, modifiers: ShortcutModifiers = [], character: String = "", isRepeat: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.character = character
        self.isRepeat = isRepeat
    }
}

public enum ShelfCommand: Equatable, Sendable {
    case preview
    case closePreview
    /// Move the selection one item left (-1) or right (1). `held` is true for a key repeat.
    case move(Int, held: Bool)
    case open
    case copy
    case remove
    case close
}

public enum ShelfKeys {
    public struct Context: Equatable, Sendable {
        public var isOpen: Bool
        /// Quick Look is showing.
        public var previewing: Bool
        /// Something is selected or under the pointer.
        public var hasTarget: Bool
        public var count: Int

        public init(isOpen: Bool, previewing: Bool = false, hasTarget: Bool = false, count: Int = 0) {
            self.isOpen = isOpen
            self.previewing = previewing
            self.hasTarget = hasTarget
            self.count = count
        }
    }

    /// What a key does right now, or nil when the shelf has no use for it and it should carry on to whoever does.
    public static func command(for key: KeyStroke, in context: Context) -> ShelfCommand? {
        guard context.isOpen else { return nil }
        let plain = key.modifiers.isEmpty
        let arrow: Int? = key.keyCode == KeyCode.left ? -1 : (key.keyCode == KeyCode.right ? 1 : nil)

        if context.previewing {
            // Quick Look keeps every other key: scrolling, zooming, its own shortcuts.
            if plain, key.keyCode == KeyCode.space || key.keyCode == KeyCode.escape {
                return key.isRepeat ? nil : .closePreview
            }
            if plain, let arrow, context.count > 1 { return .move(arrow, held: key.isRepeat) }
            return nil
        }

        if plain, key.keyCode == KeyCode.escape { return .close }
        if plain, let arrow { return context.count > 0 ? .move(arrow, held: key.isRepeat) : nil }

        // Everything else acts on one item, and only on a deliberate press.
        guard context.hasTarget, !key.isRepeat else { return nil }
        if key.modifiers == .command {
            if key.character == "c" { return .copy }
            if key.keyCode == KeyCode.delete { return .remove }
            return nil
        }
        guard plain else { return nil }
        switch key.keyCode {
        case KeyCode.space: return .preview
        case KeyCode.returnKey, KeyCode.keypadEnter: return .open
        case KeyCode.delete, KeyCode.forwardDelete: return .remove
        default: return nil
        }
    }
}
