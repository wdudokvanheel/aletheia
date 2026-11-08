import CoreText
import XCTest
@testable import MarkdownView

/// Long blocks are typeset in windows of their text (F3, F7).
final class LineWindowTests: XCTestCase {
    /// The lines one typesetter over the whole paragraph gives, as layout
    /// gave them before windows: ranges and widths.
    private func referenceLines(_ block: MarkdownBlock, width: CGFloat,
                                unbounded: Bool = false) throws -> [(range: Range<Int>, width: Double)] {
        let text = try XCTUnwrap(BlockLayout.makeText(block))
        let string = try XCTUnwrap(BlockLayout.makeString(text, runs: block.styleRuns, typography: .standard))
        let options = [kCTTypesetterOptionAllowUnboundedLayout: kCFBooleanTrue!] as CFDictionary
        let typesetter = unbounded ? try XCTUnwrap(CTTypesetterCreateWithAttributedStringAndOptions(string, options))
            : CTTypesetterCreateWithAttributedString(string)
        let length = CFStringGetLength(text)
        var lines: [(range: Range<Int>, width: Double)] = []
        var start = 0
        while start < length {
            let count = max(CTTypesetterSuggestLineBreak(typesetter, start, Double(width)), 1)
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            lines.append((start..<(start + count), CTLineGetTypographicBounds(line, nil, nil, nil)))
            start += count
        }
        return lines
    }

    private func assertSameLines(_ markdown: String, width: CGFloat = 400, unbounded: Bool = false,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let block = try XCTUnwrap(MarkdownDocument.parse(markdown).blocks.first)
        let layout = BlockLayout(block: block, columnWidth: width, typography: .standard)
        let reference = try referenceLines(block, width: width, unbounded: unbounded)
        XCTAssertEqual(layout.lines.map(\.range), reference.map(\.range), file: file, line: line)
        for (laidOut, expected) in zip(layout.lines, reference) {
            XCTAssertEqual(CTLineGetTypographicBounds(laidOut.line, nil, nil, nil), expected.width, accuracy: 0.001,
                           file: file, line: line)
        }
    }

    func testParagraphsShorterThanAWindowBreakAsOneTypesetterBreaksThem() throws {
        let paragraphs = [
            String(repeating: "Ordinary prose wraps at word boundaries, and some of it is **strong** or *emphasized*. ",
                   count: 30),
            String(repeating: "Inline `code spans` and [links](https://example.com) with ffi and fl ligatures. ", count: 40),
            String(repeating: "日本語のテキストは文字単位で折り返されます。", count: 60),
            String(repeating: "Emoji 👨‍👩‍👧 and flags 🇳🇱 next to text, e\u{301} and n\u{303}. ", count: 50),
            String(repeating: "x", count: 7_000),
        ]
        for paragraph in paragraphs {
            XCTAssertLessThan(paragraph.utf16.count, TextWindow.length)
            try assertSameLines(paragraph)
            try assertSameLines(paragraph, width: 120)
        }
    }

    func testLongParagraphsBreakAsAnUnboundedTypesetterBreaksThem() throws {
        // Over 10,000 characters, a plain typesetter stops kerning; an
        // unbounded one keeps it, as each window does.
        let paragraph = String(repeating: "AVAWAY To Ty `code` Wa Yo. Wrapping words go on. ", count: 700)
        XCTAssertGreaterThan(paragraph.utf16.count, 3 * TextWindow.length)
        try assertSameLines(paragraph, unbounded: true)
        try assertSameLines(paragraph, width: 160, unbounded: true)
    }

    func testKerningAndCodePaddingSurviveInLongBlocks() throws {
        func codeX(_ count: Int) throws -> CGFloat {
            let snapshot = MarkdownSnapshot.layOut(try MarkdownDocument.parse(
                String(repeating: "AVAWAY To Ty `code` Wa Yo. ", count: count)), width: 900)
            let line = try XCTUnwrap(snapshot.layouts[0].lines.first)
            let code = (snapshot.document.blocks[0].text as NSString).range(of: "code").location
            return line.caretX(code)
        }
        XCTAssertEqual(try codeX(420), try codeX(4), accuracy: 0.01)
        let list = (1...420).map { "- AVAWAY To Ty `code` Wa Yo \($0)" }.joined(separator: "\n")
        let first = try XCTUnwrap(MarkdownSnapshot.layOut(try MarkdownDocument.parse(list), width: 900).layouts[0].lines.first)
        let single = try XCTUnwrap(MarkdownSnapshot.layOut(try MarkdownDocument.parse("- AVAWAY To Ty `code` Wa Yo 1"),
                                                           width: 900).layouts[0].lines.first)
        XCTAssertEqual(first.caretX(15), single.caretX(15), accuracy: 0.01)
    }

    func testLineBreakingIsLinearInParagraphLength() throws {
        // One typesetter over the paragraph took 24 s here: Core Text looks
        // back to the paragraph start for every break.
        for unit in ["word ", "a", "🙂"] {
            let block = try XCTUnwrap(MarkdownDocument.parse(String(repeating: unit, count: 100_000 / unit.count)).blocks.first)
            let start = ContinuousClock.now
            let layout = BlockLayout(block: block, columnWidth: 60, typography: .standard)
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(6), unit)
            XCTAssertEqual(layout.lines.first?.range.lowerBound, 0)
            XCTAssertEqual(layout.lines.last?.range.upperBound, block.text.utf16.count)
            for (line, next) in zip(layout.lines, layout.lines.dropFirst()) {
                XCTAssertEqual(line.range.upperBound, next.range.lowerBound)
            }
        }
    }

    func testWindowsNeverSplitACharacter() throws {
        // Lines of long runs without break opportunities end where the
        // column is full, never inside a grapheme.
        for unit in ["👨‍👩‍👧", "e\u{301}\u{302}", "🇳🇱"] {
            let markdown = String(repeating: unit, count: 30_000 / unit.utf16.count)
            let snapshot = MarkdownSnapshot.layOut(try MarkdownDocument.parse(markdown), width: 700)
            let text = snapshot.document.blocks[0].text as NSString
            for line in snapshot.layouts[0].lines where line.range.lowerBound > 0 {
                XCTAssertEqual(text.rangeOfComposedCharacterSequence(at: line.range.lowerBound).location,
                               line.range.lowerBound, unit)
            }
        }
    }
}
