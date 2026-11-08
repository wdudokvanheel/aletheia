import AppKit

/// Window-local literal search. Ranges use NSTextView's UTF-16 coordinates.
@MainActor
final class FindBar: NSStackView, NSTextFieldDelegate {
    let query = NSTextField()
    let replacement = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let replaceRow = NSStackView()
    private var previous: NSButton!
    private var next: NSButton!
    private var replace: NSButton!
    private var replaceAll: NSButton!
    private(set) var matches: [NSRange] = []
    private(set) var current: Int?
    private weak var document: EditorDocument?
    private var editing = false
    var onNavigate: ((String, NSRange?) -> Void)?
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        query.placeholderString = "Find (case sensitive)"
        replacement.placeholderString = "Replace with"
        query.delegate = self
        replacement.delegate = self
        func button(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            return button
        }
        previous = button("↑", #selector(previousMatch(_:)))
        previous.toolTip = "Previous match (Shift-Return)"
        next = button("↓", #selector(nextMatch(_:)))
        next.toolTip = "Next match (Return)"
        let close = button("×", #selector(closeSearch(_:)))
        close.toolTip = "Close search (Escape)"
        replace = button("Replace", #selector(replaceCurrent(_:)))
        replaceAll = button("Replace All", #selector(replaceEveryMatch(_:)))
        let findRow = NSStackView(views: [query, count, previous, next, close])
        replaceRow.setViews([replacement, replace, replaceAll], in: .leading)
        for row in [findRow, replaceRow] {
            row.orientation = .horizontal
            row.spacing = 6
            addArrangedSubview(row)
            row.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16).isActive = true
        }
        for field in [query, replacement] {
            field.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
            let preferredWidth = field.widthAnchor.constraint(equalToConstant: 240)
            preferredWidth.priority = .defaultHigh
            preferredWidth.isActive = true
        }
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        replaceRow.isHidden = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    nonisolated static func ranges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var result: [NSRange] = []
        var start = 0
        while start < source.length {
            let range = source.range(of: query, options: .literal,
                                     range: NSRange(location: start, length: source.length - start))
            guard range.location != NSNotFound else { break }
            result.append(range)
            start = NSMaxRange(range)
        }
        return result
    }

    func bind(_ document: EditorDocument?) {
        self.document = document
        refresh(anchor: document?.editor.selectedRange().location ?? 0)
    }

    func show(replacing: Bool) {
        isHidden = false
        replaceRow.isHidden = !replacing
        refresh(anchor: document?.editor.selectedRange().location ?? 0)
        window?.makeFirstResponder(replacing ? replacement : query)
        (replacing ? replacement : query).selectText(nil)
    }

    func contentChanged() {
        guard !editing, !isHidden else { return }
        // Storage delegates run before NSTextView finishes editing/layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.editing else { return }
            self.refresh(anchor: self.currentRange?.location ?? 0)
        }
    }

    var currentRange: NSRange? { current.flatMap { matches.indices.contains($0) ? matches[$0] : nil } }

    func refresh(anchor: Int = 0) {
        matches = isHidden ? [] : Self.ranges(in: document?.editor.string ?? "", query: query.stringValue)
        current = matches.firstIndex { $0.location >= anchor } ?? (matches.isEmpty ? nil : 0)
        navigate()
    }

    func synchronize() { navigate() }

    private func navigate() {
        count.stringValue = current.map { "\($0 + 1) of \(matches.count)" } ?? "0 matches"
        previous.isEnabled = !matches.isEmpty
        next.isEnabled = !matches.isEmpty
        replace.isEnabled = !matches.isEmpty && document?.editor.isEditable == true
        replaceAll.isEnabled = replace.isEnabled
        if let range = currentRange, let document {
            document.revealSearchMatch(range)
        }
        onNavigate?(isHidden ? "" : query.stringValue, currentRange)
    }

    @objc func nextMatch(_ sender: Any?) { move(1) }
    @objc func previousMatch(_ sender: Any?) { move(-1) }
    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        current = ((current ?? 0) + delta + matches.count) % matches.count
        navigate()
    }

    @objc func closeSearch(_ sender: Any?) {
        isHidden = true
        matches = []
        current = nil
        onNavigate?("", nil)
        onClose?()
    }

    @objc func replaceCurrent(_ sender: Any?) {
        guard let range = currentRange else { return }
        performReplacement([range], all: false)
    }

    @objc func replaceEveryMatch(_ sender: Any?) { performReplacement(matches, all: true) }

    private func performReplacement(_ ranges: [NSRange], all: Bool) {
        guard let document, !document.busy, document.editor.isEditable, !ranges.isEmpty else { return }
        let editor = document.editor
        // A change may have arrived before the deferred refresh.
        guard Self.ranges(in: editor.string, query: query.stringValue) == matches else {
            refresh(); return
        }
        let text = TextFile.insertingNewlines(in: replacement.stringValue, style: document.file.newline)
        editing = true
        editor.breakUndoCoalescing()
        editor.undoManager?.beginUndoGrouping()
        for range in ranges.reversed() { editor.insertText(text, replacementRange: range) }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName(all ? "Replace All" : "Replace")
        editor.breakUndoCoalescing()
        editing = false
        refresh(anchor: all ? 0 : ranges[0].location + text.utf16.count)
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === query { refresh() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replacement { replaceCurrent(nil) }
            else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { previousMatch(nil) }
            else { nextMatch(nil) }
            return true
        case #selector(NSResponder.cancelOperation(_:)): closeSearch(nil); return true
        default: return false
        }
    }
}
