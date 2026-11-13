import AppKit

/// One key press with its modifiers. `key` is the layout's unmodified character, lowercased.
struct KeyStroke: Codable, Hashable {
    let key: String
    let modifiers: UInt

    static let modifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    init(_ key: String, _ flags: NSEvent.ModifierFlags = []) {
        self.key = key.lowercased()
        modifiers = flags.intersection(Self.modifierMask).rawValue
    }

    init?(_ event: NSEvent) {
        guard let typed = event.charactersIgnoringModifiers, let scalar = typed.unicodeScalars.first else { return nil }
        // Named keys keep AppKit's character; printable keys also drop Shift, so ⇧1 is "1" and not "!".
        let named = scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value)
        let key = named ? typed : event.characters(byApplyingModifiers: []) ?? typed
        self.init(key == "\u{19}" ? "\t" : key, event.modifierFlags)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    private static let functionKeys = 0xF704...0xF717
    private static let symbols: [String: String] = [
        "\r": "↩", "\u{3}": "⌅", "\t": "⇥", " ": "Space", "\u{7F}": "⌫", "\u{F728}": "⌦", "\u{1B}": "⎋",
        "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
        "\u{F729}": "↖", "\u{F72B}": "↘", "\u{F72C}": "⇞", "\u{F72D}": "⇟"
    ]

    private var functionKey: Int? {
        guard let scalar = key.unicodeScalars.first, Self.functionKeys.contains(Int(scalar.value)) else { return nil }
        return Int(scalar.value) - 0xF703
    }

    /// Plain and Option-only keys type text, so a shortcut starts with ⌘, ⌃, or a function key.
    var canStartShortcut: Bool {
        functionKey != nil || !flags.intersection([.command, .control]).isEmpty
    }

    static func modifierKeycaps(_ flags: NSEvent.ModifierFlags) -> [String] {
        let names: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return names.filter { flags.contains($0.0) }.map(\.1)
    }

    /// One label per keycap: modifiers in the standard macOS order, then the key.
    var keycaps: [String] {
        Self.modifierKeycaps(flags) + [functionKey.map { "F\($0)" } ?? Self.symbols[key] ?? key.uppercased()]
    }

    var text: String { keycaps.joined() }

    /// AppKit menus name Backspace differently from the key event.
    var menuKeyEquivalent: String { key == "\u{7F}" ? "\u{8}" : key }
}

/// Every command with a configurable shortcut, in menu order.
enum ShortcutCommand: String, CaseIterable {
    case settings, hide, hideOthers, quit
    case newFile, newFolder, openFile, openFolder, switchProject, save, closeTab, closeWindow
    case undo, redo, cut, copy, paste, selectAll, find, replace
    case toggleFileTree
    case minimize

    var title: String {
        switch self {
        case .settings: "Settings…"
        case .hide: "Hide Aletheia"
        case .hideOthers: "Hide Others"
        case .quit: "Quit Aletheia"
        case .newFile: "New File…"
        case .newFolder: "New Folder…"
        case .openFile: "Open File…"
        case .openFolder: "Open Folder…"
        case .switchProject: "Switch Project…"
        case .save: "Save"
        case .closeTab: "Close Tab"
        case .closeWindow: "Close Window"
        case .undo: "Undo"
        case .redo: "Redo"
        case .cut: "Cut"
        case .copy: "Copy"
        case .paste: "Paste"
        case .selectAll: "Select All"
        case .find: "Find…"
        case .replace: "Replace…"
        case .toggleFileTree: "Toggle File Tree"
        case .minimize: "Minimize"
        }
    }

    /// The menu that holds the command; Settings groups its rows the same way.
    var group: String {
        switch self {
        case .settings, .hide, .hideOthers, .quit: "Aletheia"
        case .newFile, .newFolder, .openFile, .openFolder, .switchProject, .save, .closeTab, .closeWindow: "File"
        case .undo, .redo, .cut, .copy, .paste, .selectAll, .find, .replace: "Edit"
        case .toggleFileTree: "View"
        case .minimize: "Window"
        }
    }

    var defaultStrokes: [KeyStroke] {
        switch self {
        case .settings: [KeyStroke(",", .command)]
        case .hide: [KeyStroke("h", .command)]
        case .hideOthers: [KeyStroke("h", [.command, .option])]
        case .quit: [KeyStroke("q", .command)]
        case .newFile: [KeyStroke("n", .command)]
        case .newFolder: [KeyStroke("n", [.command, .shift])]
        case .openFile: [KeyStroke("o", .command)]
        case .openFolder: [KeyStroke("o", [.command, .shift])]
        case .switchProject: [KeyStroke("s", .control), KeyStroke("s")]
        case .save: [KeyStroke("s", .command)]
        case .closeTab: [KeyStroke("w", .command)]
        case .closeWindow: [KeyStroke("w", [.command, .shift])]
        case .undo: [KeyStroke("z", .command)]
        case .redo: [KeyStroke("z", [.command, .shift])]
        case .cut: [KeyStroke("x", .command)]
        case .copy: [KeyStroke("c", .command)]
        case .paste: [KeyStroke("v", .command)]
        case .selectAll: [KeyStroke("a", .command)]
        case .find: [KeyStroke("f", .command)]
        case .replace: [KeyStroke("r", .command)]
        case .toggleFileTree: [KeyStroke("s", [.control, .shift])]
        case .minimize: [KeyStroke("m", .command)]
        }
    }
}

/// The user's shortcuts: one or two key strokes per command, or none. Only changes are stored.
@MainActor
final class Shortcuts {
    static let shared = Shortcuts()
    static let didChange = Notification.Name("AletheiaShortcutsDidChange")
    static let storageKey = "keyboardShortcuts"

    private let defaults: UserDefaults
    private var overrides: [String: [KeyStroke]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: [KeyStroke]].self, from: $0) } ?? [:]
    }

    func strokes(for command: ShortcutCommand) -> [KeyStroke] {
        overrides[command.rawValue].map { Array($0.prefix(2)) } ?? command.defaultStrokes
    }

    func isCustomized(_ command: ShortcutCommand) -> Bool { strokes(for: command) != command.defaultStrokes }
    var hasCustomizations: Bool { ShortcutCommand.allCases.contains(where: isCustomized) }

    /// An empty list removes the command's shortcut.
    func set(_ strokes: [KeyStroke], for command: ShortcutCommand) {
        guard strokes != self.strokes(for: command) else { return }
        overrides[command.rawValue] = strokes == command.defaultStrokes ? nil : strokes
        save()
    }

    func restoreDefaults() {
        guard !overrides.isEmpty else { return }
        overrides = [:]
        save()
    }

    private func save() {
        if overrides.isEmpty { defaults.removeObject(forKey: Self.storageKey) }
        else if let data = try? JSONEncoder().encode(overrides) { defaults.set(data, forKey: Self.storageKey) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Commands that could not coexist with `strokes`: the same keys, or one starting the other.
    func conflicts(with strokes: [KeyStroke], excluding command: ShortcutCommand) -> [ShortcutCommand] {
        guard !strokes.isEmpty else { return [] }
        return ShortcutCommand.allCases.filter { other in
            let existing = self.strokes(for: other)
            return other != command && !existing.isEmpty
                && (existing.starts(with: strokes) || strokes.starts(with: existing))
        }
    }

    func startsSequence(_ stroke: KeyStroke) -> Bool {
        ShortcutCommand.allCases.contains { strokes(for: $0).count == 2 && strokes(for: $0)[0] == stroke }
    }

    func command(for sequence: [KeyStroke]) -> ShortcutCommand? {
        ShortcutCommand.allCases.first { strokes(for: $0) == sequence }
    }

    /// "⌘S", or "⌃S, then S" with a separator of ", then ".
    static func text(_ strokes: [KeyStroke], separator: String = " ") -> String {
        strokes.map(\.text).joined(separator: separator)
    }

    /// " (⌃⇧S)" for tooltips, or nothing when the command has no shortcut.
    func hint(for command: ShortcutCommand) -> String {
        let strokes = strokes(for: command)
        return strokes.isEmpty ? "" : " (\(Self.text(strokes, separator: ", ")))"
    }
}
