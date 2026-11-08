import AppKit
import XCTest
@testable import MarkdownView

/// Images in the model and in layout: the alt text stays in the display
/// text, and loaded sizes from `ImageSizes` put the images in its place.
/// Sizes are those of the generated fixtures: `valid.png` is 64 x 48, the
/// small images 16 x 16, and the remote block images as their names say.
final class ImageLayoutTests: XCTestCase {
    private let width: CGFloat = 700

    private func snapshot(_ source: String, _ sizes: [String: CGSize] = [:]) throws -> MarkdownSnapshot {
        MarkdownSnapshot.layOut(try MarkdownDocument.parse(source), width: width, images: ImageSizes(sizes))
    }

    private func images(on line: LineLayout) -> [CGRect] {
        line.decorations.filter { $0.kind == .image }.map(\.rect)
    }

    private var body: (ascent: CGFloat, descent: CGFloat) {
        let font = Typography.standard.fonts[Int(TextRole.body.rawValue)]
        return (CTFontGetAscent(font), CTFontGetDescent(font))
    }

    func testImagesKeepTheirAltTextInTheDisplayText() throws {
        let source = "An inline ![PNG, inline](files/valid.png) image and ![](files/empty.png)."
        let block = try XCTUnwrap(MarkdownDocument.parse(source).blocks.first)
        XCTAssertEqual(block.text, "An inline PNG, inline image and \u{FFFC}.")
        XCTAssertEqual(block.images, [InlineImage(range: 10..<21, source: "files/valid.png"),
                                      InlineImage(range: 32..<33, source: "files/empty.png")])
        XCTAssertTrue(block.styleRuns.contains { $0.range == 10..<21 && $0.styles == .image })
        // The source map is the alt text's; an image without alt text maps to its `!`.
        XCTAssertEqual(block.sourceOffset(forDisplayOffset: 10), 12)
        XCTAssertEqual(block.sourceOffset(forDisplayOffset: 32), 52)
        XCTAssertEqual(block.sourceOffset(forDisplayOffset: 33), 72)
        // Alt text is muted, in a link too.
        XCTAssertEqual(ColorIndex.of(.body, .image), TextRole.quote.rawValue)
        XCTAssertEqual(ColorIndex.of(.body, [.link, .image]), TextRole.quote.rawValue)
        XCTAssertEqual(ColorIndex.of(.body, .link), ColorIndex.link)
        // Until loaded, it is text on the line, and nothing is placed.
        let unloaded = try snapshot(source)
        XCTAssertFalse(unloaded.layouts[0].drawsImages)
        XCTAssertEqual(unloaded.layouts[0].lines.count, 1)
        XCTAssertEqual(unloaded.layouts[0].height, Typography.standard.lineHeight(.body))
        // The place of an image without alt text takes no space, and its line
        // is drawn run by run, past it.
        let placeholder = try snapshot("![](files/empty.png)")
        let line = try XCTUnwrap(placeholder.layouts[0].lines.first)
        XCTAssertNil(line.color)
        XCTAssertEqual(CTLineGetTypographicBounds(line.line, nil, nil, nil), 0)
        XCTAssertTrue(images(on: line).isEmpty)
    }

    func testAnImageAloneInAParagraphIsAsTallAsItsScaledNaturalSize() throws {
        let remote = "https://img.example.invalid/block/1600x900.png"
        let source = "![PNG, block](files/valid.png)\n\n![1600 x 900 png](\(remote))\n\n[![Linked](l.png)](https://x.test)"
        let unloaded = try snapshot(source)
        let loaded = try snapshot(source, ["files/valid.png": CGSize(width: 64, height: 48),
                                           remote: CGSize(width: 1600, height: 900), "l.png": CGSize(width: 300, height: 100)])
        let column = loaded.columnWidth
        XCTAssertEqual(loaded.layouts.map(\.height), [48, 900 * column / 1600, 100])
        XCTAssertEqual(images(on: loaded.layouts[1].lines[0]),
                       [CGRect(x: 0, y: 0, width: column, height: 900 * column / 1600)])
        XCTAssertEqual(loaded.layouts[1].imageWidths, [column])
        XCTAssertTrue(loaded.isComplete)
        // Layouts are final only for the sizes they were laid out with.
        let block = loaded.document.blocks[0]
        XCTAssertFalse(unloaded.layouts[0].isFinal(for: column, images: loaded.images, block: block))
        XCTAssertTrue(unloaded.layouts[0].isFinal(for: column, images: unloaded.images, block: block))
        // A linked image is not underlined, and it opens its link.
        let linked = loaded.layouts[2].lines[0]
        XCTAssertFalse(linked.decorations.contains { $0.kind == .underline })
        let point = CGPoint(x: loaded.columnX + 150, y: loaded.blockTops[2] + 50)
        XCTAssertEqual(loaded.linkDestination(at: point), "https://x.test")
    }

    func testInlineImagesSitOnTheBaselineAndGrowTheLineLikeCSS() throws {
        let source = "Text ![PNG, inline](files/valid.png) and ![badge](b.svg) more text after it."
        let loaded = try snapshot(source, ["files/valid.png": CGSize(width: 64, height: 48),
                                           "b.svg": CGSize(width: 80, height: 20)])
        let line = loaded.layouts[0].lines[0]
        let rects = images(on: line)
        XCTAssertEqual(rects.map(\.size), [CGSize(width: 64, height: 48), CGSize(width: 80, height: 20)])
        for rect in rects { XCTAssertEqual(rect.maxY, line.baseline, accuracy: 0.001) }
        // The strut's half of the line below the baseline stays; the tallest image raises the top.
        let lineHeight = Typography.standard.lineHeight(.body)
        let strutAbove = body.ascent + (lineHeight - body.ascent - body.descent) / 2
        XCTAssertEqual(line.baseline - line.top, 48, accuracy: 0.01)
        XCTAssertEqual(line.height, 48 + lineHeight - strutAbove, accuracy: 0.01)
        // Text after an image starts at its right edge.
        XCTAssertEqual(CTLineGetOffsetForStringIndex(line.line, 16, nil), rects[0].maxX, accuracy: 0.001)
        // A badge shorter than the strut keeps the line height.
        let badge = try snapshot("A ![b](b.svg) badge.", ["b.svg": CGSize(width: 80, height: 14)])
        XCTAssertEqual(badge.layouts[0].lines[0].height, lineHeight, accuracy: 0.001)
        // An image wider than the column shrinks to fit it, on a line of its own.
        let wide = try snapshot("Before ![wide](w.png) after.", ["w.png": CGSize(width: 2000, height: 1000)])
        let column = wide.columnWidth
        let placed = wide.layouts[0].lines.flatMap(images(on:))
        XCTAssertEqual(placed.map(\.size), [CGSize(width: column, height: column / 2)])
        XCTAssertEqual(wide.layouts[0].lines.map { $0.decorations.contains { $0.kind == .image } }, [false, true, false])
        // Twenty 16 x 16 images to a line, as in images-500.md, keep the body line height.
        let row = (0..<20).map { "![s\($0)](small/\(String(format: "%03d", $0)).png)" }.joined(separator: " ")
        let small = try snapshot("Row 1: \(row) text.", Dictionary(uniqueKeysWithValues: (0..<20).map {
            ("small/\(String(format: "%03d", $0)).png", CGSize(width: 16, height: 16))
        }))
        XCTAssertEqual(small.layouts[0].lines.flatMap(images(on:)).count, 20)
        XCTAssertTrue(small.layouts[0].lines.allSatisfy { abs($0.height - lineHeight) < 0.001 })
    }

    func testAnImageSelectsAndCopiesAsItsAltText() throws {
        let source = "Before ![PNG, inline](files/valid.png) after. ![](x.png)"
        let loaded = try snapshot(source, ["files/valid.png": CGSize(width: 64, height: 48),
                                           "x.png": CGSize(width: 10, height: 10)])
        XCTAssertEqual(loaded.text(in: try XCTUnwrap(loaded.fullRange)), "Before PNG, inline after. ")
        let line = loaded.layouts[0].lines[0]
        let rect = try XCTUnwrap(images(on: line).first)
        let y = loaded.blockTops[0] + line.top + line.height / 2
        let left = loaded.columnX + line.x + rect.minX
        // A click on an image lands before or after its alt text, never inside.
        XCTAssertEqual(loaded.position(at: CGPoint(x: left + 10, y: y)), TextPosition(block: 0, offset: 7))
        XCTAssertEqual(loaded.position(at: CGPoint(x: left + 54, y: y)), TextPosition(block: 0, offset: 18))
        // A double-click selects all of it.
        XCTAssertEqual(loaded.unitRange(at: TextPosition(block: 0, offset: 9), granularity: .word),
                       TextPosition(block: 0, offset: 7)..<TextPosition(block: 0, offset: 18))
        // Its selection highlight covers the image.
        let selected = loaded.selectionRects(for: TextPosition(block: 0, offset: 7)..<TextPosition(block: 0, offset: 18),
                                             minY: 0, maxY: 1000)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected[0].width, 64, accuracy: 0.001)
    }

    func testImagesInTableCellsGrowTheirRow() throws {
        let badge = "https://docs.rs/objc2-ar-kit/badge.svg"
        let source = "| Crate | Docs.rs |\n| --- | --- |\n| `objc2-ar-kit` | [![docs.rs](\(badge))](https://docs.rs/objc2-ar-kit/) |"
        let plain = try snapshot(source)
        let loaded = try snapshot(source, [badge: CGSize(width: 88, height: 40)])
        XCTAssertFalse(plain.layouts[0].drawsImages)
        XCTAssertTrue(loaded.layouts[0].drawsImages)
        let table = loaded.layouts[0].tables[0]
        let line = try XCTUnwrap(table.rows[1].lines(ofCell: 1).first)
        XCTAssertEqual(images(on: line).map(\.size), [CGSize(width: 88, height: 40)])
        // A cell holding only an image is as tall as the image.
        XCTAssertEqual(table.rows[1].contentHeight, 40)
        XCTAssertEqual(loaded.layouts[0].height - plain.layouts[0].height, 40 - Typography.standard.lineHeight(.body),
                       accuracy: 0.01)
        XCTAssertGreaterThan(loaded.layouts[0].imageWidths[0], 88)
        // The image opens its link.
        let origin = loaded.tableOrigin(table, inBlock: 0, [:])
        let text = table.textOrigin(row: 1, column: 1)
        let point = CGPoint(x: origin.x + text.x + table.alignmentOffset(of: line, row: 1, column: 1) + 40,
                            y: origin.y + text.y + 20)
        XCTAssertEqual(loaded.linkDestination(at: point), "https://docs.rs/objc2-ar-kit/")
    }

    func testAnImageWiderThanItsWrappedColumnShrinksToIt() throws {
        let description = String(repeating: "long words ", count: 40)
        let source = "| Description | Links |\n| --- | --- |\n| \(description) | [![play](play.svg)](https://x.test) |"
        let loaded = try snapshot(source, ["play.svg": CGSize(width: 400, height: 40)])
        let table = loaded.layouts[0].tables[0]
        let width = table.columnWidths[1]
        XCTAssertLessThan(width, 400)
        let rects = table.rows[1].lines(ofCell: 1).flatMap(images(on:))
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].width, width, accuracy: 0.001)
        XCTAssertEqual(rects[0].height, 40 * width / 400, accuracy: 0.001)
        XCTAssertLessThanOrEqual(table.width, table.rect.width, "the table still fits")
    }

    func testLoadingAnImageRelaysOutOnlyItsBlock() throws {
        var paragraphs = (0..<30).map { "Paragraph \($0) with a few words in it." }
        paragraphs[12] = "![Image](i.png)"
        let source = paragraphs.joined(separator: "\n\n")
        let base = try snapshot(source)
        let sizes = ImageSizes(["i.png": CGSize(width: 200, height: 150)])
        let update = try MarkdownSnapshot.updating(base, to: source, width: width, images: sizes)
        XCTAssertEqual(update.reused, 29)
        XCTAssertEqual(update.laidOut, 1)
        XCTAssertEqual(update.snapshot.layouts.indices.filter { update.snapshot.layouts[$0] !== base.layouts[$0] }, [12])
        XCTAssertEqual(update.snapshot.layouts[12].height, 150)
        // Relaid out with the same sizes, everything stays.
        let again = try MarkdownSnapshot.updating(update.snapshot, to: source, width: width, images: sizes)
        XCTAssertEqual(again.laidOut, 0)
        // A relayout of the same blocks keeps the first block in view in place.
        let y = base.blockTops[14] + 5
        let anchored = update.snapshot.sameBlocksAnchoredY(y, height: 400, from: base)
        XCTAssertEqual(update.snapshot.blockTops[14] - anchored, base.blockTops[14] - y)
        XCTAssertEqual(update.snapshot.sameBlocksAnchoredY(0, height: 400, from: base), 0)
    }
}
