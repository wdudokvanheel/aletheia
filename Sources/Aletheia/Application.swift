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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [EditorWindow] = []
    private var terminating = false
    private var launched = false
    private var restoring = false
    private var pendingOpenFiles: [String] = []
    private var quitSession: SessionState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
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
            // Closing the final window retains its files; closing one of several removes only that window.
            let state = self.windows.isEmpty
                ? SessionState(windows: [closedSession], activeWindowIndex: 0) : self.sessionSnapshot()
            state.save()
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
            let controller = self.current.flatMap { $0.hasRoot ? nil : $0 } ?? self.makeWindow()
            controller.setRoot(url)
            controller.showWindow(nil)
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
            let controller = self.current ?? self.makeWindow()
            panel.urls.forEach { controller.openFile($0) }
        }
    }

    @objc private func save(_ sender: Any?) { if !terminating && !restoring { current?.saveSelected(sender) } }
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
            quitSession?.save()
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
        let active = current
        return SessionState(windows: windows.map(\.session),
                            activeWindowIndex: windows.firstIndex { $0 === active })
    }

    private func openPendingFiles() {
        guard !pendingOpenFiles.isEmpty else { return }
        let paths = pendingOpenFiles
        pendingOpenFiles.removeAll()
        let controller = current ?? makeWindow()
        paths.forEach { controller.openFile(URL(fileURLWithPath: $0)) }
    }

    private func restoreSession() {
        guard !restoring else { return }
        guard windows.isEmpty else { openPendingFiles(); return }
        guard let state = SessionState.load(), !state.windows.isEmpty else {
            _ = makeWindow()
            openPendingFiles()
            return
        }
        restoring = true
        let controllers = state.windows.map { _ in makeWindow() }
        var remaining = controllers.count
        var skipped: [String] = []
        for (controller, saved) in zip(controllers, state.windows) {
            controller.restore(saved) { failures in
                skipped.append(contentsOf: failures)
                remaining -= 1
                guard remaining == 0 else { return }
                self.restoring = false
                let activeIndex = state.activeWindowIndex ?? 0
                let active = controllers.indices.contains(activeIndex) ? controllers[activeIndex] : controllers[0]
                active.showWindow(nil)
                active.window?.makeKeyAndOrderFront(nil)
                self.openPendingFiles()
                if !skipped.isEmpty, let window = active.window {
                    let alert = NSAlert()
                    alert.messageText = "Some session items could not be reopened"
                    let unique = Array(Set(skipped)).sorted()
                    alert.informativeText = unique.prefix(8).joined(separator: "\n")
                        + (unique.count > 8 ? "\n…and \(unique.count - 8) more." : "")
                    alert.addButton(withTitle: "OK")
                    alert.beginSheetModal(for: window)
                }
            }
        }
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
        item("About Aletheia", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", in: app)
        app.addItem(.separator())
        item("Hide Aletheia", #selector(NSApplication.hide(_:)), "h", in: app)
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", in: app, modifiers: [.command, .option])
        item("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", in: app)
        app.addItem(.separator())
        item("Quit Aletheia", #selector(NSApplication.terminate(_:)), "q", in: app)
        let file = menu("File")
        item("Open File…", #selector(openFiles(_:)), "o", in: file, target: self)
        item("Open Folder…", #selector(openFolder(_:)), "o", in: file, target: self, modifiers: [.command, .shift])
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
        let window = menu("Window")
        item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", in: window)
        item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", in: window)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}
