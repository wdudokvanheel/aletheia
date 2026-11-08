import CoreText
import XCTest
@testable import MarkdownView

/// Lists, task items, quotes, code blocks, rules, and raw HTML laid out as
/// structure: indents, markers, bars, boxes, and collapsed margins.
final class BlockStructureTests: XCTestCase {
    private let typography = Typography.standard
    private var line: CGFloat { typography.lineHeight(.body) }
    private var codeLine: CGFloat { typography.lineHeight(.code) }

    private func snapshot(_ source: String, width: CGFloat = 600) throws -> MarkdownSnapshot {
        MarkdownSnapshot.layOut(try MarkdownDocument.parse(source), width: width)
    }

    private func layout(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> BlockLayout {
        let snapshot = try snapshot(source)
        XCTAssertEqual(snapshot.layouts.count, 1, "one top-level block", file: file, line: line)
        assertLinesCoverText(snapshot, file: file, line: line)
        return snapshot.layouts[0]
    }

    private func position(_ block: Int, _ offset: Int) -> TextPosition {
        TextPosition(block: block, offset: offset)
    }

    /// Every block's lines cover its display text in order, without gaps or
    /// overlaps, and go down the page.
    private func assertLinesCoverText(_ snapshot: MarkdownSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        for (index, layout) in snapshot.layouts.enumerated() where !layout.isDropped {
            var offset = 0
            var bottom: CGFloat = 0
            for laidOut in layout.lines {
                XCTAssertEqual(laidOut.range.lowerBound, offset, "block \(index)", file: file, line: line)
                XCTAssertGreaterThanOrEqual(laidOut.top, bottom - 0.001, "block \(index)", file: file, line: line)
                offset = laidOut.range.upperBound
                bottom = laidOut.top + laidOut.height
            }
            XCTAssertEqual(offset, layout.textLength, "block \(index)", file: file, line: line)
        }
    }

    private func markerKinds(_ layout: BlockLayout) -> [String] {
        layout.markers.map {
            switch $0.kind {
            case .disc: "disc"
            case .circle: "circle"
            case .square: "square"
            case .number: "number"
            case .task(let checked): checked ? "checked" : "unchecked"
            }
        }
    }

    // MARK: Lists

    func testBulletsChangeByDepthAndEachLevelIndents() throws {
        let layout = try layout("- one\n  - two\n    - three\n      - four")
        XCTAssertEqual(markerKinds(layout), ["disc", "circle", "square", "square"])
        XCTAssertEqual(layout.lines.map(\.x), [40, 80, 120, 160])
        XCTAssertEqual(layout.height, 4 * line, accuracy: 0.001, "a tight list has no gaps")
        XCTAssertEqual(layout.marginTop, 15)
        XCTAssertEqual(layout.marginBottom, 15)
        let xHeight = CTFontGetXHeight(typography.fonts[Int(TextRole.body.rawValue)])
        for (marker, laidOut) in zip(layout.markers, layout.lines) {
            // Beside the item's text, on its first line, centered on the x-height.
            XCTAssertEqual(marker.rect.maxX, laidOut.x - typography.listMarkerSpacing, accuracy: 1)
            XCTAssertEqual(marker.baseline, laidOut.baseline)
            XCTAssertEqual(marker.rect.midY, laidOut.baseline - xHeight / 2, accuracy: 1)
            XCTAssertEqual(marker.rect.width, typography.bulletSize)
        }
    }

    func testOrderedListsNumberFromTheirStartAndNest() throws {
        let source = "3. three\n4. four\n   1. one\n   2. two\n      - bullet\n5. five\n\nBreak.\n\n9) nine\n10) ten"
        let snapshot = try snapshot(source)
        assertLinesCoverText(snapshot)
        let blocks = snapshot.document.blocks
        XCTAssertEqual(blocks.map(\.kind), [.list, .paragraph, .list])
        XCTAssertEqual(blocks[0].text, "three\nfour\none\ntwo\nbullet\nfive", "markers are not text")
        XCTAssertEqual(blocks[0].containers.map(\.marker).filter { $0 != .none },
                       [.number(3), .number(4), .number(1), .number(2), .bullet(level: 2), .number(5)])
        XCTAssertEqual(blocks[2].containers.map(\.marker).filter { $0 != .none }, [.number(9), .number(10)])
        let layout = snapshot.layouts[0]
        XCTAssertEqual(markerKinds(layout), ["number", "number", "number", "number", "square", "number"])
        XCTAssertEqual(layout.lines.map(\.x), [40, 40, 80, 80, 120, 40])
        // Numbers end at the same place, so their periods line up.
        let ends = layout.markers.map(\.rect.maxX)
        XCTAssertEqual(ends[0], ends[1], accuracy: 0.001)
        XCTAssertEqual(ends[2], ends[3], accuracy: 0.001)
        XCTAssertEqual(ends[0], 40 - typography.listMarkerSpacing, accuracy: 0.001)
        let wide = snapshot.layouts[2].markers
        XCTAssertGreaterThan(wide[1].rect.width, wide[0].rect.width)
        XCTAssertEqual(wide[0].rect.maxX, wide[1].rect.maxX, accuracy: 0.001)
    }

    func testTightAndLooseListSpacing() throws {
        let tight = try layout("- a\n- b\n- c")
        XCTAssertEqual(tight.height, 3 * line, accuracy: 0.001)
        // A blank line between items makes every paragraph keep its margins.
        let loose = try layout("- a\n\n- b\n- c")
        XCTAssertEqual(loose.height, 3 * line + 2 * 15, accuracy: 0.001)
        XCTAssertEqual(loose.marginTop, 15)
        let paragraphs = try layout("- a\n\n  second paragraph\n- b")
        XCTAssertEqual(paragraphs.height, 3 * line + 2 * 15, accuracy: 0.001)
        // Nested lists have no margins; code blocks keep theirs in tight items.
        XCTAssertEqual(try layout("- a\n  - b\n- c").height, 3 * line, accuracy: 0.001)
        let code = try layout("- a\n  ```\n  code\n  ```\n- b")
        XCTAssertEqual(code.height, 2 * line + 2 * 13.5 + codeLine + 2 * typography.codeBlockPadding, accuracy: 0.001)
        XCTAssertEqual(code.codeBlocks.first?.rect.minX, 40, "the code box is indented with its item")
        XCTAssertEqual(code.lines[1].x, 40 + typography.codeBlockPadding)
    }

    func testEmptyItemsAndItemsOfOnlyHTMLKeepALineForTheirMarker() throws {
        let empty = try layout("- a\n-\n- c")
        XCTAssertEqual(empty.height, 3 * line, accuracy: 0.001)
        XCTAssertEqual(markerKinds(empty), ["disc", "disc", "disc"])
        XCTAssertEqual(empty.markers[1].baseline - empty.markers[0].baseline, line, accuracy: 0.001)
        let html = try layout("- <div>dropped</div>\n- b")
        XCTAssertEqual(html.height, 2 * line, accuracy: 0.001)
        XCTAssertEqual(html.lineCount, 1)
        XCTAssertEqual(html.markers.count, 2)
    }

    // MARK: Task items

    func testTaskItemsDrawBoxesInPlaceOfMarkersAndKeepThemOutOfTheText() throws {
        let snapshot = try snapshot("- [ ] open task\n- [x] done task\n- [X] also done\n- plain item\n\n1. [ ] numbered task")
        assertLinesCoverText(snapshot)
        let layout = snapshot.layouts[0]
        XCTAssertEqual(snapshot.document.blocks[0].text, "open task\ndone task\nalso done\nplain item")
        XCTAssertEqual(markerKinds(layout), ["unchecked", "checked", "checked", "disc"])
        XCTAssertEqual(markerKinds(snapshot.layouts[1]), ["unchecked"], "a task box replaces the number too")
        let box = layout.markers[0].rect
        XCTAssertEqual(box.width, typography.taskBoxSize)
        XCTAssertEqual(box.maxX, 40 - typography.listMarkerSpacing, accuracy: 1)
        XCTAssertGreaterThan(box.minX, 0, "inside the list indent")
        XCTAssertEqual(snapshot.text(in: try XCTUnwrap(snapshot.fullRange)),
                       "open task\ndone task\nalso done\nplain item\nnumbered task")
    }

    /// cmark-gfm 0.9.0 checks a task box when `[x]` appears anywhere on the
    /// item's first line. The parser is left as it is; this documents it.
    func testCmarkChecksATaskWhoseTextHoldsACheckedBox() throws {
        let block = try XCTUnwrap(MarkdownDocument.parse("- [ ] buy [x] item").blocks.first)
        XCTAssertEqual(block.text, "buy [x] item")
        XCTExpectFailure("cmark-gfm 0.9.0 tasklist.c searches the whole line for \"[x]\"") {
            XCTAssertEqual(block.containers.last?.marker, .task(checked: false))
        }
    }

    // MARK: Block quotes

    func testNestedQuotesDrawNestedBarsAndIndent() throws {
        let layout = try layout("> outer\n>\n> > inner\n>\n> after")
        let step = typography.quoteBarWidth + typography.quotePadding
        XCTAssertEqual(layout.lines.map(\.x), [step, 2 * step, step])
        XCTAssertEqual(layout.lines[0].maxX, 552 - typography.quoteRightMargin)
        XCTAssertEqual(layout.lines[1].maxX, 552 - 2 * typography.quoteRightMargin)
        XCTAssertEqual(layout.height, 3 * line + 2 * 15, accuracy: 0.001)
        let bars = layout.boxes.filter { $0.kind == .quoteBar }.map(\.rect).sorted { $0.minX < $1.minX }
        XCTAssertEqual(bars.count, 2)
        // The outer bar spans the whole quote; the inner one only its line.
        XCTAssertEqual(bars[0], CGRect(x: 0, y: 0, width: typography.quoteBarWidth, height: layout.height))
        XCTAssertEqual(bars[1], CGRect(x: step, y: layout.lines[1].top, width: typography.quoteBarWidth, height: line))
        XCTAssertEqual(layout.lines.map(\.color), Array(repeating: TextRole.quote.rawValue, count: 3), "muted text")
    }

    func testHeadingsAndCodeInAQuoteTakeItsColorAndMargins() throws {
        let snapshot = try snapshot("> # Title\n>\n> text\n>\n> ```\n> code\n> ```")
        let block = snapshot.document.blocks[0]
        XCTAssertEqual(block.styleRuns.map(\.styles), [.quoted, [], .quoted])
        let layout = snapshot.layouts[0]
        XCTAssertEqual(layout.lines.map(\.color), Array(repeating: TextRole.quote.rawValue, count: 3))
        XCTAssertEqual(Palette.standard.color(for: .code, styles: .quoted), Palette.standard.mutedText)
        // The heading's top margin collapses through the quote's.
        XCTAssertEqual(layout.marginTop, 30 * typography.headingTopMargin, accuracy: 0.001)
        XCTAssertEqual(layout.codeBlocks.first?.rect.minX, typography.quoteBarWidth + typography.quotePadding)
    }

    func testListsInQuotesAndQuotesInLists() throws {
        let quoted = try layout("> - one\n>   - two")
        let step = typography.quoteBarWidth + typography.quotePadding
        XCTAssertEqual(quoted.lines.map(\.x), [step + 40, step + 80])
        XCTAssertEqual(quoted.markers.map(\.color), [TextRole.quote.rawValue, TextRole.quote.rawValue],
                       "markers in a quote are muted")
        let listed = try layout("- item\n\n  > quoted")
        XCTAssertEqual(listed.lines.map(\.x), [40, 40 + step])
        XCTAssertEqual(listed.boxes.first { $0.kind == .quoteBar }?.rect.minX, 40)
    }

    func testDeepNestingKeepsAMinimumWidth() throws {
        let deep = (0..<20).map { String(repeating: "  ", count: $0) + "- level \($0)" }.joined(separator: "\n")
        let lists = try layout(deep)
        XCTAssertEqual(lists.lineCount, 20)
        for laidOut in lists.lines {
            XCTAssertLessThanOrEqual(laidOut.x, 552 - typography.minimumColumnWidth)
            XCTAssertGreaterThanOrEqual(laidOut.maxX - laidOut.x, typography.minimumColumnWidth)
        }
        let nested = (1...20).map { String(repeating: "> ", count: $0) + "depth \($0)\n" + String(repeating: "> ", count: $0) }
        let quotes = try layout(nested.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(quotes.lineCount, 20, "the narrowest wrap")
        XCTAssertEqual(quotes.boxes.filter { $0.kind == .quoteBar }.count, 20)
        XCTAssertTrue(quotes.lines.allSatisfy { $0.maxX - $0.x >= typography.minimumColumnWidth })
    }

    // MARK: Code blocks

    func testCodeLinesNeverWrapAndScrollHorizontally() throws {
        let long = (0..<60).map { "wide_code_token\($0)" }.joined(separator: " ")
        let layout = try layout("```\n\(long)   \nshort\n\n\tend\n```")
        XCTAssertEqual(layout.lineCount, 4, "one line per source line")
        XCTAssertEqual(layout.height, 4 * codeLine + 2 * typography.codeBlockPadding, accuracy: 0.001)
        let code = try XCTUnwrap(layout.codeBlocks.first)
        XCTAssertEqual(code.rect, CGRect(x: 0, y: 0, width: 552, height: layout.height))
        // Trailing spaces do not widen the scroll range.
        let width = CTLineGetOffsetForStringIndex(layout.lines[0].line, long.utf16.count, nil)
        XCTAssertGreaterThan(width, 552 * 2)
        XCTAssertEqual(code.contentWidth, width + 2 * typography.codeBlockPadding, accuracy: 0.001)
        XCTAssertEqual(code.maxOffset, (code.contentWidth - 552).rounded(.up))
        XCTAssertTrue(layout.lines.allSatisfy { $0.x == typography.codeBlockPadding && $0.codeBlock == 0 })
        // A tab reaches the next stop of 8 spaces.
        let font = typography.fonts[Int(TextRole.code.rawValue)]
        var glyph = CGGlyph(0)
        var space = UniChar(0x20)
        CTFontGetGlyphsForCharacters(font, &space, &glyph, 1)
        let spaceWidth = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
        let tabbed = layout.lines[3]
        XCTAssertEqual(CTLineGetOffsetForStringIndex(tabbed.line, tabbed.range.lowerBound + 1, nil), 8 * spaceWidth,
                       accuracy: 0.5)
        // A code block that fits does not scroll.
        XCTAssertEqual(try self.layout("```\nshort\n```").codeBlocks.first?.maxOffset, 0)
    }

    func testTheLongestCuratedLineLaysOutAsOneLine() throws {
        let long = (0..<4_842).map { _ in "x" }.joined()
        let layout = try layout("```\n\(long)\n```")
        XCTAssertEqual(layout.lineCount, 1)
        XCTAssertGreaterThan(try XCTUnwrap(layout.codeBlocks.first).maxOffset, 30_000)
    }

    // MARK: Rules and raw HTML

    func testThematicBreaksDrawARule() throws {
        let snapshot = try snapshot("a\n\n---\n\nb")
        let rule = snapshot.layouts[1]
        XCTAssertEqual(rule.height, typography.ruleThickness)
        XCTAssertEqual(rule.boxes.map(\.kind), [.rule])
        XCTAssertEqual(rule.boxes[0].rect, CGRect(x: 0, y: 0, width: 552, height: typography.ruleThickness))
        XCTAssertEqual(rule.marginTop, typography.ruleMargin)
        XCTAssertEqual(snapshot.blockTops[1], snapshot.blockTops[0] + line + 15, "the larger margin wins")
        let quoted = try layout("> a\n>\n> ---\n>\n> b")
        let box = try XCTUnwrap(quoted.boxes.first { $0.kind == .rule }).rect
        XCTAssertEqual(box.minX, typography.quoteBarWidth + typography.quotePadding)
        XCTAssertEqual(box.maxX, 552 - typography.quoteRightMargin)
        XCTAssertEqual(quoted.height, 2 * line + 2 * 15 + typography.ruleThickness, accuracy: 0.001)
    }

    func testHTMLBlocksTakeNoSpaceAtAnyDepth() throws {
        let plain = try snapshot("> a\n>\n> b\n\n- c\n\n  d")
        let withHTML = try snapshot("> a\n>\n> <div>\n> dropped\n> </div>\n>\n> b\n\n- c\n\n  <p>gone</p>\n\n  d")
        XCTAssertEqual(withHTML.document.blocks.map(\.text), plain.document.blocks.map(\.text))
        XCTAssertEqual(withHTML.layouts.map(\.height), plain.layouts.map(\.height))
        XCTAssertEqual(withHTML.totalHeight, plain.totalHeight)
    }

    // MARK: Estimates

    func testEstimatesFollowTheStructure() throws {
        for source in ["- a\n\n- b\n  - c", "> a\n>\n> > b", "- a\n  ```\n  one\n  two\n  ```\n- b", "```\n1\n2\n3\n```"] {
            let block = try XCTUnwrap(MarkdownDocument.parse(source).blocks.first)
            let estimate = BlockLayout.estimate(for: block, columnWidth: 552, typography: typography)
            let layout = BlockLayout(block: block, columnWidth: 552, typography: typography)
            XCTAssertEqual(estimate.height, layout.height, accuracy: 0.001, source)
            XCTAssertEqual(estimate.marginTop, layout.marginTop, source)
            XCTAssertTrue(estimate.lines.isEmpty && estimate.markers.isEmpty && estimate.boxes.isEmpty)
        }
    }

    // MARK: Selection and copy

    func testSelectionAndCopyAcrossAList() throws {
        let snapshot = try snapshot("Intro.\n\n- first item\n- second item\n  1. nested item\n\nOutro.")
        let list = snapshot.layouts[1]
        XCTAssertEqual(snapshot.document.blocks[1].text, "first item\nsecond item\nnested item")
        func point(_ lineIndex: Int, dx: CGFloat) -> CGPoint {
            let laidOut = list.lines[lineIndex]
            return CGPoint(x: snapshot.columnX + laidOut.x + dx, y: snapshot.blockTops[1] + laidOut.top + laidOut.height / 2)
        }
        // On a marker, left of the indented text, a click lands at the start of the line.
        XCTAssertEqual(snapshot.position(at: point(2, dx: -20)), position(1, 23))
        XCTAssertEqual(snapshot.position(at: point(0, dx: -60)), position(1, 0))
        XCTAssertFalse(snapshot.isOverText(point(2, dx: -20)))
        XCTAssertTrue(snapshot.isOverText(point(2, dx: 5)))
        let range = position(0, 2)..<position(2, 3)
        XCTAssertEqual(snapshot.text(in: range), "tro.\nfirst item\nsecond item\nnested item\nOut")
        let rects = snapshot.selectionRects(for: range, minY: 0, maxY: snapshot.totalHeight)
        let listRects = rects.filter { $0.minY >= snapshot.blockTops[1] && $0.maxY <= snapshot.blockTops[2] }
        XCTAssertEqual(listRects.map(\.minX), list.lines.map { snapshot.columnX + $0.x }, "highlights start at the text")
        XCTAssertTrue(listRects.allSatisfy { $0.maxX == snapshot.columnX + snapshot.columnWidth })
    }

    func testSelectionAndCopyInAQuote() throws {
        let snapshot = try snapshot("> quoted one\n>\n> > nested two")
        let layout = snapshot.layouts[0]
        XCTAssertEqual(snapshot.text(in: try XCTUnwrap(snapshot.fullRange)), "quoted one\nnested two")
        let rects = snapshot.selectionRects(for: position(0, 0)..<position(0, 22), minY: 0, maxY: snapshot.totalHeight)
        XCTAssertEqual(rects.map(\.minX), layout.lines.map { snapshot.columnX + $0.x })
        XCTAssertEqual(rects[0].maxX, snapshot.columnX + layout.lines[0].maxX, accuracy: 0.001,
                       "the continuing line reaches the quote's right edge")
        // In the gap between the paragraphs, the nearer line.
        let gapTop = snapshot.blockTops[0] + layout.lines[0].top + layout.lines[0].height
        let gapBottom = snapshot.blockTops[0] + layout.lines[1].top
        XCTAssertEqual(snapshot.position(at: CGPoint(x: 1000, y: gapTop + 2)), position(0, 10))
        XCTAssertEqual(snapshot.position(at: CGPoint(x: 0, y: gapBottom - 2)), position(0, 11))
    }

    func testCopyOfACodeBlockKeepsItsRawLines() throws {
        let snapshot = try snapshot("Before.\n\n```\n  indented\n\ttabbed\n\nplain  \n```\n\nAfter.")
        XCTAssertEqual(snapshot.document.blocks[1].text, "  indented\n\ttabbed\n\nplain  ")
        XCTAssertEqual(snapshot.text(in: try XCTUnwrap(snapshot.fullRange)), "Before.\n  indented\n\ttabbed\n\nplain  \nAfter.")
        XCTAssertEqual(snapshot.text(in: position(1, 4)..<position(1, 13)), "dented\n\tt")
    }

    func testHitTestingAndHighlightsInAScrolledCodeBlock() throws {
        let long = (0..<200).map { "token\($0)" }.joined(separator: " ")
        let snapshot = try snapshot("```\n\(long)\nshort\n```")
        let layout = snapshot.layouts[0]
        let first = layout.lines[0]
        let id = CodeBlockID(block: 0, code: 0)
        XCTAssertEqual(snapshot.codeBlock(at: CGPoint(x: snapshot.columnX + 5, y: snapshot.blockTops[0] + 5)), id)
        XCTAssertNil(snapshot.codeBlock(at: CGPoint(x: snapshot.columnX + 5, y: snapshot.blockTops[0] - 5)))
        let offsets: CodeOffsets = [id: 300]
        let y = snapshot.blockTops[0] + first.top + first.height / 2
        let x = snapshot.columnX + first.x + 40
        let expected = CTLineGetStringIndexForPosition(first.line, CGPoint(x: 340, y: 0))
        XCTAssertEqual(snapshot.position(at: CGPoint(x: x, y: y), codeOffsets: offsets), position(0, expected))
        XCTAssertNotEqual(snapshot.position(at: CGPoint(x: x, y: y)), position(0, expected))
        // A selection scrolled out of view leaves no highlight; one in view moves with the text.
        XCTAssertTrue(snapshot.selectionRects(for: position(0, 0)..<position(0, 5), minY: 0, maxY: snapshot.totalHeight,
                                              codeOffsets: [id: 1000]).isEmpty)
        let rects = snapshot.selectionRects(for: position(0, expected)..<position(0, expected + 3), minY: 0,
                                            maxY: snapshot.totalHeight, codeOffsets: offsets)
        XCTAssertEqual(rects.count, 1)
        let start = CTLineGetOffsetForStringIndex(first.line, expected, nil)
        XCTAssertEqual(rects[0].minX, snapshot.columnX + first.x + start - 300, accuracy: 0.01)
        // Highlights never leave the box.
        let all = snapshot.selectionRects(for: try XCTUnwrap(snapshot.fullRange), minY: 0, maxY: snapshot.totalHeight,
                                          codeOffsets: offsets)
        let box = try XCTUnwrap(snapshot.codeBlockRect(id))
        XCTAssertTrue(all.allSatisfy { $0.minX >= box.minX && $0.maxX <= box.maxX })
        XCTAssertEqual(snapshot.text(in: try XCTUnwrap(snapshot.fullRange)), long + "\nshort")
    }

    func testCodeOffsetsFollowUnchangedBlocksAcrossEdits() throws {
        let code = "```\n" + String(repeating: "long_line_of_code ", count: 80) + "\n```"
        let base = try snapshot("Intro.\n\n" + code + "\n\nOutro.")
        let offsets: CodeOffsets = [CodeBlockID(block: 1, code: 0): 250]
        let above = try MarkdownSnapshot.updating(base, to: "New block.\n\nIntro, edited.\n\n" + code + "\n\nOutro.", width: 600)
        XCTAssertEqual(above.snapshot.mapCodeOffsets(offsets, from: base, sourceChanged: true),
                       [CodeBlockID(block: 2, code: 0): 250])
        let edited = try MarkdownSnapshot.updating(base, to: "Intro.\n\n" + code.replacingOccurrences(of: "long_", with: "wide_")
                                                   + "\n\nOutro.", width: 600)
        XCTAssertEqual(edited.snapshot.mapCodeOffsets(offsets, from: base, sourceChanged: true), [:])
        // A relayout at another width keeps the offset, clamped to the new width.
        let narrow = MarkdownSnapshot.layOut(base.document, width: 400)
        XCTAssertEqual(narrow.mapCodeOffsets(offsets, from: base, sourceChanged: false), offsets)
        let clamped = narrow.mapCodeOffsets([CodeBlockID(block: 1, code: 0): 1e6], from: base, sourceChanged: false)
        XCTAssertEqual(clamped[CodeBlockID(block: 1, code: 0)], narrow.codeBlockLayout(CodeBlockID(block: 1, code: 0))?.maxOffset)
    }
}
