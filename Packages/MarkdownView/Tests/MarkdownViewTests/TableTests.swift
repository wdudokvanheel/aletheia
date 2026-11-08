import CoreText
import XCTest
@testable import MarkdownView

/// Tables lay out per cell: natural column widths shared out when too wide,
/// alignment, header style, borders, wrapping, per-table scrolling, row
/// reuse across edits, progressive rows, and selection in row-major order.
final class TableTests: XCTestCase {
    private let typography = Typography.standard

    private func snapshot(_ source: String, width: CGFloat = 700) throws -> MarkdownSnapshot {
        MarkdownSnapshot.layOut(try MarkdownDocument.parse(source), width: width)
    }

    private func table(_ snapshot: MarkdownSnapshot, _ block: Int = 0) throws -> TableLayout {
        try XCTUnwrap(snapshot.layouts[block].tables.first)
    }

    private func cellText(_ block: MarkdownBlock, _ row: Int, _ column: Int) -> String {
        let range = block.tables[0].cell(row, column)
        return (block.text as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    /// A table whose second column wraps at 700 pt.
    private func longTable(rows: Int, seed: Int = 0) -> String {
        "| ID | Description | Value |\n| --: | --- | --- |\n" + (0..<rows).map { row in
            "| \(row) | " + String(repeating: "words that wrap \(row + seed) ", count: 4 + row % 7) + "| v\(row % 5) |"
        }.joined(separator: "\n")
    }

    // MARK: Model

    func testTheModelHasRowsOfCellsAHeaderAndAlignments() throws {
        let source = "| a | b | c | d |\n| :- | :-: | -: | - |\n| 1 | *2* |\n| x | y | z | w | extra |"
        let block = try XCTUnwrap(MarkdownDocument.parse(source).blocks.first)
        let structure = try XCTUnwrap(block.tables.first)
        XCTAssertEqual(structure.alignments, [.left, .center, .right, .none])
        XCTAssertTrue(structure.hasHeader)
        XCTAssertEqual(structure.rowCount, 3)
        XCTAssertEqual(structure.columnCount, 4)
        // Short rows get empty cells and extra cells are dropped, as in GFM.
        XCTAssertEqual(block.text, "a\tb\tc\td\n1\t2\t\t\nx\ty\tz\tw")
        XCTAssertEqual((0..<3).map { row in (0..<4).map { cellText(block, row, $0) } },
                       [["a", "b", "c", "d"], ["1", "2", "", ""], ["x", "y", "z", "w"]])
        let bytes = Array(block.sourceText.utf8)
        let lines = structure.rowLines.map { String(decoding: bytes[Int($0.lowerBound)..<Int($0.upperBound)], as: UTF8.self) }
        XCTAssertEqual(lines, ["| a | b | c | d |", "| 1 | *2* |", "| x | y | z | w | extra |"])
        let starts = ["| a", "| 1", "| x"].map { (source as NSString).range(of: $0).location }
        XCTAssertEqual(structure.rowSourceStarts.map(Int.init), starts)
        // Cells are found by display offset, row-major.
        XCTAssertEqual(structure.cell(containing: 0)?.row, 0)
        XCTAssertEqual(structure.cell(containing: 9).map { [$0.row, $0.column] }, [1, 0])
        XCTAssertEqual(structure.cell(containing: 11).map { [$0.row, $0.column] }, [1, 1])
    }

    func testTheHeaderRowIsTheLineBeforeTheDelimiterAfterAParagraph() throws {
        // cmark-gfm gives the header row the paragraph's first line.
        let block = try XCTUnwrap(MarkdownDocument.parse("first line\n| a | b |\n| - | - |\n| 1 | 2 |").blocks.last)
        let structure = try XCTUnwrap(block.tables.first)
        let bytes = Array(block.sourceText.utf8)
        let line = structure.rowLines[0]
        XCTAssertEqual(String(decoding: bytes[Int(line.lowerBound)..<Int(line.upperBound)], as: UTF8.self), "| a | b |")
    }

    // MARK: Layout

    func testCellsAlignAndHeadersAreBoldAndCentered() throws {
        let snapshot = try snapshot("| Left | Center | Right | Plain |\n| :--- | :---: | ---: | --- |\n| a | b | c | d |")
        let table = try table(snapshot)
        let width = table.columnWidths
        func offset(_ row: Int, _ column: Int) throws -> CGFloat {
            let line = try XCTUnwrap(table.rows[row].lines(ofCell: column).first)
            return table.alignmentOffset(of: line, row: row, column: column)
        }
        let body = table.rows[1]
        XCTAssertEqual(try offset(1, 0), 0)
        XCTAssertEqual(try offset(1, 1), ((width[1] - body.naturalWidths[1]) / 2).rounded())
        XCTAssertEqual(try offset(1, 2), width[2] - body.naturalWidths[2])
        XCTAssertEqual(try offset(1, 3), 0, "body cells start at the left")
        XCTAssertEqual(try offset(0, 3), ((width[3] - table.rows[0].naturalWidths[3]) / 2).rounded(), "headers center")
        XCTAssertEqual(try offset(0, 0), 0, "aligned headers follow their column")

        func isBold(_ line: LineLayout) -> Bool {
            let runs = CTLineGetGlyphRuns(line.line) as? [CTRun] ?? []
            return runs.allSatisfy { run in
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let font = attributes[kCTFontAttributeName] as! CTFont
                return CTFontGetSymbolicTraits(font).contains(.traitBold)
            }
        }
        XCTAssertTrue(isBold(try XCTUnwrap(table.rows[0].lines(ofCell: 1).first)))
        XCTAssertFalse(isBold(try XCTUnwrap(table.rows[1].lines(ofCell: 1).first)))
    }

    func testBordersPaddingAndRowHeights() throws {
        let snapshot = try snapshot("| a | b |\n| - | - |\n| 1 | 2 |\n|  | 3 |")
        let table = try table(snapshot)
        let line = typography.lineHeight(.body)
        let row = line + 2 * typography.tableCellVerticalPadding + typography.tableBorderWidth
        XCTAssertEqual(table.rowTops, [0, row, 2 * row, 3 * row])
        XCTAssertEqual(table.rect.height, 3 * row + typography.tableBorderWidth)
        XCTAssertEqual(snapshot.layouts[0].height, table.rect.height)
        XCTAssertEqual(table.columnEdges[1] - table.columnEdges[0],
                       table.columnWidths[0] + 2 * typography.tableCellHorizontalPadding + typography.tableBorderWidth)
        XCTAssertEqual(table.width, table.columnEdges.last! + typography.tableBorderWidth)
        XCTAssertLessThan(table.width, table.rect.width, "a narrow table does not stretch")
        XCTAssertEqual(table.rect.width, snapshot.columnWidth)
        // The empty cell has no lines; the text is centered vertically in its row.
        XCTAssertTrue(table.rows[2].lines(ofCell: 0).isEmpty)
        XCTAssertEqual(table.textOrigin(row: 1, column: 0).y,
                       row + typography.tableBorderWidth + typography.tableCellVerticalPadding)
        XCTAssertEqual(snapshot.layouts[0].lineCount, 5)
    }

    func testANarrowWidthWrapsWideColumnsAndKeepsNarrowOnes() throws {
        let source = "| ID | Description | Owner |\n| -- | --- | --- |\n| 1 | " + String(repeating: "long words ", count: 8)
            + "| someone |"
        let wide = try table(try snapshot(source, width: 2400))
        XCTAssertTrue(wide.rows.allSatisfy { $0.lines.count == 3 }, "one line per cell when it fits")
        let narrow = try table(try snapshot(source, width: 500))
        XCTAssertEqual(narrow.columnWidths[0], wide.columnWidths[0], "a narrow column keeps its width")
        XCTAssertEqual(narrow.columnWidths[2], wide.columnWidths[2])
        XCTAssertLessThan(narrow.columnWidths[1], wide.columnWidths[1])
        XCTAssertEqual(narrow.width, narrow.rect.width, accuracy: CGFloat(narrow.columnWidths.count),
                       "the wrapped table fills its box")
        let wrapped = narrow.rows[1].lines(ofCell: 1)
        XCTAssertGreaterThan(wrapped.count, 1)
        XCTAssertTrue(wrapped.allSatisfy { $0.maxX <= narrow.columnWidths[1] + 0.5 })
        XCTAssertEqual(narrow.rows[1].contentHeight, CGFloat(wrapped.count) * typography.lineHeight(.body))
        XCTAssertFalse(narrow.isPartial)
    }

    func testColumnWidthsShareTheSpaceInProportion() {
        XCTAssertEqual(TableLayout.columnWidths(natural: [100, 200], available: 400, minimum: 60), [100, 200])
        XCTAssertEqual(TableLayout.columnWidths(natural: [400, 200], available: 300, minimum: 60), [200, 100],
                       "shared in proportion")
        XCTAssertEqual(TableLayout.columnWidths(natural: [900, 400], available: 600, minimum: 60), [415, 184])
        XCTAssertEqual(TableLayout.columnWidths(natural: [900, 300], available: 600, minimum: 60), [300, 300],
                       "a column no wider than an equal share keeps its width")
        XCTAssertEqual(TableLayout.columnWidths(natural: [1000, 70, 900], available: 300, minimum: 60), [121, 70, 108])
        XCTAssertEqual(TableLayout.columnWidths(natural: [1000, 30, 30, 900, 100], available: 250, minimum: 60),
                       [68, 30, 30, 61, 60], "none under the minimum")
        XCTAssertEqual(TableLayout.columnWidths(natural: [20, 1000, 40], available: 400, minimum: 60), [20, 340, 40],
                       "narrow columns keep their width")
        // When even the minimums do not fit, columns keep up to half the space and the table scrolls.
        XCTAssertEqual(TableLayout.columnWidths(natural: Array(repeating: 100, count: 10) + [900], available: 500, minimum: 60),
                       Array(repeating: 100, count: 10) + [250])
        XCTAssertEqual(TableLayout.columnWidths(natural: Array(repeating: 100, count: 10) + [900], available: 100, minimum: 60),
                       Array(repeating: 100, count: 10) + [180], "or three minimums")
    }

    func testAWideTableScrollsInItsOwnBox() throws {
        let source = "| " + (0..<20).map { "Column \($0)" }.joined(separator: " | ") + " |\n|"
            + String(repeating: " --- |", count: 20) + "\n| " + (0..<20).map { "value \($0)" }.joined(separator: " | ") + " |"
        let snapshot = try snapshot("Intro.\n\n" + source, width: 600)
        let table = try table(snapshot, 1)
        XCTAssertGreaterThan(table.width, table.rect.width)
        let box = try XCTUnwrap(snapshot.layouts[1].codeBlocks.first)
        XCTAssertTrue(box.isTable)
        XCTAssertEqual(box.maxOffset, (table.width - table.rect.width).rounded(.up))
        XCTAssertEqual(table.scrollIndex, 0)
        // Scrolled, the same point lands in a column further right.
        let id = CodeBlockID(block: 1, code: 0)
        let point = CGPoint(x: snapshot.columnX + 40, y: snapshot.blockTops[1] + table.rowTops[1] + 15)
        let unscrolled = try XCTUnwrap(snapshot.position(at: point))
        let scrolled = try XCTUnwrap(snapshot.position(at: point, codeOffsets: [id: table.columnEdges[5]]))
        XCTAssertEqual(table.structure.cell(containing: unscrolled.offset)?.column, 0)
        XCTAssertEqual(table.structure.cell(containing: scrolled.offset)?.column, 5)
        XCTAssertEqual(snapshot.codeBlock(at: point), id)
    }

    // MARK: Edits

    private func updating(_ base: MarkdownSnapshot, _ source: String, width: CGFloat = 700) throws -> MarkdownSnapshot {
        let result = try MarkdownSnapshot.updating(base, to: source, width: width)
        let full = try snapshot(source, width: width)
        XCTAssertEqual(result.snapshot.document.blocks, full.document.blocks)
        XCTAssertEqual(result.snapshot.layouts.map(\.height), full.layouts.map(\.height))
        XCTAssertEqual(result.snapshot.layouts.map(\.lineCount), full.layouts.map(\.lineCount))
        XCTAssertEqual(result.snapshot.blockTops, full.blockTops)
        for (a, b) in zip(result.snapshot.layouts, full.layouts) {
            XCTAssertEqual(a.tables.map(\.rowTops), b.tables.map(\.rowTops))
            XCTAssertEqual(a.tables.map(\.columnWidths), b.tables.map(\.columnWidths))
        }
        return result.snapshot
    }

    func testACellEditMeasuresAndLaysOutOnlyItsRow() throws {
        let rows = (0..<60).map { "| \($0) | item \($0) | value \($0) |" }
        let source = "# Title\n\n| ID | Name | Value |\n| - | - | - |\n" + rows.joined(separator: "\n") + "\n\nAfter."
        let base = try snapshot(source)
        var edited = rows
        edited[30] = "| 30 | i 30 | value 30 |"
        let snapshot = try updating(base, "# Title\n\n| ID | Name | Value |\n| - | - | - |\n" + edited.joined(separator: "\n")
                                    + "\n\nAfter.")
        let old = try table(base, 1)
        let new = try table(snapshot, 1)
        XCTAssertEqual(new.measuredRows, 1, "natural widths come from the other rows' cache")
        XCTAssertEqual(new.builtRows, 1)
        for row in new.rows.indices where row != 31 {
            XCTAssertTrue(new.rows[row] === old.rows[row], "row \(row)")
        }
        XCTAssertFalse(new.rows[31] === old.rows[31])
        XCTAssertTrue(snapshot.layouts[0] === base.layouts[0])
        XCTAssertTrue(snapshot.layouts[2] === base.layouts[2])

        // Inserting and deleting rows keeps the others.
        var inserted = rows
        inserted.insert("| new | row | here |", at: 10)
        let grown = try table(try updating(base, "# Title\n\n| ID | Name | Value |\n| - | - | - |\n"
                                           + inserted.joined(separator: "\n") + "\n\nAfter."), 1)
        XCTAssertEqual(grown.measuredRows, 1)
        XCTAssertEqual(grown.rows.count, 62)
        XCTAssertTrue(grown.rows[60] === old.rows[59])
    }

    func testAColumnWidthChangeRelaysOutOnlyThatTable() throws {
        let rows = (0..<40).map { "| \($0) | " + String(repeating: "text \($0) ", count: 20) + "|" }
        let header = "| ID | Text |\n| - | - |\n"
        let source = "Intro paragraph.\n\n" + header + rows.joined(separator: "\n") + "\n\nOutro paragraph."
        let base = try snapshot(source)
        let old = try table(base, 1)
        XCTAssertGreaterThan(old.rows[1].lines(ofCell: 1).count, 1, "the text column wraps")
        var edited = rows
        edited[5] = "| 5 and a much wider first cell | " + String(repeating: "text 5 ", count: 20) + "|"
        let snapshot = try updating(base, "Intro paragraph.\n\n" + header + edited.joined(separator: "\n") + "\n\nOutro paragraph.")
        let new = try table(snapshot, 1)
        XCTAssertNotEqual(new.columnWidths, old.columnWidths)
        XCTAssertEqual(new.measuredRows, 1, "only the edited row is measured")
        XCTAssertEqual(new.builtRows, new.rows.count - 1, "every wrapped row follows the new widths; the header still fits")
        XCTAssertTrue(snapshot.layouts[0] === base.layouts[0])
        XCTAssertTrue(snapshot.layouts[2] === base.layouts[2])
    }

    func testANewWidthReusesNaturalWidthsAndRowsThatStillFit() throws {
        let source = "| a | b |\n| - | - |\n| short | cell |\n| " + String(repeating: "long ", count: 60) + "| x |"
        let base = try snapshot(source, width: 800)
        let result = try MarkdownSnapshot.updating(base, to: source, width: 790)
        let old = try table(base)
        let new = try table(result.snapshot)
        XCTAssertEqual(new.measuredRows, 0)
        XCTAssertTrue(new.rows[0] === old.rows[0], "rows that still fit stay")
        XCTAssertTrue(new.rows[1] === old.rows[1])
        XCTAssertFalse(new.rows[2] === old.rows[2], "the wrapped row follows the new width")
        XCTAssertEqual(new.rowTops, try table(try snapshot(source, width: 790)).rowTops)
    }

    // MARK: Progressive rows

    func testAPartialLayoutRefinesToTheSameHeightsAsAOneShotLayout() throws {
        let block = try XCTUnwrap(MarkdownDocument.parse(longTable(rows: 300)).blocks.first)
        let columnWidth: CGFloat = 652
        let partial = try XCTUnwrap(BlockLayout.make(block, columnWidth: columnWidth, typography: typography,
                                                     tableRows: .covering(first: 0, height: 900)))
        let partialTable = try XCTUnwrap(partial.tables.first)
        XCTAssertTrue(partial.isPartial)
        XCTAssertFalse(partial.isFinal(for: columnWidth))
        XCTAssertGreaterThan(partialTable.estimatedRows, 200)
        let laidOut = partialTable.rows.prefix { !$0.isEstimate }.count
        XCTAssertGreaterThanOrEqual(partialTable.rowTops[laidOut], 900, "laid out down to the requested height")
        XCTAssertLessThan(laidOut, 60)

        let complete = try XCTUnwrap(BlockLayout.make(block, columnWidth: columnWidth, typography: typography, hint: partial))
        let oneShot = BlockLayout(block: block, columnWidth: columnWidth, typography: typography)
        XCTAssertFalse(complete.isPartial)
        XCTAssertTrue(complete.isFinal(for: columnWidth))
        XCTAssertEqual(complete.height, oneShot.height)
        XCTAssertEqual(complete.tables[0].rowTops, oneShot.tables[0].rowTops)
        XCTAssertEqual(complete.lineCount, oneShot.lineCount)
        let completeTable = try XCTUnwrap(complete.tables.first)
        XCTAssertEqual(completeTable.measuredRows, 0, "natural widths come from the partial layout")
        for row in 0..<laidOut { XCTAssertTrue(completeTable.rows[row] === partialTable.rows[row]) }

        // A relayout window starts at a row in the middle.
        let window = try XCTUnwrap(BlockLayout.make(block, columnWidth: columnWidth, typography: typography,
                                                    hint: complete, tableRows: .covering(first: 150, height: 600)))
        XCTAssertFalse(window.isPartial, "rows that still fit are kept")
        let narrower = try XCTUnwrap(BlockLayout.make(block, columnWidth: 500, typography: typography, hint: complete,
                                                      tableRows: .covering(first: 150, height: 600)))
        let rows = narrower.tables[0].rows
        XCTAssertTrue(rows[100].isEstimate)
        XCTAssertFalse(rows[150].isEstimate)
        XCTAssertFalse(rows[155].isEstimate)
        XCTAssertTrue(rows[299].isEstimate)
    }

    func testTheScrollAnchorKeepsATableRowInPlaceAsHeightsRefine() throws {
        let document = try MarkdownDocument.parse("Intro.\n\n" + longTable(rows: 200))
        let width: CGFloat = 700
        let columnWidth = typography.column(forWidth: width).width
        let intro = BlockLayout(block: document.blocks[0], columnWidth: columnWidth, typography: typography)
        let partialTable = try XCTUnwrap(BlockLayout.make(document.blocks[1], columnWidth: columnWidth,
                                                          typography: typography, tableRows: .covering(first: 0, height: 800)))
        let partial = MarkdownSnapshot(document: document, layouts: [intro, partialTable], width: width,
                                       typography: typography, generation: 1)
        XCTAssertFalse(partial.isComplete)
        let complete = MarkdownSnapshot.layOut(document, width: width)
        let table = partialTable.tables[0]
        let row = 120
        let y = partial.blockTops[1] + table.rowTops[row] + 10
        let anchor = try XCTUnwrap(partial.anchor(atY: y))
        XCTAssertEqual(anchor.row, row)
        XCTAssertEqual(complete.y(for: anchor), complete.blockTops[1] + complete.layouts[1].tables[0].rowTops[row] + 10)
        XCTAssertTrue(table.rows[..<row].contains { $0.isEstimate }, "the anchor counts from estimated rows")
    }

    func testEditingATableRowKeepsTheTopRowInPlace() throws {
        let rows = (0..<80).map { "| \($0) | " + String(repeating: "cell ", count: 1 + $0 % 3) + "|" }
        let header = "| ID | Text |\n| - | - |\n"
        let base = try snapshot("Intro.\n\n" + header + rows.joined(separator: "\n"))
        let table = try table(base, 1)
        let y = base.blockTops[1] + table.rowTops[50] + 7
        var edited = rows
        edited[10] = "| 10 | " + String(repeating: "much longer text ", count: 40) + "|"
        let snapshot = try MarkdownSnapshot.updating(base, to: "Intro.\n\n" + header + edited.joined(separator: "\n"),
                                                     width: 700).snapshot
        let update = try XCTUnwrap(snapshot.update)
        let newTable = try self.table(snapshot, 1)
        XCTAssertGreaterThan(newTable.rowTops[50], table.rowTops[50])
        XCTAssertEqual(snapshot.anchoredY(y, from: base, through: update), snapshot.blockTops[1] + newTable.rowTops[50] + 7)
    }

    // MARK: Selection and copy

    private let grid = "Before.\n\n| Name | Value | Note |\n| --- | ---: | --- |\n| pi | 3.14 | circle |\n| e | 2.71 | growth |\n\nAfter."

    /// A point in the middle of a cell's first line, in view coordinates.
    private func point(_ snapshot: MarkdownSnapshot, row: Int, column: Int, offset: Int = 0) throws -> CGPoint {
        let table = try table(snapshot, 1)
        let line = try XCTUnwrap(table.rows[row].lines(ofCell: column).first)
        let origin = table.textOrigin(row: row, column: column)
        // Line ranges index the string the row was shaped in.
        let index = table.structure.cell(row, column).lowerBound - table.textOffset(row: row, column: column) + offset
        let x = origin.x + table.alignmentOffset(of: line, row: row, column: column)
            + CTLineGetOffsetForStringIndex(line.line, index, nil)
        return CGPoint(x: snapshot.columnX + table.rect.minX + x + 0.5,
                       y: snapshot.blockTops[1] + table.rect.minY + origin.y + line.height / 2)
    }

    func testHitTestingFindsTheCellUnderThePointInRowMajorOrder() throws {
        let snapshot = try snapshot(grid)
        let block = snapshot.document.blocks[1]
        var previous: TextPosition?
        for row in 0..<3 {
            for column in 0..<3 {
                let position = try XCTUnwrap(snapshot.position(at: try point(snapshot, row: row, column: column, offset: 1)))
                XCTAssertEqual(position.block, 1)
                XCTAssertEqual(position.offset, block.tables[0].cell(row, column).lowerBound + 1, "row \(row) column \(column)")
                if let previous { XCTAssertLessThan(previous, position, "row-major order") }
                previous = position
            }
        }
        // In a cell's padding, the nearest end of its text; between blocks, the nearer block.
        let table = try table(snapshot, 1)
        let left = CGPoint(x: snapshot.columnX + 2, y: snapshot.blockTops[1] + table.rowTops[2] + 8)
        XCTAssertEqual(snapshot.position(at: left)?.offset, block.tables[0].cell(2, 0).lowerBound)
        XCTAssertTrue(snapshot.isOverText(try point(snapshot, row: 1, column: 2, offset: 2)))
        XCTAssertFalse(snapshot.isOverText(left))
    }

    func testSelectionRectsArePerCellInRowMajorOrder() throws {
        let snapshot = try snapshot(grid)
        let structure = snapshot.document.blocks[1].tables[0]
        let table = try table(snapshot, 1)
        // From inside "pi" (row 1) to inside "2.71" (row 2).
        let start = TextPosition(block: 1, offset: structure.cell(1, 0).lowerBound + 1)
        let end = TextPosition(block: 1, offset: structure.cell(2, 1).lowerBound + 2)
        let rects = snapshot.selectionRects(for: start..<end, minY: 0, maxY: snapshot.totalHeight)
        XCTAssertEqual(rects.count, 5, "the rest of row 1 and the first two cells of row 2")
        let top = snapshot.blockTops[1]
        let rowOf = { (rect: CGRect) in table.row(atY: rect.midY - top) }
        XCTAssertEqual(rects.map(rowOf), [1, 1, 1, 2, 2])
        let columnOf = { (rect: CGRect) in table.column(atX: rect.midX - snapshot.columnX) }
        XCTAssertEqual(rects.map(columnOf), [0, 1, 2, 0, 1])
        // Cells the selection continues past are highlighted to their column's edge.
        XCTAssertEqual(rects[1].maxX, snapshot.columnX + table.textOrigin(row: 1, column: 1).x + table.columnWidths[1],
                       accuracy: 0.001)
        XCTAssertEqual(snapshot.text(in: start..<end), "i\t3.14\tcircle\ne\t2.")
        // The dirty band of a table position is its row.
        let band = snapshot.lineBand(start, start)
        XCTAssertEqual(band.minY, top + table.rowTops[1])
        XCTAssertEqual(band.height, table.rowTops[2] - table.rowTops[1] + typography.tableBorderWidth)
    }

    func testCopyUsesTabsBetweenCellsAndNewlinesBetweenRows() throws {
        let snapshot = try snapshot(grid)
        let structure = snapshot.document.blocks[1].tables[0]
        XCTAssertEqual(snapshot.text(in: try XCTUnwrap(snapshot.fullRange)),
                       "Before.\nName\tValue\tNote\npi\t3.14\tcircle\ne\t2.71\tgrowth\nAfter.")
        // A partial row copies the cells it covers.
        let row = TextPosition(block: 1, offset: structure.cell(1, 1).lowerBound)
            ..< TextPosition(block: 1, offset: structure.cell(2, 1).upperBound)
        XCTAssertEqual(snapshot.text(in: row), "3.14\tcircle\ne\t2.71")
        let paragraph = snapshot.unitRange(at: TextPosition(block: 1, offset: structure.cell(1, 2).lowerBound + 2),
                                           granularity: .paragraph)
        XCTAssertEqual(snapshot.text(in: paragraph), "circle", "a triple-click selects the cell")
        let word = snapshot.unitRange(at: TextPosition(block: 1, offset: structure.cell(2, 2).lowerBound + 1),
                                      granularity: .word)
        XCTAssertEqual(snapshot.text(in: word), "growth")
        // From the paragraph above into the table.
        XCTAssertEqual(snapshot.text(in: TextPosition(block: 0, offset: 3)..<TextPosition(block: 1, offset: 4)),
                       "ore.\nName")
    }

    func testLinksInCellsOpen() throws {
        let snapshot = try snapshot("Before.\n\n| Site | Link |\n| - | - |\n| home | [example](https://example.com) |")
        let target = try point(snapshot, row: 1, column: 1, offset: 2)
        XCTAssertEqual(snapshot.linkDestination(at: target), "https://example.com")
        XCTAssertNil(snapshot.linkDestination(at: try point(snapshot, row: 1, column: 0, offset: 1)))
        let origin = try XCTUnwrap(snapshot.baselineOrigin(of: TextPosition(block: 1, offset: snapshot.document.blocks[1]
            .tables[0].cell(1, 1).lowerBound + 2)))
        XCTAssertEqual(origin.point.x, target.x - 0.5, accuracy: 0.01)
        XCTAssertTrue(origin.style.styles.contains(.link))
    }
}
