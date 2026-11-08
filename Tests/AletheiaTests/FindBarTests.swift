import AppKit
import XCTest
@testable import Aletheia

final class FindBarTests: XCTestCase {
    func testLiteralUTF16Ranges() {
        XCTAssertEqual(FindBar.ranges(in: "😀 a.a A.a a.a", query: "a.a"),
                       [NSRange(location: 3, length: 3), NSRange(location: 11, length: 3)])
        XCTAssertEqual(FindBar.ranges(in: "aaa", query: "aa"), [NSRange(location: 0, length: 2)])
        XCTAssertTrue(FindBar.ranges(in: "text", query: "").isEmpty)
    }

    @MainActor func testReplaceNavigationAndUndo() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("😀 cat cat\r\ncat".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = EditorDocument(file: try TextFile.read(url))
        let bar = FindBar()
        bar.bind(doc)
        bar.query.stringValue = "cat"
        bar.show(replacing: true)
        XCTAssertEqual(bar.matches.count, 3)
        bar.previousMatch(nil)
        XCTAssertEqual(bar.current, 2)
        bar.nextMatch(nil)
        XCTAssertEqual(bar.current, 0)
        bar.replacement.stringValue = "cat!"
        bar.replaceCurrent(nil)
        XCTAssertEqual(doc.editor.string, "😀 cat! cat\r\ncat")
        XCTAssertEqual(bar.currentRange, NSRange(location: 8, length: 3))
        XCTAssertTrue(doc.isDirty)
        doc.editor.undoManager?.undo()
        XCTAssertEqual(doc.editor.string, "😀 cat cat\r\ncat")
        XCTAssertFalse(doc.isDirty)
        bar.refresh()
        bar.replacement.stringValue = "dog\n"
        bar.replaceEveryMatch(nil)
        XCTAssertEqual(doc.editor.string, "😀 dog\r\n dog\r\n\r\ndog\r\n")
        doc.editor.undoManager?.undo()
        XCTAssertEqual(doc.editor.string, "😀 cat cat\r\ncat")
        XCTAssertFalse(doc.isDirty)
        doc.editor.undoManager?.redo()
        XCTAssertEqual(doc.editor.string, "😀 dog\r\n dog\r\n\r\ndog\r\n")
    }

    @MainActor func testBarLayoutAcrossMarkdownModes() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("# cat\n\ncat".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        for mode in MarkdownMode.allCases {
            let controller = EditorWindow()
            let state = WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                rootPath: nil, filePaths: [url.path], selectedPath: url.path,
                markdownModes: [url.path: mode])
            await withCheckedContinuation { continuation in
                controller.restore(state) { _ in continuation.resume() }
            }
            let window = try XCTUnwrap(controller.window)
            controller.findBar.query.stringValue = "cat"
            controller.showFind(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            let findHeight = controller.findBar.frame.height
            XCTAssertGreaterThan(findHeight, 20)
            XCTAssertGreaterThan(controller.findBar.query.frame.width, 50)
            XCTAssertEqual(controller.findBar.matches.count, 2)
            controller.showReplace(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(controller.findBar.frame.height, findHeight + 20)
            XCTAssertFalse(controller.findBar.replacement.isHiddenOrHasHiddenAncestor)
            controller.findBar.nextMatch(nil)
            XCTAssertEqual(controller.documents[0].editor.selectedRange(), NSRange(location: 7, length: 3))
            controller.findBar.closeSearch(nil)
            XCTAssertTrue(controller.findBar.isHidden)
            window.close()
        }
    }

    @MainActor func testReadOnlyAndDocumentSwitch() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("one one".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = EditorDocument(file: try TextFile.read(url))
        let bar = FindBar()
        bar.bind(doc)
        bar.query.stringValue = "one"
        bar.show(replacing: true)
        doc.editor.isEditable = false
        bar.replacement.stringValue = "two"
        bar.replaceEveryMatch(nil)
        XCTAssertEqual(doc.editor.string, "one one")
        bar.bind(nil)
        XCTAssertTrue(bar.matches.isEmpty)
        bar.closeSearch(nil)
        XCTAssertTrue(bar.isHidden)
    }
}
