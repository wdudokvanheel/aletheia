import AppKit
import XCTest
@testable import Aletheia

final class MarkdownThemeTests: XCTestCase {
    @MainActor func testThemeChangeRecolorsMarkdownAndReturningFromPreview() async throws {
        _ = NSApplication.shared
        let previous = AppSettings.shared.selectedSchemeID
        defer { AppSettings.shared.selectScheme(id: previous) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let source = "# Heading\n\nSome **bold** and `code`.\n"
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = EditorWindow()
        defer { controller.window?.performClose(nil) }
        await withCheckedContinuation { continuation in
            controller.restore(WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                             filePaths: [url.path], selectedPath: url.path,
                                             markdownModes: [url.path: .editor])) { _ in continuation.resume() }
        }
        let document = try XCTUnwrap(controller.documents.first)
        let runs = SyntaxHighlighting.runs(in: source, languageID: "markdown")
        XCTAssertFalse(runs.isEmpty)
        for _ in 0..<200 {
            if document.highlightedGeneration >= 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let layout = try XCTUnwrap(document.editor.layoutManager)
        let parsedGeneration = document.highlightedGeneration
        for scheme in AppSettings.schemes {
            AppSettings.shared.selectScheme(id: scheme.id)
            // No delay: Settings must synchronously recolor already parsed tokens.
            for run in runs {
                XCTAssertEqual(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: run.range.location,
                                                         effectiveRange: nil) as? NSColor,
                               run.style.color(AppSettings.shared.selectedScheme.syntaxPalette))
            }
            XCTAssertEqual(document.highlightedGeneration, parsedGeneration)
        }
        func control(in view: NSView) -> NSSegmentedControl? {
            (view as? NSSegmentedControl) ?? view.subviews.lazy.compactMap { control(in: $0) }.first
        }
        let mode = try XCTUnwrap(controller.window?.contentView.flatMap { control(in: $0) })
        mode.selectedSegment = 2
        NSApp.sendAction(try XCTUnwrap(mode.action), to: mode.target, from: mode)
        AppSettings.shared.selectScheme(id: "ayu-light")
        let generation = document.highlightedGeneration
        mode.selectedSegment = 0
        NSApp.sendAction(try XCTUnwrap(mode.action), to: mode.target, from: mode)
        for _ in 0..<200 {
            if document.highlightedGeneration > generation { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for run in runs {
            XCTAssertEqual(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: run.range.location,
                                                     effectiveRange: nil) as? NSColor,
                           run.style.color(AppSettings.shared.selectedScheme.syntaxPalette))
        }
        XCTAssertEqual(document.editor.string, source)
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(document.editor.undoManager!.canUndo)
    }
}
