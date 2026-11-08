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

    @MainActor func testSearchUsesSourceOccurrenceIncludingHiddenDestinationsAndUTF16() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let source = "😀 first\r\n\r\n[repeat](repeat) repeat **repeat**\r\n\r\nrepeat\r\n\r\n[hidden]: destination"
        try Data(source.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(file: try TextFile.read(url))
        let preview = MarkdownPreview()
        preview.show(document)
        try await eventually {
            guard preview.ready else { return false }
            return try await self.script(preview, "return committedSource") as? String == source
        }
        let ns = source as NSString
        var cursor = 0
        var occurrences: [NSRange] = []
        while cursor < ns.length {
            let range = ns.range(of: "repeat", options: .literal, range: NSRange(location: cursor, length: ns.length - cursor))
            if range.location == NSNotFound { break }
            occurrences.append(range)
            cursor = NSMaxRange(range)
        }
        for index in [0, 2, 3, 4] {
            let range = occurrences[index]
            preview.setSearch(query: "repeat", sourceRange: range)
            try await eventually {
                try await self.script(preview, """
                    const selection = window.getSelection();
                    return selection.toString() === 'repeat' &&
                      Number(selection.anchorNode?.parentElement.closest('[data-text-start]')?.dataset.textStart) + selection.anchorOffset === location;
                    """, ["location": range.location]) as? Bool == true
            }
        }
        // The identical word in the link destination has no visible range.
        _ = try await script(preview, "Element.prototype.scrollIntoView = function() { window.searchedBlock = Number(this.dataset.sourceStart); }")
        preview.setSearch(query: "repeat", sourceRange: occurrences[1])
        try await eventually {
            try await self.script(preview, "return window.getSelection().toString() === '' && window.searchedBlock === start",
                                  ["start": ns.range(of: "[repeat]").location]) as? Bool == true
        }
        preview.setSearch(query: "**", sourceRange: ns.range(of: "**"))
        try await eventually {
            try await self.script(preview, "return window.getSelection().toString() === ''") as? Bool == true
        }
        for (query, expected) in [("**repeat**\r\n\r\nrepeat", ns.range(of: "[repeat]").location),
                                  ("destination", occurrences[4].location)] {
            _ = try await script(preview, "window.searchedBlock = -1")
            preview.setSearch(query: query, sourceRange: ns.range(of: query))
            try await eventually {
                try await self.script(preview, "return window.searchedBlock === start && window.getSelection().toString() === ''",
                                      ["start": expected]) as? Bool == true
            }
        }
        preview.show(nil)
    }

    @MainActor func testSearchSurvivesPendingRenderAndReloadButClearsOnSwitch() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("first target".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(file: try TextFile.read(url))
        let other = EditorDocument(file: try TextFile.read(url))
        let preview = MarkdownPreview()
        preview.show(document)
        preview.setSearch(query: "target", sourceRange: NSRange(location: 6, length: 6))
        try await eventually {
            guard preview.ready else { return false }
            return try await self.script(preview, "return window.getSelection().toString()") as? String == "target"
        }
        document.editor.insertText("new ", replacementRange: NSRange(location: 0, length: 0))
        preview.contentChanged()
        preview.setSearch(query: "target", sourceRange: NSRange(location: 10, length: 6))
        try await eventually {
            try await self.script(preview, "return committedSource === 'new first target' && window.getSelection().toString() === 'target'") as? Bool == true
        }
        let originValue = try await script(preview, "return performance.timeOrigin") as? Double
        let origin = try XCTUnwrap(originValue)
        preview.webView.reload()
        try await eventually {
            guard preview.ready else { return false }
            return try await self.script(preview, "return performance.timeOrigin !== origin && committedSource === 'new first target' && window.getSelection().toString() === 'target'", ["origin": origin]) as? Bool == true
        }
        preview.show(other)
        try await eventually {
            try await self.script(preview, "return committedSource === 'first target' && search === null && window.getSelection().toString() === ''") as? Bool == true
        }
        preview.setSearch(query: "target", sourceRange: NSRange(location: 6, length: 6))
        preview.setSearch(query: "", sourceRange: nil)
        try await eventually {
            try await self.script(preview, "return search === null && window.getSelection().toString() === ''") as? Bool == true
        }
        preview.show(nil)
        try await eventually {
            try await self.script(preview, "return search === null && committed === null") as? Bool == true
        }
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

    @MainActor func testTabSelectionBypassesEditDebounce() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("# Selected".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = EditorDocument(file: try TextFile.read(url))
        let second = EditorDocument(file: try TextFile.read(url))
        let preview = MarkdownPreview()
        try await eventually { preview.ready }
        preview.show(first)
        try await eventually { preview.renderCount == 1 }
        preview.contentChanged()
        preview.show(second)
        // A main-actor scheduling turn starts a selection render without sleeping
        // for the 200 ms editing debounce (no WebKit paint timing assertion).
        await Task.yield()
        XCTAssertEqual(preview.renderCount, 2)
        preview.contentChanged()
        await Task.yield()
        XCTAssertEqual(preview.renderCount, 2)
        preview.show(nil)
    }

    @MainActor func testHiddenWindowReleasesAndRecreatesPreview() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("# Retained".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = EditorWindow()
        let state = WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                  filePaths: [url.path], selectedPath: url.path)
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(state) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(failures.isEmpty)
        let editor = try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
        editor.insertText(" edited", replacementRange: NSRange(location: 10, length: 0))
        let selection = editor.selectedRange()
        weak let oldPreview = controller.preview
        weak let oldWebView = controller.preview?.webView
        XCTAssertNotNil(oldPreview)
        controller.updatePreviewVisibility(isVisible: false)
        try await Task.sleep(for: .milliseconds(100))
        controller.updatePreviewVisibility(isVisible: true)
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertTrue(controller.preview === oldPreview)
        controller.updatePreviewVisibility(isVisible: false)
        XCTAssertNotNil(controller.preview)
        try await eventually { controller.preview == nil }
        try await eventually { oldPreview == nil && oldWebView == nil }
        controller.updatePreviewVisibility(isVisible: true)
        let recreated = try XCTUnwrap(controller.preview)
        try await eventually {
            guard recreated.ready else { return false }
            return try await self.script(recreated, "return document.querySelector('h1')?.textContent") as? String == "Retained edited"
        }
        XCTAssertEqual(editor.selectedRange(), selection)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "# Retained")
        controller.window?.performClose(nil)
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
                                  markdownModes: [url.path: .editor], treeWidth: 260, editorFraction: 0.4)
        let controller = EditorWindow()
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(state) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(controller.session.treeWidth, 260)
        XCTAssertEqual(controller.session.editorFraction, 0.4)
        let editor = try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
        editor.insertText(" edited", replacementRange: NSRange(location: 10, length: 0))
        let selection = editor.selectedRange()
        func findControl(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.lazy.compactMap { findControl($0) }.first
        }
        let control = try XCTUnwrap(controller.window?.contentView.flatMap(findControl))
        for (segment, mode) in [(1, MarkdownMode.split), (2, .preview), (1, .split), (0, .editor)] {
            control.selectedSegment = segment
            NSApplication.shared.sendAction(try XCTUnwrap(control.action), to: control.target, from: control)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let host = try XCTUnwrap(control.superview?.superview?.subviews.last)
            let visibleContent = try XCTUnwrap(host.subviews.last)
            XCTAssertFalse(visibleContent.isHidden)
            XCTAssertGreaterThan(visibleContent.frame.width, 400)
            XCTAssertGreaterThan(visibleContent.frame.height, 300)
            XCTAssertEqual(visibleContent.frame.width, host.bounds.width, accuracy: 1)
            XCTAssertEqual(visibleContent.frame.height, host.bounds.height, accuracy: 1)
            XCTAssertFalse(visibleContent.hasAmbiguousLayout)
            if let split = visibleContent as? NSSplitView {
                XCTAssertEqual(split.arrangedSubviews[0].frame.width,
                               (split.bounds.width - split.dividerThickness) * 0.4, accuracy: 1)
                XCTAssertEqual(split.arrangedSubviews.count, 2)
                XCTAssertGreaterThan(split.arrangedSubviews[0].frame.width, 100)
                XCTAssertGreaterThan(split.arrangedSubviews[1].frame.width, 100)
            }
            if mode == .editor { XCTAssertTrue(visibleContent === editor.enclosingScrollView) }
            if mode == .preview { XCTAssertTrue(visibleContent is WKWebView) }
            XCTAssertEqual(controller.session.markdownModes?[url.path], mode)
            XCTAssertEqual(controller.session.lastMarkdownMode, mode)
            XCTAssertEqual(editor.string, "# Original edited")
            XCTAssertEqual(editor.selectedRange(), selection)
        }
        XCTAssertTrue(controller.window?.firstResponder === editor)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "# Original")
        controller.window?.performClose(nil)
    }

    @MainActor func testThemeAppliesToPreviewAndPreservesEditorUndo() async throws {
        _ = NSApplication.shared
        let settings = AppSettings.shared
        let previous = settings.selectedSchemeID
        defer { settings.selectScheme(id: previous) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data("# Theme".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(file: try TextFile.read(url))
        document.editor.insertText(" edited", replacementRange: NSRange(location: 7, length: 0))
        let selection = document.editor.selectedRange()
        let preview = MarkdownPreview()
        preview.show(document)
        try await eventually { preview.ready }
        for (id, expected) in [("dracula", "rgb(40, 42, 54)"), ("catppuccin-latte", "rgb(239, 241, 245)")] {
            settings.selectScheme(id: id)
            document.applyTheme()
            preview.applyTheme()
            try await eventually {
                try await self.script(preview, "return getComputedStyle(document.body).backgroundColor") as? String == expected
            }
            XCTAssertEqual(document.editor.string, "# Theme edited")
            XCTAssertEqual(document.editor.selectedRange(), selection)
            XCTAssertTrue(document.isDirty)
        }
        document.editor.undoManager?.undo()
        XCTAssertEqual(document.editor.string, "# Theme")
        XCTAssertFalse(document.isDirty)
        settings.selectScheme(id: "system")
        preview.applyTheme()
        try await eventually {
            try await self.script(preview, "return document.documentElement.style.getPropertyValue('--background')") as? String == ""
        }
        preview.show(nil)
    }

    func testOldSessionLoadsAndModesRoundTrip() throws {
        let old = Data("""
            {"frame":[[0,0],[900,600]],"filePaths":["/a.md"],"selectedPath":"/a.md"}
            """.utf8)
        var state = try JSONDecoder().decode(WindowSession.self, from: old)
        XCTAssertNil(state.treeWidth)
        XCTAssertNil(state.editorFraction)
        XCTAssertNil(state.markdownModes)
        state.markdownModes = ["/a.md": .preview]
        XCTAssertEqual(try JSONDecoder().decode(WindowSession.self, from: JSONEncoder().encode(state)), state)
    }
}
