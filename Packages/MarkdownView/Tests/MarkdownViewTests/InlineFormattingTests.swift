import CoreText
import XCTest
@testable import MarkdownView

final class InlineFormattingTests: XCTestCase {
    private func block(_ markdown: String, file: StaticString = #filePath, line: UInt = #line) throws -> MarkdownBlock {
        try XCTUnwrap(MarkdownDocument.parse(markdown).blocks.first, file: file, line: line)
    }

    private func run(_ range: Range<Int>, _ styles: InlineStyle = [], _ role: TextRole = .body) -> StyleRun {
        StyleRun(range: range, role: role, styles: styles)
    }

    // MARK: Styles

    func testEachInlineStyle() throws {
        let block = try block("Plain *em* **strong** ~~gone~~ `code` end")
        XCTAssertEqual(block.text, "Plain em strong gone code end")
        XCTAssertEqual(block.styleRuns, [
            run(0..<6), run(6..<8, .emphasis), run(8..<9), run(9..<15, .strong), run(15..<16),
            run(16..<20, .strikethrough), run(20..<21), run(21..<25, .code), run(25..<29)
        ])
        XCTAssertTrue(block.links.isEmpty)
    }

    func testNestedStylesCombine() throws {
        let block = try block("***both*** and **bold _italic_ bold** and ~~**struck bold**~~ and *`code em`*")
        XCTAssertEqual(block.text, "both and bold italic bold and struck bold and code em")
        XCTAssertEqual(block.styleRuns, [
            run(0..<4, [.emphasis, .strong]), run(4..<9), run(9..<14, .strong), run(14..<20, [.strong, .emphasis]),
            run(20..<25, .strong), run(25..<30), run(30..<41, [.strikethrough, .strong]), run(41..<46),
            run(46..<53, [.emphasis, .code])
        ])
    }

    func testHeadingsKeepTheirRoleUnderInlineStyles() throws {
        let block = try block("## Title with *em* and `code`")
        XCTAssertEqual(block.text, "Title with em and code")
        XCTAssertEqual(block.styleRuns, [
            run(0..<11, [], .heading2), run(11..<13, .emphasis, .heading2), run(13..<18, [], .heading2),
            run(18..<22, .code, .heading2)
        ])
        let typography = Typography.standard
        let heading = typography.fonts[Int(TextRole.heading2.rawValue)]
        let code = typography.font(.heading2, .code)
        XCTAssertEqual(CTFontGetSize(code), CTFontGetSize(heading) * 0.9, accuracy: 0.01)
        XCTAssertTrue(CTFontGetSymbolicTraits(code).contains(.traitMonoSpace))
        XCTAssertTrue(CTFontGetSymbolicTraits(code).contains(.traitBold))
        XCTAssertTrue(CTFontGetSymbolicTraits(typography.font(.heading2, .emphasis)).contains(.traitItalic))
        XCTAssertTrue(CTFontGetSymbolicTraits(typography.font(.body, [.strong, .emphasis])).contains([.traitBold, .traitItalic]))
        XCTAssertFalse(CTFontGetSymbolicTraits(typography.font(.body, .link)).contains(.traitBold))
    }

    func testInlineCodeIsMonospacedAtNinetyPercent() {
        let typography = Typography.standard
        let code = typography.font(.body, .code)
        XCTAssertEqual(CTFontGetSize(code), 13.5, accuracy: 0.01)
        XCTAssertTrue(CTFontGetSymbolicTraits(code).contains(.traitMonoSpace))
        XCTAssertTrue(CTFontGetSymbolicTraits(typography.font(.body, [.code, .emphasis])).contains(.traitItalic))
    }

    // MARK: Links

    func testLinkRangesAndDestinations() throws {
        let block = try block("""
        See [the docs](docs/guide.md "Guide"), <https://example.com>, www.example.org, and mail@example.com.
        """)
        XCTAssertEqual(block.text, "See the docs, https://example.com, www.example.org, and mail@example.com.")
        XCTAssertEqual(block.links, [
            MarkdownLink(range: 4..<12, destination: "docs/guide.md", title: "Guide"),
            MarkdownLink(range: 14..<33, destination: "https://example.com"),
            MarkdownLink(range: 35..<50, destination: "http://www.example.org"),
            MarkdownLink(range: 56..<72, destination: "mailto:mail@example.com")
        ])
        XCTAssertEqual(block.styleRuns, [
            run(0..<4), run(4..<12, .link), run(12..<14), run(14..<33, .link), run(33..<35), run(35..<50, .link),
            run(50..<56), run(56..<72, .link), run(72..<73)
        ])
    }

    func testStyledLinksEscapedDestinationsAndImages() throws {
        let block = try block("""
        [**Bold** link](https://x.test/a\\_b&amp;c) ![alt *text*](img.png) [![logo](l.png)](mailto:me@x.test) [](empty)
        """)
        XCTAssertEqual(block.text, "Bold link alt text logo ")
        XCTAssertEqual(block.links, [
            MarkdownLink(range: 0..<9, destination: "https://x.test/a_b&c"),
            MarkdownLink(range: 19..<23, destination: "mailto:me@x.test")
        ])
        // Alt text is marked as an image's, which mutes it until the image shows.
        XCTAssertEqual(block.styleRuns, [
            run(0..<4, [.link, .strong]), run(4..<9, .link), run(9..<10), run(10..<14, .image),
            run(14..<18, [.emphasis, .image]), run(18..<19), run(19..<23, [.link, .image]), run(23..<24)
        ])
    }

    // MARK: Text

    func testInlineHTMLIsDroppedAndItsTextKept() throws {
        let block = try block("Some <b>bold</b> and <span class=\"x\">span</span> text<br> <!-- note --> end")
        // The spaces around the dropped tags collapse, as `white-space: normal` shows them.
        XCTAssertEqual(block.text, "Some bold and span text end")
        XCTAssertEqual(block.styleRuns, [run(0..<27)])
    }

    func testHardAndSoftBreaks() throws {
        let block = try block("line one\nline two  \nline three\\\nline four")
        XCTAssertEqual(block.text, "line one line two\nline three\nline four")
        XCTAssertEqual(block.styleRuns, [run(0..<38)])
    }

    func testEscapesAndEntitiesDisplayAsLiterals() throws {
        let block = try block("\\*not em\\* &amp; &copy; &#35; &#x41; \\[x\\] \\`tick\\` &lt;b&gt;")
        XCTAssertEqual(block.text, "*not em* & \u{A9} # A [x] `tick` <b>")
        XCTAssertEqual(block.styleRuns, [run(0..<31)])
    }

    // MARK: Source map

    func testSourceMapRoundTripsInAParagraphWithEmphasisAndALink() throws {
        let document = try MarkdownDocument.parse("# H\n\nRead *this* and [that link](https://example.com/x) now.")
        let block = document.blocks[1]
        XCTAssertEqual(block.text, "Read this and that link now.")
        XCTAssertEqual(block.sourceRange.lowerBound, 5)
        let map = block.sourceMap
        // Display offset to source offset, relative to the block.
        for (display, source) in [(0, 0), (2, 2), (5, 6), (7, 8), (9, 11), (14, 17), (20, 23), (23, 50), (28, 55)] {
            XCTAssertEqual(map.sourceOffset(forDisplayOffset: display), source, "display \(display)")
        }
        // Source offsets inside markup map to the next text.
        for (source, display) in [(6, 5), (5, 5), (10, 9), (30, 23), (52, 25), (55, 28)] {
            XCTAssertEqual(map.displayOffset(forSourceOffset: source), display, "source \(source)")
        }
        XCTAssertEqual(block.sourceOffset(forDisplayOffset: 5), 11)
        XCTAssertEqual(block.displayOffset(forSourceOffset: 11), 5)
    }

    /// Every display character that is copied from the source maps to that
    /// same character, in every block of a mixed document.
    func testSourceMapFindsTextInEveryKindOfBlock() throws {
        let markdown = """
        ## Caf\u{E9} *\u{1F600} smile* `code`

        > quoted *one*
        lazy two
        > three [link](u)

        1. first **item**
           continued line
        2. second ~~item~~
           - nested <https://example.com/n>

        ```swift
        let a = 1
          indented()
        ```

        > ```
        > quoted code
        > ```

        | Name | *Value* |
        | ---- | ------- |
        | `pi` | 3.14 www.example.com |

            indented code
            block

        Escapes \\*a\\* &amp; entities &copy; and a hard\\
        break with `two  spaces` and trailing text.
        """
        let document = try MarkdownDocument.parse(markdown)
        let source = markdown.utf16.map { $0 }
        XCTAssertEqual(document.blocks.map(\.kind), [.heading(level: 2), .blockQuote, .list, .codeBlock, .blockQuote,
                                                     .table, .codeBlock, .paragraph])
        for (index, block) in document.blocks.enumerated() {
            let text = Array(block.text.utf16)
            var checked = 0
            for offset in text.indices where Self.isMappedVerbatim(text[offset]) {
                let mapped = block.sourceOffset(forDisplayOffset: offset)
                XCTAssertTrue(block.sourceRange.contains(mapped), "block \(index) offset \(offset)")
                guard source.indices.contains(mapped) else { continue }
                XCTAssertEqual(source[mapped], text[offset],
                               "block \(index) \(block.text.debugDescription) offset \(offset)")
                XCTAssertEqual(block.displayOffset(forSourceOffset: mapped), offset, "block \(index) offset \(offset)")
                checked += 1
            }
            XCTAssertGreaterThan(checked, 0, "block \(index)")
        }
    }

    /// Letters, digits, and surrogates are never produced by escapes or
    /// entities in the fixture above, so they must map to themselves.
    private static func isMappedVerbatim(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return CharacterSet.alphanumerics.contains(scalar) && unit != 0xA9
    }

    func testSourceMapForHandBuiltBlocksIsTheIdentity() {
        let block = MarkdownBlock(kind: .paragraph, sourceRange: 10..<15, sourceText: "hello", text: "hello",
                                  styleRuns: [StyleRun(range: 0..<5, role: .body)])
        XCTAssertEqual(block.sourceOffset(forDisplayOffset: 3), 13)
        XCTAssertEqual(block.displayOffset(forSourceOffset: 14), 4)
        XCTAssertEqual(block.sourceOffset(forDisplayOffset: 9), 15)
    }

    // MARK: Layout

    func testDecorationsFollowStyledRuns() throws {
        let document = try MarkdownDocument.parse("Plain **bold** words\n\nUse `code` and ~~gone~~ and [a link](https://x.test).")
        let snapshot = MarkdownSnapshot.layOut(document, width: 800)
        let plain = try XCTUnwrap(snapshot.layouts[0].lines.first)
        XCTAssertEqual(plain.color, TextRole.body.rawValue, "bold body text draws in one pass")
        XCTAssertTrue(plain.decorations.isEmpty)

        let layout = snapshot.layouts[1]
        XCTAssertEqual(layout.lineCount, 1)
        let line = layout.lines[0]
        XCTAssertNil(line.color, "the link takes another color")
        let kinds = line.decorations.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .codeBackground }.count, 1, "the kerned last character joins the background")
        XCTAssertEqual(kinds.first, .codeBackground)
        let code = line.decorations[0].rect
        // Glyph origins: Core Text puts the caret halfway into kerning.
        func glyphX(at offset: Int) -> CGFloat? {
            for run in CTLineGetGlyphRuns(line.line) as? [CTRun] ?? [] where CTRunGetStringRange(run).location == offset {
                var origin = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &origin)
                return origin.x
            }
            return nil
        }
        let padding = Typography.standard.inlineCodePadding
        let codeStart = try XCTUnwrap(glyphX(at: 4))
        // Padded on both sides, with room made by kerning before and after.
        XCTAssertEqual(code.minX, codeStart - padding, accuracy: 0.5)
        XCTAssertEqual(code.maxX, try XCTUnwrap(glyphX(at: 8)), accuracy: 0.5)
        XCTAssertGreaterThan(code.minX, CTLineGetOffsetForStringIndex(line.line, 3, nil) + 2, "clear of the space before")
        XCTAssertLessThan(code.minY, line.baseline - 8)
        XCTAssertGreaterThan(code.maxY, line.baseline)
        let underlines = line.decorations.filter { $0.kind == .underline }
        let underline = underlines.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(underline.minX, CTLineGetOffsetForStringIndex(line.line, 22, nil), accuracy: 0.5)
        XCTAssertEqual(underline.maxX, CTLineGetOffsetForStringIndex(line.line, 28, nil), accuracy: 0.5)
        XCTAssertGreaterThan(underline.minY, line.baseline)
        XCTAssertEqual(underlines.map(\.color), underlines.map { _ in ColorIndex.link })
        let strike = try XCTUnwrap(line.decorations.first { $0.kind == .strikethrough })
        XCTAssertEqual(strike.rect.minX, CTLineGetOffsetForStringIndex(line.line, 13, nil), accuracy: 0.5)
        XCTAssertLessThan(strike.rect.maxY, line.baseline)
        XCTAssertEqual(strike.color, TextRole.body.rawValue)
    }

    func testLinkHitTestingCoversOnlyLinkText() throws {
        let document = try MarkdownDocument.parse("Go to [the site](https://example.com) now.")
        let snapshot = MarkdownSnapshot.layOut(document, width: 600)
        let layout = snapshot.layouts[0]
        let line = layout.lines[0]
        func point(at offset: Int) -> CGPoint {
            let x = CTLineGetOffsetForStringIndex(line.line, offset, nil)
            return CGPoint(x: snapshot.columnX + line.x + x + 2, y: snapshot.blockTops[0] + line.top + 2)
        }
        XCTAssertEqual(snapshot.linkDestination(at: point(at: 6)), "https://example.com")
        XCTAssertEqual(snapshot.linkDestination(at: point(at: 13)), "https://example.com")
        XCTAssertNil(snapshot.linkDestination(at: point(at: 1)))
        XCTAssertNil(snapshot.linkDestination(at: point(at: 16)))
        XCTAssertNil(snapshot.linkDestination(at: CGPoint(x: point(at: 6).x, y: snapshot.blockTops[0] - 4)))
    }
}
