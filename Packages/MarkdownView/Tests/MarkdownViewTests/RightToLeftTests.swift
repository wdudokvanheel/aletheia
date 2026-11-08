import CoreText
import XCTest
@testable import MarkdownView

/// Paragraph directions as `dir="auto"` sets them, and selection in
/// mixed-direction lines (F9, F10).
final class RightToLeftTests: XCTestCase {
    private func snapshot(_ markdown: String, width: CGFloat = 700) throws -> MarkdownSnapshot {
        MarkdownSnapshot.layOut(try MarkdownDocument.parse(markdown), width: width)
    }

    private func visibleWidth(_ line: LineLayout) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line.line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line.line))
    }

    /// The string ranges of a line's glyph runs, left to right.
    private func visualRuns(_ line: LineLayout) -> [Range<Int>] {
        (CTLineGetGlyphRuns(line.line) as? [CTRun] ?? []).map {
            let range = CTRunGetStringRange($0)
            return range.location..<(range.location + range.length)
        }
    }

    func testARightToLeftParagraphReadsAndAlignsRightToLeft() throws {
        let snapshot = try snapshot("مرحبا بالعالم (hello) 123.")
        let line = try XCTUnwrap(snapshot.layouts[0].lines.first)
        XCTAssertTrue(line.isRightToLeft)
        XCTAssertEqual(line.x + visibleWidth(line), snapshot.columnWidth, accuracy: 0.01)
        // The period, logically last, is drawn at the left end.
        let period = line.range.upperBound - 1
        XCTAssertLessThan(line.caretX(period), line.caretX(0))
        XCTAssertEqual(visualRuns(line).first?.contains(period), true)
    }

    func testALeftToRightParagraphStaysLeftAligned() throws {
        let snapshot = try snapshot("Urdu as (چوکیدار) which is widely used.")
        let line = try XCTUnwrap(snapshot.layouts[0].lines.first)
        XCTAssertFalse(line.isRightToLeft)
        XCTAssertEqual(line.x, 0)
    }

    func testCodeIsAlwaysLeftToRight() throws {
        let snapshot = try snapshot("```\n// 1392 بهمن 22\n```")
        let line = try XCTUnwrap(snapshot.layouts[0].lines.first)
        XCTAssertFalse(line.isRightToLeft)
        // `//` comes first, at the left, as WebKit shows it.
        XCTAssertEqual(visualRuns(line).first?.lowerBound, 0)
        XCTAssertEqual(line.caretX(0), 0, accuracy: 0.01)
    }

    func testAHardBreakKeepsTheParagraphsDirection() throws {
        let rightToLeft = try snapshot("مرحبا بالعالم\\\nhello world")
        XCTAssertEqual(rightToLeft.layouts[0].lines.count, 2)
        for line in rightToLeft.layouts[0].lines {
            XCTAssertTrue(line.isRightToLeft)
            XCTAssertEqual(line.x + visibleWidth(line), rightToLeft.columnWidth, accuracy: 0.01)
        }
        // A line after the break that starts with Latin still reads right to
        // left: "hello world" is drawn as one left-to-right run at the right.
        let second = rightToLeft.layouts[0].lines[1]
        XCTAssertGreaterThan(second.x, 0)
        let leftToRight = try snapshot("hello world\\\nمرحبا بالعالم")
        for line in leftToRight.layouts[0].lines {
            XCTAssertFalse(line.isRightToLeft)
            XCTAssertEqual(line.x, 0)
        }
    }

    func testDirectionIsPerParagraphInListsAndQuotes() throws {
        let snapshot = try snapshot("- first item\n- مرحبا بالعالم\n\n> שלום עולם\n> \n> back to English")
        let list = snapshot.layouts[0].lines
        XCTAssertEqual(list.map(\.isRightToLeft), [false, true])
        XCTAssertGreaterThan(list[1].x, list[0].x)
        let quote = snapshot.layouts[1].lines
        XCTAssertEqual(quote.map(\.isRightToLeft), [true, false])
    }

    func testRightToLeftCellsStartOnTheRight() throws {
        let snapshot = try snapshot("| head |\n|---|\n| نص عربي 42. |\n| text |\n| wider text in the column |")
        let table = try XCTUnwrap(snapshot.layouts[0].tables.first)
        let arabic = try XCTUnwrap(table.rows[1].lines(ofCell: 0).first)
        let latin = try XCTUnwrap(table.rows[2].lines(ofCell: 0).first)
        XCTAssertTrue(arabic.isRightToLeft)
        XCTAssertFalse(latin.isRightToLeft)
        XCTAssertEqual(table.alignmentOffset(of: arabic, row: 1, column: 0) + arabic.maxX, table.columnWidths[0],
                       accuracy: 0.5)
        XCTAssertEqual(table.alignmentOffset(of: latin, row: 2, column: 0), 0)
        // The cell's own period is drawn at its left.
        let period = arabic.range.upperBound - 1
        XCTAssertLessThan(arabic.caretX(period), arabic.caretX(arabic.range.lowerBound))
    }

    /// For every selection of `line`'s text, the highlight covers the
    /// selected glyphs and no others, by their centers.
    private func assertHighlightCoversExactlyTheSelection(_ snapshot: MarkdownSnapshot, block: Int,
                                                          line lineIndex: Int,
                                                          file: StaticString = #filePath, lineNumber: UInt = #line) {
        let layout = snapshot.layouts[block]
        let line = layout.lines[lineIndex]
        let text = snapshot.document.blocks[block].text as NSString
        let top = snapshot.blockTops[block] + line.top
        let left = snapshot.columnX + line.x
        var glyphs: [(index: Int, center: CGFloat)] = []
        for run in CTLineGetGlyphRuns(line.line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetAdvances(run, CFRange(), &advances)
            CTRunGetStringIndices(run, CFRange(), &indices)
            for glyph in 0..<count where advances[glyph].width > 1 {
                glyphs.append((indices[glyph] + Int(line.base), left + positions[glyph].x + advances[glyph].width / 2))
            }
        }
        var boundaries: [Int] = []
        var offset = line.range.lowerBound
        while offset < line.caretEnd {
            boundaries.append(offset)
            offset = NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset))
        }
        boundaries.append(line.caretEnd)
        var checked = 0
        for (i, from) in boundaries.enumerated() {
            for to in boundaries[(i + 1)...] where to < line.caretEnd {
                let selection = TextPosition(block: block, offset: from)..<TextPosition(block: block, offset: to)
                let rects = snapshot.selectionRects(for: selection, minY: top + 1, maxY: top + line.height - 1)
                for glyph in glyphs {
                    let isSelected = glyph.index >= from && glyph.index < to
                    let isLit = rects.contains { $0.minX < glyph.center && glyph.center < $0.maxX }
                    if isSelected != isLit {
                        XCTFail("selecting \(from)..<\(to) of \(text.substring(with: NSRange(location: line.range.lowerBound, length: line.range.count)).debugDescription): glyph of \(glyph.index) \(isSelected ? "not lit" : "lit")",
                                file: file, line: lineNumber)
                        return
                    }
                }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 10, file: file, line: lineNumber)
    }

    func testHighlightsInMixedDirectionLinesCoverOnlySelectedGlyphs() throws {
        // chokidar's README, and shaghlaty's change log.
        let chokidar = try snapshot("like Urdu as (چوکیدار) which is used")
        assertHighlightCoversExactlyTheSelection(chokidar, block: 0, line: 0)
        let shaghlaty = try snapshot("The tab reads «مؤكدة» / Confirmed and the chip «مؤكد» / Confirmed.", width: 1200)
        assertHighlightCoversExactlyTheSelection(shaghlaty, block: 0, line: 0)
        let arabic = try snapshot("مرحبا بالعالم (hello world) 123 نص.")
        assertHighlightCoversExactlyTheSelection(arabic, block: 0, line: 0)
        let picker = try snapshot("The language picker names Arabic «العربية (العراق)» in either language.", width: 1200)
        assertHighlightCoversExactlyTheSelection(picker, block: 0, line: 0)
    }

    func testASelectionPastARightToLeftLineReachesItsLeftEdge() throws {
        let snapshot = try snapshot("مرحبا بالعالم\n\nnext")
        let line = try XCTUnwrap(snapshot.layouts[0].lines.first)
        let selection = TextPosition(block: 0, offset: 2)..<TextPosition(block: 1, offset: 2)
        let rects = snapshot.selectionRects(for: selection, minY: 0, maxY: snapshot.blockTops[0] + line.height)
        let first = try XCTUnwrap(rects.first)
        XCTAssertEqual(first.minX, snapshot.columnX, accuracy: 0.5)
        XCTAssertEqual(first.maxX, snapshot.columnX + line.x + line.caretX(2), accuracy: 0.5)
    }

    func testFirstStrongCharacterDecides() {
        func direction(_ text: String) -> Bool {
            TextDirection.scan(text as CFString, 0..<(text as NSString).length).isRightToLeft
        }
        XCTAssertTrue(direction("123 مرحبا hello"))
        XCTAssertFalse(direction("123 hello مرحبا"))
        XCTAssertFalse(direction("\u{2067}مرحبا\u{2069} hello"), "isolates are skipped")
        XCTAssertTrue(direction("\u{200F}hello"), "a right-to-left mark is strong")
        XCTAssertFalse(direction("(1) — 2."), "no strong character")
        XCTAssertTrue(direction("𞤀𞤁 Adlam"))
        XCTAssertTrue(direction("שלום"))
    }
}
