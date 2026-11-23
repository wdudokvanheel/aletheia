import AppKit

@MainActor
final class EditorDocument: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    var file: DocumentFile { didSet { updateDirty() } }
    private let undo = UndoManager()
    lazy var editor = NSTextView()
    lazy var scroll = NSScrollView()
    private(set) var nativePreview: NativePreview?
    var isEditable: Bool { file.isText }
    var contentView: NSView {
        if case .preview(let file) = file {
            if nativePreview == nil { nativePreview = NativePreview(file: file) }
            return nativePreview!.view
        }
        return scroll
    }

    func detachContent() {
        if isEditable { scroll.removeFromSuperview() }
        else { nativePreview?.view.removeFromSuperview() }
    }
    private var pendingSourcePosition: CGPoint?
    private var sourceVisible = false
    var previewPosition: CGPoint = .zero
    var scrollPosition: FileScrollPosition {
        guard isEditable else { return FileScrollPosition() }
        return FileScrollPosition(source: pendingSourcePosition ?? scroll.contentView.bounds.origin,
                           preview: previewPosition)
    }

    func restoreScrollPosition(_ position: FileScrollPosition) {
        pendingSourcePosition = Self.validPosition(position.source)
        previewPosition = Self.validPosition(position.preview)
    }

    static func validPosition(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.isFinite ? max(0, point.x) : 0,
                y: point.y.isFinite ? max(0, point.y) : 0)
    }

    func setSourceVisible(_ visible: Bool) {
        guard isEditable else { return }
        if !visible, sourceVisible, pendingSourcePosition == nil {
            pendingSourcePosition = Self.validPosition(scroll.contentView.bounds.origin)
        }
        sourceVisible = visible
        if visible { restoreSourceScrollAfterLayout() }
    }

    func restoreSourceScrollAfterLayout() {
        guard sourceVisible, scroll.window != nil, !scroll.isHiddenOrHasHiddenAncestor,
              scroll.contentSize.width > 0, scroll.contentSize.height > 0,
              let position = pendingSourcePosition,
              let layout = editor.layoutManager, let container = editor.textContainer else { return }
        // Finish wrapping at the actual pane width before clamping against EOF.
        scroll.layoutSubtreeIfNeeded()
        layout.ensureLayout(for: container)
        editor.sizeToFit()
        let maximum = CGPoint(x: max(0, editor.frame.width - scroll.contentSize.width),
                              y: max(0, editor.frame.height - scroll.contentSize.height))
        pendingSourcePosition = nil
        scroll.contentView.scroll(to: CGPoint(x: min(position.x, maximum.x), y: min(position.y, maximum.y)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func revealSearchMatch(_ range: NSRange) {
        guard isEditable else { return }
        pendingSourcePosition = nil
        editor.setSelectedRange(range)
        if sourceVisible { editor.scrollRangeToVisible(range) }
    }

    var diskUnavailable = false { didSet { updateDirty() } }
    var busy = false
    var markdownMode = MarkdownMode.split
    var isMarkdown: Bool { isEditable && file.url.pathExtension.lowercased() == "md" }
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
        guard isEditable else { return }
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

    /// Edited since it opened or last reloaded from disk, even if the edits were saved or undone.
    var hasEdits: Bool { isEditable && (undo.canUndo || undo.canRedo) }

    convenience init(file: TextFile) { self.init(file: .text(file)) }

    init(file: DocumentFile) {
        self.file = file
        super.init()
        guard file.isText else { return }
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
        guard isEditable else { nativePreview?.applyTheme(); return }
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

    /// Copies the selection after itself, or the caret's line below it, and moves to the copy.
    func duplicateLine() {
        guard editor.isEditable, !busy else { return }
        let text = editor.string as NSString
        let selection = editor.selectedRange()
        if selection.length > 0 {
            replace(NSRange(location: NSMaxRange(selection), length: 0), with: text.substring(with: selection))
            editor.setSelectedRange(NSRange(location: NSMaxRange(selection), length: selection.length))
            return
        }
        let line = text.lineRange(for: selection)
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: selection)
        // The last line has no break of its own, so the copy starts with one.
        let lineBreak = contentsEnd == NSMaxRange(line) ? file.newline : ""
        replace(NSRange(location: NSMaxRange(line), length: 0), with: lineBreak + text.substring(with: line))
        editor.setSelectedRange(NSRange(location: NSMaxRange(line) + (lineBreak as NSString).length
                                        + selection.location - line.location, length: 0))
    }

    /// Removes every line the selection touches; the caret keeps its column on the line that follows.
    func deleteLine() {
        guard editor.isEditable, !busy else { return }
        let text = editor.string as NSString
        let selection = editor.selectedRange()
        var removed = text.lineRange(for: selection)
        let column = selection.location - removed.location
        var lineStart = removed.location
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: selection)
        if contentsEnd == NSMaxRange(removed) && removed.location > 0 {
            // The last line also takes the break before it, so no empty line is left behind.
            text.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd,
                              for: NSRange(location: removed.location - 1, length: 0))
            removed = NSRange(location: contentsEnd, length: NSMaxRange(removed) - contentsEnd)
        }
        guard removed.length > 0 else { return }
        replace(removed, with: "")
        let remaining = editor.string as NSString
        remaining.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
        editor.setSelectedRange(NSRange(location: min(lineStart + column, contentsEnd), length: 0))
    }

    /// Swaps every line the selection touches with the line above or below; the selection moves along.
    func moveLine(up: Bool) {
        guard editor.isEditable, !busy else { return }
        let text = editor.string as NSString
        let selection = editor.selectedRange()
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: selection)
        let block = text.substring(with: NSRange(location: start, length: contentsEnd - start))
        let blockBreak = text.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))
        if up {
            guard start > 0 else { return }
            var other = 0, otherEnd = 0
            text.getLineStart(&other, end: nil, contentsEnd: &otherEnd, for: NSRange(location: start - 1, length: 0))
            let line = text.substring(with: NSRange(location: other, length: otherEnd - other))
            let lineBreak = text.substring(with: NSRange(location: otherEnd, length: start - otherEnd))
            replace(NSRange(location: other, length: end - other), with: block + lineBreak + line + blockBreak)
            editor.setSelectedRange(NSRange(location: selection.location - (start - other), length: selection.length))
        } else {
            guard end < text.length else { return }
            var otherEnd = 0, otherContentsEnd = 0
            text.getLineStart(nil, end: &otherEnd, contentsEnd: &otherContentsEnd, for: NSRange(location: end, length: 0))
            let line = text.substring(with: NSRange(location: end, length: otherContentsEnd - end))
            let lineBreak = text.substring(with: NSRange(location: otherContentsEnd, length: otherEnd - otherContentsEnd))
            replace(NSRange(location: start, length: otherEnd - start), with: line + blockBreak + block + lineBreak)
            editor.setSelectedRange(NSRange(location: selection.location + (line as NSString).length
                                            + (blockBreak as NSString).length, length: selection.length))
        }
    }

    /// One undo step per command, through the delegate so line breaks follow the file.
    private func replace(_ range: NSRange, with string: String) {
        editor.breakUndoCoalescing()
        editor.insertText(string, replacementRange: range)
        editor.breakUndoCoalescing()
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedCharacters) {
            updateDirty()
            scheduleHighlighting()
            onContentChange?()
        }
    }

    private func updateDirty() {
        let dirty = isEditable && (diskUnavailable || !editor.string.utf8.elementsEqual(file.text.utf8))
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

    /// The same file at a new path: the buffer, undo history and dirty state stay.
    func move(to file: DocumentFile) {
        let language = SyntaxHighlighting.languageID(for: self.file.url)
        self.file = file
        // A new extension can change the language; clear the old colors at once.
        guard isEditable, SyntaxHighlighting.languageID(for: file.url) != language else { return }
        scheduleHighlighting()
        renderSyntax()
    }

    func reload(_ file: DocumentFile) {
        guard isEditable, file.isText else {
            nativePreview?.view.removeFromSuperview()
            nativePreview = nil
            self.file = file
            diskUnavailable = false
            onContentChange?()
            return
        }
        let selection = editor.selectedRange()
        let position = scrollPosition
        diskUnavailable = false
        self.file = file
        editor.string = file.text
        editor.undoManager?.removeAllActions()
        editor.setSelectedRange(NSRange(location: min(selection.location, editor.string.utf16.count), length: 0))
        restoreScrollPosition(position)
        restoreSourceScrollAfterLayout()
        scheduleHighlighting()
        onContentChange?()
        updateDirty()
    }
}
