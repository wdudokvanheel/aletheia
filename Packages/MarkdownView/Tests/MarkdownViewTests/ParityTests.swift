import AppKit
import XCTest
@testable import MarkdownView

/// Behaviors of the WebKit preview from `docs/markdown-parity-checklist.md`
/// that no other test covers directly.
final class ParityTests: XCTestCase {
    private let width: CGFloat = 700

    private func snapshot(_ source: String, _ sizes: [String: CGSize] = [:]) throws -> MarkdownSnapshot {
        MarkdownSnapshot.layOut(try MarkdownDocument.parse(source), width: width, images: ImageSizes(sizes))
    }

    /// The middle of the first line holding display offset `offset` of block
    /// `block`, one point right of its caret, in view coordinates.
    private func point(in snapshot: MarkdownSnapshot, _ block: Int, _ offset: Int) -> CGPoint {
        let layout = snapshot.layouts[block]
        let line = layout.lines[layout.lineIndex(containing: offset, upstream: false)]
        let x = CTLineGetOffsetForStringIndex(line.line, offset, nil)
        return CGPoint(x: snapshot.columnX + line.x + x + 1, y: snapshot.blockTops[block] + line.top + line.height / 2)
    }

    func testOutOfScopeSyntaxStaysLiteral() throws {
        let blocks = try MarkdownDocument.parse("""
        > [!NOTE]
        > An alert.

        Inline $x^2$ and

        $$
        y = 1
        $$

        ```mermaid
        graph TD; A-->B
        ```

        A note[^1] here.

        [^1]: The footnote.
        """).blocks
        // Soft breaks are spaces; the footnote line is no definition (its text is not a title).
        XCTAssertEqual(blocks.map(\.text), ["[!NOTE] An alert.", "Inline $x^2$ and", "$$ y = 1 $$", "graph TD; A-->B",
                                            "A note[^1] here.", "[^1]: The footnote."])
        XCTAssertTrue(blocks.allSatisfy(\.links.isEmpty))
        XCTAssertEqual(blocks[3].kind, .codeBlock)
    }

    func testFencedCodeDropsItsInfoStringAndIsNotHighlighted() throws {
        let block = try XCTUnwrap(MarkdownDocument.parse("```swift title=\"x\"\nlet a = \"b\" // c\n```").blocks.first)
        XCTAssertEqual(block.kind, .codeBlock)
        XCTAssertEqual(block.text, "let a = \"b\" // c")
        XCTAssertEqual(block.styleRuns, [StyleRun(range: 0..<16, role: .code)])
    }

    func testRawImageTagsShowNothing() throws {
        let blocks = try MarkdownDocument.parse("""
        <img src="logo.png" alt="Logo">

        Text <img src="inline.png" alt="inline"> after.
        """).blocks
        XCTAssertEqual(blocks.map(\.kind), [.htmlBlock, .paragraph])
        XCTAssertEqual(blocks[1].text, "Text  after.")
        XCTAssertTrue(blocks.allSatisfy(\.images.isEmpty))
    }

    func testLongUnbrokenWordsAndURLsWrapWithinTheColumn() throws {
        let word = String(repeating: "abcdefghij", count: 40)
        let url = "https://example.com/" + String(repeating: "segment", count: 50)
        let snapshot = try snapshot("\(word)\n\nSee <\(url)> here.")
        for index in 0..<2 {
            let layout = snapshot.layouts[index]
            XCTAssertGreaterThan(layout.lines.count, 3)
            for line in layout.lines {
                XCTAssertLessThanOrEqual(CTLineGetTypographicBounds(line.line, nil, nil, nil)
                                         - CTLineGetTrailingWhitespaceWidth(line.line), snapshot.columnWidth + 0.5)
            }
        }
    }

    func testLinksWithDisallowedDestinationsAreInert() throws {
        let source = "[js](javascript:alert(1)) [file](file:///etc/hosts) [ftp](ftp://x.test) [bad](http://[) "
            + "[web](https://x.test) [mail](mailto:a@x.test) [rel](notes.md) [frag](#part)"
        let snapshot = try snapshot(source)
        let block = snapshot.document.blocks[0]
        XCTAssertEqual(block.links.map(\.isLive), [false, false, false, false, true, true, true, true])
        // Every link keeps the link color.
        for link in block.links {
            XCTAssertTrue(block.styleRuns.contains { $0.range.overlaps(link.range) && $0.styles.contains(.link) })
        }
        let underlined = snapshot.layouts[0].lines.flatMap(\.decorations).filter { $0.kind == .underline }.map(\.tag)
        XCTAssertEqual(Set(underlined), [4, 5, 6, 7])
        for (index, link) in block.links.enumerated() {
            let destination = snapshot.linkDestination(at: point(in: snapshot, 0, link.range.lowerBound + 1))
            XCTAssertEqual(destination, link.isLive ? link.destination : nil, "link \(index)")
        }
    }

    func testLinkAndImageTitlesAreTooltips() throws {
        let source = #"[guide](docs/guide.md "The guide") [plain](x.md) ![pic](p.png "A picture") [![in](l.png)](y.md "Around")"#
        let snapshot = try snapshot(source, ["p.png": CGSize(width: 20, height: 10), "l.png": CGSize(width: 20, height: 10)])
        let block = snapshot.document.blocks[0]
        XCTAssertEqual(block.links.map(\.title), ["The guide", "", "Around"])
        XCTAssertEqual(block.images.map(\.title), ["A picture", ""])
        XCTAssertEqual(snapshot.toolTip(at: point(in: snapshot, 0, 1)), "The guide")
        XCTAssertNil(snapshot.toolTip(at: point(in: snapshot, 0, block.links[1].range.lowerBound + 1)))
        let images = snapshot.layouts[0].lines.flatMap(\.decorations).filter { $0.kind == .image }
        XCTAssertEqual(images.count, 2)
        let line = snapshot.layouts[0].lines[0]
        for (image, expected) in zip(images, ["A picture", "Around"]) {
            let center = CGPoint(x: snapshot.columnX + line.x + image.rect.midX, y: snapshot.blockTops[0] + image.rect.midY)
            XCTAssertEqual(snapshot.toolTip(at: center), expected)
        }
        // Between them, nothing.
        XCTAssertNil(snapshot.toolTip(at: CGPoint(x: snapshot.columnX + 1, y: snapshot.blockTops[0] - 5)))
    }

    @MainActor func testForceClickLooksUpTheSelectionOrTheWord() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MarkdownPreviewView(frame: window.contentLayoutRect)
        window.contentView = view
        let canvas = try XCTUnwrap(view.documentView as? MarkdownDocumentView)
        let installed = expectation(description: "installed")
        installed.assertForOverFulfill = false
        view.onInstall = { if $0.isComplete, !$0.layouts.isEmpty { installed.fulfill() } }
        view.setSource("Look up a word here.")
        wait(for: [installed], timeout: 5)
        let snapshot = view.snapshot
        XCTAssertEqual(canvas.lookUpRange(at: point(in: snapshot, 0, 11)).map(snapshot.text(in:)), "word")
        canvas.setSelection(TextPosition(block: 0, offset: 5)..<TextPosition(block: 0, offset: 15))
        XCTAssertEqual(canvas.lookUpRange(at: point(in: snapshot, 0, 11)).map(snapshot.text(in:)), "up a word ")
        XCTAssertEqual(canvas.lookUpRange(at: point(in: snapshot, 0, 1)).map(snapshot.text(in:)), "Look")
        XCTAssertNil(canvas.lookUpRange(at: CGPoint(x: 2, y: 2)))
        // The tooltip owner answers for the point AppKit asks about.
        view.setSource(#"[guide](docs/guide.md "The guide")"#)
        let titled = expectation(description: "titled")
        titled.assertForOverFulfill = false
        view.onInstall = { if $0.isComplete, $0.document.blocks.first?.links.first?.title == "The guide" { titled.fulfill() } }
        wait(for: [titled], timeout: 5)
        XCTAssertEqual(canvas.view(canvas, stringForToolTip: 0, point: point(in: view.snapshot, 0, 2), userData: nil),
                       "The guide")
        XCTAssertEqual(canvas.view(canvas, stringForToolTip: 0, point: CGPoint(x: 2, y: 2), userData: nil), "")
        canvas.updateToolTip(at: point(in: view.snapshot, 0, 2))
        XCTAssertEqual(canvas.shownToolTip, "The guide")
        canvas.updateToolTip(at: CGPoint(x: 2, y: 2))
        XCTAssertNil(canvas.shownToolTip)
    }
}
