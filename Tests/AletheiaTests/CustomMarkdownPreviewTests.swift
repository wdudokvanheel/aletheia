import AppKit
import MarkdownView
import WebKit
import XCTest
@testable import Aletheia

@MainActor
private final class NotificationCounter: NSObject {
    var count = 0
    @objc func received() { count += 1 }
}

final class CustomMarkdownPreviewTests: XCTestCase {
    @MainActor private func eventually(file: StaticString = #filePath, line: UInt = #line,
                                       _ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("Preview did not settle", file: file, line: line)
    }

    @MainActor private func script(_ preview: MarkdownPreview, _ script: String) async throws -> Any? {
        try await preview.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }

    private func temporaryMarkdown(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func longMarkdown(_ title: String) -> String {
        "# \(title)\n\n" + (1...150).map {
            "## Section \($0)\n\nParagraph \($0) with enough words to wrap across the preview column at least once."
        }.joined(separator: "\n\n")
    }

    @MainActor func testRendererPreferenceRoundTripsAndNotifies() throws {
        let suite = "AletheiaTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let renderer = NotificationCounter()
        let timings = NotificationCounter()
        NotificationCenter.default.addObserver(renderer, selector: #selector(NotificationCounter.received),
            name: AppSettings.markdownRendererDidChange, object: settings)
        NotificationCenter.default.addObserver(timings, selector: #selector(NotificationCounter.received),
            name: AppSettings.previewTimingsDidChange, object: settings)
        XCTAssertEqual(settings.markdownRenderer, .webkit)
        XCTAssertFalse(settings.showsPreviewTimings)
        settings.setMarkdownRenderer(.custom)
        settings.setMarkdownRenderer(.custom)
        XCTAssertEqual(renderer.count, 1)
        XCTAssertEqual(AppSettings(defaults: defaults).markdownRenderer, .custom)
        settings.setShowsPreviewTimings(true)
        XCTAssertEqual(timings.count, 1)
        XCTAssertTrue(AppSettings(defaults: defaults).showsPreviewTimings)
        settings.setMarkdownRenderer(.webkit)
        XCTAssertEqual(renderer.count, 2)
        XCTAssertEqual(AppSettings(defaults: defaults).markdownRenderer, .webkit)
        defaults.set("removed", forKey: AppSettings.markdownRendererKey)
        XCTAssertEqual(AppSettings(defaults: defaults).markdownRenderer, .webkit)
    }

    @MainActor func testHiddenCustomPreviewKeepsContentAndDefersUpdates() async throws {
        _ = NSApplication.shared
        let url = try temporaryMarkdown("# Title\n\nBody")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(file: try TextFile.read(url))
        let preview = CustomMarkdownPreview()
        preview.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        document.onContentChange = { preview.contentChanged() }
        preview.show(document)
        try await eventually { preview.preview.snapshot.document.blocks.first?.text == "Title" }
        let installed = preview.preview.snapshot.generation

        preview.setVisible(false)
        XCTAssertFalse(preview.preview.isShown)
        document.editor.insertText(" changed", replacementRange: NSRange(location: 7, length: 0))
        try await Task.sleep(for: .milliseconds(400))
        // Nothing installs while hidden, and the previous content stays.
        XCTAssertEqual(preview.preview.snapshot.generation, installed)
        XCTAssertEqual(preview.preview.snapshot.document.blocks.map(\.text), ["Title", "Body"])

        preview.setVisible(true)
        try await eventually { preview.preview.snapshot.document.blocks.first?.text == "Title changed" }
        XCTAssertTrue(document.isDirty)
        preview.prepareForRelease()
    }

    @MainActor func testCustomPreviewUpdatesWithoutADebounce() async throws {
        _ = NSApplication.shared
        let url = try temporaryMarkdown("# Title\n\nBody")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(file: try TextFile.read(url))
        let preview = CustomMarkdownPreview()
        preview.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        document.onContentChange = { preview.contentChanged() }
        preview.show(document)
        try await eventually { preview.preview.snapshot.document.blocks.first?.text == "Title" }
        let start = ContinuousClock.now
        for (offset, character) in " now".enumerated() {
            document.editor.insertText(String(character), replacementRange: NSRange(location: 7 + offset, length: 0))
        }
        try await eventually { preview.preview.snapshot.document.blocks.first?.text == "Title now" }
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(200), "no editing debounce")
        XCTAssertEqual(preview.preview.snapshot.document.blocks.map(\.text), ["Title now", "Body"])
        preview.prepareForRelease()
    }

    @MainActor func testCustomPreviewRestoresEachDocumentsScrollOffset() async throws {
        _ = NSApplication.shared
        let first = try temporaryMarkdown(longMarkdown("First"))
        let second = try temporaryMarkdown(longMarkdown("Second"))
        defer { [first, second].forEach { try? FileManager.default.removeItem(at: $0) } }
        let a = EditorDocument(file: try TextFile.read(first))
        let b = EditorDocument(file: try TextFile.read(second))
        let preview = CustomMarkdownPreview()
        preview.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        preview.show(a)
        try await eventually { preview.preview.snapshot.document.blocks.first?.text == "First" }
        preview.preview.scrollFraction = 0.4
        let offset = preview.preview.contentView.bounds.minY
        XCTAssertGreaterThan(offset, 1000)
        XCTAssertEqual(a.previewPosition.y, offset)

        preview.show(b)
        try await eventually { preview.preview.snapshot.document.blocks.first?.text == "Second" }
        XCTAssertEqual(preview.preview.contentView.bounds.minY, 0)
        XCTAssertEqual(a.previewPosition.y, offset)
        XCTAssertEqual(b.previewPosition.y, 0)

        preview.show(a)
        try await eventually { preview.preview.snapshot.document.blocks.first?.text == "First" }
        XCTAssertEqual(preview.preview.contentView.bounds.minY, offset, accuracy: 0.5)
        XCTAssertEqual(a.previewPosition.y, offset, accuracy: 0.5)
        preview.prepareForRelease()
    }

    @MainActor func testLinkClicksFollowTheWebKitRules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = folder.appendingPathComponent("page.md")
        try Data("# Page".utf8).write(to: page)
        try Data("other".utf8).write(to: folder.appendingPathComponent("other notes.md"))
        try Data("nested".utf8).write(to: folder.appendingPathComponent("sub/nested.txt"))
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.md"))
        let document = EditorDocument(file: try TextFile.read(page))
        let preview = CustomMarkdownPreview()
        var system: [URL] = []
        var editor: [URL] = []
        preview.openInSystem = { system.append($0) }
        preview.onOpen = { editor.append($0) }
        let click = try XCTUnwrap(preview.preview.onOpenLink)
        click("https://example.com/a")
        XCTAssertTrue(system.isEmpty, "no document shown yet")
        preview.show(document)

        // Web and mail links open in the system.
        for destination in ["https://example.com/a?b=1#c", "HTTP://example.com", "mailto:someone@example.com"] {
            click(destination)
        }
        XCTAssertEqual(system.map(\.absoluteString),
                       ["https://example.com/a?b=1#c", "HTTP://example.com", "mailto:someone@example.com"])

        // Relative files inside the document's folder open in the editor.
        let canonical = folder.resolvingSymlinksInPath()
        for destination in ["other%20notes.md", "other notes.md", "sub/nested.txt#part", "sub/../other%20notes.md"] {
            click(destination)
        }
        XCTAssertEqual(editor.map(\.path), [canonical.appendingPathComponent("other notes.md").path,
                                            canonical.appendingPathComponent("other notes.md").path,
                                            canonical.appendingPathComponent("sub/nested.txt").path,
                                            canonical.appendingPathComponent("other notes.md").path])

        // Everything else is ignored.
        for destination in ["../outside.md", "/etc/hosts", "file:///etc/hosts", "missing.md", "sub", "#heading",
                            "javascript:alert(1)", "ftp://example.com/x", "aletheia-preview://document/x/page.md", ""] {
            click(destination)
        }
        XCTAssertEqual(system.count, 3)
        XCTAssertEqual(editor.count, 4)
        preview.prepareForRelease()
    }

    @MainActor func testShowingAnotherDocumentClearsTheSelection() async throws {
        _ = NSApplication.shared
        let first = try temporaryMarkdown("# Same\n\nShared words.")
        let second = try temporaryMarkdown("# Same\n\nShared words.")
        defer { [first, second].forEach { try? FileManager.default.removeItem(at: $0) } }
        let preview = CustomMarkdownPreview()
        preview.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        preview.show(EditorDocument(file: try TextFile.read(first)))
        try await eventually { preview.preview.snapshot.document.blocks.count == 2 }
        preview.preview.documentView?.selectAll(nil)
        XCTAssertNotNil(preview.preview.selection)
        preview.show(EditorDocument(file: try TextFile.read(second)))
        XCTAssertNil(preview.preview.selection)
        preview.prepareForRelease()
    }

    @MainActor func testTimingsOverlayShowsTheLastUpdate() async throws {
        _ = NSApplication.shared
        let settings = AppSettings.shared
        let previous = settings.showsPreviewTimings
        defer { settings.setShowsPreviewTimings(previous) }
        settings.setShowsPreviewTimings(false)
        let url = try temporaryMarkdown("# Timed\n\nBody")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(file: try TextFile.read(url))
        let preview = CustomMarkdownPreview()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = preview.view
        XCTAssertTrue(preview.timingsLabel.isHidden)
        preview.show(document)
        try await eventually {
            window.display()
            return preview.preview.lastTimings != nil
        }
        settings.setShowsPreviewTimings(true)
        XCTAssertFalse(preview.timingsLabel.isHidden)
        XCTAssertTrue(preview.timingsLabel.stringValue.contains("parse"))
        XCTAssertTrue(preview.timingsLabel.stringValue.contains("2 blocks"))
        settings.setShowsPreviewTimings(false)
        XCTAssertTrue(preview.timingsLabel.isHidden)
        preview.prepareForRelease()
        window.close()
    }

    @MainActor func testApplyThemeMapsTheAppPalette() {
        let settings = AppSettings.shared
        let previous = settings.selectedSchemeID
        defer { settings.selectScheme(id: previous) }
        let preview = CustomMarkdownPreview()
        settings.selectScheme(id: "dracula")
        preview.applyTheme()
        let palette = settings.palette
        XCTAssertEqual(preview.preview.palette.background, palette.background)
        XCTAssertEqual(preview.preview.palette.text, palette.foreground)
        XCTAssertEqual(preview.preview.palette.codeBackground, palette.surface)
        XCTAssertEqual(preview.preview.palette.mutedText, palette.muted)
        settings.selectScheme(id: "system")
        preview.applyTheme()
        XCTAssertEqual(preview.preview.palette, .standard)
    }

    @MainActor func testSwitchingRendererSwapsPreviewAndKeepsEditingState() async throws {
        _ = NSApplication.shared
        let settings = AppSettings.shared
        let previous = settings.markdownRenderer
        defer { settings.setMarkdownRenderer(previous) }
        settings.setMarkdownRenderer(.webkit)
        let url = try temporaryMarkdown(longMarkdown("Switch"))
        defer { try? FileManager.default.removeItem(at: url) }
        let state = WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                  filePaths: [url.path], selectedPath: url.path,
                                  markdownModes: [url.path: .split], editorFraction: 0.4)
        let controller = EditorWindow()
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(state) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(failures.isEmpty)
        let document = try XCTUnwrap(controller.documents.first)
        let editor = document.editor
        editor.insertText(" edited", replacementRange: NSRange(location: 8, length: 0))
        editor.setSelectedRange(NSRange(location: 2, length: 6))
        let text = editor.string

        func assertEditingStateKept(_ mode: MarkdownMode, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(editor.string, text, file: file, line: line)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 6), file: file, line: line)
            XCTAssertTrue(document.isDirty, file: file, line: line)
            XCTAssertEqual(document.markdownMode, mode, file: file, line: line)
            XCTAssertEqual(controller.session.markdownModes?[url.path], mode, file: file, line: line)
            XCTAssertEqual(controller.session.editorFraction, 0.4, file: file, line: line)
        }
        func findControl(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.lazy.compactMap { findControl($0) }.first
        }

        // Scoped so the test's own references do not keep replaced previews alive.
        weak var oldWebKit: MarkdownPreview?
        let webFraction: Double
        do {
            let webkit = try XCTUnwrap(controller.preview as? MarkdownPreview)
            try await eventually {
                guard webkit.ready else { return false }
                return try await self.script(webkit, "return committedSource") as? String == text
            }
            _ = try await script(webkit, "window.scrollTo(0, document.documentElement.scrollHeight * 0.3)")
            try await eventually { document.previewPosition.y > 0 }
            let reported = await webkit.scrollFraction()
            webFraction = try XCTUnwrap(reported)
            XCTAssertEqual(webFraction, 0.3, accuracy: 0.05)
            oldWebKit = webkit
        }
        document.scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        document.scroll.reflectScrolledClipView(document.scroll.contentView)
        // The text view settles its own non-contiguous layout first.
        try await Task.sleep(for: .milliseconds(300))
        let sourceOrigin = document.scroll.contentView.bounds.origin
        XCTAssertGreaterThan(sourceOrigin.y, 0)

        weak var oldCustom: CustomMarkdownPreview?
        let customFraction: Double
        settings.setMarkdownRenderer(.custom)
        try await eventually { controller.preview is CustomMarkdownPreview }
        do {
            let custom = try XCTUnwrap(controller.preview as? CustomMarkdownPreview)
            try await eventually { custom.preview.snapshot.document.blocks.first?.text == "Switch edited" }
            XCTAssertEqual(custom.preview.scrollFraction, webFraction, accuracy: 0.01)
            let split = try XCTUnwrap(custom.view.superview as? NSSplitView)
            XCTAssertTrue(split.arrangedSubviews.first === document.scroll)
            XCTAssertEqual(split.arrangedSubviews[0].frame.width,
                           (split.bounds.width - split.dividerThickness) * 0.4, accuracy: 1)
            XCTAssertEqual(document.scroll.contentView.bounds.origin, sourceOrigin)
            XCTAssertTrue(controller.window?.firstResponder === editor)
            assertEditingStateKept(.split)
            try await eventually { oldWebKit == nil }

            // Hidden windows keep the Custom preview and only pause it.
            controller.updatePreviewVisibility(isVisible: false)
            XCTAssertFalse(custom.preview.isShown)
            try await Task.sleep(for: .milliseconds(2200))
            XCTAssertTrue(controller.preview === custom)
            XCTAssertEqual(custom.preview.snapshot.document.blocks.first?.text, "Switch edited")
            controller.updatePreviewVisibility(isVisible: true)
            XCTAssertTrue(custom.preview.isShown)

            let control = try XCTUnwrap(controller.window?.contentView.flatMap(findControl))
            control.selectedSegment = 2
            NSApplication.shared.sendAction(try XCTUnwrap(control.action), to: control.target, from: control)
            XCTAssertTrue(controller.preview === custom)
            XCTAssertTrue(controller.window?.firstResponder === custom.focusView)
            // Let the wider Preview layout install before positioning it.
            try await eventually {
                custom.preview.snapshot.isComplete
                    && custom.preview.snapshot.width == custom.preview.contentView.bounds.width
            }
            custom.preview.scrollFraction = 0.6
            customFraction = custom.preview.scrollFraction
            oldCustom = custom
        }

        settings.setMarkdownRenderer(.webkit)
        try await eventually { controller.preview is MarkdownPreview }
        do {
            let recreated = try XCTUnwrap(controller.preview as? MarkdownPreview)
            try await eventually {
                guard recreated.ready else { return false }
                return try await self.script(recreated, "return committedSource") as? String == text
            }
            try await eventually {
                let fraction = try await self.script(recreated,
                    "return window.scrollY / document.documentElement.scrollHeight") as? Double ?? 0
                return abs(fraction - customFraction) < 0.01
            }
            XCTAssertTrue(recreated.view.superview?.subviews.last === recreated.view)
            XCTAssertTrue(controller.window?.firstResponder === recreated.webView)
        }
        assertEditingStateKept(.preview)
        try await eventually { oldCustom == nil }

        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, longMarkdown("Switch"))
        controller.window?.performClose(nil)
    }
}
