import AppKit
import XCTest
@testable import Aletheia

final class TabInteractionTests: XCTestCase {
    @MainActor func testTabSelectionFollowsPreferenceAndEnablingRevealsCurrentFile() async throws {
        _ = NSApplication.shared
        let saved = UserDefaults.standard.object(forKey: AppSettings.revealActiveFileKey)
        defer { UserDefaults.standard.set(saved, forKey: AppSettings.revealActiveFileKey) }
        AppSettings.shared.setRevealActiveFileInTree(true)
        var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
        let nested = root.appendingPathComponent("parent/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = [root.appendingPathComponent("first.txt"), nested.appendingPathComponent("second.txt")]
        for url in urls { try Data("Original".utf8).write(to: url) }
        func canonical(_ path: String?) -> String? {
            path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        }
        let controller = EditorWindow()
        defer { controller.window?.performClose(nil) }
        let state = WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                  rootPath: root.path, filePaths: urls.map(\.path), selectedPath: urls[1].path)
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(state) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(failures.isEmpty)
        let deadline = Date().addingTimeInterval(5)
        while canonical(controller.session.treeState?.selectedPath) != canonical(urls[1].path) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(canonical(controller.session.treeState?.selectedPath), canonical(urls[1].path))
        let editor = try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
        AppSettings.shared.setRevealActiveFileInTree(false)
        controller.openFile(urls[0]) // Select an existing tab with following disabled.
        XCTAssertEqual(controller.session.selectedPath, urls[0].path)
        XCTAssertEqual(canonical(controller.session.treeState?.selectedPath), canonical(urls[1].path))
        AppSettings.shared.setRevealActiveFileInTree(true)
        XCTAssertEqual(canonical(controller.session.treeState?.selectedPath), canonical(urls[0].path))
        controller.openFile(urls[1])
        XCTAssertEqual(canonical(controller.session.treeState?.selectedPath), canonical(urls[1].path))
        XCTAssertTrue(controller.window?.firstResponder === editor, "Revealing must retain editor focus")
        XCTAssertEqual(controller.session.filePaths, urls.map(\.path), "Revealing must not reopen files")
    }

    @MainActor func testMiddleClickFromTitleClosesCleanTabAndPromptsForDirtyTab() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["first.txt", "second.txt"].map { root.appendingPathComponent($0) }
        for url in urls { try Data("Original".utf8).write(to: url) }
        let controller = EditorWindow()
        let state = WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                  rootPath: root.path, filePaths: urls.map(\.path), selectedPath: urls[1].path)
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(state) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(failures.isEmpty)
        let window = try XCTUnwrap(controller.window)
        func tabs(_ view: NSView) -> [EditorTabView] {
            if let tab = view as? EditorTabView { return [tab] }
            return view.subviews.flatMap(tabs)
        }
        func middleClickFirstTitle() throws {
            let tab = try XCTUnwrap(tabs(try XCTUnwrap(window.contentView)).first)
            let title = try XCTUnwrap(tab.subviews.first as? NSButton)
            let cg = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                           mouseCursorPosition: .zero, mouseButton: .center))
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            XCTAssertEqual(event.buttonNumber, 2)
            title.otherMouseDown(with: event)
        }
        try middleClickFirstTitle()
        XCTAssertEqual(controller.session.filePaths, [urls[1].path])
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText(" edited", replacementRange: NSRange(location: 8, length: 0))
        try middleClickFirstTitle()
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(controller.session.filePaths, [urls[1].path])
        window.endSheet(sheet, returnCode: .alertThirdButtonReturn)
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(controller.session.filePaths, [urls[1].path])
        XCTAssertEqual(editor.string, "Original edited")
        editor.undoManager?.undo()
        window.performClose(nil)
    }
}
