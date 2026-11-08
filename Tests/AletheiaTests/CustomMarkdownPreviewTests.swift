import AppKit
import ImageIO
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

    @MainActor func testShowingADocumentAgainReusesItsLayouts() async throws {
        _ = NSApplication.shared
        let urls = try ["First", "Second", "Third"].map { try temporaryMarkdown(longMarkdown($0)) }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let a = EditorDocument(file: try TextFile.read(urls[0]))
        var b: EditorDocument? = EditorDocument(file: try TextFile.read(urls[1]))
        let c = EditorDocument(file: try TextFile.read(urls[2]))
        let preview = CustomMarkdownPreview()
        preview.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        func shown(_ title: String) -> Bool {
            preview.preview.snapshot.isComplete && preview.preview.snapshot.document.blocks.first?.text == title
        }
        preview.show(a)
        try await eventually { shown("First") }
        let layouts = preview.preview.snapshot.layouts
        preview.show(b)
        try await eventually { shown("Second") }
        XCTAssertEqual(preview.keptSnapshotCount, 1)

        preview.show(a)
        try await eventually { shown("First") }
        XCTAssertTrue(zip(preview.preview.snapshot.layouts, layouts).allSatisfy { $0 === $1 }, "every block reused")
        XCTAssertEqual(preview.keptSnapshotCount, 1, "the second document's")

        // Edited while not shown: only the changed block is laid out again.
        preview.show(c)
        try await eventually { shown("Third") }
        a.editor.insertText(" edited", replacementRange: NSRange(location: 7, length: 0))
        preview.show(a)
        try await eventually { shown("First edited") }
        let reused = zip(preview.preview.snapshot.layouts, layouts).count(where: { $0 === $1 })
        XCTAssertEqual(reused, layouts.count - 1)

        // A closed document's snapshot goes with it.
        weak let closed = b
        b = nil
        XCTAssertNil(closed)
        preview.show(c)
        try await eventually { shown("Third") }
        XCTAssertEqual(preview.keptSnapshotCount, 1, "only the first document's")
        preview.prepareForRelease()
        XCTAssertEqual(preview.keptSnapshotCount, 0)
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

/// The Custom preview's image provider: `PreviewImageLoader` relative to the
/// shown document's folder, with its errors passed through.
final class CustomMarkdownImageTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("doc/images"),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @MainActor private func document(_ text: String) throws -> EditorDocument {
        let url = folder.appendingPathComponent("doc/README.md")
        try Data(text.utf8).write(to: url)
        return EditorDocument(file: try TextFile.read(url))
    }

    @MainActor private func request(_ preview: CustomMarkdownPreview, _ source: String,
                                    displaySize: CGSize = CGSize(width: 600, height: CGFloat.infinity))
        async -> Result<MarkdownImage, any Error> {
        await withCheckedContinuation { continuation in
            _ = preview.requestImage(source: source, displaySize: displaySize, scale: 2) { continuation.resume(returning: $0) }
        }
    }

    @MainActor func testRelativeSourcesResolveAgainstTheDocumentsFolder() async throws {
        _ = NSApplication.shared
        try png(width: 64, height: 48).write(to: folder.appendingPathComponent("doc/images/pic.png"))
        try png(width: 40, height: 40).write(to: folder.appendingPathComponent("outside.png"))
        let preview = CustomMarkdownPreview(imageLoader: PreviewImageLoader(configuration: .ephemeral, cache: nil))
        preview.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let document = try document("# Images\n\n![Picture](images/pic.png)\n\nAfter.")
        preview.show(document)
        XCTAssertTrue(preview.preview.imageProvider === preview)
        let image = try await request(preview, "images/pic.png").get()
        XCTAssertEqual(image.size, CGSize(width: 64, height: 48))
        XCTAssertEqual(image.image.width, 64)
        XCTAssertFalse(image.isAnimated)
        // Shown in the view, it replaces its alt text.
        try await eventually {
            preview.preview.snapshot.document.blocks.count == 3 && preview.preview.snapshot.layouts[1].height == 48
        }
        XCTAssertEqual(preview.preview.retainedImageCount, 1)
        // Downsampled to the size asked for.
        let small = try await request(preview, "images/pic.png", displaySize: CGSize(width: 32, height: 24)).get()
        XCTAssertEqual(small.image.width, 64, "32 points at scale 2")
        let smaller = try await request(preview, "./images/pic.png", displaySize: CGSize(width: 16, height: 12)).get()
        XCTAssertEqual(smaller.image.width, 32)
        preview.prepareForRelease()
    }

    @MainActor func testLoaderErrorsPassThrough() async throws {
        _ = NSApplication.shared
        try png(width: 40, height: 40).write(to: folder.appendingPathComponent("outside.png"))
        try Data("not an image".utf8).write(to: folder.appendingPathComponent("doc/images/broken.png"))
        try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: folder.appendingPathComponent("doc/images/logo.svg"))
        let preview = CustomMarkdownPreview(imageLoader: PreviewImageLoader(configuration: .ephemeral, cache: nil))
        // The preview holds its document weakly.
        let document = try document("# Errors")
        preview.show(document)
        for (source, expected) in [("images/missing.png", PreviewImageError.notFound), ("../outside.png", .blocked),
                                   ("http://example.com/a.png", .blocked), ("images/broken.png", .decode),
                                   ("images/logo.svg", .badType)] {
            let result = await request(preview, source)
            guard case .failure(let error) = result else { XCTFail("\(source) loaded"); continue }
            XCTAssertEqual(error as? PreviewImageError, expected, source)
        }
        withExtendedLifetime(document) { preview.prepareForRelease() }
    }

    /// The generated traversal fixture, end to end: only the image linked
    /// inside the folder loads; every other block keeps its alt text.
    @MainActor func testGeneratedTraversalFixtureShowsAltText() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/markdown-corpus/generated/images/traversal.md")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("Run `swift run -c release MarkdownViewBench generate` in Packages/MarkdownView")
        }
        _ = NSApplication.shared
        let preview = CustomMarkdownPreview(imageLoader: PreviewImageLoader(configuration: .ephemeral, cache: nil))
        preview.view.frame = NSRect(x: 0, y: 0, width: 700, height: 4000)
        let document = EditorDocument(file: try TextFile.read(root))
        preview.show(document)
        func height(of text: String) -> CGFloat? {
            let snapshot = preview.preview.snapshot
            return snapshot.document.blocks.firstIndex { $0.text == text }.map { snapshot.layouts[$0].height }
        }
        try await eventually { height(of: "Link inside the folder, block") == 48 }
        try await Task.sleep(for: .milliseconds(200))
        let line = Typography.standard.bodyFontSize * Typography.standard.lineHeightMultiple
        for name in ["Parent traversal", "Traversal to a real image", "Absolute file URL", "Absolute path", "Escaping link"] {
            XCTAssertEqual(height(of: "\(name), block"), line, name)
        }
        XCTAssertEqual(preview.preview.retainedImageCount, 1)
        withExtendedLifetime(document) { preview.prepareForRelease() }
    }

    @MainActor private func eventually(file: StaticString = #filePath, line: UInt = #line,
                                       _ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Preview did not settle", file: file, line: line)
    }
}
