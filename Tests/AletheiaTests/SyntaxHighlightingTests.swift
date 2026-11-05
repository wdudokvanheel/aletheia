import AppKit
import XCTest
@testable import Aletheia

final class SyntaxHighlightingTests: XCTestCase {
    func testRequestedFormatsAndCommonAliases() {
        for (name, id) in [("a.ts", "typescript"), ("a.tsx", "tsx"), ("a.js", "javascript"),
                           ("a.jsx", "javascript"), ("a.md", "markdown"), ("a.json", "json"),
                           (".env", "shell"), (".env.local", "shell"), ("a.env", "shell")] {
            XCTAssertEqual(SyntaxHighlighting.languageID(for: URL(fileURLWithPath: name)), id, name)
        }
        XCTAssertNil(SyntaxHighlighting.languageID(for: URL(fileURLWithPath: "plain.unknown")))
    }

    func testTokensUseNativeUnicodeRanges() {
        let fixtures = [
            ("typescript", "// 😀 é\r\nconst greeting: string = \"héllo\";", "const", SyntaxStyle.keyword),
            ("tsx", "const view = <Button title=\"😀\">Hello</Button>;", "Button", .name),
            ("javascript", "/* 😀 */ const x = true;", "const", .keyword),
            ("json", "{\"😀\": 42}", "42", .number),
            ("markdown", "# Hello 😀\n\n**bold**", "Hello", .markup),
            ("shell", "# config 😀\r\nAPI_KEY=\"hello\"\r\n", "API_KEY", .property)
        ]
        for (language, text, needle, style) in fixtures {
            let runs = SyntaxHighlighting.runs(in: text, languageID: language)
            let range = (text as NSString).range(of: needle)
            XCTAssertTrue(runs.contains { $0.style == style && NSIntersectionRange($0.range, range).length == range.length }, language)
            for run in runs { XCTAssertLessThanOrEqual(NSMaxRange(run.range), text.utf16.count) }
        }
    }

    @MainActor private func document(_ text: String, extension ext: String = "ts") throws -> EditorDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(file: try TextFile.read(url))
        document.scroll.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        document.editor.frame = NSRect(x: 0, y: 0, width: 780, height: 600)
        return document
    }

    @MainActor private func settled(_ document: EditorDocument, after generation: Int = -1) async throws {
        for _ in 0..<200 {
            if document.highlightedGeneration > generation { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Highlighting did not settle")
    }

    @MainActor func testDisplayOnlyHighlightingPreservesUndoSelectionAndTheme() async throws {
        let original = "// 😀\r\nconst x = 42;\r\n"
        let doc = try document(original)
        doc.editor.setSelectedRange(NSRange(location: 0, length: 0))
        try await settled(doc)
        let keyword = (original as NSString).range(of: "const")
        XCTAssertNotNil(doc.editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: keyword.location, effectiveRange: nil))
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.editor.undoManager!.canUndo)
        let originalScheme = AppSettings.shared.selectedSchemeID
        defer { AppSettings.shared.selectScheme(id: originalScheme) }
        AppSettings.shared.selectScheme(id: "dracula")
        doc.applyTheme()
        XCTAssertEqual(doc.editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: keyword.location, effectiveRange: nil) as? NSColor, SyntaxStyle.keyword.color(AppSettings.shared.selectedScheme.syntaxPalette))
        XCTAssertEqual(doc.editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(doc.editor.string, original)
        let generation = doc.highlightedGeneration
        doc.editor.insertText("// edit\n", replacementRange: NSRange(location: 0, length: 0))
        doc.editor.breakUndoCoalescing()
        try await settled(doc, after: generation)
        XCTAssertTrue(doc.isDirty)
        let editedGeneration = doc.highlightedGeneration
        doc.editor.undoManager?.undo()
        try await settled(doc, after: editedGeneration)
        XCTAssertEqual(doc.editor.string, original)
        XCTAssertFalse(doc.isDirty)
        XCTAssertTrue(doc.editor.undoManager!.canRedo)
        XCTAssertEqual(doc.editor.textStorage?.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? NSColor, AppSettings.shared.palette.foreground)
    }

    @MainActor func testEditsInvalidateMultilineStateAndHiddenWork() async throws {
        let doc = try document("/* comment\nconst x = 1;\n")
        try await settled(doc)
        let initial = doc.highlightedGeneration
        doc.setHighlightingActive(false)
        doc.editor.insertText("*/", replacementRange: NSRange(location: 10, length: 0))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(doc.highlightedGeneration, initial)
        doc.setHighlightingActive(true)
        try await settled(doc, after: initial)
        let index = (doc.editor.string as NSString).range(of: "const").location
        XCTAssertEqual(doc.editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor, SyntaxStyle.keyword.color(AppSettings.shared.selectedScheme.syntaxPalette))
        let last = doc.highlightedGeneration
        doc.editor.string = "const obsolete = 1;"
        doc.editor.string = "// latest 😀"
        try await settled(doc, after: last)
        XCTAssertEqual(doc.editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor, SyntaxStyle.comment.color(AppSettings.shared.selectedScheme.syntaxPalette))
    }

    @MainActor func testScrollAndReloadRefreshVisibleColors() async throws {
        let line = "const x = 42; // comment\n"
        let doc = try document(String(repeating: line, count: 500))
        try await settled(doc)
        let index = line.utf16.count * 400
        doc.editor.scrollRangeToVisible(NSRange(location: index, length: 5))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: doc.scroll.contentView)
        XCTAssertNotNil(doc.editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil))
        let previous = doc.highlightedGeneration
        let replacement = try document("// reloaded 😀")
        doc.reload(replacement.file)
        doc.editor.scrollRangeToVisible(NSRange(location: 0, length: 1))
        try await settled(doc, after: previous)
        XCTAssertFalse(doc.isDirty)
        XCTAssertFalse(doc.editor.undoManager!.canUndo)
        XCTAssertEqual(doc.editor.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor, SyntaxStyle.comment.color(AppSettings.shared.selectedScheme.syntaxPalette))
    }

    func testHugeFilesStayPlain() {
        XCTAssertTrue(SyntaxHighlighting.runs(in: String(repeating: "a", count: 10 * 1024 * 1024), languageID: "typescript").isEmpty)
    }

    @MainActor func testReleaseTimingWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["ALETHEIA_HIGHLIGHT_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in Release measurement") }
        let line = "export const greeting: string = `Hello 😀`; // comment\n"
        let text = String(repeating: line, count: 1_048_576 / line.utf8.count)
        _ = SyntaxHighlighting.runs(in: text, languageID: "typescript")
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let runs = SyntaxHighlighting.runs(in: text, languageID: "typescript")
            XCTAssertFalse(runs.isEmpty)
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        let doc = try document(text)
        try await settled(doc)
        var renderSamples: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            doc.applyTheme()
            let elapsed = start.duration(to: .now).components
            renderSamples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        renderSamples.sort()
        print("HIGHLIGHT native color application median=\(renderSamples[10])ms p95=\(renderSamples[18])ms max=\(renderSamples[19])ms")
        samples.sort()
        print("HIGHLIGHT 1MiB 20 repeats median=\(samples[10])ms p95=\(samples[18])ms max=\(samples[19])ms")
    }
}
