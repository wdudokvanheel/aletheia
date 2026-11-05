import AppKit
import WebKit
import XCTest
@testable import Aletheia

final class ScrollRestorationTests: XCTestCase {
    @MainActor func testActiveAndInactiveSourcePositionsSurviveReopenAndTabSwitch() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("one.txt")
        let second = directory.appendingPathComponent("two.txt")
        let text = (0..<500).map { "Line \($0)" }.joined(separator: "\n")
        for url in [first, second] { try Data(text.utf8).write(to: url) }
        var state = WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                  filePaths: [first.path, second.path], selectedPath: first.path)
        state.scrollPositions = [first.path: FileScrollPosition(source: CGPoint(x: 0, y: 800)),
                                 second.path: FileScrollPosition(source: CGPoint(x: 0, y: 1800))]
        for _ in 0..<2 {
            let controller = EditorWindow()
            let failures = await withCheckedContinuation { continuation in
                controller.restore(state) { continuation.resume(returning: $0) }
            }
            XCTAssertTrue(failures.isEmpty)
            let firstEditor = try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
            XCTAssertEqual(firstEditor.enclosingScrollView!.contentView.bounds.origin.y, 800, accuracy: 1)
            // An inactive document has no usable layout: its saved offset must remain pending.
            XCTAssertEqual(controller.session.scrollPositions?[second.path]?.source.y, 1800)
            controller.openFile(second)
            let secondEditor = try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
            XCTAssertEqual(secondEditor.enclosingScrollView!.contentView.bounds.origin.y, 1800, accuracy: 1)
            secondEditor.enclosingScrollView!.contentView.scroll(to: CGPoint(x: 0, y: 2200))
            controller.openFile(first)
            XCTAssertEqual(firstEditor.enclosingScrollView!.contentView.bounds.origin.y, 800, accuracy: 1)
            controller.openFile(second)
            XCTAssertEqual(secondEditor.enclosingScrollView!.contentView.bounds.origin.y, 2200, accuracy: 1)
            // Save a fresh reopen candidate, with the original selected tab.
            controller.openFile(first)
            state = controller.session
            state.scrollPositions?[second.path]?.source.y = 1800
            controller.window?.performClose(nil)
        }
    }

    @MainActor func testPendingSourceClampsAfterLayoutWithoutChangingBufferOrUndo() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("short".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(file: try TextFile.read(url))
        document.editor.insertText(" edit", replacementRange: NSRange(location: 5, length: 0))
        document.restoreScrollPosition(FileScrollPosition(source: CGPoint(x: CGFloat.nan, y: 1e9)))
        document.setSourceVisible(true)
        XCTAssertEqual(document.scrollPosition.source.y, 1e9)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = document.scroll
        window.contentView?.layoutSubtreeIfNeeded()
        document.restoreSourceScrollAfterLayout()
        XCTAssertEqual(document.scrollPosition.source, .zero)
        XCTAssertEqual(document.editor.string, "short edit")
        document.editor.undoManager?.undo()
        XCTAssertEqual(document.editor.string, "short")
        window.close()
    }

    @MainActor private func eventually(_ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Scroll restoration did not settle")
    }

    @MainActor func testPreviewRestoresEachDocumentAndRejectsStaleScrollMessages() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func document(_ name: String, y: CGFloat) throws -> EditorDocument {
            let url = directory.appendingPathComponent(name + ".md")
            try Data(String(repeating: "Paragraph\n\n", count: 300).utf8).write(to: url)
            let document = EditorDocument(file: try TextFile.read(url))
            document.previewPosition = CGPoint(x: 0, y: y)
            return document
        }
        let first = try document("first", y: 700)
        let second = try document("second", y: 1500)
        let preview = MarkdownPreview()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview.webView
        defer { preview.show(nil); window.close() }
        func scrollY() async throws -> Double? {
            try await preview.webView.callAsyncJavaScript("return window.scrollY", arguments: [:],
                                                          in: nil, contentWorld: .page) as? Double
        }
        preview.show(first)
        try await eventually {
            guard preview.ready else { return false }
            return try await scrollY() == 700
        }
        let oldToken = preview.resources.token
        let oldGeneration = preview.generation
        _ = try await preview.webView.callAsyncJavaScript("window.scrollTo(0, 950)", arguments: [:],
                                                         in: nil, contentWorld: .page)
        try await eventually { first.previewPosition.y == 950 }
        // Scroll messages from the committed DOM remain valid while an edit is debounced.
        preview.contentChanged()
        preview.receiveScroll(["token": oldToken, "generation": oldGeneration, "x": 0.0, "y": 975.0])
        XCTAssertEqual(first.previewPosition.y, 975)
        preview.show(second)
        preview.receiveScroll(["token": oldToken, "generation": oldGeneration, "x": 0.0, "y": 99.0])
        XCTAssertEqual(second.previewPosition.y, 1500)
        try await eventually { try await scrollY() == 1500 }
        preview.receiveScroll(["token": preview.resources.token, "generation": oldGeneration, "x": 0.0, "y": 99.0])
        XCTAssertEqual(second.previewPosition.y, 1500)
        preview.show(first)
        try await eventually { try await scrollY() == 975 }
    }
}
