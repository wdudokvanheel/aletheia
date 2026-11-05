import AppKit

@MainActor
final class FolderNode {
    let url: URL
    let isDirectory: Bool
    var children: [FolderNode]?
    var loading = false
    var wantsExpanded = false

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

// Keep native selection and keyboard navigation; icons replace disclosure controls.
@MainActor
private final class FileOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        super.mouseDown(with: event)
    }
}

@MainActor
final class FolderTree: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let scroll = NSScrollView()
    private let outline = FileOutlineView()
    private var root: FolderNode?
    private var pendingState: FolderTreeState?
    private var failedRestorationPaths = Set<String>()
    private var applyingRestoration = false

    var session: FolderTreeState {
        if let pendingState { return pendingState }
        var expanded: [String] = []
        func collect(_ node: FolderNode) {
            if node.wantsExpanded { expanded.append(node.url.path) }
            node.children?.forEach(collect)
        }
        root?.children?.forEach(collect)
        let selected = outline.item(atRow: outline.selectedRow) as? FolderNode
        return FolderTreeState(expandedPaths: expanded.sorted(), selectedPath: selected?.url.path,
                               scrollOrigin: scroll.contentView.bounds.origin)
    }

    func restore(_ state: FolderTreeState) {
        pendingState = state
        failedRestorationPaths.removeAll()
        restoreLoadedBranches()
    }

    @objc private func viewportChanged(_ notification: Notification) { restoreLoadedBranches() }

    private func restoreLoadedBranches() {
        guard !applyingRestoration, let state = pendingState, let root else { return }
        applyingRestoration = true
        defer { applyingRestoration = false }
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let expanded = Set(state.expandedPaths.map(canonical))
        var waiting = false
        func visit(_ node: FolderNode) {
            guard !failedRestorationPaths.contains(node.url.path) else { return }
            guard let children = node.children else {
                load(node)
                waiting = true
                return
            }
            for child in children where child.isDirectory && expanded.contains(canonical(child.url.path)) {
                outline.expandItem(child)
                visit(child)
            }
        }
        visit(root)
        guard !waiting, scroll.contentSize.width > 0, scroll.contentSize.height > 0 else { return }
        // Selection restoration must never invoke the single-click file action.
        if let path = state.selectedPath,
           let row = (0..<outline.numberOfRows).first(where: {
               (outline.item(atRow: $0) as? FolderNode).map { canonical($0.url.path) == canonical(path) } == true
           }) {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        outline.layoutSubtreeIfNeeded()
        let position = EditorDocument.validPosition(state.scrollOrigin)
        let maximum = CGPoint(x: max(0, outline.frame.width - scroll.contentSize.width),
                              y: max(0, outline.frame.height - scroll.contentSize.height))
        scroll.contentView.scroll(to: CGPoint(x: min(position.x, maximum.x), y: min(position.y, maximum.y)))
        scroll.reflectScrolledClipView(scroll.contentView)
        pendingState = nil
    }
    private var gitStatus = GitStatusSnapshot()
    private var gitRefreshTask: Task<Void, Never>?
    private var gitRefreshRunning = false
    private var gitRefreshPending = false
    var onOpen: ((URL) -> Void)?
    var onError: ((Error) -> Void)?

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 28
        outline.indentationPerLevel = 18
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(openSelection)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged(_:)),
            name: NSView.frameDidChangeNotification, object: scroll.contentView)
        applyTheme()
    }

    func setRoot(_ url: URL) {
        pendingState = nil
        failedRestorationPaths.removeAll()
        root = FolderNode(url: url, isDirectory: true)
        gitStatus = GitStatusSnapshot()
        outline.reloadData()
        if let root { load(root) }
        refreshGitStatus()
    }

    func applyTheme() {
        let palette = AppSettings.shared.palette
        scroll.backgroundColor = palette.surface
        outline.backgroundColor = palette.surface
        refreshVisibleCells()
    }

    /// Debounce bursts of expansions/saves, with at most one Git process chain in flight.
    func refreshGitStatus() {
        gitRefreshTask?.cancel()
        gitRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            self?.startGitRefresh()
        }
    }

    private func startGitRefresh() {
        guard let root else { return }
        guard !gitRefreshRunning else {
            gitRefreshPending = true
            return
        }
        gitRefreshRunning = true
        let url = root.url
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = GitStatusSnapshot.read(root: url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.gitRefreshRunning = false
                if self.root === root {
                    self.gitStatus = snapshot
                    self.refreshVisibleCells()
                }
                if self.gitRefreshPending {
                    self.gitRefreshPending = false
                    self.refreshGitStatus()
                }
            }
        }
    }

    private func refreshVisibleCells() {
        let rows = outline.rows(in: outline.visibleRect)
        guard rows.location != NSNotFound, rows.length > 0 else { return }
        for row in rows.location..<NSMaxRange(rows) {
            if let node = outline.item(atRow: row) as? FolderNode { updateIcon(node) }
        }
    }

    private func load(_ node: FolderNode) {
        guard node.children == nil, !node.loading else { return }
        node.loading = true
        let url = node.url
        let loadingRoot = root
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
                    .map { url -> (url: URL, isDirectory: Bool) in
                        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        return (url, values.isDirectory == true && values.isSymbolicLink != true)
                    }
                    .sorted {
                        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                        return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                    }
            }
            DispatchQueue.main.async {
                guard self.root === loadingRoot else { return }
                node.loading = false
                switch result {
                case .success(let children):
                    node.children = children.map { FolderNode(url: $0.url, isDirectory: $0.isDirectory) }
                    if node === self.root { self.outline.reloadData() }
                    else {
                        let expand = node.wantsExpanded
                        self.outline.reloadItem(node, reloadChildren: true)
                        if expand, self.pendingState == nil { self.outline.expandItem(node) }
                        self.updateIcon(node)
                    }
                case .failure(let error):
                    // Keep nil so collapsing/re-expanding can retry after access changes.
                    self.failedRestorationPaths.insert(node.url.path)
                    self.onError?(error)
                }
                self.restoreLoadedBranches()
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FolderNode ?? root else { return 0 }
        if node.children == nil { load(node) }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FolderNode ?? root!).children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FolderNode)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("file")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 14)
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            cell.addSubview(icon)
            cell.imageView = icon
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = node.url.lastPathComponent
        configureIcon(cell, node: node)
        return cell
    }

    private func configureIcon(_ cell: NSTableCellView, node: FolderNode) {
        let symbol = node.isDirectory ? (node.wantsExpanded ? "folder.fill" : "folder") : Self.fileSymbol(for: node.url)
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        let palette = AppSettings.shared.palette
        let status = gitStatus.status(for: node.url)
        // Conflict and removal win, then unstaged edits, additions, staged-only, untracked.
        let color: NSColor
        if status.contains(.conflict) { color = palette.conflict }
        else if status.contains(.deleted) { color = palette.deleted }
        else if status.contains(.unstaged) { color = palette.modified }
        else if status.contains(.added) { color = palette.added }
        else if status.contains(.staged) { color = palette.staged }
        else if status.contains(.untracked) { color = palette.muted }
        else { color = palette.foreground }
        cell.textField?.textColor = node.url.lastPathComponent.hasPrefix(".")
            ? color.blended(withFraction: 0.16, of: .white) ?? color : color
        cell.imageView?.contentTintColor = status.isEmpty ? (node.isDirectory ? palette.accent : palette.muted) : color
        cell.toolTip = node.url.path + (status.isEmpty ? "" : "\n" + status.description)
        if node.isDirectory && status.contains(.deleted) {
            cell.toolTip! += "\nIncludes deleted paths; files absent from disk are not listed."
        }
    }

    static func fileSymbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "rb", "go", "rs", "c", "h", "cpp", "hpp", "java", "kt", "sh", "zsh", "bash": return "chevron.left.forwardslash.chevron.right"
        case "json", "jsonc", "yaml", "yml", "toml", "xml", "plist", "ini", "conf": return "slider.horizontal.3"
        case "md", "markdown", "txt", "rtf": return "doc.text"
        case "html", "htm", "css", "scss", "sass", "less": return "globe"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "ico", "tiff": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "bz2", "xz", "7z": return "doc.zipper"
        case "mp3", "wav", "m4a", "flac", "aac": return "music.note"
        case "mp4", "mov", "mkv", "webm": return "film"
        case "ttf", "otf", "woff", "woff2": return "textformat"
        default: return "doc"
        }
    }

    private func updateIcon(_ node: FolderNode) {
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return }
        configureIcon(cell, node: node)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FolderNode else { return true }
        if !applyingRestoration { pendingState = nil }
        node.wantsExpanded = true
        refreshGitStatus()
        updateIcon(node)
        load(node)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard let node = item as? FolderNode else { return true }
        if !applyingRestoration { pendingState = nil }
        node.wantsExpanded = false
        updateIcon(node)
        return true
    }

    @objc private func openSelection() {
        pendingState = nil
        guard let node = outline.item(atRow: outline.clickedRow) as? FolderNode else { return }
        if node.isDirectory {
            if node.wantsExpanded {
                node.wantsExpanded = false
                outline.collapseItem(node)
                updateIcon(node)
            }
            else { outline.expandItem(node) }
        } else { onOpen?(node.url) }
    }
}
