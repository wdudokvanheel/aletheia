import AppKit
import XCTest
@testable import Aletheia

final class ShortcutsTests: XCTestCase {
    @MainActor private func makeShortcuts() throws -> (Shortcuts, UserDefaults, String) {
        let suite = "AletheiaShortcutsTests.\(UUID().uuidString)"
        return (Shortcuts(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))), UserDefaults(suiteName: suite)!, suite)
    }

    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [],
                     isRepeat: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: code))
    }

    @MainActor func testDefaultsKeepTheExistingShortcuts() throws {
        let (shortcuts, defaults, suite) = try makeShortcuts()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(Shortcuts.text(shortcuts.strokes(for: .switchProject), separator: ", then "), "⌃S, then S")
        XCTAssertEqual(Shortcuts.text(shortcuts.strokes(for: .toggleFileTree)), "⌃⇧S")
        XCTAssertEqual(Shortcuts.text(shortcuts.strokes(for: .hideOthers)), "⌥⌘H")
        XCTAssertEqual(shortcuts.hint(for: .save), " (⌘S)")
        XCTAssertFalse(shortcuts.hasCustomizations)
        for command in ShortcutCommand.allCases {
            XCTAssertEqual(shortcuts.conflicts(with: command.defaultStrokes, excluding: command), [], command.rawValue)
            XCTAssertEqual(command.defaultStrokes.first?.canStartShortcut, true, command.rawValue)
        }
    }

    @MainActor func testChangesPersistAndDefaultsAreNotStored() throws {
        let (shortcuts, defaults, suite) = try makeShortcuts()
        defer { defaults.removePersistentDomain(forName: suite) }
        let chord = [KeyStroke("k", .command), KeyStroke("t", .command)]
        let changed = expectation(forNotification: Shortcuts.didChange, object: shortcuts)
        shortcuts.set(chord, for: .toggleFileTree)
        wait(for: [changed], timeout: 1)
        shortcuts.set([], for: .minimize)
        let reloaded = Shortcuts(defaults: defaults)
        XCTAssertEqual(reloaded.strokes(for: .toggleFileTree), chord)
        XCTAssertEqual(reloaded.strokes(for: .minimize), [])
        XCTAssertEqual(reloaded.hint(for: .minimize), "")
        XCTAssertTrue(reloaded.isCustomized(.minimize))
        XCTAssertFalse(reloaded.isCustomized(.save))

        shortcuts.set(ShortcutCommand.toggleFileTree.defaultStrokes, for: .toggleFileTree)
        XCTAssertFalse(shortcuts.isCustomized(.toggleFileTree))
        shortcuts.restoreDefaults()
        XCTAssertNil(defaults.object(forKey: Shortcuts.storageKey))
        XCTAssertEqual(Shortcuts(defaults: defaults).strokes(for: .minimize), ShortcutCommand.minimize.defaultStrokes)
    }

    @MainActor func testConflictsCoverSharedKeysAndFirstSteps() throws {
        let (shortcuts, defaults, suite) = try makeShortcuts()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(shortcuts.conflicts(with: [KeyStroke("s", .command)], excluding: .closeTab), [.save])
        XCTAssertEqual(shortcuts.conflicts(with: [KeyStroke("s", .command)], excluding: .save), [])
        // ⌃S alone would be swallowed as the first step of Switch Project, and the reverse.
        XCTAssertEqual(shortcuts.conflicts(with: [KeyStroke("s", .control)], excluding: .find), [.switchProject])
        XCTAssertEqual(shortcuts.conflicts(with: [KeyStroke("s", .command), KeyStroke("x")], excluding: .find), [.save])
        XCTAssertEqual(shortcuts.conflicts(with: [KeyStroke("s", .control), KeyStroke("t")], excluding: .find), [])
        XCTAssertEqual(shortcuts.conflicts(with: [], excluding: .find), [])
    }

    @MainActor func testSequencesResolveToCommands() throws {
        let (shortcuts, defaults, suite) = try makeShortcuts()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(shortcuts.startsSequence(KeyStroke("s", .control)))
        XCTAssertFalse(shortcuts.startsSequence(KeyStroke("s", .command)))
        XCTAssertEqual(shortcuts.command(for: [KeyStroke("S", .control), KeyStroke("s")]), .switchProject)
        XCTAssertNil(shortcuts.command(for: [KeyStroke("s", .control), KeyStroke("x")]))
        shortcuts.set([KeyStroke("p", [.command, .shift])], for: .switchProject)
        XCTAssertFalse(shortcuts.startsSequence(KeyStroke("s", .control)))
    }

    func testKeyStrokesReadEventsAndNameSpecialKeys() throws {
        let enter = try XCTUnwrap(KeyStroke(try key(36, "\r", [.command, .capsLock])))
        XCTAssertEqual(enter, KeyStroke("\r", .command))
        XCTAssertEqual(enter.text, "⌘↩")
        let f5 = try XCTUnwrap(KeyStroke(try key(96, "\u{F708}", .function)))
        XCTAssertEqual(f5.keycaps, ["F5"])
        XCTAssertTrue(f5.canStartShortcut)
        XCTAssertEqual(KeyStroke("\u{7F}", [.control, .option, .shift, .command]).keycaps, ["⌃", "⌥", "⇧", "⌘", "⌫"])
        XCTAssertEqual(KeyStroke("\u{7F}").menuKeyEquivalent, "\u{8}")
        XCTAssertEqual(KeyStroke(try key(48, "\u{19}", .shift)), KeyStroke("\t", .shift))
        XCTAssertEqual(KeyStroke(try key(18, "!", [.command, .shift]))?.modifiers, KeyStroke("1", [.command, .shift]).modifiers)
        XCTAssertNotEqual(KeyStroke(try key(18, "!", [.command, .shift]))?.key, "!")
        XCTAssertFalse(KeyStroke("a").canStartShortcut)
        XCTAssertFalse(KeyStroke("a", [.option, .shift]).canStartShortcut)
        XCTAssertTrue(KeyStroke("a", [.control]).canStartShortcut)
    }

    @MainActor func testFieldRecordsOneOrTwoStrokes() throws {
        let field = ShortcutField(frame: NSRect(x: 0, y: 0, width: 120, height: 28))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(field)
        var recorded: [[KeyStroke]] = []
        var statuses: [String?] = []
        var warned = false
        field.onRecord = { recorded.append($0) }
        field.onStatus = { statuses.append($0); warned = warned || $1 }
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))

        // A plain key cannot start a shortcut; a modified key waits for Return or a second key.
        field.mouseDown(with: click)
        XCTAssertTrue(ShortcutField.recording === field)
        XCTAssertTrue(field.handle(try key(36, "\r", .command, isRepeat: true)))
        XCTAssertTrue(field.handle(try key(49, " ")))
        XCTAssertTrue(warned)
        XCTAssertTrue(field.handle(try key(36, "\r", .command)))
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertTrue(field.handle(try key(36, "\r")))
        XCTAssertEqual(recorded, [[KeyStroke("\r", .command)]])
        XCTAssertNil(ShortcutField.recording)
        XCTAssertEqual(statuses.last, .some(nil))

        // The second key completes a two-step shortcut on its own.
        field.mouseDown(with: click)
        _ = field.handle(try key(36, "\r", .control))
        _ = field.handle(try key(49, " "))
        XCTAssertEqual(recorded.last, [KeyStroke("\r", .control), KeyStroke(" ")])
        XCTAssertNil(ShortcutField.recording)

        // Escape leaves the shortcut alone; Delete removes it.
        field.mouseDown(with: click)
        _ = field.handle(try key(36, "\r", .control))
        _ = field.handle(try key(53, "\u{1B}"))
        XCTAssertEqual(recorded.count, 2)
        field.mouseDown(with: click)
        _ = field.handle(try key(51, "\u{7F}"))
        XCTAssertEqual(recorded.last, [])

        // A click elsewhere keeps what was recorded and is not consumed.
        field.mouseDown(with: click)
        _ = field.handle(try key(96, "\u{F708}"))
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 180, y: 80), modifierFlags: [],
                                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertFalse(field.handle(outside))
        XCTAssertEqual(recorded.last?.map(\.keycaps), [["F5"]])
        XCTAssertNil(ShortcutField.recording)
    }

    @MainActor func testMenuShowsShortcutsAndTwoStepKeysAreConsumed() throws {
        let (shortcuts, defaults, suite) = try makeShortcuts()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let app = AppDelegate(defaults: defaults, shortcuts: shortcuts)
        app.buildMenu()
        let save = try XCTUnwrap(app.commandItems[.save])
        let switchProject = try XCTUnwrap(app.commandItems[.switchProject])
        XCTAssertEqual(app.commandItems.count, ShortcutCommand.allCases.count)
        XCTAssertEqual(save.keyEquivalent, "s")
        XCTAssertEqual(save.keyEquivalentModifierMask, .command)
        XCTAssertEqual(switchProject.title, "Switch Project…")
        XCTAssertEqual(switchProject.keyEquivalent, "")
        XCTAssertEqual(switchProject.badge?.stringValue, "⌃S S")

        // The first step is held back; an unrelated key afterwards reaches the app untouched.
        XCTAssertFalse(app.consumeShortcutEvent(try key(1, "s")))
        XCTAssertTrue(app.consumeShortcutEvent(try key(1, "s", .control)))
        XCTAssertTrue(app.consumeShortcutEvent(try key(1, "s", .control, isRepeat: true)))
        XCTAssertFalse(app.consumeShortcutEvent(try key(7, "x")))
        XCTAssertFalse(app.consumeShortcutEvent(try key(53, "\u{1B}")))
        XCTAssertTrue(app.consumeShortcutEvent(try key(1, "s", .control)))
        XCTAssertTrue(app.consumeShortcutEvent(try key(53, "\u{1B}")))

        // Changing shortcuts updates the menu at once, and the old first step is released.
        shortcuts.set([KeyStroke("k", .command), KeyStroke("s", .command)], for: .save)
        shortcuts.set([KeyStroke("p", [.command, .shift])], for: .switchProject)
        XCTAssertEqual(save.keyEquivalent, "")
        XCTAssertEqual(save.badge?.stringValue, "⌘K ⌘S")
        XCTAssertEqual(switchProject.keyEquivalent, "p")
        XCTAssertEqual(switchProject.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertNil(switchProject.badge)
        XCTAssertFalse(app.consumeShortcutEvent(try key(1, "s", .control)))
        // Save has no editable document here, so the completed shortcut is consumed without running.
        XCTAssertTrue(app.consumeShortcutEvent(try key(40, "k", .command)))
        XCTAssertTrue(app.consumeShortcutEvent(try key(1, "s", .command)))
    }
}
