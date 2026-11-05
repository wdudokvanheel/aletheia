import AppKit

@MainActor
final class FolderNode {
    let url: URL
    let isDirectory: Bool
    var children: [FolderNode]?
    var loading = false

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

@MainActor
final class FolderTree: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let scroll = NSScrollView()
    private let outline = NSOutlineView()
    private var root: FolderNode?
    var onOpen: ((URL) -> Void)?
    var onError: ((Error) -> Void)?

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .small
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(openSelection)
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
                node.loading = false
                switch result {
                case .success(let children):
                    node.children = children.map { FolderNode(url: $0.url, isDirectory: $0.isDirectory) }
                    if node === self.root { self.outline.reloadData() }
                    else {
                        self.outline.reloadItem(node, reloadChildren: true)
                        self.outline.expandItem(node)
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
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = node.url.lastPathComponent
        cell.toolTip = node.url.path
        return cell
    }

    @objc private func openSelection() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FolderNode else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) }
            else { outline.expandItem(node) }
        } else { onOpen?(node.url) }
    }
}
