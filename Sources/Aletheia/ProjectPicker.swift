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
    var running: [PickerProject]
    var notice: String?

    /// Worker-only: reads immediate children and invokes tmux directly, never a shell.
    static func read(base: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let tmux = Process()
        tmux.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
        tmux.arguments = ["ls", "-F", "#{session_id}\t#{session_name}\t#{session_path}"]
        let output = Pipe()
        tmux.standardOutput = output
        tmux.standardError = FileHandle.nullDevice
        tmux.standardInput = FileHandle.nullDevice
        var sessions = ""
        do {
            try tmux.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            tmux.waitUntilExit()
            if tmux.terminationStatus == 0 { sessions = String(decoding: data, as: UTF8.self) }
        } catch { /* tmux is optional; configured projects and folders remain available. */ }
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/state")
        let order = (try? String(contentsOf: state.appendingPathComponent("tmux-pick/order"), encoding: .utf8)) ?? ""
        let keys = (try? String(contentsOf: home.appendingPathComponent(".config/tmux/session-keys"), encoding: .utf8)) ?? ""
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
        var result = assemble(sessions: sessions, order: order, keys: keys, folders: folders.map(\.0), home: home)
        result.notice = notice
        return result
    }

    static func assemble(sessions: String, order: String, keys: String, folders: [URL], home: URL) -> Self {
        let created = sessions.split(separator: "\n").compactMap { line -> (Int, PickerProject)? in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let id = Int(fields[0].dropFirst()), fields[2].hasPrefix("/") else { return nil }
            return (id, PickerProject(name: String(fields[1]), directory: URL(fileURLWithPath: String(fields[2]))))
        }.sorted { $0.0 < $1.0 }.map(\.1)
        var running: [PickerProject] = []
        var names = Set<String>()
        for name in order.split(separator: "\n").map(String.init) {
            if let project = created.first(where: { $0.name == name }), names.insert(name).inserted { running.append(project) }
        }
        for project in created where names.insert(project.name).inserted { running.append(project) }
        var projects = running
        for line in keys.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, !fields[0].hasPrefix("#"), names.insert(String(fields[1])).inserted else { continue }
            let path = String(fields[2])
            let url: URL
            if path == "~" { url = home }
            else if path.hasPrefix("~/") { url = home.appendingPathComponent(String(path.dropFirst(2))) }
            else if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
            else { continue }
            projects.append(PickerProject(name: String(fields[1]), directory: url))
        }
        var paths = Set(projects.map(\.directory))
        for folder in folders {
            let project = PickerProject(name: folder.lastPathComponent, directory: folder)
            if paths.insert(project.directory).inserted { projects.append(project) }
        }
        return Self(projects: projects, running: running)
    }

    static func matches(_ project: PickerProject, query: String) -> Bool {
        var remaining = Array(query.lowercased())[...]
        for character in (project.name + " " + project.directory.path).lowercased() {
            if character == remaining.first { remaining = remaining.dropFirst() }
        }
        return remaining.isEmpty
    }
}

private final class ProjectPanel: NSPanel {
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
        let panel = ProjectPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Open Project"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.handleKey = { [weak self] in self?.handleKey($0) ?? false }
        search.placeholderString = "Search projects"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project"))
        table.addTableColumn(column)
        table.headerView = nil
        table.refusesFirstResponder = true
        table.rowHeight = 48
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(acceptRow)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [search, scroll, status])
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
        if let parent, let window {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                          y: parent.frame.midY - window.frame.height / 2))
        } else { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
        let base = settings.baseDirectory
        Task { [weak self] in
            let catalog = await Task.detached(priority: .userInitiated) { ProjectCatalog.read(base: base) }.value
            guard let self, self.generation == request, self.onSelect != nil else { return }
            self.settings.seedIfNeeded(catalog.running)
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
        let name = NSTextField(labelWithString: (numbers.isEmpty ? "" : "\(numbers)  ") + project.name)
        name.font = .systemFont(ofSize: 14, weight: .medium)
        let path = NSTextField(labelWithString: project.directory.path)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [name, path])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func refresh() {
        filtered = projects.filter { ProjectCatalog.matches($0, query: search.stringValue) }
        table.reloadData()
        table.selectRowIndexes(filtered.isEmpty ? [] : IndexSet(integer: 0), byExtendingSelection: false)
        status.stringValue = loading ? "Loading projects…" : notice ?? (filtered.isEmpty ? "No matching projects." : "↑ ↓ select · Return open · Esc cancel · 1–9, 0 assigned projects")
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
