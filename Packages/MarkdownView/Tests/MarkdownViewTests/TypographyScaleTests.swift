import AppKit
import XCTest
@testable import MarkdownView

/// A scaled typography makes the same page bigger or smaller: every size in
/// points scales, so text breaks into the same lines.
@MainActor
final class TypographyScaleTests: XCTestCase {
    private let page = """
    # Release notes

    The preview lays out every block with Core Text and draws only what is visible on screen, so even very long \
    documents open quickly and scroll without stalls. This paragraph is long enough to wrap several times in a \
    column of nine hundred points, which is what the comparison below needs.

    ## Changes

    - Faster startup, because nothing is laid out before it is needed and the visible area always comes first
    - Smaller memory footprint
      1. Nested items keep their indent, which scales with the text around them in the same proportion
    - [x] A finished task whose description wraps onto a second line when the column is narrow enough for it

    > A quoted remark that is long enough to wrap onto a second line at this width, with a little more text so \
    that it does, and then some more words to be sure that it really wraps at least once here.

    ```
    let answer = 42
    print(answer)
    ```

    Final paragraph with `inline code`, **strong text**, and *emphasis* mixed into a sentence that wraps over \
    the end of the line at least once, perhaps twice when the fonts are what they are.
    """

    private func lineRanges(_ snapshot: MarkdownSnapshot) -> [[Range<Int>]] {
        snapshot.layouts.map { $0.lines.map(\.range) }
    }

    func testScaledTypographyMultipliesEverySize() {
        let standard = Typography.standard
        let double = Typography(scale: 2)
        XCTAssertEqual(standard.scale, 1)
        XCTAssertEqual(double.bodyFontSize, 2 * standard.bodyFontSize)
        for role in TextRole.allCases {
            XCTAssertEqual(double.lineHeight(role), 2 * standard.lineHeight(role), accuracy: 0.001)
            XCTAssertEqual(CTFontGetSize(double.fonts[Int(role.rawValue)]),
                           2 * CTFontGetSize(standard.fonts[Int(role.rawValue)]), accuracy: 0.001)
        }
        XCTAssertEqual(CTFontGetSize(double.font(.body, .code)), 2 * CTFontGetSize(standard.font(.body, .code)),
                       accuracy: 0.001)
        let pairs: [(CGFloat, CGFloat)] = [
            (double.topInset, standard.topInset), (double.bottomInset, standard.bottomInset),
            (double.horizontalInset, standard.horizontalInset),
            (double.maximumColumnWidth, standard.maximumColumnWidth),
            (double.minimumColumnWidth, standard.minimumColumnWidth), (double.blockSpacing, standard.blockSpacing),
            (double.codeBlockMargin, standard.codeBlockMargin), (double.codeBlockPadding, standard.codeBlockPadding),
            (double.codeBlockCornerRadius, standard.codeBlockCornerRadius),
            (double.inlineCodePadding, standard.inlineCodePadding), (double.ruleThickness, standard.ruleThickness),
            (double.ruleMargin, standard.ruleMargin), (double.tableBorderWidth, standard.tableBorderWidth),
            (double.tableCellVerticalPadding, standard.tableCellVerticalPadding),
            (double.tableCellHorizontalPadding, standard.tableCellHorizontalPadding),
            (double.tableMinimumColumnWidth, standard.tableMinimumColumnWidth), (double.listIndent, standard.listIndent),
            (double.listMarkerSpacing, standard.listMarkerSpacing), (double.bulletSize, standard.bulletSize),
            (double.taskBoxSize, standard.taskBoxSize), (double.taskBoxCornerRadius, standard.taskBoxCornerRadius),
            (double.quoteBarWidth, standard.quoteBarWidth), (double.quotePadding, standard.quotePadding),
            (double.quoteRightMargin, standard.quoteRightMargin)
        ]
        for (scaled, base) in pairs { XCTAssertEqual(scaled, 2 * base) }
        XCTAssertEqual(double.headingScale, standard.headingScale)
        XCTAssertEqual(double.lineHeightMultiple, standard.lineHeightMultiple)
        XCTAssertEqual(Typography(scale: 0).scale, 1)
        XCTAssertEqual(Typography(scale: .nan).scale, 1)
    }

    func testScaledPageBreaksIntoTheSameLines() throws {
        let document = try MarkdownDocument.parse(page)
        let standard = MarkdownSnapshot.layOut(document, width: 2000)
        XCTAssertEqual(standard.columnWidth, 900)
        XCTAssertGreaterThan(standard.layouts.map(\.lineCount).reduce(0, +), standard.layouts.count,
                             "some blocks wrap")
        for scale: CGFloat in [0.7, 1.5, 2] {
            let scaled = MarkdownSnapshot.layOut(document, width: 2000 * scale, typography: Typography(scale: scale))
            XCTAssertEqual(scaled.columnWidth, 900 * scale, accuracy: 0.001)
            XCTAssertEqual(scaled.layouts.map(\.lineCount), standard.layouts.map(\.lineCount), "at \(scale)")
            XCTAssertEqual(lineRanges(scaled), lineRanges(standard), "at \(scale)")
            XCTAssertEqual(scaled.totalHeight, standard.totalHeight * scale, accuracy: 2)
        }
        let wide = MarkdownSnapshot.layOut(document, width: 3000, typography: Typography(scale: 1.5))
        XCTAssertEqual(wide.columnWidth, 1350)
    }

    /// Waits for the view's next complete snapshot laid out with `typography`.
    @discardableResult
    private func waitForComplete(_ view: MarkdownPreviewView, typography: Typography,
                                 change: () -> Void) -> Timings? {
        let installed = expectation(description: "installed")
        let original = view.pipeline.onOutcome
        var timings: Timings?
        view.pipeline.onOutcome = { outcome in
            original?(outcome)
            if case .snapshot(let snapshot, _, let received) = outcome, snapshot.isComplete,
               snapshot.typography === typography {
                timings = received
                installed.fulfill()
            }
        }
        change()
        wait(for: [installed], timeout: 10)
        view.pipeline.onOutcome = original
        return timings
    }

    func testSettingATypographyLaysTheSourceOutAgain() throws {
        let view = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let source = (0..<80).map { "## Section \($0)\n\nParagraph \($0) with enough words to wrap across the column." }
            .joined(separator: "\n\n")
        waitForComplete(view, typography: .standard) { view.setSource(source) }
        let before = view.snapshot
        let index = 40
        view.setScrollOffset(before.blockTops[index])
        let runs = view.pipeline.runs
        let double = Typography(scale: 2)
        waitForComplete(view, typography: double) { view.typography = double }
        XCTAssertTrue(view.typography === double)
        XCTAssertEqual(view.pipeline.runs - runs, 1, "one update, no parse")
        let after = view.snapshot
        XCTAssertTrue(after.typography === double)
        XCTAssertEqual(after.document.blocks, before.document.blocks)
        // A heading that fits on one line at both sizes.
        XCTAssertEqual(after.layouts[0].height, 2 * before.layouts[0].height, accuracy: 0.5)
        XCTAssertGreaterThan(after.totalHeight, 1.5 * before.totalHeight)
        // The block that was at the top still is.
        XCTAssertEqual(view.contentView.bounds.minY, after.blockTops[index], accuracy: 1)

        // The same instance again starts nothing.
        let settled = view.pipeline.runs
        view.typography = double
        XCTAssertEqual(view.pipeline.runs, settled)
    }

    func testASnapshotOfAnotherScaleLendsNoLayouts() throws {
        let view = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let first = (0..<30).map { "Paragraph \($0) with some words." }.joined(separator: "\n\n")
        waitForComplete(view, typography: .standard) { view.setSource(first) }
        let saved = view.snapshot
        waitForComplete(view, typography: .standard) { view.setSource("# Other") }
        let large = Typography(scale: 1.5)
        waitForComplete(view, typography: large) { view.typography = large }
        let timings = waitForComplete(view, typography: large) { view.setSource(first, reusing: saved) }
        XCTAssertTrue(view.snapshot.typography === large)
        XCTAssertFalse(zip(view.snapshot.layouts, saved.layouts).contains { $0 === $1 })
        let expected = MarkdownSnapshot.layOut(saved.document, width: 600, typography: large)
        XCTAssertEqual(view.snapshot.blockTops, expected.blockTops)
        XCTAssertEqual(timings?.reusedBlocks, 0)
    }
}
