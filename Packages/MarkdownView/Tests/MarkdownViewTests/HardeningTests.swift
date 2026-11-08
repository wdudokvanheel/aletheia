import CoreText
import XCTest
@testable import MarkdownView

/// Regressions found by the Phase 9 robustness sweep.
final class HardeningTests: XCTestCase {
    // MARK: U+FEFF (F1)

    /// Blocks whose display text starts with U+FEFF, which Core Foundation
    /// drops as a byte order mark when it converts UTF-8: from the fuzz
    /// cases and the two corpus files that start with a line break and one.
    private let byteOrderMarkFixtures = [
        "a\n\n\u{FEFF}b",
        "a\n\n\u{FEFF}bc **d** [link](https://example.com) `code` e",
        "\n\u{FEFF}# umockstring requirements\n\n# Overview\n\numockstring is a module that provides the functionality of "
            + "cloning a string (allocating memory and copying the chars).\n\n# Exposed API\n\n```c\n"
            + "extern char* umockstring_clone(const char* source);\n```\n",
        "\n\u{FEFF}# umocktypes_bool requirements\n\n# Overview\n\numocktypes_c is a module that exposes out of the box "
            + "functionality for bool and \\_Bool for umock_c.\n\n# Exposed API\n\n```c\n"
            + "    extern int umocktypes_bool_register_types(void);\n```\n",
        "# \u{FEFF}Heading",
        "- \u{FEFF}item one\n- \u{FEFF}item two",
        "> \u{FEFF}quoted",
        "```\n\u{FEFF}code line\nsecond\n```",
        "| \u{FEFF}x | y |\n|---|---|\n| \u{FEFF}z | w |\n| \u{FEFF}\u{FEFF} | \u{FEFF} |",
        "\u{FEFF}" + String(repeating: "long words wrap here ", count: 300),
        "\u{FEFF}\u{FEFF}\u{FEFF}",
    ]

    func testTextStartingWithAByteOrderMarkKeepsItsLength() throws {
        for markdown in byteOrderMarkFixtures {
            let document = try MarkdownDocument.parse(markdown)
            for block in document.blocks {
                let length = block.text.utf16.count
                guard length > 0 else { continue }
                let text = try XCTUnwrap(BlockLayout.makeText(block))
                XCTAssertEqual(CFStringGetLength(text), length, markdown.debugDescription)
            }
            for width: CGFloat in [120, 700] {
                let snapshot = MarkdownSnapshot.layOut(document, width: width)
                assertLinesCoverText(snapshot, markdown)
            }
        }
    }

    func testTheCorpusByteOrderMarkParagraphIsOneLine() throws {
        let snapshot = MarkdownSnapshot.layOut(try MarkdownDocument.parse(byteOrderMarkFixtures[2]), width: 900)
        let block = try XCTUnwrap(snapshot.document.blocks.first)
        XCTAssertEqual(block.text, "\u{FEFF}# umockstring requirements")
        XCTAssertEqual(snapshot.layouts[0].lines.map(\.range), [0..<27])
    }

    /// Every display unit but separators is on a line or in a cell, and no
    /// line reaches past the text.
    private func assertLinesCoverText(_ snapshot: MarkdownSnapshot, _ context: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        for (index, layout) in snapshot.layouts.enumerated() {
            let text = Array(snapshot.document.blocks[index].text.utf16)
            var covered = [Bool](repeating: false, count: text.count)
            for textLine in layout.lines {
                XCTAssertLessThanOrEqual(textLine.range.upperBound, text.count, context, file: file, line: line)
                for offset in textLine.range where offset < text.count { covered[offset] = true }
            }
            for table in layout.tables {
                for row in table.rows.indices {
                    for column in 0..<table.structure.columnCount {
                        let start = table.textOffset(row: row, column: column)
                        for cellLine in table.rows[row].lines(ofCell: column) {
                            for offset in cellLine.range where start + offset < text.count { covered[start + offset] = true }
                        }
                    }
                }
            }
            for offset in text.indices where !covered[offset] && text[offset] != 0x0A && text[offset] != 0x09 {
                XCTFail("block \(index) offset \(offset) is on no line: \(context.debugDescription)", file: file, line: line)
                break
            }
        }
    }

    // MARK: Word selection in a cell (F2)

    func testWordSelectionInACellHoldingAParagraphSeparator() throws {
        for scalar in ["\u{2029}", "\u{2028}", "\u{85}"] {
            let snapshot = MarkdownSnapshot.layOut(try MarkdownDocument.parse("| \(scalar) |\n|---|\n| a\(scalar)b |\n"),
                                                   width: 700)
            for offset in 0...snapshot.layouts[0].textLength {
                for forward in [false, true] {
                    let range = snapshot.unitRange(at: TextPosition(block: 0, offset: offset), granularity: .word,
                                                   forward: forward)
                    XCTAssertLessThanOrEqual(range.upperBound.offset, snapshot.layouts[0].textLength)
                    XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound)
                }
            }
        }
    }

    func testWordSelectionJustPastACellStaysInTheCell() throws {
        let snapshot = MarkdownSnapshot.layOut(try MarkdownDocument.parse("| alpha | beta |\n|---|---|\n"), width: 700)
        // Offset 5 is the end of "alpha", on the tab before "beta".
        let range = snapshot.unitRange(at: TextPosition(block: 0, offset: 5), granularity: .word)
        XCTAssertEqual(snapshot.text(in: range), "alpha")
    }

    // MARK: Inline code next to emoji (F6)

    func testEmojiTouchingInlineCodeKeepsItsGlyph() throws {
        for markdown in ["x `a👍` y", "x 👍`code` y", "x `👩🏽‍💻` y", "x 🇳🇱`c` y", "| `a👍` | 👍`b` |\n|---|---|\n"] {
            let snapshot = MarkdownSnapshot.layOut(try MarkdownDocument.parse(markdown), width: 700)
            let layout = snapshot.layouts[0]
            let lines = layout.lines + layout.tables.flatMap { $0.rows.flatMap(\.lines) }
            for line in lines {
                for run in CTLineGetGlyphRuns(line.line) as? [CTRun] ?? [] {
                    let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String].map { $0 as! CTFont }
                    let name = font.map { CTFontCopyPostScriptName($0) as String } ?? ""
                    XCTAssertFalse(name.contains("LastResort"), markdown)
                }
            }
        }
    }

    func testInlineCodePaddingBesideAnEmojiIsOnePadding() throws {
        let padding = Typography.standard.inlineCodePadding
        let plain = MarkdownSnapshot.layOut(try MarkdownDocument.parse("x 👍"), width: 700).layouts[0].lines[0].line
        let touching = MarkdownSnapshot.layOut(try MarkdownDocument.parse("x 👍`code` y"), width: 700).layouts[0].lines[0].line
        let emoji = CTLineGetOffsetForStringIndex(plain, 4, nil) - CTLineGetOffsetForStringIndex(plain, 2, nil)
        // The emoji spans offsets 2 to 4; the code's glyphs start one padding after it.
        let code = try XCTUnwrap((CTLineGetGlyphRuns(touching) as? [CTRun])?.first { CTRunGetStringRange($0).location == 4 })
        var origin = CGPoint.zero
        CTRunGetPositions(code, CFRange(location: 0, length: 1), &origin)
        XCTAssertEqual(origin.x - CTLineGetOffsetForStringIndex(touching, 2, nil), emoji + padding, accuracy: 0.5)
    }

    // MARK: Setext headings (F8)

    func testASetextHeadingEndsAtItsUnderline() throws {
        let markdown = "Title\n-----\nNext line.\n"
        let blocks = try MarkdownDocument.parse(markdown).blocks
        XCTAssertEqual(blocks.map(\.kind), [.heading(level: 2), .paragraph])
        XCTAssertEqual(blocks[0].sourceRange, 0..<11)
        XCTAssertEqual(blocks[0].sourceText, "Title\n-----")
        XCTAssertEqual(blocks[1].sourceRange, 12..<22)
        for markdown in ["Title\n=====\n- item\n- two\n", "A\nB\n===\n  indented para\n", "T\n-\n<div>\n", "T\r\n=\r\nnext\r\n",
                         "T\n===\n| a |\n|---|\n", "Title\n=====\n\nNext\n"] {
            let blocks = try MarkdownDocument.parse(markdown).blocks
            let source = markdown as NSString
            for index in blocks.indices {
                let range = blocks[index].sourceRange
                XCTAssertEqual(source.substring(with: NSRange(location: range.lowerBound, length: range.count)),
                               blocks[index].sourceText, markdown.debugDescription)
                if index > 0 {
                    XCTAssertGreaterThanOrEqual(range.lowerBound, blocks[index - 1].sourceRange.upperBound,
                                                markdown.debugDescription)
                }
            }
        }
    }

    func testTypingBelowASetextHeadingKeepsScrollAndSelection() throws {
        let items = (1...60).map { "- item \($0) with some words" }
        var edited = items
        edited[40] += " typed"
        let base = "Intro para.\n\nTitle\n=====\n" + items.joined(separator: "\n") + "\n"
        let text = "Intro para.\n\nTitle\n=====\n" + edited.joined(separator: "\n") + "\n"
        let old = MarkdownSnapshot.layOut(try MarkdownDocument.parse(base), width: 700)
        let new = try MarkdownSnapshot.updating(old, to: text, width: 700).snapshot
        let list = try XCTUnwrap(old.document.blocks.firstIndex { $0.kind == .list })
        let y = old.blockTops[list] + 300
        let update = try XCTUnwrap(new.update(from: old))
        XCTAssertEqual(new.anchoredY(y, from: old, through: update), new.blockTops[list] + 300, accuracy: 0.01)
        let selection = TextPosition(block: list, offset: 2)..<TextPosition(block: list, offset: 6)
        let mapped = try XCTUnwrap(new.mapRange(selection, from: old))
        XCTAssertEqual(new.text(in: mapped), old.text(in: selection))
    }

    // MARK: Anchoring near the top (F11)

    func testAnchoringInTheTopInsetNeverGoesAboveTheTop() throws {
        let old = MarkdownSnapshot.layOut(try MarkdownDocument.parse("# Title\n\ntext"), width: 700)
        let new = try MarkdownSnapshot.updating(old, to: "Title\n\ntext", width: 700).snapshot
        let update = try XCTUnwrap(new.update(from: old))
        for y: CGFloat in [1, 5, 10, old.blockTops[0] - 1] {
            XCTAssertGreaterThanOrEqual(new.anchoredY(y, from: old, through: update), 0)
        }
    }

    // MARK: Spaces (F12)

    func testRunsOfSpacesCollapseOutsideCode() throws {
        let cases: [(String, String)] = [
            ("One.  Two   three", "One. Two three"),
            ("a\tb", "a b"),
            ("- item  with   spaces", "item with spaces"),
            ("| a     b |\n|---|\n", "a b"),
            ("**bold**  *em*   `code  kept`  end", "bold em code  kept end"),
            ("x &#32; y", "x y"),
            ("line one  \nline two", "line one\nline two"),
        ]
        for (markdown, expected) in cases {
            let block = try XCTUnwrap(MarkdownDocument.parse(markdown).blocks.first)
            XCTAssertEqual(block.text, expected, markdown.debugDescription)
            XCTAssertEqual(block.sourceMap.displayLength, expected.utf16.count)
        }
        let code = try XCTUnwrap(MarkdownDocument.parse("```\na   b\n```").blocks.first)
        XCTAssertEqual(code.text, "a   b")
    }

    func testCollapsedSpacesMapToTheirSource() throws {
        let markdown = "One.  Two   three"
        let block = try XCTUnwrap(MarkdownDocument.parse(markdown).blocks.first)
        XCTAssertEqual(block.text, "One. Two three")
        XCTAssertEqual(block.sourceOffset(forDisplayOffset: 5), 6, "Two")
        XCTAssertEqual(block.sourceOffset(forDisplayOffset: 9), 12, "three")
        XCTAssertEqual(block.displayOffset(forSourceOffset: 12), 9)
        let source = markdown as NSString
        for (display, word) in [(0, "One."), (5, "Two"), (9, "three")] {
            let start = block.sourceOffset(forDisplayOffset: display)
            XCTAssertEqual(source.substring(with: NSRange(location: start, length: word.utf16.count)), word)
        }
    }

    // MARK: NUL (F13)

    func testNULKeepsSourceRangesInPlace() throws {
        let markdown = "x\u{0}ab **c**\n\nnext"
        let blocks = try MarkdownDocument.parse(markdown).blocks
        XCTAssertEqual(blocks.map(\.sourceRange), [0..<10, 12..<16])
        XCTAssertEqual(blocks[0].sourceText, "x\u{FFFD}ab **c**")
        XCTAssertEqual(blocks[0].text, "x\u{FFFD}ab c")
        let emoji = try MarkdownDocument.parse("x\u{0}🧑\n\nnext").blocks
        XCTAssertEqual(emoji.map(\.sourceRange), [0..<4, 6..<10])
    }
}
