import AppKit
import Synchronization
import XCTest
@testable import MarkdownView

/// Tokens for every other word, of each kind in turn, for any info string.
struct WordHighlighter: MarkdownCodeHighlighter {
    func tokens(for code: String, info: String) -> [CodeToken]? {
        var tokens: [CodeToken] = []
        var words = 0
        var start: Int?
        var offset = 0
        func endWord() {
            guard let wordStart = start else { return }
            if words % 2 == 0 {
                tokens.append(CodeToken(range: wordStart..<offset,
                                        kind: CodeTokenKind.allCases[tokens.count % CodeTokenKind.allCases.count]))
            }
            words += 1
            start = nil
        }
        for unit in code.utf16 {
            if unit == 0x20 || unit == 0x0A { endWord() } else if start == nil { start = offset }
            offset += 1
        }
        endWord()
        return tokens
    }
}

/// Counts and records its calls, answering with `answer`.
final class RecordingHighlighter: MarkdownCodeHighlighter {
    private let calls = Mutex<[(code: String, info: String)]>([])
    private let answer: @Sendable (String, String) -> [CodeToken]?

    init(_ answer: @escaping @Sendable (String, String) -> [CodeToken]? = { code, info in
        WordHighlighter().tokens(for: code, info: info)
    }) {
        self.answer = answer
    }

    var count: Int { calls.withLock { $0.count } }
    var recorded: [(code: String, info: String)] { calls.withLock { $0 } }

    func tokens(for code: String, info: String) -> [CodeToken]? {
        calls.withLock { $0.append((code, info)) }
        return answer(code, info)
    }
}

/// Fenced code colored by a host highlighter (Phase 10): info strings, run
/// splitting, colors, which blocks ask for tokens, and drawing.
final class CodeHighlightingTests: XCTestCase {
    private func parse(_ markdown: String, _ highlighter: (any MarkdownCodeHighlighter)?) throws -> MarkdownDocument {
        try MarkdownDocument.parse(markdown, reusing: nil, highlighting: highlighter.map(CodeHighlighting.init)).document
    }

    // MARK: Info strings

    func testFencedBlocksKeepTheirInfoStrings() throws {
        let markdown = "```java\na\n```\n\n"
            + "```ts title=\"x\"  \nb\n```\n\n"
            + "``` {python}\nc\n```\n\n"
            + "~~~   rust \t\nd\n~~~\n\n"
            + "```\ne\n```\n\n"
            + "    indented\n\n"
            + "Text.\n\n"
            + "- item\n\n  ```sh\n  f\n  ```\n- other\n\n      indented in an item\n\n"
            + "> ```js\n> g\n> ```\n>\n>     quoted indented\n"
        let blocks = try parse(markdown, nil).blocks
        XCTAssertEqual(blocks.map(\.codeInfo), [["java"], ["ts title=\"x\""], ["{python}"], ["rust"], [""], [""], [],
                                                ["sh", ""], ["js", ""]])
    }

    func testFrontMatterShownAsCodeHasAnEmptyInfoString() throws {
        XCTAssertEqual(try parse("---\n- a\n- b\n---\n\nText.", nil).blocks.map(\.codeInfo), [[""], []])
        XCTAssertEqual(try parse("---\ntitle: x\n---\n\nText.", nil).blocks.map(\.codeInfo), [[], []])
    }

    // MARK: Tokens and runs

    func testTokensAreClippedToTheTextAndScalarsAndOverlapsDropped() {
        // "ab😀cd": the emoji is units 2 and 3.
        let tokens = [CodeToken(range: 5..<99, kind: .comment), CodeToken(range: 0..<2, kind: .name),
                      CodeToken(range: -3..<1, kind: .keyword), CodeToken(range: 1..<3, kind: .string),
                      CodeToken(range: 3..<5, kind: .number), CodeToken(range: 2..<3, kind: .markup),
                      CodeToken(range: 4..<4, kind: .invalid), CodeToken(range: 7..<9, kind: .property)]
        XCTAssertEqual(MarkdownBlock.clipped(tokens, to: "ab😀cd", length: 6),
                       [CodeToken(range: 0..<1, kind: .keyword), CodeToken(range: 1..<2, kind: .string),
                        CodeToken(range: 4..<5, kind: .number), CodeToken(range: 5..<6, kind: .comment)])
        // Equal starts: the earlier in the array wins.
        XCTAssertEqual(MarkdownBlock.clipped([CodeToken(range: 0..<2, kind: .string), CodeToken(range: 0..<1, kind: .name)],
                                             to: "ab", length: 2),
                       [CodeToken(range: 0..<2, kind: .string)])
    }

    func testRunsSplitAtTokensAndKeepTheirStyles() {
        let runs = [StyleRun(range: 0..<2, role: .body), StyleRun(range: 2..<6, role: .code),
                    StyleRun(range: 6..<9, role: .code, styles: .quoted)]
        let split = MarkdownBlock.split(runs, at: [CodeToken(range: 3..<4, kind: .keyword),
                                                   CodeToken(range: 4..<7, kind: .keyword),
                                                   CodeToken(range: 8..<9, kind: .string)])
        XCTAssertEqual(split, [StyleRun(range: 0..<2, role: .body), StyleRun(range: 2..<3, role: .code),
                               StyleRun(range: 3..<6, role: .code, token: .keyword),
                               StyleRun(range: 6..<7, role: .code, styles: .quoted, token: .keyword),
                               StyleRun(range: 7..<8, role: .code, styles: .quoted),
                               StyleRun(range: 8..<9, role: .code, styles: .quoted, token: .string)])
    }

    func testHighlightingNeverSplitsASurrogatePair() throws {
        let highlighter = RecordingHighlighter { _, _ in
            (0..<12).map { CodeToken(range: $0..<($0 + 1), kind: CodeTokenKind.allCases[$0 % 8]) }
        }
        let block = try XCTUnwrap(try parse("```swift\na😀b👍🏽c\n```", highlighter).blocks.first)
        let units = Array(block.text.utf16)
        XCTAssertEqual(block.styleRuns.first?.range.lowerBound, 0)
        XCTAssertEqual(block.styleRuns.last?.range.upperBound, units.count)
        for (run, next) in zip(block.styleRuns, block.styleRuns.dropFirst()) {
            XCTAssertEqual(run.range.upperBound, next.range.lowerBound, "contiguous")
            XCTAssertFalse(UTF16.isTrailSurrogate(units[next.range.lowerBound]), "\(block.styleRuns)")
        }
        XCTAssertEqual(block.styleRuns.filter { $0.token != nil }.map(\.range), [0..<1, 3..<4, 8..<9])
        let layout = BlockLayout(block: block, columnWidth: 600, typography: .standard)
        XCTAssertEqual(layout.lines.map(\.range), [0..<units.count])
    }

    func testCodeInListsAndQuotesIsHighlightedInPlace() throws {
        let highlighter = RecordingHighlighter()
        let document = try parse("- item\n\n  ```swift\n  let a = 1\n  ```\n\n> Quote.\n>\n> ```js\n> var b\n> ```", highlighter)
        XCTAssertEqual(highlighter.recorded.map(\.code), ["let a = 1", "var b"])
        XCTAssertEqual(highlighter.recorded.map(\.info), ["swift", "js"])
        let text = { (block: MarkdownBlock, run: StyleRun) in
            String((block.text as NSString).substring(with: NSRange(location: run.range.lowerBound, length: run.range.count)))
        }
        let list = document.blocks[0]
        XCTAssertEqual(list.styleRuns.filter { $0.token != nil }.map { text(list, $0) }, ["let", "="])
        let quote = document.blocks[1]
        let tokenized = quote.styleRuns.filter { $0.token != nil }
        XCTAssertEqual(tokenized.map { text(quote, $0) }, ["var"])
        XCTAssertEqual(tokenized.map(\.styles), [[.quoted]], "a quoted block keeps its style")
        // The token takes its color; the rest of the quoted code stays muted.
        let layout = BlockLayout(block: quote, columnWidth: 600, typography: .standard)
        let codeLine = try XCTUnwrap(layout.lines.last)
        XCTAssertNil(codeLine.color)
        XCTAssertEqual(ColorIndex.of(.code, [.quoted], .keyword), ColorIndex.token(.keyword))
        XCTAssertEqual(ColorIndex.of(.code, [.quoted]), TextRole.quote.rawValue)
    }

    func testWithoutTokensBlocksAreAsWithoutAHighlighter() throws {
        let markdown = "# Title\n\n```swift\nlet a = 1\n```\n\n    indented\n\n- ```sh\n  ls\n  ```"
        let plain = try parse(markdown, nil)
        XCTAssertEqual(try parse(markdown, RecordingHighlighter { _, _ in nil }).blocks, plain.blocks)
        XCTAssertEqual(try parse(markdown, RecordingHighlighter { _, _ in [] }).blocks, plain.blocks)
    }

    func testCodeOverTheCapIsNotHighlighted() throws {
        let highlighter = RecordingHighlighter { _, _ in [CodeToken(range: 0..<1, kind: .keyword)] }
        let limit = MarkdownBlock.highlightLimit
        let document = try parse("```swift\n" + String(repeating: "x", count: limit) + "\n```\n\n```swift\n"
                                 + String(repeating: "y", count: limit + 1) + "\n```", highlighter)
        XCTAssertEqual(highlighter.recorded.map(\.code.utf16.count), [limit])
        XCTAssertEqual(document.blocks.map { $0.styleRuns.contains { $0.token != nil } }, [true, false])
    }

    // MARK: Colors

    func testEachKindHasItsColorAndTheDefaultIsCodeText() {
        let palette = Palette.standard
        let colors = palette.cgColors
        XCTAssertEqual(colors.count, TextRole.allCases.count + 1 + CodeTokenKind.allCases.count)
        for kind in CodeTokenKind.allCases {
            let index = ColorIndex.of(.code, [], kind)
            XCTAssertEqual(index, ColorIndex.link + 1 + kind.rawValue)
            XCTAssertEqual(palette.color(for: kind), palette.codeText)
            XCTAssertEqual(colors[Int(index)], palette.codeText.cgColor)
            XCTAssertEqual(ColorIndex.of(.body, [], kind), TextRole.body.rawValue, "only code text has tokens")
        }
        var custom = Palette(background: .white, text: .black, headingText: .black, codeText: .black,
                             codeBackground: .white, mutedText: .gray)
        let hues: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
                               .systemPink, .systemBrown]
        custom.codeComment = hues[0]
        custom.codeString = hues[1]
        custom.codeKeyword = hues[2]
        custom.codeNumber = hues[3]
        custom.codeName = hues[4]
        custom.codeProperty = hues[5]
        custom.codeMarkup = hues[6]
        custom.codeInvalid = hues[7]
        let customColors = custom.cgColors
        for kind in CodeTokenKind.allCases {
            XCTAssertEqual(customColors[Int(ColorIndex.token(kind))], hues[Int(kind.rawValue)].cgColor, "\(kind)")
        }
    }

    func testATokenColoredLineDrawsRunByRun() throws {
        let markdown = "```swift\nlet value = 1\n```"
        let plain = MarkdownSnapshot.layOut(try parse(markdown, nil), width: 700)
        XCTAssertEqual(plain.layouts[0].lines.map(\.color), [TextRole.code.rawValue], "one color, one pass")
        let highlighted = MarkdownSnapshot.layOut(try parse(markdown, WordHighlighter()), width: 700)
        XCTAssertEqual(highlighted.layouts[0].lines.map(\.color), [nil])
        // Tokens are colored within glyph runs: code shapes as without them.
        let glyphRuns = { (snapshot: MarkdownSnapshot) in
            snapshot.layouts[0].lines.map { CFArrayGetCount(CTLineGetGlyphRuns($0.line)) }
        }
        XCTAssertEqual(glyphRuns(highlighted), glyphRuns(plain))
        let one = MarkdownSnapshot.layOut(try parse(markdown, RecordingHighlighter { code, _ in
            [CodeToken(range: 0..<code.utf16.count, kind: .string)]
        }), width: 700)
        XCTAssertEqual(one.layouts[0].lines.map(\.color), [ColorIndex.token(.string)], "a line in one token")
    }

    // MARK: Concurrency

    /// For the Thread Sanitizer run: a first parse highlights its blocks on
    /// several threads while the host calls the same highlighter elsewhere.
    func testTheHighlighterIsCalledConcurrently() throws {
        let highlighter = RecordingHighlighter()
        let markdown = (0..<64).map { "Paragraph \($0).\n\n```swift\nlet value\($0) = compute(\($0))\nprint(value\($0))\n```" }
            .joined(separator: "\n\n")
        let elsewhere = DispatchGroup()
        DispatchQueue.global().async(group: elsewhere) {
            DispatchQueue.concurrentPerform(iterations: 64) { _ in _ = highlighter.tokens(for: "let a = b", info: "swift") }
        }
        let highlighting = CodeHighlighting(highlighter)
        let document = try MarkdownDocument.parse(markdown, reusing: nil, highlighting: highlighting).document
        elsewhere.wait()
        XCTAssertEqual(highlighter.count, 128)
        XCTAssertEqual(document.blocks.filter { $0.styleRuns.contains { $0.token != nil } }.count, 64)
        let snapshot = MarkdownSnapshot.layOut(document, width: 700)
        let edited = markdown + "\n\nThe end."
        let incremental = try MarkdownSnapshot.updating(snapshot, to: edited, width: 700, highlighting: highlighting)
        XCTAssertEqual(highlighter.count, 128, "unchanged blocks keep their tokens")
        XCTAssertEqual(incremental.reused, 128)
        XCTAssertEqual(Array(incremental.snapshot.document.blocks.prefix(128)), document.blocks)
    }
}

/// The highlighter in the view: which blocks ask for tokens, setting it, and
/// what it draws and copies.
@MainActor
final class CodeHighlightingViewTests: XCTestCase {
    private var window: NSWindow!
    private var view: MarkdownPreviewView!
    private var canvas: MarkdownDocumentView { view.documentView as! MarkdownDocumentView }

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = MarkdownPreviewView(frame: window.contentLayoutRect)
        window.contentView = view
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        view = nil
    }

    /// Waits until a complete snapshot that `isDone` accepts has installed.
    private func waitForInstall(after change: () -> Void, until isDone: @escaping (MarkdownSnapshot) -> Bool) {
        let installed = expectation(description: "installed")
        installed.assertForOverFulfill = false
        let original = view.pipeline.onOutcome
        view.pipeline.onOutcome = { [view] outcome in
            original?(outcome)
            if view!.snapshot.isComplete, isDone(view!.snapshot) { installed.fulfill() }
        }
        change()
        wait(for: [installed], timeout: 10)
        view.pipeline.onOutcome = original
    }

    private func load(_ text: String) {
        waitForInstall(after: { view.setSource(text) }) { $0.document.source == text }
        // The scroller appearing narrows the view once, on a later turn of
        // the run loop; let that settle too.
        window.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if view.snapshot.width != view.contentView.bounds.width {
            waitForInstall(after: {}) { [view] in $0.width == view!.contentView.bounds.width }
            window.display()
        }
    }

    private static let blocks = [
        "# Title", "First paragraph.", "```swift\nlet a = 1\n```", "Second paragraph.",
        "- item\n\n  ```sh\n  ls -la\n  ```", "```js\nvar b = 2\n```", "Third paragraph.",
    ]

    private func source(_ blocks: [String]) -> String { blocks.joined(separator: "\n\n") }

    func testEditingAParagraphAsksForNoTokens() {
        let highlighter = RecordingHighlighter()
        view.codeHighlighter = highlighter
        load(source(Self.blocks))
        XCTAssertEqual(highlighter.recorded.map(\.info), ["swift", "sh", "js"])
        let codeLayouts = [2, 4, 5].map { view.snapshot.layouts[$0] }

        var blocks = Self.blocks
        blocks[3] = "Second paragraph, edited."
        load(source(blocks))
        XCTAssertEqual(highlighter.count, 3, "untouched code keeps its tokens")
        XCTAssertTrue(zip(codeLayouts, [2, 4, 5].map { view.snapshot.layouts[$0] }).allSatisfy { $0 === $1 },
                      "and its layout")

        blocks[5] = "```js\nvar b = 22\n```"
        load(source(blocks))
        XCTAssertEqual(highlighter.recorded.map(\.code), ["let a = 1", "ls -la", "var b = 2", "var b = 22"])
        XCTAssertTrue(view.snapshot.layouts[2] === codeLayouts[0])
    }

    func testSettingTheHighlighterRendersAgain() {
        load(source(Self.blocks))
        let plain = view.snapshot
        XCTAssertFalse(plain.document.blocks.contains { $0.styleRuns.contains { $0.token != nil } })
        let runs = view.pipeline.runs

        let highlighter = RecordingHighlighter()
        waitForInstall(after: { view.codeHighlighter = highlighter }) { snapshot in
            snapshot.document.blocks[2].styleRuns.contains { $0.token != nil }
        }
        XCTAssertTrue(view.codeHighlighter as? RecordingHighlighter === highlighter)
        XCTAssertGreaterThan(view.pipeline.runs, runs)
        XCTAssertEqual(highlighter.count, 3)
        let highlighted = view.snapshot
        for index in highlighted.layouts.indices {
            let hasCode = !highlighted.document.blocks[index].codeInfo.isEmpty
            XCTAssertEqual(highlighted.layouts[index] === plain.layouts[index], !hasCode, "block \(index)")
            XCTAssertEqual(highlighted.document.blocks[index].styleRuns.contains { $0.token != nil }, hasCode)
        }

        waitForInstall(after: { view.codeHighlighter = nil }) { snapshot in
            !snapshot.document.blocks.contains { $0.styleRuns.contains { $0.token != nil } }
        }
        XCTAssertNil(view.codeHighlighter)
        XCTAssertEqual(view.snapshot.document.blocks, plain.document.blocks)
        XCTAssertTrue(view.snapshot.layouts[1] === plain.layouts[1])
    }

    func testTokensDrawInTheirColors() throws {
        view.palette = Palette(background: .white, text: .black, headingText: .black, codeText: .black,
                               codeBackground: .white, mutedText: .gray)
        view.palette.codeKeyword = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        view.codeHighlighter = RecordingHighlighter { _, _ in [CodeToken(range: 0..<7, kind: .keyword)] }
        load("```swift\nKEYWORD plain text\n```")
        let snapshot = view.snapshot
        let line = try XCTUnwrap(snapshot.layouts[0].lines.first)
        XCTAssertNil(line.color)
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / canvas.bounds.height
        var red = 0
        var black = 0
        let top = snapshot.blockTops[0] + line.top
        for y in Int(top * scale)..<Int((top + line.height) * scale) {
            for x in Int((snapshot.columnX + line.x) * scale)..<Int((snapshot.columnX + line.x + 200) * scale) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let (r, g, b) = (color.redComponent, color.greenComponent, color.blueComponent)
                if r - (g + b) / 2 > 0.35 { red += 1 }
                if r < 0.5, abs(r - g) < 0.1, abs(r - b) < 0.1 { black += 1 }
            }
        }
        XCTAssertGreaterThan(red, 20, "the keyword is red")
        XCTAssertGreaterThan(black, 20, "the rest stays in the code color")
    }

    func testCopyIgnoresTokens() throws {
        let markdown = "Intro.\n\n```swift\nlet a = 1\nprint(a)\n```\n\n> ```js\n> var b\n> ```"
        load(markdown)
        let plain = view.snapshot
        waitForInstall(after: { view.codeHighlighter = WordHighlighter() }) { snapshot in
            snapshot.document.blocks[1].styleRuns.contains { $0.token != nil }
        }
        let highlighted = view.snapshot
        let range = TextPosition(block: 0, offset: 0)..<TextPosition(block: 2, offset: highlighted.layouts[2].textLength)
        XCTAssertEqual(highlighted.text(in: range), plain.text(in: range))
        XCTAssertEqual(highlighted.html(in: range), plain.html(in: range))
        XCTAssertEqual(highlighted.rtf(in: range), plain.rtf(in: range))
    }
}
