import AppKit

/// A clickable shortcut drawn as keycaps. Clicking records one or two key strokes in place.
@MainActor
final class ShortcutField: NSView {
    /// The field being recorded; the app's event monitor sends it every key and click.
    private(set) static weak var recording: ShortcutField?

    var strokes: [KeyStroke] = [] { didSet { refresh() } }
    /// Receives the recorded strokes; an empty list asks to remove the shortcut.
    var onRecord: (([KeyStroke]) -> Void)?
    /// Receives guidance for the current recording step, or nil once recording ends.
    var onStatus: ((_ text: String?, _ warning: Bool) -> Void)?

    private var captured: [KeyStroke] = []
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var hovered = false
    private var isRecording: Bool { Self.recording === self }

    private enum Piece { case cap(String), label(String) }
    private static let capFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let labelFont = NSFont.systemFont(ofSize: 12)
    private static let capHeight: CGFloat = 20
    private static let inset: CGFloat = 5
    private static let gap: CGFloat = 3

    private var pieces: [Piece] {
        func caps(_ strokes: [KeyStroke]) -> [Piece] {
            strokes.enumerated().flatMap { index, stroke in
                (index > 0 ? [Piece.label("then")] : []) + stroke.keycaps.map(Piece.cap)
            }
        }
        guard isRecording else { return strokes.isEmpty ? [.label("Add Shortcut")] : caps(strokes) }
        guard captured.isEmpty else { return caps(captured) + [.label("then…")] }
        let held = KeyStroke.modifierKeycaps(heldModifiers)
        return held.map(Piece.cap) + [.label(held.isEmpty ? "Type shortcut…" : "…")]
    }

    private func width(of piece: Piece) -> CGFloat {
        switch piece {
        case .cap(let text):
            max(Self.capHeight, ceil((text as NSString).size(withAttributes: [.font: Self.capFont]).width) + 10)
        case .label(let text):
            ceil((text as NSString).size(withAttributes: [.font: Self.labelFont]).width) + 6
        }
    }

    override var intrinsicContentSize: NSSize {
        let pieces = pieces
        let content = pieces.map(width).reduce(0, +) + Self.gap * CGFloat(pieces.count - 1)
        return NSSize(width: content + Self.inset * 2, height: 28)
    }

    private func refresh() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            outline.fill()
            NSColor.controlAccentColor.setStroke()
            outline.lineWidth = 1.5
            outline.stroke()
        } else if hovered {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            outline.fill()
        }
        func draw(_ text: String, _ font: NSFont, _ color: NSColor, in rect: NSRect) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                    withAttributes: attributes)
        }
        var x = Self.inset
        for piece in pieces {
            let width = width(of: piece)
            switch piece {
            case .cap(let text):
                let rect = NSRect(x: x, y: (bounds.height - Self.capHeight) / 2, width: width, height: Self.capHeight)
                let cap = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
                NSColor.labelColor.withAlphaComponent(0.09).setFill()
                cap.fill()
                NSColor.labelColor.withAlphaComponent(0.18).setStroke()
                cap.stroke()
                draw(text, Self.capFont, .labelColor, in: rect)
            case .label(let text):
                draw(text, Self.labelFont, isRecording ? .controlAccentColor : .tertiaryLabelColor,
                     in: NSRect(x: x, y: 0, width: width, height: bounds.height))
            }
            x += width + Self.gap
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        if isRecording { finish(save: !captured.isEmpty) } else { startRecording() }
    }

    private func startRecording() {
        guard let window, window.attachedSheet == nil else { return }
        Self.recording?.finish(save: false)
        captured = []
        heldModifiers = []
        Self.recording = self
        // A sheet, another window or another app taking the keyboard ends the recording.
        NotificationCenter.default.addObserver(self, selector: #selector(cancelRecording),
            name: NSWindow.didResignKeyNotification, object: window)
        refresh()
        reportStep()
    }

    private func finish(save: Bool) {
        guard isRecording else { return }
        Self.recording = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        let recorded = captured
        captured = []
        refresh()
        onStatus?(nil, false)
        if save { onRecord?(recorded) }
    }

    @objc private func cancelRecording() { finish(save: false) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finish(save: false) }
        super.viewWillMove(toWindow: newWindow)
    }

    private func reportStep() {
        onStatus?(captured.isEmpty
            ? "Press the new shortcut.   ⌫ removes it   ·   ⎋ cancels"
            : "Press ↩ to save \(Shortcuts.text(captured)), or press another key to make a two-step shortcut.", false)
    }

    /// Takes an event from the app's monitor while recording. Returns whether it was consumed.
    func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            heldModifiers = event.modifierFlags.intersection(KeyStroke.modifierMask)
            refresh()
            return false
        case .keyDown:
            guard !event.isARepeat, let stroke = KeyStroke(event) else { return true }
            switch stroke.modifiers == 0 ? stroke.key : "" {
            case "\u{1B}": finish(save: false)
            case "\r", "\u{3}": finish(save: !captured.isEmpty)
            case "\u{7F}", "\u{F728}":
                // Delete removes the shortcut, or the first key when one is already recorded.
                if captured.isEmpty { finish(save: true) } else { captured = []; refresh(); reportStep() }
            default:
                if !captured.isEmpty {
                    captured.append(stroke)
                    finish(save: true)
                } else if stroke.canStartShortcut {
                    captured = [stroke]
                    refresh()
                    reportStep()
                } else {
                    onStatus?("Start with ⌘ or ⌃, or use a function key. Other keys type text.", true)
                }
            }
            return true
        default:
            // A click on this field goes to mouseDown; a click anywhere else keeps what was recorded.
            if event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)) { return false }
            finish(save: !captured.isEmpty)
            return false
        }
    }
}

private final class ShortcutList: NSStackView {
    override var isFlipped: Bool { true }
}

/// The Shortcuts settings page: every command with its shortcut, grouped like the menu bar.
@MainActor
final class ShortcutSettingsView: NSView {
    private let shortcuts: Shortcuts
    private var fields: [ShortcutCommand: ShortcutField] = [:]
    private var resets: [ShortcutCommand: NSButton] = [:]
    private let restore = NSButton(title: "Restore Defaults", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")

    init(shortcuts: Shortcuts) {
        self.shortcuts = shortcuts
        super.init(frame: .zero)
        restore.target = self
        restore.action = #selector(restoreDefaults)
        let heading = SettingsPage.heading("Keyboard shortcuts")
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, restore])
        header.distribution = .fill
        let note = SettingsPage.note("Click a shortcut to change it. A shortcut is one key combination, or two pressed one after the other.")

        let list = ShortcutList()
        list.orientation = .vertical
        list.alignment = .centerX
        list.spacing = 0
        var group: String?
        for command in ShortcutCommand.allCases {
            let lead: NSView
            if command.group == group {
                lead = NSBox()
                (lead as! NSBox).boxType = .separator
            } else {
                group = command.group
                let label = NSTextField(labelWithString: command.group.uppercased())
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .secondaryLabelColor
                let groupHeader = NSStackView(views: [label])
                groupHeader.distribution = .fill
                groupHeader.edgeInsets = NSEdgeInsets(top: 16, left: 0, bottom: 6, right: 0)
                lead = groupHeader
            }
            let row = row(for: command)
            list.addArrangedSubview(lead)
            list.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                lead.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -28),
                row.widthAnchor.constraint(equalTo: list.widthAnchor)
            ])
        }
        list.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = list
        list.translatesAutoresizingMaskIntoConstraints = false
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .quaternarySystemFill
        box.contentViewMargins = NSSize(width: 1, height: 1)
        box.contentView = scroll

        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [header, note, box, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            note.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            box.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 14),
            status.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 10),
            status.heightAnchor.constraint(equalToConstant: 16),
            status.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
            name: Shortcuts.didChange, object: shortcuts)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func row(for command: ShortcutCommand) -> NSView {
        let title = NSTextField(labelWithString: command.title)
        title.font = .systemFont(ofSize: 13)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let field = ShortcutField()
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.onRecord = { [weak self] in self?.assign($0, to: command) }
        field.onStatus = { [weak self] in self?.show($0, warning: $1) }
        let reset = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Reset")!,
                             target: self, action: #selector(resetShortcut(_:)))
        reset.isBordered = false
        reset.contentTintColor = .secondaryLabelColor
        reset.tag = ShortcutCommand.allCases.firstIndex(of: command)!
        fields[command] = field
        resets[command] = reset
        let row = NSStackView(views: [title, reset, field])
        row.distribution = .fill
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 9)
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return row
    }

    @objc private func refresh() {
        for command in ShortcutCommand.allCases {
            fields[command]?.strokes = shortcuts.strokes(for: command)
            resets[command]?.isHidden = !shortcuts.isCustomized(command)
            let original = command.defaultStrokes
            resets[command]?.toolTip = "Reset to " + (original.isEmpty ? "no shortcut" : Shortcuts.text(original, separator: ", then "))
        }
        restore.isEnabled = shortcuts.hasCustomizations
    }

    private func show(_ text: String?, warning: Bool) {
        status.stringValue = text ?? ""
        status.textColor = warning ? .systemOrange : .secondaryLabelColor
    }

    /// Two commands cannot share keys, and one shortcut cannot be the first step of another.
    private func assign(_ strokes: [KeyStroke], to command: ShortcutCommand) {
        let conflicts = shortcuts.conflicts(with: strokes, excluding: command)
        guard !conflicts.isEmpty, let window else { shortcuts.set(strokes, for: command); return }
        let names = conflicts.map(\.title).formatted(.list(type: .and))
        let alert = NSAlert()
        alert.messageText = "\(Shortcuts.text(strokes, separator: ", then ")) is already in use"
        alert.informativeText = conflicts.map {
            "\($0.title) uses \(Shortcuts.text(shortcuts.strokes(for: $0), separator: ", then "))."
        }.joined(separator: "\n") + "\n\nReassigning it to \(command.title) leaves \(names) without a shortcut."
        alert.addButton(withTitle: "Reassign")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            conflicts.forEach { self.shortcuts.set([], for: $0) }
            self.shortcuts.set(strokes, for: command)
        }
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        let command = ShortcutCommand.allCases[sender.tag]
        assign(command.defaultStrokes, to: command)
    }

    @objc private func restoreDefaults() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Restore all shortcuts to their defaults?"
        alert.informativeText = "Your changed shortcuts will be replaced."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.shortcuts.restoreDefaults() }
        }
    }
}
