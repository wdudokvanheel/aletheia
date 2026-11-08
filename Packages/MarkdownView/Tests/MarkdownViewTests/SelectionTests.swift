import CoreText
import XCTest
@testable import MarkdownView

final class SelectionTests: XCTestCase {
    private func snapshot(_ source: String, width: CGFloat = 600) throws -> MarkdownSnapshot {
        MarkdownSnapshot.layOut(try MarkdownDocument.parse(source), width: width)
    }

    private func position(_ block: Int, _ offset: Int) -> TextPosition {
        TextPosition(block: block, offset: offset)
    }

    /// A view point at the caret of `offset` in `block`, plus `dx`, at mid-line.
    private func point(_ snapshot: MarkdownSnapshot, _ block: Int, _ offset: Int, dx: CGFloat = 0) -> CGPoint {
        let layout = snapshot.layouts[block]
        let line = layout.lines[layout.lineIndex(containing: offset, upstream: false)]
        let x = CTLineGetOffsetForStringIndex(line.line, offset, nil)
        return CGPoint(x: snapshot.columnX + line.x + x + dx, y: snapshot.blockTops[block] + line.top + line.height / 2)
    }

    private func bottom(_ snapshot: MarkdownSnapshot, _ block: Int) -> CGFloat {
        snapshot.blockTops[block] + snapshot.layouts[block].height
    }

    // MARK: Positions and hit-testing

    func testPositionsOrderInDocumentOrder() {
        XCTAssertLessThan(position(0, 9), position(1, 0))
        XCTAssertLessThan(position(2, 3), position(2, 4))
        XCTAssertEqual([position(1, 2), position(0, 5), position(1, 0)].sorted(), [position(0, 5), position(1, 0), position(1, 2)])
    }

    func testHitTestingInsideLines() throws {
        let snapshot = try snapshot("Hello world\n\n```\nlet x = 1\n```")
        XCTAssertEqual(snapshot.position(at: point(snapshot, 0, 6, dx: 1)), position(0, 6))
        XCTAssertEqual(snapshot.position(at: point(snapshot, 0, 6, dx: -1)), position(0, 6))
        XCTAssertEqual(snapshot.position(at: point(snapshot, 1, 4, dx: 1)), position(1, 4), "code text is inset")
        var left = point(snapshot, 0, 3)
        left.x = 0
        XCTAssertEqual(snapshot.position(at: left), position(0, 0))
        var right = point(snapshot, 0, 3)
        right.x = 10_000
        XCTAssertEqual(snapshot.position(at: right), position(0, 11))
        // In the code block's padding, above its first line.
        var padding = point(snapshot, 1, 4, dx: 1)
        padding.y = snapshot.blockTops[1] + 2
        XCTAssertEqual(snapshot.position(at: padding), position(1, 4))
    }

    func testHitTestingWrappedLinesAndHardBreaks() throws {
        let snapshot = try snapshot(String(repeating: "wrapping words ", count: 30) + "\n\n- one\n- two", width: 300)
        let paragraph = snapshot.layouts[0]
        XCTAssertGreaterThan(paragraph.lineCount, 2)
        let second = paragraph.lines[1]
        let y = snapshot.blockTops[0] + second.top + second.height / 2
        XCTAssertEqual(snapshot.position(at: CGPoint(x: 0, y: y)), position(0, second.range.lowerBound))
        XCTAssertEqual(snapshot.position(at: CGPoint(x: 10_000, y: y)), position(0, second.range.upperBound))
        // Right of "one", the caret stays before the newline that ends the item.
        XCTAssertEqual(snapshot.document.blocks[1].text, "one\ntwo")
        var right = point(snapshot, 1, 0)
        right.x = 10_000
        XCTAssertEqual(snapshot.position(at: right), position(1, 3))
    }

    func testHitTestingGapsResolveToTheNearerBlockEdge() throws {
        let snapshot = try snapshot("First paragraph.\n\nSecond paragraph.")
        let gapTop = bottom(snapshot, 0)
        let gapBottom = snapshot.blockTops[1]
        XCTAssertGreaterThan(gapBottom - gapTop, 4)
        XCTAssertEqual(snapshot.position(at: CGPoint(x: 100, y: gapTop + 1)), position(0, 16))
        XCTAssertEqual(snapshot.position(at: CGPoint(x: 100, y: gapBottom - 1)), position(1, 0))
    }

    func testHitTestingOutsideTheDocumentClamps() throws {
        let snapshot = try snapshot("First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(snapshot.position(at: CGPoint(x: 300, y: -100)), position(0, 0))
        XCTAssertEqual(snapshot.position(at: CGPoint(x: -50, y: 2)), position(0, 0))
        XCTAssertEqual(snapshot.position(at: CGPoint(x: 0, y: snapshot.totalHeight + 100)), position(1, 17))
        XCTAssertNil(try self.snapshot("").position(at: .zero))
        XCTAssertNil(try self.snapshot("<div>only html</div>").position(at: CGPoint(x: 10, y: 10)))
    }

    func testHitTestingSkipsBlocksWithoutText() throws {
        let snapshot = try snapshot("Para one.\n\n---\n\n<div>x</div>\n\nPara two.")
        XCTAssertEqual(snapshot.document.blocks.map(\.kind), [.paragraph, .thematicBreak, .htmlBlock, .paragraph])
        XCTAssertEqual(snapshot.position(at: CGPoint(x: 100, y: bottom(snapshot, 0) + 1)), position(0, 9))
        XCTAssertEqual(snapshot.position(at: CGPoint(x: 100, y: snapshot.blockTops[3] - 1)), position(3, 0))
        // Inside the rule's margins, nearer the paragraph below.
        XCTAssertEqual(snapshot.position(at: CGPoint(x: 100, y: snapshot.blockTops[2] + 1)), position(3, 0))
        XCTAssertEqual(snapshot.fullRange, position(0, 0)..<position(3, 9))
    }

    // MARK: Words and paragraphs

    private func word(_ source: String, at offset: Int, forward: Bool = false) throws -> String {
        let snapshot = try snapshot(source)
        return snapshot.text(in: snapshot.unitRange(at: position(0, offset), granularity: .word, forward: forward))
    }

    func testWordRangesFollowSystemBoundaries() throws {
        let text = "Hello, world! foo-bar café's end."
        XCTAssertEqual(try word(text, at: 0), "Hello")
        XCTAssertEqual(try word(text, at: 8), "world")
        XCTAssertEqual(try word(text, at: 5), ",")
        XCTAssertEqual(try word(text, at: 6), " ")
        XCTAssertEqual(try word(text, at: 15), "foo")
        XCTAssertEqual(try word(text, at: 17), "-")
        XCTAssertEqual(try word(text, at: 24), "café's")
        XCTAssertEqual(try word(text, at: 33), ".", "the end of the block takes the last character")
        XCTAssertEqual(try word(text, at: 7, forward: true), " ", "forward takes the character before the caret")
        XCTAssertEqual(try word(text, at: 12, forward: true), "world")
    }

    func testWordRangesForCJKAndEmoji() throws {
        XCTAssertEqual(try word("日本語のテキストを選択します。", at: 5), "テキスト")
        let emoji = "Emoji 👍🏽 and 👨‍👩‍👧 family"
        XCTAssertEqual(try word(emoji, at: 7), "👍🏽")
        XCTAssertEqual(try word(emoji, at: 17), "👨‍👩‍👧")
        XCTAssertEqual(try word(emoji, at: 24), "family")
    }

    func testParagraphRanges() throws {
        let snapshot = try snapshot("Plain paragraph text.\n\n- one\n- two\n  - nested\n\n| a | b |\n| - | - |\n| c | d |")
        func paragraph(_ block: Int, _ offset: Int) -> String {
            snapshot.text(in: snapshot.unitRange(at: position(block, offset), granularity: .paragraph))
        }
        XCTAssertEqual(paragraph(0, 3), "Plain paragraph text.")
        XCTAssertEqual(paragraph(0, 21), "Plain paragraph text.")
        XCTAssertEqual(paragraph(1, 5), "two")
        XCTAssertEqual(paragraph(1, 3), "one", "before the newline")
        XCTAssertEqual(paragraph(1, 4), "two", "after the newline")
        XCTAssertEqual(paragraph(2, 4), "c", "a table cell")
        let character = snapshot.unitRange(at: position(0, 3), granularity: .character)
        XCTAssertTrue(character.isEmpty)
    }

    // MARK: Copy

    func testCopyJoinsBlocksWithoutListMarkersOrTaskBoxes() throws {
        let snapshot = try snapshot("""
        # Title

        Some *emphasis* text.

        - [ ] open task
        - [x] done task
        - plain item

        1. first
        2. second

        ---

        <div>dropped</div>

        ```
        code line
        ```
        """)
        let range = try XCTUnwrap(snapshot.fullRange)
        let text = snapshot.text(in: range)
        XCTAssertEqual(text, "Title\nSome emphasis text.\nopen task\ndone task\nplain item\nfirst\nsecond\ncode line")
        XCTAssertFalse(text.contains("[ ]") || text.contains("[x]") || text.contains("- ") || text.contains("1."))
        XCTAssertEqual(snapshot.text(in: position(1, 5)..<position(2, 4)), "emphasis text.\nopen")
    }

    func testCopyTableRowsUseTabsAndNewlines() throws {
        let snapshot = try snapshot("Before.\n\n| Name | Value |\n| ---- | ----: |\n| pi | 3.14 |\n| e | 2.71 |\n\nAfter.")
        let range = try XCTUnwrap(snapshot.fullRange)
        XCTAssertEqual(snapshot.text(in: range), "Before.\nName\tValue\npi\t3.14\ne\t2.71\nAfter.")
        XCTAssertEqual(snapshot.text(in: position(1, 11)..<position(1, 21)), "pi\t3.14\ne\t")
    }

    func testCopyOfASeparatorOnlySelectionIsANewline() throws {
        let snapshot = try snapshot("One.\n\nTwo.")
        XCTAssertEqual(snapshot.text(in: position(0, 4)..<position(1, 0)), "\n")
        XCTAssertEqual(snapshot.text(in: position(0, 1)..<position(0, 3)), "ne")
    }

    // MARK: Rectangles

    func testSelectionRectsPerLineExtendWhereTheSelectionContinues() throws {
        let snapshot = try snapshot(String(repeating: "wrapping words ", count: 30) + "\n\nNext block.", width: 300)
        let layout = snapshot.layouts[0]
        XCTAssertGreaterThan(layout.lineCount, 3)
        let lines = layout.lines
        let end = lines[2].range.lowerBound + 4
        let rects = snapshot.selectionRects(for: position(0, 3)..<position(0, end), minY: 0, maxY: snapshot.totalHeight)
        XCTAssertEqual(rects.count, 3)
        let left = snapshot.columnX
        let right = snapshot.columnX + snapshot.columnWidth
        XCTAssertEqual(rects[0].minX, left + CTLineGetOffsetForStringIndex(lines[0].line, 3, nil), accuracy: 0.01)
        XCTAssertEqual(rects[0].maxX, right, accuracy: 0.01)
        XCTAssertEqual(rects[1].minX, left, accuracy: 0.01)
        XCTAssertEqual(rects[1].maxX, right, accuracy: 0.01)
        XCTAssertEqual(rects[2].minX, left, accuracy: 0.01)
        XCTAssertEqual(rects[2].maxX, left + CTLineGetOffsetForStringIndex(lines[2].line, end, nil), accuracy: 0.01)
        for (rect, line) in zip(rects, lines) {
            XCTAssertEqual(rect.minY, snapshot.blockTops[0] + line.top, accuracy: 0.01)
            XCTAssertEqual(rect.height, line.height, accuracy: 0.01)
        }
        // Only the visible part is computed.
        let visible = snapshot.selectionRects(for: position(0, 3)..<position(0, end),
                                              minY: snapshot.blockTops[0] + lines[1].top + 1,
                                              maxY: snapshot.blockTops[0] + lines[1].top + 2)
        XCTAssertEqual(visible.count, 1)
        // Into the next block: the last line reaches the right edge.
        let across = snapshot.selectionRects(for: position(0, lines.last!.range.lowerBound)..<position(1, 4),
                                             minY: 0, maxY: snapshot.totalHeight)
        XCTAssertEqual(across.count, 2)
        XCTAssertEqual(across[0].maxX, right, accuracy: 0.01)
        XCTAssertEqual(across[1].minY, snapshot.blockTops[1], accuracy: 0.01)
    }

    func testSelectionRectsInsideCodeBlocksStayInsideThePadding() throws {
        let snapshot = try snapshot("```\nfirst line\nsecond line\n```")
        let rects = snapshot.selectionRects(for: position(0, 0)..<position(0, 14), minY: 0, maxY: snapshot.totalHeight)
        let padding = Typography.standard.codeBlockPadding
        XCTAssertEqual(rects.count, 2)
        XCTAssertEqual(rects[0].minX, snapshot.columnX + padding, accuracy: 0.01)
        XCTAssertEqual(rects[0].maxX, snapshot.columnX + snapshot.columnWidth - padding, accuracy: 0.01)
    }

    func testSelectionRectsInARightToLeftLineCoverTheSelectedGlyphs() throws {
        let snapshot = try snapshot("שלום עולם")
        let line = try XCTUnwrap(snapshot.layouts[0].lines.first)
        let rects = snapshot.selectionRects(for: position(0, 0)..<position(0, 4), minY: 0, maxY: snapshot.totalHeight)
        XCTAssertEqual(rects.count, 1)
        // The first word in logical order is drawn on the right.
        let start = CTLineGetOffsetForStringIndex(line.line, 0, nil)
        let end = CTLineGetOffsetForStringIndex(line.line, 4, nil)
        XCTAssertGreaterThan(start, end)
        XCTAssertEqual(rects[0].minX, snapshot.columnX + end, accuracy: 0.01)
        XCTAssertEqual(rects[0].maxX, snapshot.columnX + start, accuracy: 0.01)
    }

    func testDirtyRectsCoverOnlyTheLinesBetweenMovedEnds() throws {
        let snapshot = try snapshot(String(repeating: "wrapping words ", count: 30), width: 300)
        let lines = snapshot.layouts[0].lines
        let old = position(0, 2)..<position(0, lines[1].range.lowerBound + 3)
        let new = position(0, 2)..<position(0, lines[1].range.lowerBound + 6)
        let dirty = snapshot.selectionDirtyRects(from: old, to: new)
        XCTAssertEqual(dirty.count, 1)
        XCTAssertEqual(dirty[0].minY, snapshot.blockTops[0] + lines[1].top, accuracy: 0.01)
        XCTAssertEqual(dirty[0].height, lines[1].height, accuracy: 0.01)
        // At a soft wrap, the line the old end finished is included.
        let atWrap = position(0, 2)..<position(0, lines[1].range.lowerBound)
        let band = snapshot.selectionDirtyRects(from: atWrap, to: new)
        XCTAssertEqual(band[0].minY, snapshot.blockTops[0] + lines[0].top, accuracy: 0.01)
        XCTAssertTrue(snapshot.selectionDirtyRects(from: new, to: new).isEmpty)
    }

    // MARK: Across updates

    private let original = "Intro.\n\nThe selected words are here.\n\nTail."
    private let selected = TextPosition(block: 1, offset: 4)..<TextPosition(block: 1, offset: 18)

    func testSelectionSurvivesABlockAboveChangingHeight() throws {
        let old = try snapshot(original)
        XCTAssertEqual(old.text(in: selected), "selected words")
        let taller = try snapshot("Intro, " + String(repeating: "now long enough to wrap, ", count: 20)
                                  + "\n\nThe selected words are here.\n\nTail.")
        XCTAssertGreaterThan(taller.layouts[0].height, old.layouts[0].height)
        let mapped = try XCTUnwrap(taller.mapRange(selected, from: old))
        XCTAssertEqual(mapped, selected)
        XCTAssertEqual(taller.text(in: mapped), "selected words")
        let inserted = try snapshot("A new first block.\n\n" + original)
        let moved = try XCTUnwrap(inserted.mapRange(selected, from: old))
        XCTAssertEqual(moved, position(2, 4)..<position(2, 18))
        XCTAssertEqual(inserted.text(in: moved), "selected words")
        let removed = try snapshot("The selected words are here.\n\nTail.")
        XCTAssertEqual(removed.text(in: try XCTUnwrap(removed.mapRange(selected, from: old))), "selected words")
    }

    func testSelectionInAnEditedBlockFollowsTheTextOrClamps() throws {
        let old = try snapshot(original)
        func mapped(_ source: String) throws -> String? {
            let new = try snapshot(source)
            return new.mapRange(selected, from: old).map { new.text(in: $0) }
        }
        XCTAssertEqual(try mapped("Intro.\n\nThe selected words are here, edited.\n\nTail."), "selected words")
        XCTAssertEqual(try mapped("Intro.\n\nSo The selected words are here.\n\nTail."), "selected words")
        XCTAssertEqual(try mapped("Intro.\n\nThe selected few words are here.\n\nTail."), "selected few words")
        XCTAssertEqual(try mapped("Intro.\n\nThe chosen words are here.\n\nTail."), "chosen words")
        // An end inside the replaced text is clamped to its end.
        XCTAssertEqual(SnapshotOffsets.map(6, "The selected words", "The chosen words"), 6)
        XCTAssertEqual(SnapshotOffsets.map(10, "The selected words", "The ok words"), 6)
        XCTAssertEqual(SnapshotOffsets.map(13, "The selected words", "The ok words"), 7)
        XCTAssertEqual(SnapshotOffsets.map(3, "abXYZcd", "ab👍cd"), 2, "never inside a surrogate pair")
    }

    func testSelectionClearsWhenItsBlockVanishes() throws {
        let old = try snapshot(original)
        XCTAssertNil(try snapshot("Intro.\n\nTail.").mapRange(selected, from: old))
        XCTAssertNil(try snapshot("Intro.").mapRange(selected, from: old))
        XCTAssertNil(try snapshot("").mapRange(selected, from: old))
        // Another document with a block at the same source offset.
        XCTAssertNil(try snapshot("Other.\n\nCompletely different content now.\n\nEnd.").mapRange(selected, from: old))
        XCTAssertNil(SnapshotOffsets.map(3, "The selected words", "Nothing alike here"))
    }
}

private enum SnapshotOffsets {
    static func map(_ offset: Int, _ old: String, _ new: String) -> Int? {
        MarkdownSnapshot.mapOffset(offset, from: old, to: new)
    }
}
