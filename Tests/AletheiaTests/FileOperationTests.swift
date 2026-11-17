import AppKit
import XCTest
@testable import Aletheia

final class FileOperationTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func names(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testFreeNamesFollowFinder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "a copy.txt", ".gitignore", "noext", "v1.2"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir.d"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("broken"),
                                                   withDestinationURL: root.appendingPathComponent("missing"))
        func free(_ name: String, directory: Bool = false) -> String {
            FileOperations.freeURL(for: name, in: root, isDirectory: directory).lastPathComponent
        }
        XCTAssertEqual(free("new.txt"), "new.txt")
        XCTAssertEqual(free("a.txt"), "a copy 2.txt")
        XCTAssertEqual(free(".gitignore"), ".gitignore copy")
        XCTAssertEqual(free("noext"), "noext copy")
        XCTAssertEqual(free("v1.2"), "v1 copy.2")
        XCTAssertEqual(free("dir.d", directory: true), "dir.d copy", "A folder keeps its whole name")
        XCTAssertEqual(free("broken"), "broken copy", "A broken symlink still takes its name")
    }

    func testRenameValidatesAndNeverReplaces() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.md")
        let other = root.appendingPathComponent("other.md")
        try Data("Notes".utf8).write(to: file)
        try Data("Other".utf8).write(to: other)

        for name in ["", "a/b", ".", ".."] {
            XCTAssertThrowsError(try FileOperations.rename(file, to: name), name)
        }
        XCTAssertThrowsError(try FileOperations.rename(file, to: "other.md")) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }
        XCTAssertEqual(try Data(contentsOf: other), Data("Other".utf8))
        XCTAssertEqual(try FileOperations.rename(file, to: "notes.md"), file)

        // A case-only rename, on a case-insensitive volume the "existing" item is itself.
        let cased = try FileOperations.rename(file, to: "Notes.md")
        XCTAssertEqual(cased.lastPathComponent, "Notes.md")
        XCTAssertEqual(try names(root), ["Notes.md", "other.md"])
        XCTAssertEqual(try Data(contentsOf: cased), Data("Notes".utf8))

        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("Inside".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        let renamed = try FileOperations.rename(folder, to: "renamed")
        XCTAssertEqual(try Data(contentsOf: renamed.appendingPathComponent("inside.txt")), Data("Inside".utf8))
        XCTAssertThrowsError(try FileOperations.rename(renamed, to: "other.md"))
    }

    func testPasteCopiesUnderFreeNamesAndRefusesToRecurse() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file.txt")
        try Data("File".utf8).write(to: file)
        try Data("Deep".utf8).write(to: nested.appendingPathComponent("deep.txt"))

        XCTAssertEqual(try FileOperations.paste([file], into: root).map(\.lastPathComponent), ["file copy.txt"])
        XCTAssertEqual(try FileOperations.paste([file, file], into: root).map(\.lastPathComponent),
                       ["file copy 2.txt", "file copy 3.txt"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file copy 3.txt")), Data("File".utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data("File".utf8))

        let copies = try FileOperations.paste([folder], into: root)
        XCTAssertEqual(copies.map(\.lastPathComponent), ["folder copy"])
        XCTAssertEqual(try Data(contentsOf: copies[0].appendingPathComponent("nested/deep.txt")), Data("Deep".utf8))

        // Into itself or below it fails before anything is copied, also with a valid item first.
        for target in [folder, nested] {
            XCTAssertThrowsError(try FileOperations.paste([file, folder], into: target)) { error in
                XCTAssertTrue(error is FileOperations.OperationError)
            }
        }
        XCTAssertEqual(try names(folder), ["nested"])
        XCTAssertEqual(try names(nested), ["deep.txt"])
        // A sibling whose name only starts with the folder's is not inside it.
        let sibling = root.appendingPathComponent("folder2")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        XCTAssertEqual(try FileOperations.paste([folder], into: sibling).map(\.lastPathComponent), ["folder"])
    }

    func testPastedImagesGetScreenshotNamesAndNeverReplace() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 11, 17, 9, 5, 3)
        let date = try XCTUnwrap(Calendar.current.date(from: parts))
        let first = try FileOperations.pasteImage(Data([1]), into: root, date: date)
        let second = try FileOperations.pasteImage(Data([2]), into: root, date: date)
        XCTAssertEqual(first.lastPathComponent, "Image 2026-11-17 at 09.05.03.png")
        XCTAssertEqual(second.lastPathComponent, "Image 2026-11-17 at 09.05.03 copy.png")
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
    }

    func testMovedSnapshotsKeepTheirIdentity() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("a.md")
        try Data("Text".utf8).write(to: file)
        let snapshot = DocumentFile.text(try TextFile.read(file))
        let outside = DocumentFile.text(try TextFile.read({
            let url = root.appendingPathComponent("docs2.md")
            try Data().write(to: url)
            return url
        }()))

        let renamed = try FileOperations.rename(folder, to: "guides")
        XCTAssertNil(outside.moved(from: folder, to: renamed), "A shared name prefix is not a parent folder")
        XCTAssertTrue(snapshot.isInside(folder))
        XCTAssertFalse(outside.isInside(folder))
        let moved = try XCTUnwrap(snapshot.moved(from: folder, to: renamed))
        XCTAssertEqual(moved.requestedURL.path, renamed.appendingPathComponent("a.md").path)
        XCTAssertEqual(moved.url.path, renamed.appendingPathComponent("a.md").path)
        // The disk check compares a reread with the snapshot: a plain move is no change.
        XCTAssertTrue(moved.matches(try moved.reread()))
        XCTAssertEqual(moved.text, "Text")
    }

    @MainActor func testOpenTabsFollowRenamesAndTrash() async throws {
        _ = NSApplication.shared
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let edited = folder.appendingPathComponent("edited.md")
        let clean = folder.appendingPathComponent("sub/clean.txt")
        let loose = root.appendingPathComponent("loose.txt")
        for url in [edited, clean, loose] { try Data("Original".utf8).write(to: url) }

        let controller = EditorWindow()
        let state = WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                  rootPath: root.path, filePaths: [clean.path, loose.path, edited.path],
                                  selectedPath: edited.path,
                                  treeState: FolderTreeState(expandedPaths: [folder.path, folder.appendingPathComponent("sub").path]))
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(state) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(failures.isEmpty)
        let window = try XCTUnwrap(controller.window)
        defer { window.performClose(nil) }
        func outlines(_ view: NSView) -> [NSOutlineView] {
            (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap(outlines)
        }
        let outline = try XCTUnwrap(outlines(try XCTUnwrap(window.contentView)).first)
        let menu = try XCTUnwrap(outline.menu)
        func canonical(_ path: String?) -> String? {
            path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        }
        func row(_ url: URL) -> Int? {
            (0..<outline.numberOfRows).first {
                canonical((outline.item(atRow: $0) as? FolderNode)?.url.path) == canonical(url.path)
            }
        }
        func waitFor(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(condition())
        }
        try await waitFor { row(clean) != nil }

        // Trash, Copy and Paste from the menu bar act only with the tree focused; Rename does not need it.
        let barItems = [#selector(EditorWindow.trashFileItem(_:)), #selector(EditorWindow.copy(_:)),
                        #selector(EditorWindow.renameFileItem(_:))].map {
            NSMenuItem(title: "", action: $0, keyEquivalent: "")
        }
        outline.selectRowIndexes(IndexSet(integer: try XCTUnwrap(row(loose))), byExtendingSelection: false)
        XCTAssertTrue(window.firstResponder is NSTextView)
        XCTAssertEqual(barItems.map(controller.validateUserInterfaceItem), [false, false, true])
        let treeTrash = try XCTUnwrap(menu.items.first { $0.action == #selector(EditorWindow.trashFileItem(_:)) })
        XCTAssertTrue(controller.validateUserInterfaceItem(treeTrash), "The tree's own menu needs no focus")
        window.makeFirstResponder(outline)
        XCTAssertEqual(barItems.map(controller.validateUserInterfaceItem), [true, true, true])
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(barItems.map(controller.validateUserInterfaceItem), [false, true, false], "The root stays")

        // Rename prompt: prefilled, with the stem selected.
        outline.selectRowIndexes(IndexSet(integer: try XCTUnwrap(row(edited))), byExtendingSelection: false)
        controller.renameFileItem(nil)
        let sheet = try XCTUnwrap(window.attachedSheet)
        try await Task.sleep(for: .milliseconds(100))
        let field = try XCTUnwrap(sheet.firstResponder as? NSTextView)
        XCTAssertEqual(field.string, "edited.md")
        XCTAssertEqual(field.selectedRange(), NSRange(location: 0, length: 6))
        XCTAssertEqual(barItems.map(controller.validateUserInterfaceItem), [false, false, false])
        window.endSheet(sheet)
        try await waitFor { window.attachedSheet == nil }

        // Renaming the folder keeps edits and undo, saves the new paths and lands the tree there.
        let document = try XCTUnwrap(controller.documents.last)
        document.editor.insertText(" edited", replacementRange: NSRange(location: 8, length: 0))
        // As from the tree's menu: the tree's own URL, here under /private/var while the tabs use /var.
        let treeFolder = try XCTUnwrap(outline.item(atRow: try XCTUnwrap(row(folder))) as? FolderNode).url
        controller.renameItem(at: treeFolder, to: "guides")
        let guides = root.appendingPathComponent("guides")
        let movedEdited = guides.appendingPathComponent("edited.md")
        let movedClean = guides.appendingPathComponent("sub/clean.txt")
        XCTAssertEqual(controller.session.filePaths, [movedClean.path, loose.path, movedEdited.path])
        XCTAssertEqual(controller.session.selectedPath, movedEdited.path)
        XCTAssertEqual(document.editor.string, "Original edited")
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(document.editor.undoManager?.canUndo == true)
        try await waitFor { canonical(controller.session.treeState?.selectedPath) == guides.path }
        XCTAssertEqual(controller.session.treeState?.expandedPaths.compactMap(canonical),
                       [guides.path, guides.appendingPathComponent("sub").path])
        try await Task.sleep(for: .milliseconds(700)) // Let the watcher and disk check run.
        XCTAssertNil(window.attachedSheet, "A renamed file is neither missing nor changed on disk")
        XCTAssertFalse(document.diskUnavailable)
        controller.saveSelected(nil)
        try await waitFor { !document.isDirty }
        XCTAssertEqual(try Data(contentsOf: movedEdited), Data("Original edited".utf8))

        // A case-only rename of the file itself.
        controller.renameItem(at: movedEdited, to: "Edited.md")
        XCTAssertEqual(controller.session.selectedPath, guides.appendingPathComponent("Edited.md").path)
        XCTAssertNil(window.attachedSheet)

        // Trashing the folder closes the clean tab and keeps the edited one with its content.
        document.editor.insertText(" again", replacementRange: NSRange(location: 15, length: 0))
        let trashed = try XCTUnwrap(controller.trashItem(at: guides))
        defer { try? FileManager.default.removeItem(at: trashed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: guides.path))
        XCTAssertEqual(controller.session.filePaths, [loose.path, guides.appendingPathComponent("Edited.md").path])
        XCTAssertEqual(document.editor.string, "Original edited again")
        XCTAssertTrue(document.isDirty)
        // The existing missing-file path reports it and keeps the buffer.
        try await waitFor { window.attachedSheet != nil }
        XCTAssertTrue(document.diskUnavailable)
        XCTAssertEqual(document.editor.string, "Original edited again")
        window.endSheet(try XCTUnwrap(window.attachedSheet))
    }

    /// A disabled menu item would still swallow its key, so ⌘⌫ must reach the editor through the main menu.
    @MainActor func testCommandBackspaceStillDeletesToLineStartInTheEditor() async throws {
        _ = NSApplication.shared
        let suite = "AletheiaFileOperationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let app = AppDelegate(defaults: defaults, shortcuts: Shortcuts(defaults: defaults))
        app.buildMenu()
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("text.txt")
        try Data("Hello world".utf8).write(to: file)
        let controller = EditorWindow()
        let state = WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                  rootPath: root.path, filePaths: [file.path], selectedPath: file.path)
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(state) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(failures.isEmpty)
        let window = try XCTUnwrap(controller.window)
        defer { window.performClose(nil) }
        // A test process has no key window to resolve the item's nil target, so name the window.
        try XCTUnwrap(app.commandItems[.delete]).target = controller
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 11, length: 0))
        // A keyboard event as the hardware sends it: ⌘ and the Backspace key.
        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true))
        key.flags = .maskCommand
        let event = try XCTUnwrap(NSEvent(cgEvent: key))
        // Dequeue it, as the run loop does, so it is the app's current event.
        NSApp.postEvent(event, atStart: true)
        let current = try XCTUnwrap(NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .default, dequeue: true))
        XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: current))
        XCTAssertEqual(editor.string, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Nothing goes to the Trash")
        XCTAssertNil(window.attachedSheet)
        editor.undoManager?.undo()
    }
}
