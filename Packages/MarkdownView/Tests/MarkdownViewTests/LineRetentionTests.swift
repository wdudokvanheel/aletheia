import CoreText
import XCTest
@testable import MarkdownView

/// Lines far from the view are dropped and typeset again when needed (F4, F5).
final class LineRetentionTests: XCTestCase {
    private let markdown = """
    # Lines that can be dropped

    \(String(repeating: "A paragraph long enough for several windows, with `code`, [links](https://example.com), **strong** and *emphasized* text. ", count: 220))

    - first item with `code`
    - second item, quite a bit longer so that it wraps onto another line at the width used here
      1. nested and numbered
      2. again

    > A quote with עברית and English, and مرحبا بالعالم.

    مرحبا بالعالم (hello) 123.

    ```swift
    let tab =\t"value" // 1392 بهمن 22
    print(tab)
    ```

    | Name | Value | Note |
    |------|------:|:----:|
    | alpha | 1 | `code` cell with a [link](https://example.com) |
    | نص عربي | 2 | wraps \(String(repeating: "word ", count: 60)) |
    | ![badge](badge.png) | 3 | 👍`x` |
    """

    private static func lines(of snapshot: MarkdownSnapshot) -> [LineLayout] {
        snapshot.layouts.flatMap { $0.lines + $0.tables.flatMap { $0.rows.flatMap(\.lines) } }
    }

    /// What drawing and hit-testing a line depend on.
    private static func fingerprint(_ line: LineLayout) -> [Double] {
        let ctLine = line.line
        var values = [CTLineGetTypographicBounds(ctLine, nil, nil, nil), CTLineGetTrailingWhitespaceWidth(ctLine),
                      Double(CTLineGetGlyphCount(ctLine))]
        for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var positions = [CGPoint](repeating: .zero, count: count)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            let range = CTRunGetStringRange(run)
            values += [Double(range.location), Double(range.length)]
            values += positions.map { Double($0.x) } + glyphs.map { Double($0) }
        }
        return values
    }

    func testDroppedLinesAreTypesetAgainExactlyAsLaidOut() throws {
        let document = try MarkdownDocument.parse(markdown)
        let images = ImageSizes(["badge.png": CGSize(width: 80, height: 20)])
        for width: CGFloat in [700, 260] {
            let snapshot = MarkdownSnapshot.layOut(document, width: width, images: images)
            let lines = Self.lines(of: snapshot)
            XCTAssertGreaterThan(Set(lines.map { ObjectIdentifier($0.lineSet) }).count, 3, "several windows and runs")
            let before = lines.map(Self.fingerprint)
            LineCache.trim(to: 0, sparingMilliseconds: 0)
            XCTAssertFalse(lines.contains { $0.lineSet.isKept }, "every line dropped")
            XCTAssertEqual(lines.map(Self.fingerprint), before)
            XCTAssertTrue(lines.allSatisfy { $0.lineSet.isKept })
        }
    }

    func testHitTestingAndSelectionWorkOnDroppedLines() throws {
        let snapshot = MarkdownSnapshot.layOut(try MarkdownDocument.parse(markdown), width: 700)
        let full = try XCTUnwrap(snapshot.fullRange)
        let rects = snapshot.selectionRects(for: full, minY: 0, maxY: snapshot.totalHeight)
        let points = stride(from: CGFloat(0), to: snapshot.totalHeight, by: 37).map { CGPoint(x: 300, y: $0) }
        let positions = points.map { snapshot.position(at: $0) }
        LineCache.trim(to: 0, sparingMilliseconds: 0)
        XCTAssertEqual(snapshot.selectionRects(for: full, minY: 0, maxY: snapshot.totalHeight), rects)
        LineCache.trim(to: 0, sparingMilliseconds: 0)
        XCTAssertEqual(points.map { snapshot.position(at: $0) }, positions)
    }

    func testLinesLaidOutAheadStayWithinTheBudget() throws {
        // Far more lines than the budget holds, laid out as an open's second
        // step lays them out: ahead of being drawn.
        let paragraph = String(repeating: "Prose that wraps over many lines in a long document. ", count: 40)
        let document = try MarkdownDocument.parse(Array(repeating: paragraph, count: 1_500).joined(separator: "\n\n"))
        let layouts = try XCTUnwrap(BlockLayout.layOut(document.blocks, filling: Array(repeating: nil, count: document.blocks.count),
                                                       columnWidth: 700, typography: .standard, linesWarm: false))
        let deadline = ContinuousClock.now + .seconds(5)
        while LineCache.keptCost > LineCache.budget, ContinuousClock.now < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertLessThanOrEqual(LineCache.keptCost, LineCache.budget)
        // What was dropped is typeset again on demand.
        let last = try XCTUnwrap(layouts.last?.lines.last)
        XCTAssertGreaterThan(CTLineGetGlyphCount(last.line), 0)
    }

    func testTheViewPrefetchesLinesNearTheVisibleArea() throws {
        let snapshot = MarkdownSnapshot.layOut(try MarkdownDocument.parse(markdown), width: 700)
        LineCache.trim(to: 0, sparingMilliseconds: 0)
        let sets = snapshot.lineSets(intersecting: 0, 400)
        XCTAssertFalse(sets.isEmpty)
        XCTAssertTrue(sets.allSatisfy { !$0.isKept })
        LineCache.prefetch(sets)
        let deadline = ContinuousClock.now + .seconds(5)
        while !sets.allSatisfy(\.isKept), ContinuousClock.now < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(sets.allSatisfy(\.isKept))
    }

    func testListNumbersAreSharedAcrossLists() throws {
        let snapshot = MarkdownSnapshot.layOut(try MarkdownDocument.parse("1. a\n2. b\n\n---\n\n1. c\n2. d\n"), width: 700)
        let numbers = snapshot.layouts.flatMap(\.markers).compactMap { marker -> Int? in
            if case .number(let number) = marker.kind { return number }
            return nil
        }
        XCTAssertEqual(numbers, [1, 2, 1, 2])
        XCTAssertTrue(MarkerNumbers.line(1, typography: .standard) === MarkerNumbers.line(1, typography: .standard))
    }
}
