import AppKit

@MainActor
final class ProjectSettings {
    static let shared = ProjectSettings()
    static let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    private let defaults: UserDefaults
    private static let baseKey = "projectBaseDirectory"
    private static let assignmentsKey = "numberedProjects"
    private static let seededKey = "numberedProjectsInitialized"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var baseDirectory: URL {
        get {
            defaults.string(forKey: Self.baseKey).map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("workspace")
        }
        set { defaults.set(newValue.resolvingSymlinksInPath().standardizedFileURL.path, forKey: Self.baseKey) }
    }

    var assignments: [PickerProject?] {
        guard let data = defaults.data(forKey: Self.assignmentsKey),
              let values = try? JSONDecoder().decode([PickerProject?].self, from: data) else {
            return Array(repeating: nil, count: 10)
        }
        return Array((values + Array(repeating: nil, count: 10)).prefix(10))
    }

    func assign(_ project: PickerProject?, to index: Int) {
        guard (0..<10).contains(index) else { return }
        var values = assignments
        values[index] = project
        save(values)
    }

    func seedIfNeeded(_ running: [PickerProject]) {
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        save(Array((running.map(Optional.some) + Array(repeating: nil, count: 10)).prefix(10)))
    }

    private func save(_ values: [PickerProject?]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.assignmentsKey)
        defaults.set(true, forKey: Self.seededKey)
    }
}

/// Embedded in the existing Settings window; each assignment is an explicit folder choice.
@MainActor
final class ProjectSettingsView: NSStackView {
    private let settings: ProjectSettings
    private let baseLabel = NSTextField(labelWithString: "")
    private var labels: [NSTextField] = []
    private var refreshGeneration = UUID()

    init(settings: ProjectSettings) {
        self.settings = settings
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        let heading = NSTextField(labelWithString: "Projects")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        addArrangedSubview(heading)
        let baseButton = NSButton(title: "Base Folder…", target: self, action: #selector(chooseBase))
        addRow(label: baseLabel, controls: [baseButton])
        let note = NSTextField(labelWithString: "Number keys open these projects when the project search is empty.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        addArrangedSubview(note)
        for index in 0..<10 {
            let label = NSTextField(labelWithString: "")
            labels.append(label)
            let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseProject(_:)))
            choose.tag = index
            let clear = NSButton(title: "Clear", target: self, action: #selector(clearProject(_:)))
            clear.tag = index
            addRow(label: label, controls: [choose, clear])
        }
        updateLabels()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        updateLabels()
        refreshGeneration = UUID()
        let request = refreshGeneration
        let base = settings.baseDirectory
        Task { [weak self] in
            let catalog = await Task.detached(priority: .userInitiated) { ProjectCatalog.read(base: base) }.value
            guard let self, self.refreshGeneration == request else { return }
            self.settings.seedIfNeeded(catalog.running)
            self.updateLabels()
        }
    }

    private func addRow(label: NSTextField, controls: [NSView]) {
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label] + controls)
        row.spacing = 8
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func updateLabels() {
        baseLabel.stringValue = settings.baseDirectory.path
        baseLabel.toolTip = baseLabel.stringValue
        for (index, label) in labels.enumerated() {
            let project = settings.assignments[index]
            label.stringValue = "\(ProjectSettings.digits[index])  " + (project.map { "\($0.name) — \($0.directory.path)" } ?? "Unassigned")
            label.toolTip = project?.directory.path
        }
    }

    private func chooseFolder(initial: URL, completion: @escaping (URL) -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = initial
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { completion(url) }
        }
    }

    @objc private func chooseBase() {
        chooseFolder(initial: settings.baseDirectory) { [weak self] url in
            self?.settings.baseDirectory = url
            self?.updateLabels()
        }
    }

    @objc private func chooseProject(_ sender: NSButton) {
        let index = sender.tag
        chooseFolder(initial: settings.assignments[index]?.directory ?? settings.baseDirectory) { [weak self] url in
            self?.settings.assign(PickerProject(name: url.lastPathComponent, directory: url), to: index)
            self?.updateLabels()
        }
    }

    @objc private func clearProject(_ sender: NSButton) {
        settings.assign(nil, to: sender.tag)
        updateLabels()
    }
}
