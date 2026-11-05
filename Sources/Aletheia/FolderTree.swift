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
    }

    func setRoot(_ url: URL) {
        root = FolderNode(url: url, isDirectory: true)
        outline.reloadData()
        if let root { load(root) }
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
                        if expand { self.outline.expandItem(node) }
                        self.updateIcon(node)
                    }
                case .failure(let error):
                    // Keep nil so collapsing/re-expanding can retry after access changes.
                    self.onError?(error)
                }
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
        cell.toolTip = node.url.path
        return cell
    }

    private func configureIcon(_ cell: NSTableCellView, node: FolderNode) {
        let symbol = node.isDirectory ? (node.wantsExpanded ? "folder.fill" : "folder") : "doc"
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        cell.imageView?.contentTintColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
    }

    private func updateIcon(_ node: FolderNode) {
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return }
        configureIcon(cell, node: node)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FolderNode else { return true }
        node.wantsExpanded = true
        updateIcon(node)
        load(node)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard let node = item as? FolderNode else { return true }
        node.wantsExpanded = false
        updateIcon(node)
        return true
    }

    @objc private func openSelection() {
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
