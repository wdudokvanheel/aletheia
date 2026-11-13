import AppKit
import XCTest
@testable import Aletheia

final class NewItemTests: XCTestCase {
    private func canonical(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    @MainActor func testNewItemsAppearInTheTreeAndNeverReplaceExistingOnes() async throws {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.object(forKey: AppSettings.revealActiveFileKey)
        defer { UserDefaults.standard.set(saved, forKey: AppSettings.revealActiveFileKey) }
        // The created file must be shown even when the tree does not follow the active tab.
        AppSettings.shared.setRevealActiveFileInTree(false)
        var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("parent/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let existing = root.appendingPathComponent("existing.txt")
        try Data("Original".utf8).write(to: existing)

        let controller = EditorWindow()
        let item = NSMenuItem(title: "", action: #selector(EditorWindow.newFile(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateUserInterfaceItem(item), "There is no folder to create in yet")
        let state = WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                  rootPath: root.path, filePaths: [], selectedPath: nil)
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(state) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(failures.isEmpty)
        let window = try XCTUnwrap(controller.window)
        defer { window.performClose(nil) }
        XCTAssertTrue(controller.validateUserInterfaceItem(item))
        func outlines(_ view: NSView) -> [NSOutlineView] {
            (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap(outlines)
        }
        let outline = try XCTUnwrap(outlines(try XCTUnwrap(window.contentView)).first)
        XCTAssertEqual(outline.menu?.items.map(\.action),
                       [#selector(EditorWindow.newFile(_:)), #selector(EditorWindow.newFolder(_:))])
        func waitForTreeSelection(_ url: URL) async throws {
            let deadline = Date().addingTimeInterval(5)
            while canonical(controller.session.treeState?.selectedPath) != canonical(url.path) && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(canonical(controller.session.treeState?.selectedPath), canonical(url.path))
        }

        // A file in a folder the tree has not loaded yet.
        let file = nested.appendingPathComponent("notes.md")
        controller.createItem(named: "notes.md", in: nested, directory: false)
        try await waitForTreeSelection(file)
        XCTAssertEqual(try Data(contentsOf: file), Data())
        XCTAssertEqual(controller.session.selectedPath, file.path)

        // A folder beside it, in a folder that is already listed.
        let folder = nested.appendingPathComponent("assets")
        controller.createItem(named: "assets", in: nested, directory: true)
        try await waitForTreeSelection(folder)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(controller.session.filePaths, [file.path], "A new folder opens no tab")

        for (name, directory) in [("existing.txt", false), ("existing.txt", true), ("../escaped.txt", false), ("..", true)] {
            controller.createItem(named: name, in: root, directory: directory)
            let sheet = try XCTUnwrap(window.attachedSheet, name)
            XCTAssertFalse(controller.validateUserInterfaceItem(item))
            window.endSheet(sheet)
            for _ in 0..<5 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(try Data(contentsOf: existing), Data("Original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))
        XCTAssertEqual(controller.session.filePaths, [file.path])
    }
}
