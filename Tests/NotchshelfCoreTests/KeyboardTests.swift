import XCTest
@testable import NotchshelfCore

final class SelectionTests: XCTestCase {
    func testMovesOneStepAtATime() {
        XCTAssertEqual(ShelfSelection.move(from: 1, by: 1, count: 4), 2)
        XCTAssertEqual(ShelfSelection.move(from: 1, by: -1, count: 4), 0)
    }

    func testFirstArrowStartsAtTheNearEnd() {
        XCTAssertEqual(ShelfSelection.move(from: nil, by: 1, count: 4), 0)
        XCTAssertEqual(ShelfSelection.move(from: nil, by: -1, count: 4), 3)
    }

    func testAFreshPressWrapsAround() {
        XCTAssertEqual(ShelfSelection.move(from: 3, by: 1, count: 4), 0)
        XCTAssertEqual(ShelfSelection.move(from: 0, by: -1, count: 4), 3)
    }

    func testAHeldKeyStopsAtTheEnd() {
        XCTAssertEqual(ShelfSelection.move(from: 3, by: 1, count: 4, isRepeat: true), 3)
        XCTAssertEqual(ShelfSelection.move(from: 0, by: -1, count: 4, isRepeat: true), 0)
        XCTAssertEqual(ShelfSelection.move(from: 1, by: 1, count: 4, isRepeat: true), 2)
    }

    func testOneItemStaysSelected() {
        XCTAssertEqual(ShelfSelection.move(from: 0, by: 1, count: 1), 0)
        XCTAssertEqual(ShelfSelection.move(from: 0, by: -1, count: 1), 0)
    }

    func testAnEmptyShelfHasNoSelection() {
        XCTAssertNil(ShelfSelection.move(from: nil, by: 1, count: 0))
        XCTAssertNil(ShelfSelection.move(from: 2, by: -1, count: 0))
    }

    func testAStaleIndexStartsOver() {
        XCTAssertEqual(ShelfSelection.move(from: 9, by: 1, count: 3), 0)
        XCTAssertEqual(ShelfSelection.move(from: -1, by: -1, count: 3), 2)
    }

    func testRemovalSelectsTheItemThatTookItsPlace() {
        XCTAssertEqual(ShelfSelection.afterRemoval(at: 1, remaining: 3), 1)
        XCTAssertEqual(ShelfSelection.afterRemoval(at: 0, remaining: 3), 0)
    }

    func testRemovingTheLastItemSelectsTheNewLast() {
        XCTAssertEqual(ShelfSelection.afterRemoval(at: 3, remaining: 3), 2)
    }

    func testRemovingTheOnlyItemClearsTheSelection() {
        XCTAssertNil(ShelfSelection.afterRemoval(at: 0, remaining: 0))
    }

    func testTheSelectionWinsOverThePointer() {
        XCTAssertEqual(ShelfSelection.target(selected: "a", hovered: "b"), "a")
        XCTAssertEqual(ShelfSelection.target(selected: nil, hovered: "b"), "b")
        XCTAssertNil(ShelfSelection.target(selected: nil as String?, hovered: nil))
    }

    func testHoverTakesTheSelectionOnlyOnAKeyboardShelf() {
        XCTAssertEqual(ShelfSelection.afterHover(over: "b", keyboardOpen: true), "b")
        XCTAssertNil(ShelfSelection.afterHover(over: "b", keyboardOpen: false))
    }
}

final class ShortcutTests: XCTestCase {
    func testTheStandardShortcutIsControlOptionS() {
        XCTAssertEqual(Shortcut.standard.keyCode, 1)
        XCTAssertEqual(Shortcut.standard.modifiers, [.control, .option])
        XCTAssertEqual(Shortcut.standard.parts, ["⌃", "⌥", "S"])
    }

    func testModifiersReadCocoaFlags() {
        // NSEvent.ModifierFlags: shift 1 << 17, control 1 << 18, option 1 << 19, command 1 << 20.
        XCTAssertEqual(ShortcutModifiers(cocoaFlags: 1 << 18 | 1 << 19), [.control, .option])
        XCTAssertEqual(ShortcutModifiers(cocoaFlags: 1 << 17 | 1 << 20), [.shift, .command])
        // Caps Lock (1 << 16), the number pad (1 << 21) and Fn (1 << 23) are not modifiers a shortcut can use.
        XCTAssertEqual(ShortcutModifiers(cocoaFlags: 1 << 16 | 1 << 21 | 1 << 23), [])
    }

    func testModifiersRoundTripThroughCocoaFlags() {
        let all: ShortcutModifiers = [.control, .option, .shift, .command]
        XCTAssertEqual(ShortcutModifiers(cocoaFlags: all.cocoaFlags), all)
        XCTAssertEqual(ShortcutModifiers([.control, .option]).cocoaFlags, 1 << 18 | 1 << 19)
    }

    func testModifiersBecomeCarbonFlags() {
        // Carbon: cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096.
        XCTAssertEqual(ShortcutModifiers([.control, .option]).carbonFlags, 4096 + 2048)
        XCTAssertEqual(ShortcutModifiers([.command, .shift]).carbonFlags, 256 + 512)
        XCTAssertEqual(ShortcutModifiers([]).carbonFlags, 0)
    }

    func testGlyphsFollowTheSystemOrder() {
        XCTAssertEqual(ShortcutModifiers([.command, .shift, .option, .control]).glyphs, ["⌃", "⌥", "⇧", "⌘"])
    }

    func testEncodesAndDecodes() {
        let shortcut = Shortcut(keyCode: 1, modifiers: [.control, .option], label: "s")
        XCTAssertEqual(shortcut.encoded, "control+option:1:s")
        XCTAssertEqual(Shortcut(encoded: shortcut.encoded), shortcut)

        let bare = Shortcut(keyCode: 96, modifiers: [])
        XCTAssertEqual(bare.encoded, "none:96")
        XCTAssertEqual(Shortcut(encoded: bare.encoded), bare)

        let everything = Shortcut(keyCode: 49, modifiers: [.control, .option, .shift, .command])
        XCTAssertEqual(everything.encoded, "control+option+shift+command:49")
        XCTAssertEqual(Shortcut(encoded: everything.encoded), everything)
    }

    func testALabelMayBeAColon() {
        let shortcut = Shortcut(keyCode: 41, modifiers: [.command, .shift], label: ":")
        XCTAssertEqual(Shortcut(encoded: shortcut.encoded), shortcut)
    }

    func testRejectsWhatItCannotRead() {
        for text in ["", "control", "control+option", "control+hyper:1", "control:abc", "control+control:1", ":1", "control+:1", "control:70000"] {
            XCTAssertNil(Shortcut(encoded: text), text)
        }
    }

    func testKeyNames() {
        XCTAssertEqual(Shortcut(keyCode: KeyCode.space, modifiers: []).keyName, "Space")
        XCTAssertEqual(Shortcut(keyCode: KeyCode.returnKey, modifiers: []).keyName, "↩")
        XCTAssertEqual(Shortcut(keyCode: 122, modifiers: []).keyName, "F1")
        XCTAssertEqual(Shortcut(keyCode: 90, modifiers: []).keyName, "F20")
        // The layout's own character wins over the US one, except for keys that are the same everywhere.
        XCTAssertEqual(Shortcut(keyCode: 1, modifiers: [], label: "o").keyName, "O")
        XCTAssertEqual(Shortcut(keyCode: KeyCode.space, modifiers: [], label: " ").keyName, "Space")
        XCTAssertEqual(Shortcut(keyCode: 1, modifiers: []).keyName, "S")
        XCTAssertEqual(Shortcut(keyCode: 200, modifiers: []).keyName, "Key 200")
    }

    func testSettingFallsBackToTheStandardShortcut() {
        XCTAssertEqual(ShortcutSetting(stored: nil), .on(.standard))
        XCTAssertEqual(ShortcutSetting(stored: "nonsense"), .on(.standard))
    }

    func testSettingRemembersOffAndCustom() {
        XCTAssertEqual(ShortcutSetting(stored: ShortcutSetting.off.stored), .off)
        XCTAssertNil(ShortcutSetting.off.shortcut)

        let custom = Shortcut(keyCode: 49, modifiers: [.control, .shift])
        let setting = ShortcutSetting.on(custom)
        XCTAssertEqual(ShortcutSetting(stored: setting.stored), setting)
        XCTAssertEqual(setting.shortcut, custom)
    }

    func testRecorderCancelsOnEscape() {
        XCTAssertEqual(ShortcutRecorder.result(keyCode: KeyCode.escape, modifiers: []), .cancel)
        // With a modifier it is a shortcut like any other.
        XCTAssertEqual(ShortcutRecorder.result(keyCode: KeyCode.escape, modifiers: .control),
                       .accept(Shortcut(keyCode: KeyCode.escape, modifiers: .control)))
    }

    func testRecorderWantsControlOrCommand() {
        XCTAssertEqual(ShortcutRecorder.result(keyCode: 1, modifiers: []), .needsModifier)
        XCTAssertEqual(ShortcutRecorder.result(keyCode: 1, modifiers: .shift), .needsModifier)
        XCTAssertEqual(ShortcutRecorder.result(keyCode: 1, modifiers: [.option, .shift]), .needsModifier)
        XCTAssertEqual(ShortcutRecorder.result(keyCode: KeyCode.space, modifiers: []), .needsModifier)
        XCTAssertEqual(ShortcutRecorder.result(keyCode: 1, modifiers: [.control, .option], label: "s"),
                       .accept(Shortcut(keyCode: 1, modifiers: [.control, .option], label: "s")))
        XCTAssertEqual(ShortcutRecorder.result(keyCode: 1, modifiers: .command), .accept(Shortcut(keyCode: 1, modifiers: .command)))
    }

    func testRecorderTakesAFunctionKeyAlone() {
        XCTAssertEqual(ShortcutRecorder.result(keyCode: 96, modifiers: []), .accept(Shortcut(keyCode: 96, modifiers: [])))
    }
}

final class ShelfKeysTests: XCTestCase {
    private let open = ShelfKeys.Context(isOpen: true, hasTarget: true, count: 3)
    private let nothingTargeted = ShelfKeys.Context(isOpen: true, hasTarget: false, count: 3)
    private let previewing = ShelfKeys.Context(isOpen: true, previewing: true, hasTarget: true, count: 3)

    private func key(_ code: UInt16, _ modifiers: ShortcutModifiers = [], character: String = "", isRepeat: Bool = false) -> KeyStroke {
        KeyStroke(keyCode: code, modifiers: modifiers, character: character, isRepeat: isRepeat)
    }

    func testAClosedShelfUsesNoKeys() {
        let closed = ShelfKeys.Context(isOpen: false, hasTarget: true, count: 3)
        for code in [KeyCode.space, KeyCode.escape, KeyCode.left, KeyCode.returnKey, KeyCode.delete] {
            XCTAssertNil(ShelfKeys.command(for: key(code), in: closed))
        }
    }

    func testKeysOnAnOpenShelf() {
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.space), in: open), .preview)
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.returnKey), in: open), .open)
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.keypadEnter), in: open), .open)
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.delete), in: open), .remove)
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.forwardDelete), in: open), .remove)
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.delete, .command), in: open), .remove)
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.escape), in: open), .close)
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.left), in: open), .move(-1, held: false))
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.right), in: open), .move(1, held: false))
    }

    func testCopyFollowsTheLayoutNotTheKeyPosition() {
        XCTAssertEqual(ShelfKeys.command(for: key(8, .command, character: "c"), in: open), .copy)
        // Dvorak: the key that types C sits where QWERTY has I.
        XCTAssertEqual(ShelfKeys.command(for: key(34, .command, character: "c"), in: open), .copy)
        XCTAssertNil(ShelfKeys.command(for: key(8, .command, character: "j"), in: open))
        XCTAssertNil(ShelfKeys.command(for: key(8, character: "c"), in: open))
        XCTAssertNil(ShelfKeys.command(for: key(8, [.command, .shift], character: "c"), in: open))
    }

    func testItemKeysNeedAnItem() {
        for stroke in [key(KeyCode.space), key(KeyCode.returnKey), key(KeyCode.delete), key(8, .command, character: "c")] {
            XCTAssertNil(ShelfKeys.command(for: stroke, in: nothingTargeted))
        }
        // Moving and closing do not.
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.right), in: nothingTargeted), .move(1, held: false))
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.escape), in: nothingTargeted), .close)
    }

    func testAnEmptyShelfOnlyCloses() {
        let empty = ShelfKeys.Context(isOpen: true, hasTarget: false, count: 0)
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.escape), in: empty), .close)
        XCTAssertNil(ShelfKeys.command(for: key(KeyCode.right), in: empty))
        XCTAssertNil(ShelfKeys.command(for: key(KeyCode.space), in: empty))
    }

    func testAHeldKeyOnlyMoves() {
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.right, isRepeat: true), in: open), .move(1, held: true))
        for code in [KeyCode.space, KeyCode.returnKey, KeyCode.delete] {
            XCTAssertNil(ShelfKeys.command(for: key(code, isRepeat: true), in: open))
        }
    }

    func testModifiedKeysAreLeftAlone() {
        XCTAssertNil(ShelfKeys.command(for: key(KeyCode.space, .shift), in: open))
        XCTAssertNil(ShelfKeys.command(for: key(KeyCode.left, .command), in: open))
        XCTAssertNil(ShelfKeys.command(for: key(KeyCode.escape, .option), in: open))
        XCTAssertNil(ShelfKeys.command(for: key(KeyCode.up), in: open))
        XCTAssertNil(ShelfKeys.command(for: key(0, character: "a"), in: open))
    }

    func testKeysWhileQuickLookIsShowing() {
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.space), in: previewing), .closePreview)
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.escape), in: previewing), .closePreview)
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.left), in: previewing), .move(-1, held: false))
        XCTAssertEqual(ShelfKeys.command(for: key(KeyCode.right, isRepeat: true), in: previewing), .move(1, held: true))
    }

    func testQuickLookKeepsItsOtherKeys() {
        // Nothing here may open, copy or remove a file from behind the preview.
        XCTAssertNil(ShelfKeys.command(for: key(KeyCode.returnKey), in: previewing))
        XCTAssertNil(ShelfKeys.command(for: key(KeyCode.delete), in: previewing))
        XCTAssertNil(ShelfKeys.command(for: key(8, .command, character: "c"), in: previewing))
        XCTAssertNil(ShelfKeys.command(for: key(KeyCode.down), in: previewing))
        // A held Space must not close the preview it just opened.
        XCTAssertNil(ShelfKeys.command(for: key(KeyCode.space, isRepeat: true), in: previewing))
    }

    func testOneFileHasNowhereToMoveInQuickLook() {
        let single = ShelfKeys.Context(isOpen: true, previewing: true, hasTarget: true, count: 1)
        XCTAssertNil(ShelfKeys.command(for: key(KeyCode.right), in: single))
    }

    func testCommandVPastesEvenOnAnEmptyShelf() {
        let paste = KeyStroke(keyCode: 9, modifiers: .command, character: "v")
        XCTAssertEqual(ShelfKeys.command(for: paste, in: .init(isOpen: true)), .paste)
        XCTAssertEqual(ShelfKeys.command(for: paste, in: .init(isOpen: true, hasTarget: true, count: 3)), .paste)
        XCTAssertNil(ShelfKeys.command(for: paste, in: .init(isOpen: false)))

        // Not while Quick Look has the keys, not on a held key, and not with anything else held as well.
        XCTAssertNil(ShelfKeys.command(for: paste, in: .init(isOpen: true, previewing: true, hasTarget: true, count: 3)))
        var held = paste
        held.isRepeat = true
        XCTAssertNil(ShelfKeys.command(for: held, in: .init(isOpen: true)))
        let shifted = KeyStroke(keyCode: 9, modifiers: [.command, .shift], character: "v")
        XCTAssertNil(ShelfKeys.command(for: shifted, in: .init(isOpen: true)))
        XCTAssertNil(ShelfKeys.command(for: KeyStroke(keyCode: 9, character: "v"), in: .init(isOpen: true)))
    }
}
