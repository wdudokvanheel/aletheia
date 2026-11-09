import AppKit
import MarkdownView
import SwiftHighlight
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

    func testFencedCodeTakesTheKindsTheEditorGivesTheSameFile() throws {
        let highlighter = PreviewCodeHighlighter()
        let fixtures = [
            ("ts", "a.ts", "// 😀 note\nconst greeting: string = \"héllo\";\nexport function f() { return 42; }", "const", CodeTokenKind.keyword),
            ("json", "a.json", "{\"😀\": 42, \"list\": [true, null, \"x\"]}", "42", .number),
            ("sh", "a.sh", "# config 😀\nexport API_KEY=\"hello\"\necho $HOME | grep -c x", "\"hello\"", .string),
            ("java title=\"Main.java\"", "Main.java",
             "// 😀\npublic class Main {\n    public static void main(String[] args) { System.out.println(\"hi\" + 42); }\n}",
             "class", .keyword)
        ]
        for (info, file, code, needle, kind) in fixtures {
            let language = try XCTUnwrap(SyntaxHighlighting.languageID(for: URL(fileURLWithPath: file)), file)
            let editor = SyntaxHighlighting.runs(in: code, languageID: language)
            XCTAssertGreaterThan(Set(editor.map { "\($0.style)" }).count, 1, info)
            let tokens = try XCTUnwrap(highlighter.tokens(for: code, info: info), info)
            XCTAssertEqual(tokens.map { "\($0.range) \($0.kind)" },
                           editor.map { "\($0.range.location..<NSMaxRange($0.range)) \($0.style)" }, info)
            let range = (code as NSString).range(of: needle)
            XCTAssertTrue(tokens.contains { $0.kind == kind && $0.range == range.location..<NSMaxRange(range) }, info)
        }
        for info in ["", "unknown-language", "mermaid"] {
            XCTAssertNil(highlighter.tokens(for: "const x = 42;", info: info), info)
        }
    }

    @MainActor private func document(_ text: String, extension ext: String = "ts") throws -> EditorDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(file: try TextFile.read(url))
        document.scroll.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        document.editor.frame = NSRect(x: 0, y: 0, width: 780, height: 600)
        document.setHighlightingActive(true)
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

    @MainActor func testRestoredTabsHighlightOnFirstSelection() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["first.ts", "second.js", "third.json"].map { root.appendingPathComponent($0) }
        let sources = ["const first = 1;", "const second = 2;", "{\"third\": 3}"]
        for (url, source) in zip(urls, sources) { try source.write(to: url, atomically: true, encoding: .utf8) }
        let controller = EditorWindow()
        defer { controller.window?.performClose(nil) }
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                             rootPath: root.path, filePaths: urls.map(\.path), selectedPath: urls[0].path)) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(failures.isEmpty)
        // Let launch-time highlighting settle before first visiting the other tabs.
        try await Task.sleep(for: .milliseconds(400))
        for (url, source) in zip(urls, sources) {
            controller.openFile(url) // Select the already-restored document.
            let editor = try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
            XCTAssertEqual(editor.string, source)
            let document = try XCTUnwrap(editor.delegate as? EditorDocument)
            try await settled(document)
            let run = try XCTUnwrap(SyntaxHighlighting.runs(in: source,
                languageID: try XCTUnwrap(SyntaxHighlighting.languageID(for: url))).first)
            XCTAssertEqual(editor.layoutManager?.temporaryAttribute(.foregroundColor,
                atCharacterIndex: run.range.location, effectiveRange: nil) as? NSColor,
                run.style.color(AppSettings.shared.selectedScheme.syntaxPalette), url.lastPathComponent)
            XCTAssertFalse(document.isDirty)
            XCTAssertFalse(editor.undoManager!.canUndo)
        }
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

    /// A 100 KiB fence of each language, through the preview's highlighter:
    /// SwiftHighlight's tokenizing and the shared mapping to kinds.
    func testFenceTimingWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["ALETHEIA_HIGHLIGHT_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in Release measurement") }
        let snippets = [
            ("ts", """
            /** A cache of parsed records, keyed by id. */
            export interface Entry<T> { id: string; value: T; updated: Date }
            export class Cache<T> {
              private readonly items = new Map<string, Entry<T>>();
              constructor(private limit = 128) {}
              get(id: string): T | undefined {
                const item = this.items.get(id);
                return item?.value; // may be undefined
              }
              set(id: string, value: T): void {
                if (this.items.size >= this.limit) this.items.clear();
                this.items.set(id, { id, value, updated: new Date() });
              }
            }
            console.log(`cached ${new Cache<number>(42).get("answer")} at ${Date.now()}`);

            """),
            ("java", """
            /**
             * Routes requests to their handlers.
             */
            public final class Router implements Handler {
                private static final int LIMIT = 128;
                private final Map<String, Handler> routes = new HashMap<>();

                @Override
                public Response handle(Request request) throws IOException {
                    Handler handler = routes.getOrDefault(request.path(), NOT_FOUND);
                    if (routes.size() > LIMIT) { throw new IllegalStateException("too many: " + routes.size()); }
                    return handler.handle(request); // delegate
                }
            }

            """),
            ("json", """
            {"id": 42, "name": "router", "enabled": true, "ratio": 0.75, "tags": ["a", "b"], "owner": null},

            """),
            ("sh", """
            # Install the dependencies, then build.
            export PREFIX="${HOME}/.local"
            if [ ! -d "$PREFIX/bin" ]; then mkdir -p "$PREFIX/bin"; fi
            for file in src/*.c; do cc -O2 -c "$file" -o "${file%.c}.o" || exit 1; done
            echo "built $(ls src/*.o | wc -l) objects" | tee -a build.log

            """)
        ]
        let highlighter = PreviewCodeHighlighter()
        for (info, snippet) in snippets {
            let code = String(repeating: snippet, count: 100 * 1024 / snippet.utf16.count + 1)
            let language = try XCTUnwrap(LanguageRegistry.shared.language(named: info))
            func median(_ body: () -> Int) -> (Double, Double) {
                _ = body()
                var samples: [Double] = []
                for _ in 0..<21 {
                    let start = ContinuousClock.now
                    XCTAssertGreaterThan(body(), 0)
                    let elapsed = start.duration(to: .now).components
                    samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                }
                samples.sort()
                return (samples[10], samples[19])
            }
            let tokenize = median { language.tokenize(code).count }
            let total = median { highlighter.tokens(for: code, info: info)?.count ?? 0 }
            let count = highlighter.tokens(for: code, info: info)?.count ?? 0
            print("HIGHLIGHT fence \(info) \(code.utf16.count / 1024) KiB, \(count) kinds: tokenize median=\(tokenize.0)ms p95=\(tokenize.1)ms;"
                  + " with mapping median=\(total.0)ms p95=\(total.1)ms")
        }
    }
}
