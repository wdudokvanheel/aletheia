import AppKit
import WebKit
import XCTest
@testable import Aletheia

final class MarkdownPreviewTests: XCTestCase {
    @MainActor private func eventually(_ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Preview did not settle")
    }

    @MainActor private func script(_ preview: MarkdownPreview, _ script: String,
                                   _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await preview.webView.callAsyncJavaScript(script, arguments: arguments,
                                                      in: nil, contentWorld: .page)
    }

    @MainActor func testGFMAndUnsafeContentUseRealBundledRenderer() async throws {
        _ = NSApplication.shared
        let preview = MarkdownPreview()
        try await eventually { preview.ready }
        let markdown = """
        | Name | Value |
        | --- | --- |
        | a | b |

        - [x] Done
        - [ ] Pending

        <script>window.compromised = true</script>
        <img src=x onerror="window.compromised = true">
        <iframe src="https://example.com"></iframe><form><input></form>

        [bad](javascript:alert(1))
        [malformed](http://[)
        ![remote](https://example.com/track.png)
        ![local](image.png)
        [relative](next.md)
        """
        let result = try await script(preview, """
            const html = renderMarkdown(markdown, base);
            invalidatePreview(1, true);
            commitPreview(html, 1, true);
            const content = document.getElementById('content');
            return { table: !!content.querySelector('table tbody td'),
              tasks: content.querySelectorAll('input[type=checkbox][disabled]').length,
              checked: content.querySelectorAll('input[checked]').length,
              unsafe: !!content.querySelector('script,iframe,form,[onerror],a[href^="javascript:"]'),
              remote: !!content.querySelector('img[src^="https:"]'),
              local: content.querySelector('img')?.getAttribute('src'),
              link: content.querySelector('a[href]')?.getAttribute('href'),
              executed: window.compromised === true };
            """, ["markdown": markdown, "base": "aletheia-preview://document/token/"]) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["table"] as? Bool, true)
        XCTAssertEqual(values["tasks"] as? Int, 2)
        XCTAssertEqual(values["checked"] as? Int, 1)
        XCTAssertEqual(values["unsafe"] as? Bool, false)
        XCTAssertEqual(values["remote"] as? Bool, false)
        XCTAssertEqual(values["executed"] as? Bool, false)
        XCTAssertEqual(values["local"] as? String, "aletheia-preview://document/token/image.png")
        XCTAssertEqual(values["link"] as? String, "aletheia-preview://document/token/next.md")
        // Defense in depth also applies to direct generated HTML, not only raw HTML omission.
        let sanitized = try await script(preview, "return DOMPurify.sanitize(html)", ["html":
            "<img src=x onerror=alert(1)><svg onload=alert(1)></svg><a href='javascript:alert(1)'>x</a>"]) as? String
        XCTAssertFalse(try XCTUnwrap(sanitized).contains("onerror"))
        XCTAssertFalse(try XCTUnwrap(sanitized).contains("javascript:"))
    }

    @MainActor func testUnsavedContinuousEditsDebounceHideAndStaleCommit() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("# Disk".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(file: try TextFile.read(url))
        let preview = MarkdownPreview()
        document.onContentChange = { preview.contentChanged() }
        preview.show(document)
        try await eventually {
            guard preview.ready else { return false }
            return try await self.script(preview, "return document.querySelector('h1')?.textContent") as? String == "Disk"
        }
        document.editor.insertText(" first", replacementRange: NSRange(location: 6, length: 0))
        try await eventually {
            try await self.script(preview, "return document.querySelector('h1')?.textContent") as? String == "Disk first"
        }
        document.editor.breakUndoCoalescing()
        document.editor.insertText(" second", replacementRange: NSRange(location: 12, length: 0))
        let selection = document.editor.selectedRange()
        preview.show(nil)
        let count = preview.renderCount
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(preview.renderCount, count)
        preview.show(document)
        try await eventually {
            try await self.script(preview, "return document.querySelector('h1')?.textContent") as? String == "Disk first second"
        }
        XCTAssertEqual(document.editor.selectedRange(), selection)
        XCTAssertTrue(document.isDirty)
        document.editor.undoManager?.undo()
        XCTAssertEqual(document.editor.string, "# Disk first")
        try await eventually {
            try await self.script(preview, "return document.querySelector('h1')?.textContent") as? String == "Disk first"
        }
        let accepted = try await script(preview, "return commitPreview('<p>stale</p>', -1, false)") as? Bool
        XCTAssertEqual(accepted, false)
        preview.show(nil)
    }

    @MainActor func testLocalResourceBoundaryRejectsTraversalSymlinksAndOldDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = PreviewResources()
        resources.directory = root
        try Data().write(to: root.appendingPathComponent("image.png"))
        let url = URL(string: resources.base + "image.png")!
        XCTAssertEqual(resources.localURL(url), root.appendingPathComponent("image.png"))
        XCTAssertNil(resources.localURL(URL(string: resources.base + "../secret.png")!))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"),
                                                   withDestinationURL: root.deletingLastPathComponent())
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
        try Data().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertNil(resources.localURL(URL(string: resources.base + "escape/" + outside.lastPathComponent)!))
        XCTAssertNil(resources.localURL(URL(string: resources.base + "escape/secret.png")!))
        resources.token = UUID().uuidString
        XCTAssertNil(resources.localURL(url))
    }

    @MainActor func testWindowModesRestoreAndRetainNativeEditingState() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("# Original".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                  filePaths: [url.path], selectedPath: url.path,
                                  markdownModes: [url.path: .editor])
        let controller = EditorWindow()
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(state) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(failures.isEmpty)
        let editor = try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
        editor.insertText(" edited", replacementRange: NSRange(location: 10, length: 0))
        let selection = editor.selectedRange()
        func findControl(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.lazy.compactMap { findControl($0) }.first
        }
        let control = try XCTUnwrap(controller.window?.contentView.flatMap(findControl))
        for (segment, mode) in [(1, MarkdownMode.split), (2, .preview), (0, .editor)] {
            control.selectedSegment = segment
            NSApplication.shared.sendAction(try XCTUnwrap(control.action), to: control.target, from: control)
            XCTAssertEqual(controller.session.markdownModes?[url.path], mode)
            XCTAssertEqual(editor.string, "# Original edited")
            XCTAssertEqual(editor.selectedRange(), selection)
        }
        XCTAssertTrue(controller.window?.firstResponder === editor)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "# Original")
        controller.window?.performClose(nil)
    }

    func testOldSessionLoadsAndModesRoundTrip() throws {
        let old = Data("""
            {"frame":[[0,0],[900,600]],"filePaths":["/a.md"],"selectedPath":"/a.md"}
            """.utf8)
        var state = try JSONDecoder().decode(WindowSession.self, from: old)
        XCTAssertNil(state.markdownModes)
        state.markdownModes = ["/a.md": .preview]
        XCTAssertEqual(try JSONDecoder().decode(WindowSession.self, from: JSONEncoder().encode(state)), state)
    }
}
