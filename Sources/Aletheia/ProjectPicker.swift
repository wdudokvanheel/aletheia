import AppKit

struct PickerProject: Codable, Equatable, Sendable {
    var name: String
    var directory: URL

    init(name: String, directory: URL) {
        self.name = name
        self.directory = URL(fileURLWithPath: directory.resolvingSymlinksInPath().standardizedFileURL.path, isDirectory: true)
    }
}

struct ProjectCatalog: Sendable {
    var projects: [PickerProject]
    var notice: String?

    /// Worker-only: reads immediate project folders.
    static func read(base: URL) -> Self {
        var folders: [(URL, Date)] = []
        var notice: String?
        do {
            for url in try FileManager.default.contentsOfDirectory(at: base,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                if values?.isDirectory == true { folders.append((url, values?.contentModificationDate ?? .distantPast)) }
            }
        } catch { notice = "Cannot read base folder: \(error.localizedDescription)" }
        folders.sort { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
        var paths = Set<URL>()
        let projects = folders.compactMap { folder -> PickerProject? in
            let project = PickerProject(name: folder.0.lastPathComponent, directory: folder.0)
            return paths.insert(project.directory).inserted ? project : nil
        }
        return Self(projects: projects, notice: notice)
    }

    /// Name relevance wins over parent-directory matches; ties retain catalog order.
    static func matchScore(_ project: PickerProject, query: String) -> Int? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return 0 }
        func score(_ text: String) -> Int? {
            let text = text.lowercased()
            if text == query { return 0 }
            if text.hasPrefix(query) { return 100 + min(text.count - query.count, 99) }
            if let range = text.range(of: query) {
                return 200 + min(text.distance(from: text.startIndex, to: range.lowerBound), 99)
            }
            var remaining = Array(query)[...]
            var first: Int?
            var last = 0
            for (index, character) in text.enumerated() where character == remaining.first {
                if first == nil { first = index }
                last = index
                remaining = remaining.dropFirst()
                if remaining.isEmpty { break }
            }
            guard remaining.isEmpty, let first else { return nil }
            return 300 + min(last - first + first / 2, 699)
        }
        if let nameScore = score(project.name) { return nameScore }
        return score(project.directory.path).map { 1000 + $0 }
    }

    static func matches(_ project: PickerProject, query: String) -> Bool {
        matchScore(project, query: query) != nil
    }

    static func ranked(_ projects: [PickerProject], query: String) -> [PickerProject] {
        var scored: [(index: Int, project: PickerProject, score: Int)] = []
        for (index, project) in projects.enumerated() {
            if let score = matchScore(project, query: query) { scored.append((index, project, score)) }
        }
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score < rhs.score
        }
        return scored.map(\.project)
    }

}

private final class ProjectPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var handleKey: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class ProjectPicker: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let search = NSSearchField()
    private let table = NSTableView()
    private let heading = NSTextField(labelWithString: "PROJECTS")
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let settings: ProjectSettings
    private var projects: [PickerProject] = []
    private var filtered: [PickerProject] = []
    private var generation = UUID()
    private var onSelect: ((URL) -> Void)?
    private var loading = false
    private var notice: String?

    init(settings: ProjectSettings = .shared) {
        self.settings = settings
        let panel = ProjectPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 780),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Open Project"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView!.wantsLayer = true
        panel.contentView!.layer?.cornerRadius = 14
        panel.contentView!.layer?.masksToBounds = true
        panel.contentView!.layer?.borderWidth = 1
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.handleKey = { [weak self] in self?.handleKey($0) ?? false }
        heading.font = .systemFont(ofSize: 12, weight: .bold)
        search.controlSize = .large
        search.font = .systemFont(ofSize: 17)
        search.placeholderString = "Search projects"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        table.addTableColumn(column)
        table.headerView = nil
        table.refusesFirstResponder = true
        table.rowHeight = 40
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(acceptRow)
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, search, scroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -16),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        panel.minSize = NSSize(width: 420, height: 280)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(relativeTo parent: NSWindow?, onSelect: @escaping (URL) -> Void) {
        generation = UUID()
        let request = generation
        self.onSelect = onSelect
        projects = []
        search.stringValue = ""
        loading = true
        notice = nil
        refresh()
        let palette = AppSettings.shared.palette
        window?.appearance = palette.isDark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! }
        window?.contentView?.layer?.backgroundColor = palette.background.cgColor
        window?.contentView?.layer?.borderColor = palette.accent.withAlphaComponent(0.35).cgColor
        table.backgroundColor = palette.background
        scroll.backgroundColor = palette.background
        heading.textColor = palette.accent
        status.textColor = palette.staged
        if let window, let screen = parent?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 24, dy: 24)
            let size = NSSize(width: min(780, visible.width), height: min(820, visible.height * 0.9))
            let center = parent?.frame ?? visible
            window.setFrame(NSRect(x: min(max(center.midX - size.width / 2, visible.minX), visible.maxX - size.width),
                                   y: min(max(center.midY - size.height / 2, visible.minY), visible.maxY - size.height),
                                   width: size.width, height: size.height), display: true)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
        let base = settings.baseDirectory
        Task { [weak self] in
            let catalog = await Task.detached(priority: .userInitiated) { ProjectCatalog.read(base: base) }.value
            guard let self, self.generation == request, self.onSelect != nil else { return }
            self.projects = catalog.projects
            for project in self.settings.assignments.compactMap({ $0 }) where !self.projects.contains(project) {
                self.projects.append(project)
            }
            self.loading = false
            self.notice = catalog.notice
            self.refresh()
        }
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }
    func windowWillClose(_ notification: Notification) { generation = UUID(); onSelect = nil }
    func windowDidResignKey(_ notification: Notification) { close() }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let project = filtered[row]
        let numbers = settings.assignments.enumerated().compactMap { index, assigned in
            assigned == project ? ProjectSettings.digits[index] : nil
        }.joined(separator: ",")
        let palette = AppSettings.shared.palette
        let badge = NSTextField(labelWithString: numbers.isEmpty ? "·" : numbers)
        badge.font = .monospacedDigitSystemFont(ofSize: 16, weight: .bold)
        badge.alignment = .center
        badge.textColor = numbers.isEmpty ? palette.muted : palette.modified
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.backgroundColor = palette.modified.withAlphaComponent(numbers.isEmpty ? 0 : 0.16).cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = numbers.isEmpty ? palette.accent : palette.added
        let name = NSTextField(labelWithString: project.name)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.textColor = palette.foreground
        name.lineBreakMode = .byTruncatingTail
        let path = NSTextField(labelWithString: (project.directory.path as NSString).abbreviatingWithTildeInPath)
        path.font = .systemFont(ofSize: 11)
        path.textColor = palette.muted
        path.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [name, path])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let rowView = NSView()
        for view in [badge, icon, labels] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rowView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: max(30, CGFloat(numbers.count * 11 + 12))),
            badge.heightAnchor.constraint(equalToConstant: 24),
            icon.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            name.widthAnchor.constraint(equalTo: labels.widthAnchor),
            path.widthAnchor.constraint(equalTo: labels.widthAnchor)
        ])
        return rowView
    }

    private func refresh() {
        filtered = ProjectCatalog.ranked(projects, query: search.stringValue)
        table.reloadData()
        table.selectRowIndexes(filtered.isEmpty ? [] : IndexSet(integer: 0), byExtendingSelection: false)
        status.stringValue = loading ? "Loading projects…" : notice ?? (filtered.isEmpty ? "No matching projects." : "\(filtered.count) projects   ·   ↑ ↓ select   ·   Return open   ·   Esc cancel   ·   1–9, 0 shortcuts")
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 53: close(); return true
        case 36, 76: acceptRow(); return true
        case 125, 126:
            guard !filtered.isEmpty else { return true }
            let row = max(0, min(filtered.count - 1, table.selectedRow + (event.keyCode == 125 ? 1 : -1)))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        default:
            if search.stringValue.isEmpty, let digit = event.characters,
               let index = ProjectSettings.digits.firstIndex(of: digit) {
                if let project = settings.assignments[index] { select(project) }
                return true
            }
            return false
        }
    }

    @objc private func acceptRow() {
        guard !loading, filtered.indices.contains(table.selectedRow) else { return }
        select(filtered[table.selectedRow])
    }

    private func select(_ project: PickerProject) {
        let callback = onSelect
        close()
        callback?(project.directory)
    }
}
