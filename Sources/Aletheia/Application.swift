import AppKit

@main
struct Aletheia {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var windows: [EditorWindow] = []
    private var terminating = false
    private var launched = false
    private var restoring = false
    private var pendingOpenFiles: [String] = []
    private var quitSession: SessionState?
    private var projectSessions: ProjectSessions
    private let defaults: UserDefaults
    private weak var activeProjectWindow: EditorWindow?
    private var picker: ProjectPicker?
    private var keyMonitor: Any?
    private var prefixPending = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        projectSessions = ProjectSessions.load(from: defaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        installProjectShortcut()
        launched = true
        restoreSession()
        NSApp.activate(ignoringOtherApps: true)
    }

    private var current: EditorWindow? {
        windows.first { $0.window === NSApp.keyWindow }
            ?? windows.first { $0.window === NSApp.mainWindow } ?? windows.last
    }

    @discardableResult private func makeWindow() -> EditorWindow {
        let controller = EditorWindow()
        controller.onClose = { [weak self, weak controller] closedSession in
            guard let self else { return }
            self.windows.removeAll { $0 === controller }
            guard !self.terminating else { return }
            self.projectSessions.remember(closedSession, active: self.windows.isEmpty)
            self.persistOpenProjects()
        }
        controller.onActivate = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.prefixPending = false
            self.activeProjectWindow = controller
            guard !self.restoring, !self.terminating else { return }
            self.persistOpenProjects()
        }
        windows.append(controller)
        controller.showWindow(nil)
        return controller
    }

    @objc private func openFolder(_ sender: Any?) {
        guard !terminating, !restoring else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url, !self.terminating else { return }
            self.openProject(url)
        }
    }

    @objc private func openFiles(_ sender: Any?) {
        guard !terminating, !restoring else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Files"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.begin { result in
            guard result == .OK, !self.terminating else { return }
            self.openRequestedFiles(panel.urls.map(\.path))
        }
    }

    @objc private func save(_ sender: Any?) { if !terminating && !restoring { current?.saveSelected(sender) } }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(save(_:)) {
            return !terminating && !restoring && current?.canEditSelected == true
        }
        return true
    }
    @objc private func closeTab(_ sender: Any?) { if !terminating && !restoring { current?.closeSelectedTab(sender) } }
    @objc private func closeWindow(_ sender: Any?) { if !terminating && !restoring { current?.window?.performClose(sender) } }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if launched && !flag && !terminating && !restoring { restoreSession() }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard !terminating else { sender.reply(toOpenOrPrint: .failure); return }
        // LaunchServices may deliver these before or during launch restoration.
        pendingOpenFiles.append(contentsOf: filenames)
        if launched && !restoring { openPendingFiles() }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, !restoring else { return .terminateCancel }
        guard !windows.isEmpty else { return .terminateNow }
        // Prompts can select other dirty tabs. Remember the user's selection before they begin.
        quitSession = sessionSnapshot()
        terminating = true
        // Reply on the next turn even when every window is clean.
        let closingWindows = windows
        DispatchQueue.main.async { self.confirmQuit(closingWindows, index: 0) }
        return .terminateLater
    }

    private func confirmQuit(_ closingWindows: [EditorWindow], index: Int) {
        guard index < closingWindows.count else {
            if let state = quitSession {
                for (index, session) in state.windows.enumerated() {
                    projectSessions.remember(session, active: index == state.activeWindowIndex)
                }
                projectSessions.save(to: defaults)
            }
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        closingWindows[index].prepareToClose { allowed in
            if allowed { self.confirmQuit(closingWindows, index: index + 1) }
            else {
                closingWindows.forEach { $0.cancelPreparedClose() }
                self.terminating = false
                self.quitSession = nil
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
    }

    private func sessionSnapshot() -> SessionState {
        let active = activeProjectWindow ?? current
        return SessionState(windows: windows.map(\.session),
                            activeWindowIndex: windows.firstIndex { $0 === active })
    }

    private func openPendingFiles() {
        guard !pendingOpenFiles.isEmpty else { return }
        let paths = pendingOpenFiles
        pendingOpenFiles.removeAll()
        openRequestedFiles(paths)
    }

    private func openRequestedFiles(_ paths: [String]) {
        guard let first = paths.first else { return }
        if current?.hasRoot != true {
            let folder = URL(fileURLWithPath: first).deletingLastPathComponent()
            // Queue until the project has finished restoring its existing tabs.
            pendingOpenFiles.append(contentsOf: paths)
            openProject(folder)
            return
        }
        paths.forEach { current?.openFile(URL(fileURLWithPath: $0)) }
    }

    private func persistOpenProjects() {
        guard !restoring, !terminating else { return }
        for controller in windows {
            projectSessions.remember(controller.session, active: controller === activeProjectWindow)
        }
        projectSessions.save(to: defaults)
    }

    func openProject(_ url: URL) {
        guard !terminating, !restoring else { return }
        if let existing = windows.first(where: {
            $0.projectURL.map { ProjectSessions.sameProject($0, url) } ?? false
        }) {
            existing.window?.deminiaturize(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            activeProjectWindow = existing
            persistOpenProjects()
            openPendingFiles()
            return
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "Project folder is unavailable"
            alert.informativeText = url.path
            alert.runModal()
            return
        }
        let saved = projectSessions.session(for: url)
        restoring = true
        let controller = makeWindow()
        controller.setRoot(url)
        activeProjectWindow = controller
        if let saved {
            controller.restore(saved) { failures in
                self.finishRestoring(controller, failures: failures)
            }
        } else {
            finishRestoring(controller, failures: [])
        }
    }

    private func finishRestoring(_ controller: EditorWindow, failures: [String]) {
        restoring = false
        controller.window?.makeKeyAndOrderFront(nil)
        activeProjectWindow = controller
        persistOpenProjects()
        openPendingFiles()
        if !failures.isEmpty, let window = controller.window {
            let alert = NSAlert()
            alert.messageText = "Some session items could not be reopened"
            let unique = Array(Set(failures)).sorted()
            alert.informativeText = unique.prefix(8).joined(separator: "\n")
                + (unique.count > 8 ? "\n…and \(unique.count - 8) more." : "")
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        }
    }

    func restoreSession() {
        guard !restoring else { return }
        guard windows.isEmpty else { openPendingFiles(); return }
        guard let saved = projectSessions.mostRecent else {
            _ = makeWindow()
            openPendingFiles()
            return
        }
        restoring = true
        let controller = makeWindow()
        controller.restore(saved) { failures in
            self.finishRestoring(controller, failures: failures)
        }
    }

    @objc private func showProjects(_ sender: Any?) {
        guard !terminating, !restoring, current?.window?.attachedSheet == nil else { return }
        if picker == nil { picker = ProjectPicker() }
        picker?.present(relativeTo: current?.window) { [weak self] url in self?.openProject(url) }
    }

    private func installProjectShortcut() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                guard event.type == .keyDown else { self.prefixPending = false; return false }
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                let key = event.charactersIgnoringModifiers?.lowercased()
                if modifiers == .control, key == "s" {
                    self.prefixPending = true
                    return true
                }
                if self.prefixPending {
                    self.prefixPending = false
                    if modifiers.isEmpty, key == "s" { self.showProjects(nil); return true }
                    if event.keyCode == 53 { return true }
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    func applicationDidResignActive(_ notification: Notification) { prefixPending = false }

    @objc private func showSettings(_ sender: Any?) { AppSettings.shared.showWindow() }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Aletheia",
            .applicationVersion: AppMetadata.version,
            .version: AppMetadata.build,
            .credits: NSAttributedString(string: AppMetadata.description)
        ])
    }

    private func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            main.addItem(item)
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            return submenu
        }
        func item(_ title: String, _ action: Selector, _ key: String, in menu: NSMenu,
                  target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        let app = menu("Aletheia")
        item("About Aletheia", #selector(showAbout(_:)), "", in: app, target: self)
        app.addItem(.separator())
        item("Settings…", #selector(showSettings(_:)), ",", in: app, target: self)
        app.addItem(.separator())
        item("Hide Aletheia", #selector(NSApplication.hide(_:)), "h", in: app)
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", in: app, modifiers: [.command, .option])
        item("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", in: app)
        app.addItem(.separator())
        item("Quit Aletheia", #selector(NSApplication.terminate(_:)), "q", in: app)
        let file = menu("File")
        item("Open File…", #selector(openFiles(_:)), "o", in: file, target: self)
        item("Open Folder…", #selector(openFolder(_:)), "o", in: file, target: self, modifiers: [.command, .shift])
        item("Switch Project… (⌃S, S)", #selector(showProjects(_:)), "", in: file, target: self)
        file.addItem(.separator())
        item("Save", #selector(save(_:)), "s", in: file, target: self)
        item("Close Tab", #selector(closeTab(_:)), "w", in: file, target: self)
        item("Close Window", #selector(closeWindow(_:)), "w", in: file, target: self, modifiers: [.command, .shift])
        let edit = menu("Edit")
        item("Undo", Selector(("undo:")), "z", in: edit)
        item("Redo", Selector(("redo:")), "z", in: edit, modifiers: [.command, .shift])
        edit.addItem(.separator())
        item("Cut", #selector(NSText.cut(_:)), "x", in: edit)
        item("Copy", #selector(NSText.copy(_:)), "c", in: edit)
        item("Paste", #selector(NSText.paste(_:)), "v", in: edit)
        item("Select All", #selector(NSText.selectAll(_:)), "a", in: edit)
        edit.addItem(.separator())
        item("Find…", #selector(EditorWindow.showFind(_:)), "f", in: edit)
        item("Replace…", #selector(EditorWindow.showReplace(_:)), "r", in: edit)
        let window = menu("Window")
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", in: window)
        item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", in: window)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}
