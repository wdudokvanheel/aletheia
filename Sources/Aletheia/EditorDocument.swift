import AppKit

@MainActor
final class EditorDocument: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    var file: TextFile { didSet { updateDirty() } }
    private let undo = UndoManager()
    let editor = NSTextView()
    let scroll = NSScrollView()
    var busy = false
    var markdownMode = MarkdownMode.split
    var isMarkdown: Bool { file.url.pathExtension.lowercased() == "md" }
    var onContentChange: (() -> Void)?
    var onChange: (() -> Void)?
    private var convertingNewlines = false
    private var highlightingTask: Task<Void, Never>?
    private var highlightGeneration = 0
    private var syntaxRuns: [SyntaxRun] = []
    private var highlightingActive = false
    private var styledRange: NSRange?
    private var renderingSyntax = false
    private(set) var highlightedGeneration = -1

    deinit { highlightingTask?.cancel() }

    func setHighlightingActive(_ active: Bool) {
        guard active != highlightingActive else { return }
        highlightingActive = active
        if active { scheduleHighlighting() }
        else { highlightingTask?.cancel(); highlightGeneration += 1 }
    }

    private func scheduleHighlighting() {
        highlightGeneration += 1
        highlightingTask?.cancel()
        syntaxRuns = []
        guard highlightingActive, let language = SyntaxHighlighting.languageID(for: file.url) else { return }
        let generation = highlightGeneration
        highlightingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            let text = self.editor.string
            let worker = Task.detached(priority: .userInitiated) {
                SyntaxHighlighting.runs(in: text, languageID: language)
            }
            let runs = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, self.highlightGeneration == generation else { return }
            self.syntaxRuns = runs
            self.renderSyntax()
            self.highlightedGeneration = generation
        }
    }

    @objc private func highlightViewportChanged(_ notification: Notification) {
        guard highlightingActive, !syntaxRuns.isEmpty else { return }
        renderSyntax(force: false)
    }

    private func renderSyntax(force: Bool = true) {
        guard !renderingSyntax, let layout = editor.layoutManager,
              let container = editor.textContainer else { return }
        renderingSyntax = true
        defer { renderingSyntax = false }
        var visible = scroll.contentView.bounds.insetBy(dx: 0, dy: -40)
        visible.origin.x -= editor.textContainerOrigin.x
        visible.origin.y -= editor.textContainerOrigin.y
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard force || styledRange != range else { return }
        styledRange = range
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: editor.string.utf16.count))
        let palette = AppSettings.shared.selectedScheme.syntaxPalette
        // Runs are ordered and non-overlapping. Find the viewport in logarithmic time.
        var lower = 0
        var upper = syntaxRuns.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(syntaxRuns[middle].range) <= range.location { lower = middle + 1 }
            else { upper = middle }
        }
        for run in syntaxRuns[lower...] {
            if run.range.location >= NSMaxRange(range) { break }
            let intersection = NSIntersectionRange(run.range, range)
            if intersection.length > 0 {
                layout.addTemporaryAttribute(.foregroundColor, value: run.style.color(palette), forCharacterRange: intersection)
            }
        }
    }

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
        editor.layoutManager?.allowsNonContiguousLayout = true
        editor.string = file.text
        editor.delegate = self
        editor.textStorage?.delegate = self
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(highlightViewportChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    func applyTheme() {
        let palette = AppSettings.shared.palette
        editor.backgroundColor = palette.background
        editor.textColor = palette.foreground
        editor.insertionPointColor = palette.foreground
        editor.selectedTextAttributes = [.backgroundColor: palette.accent.withAlphaComponent(0.35),
                                         .foregroundColor: palette.foreground]
        scroll.backgroundColor = palette.background
        renderSyntax()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) {
            updateDirty()
            scheduleHighlighting()
            onContentChange?()
        }
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
