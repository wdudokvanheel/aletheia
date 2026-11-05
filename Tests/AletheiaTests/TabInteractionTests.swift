import AppKit
import XCTest
@testable import Aletheia

final class TabInteractionTests: XCTestCase {
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
