import AppKit

@MainActor
final class EditorDocument: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    var file: TextFile { didSet { updateDirty() } }
    private let undo = UndoManager()
    let editor = NSTextView()
    let scroll = NSScrollView()
    var busy = false
    var onChange: (() -> Void)?
    private var convertingNewlines = false

    private(set) var isDirty = false

    init(file: TextFile) {
        self.file = file
        super.init()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.string = file.text
        editor.delegate = self
        editor.textStorage?.delegate = self
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = editor
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) { updateDirty() }
    }

    private func updateDirty() {
        let dirty = !editor.string.utf8.elementsEqual(file.text.utf8)
        guard dirty != isDirty else { return }
        isDirty = dirty
        onChange?()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        guard !convertingNewlines, !busy,
              editor.undoManager?.isUndoing != true, editor.undoManager?.isRedoing != true,
              let replacementString else { return !busy }
        let converted = TextFile.insertingNewlines(in: replacementString, style: file.newline)
        guard !converted.utf8.elementsEqual(replacementString.utf8) else { return true }
        convertingNewlines = true
        editor.insertText(converted, replacementRange: affectedCharRange)
        convertingNewlines = false
        return false
    }

    func reload(_ file: TextFile) {
        self.file = file
        editor.string = file.text
        editor.undoManager?.removeAllActions()
        updateDirty()
    }
}
