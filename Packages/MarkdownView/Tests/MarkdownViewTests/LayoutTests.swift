import XCTest
@testable import MarkdownView

final class LayoutTests: XCTestCase {
    private let mixed = """
    # Release notes

    The preview lays out every block with Core Text and draws only what is visible on screen.

    ## Changes

    - Faster startup
    - Smaller memory footprint

    ```
    let answer = 42
    print(answer)
    ```

    > A quoted remark that is long enough to wrap onto a second line at a narrow width.

    | Column | Value |
    | ------ | ----- |
    | width  | 600   |

    ---

    Final paragraph.
    """

    func testBlockTopsIncreaseAndTotalHeightCoversLastBlock() throws {
        let snapshot = MarkdownSnapshot.layOut(try MarkdownDocument.parse(mixed), width: 600, generation: 3)
        XCTAssertEqual(snapshot.generation, 3)
        XCTAssertEqual(snapshot.layouts.count, 9)
        XCTAssertTrue(snapshot.isComplete)
        for index in 1..<snapshot.blockTops.count {
            let previous = snapshot.blockTops[index - 1] + snapshot.layouts[index - 1].height
            XCTAssertGreaterThan(snapshot.blockTops[index], snapshot.blockTops[index - 1])
            XCTAssertGreaterThanOrEqual(snapshot.blockTops[index], previous)
        }
        let last = snapshot.layouts.count - 1
        XCTAssertGreaterThan(snapshot.totalHeight, snapshot.blockTops[last] + snapshot.layouts[last].height)
    }

    func testMarginsCollapseAndHTMLTakesNoSpace() throws {
        let typography = Typography.standard
        let plain = MarkdownSnapshot.layOut(try MarkdownDocument.parse("one\n\ntwo"), width: 600)
        let withHTML = MarkdownSnapshot.layOut(try MarkdownDocument.parse("one\n\n<div>x</div>\n\ntwo"), width: 600)
        let line = typography.lineHeight(.body)
        XCTAssertEqual(plain.blockTops, [typography.topInset + 15, typography.topInset + 15 + line + 15])
        XCTAssertEqual(withHTML.layouts[1].height, 0)
        XCTAssertEqual(withHTML.blockTops[2], plain.blockTops[1])
        XCTAssertEqual(withHTML.totalHeight, plain.totalHeight)
    }

    func testNarrowWidthWrapsIntoMoreLines() throws {
        let block = try XCTUnwrap(MarkdownDocument.parse(String(repeating: "wrapping words ", count: 40)).blocks.first)
        let wide = BlockLayout(block: block, columnWidth: 800, typography: .standard)
        let narrow = BlockLayout(block: block, columnWidth: 200, typography: .standard)
        XCTAssertGreaterThan(narrow.lineCount, wide.lineCount)
        XCTAssertEqual(narrow.height, CGFloat(narrow.lineCount) * Typography.standard.lineHeight(.body), accuracy: 0.001)
    }

    func testHeadingAndCodeMetrics() throws {
        let blocks = try MarkdownDocument.parse("# Big\n\n```\na\nb\n```").blocks
        let heading = BlockLayout(block: blocks[0], columnWidth: 600, typography: .standard)
        let code = BlockLayout(block: blocks[1], columnWidth: 600, typography: .standard)
        XCTAssertEqual(heading.height, 30 * 1.3, accuracy: 0.001)
        XCTAssertEqual(heading.marginTop, 42, accuracy: 0.001)
        XCTAssertEqual(code.lineCount, 2)
        XCTAssertEqual(code.height, 2 * 13.5 * 1.6 + 24, accuracy: 0.001)
    }

    func testColumnIsInsetCappedAndCentered() {
        let typography = Typography.standard
        XCTAssertEqual(typography.column(forWidth: 600).x, 24)
        XCTAssertEqual(typography.column(forWidth: 600).width, 552)
        XCTAssertEqual(typography.column(forWidth: 1200).width, 900)
        XCTAssertEqual(typography.column(forWidth: 1200).x, 150)
    }

    func testVisibleBlockRangeMatchesLinearScan() throws {
        let source = (0..<200).map { index in
            index % 7 == 0 ? "## Heading \(index)" : String(repeating: "Paragraph \(index) text. ", count: index % 5 + 1)
        }.joined(separator: "\n\n")
        let snapshot = MarkdownSnapshot.layOut(try MarkdownDocument.parse(source), width: 500)
        XCTAssertEqual(snapshot.layouts.count, 200)
        let step = snapshot.totalHeight / 97
        for minY in stride(from: -50, through: snapshot.totalHeight + 50, by: step) {
            let maxY = minY + 300
            let expected = snapshot.layouts.indices.filter { index in
                let top = snapshot.blockTops[index]
                return top + snapshot.layouts[index].height > minY && top < maxY
            }
            XCTAssertEqual(Array(snapshot.blockRange(intersecting: minY, maxY)), expected, "minY \(minY)")
        }
        XCTAssertTrue(snapshot.blockRange(intersecting: snapshot.totalHeight, snapshot.totalHeight + 10).isEmpty)
    }

    func testScrollAnchorSurvivesRelayout() throws {
        let document = try MarkdownDocument.parse((0..<50).map { "Paragraph \($0) " + String(repeating: "word ", count: 60) }
            .joined(separator: "\n\n"))
        let wide = MarkdownSnapshot.layOut(document, width: 800)
        let narrow = MarkdownSnapshot.layOut(document, width: 300)
        let inside = try XCTUnwrap(wide.anchor(atY: wide.blockTops[10] + wide.layouts[10].height / 2))
        XCTAssertEqual(inside.block, 10)
        XCTAssertEqual(narrow.y(for: inside), narrow.blockTops[10] + narrow.layouts[10].height / 2, accuracy: 0.001)
        let margin = try XCTUnwrap(wide.anchor(atY: wide.blockTops[10] - 5))
        XCTAssertEqual(margin.block, 10)
        XCTAssertEqual(narrow.y(for: margin), narrow.blockTops[10] - 5, accuracy: 0.001)
        XCTAssertEqual(narrow.y(for: try XCTUnwrap(wide.anchor(atY: 0))), 0)
    }

    func testCancelledParallelLayoutReturnsNil() throws {
        let blocks = try MarkdownDocument.parse(mixed).blocks
        XCTAssertNil(BlockLayout.layOut(blocks, columnWidth: 500, typography: .standard, isCancelled: { true }))
        XCTAssertEqual(BlockLayout.layOut(blocks, columnWidth: 500, typography: .standard)?.count, blocks.count)
    }

    func testEmptyDocumentHasInsetsOnly() {
        let snapshot = MarkdownSnapshot.layOut(MarkdownDocument(blocks: []), width: 400)
        XCTAssertEqual(snapshot.totalHeight, Typography.standard.topInset + Typography.standard.bottomInset)
        XCTAssertTrue(snapshot.blockRange(intersecting: 0, 1000).isEmpty)
    }
}
