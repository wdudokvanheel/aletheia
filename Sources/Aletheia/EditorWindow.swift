import AppKit

@MainActor
final class EditorTabView: NSView {
    var onMiddleClick: (() -> Void)?

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onMiddleClick?() }
        else { super.otherMouseDown(with: event) }
    }
    var selected = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if selected {
            AppSettings.shared.palette.background.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            AppSettings.shared.palette.accent.setFill()
            NSRect(x: 8, y: 0, width: bounds.width - 16, height: 2).fill()
        } else {
            NSColor.separatorColor.setFill()
            NSRect(x: bounds.width - 1, y: 9, width: 1, height: bounds.height - 18).fill()
        }
    }
}

@MainActor
private final class EditorHostView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        AppSettings.shared.palette.background.setFill()
        bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class EditorWindow: NSWindowController, NSWindowDelegate {
    private let tree = FolderTree()
    private let tabs = NSStackView()
    private let tabScroll = NSScrollView()
    private let editorHost = EditorHostView()
    private let split = PaneSplitView(proportional: false, preferredSize: 230)
    private let markdownSplit = PaneSplitView(proportional: true, preferredSize: 0.5)
    private var contentConstraints: [NSLayoutConstraint] = []
    private let modeControl = NSSegmentedControl(labels: ["Editor", "Split", "Preview"],
        trackingMode: .selectOne, target: nil, action: nil)
    private var preview: MarkdownPreview?
    private let placeholder = NSTextField(labelWithString: "Open a folder or file from the File menu")
    private var documents: [EditorDocument] = []
    private var selected: EditorDocument?
    private var rootURL: URL?
    private var approvedClose = false
    private var closing = false
    private var closed = false
    private var restoring = false
    private var closingSession: WindowSession?
    var projectURL: URL? { rootURL }
    var onActivate: (() -> Void)?
    var onClose: ((WindowSession) -> Void)?

    var session: WindowSession {
        WindowSession(frame: window?.frame ?? .zero, rootPath: rootURL?.path,
                      filePaths: documents.map { $0.file.requestedURL.path },
                      selectedPath: selected?.file.requestedURL.path,
                      markdownModes: Dictionary(uniqueKeysWithValues: documents.filter(\.isMarkdown).map {
                          ($0.file.requestedURL.path, $0.markdownMode)
                      }), treeState: tree.session,
                      scrollPositions: Dictionary(uniqueKeysWithValues: documents.map {
                          ($0.file.requestedURL.path, $0.scrollPosition)
                      }), treeWidth: split.preferredSize, editorFraction: markdownSplit.preferredSize)
    }

    func restore(_ state: WindowSession, completion: @escaping @MainActor ([String]) -> Void) {
        restoring = true
        if let width = state.treeWidth, width.isFinite, width > 0 { split.preferredSize = width }
        if let fraction = state.editorFraction, fraction.isFinite, fraction > 0, fraction < 1 {
            markdownSplit.preferredSize = fraction
        }
        window?.setFrame(state.visibleFrame(on: NSScreen.screens.map(\.visibleFrame)), display: true)
        split.applyPreferredSize()
        DispatchQueue.global(qos: .userInitiated).async {
            var skipped: [String] = []
            var root: URL?
            if let path = state.rootPath {
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &directory),
                   directory.boolValue, FileManager.default.isReadableFile(atPath: path) {
                    root = URL(fileURLWithPath: path)
                } else { skipped.append(path) }
            }
            // Read in snapshot order and install together, so completion timing cannot reorder tabs.
            var files: [TextFile] = []
            for path in state.filePaths {
                do { files.append(try TextFile.read(URL(fileURLWithPath: path))) }
                catch { skipped.append("\(path): \(error.localizedDescription)") }
            }
            let restoredRoot = root
            let restoredFiles = files
            let failures = skipped
            DispatchQueue.main.async {
                guard !self.closed else { completion(failures); return }
                if let restoredRoot {
                    self.setRoot(restoredRoot)
                    if let treeState = state.treeState { self.tree.restore(treeState) }
                }
                for file in restoredFiles where !self.documents.contains(where: { $0.file.url == file.url }) {
                    let document = EditorDocument(file: file)
                    self.configure(document)
                    document.markdownMode = state.markdownModes?[file.requestedURL.path] ?? .split
                    document.restoreScrollPosition(state.scrollPositions?[file.requestedURL.path] ?? FileScrollPosition())
                    self.documents.append(document)
                }
                let selected = self.documents.first { $0.file.requestedURL.path == state.selectedPath }
                self.select(selected ?? self.documents.first)
                self.restoring = false
                completion(failures)
            }
        }
    }

    var hasRoot: Bool { rootURL != nil }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = AppMetadata.title
        window.minSize = NSSize(width: 620, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildLayout()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
            name: AppSettings.didChange, object: nil)
        applyTheme()
        tree.onOpen = { [weak self] in self?.openFile($0) }
        tree.onError = { [weak self] in self?.present($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildLayout() {
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        let right = NSView()
        split.addArrangedSubview(tree.scroll)
        split.addArrangedSubview(right)
        window?.contentView = split
        split.applyPreferredSize()

        tabScroll.hasHorizontalScroller = true
        tabScroll.autohidesScrollers = true
        tabScroll.drawsBackground = true
        tabScroll.backgroundColor = .windowBackgroundColor
        tabScroll.scrollerStyle = .overlay
        tabs.orientation = .horizontal
        tabs.spacing = 3
        tabs.alignment = .centerY
        tabs.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        tabScroll.documentView = tabs
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        editorHost.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [tabScroll, modeControl])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        header.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(header)
        right.addSubview(editorHost)
        modeControl.target = self
        modeControl.action = #selector(changeMarkdownMode(_:))
        modeControl.controlSize = .small
        modeControl.isHidden = true
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        markdownSplit.isVertical = true
        markdownSplit.dividerStyle = .thin
        markdownSplit.autoresizingMask = [.width, .height]
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: right.topAnchor),
            header.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            tabScroll.heightAnchor.constraint(equalToConstant: 44),
            tabs.heightAnchor.constraint(equalTo: tabScroll.contentView.heightAnchor),
            editorHost.topAnchor.constraint(equalTo: header.bottomAnchor),
            editorHost.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            editorHost.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            editorHost.bottomAnchor.constraint(equalTo: right.bottomAnchor)
        ])
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        editorHost.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: editorHost.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: editorHost.centerYAnchor)
        ])
    }

    func setRoot(_ url: URL) {
        rootURL = url.resolvingSymlinksInPath()
        tree.setRoot(rootURL!)
        updateTitle()
    }

    func openFile(_ url: URL) {
        guard !closing, !closed, !restoring else { return }
        let canonical = url.resolvingSymlinksInPath()
        if let existing = documents.first(where: { $0.file.url == canonical }) {
            select(existing)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try TextFile.read(url) }
            DispatchQueue.main.async {
                guard !self.closed, !self.closing else { return }
                switch result {
                case .success(let file):
                    if let existing = self.documents.first(where: { $0.file.url == file.url }) {
                        self.select(existing)
                        return
                    }
                    if self.rootURL == nil { self.setRoot(file.url.deletingLastPathComponent()) }
                    let document = EditorDocument(file: file)
                    self.configure(document)
                    self.documents.append(document)
                    self.select(document)
                case .failure(let error): self.present(error)
                }
            }
        }
    }

    private func configure(_ document: EditorDocument) {
        document.applyTheme()
        document.onChange = { [weak self] in self?.refreshTabs(); self?.updateTitle() }
        document.onContentChange = { [weak self, weak document] in
            guard let self, let document, self.selected === document,
                  document.isMarkdown, document.markdownMode != .editor else { return }
            self.preview?.contentChanged()
        }
    }

    private func select(_ document: EditorDocument?) {
        selected?.setSourceVisible(false)
        selected?.setHighlightingActive(false)
        selected?.scroll.removeFromSuperview()
        selected = document
        layoutEditor()
        refreshTabs()
        updateTitle()
    }

    @objc private func changeMarkdownMode(_ sender: NSSegmentedControl) {
        guard let selected, selected.isMarkdown,
              MarkdownMode.allCases.indices.contains(sender.selectedSegment) else { return }
        selected.markdownMode = MarkdownMode.allCases[sender.selectedSegment]
        layoutEditor()
    }

    private func layoutEditor() {
        selected?.setSourceVisible(false)
        for view in markdownSplit.arrangedSubviews {
            markdownSplit.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        markdownSplit.removeFromSuperview()
        NSLayoutConstraint.deactivate(contentConstraints)
        contentConstraints.removeAll()
        selected?.scroll.removeFromSuperview()
        preview?.webView.removeFromSuperview()
        placeholder.isHidden = selected != nil
        modeControl.isHidden = selected?.isMarkdown != true
        guard let document = selected else { preview?.show(nil); return }
        let mode = document.isMarkdown ? document.markdownMode : .editor
        modeControl.selectedSegment = MarkdownMode.allCases.firstIndex(of: mode)!
        if mode != .editor, preview == nil {
            preview = MarkdownPreview()
            preview?.onOpen = { [weak self] in self?.openFile($0) }
        }
        preview?.show(mode == .editor ? nil : document)
        let content: NSView
        switch mode {
        case .editor: content = document.scroll
        case .preview: content = preview!.webView
        case .split:
            document.scroll.translatesAutoresizingMaskIntoConstraints = true
            preview!.webView.translatesAutoresizingMaskIntoConstraints = true
            document.scroll.isHidden = false
            preview!.webView.isHidden = false
            content = markdownSplit
        }
        content.isHidden = false
        content.translatesAutoresizingMaskIntoConstraints = false
        editorHost.addSubview(content)
        contentConstraints = [
            content.leadingAnchor.constraint(equalTo: editorHost.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: editorHost.trailingAnchor),
            content.topAnchor.constraint(equalTo: editorHost.topAnchor),
            content.bottomAnchor.constraint(equalTo: editorHost.bottomAnchor)
        ]
        NSLayoutConstraint.activate(contentConstraints)
        editorHost.layoutSubtreeIfNeeded()
        if mode == .split {
            markdownSplit.addArrangedSubview(document.scroll)
            markdownSplit.addArrangedSubview(preview!.webView)
            markdownSplit.applyPreferredSize()
        }
        document.setHighlightingActive(mode != .preview)
        window?.makeFirstResponder(mode == .preview ? preview!.webView : document.editor)
        editorHost.layoutSubtreeIfNeeded()
        document.setSourceVisible(mode != .preview)
    }

    private func refreshTabs() {
        for view in tabs.arrangedSubviews { tabs.removeArrangedSubview(view); view.removeFromSuperview() }
        var selectedTab: NSView?
        for (index, document) in documents.enumerated() {
            let group = EditorTabView()
            group.selected = document === selected
            group.onMiddleClick = { [weak self, weak document] in
                guard let document else { return }
                self?.close(document)
            }
            group.translatesAutoresizingMaskIntoConstraints = false
            let button = NSButton(title: document.file.url.lastPathComponent,
                                  target: self, action: #selector(selectTab(_:)))
            button.tag = index
            button.isBordered = false
            button.setButtonType(.momentaryChange)
            button.font = .systemFont(ofSize: 14, weight: group.selected ? .medium : .regular)
            button.contentTintColor = group.selected ? AppSettings.shared.palette.foreground : AppSettings.shared.palette.muted
            button.lineBreakMode = .byTruncatingMiddle
            button.toolTip = document.file.requestedURL.path
            let dirty = NSTextField(labelWithString: document.isDirty ? "●" : "")
            dirty.font = .systemFont(ofSize: 9)
            dirty.textColor = AppSettings.shared.palette.muted
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")!,
                                 target: self, action: #selector(closeTabButton(_:)))
            close.isBordered = false
            close.contentTintColor = AppSettings.shared.palette.muted
            close.imageScaling = .scaleProportionallyDown
            close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            close.tag = index
            close.isEnabled = !document.busy && !closing
            for view in [button, dirty, close] {
                view.translatesAutoresizingMaskIntoConstraints = false
                group.addSubview(view)
            }
            let titleWidth = (button.title as NSString).size(withAttributes: [.font: button.font!]).width
            NSLayoutConstraint.activate([
                group.widthAnchor.constraint(equalToConstant: min(280, max(150, titleWidth + 76))),
                group.heightAnchor.constraint(equalToConstant: 36),
                button.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 10),
                button.topAnchor.constraint(equalTo: group.topAnchor),
                button.bottomAnchor.constraint(equalTo: group.bottomAnchor),
                button.trailingAnchor.constraint(equalTo: dirty.leadingAnchor, constant: -5),
                dirty.widthAnchor.constraint(equalToConstant: 10),
                dirty.centerYAnchor.constraint(equalTo: group.centerYAnchor),
                dirty.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
                close.widthAnchor.constraint(equalToConstant: 24),
                close.heightAnchor.constraint(equalToConstant: 26),
                close.centerYAnchor.constraint(equalTo: group.centerYAnchor),
                close.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -4)
            ])
            tabs.addArrangedSubview(group)
            if group.selected { selectedTab = group }
        }
        tabs.layoutSubtreeIfNeeded()
        tabs.setFrameSize(NSSize(width: tabs.fittingSize.width, height: tabScroll.contentSize.height))
        tabs.layoutSubtreeIfNeeded()
        if let selectedTab { tabs.scrollToVisible(selectedTab.frame) }
    }

    @objc private func applyTheme() {
        let palette = AppSettings.shared.palette
        window?.appearance = palette.isDark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! }
        window?.backgroundColor = palette.surface
        tabScroll.backgroundColor = palette.surface
        editorHost.needsDisplay = true
        placeholder.textColor = palette.muted
        documents.forEach { $0.applyTheme() }
        tree.applyTheme()
        preview?.applyTheme()
        refreshTabs()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        tree.refreshGitStatus()
        selected?.restoreSourceScrollAfterLayout()
        onActivate?()
    }

    func windowDidResize(_ notification: Notification) {
        selected?.restoreSourceScrollAfterLayout()
        guard let selected, let index = documents.firstIndex(where: { $0 === selected }),
              index < tabs.arrangedSubviews.count else { return }
        tabs.scrollToVisible(tabs.arrangedSubviews[index].frame)
    }

    private func updateTitle() {
        let context = [selected?.file.url.lastPathComponent, rootURL?.lastPathComponent]
            .compactMap { $0 }
        window?.title = (context + [AppMetadata.title]).joined(separator: " — ")
        window?.representedURL = selected?.file.requestedURL
        window?.isDocumentEdited = documents.contains(where: \.isDirty)
    }

    @objc private func selectTab(_ sender: NSButton) { select(documents[sender.tag]) }
    @objc private func closeTabButton(_ sender: NSButton) { close(documents[sender.tag]) }
    @objc func closeSelectedTab(_ sender: Any?) {
        if let selected { close(selected) } else { window?.performClose(sender) }
    }
    @objc func saveSelected(_ sender: Any?) {
        if let selected { save(selected) { _ in } }
    }

    private func close(_ document: EditorDocument) {
        guard !closing, !document.busy else { NSSound.beep(); return }
        closing = true
        confirm(document) { allowed in
            self.cancelPreparedClose()
            guard allowed, let index = self.documents.firstIndex(where: { $0 === document }) else { return }
            self.documents.remove(at: index)
            if self.selected === document {
                self.select(self.documents.isEmpty ? nil : self.documents[min(index, self.documents.count - 1)])
            } else { self.refreshTabs(); self.updateTitle() }
        }
    }

    private func confirm(_ document: EditorDocument, completion: @escaping @MainActor (Bool) -> Void) {
        guard !document.busy else { NSSound.beep(); completion(false); return }
        guard document.isDirty else { completion(true); return }
        select(document)
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(document.file.url.lastPathComponent)”?"
        alert.informativeText = "Your changes will be lost if you discard them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window!) { response in
            switch response {
            case .alertFirstButtonReturn: self.save(document, completion: completion)
            case .alertSecondButtonReturn: completion(true)
            default: completion(false)
            }
        }
    }

    private func save(_ document: EditorDocument, completion: @escaping @MainActor (Bool) -> Void) {
        guard !document.busy else { completion(false); return }
        guard document.isDirty else { completion(true); return }
        document.editor.breakUndoCoalescing()
        document.busy = true
        document.editor.isEditable = false
        let text = document.editor.string
        let file = document.file
        refreshTabs()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try file.save(text) }
            DispatchQueue.main.async {
                document.busy = false
                document.editor.isEditable = !self.closing
                switch result {
                case .success(let saved):
                    document.file = saved
                    self.tree.refreshGitStatus()
                    self.refreshTabs()
                    self.updateTitle()
                    completion(true)
                case .failure(TextFile.FileError.changed):
                    self.resolveConflict(document, completion: completion)
                case .failure(let error):
                    self.refreshTabs()
                    self.present(error)
                    completion(false)
                }
            }
        }
    }

    private func resolveConflict(_ document: EditorDocument, completion: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(document.file.url.lastPathComponent)” changed on disk"
        alert.informativeText = "Reload discards your unsaved edits and reads the current file. Keep Edits retains your buffer without overwriting the file."
        alert.addButton(withTitle: "Keep Edits")
        alert.addButton(withTitle: "Reload from Disk")
        alert.beginSheetModal(for: window!) { response in
            guard response == .alertSecondButtonReturn else {
                self.refreshTabs()
                completion(false)
                return
            }
            document.busy = true
            document.editor.isEditable = false
            let requestedURL = document.file.requestedURL
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try TextFile.read(requestedURL) }
                DispatchQueue.main.async {
                    document.busy = false
                    document.editor.isEditable = !self.closing
                    switch result {
                    case .success(let file):
                        // Reload explicitly abandons these edits, but cancels any pending close.
                        document.reload(file)
                    case .failure(let error): self.present(error)
                    }
                    self.refreshTabs()
                    completion(false)
                }
            }
        }
    }

    func prepareToClose(completion: @escaping @MainActor (Bool) -> Void) {
        guard !closing, !restoring, !documents.contains(where: \.busy) else { NSSound.beep(); completion(false); return }
        closing = true
        // Freeze all buffers during a multi-document decision, so earlier approvals stay valid.
        documents.forEach { $0.editor.isEditable = false }
        confirmNext(documents, index: 0) { allowed in
            if !allowed { self.cancelPreparedClose() }
            completion(allowed)
        }
    }

    func cancelPreparedClose() {
        closing = false
        documents.forEach { $0.editor.isEditable = !$0.busy }
        refreshTabs()
    }

    private func confirmNext(_ documents: [EditorDocument], index: Int, completion: @escaping @MainActor (Bool) -> Void) {
        guard index < documents.count else { completion(true); return }
        confirm(documents[index]) { allowed in
            if allowed { self.confirmNext(documents, index: index + 1, completion: completion) }
            else { completion(false) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if approvedClose { return true }
        let candidate = session
        prepareToClose { allowed in
            if allowed {
                self.closingSession = candidate
                self.approvedClose = true
                sender.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        preview?.show(nil)
        onClose?(closingSession ?? session)
    }

    private func present(_ error: Error) {
        guard !closed, let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}
