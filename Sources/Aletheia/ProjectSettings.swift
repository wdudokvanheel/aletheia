import AppKit

@MainActor
final class ProjectSettings {
    static let shared = ProjectSettings()
    static let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
    private let defaults: UserDefaults
    private static let baseKey = "projectBaseDirectory"
    private static let assignmentsKey = "numberedProjects"

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

    private func save(_ values: [PickerProject?]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.assignmentsKey)
    }
}

/// Native project preferences; each assignment is an explicit folder choice.
@MainActor
final class ProjectSettingsView: NSStackView {
    enum Section { case projects, shortcuts }
    private let section: Section
    private let settings: ProjectSettings
    private var assignmentMenus: [NSPopUpButton] = []
    private let baseLabel = NSTextField(labelWithString: "")

    init(settings: ProjectSettings, section: Section) {
        self.settings = settings
        self.section = section
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        if section == .projects {
            addArrangedSubview(SettingsPage.heading("Project discovery"))
            addArrangedSubview(SettingsPage.note("Choose the folder whose projects appear in the project selector."))
            let baseButton = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseBase))
            addRow(label: baseLabel, controls: [baseButton])
            addArrangedSubview(SettingsPage.note("Open the project selector with Control-S, then S."))
        } else {
            addArrangedSubview(SettingsPage.heading("Numbered projects"))
            addArrangedSubview(SettingsPage.note("Press Control-S, then S to open the project selector. With its search empty, press a number to open the assigned project."))
            let assignments = NSStackView()
            assignments.orientation = .vertical
            assignments.alignment = .leading
            assignments.spacing = 8
            for index in 0..<10 {
                let badge = NSTextField(labelWithString: ProjectSettings.digits[index])
                badge.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
                badge.alignment = .center
                badge.isBezeled = true
                badge.bezelStyle = .roundedBezel
                badge.drawsBackground = true
                badge.backgroundColor = .controlBackgroundColor
                badge.textColor = .secondaryLabelColor
                badge.widthAnchor.constraint(equalToConstant: 30).isActive = true
                let menu = NSPopUpButton(frame: .zero, pullsDown: true)
                menu.lineBreakMode = .byTruncatingMiddle
                menu.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                assignmentMenus.append(menu)
                let row = NSStackView(views: [badge, menu])
                row.alignment = .centerY
                row.spacing = 12
                assignments.addArrangedSubview(row)
                NSLayoutConstraint.activate([
                    row.widthAnchor.constraint(equalTo: assignments.widthAnchor),
                    row.heightAnchor.constraint(equalToConstant: 32)
                ])
            }
            addArrangedSubview(assignments)
            assignments.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        updateLabels()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        updateLabels()
    }

    private func addRow(label: NSTextField, controls: [NSView]) {
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label] + controls)
        row.alignment = .centerY
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        row.spacing = 8
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func updateLabels() {
        baseLabel.stringValue = settings.baseDirectory.path
        baseLabel.toolTip = baseLabel.stringValue
        let assignments = settings.assignments
        for (index, popup) in assignmentMenus.enumerated() {
            let project = assignments[index]
            popup.removeAllItems()
            // A pull-down menu's first item is its persistent button title.
            popup.addItem(withTitle: project?.name ?? "Assign a project…")
            popup.toolTip = project?.directory.path ?? "Choose a project for key \(ProjectSettings.digits[index])"
            if let project {
                let path = NSMenuItem(title: project.directory.path, action: nil, keyEquivalent: "")
                path.isEnabled = false
                popup.menu?.addItem(path)
                popup.menu?.addItem(.separator())
            }
            let choose = NSMenuItem(title: project == nil ? "Choose Folder…" : "Change Folder…",
                                    action: #selector(chooseProject(_:)), keyEquivalent: "")
            choose.target = self
            choose.tag = index
            popup.menu?.addItem(choose)
            if project != nil {
                let clear = NSMenuItem(title: "Remove Assignment", action: #selector(clearProject(_:)), keyEquivalent: "")
                clear.target = self
                clear.tag = index
                popup.menu?.addItem(clear)
            }
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

    @objc private func chooseProject(_ sender: NSMenuItem) {
        let index = sender.tag
        chooseFolder(initial: settings.assignments[index]?.directory ?? settings.baseDirectory) { [weak self] url in
            self?.settings.assign(PickerProject(name: url.lastPathComponent, directory: url), to: index)
            self?.updateLabels()
        }
    }

    @objc private func clearProject(_ sender: NSMenuItem) {
        settings.assign(nil, to: sender.tag)
        updateLabels()
    }
}
