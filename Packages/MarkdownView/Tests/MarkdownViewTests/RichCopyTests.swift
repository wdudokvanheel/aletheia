import AppKit
import XCTest
@testable import MarkdownView

/// Copy writes plain text at once and RTF and HTML on demand; the selected
/// text drags out with the same flavors, only from inside the selection.
@MainActor
final class RichCopyTests: XCTestCase {
    private var window: NSWindow!
    private var view: MarkdownPreviewView!
    private var canvas: MarkdownDocumentView { view.documentView as! MarkdownDocumentView }

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = MarkdownPreviewView(frame: window.contentLayoutRect)
        window.contentView = view
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        view = nil
    }

    private func load(_ text: String) {
        let installed = expectation(description: "installed")
        installed.assertForOverFulfill = false
        let original = view.pipeline.onOutcome
        view.pipeline.onOutcome = { [view] outcome in
            original?(outcome)
            if view!.snapshot.isComplete, !view!.snapshot.layouts.isEmpty { installed.fulfill() }
        }
        view.setSource(text)
        wait(for: [installed], timeout: 5)
        view.pipeline.onOutcome = original
    }

    /// What Copy writes for the current selection, on a private pasteboard.
    private func copied() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("RichCopyTests-\(UUID().uuidString)"))
        XCTAssertTrue(canvas.writeCopy(to: pasteboard))
        addTeardownBlock { @MainActor in pasteboard.releaseGlobally() }
        return pasteboard
    }

    private func rtf(_ pasteboard: NSPasteboard) throws -> NSAttributedString {
        let data = try XCTUnwrap(pasteboard.data(forType: .rtf))
        return try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
    }

    private func font(in text: NSAttributedString, at substring: String) throws -> NSFont {
        let range = (text.string as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, substring)
        return try XCTUnwrap(text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    }

    func testInlineFormattingInRTFAndHTML() throws {
        load("# Title\n\nSome **bold** and *italic*, ~~gone~~, `code` and [a link](https://example.com/a?b=1&c) or [local](notes.md).")
        canvas.selectAll(nil)
        let pasteboard = copied()
        XCTAssertEqual(pasteboard.types?.contains(.rtf), true)
        XCTAssertEqual(pasteboard.types?.contains(.html), true)
        let plain = "Title\nSome bold and italic, gone, code and a link or local."
        XCTAssertEqual(pasteboard.string(forType: .string), plain)

        let rich = try rtf(pasteboard)
        XCTAssertEqual(rich.string, plain)
        XCTAssertTrue(try font(in: rich, at: "bold").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(try font(in: rich, at: "Some").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(try font(in: rich, at: "italic").fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertTrue(try font(in: rich, at: "code").fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertGreaterThan(try font(in: rich, at: "Title").pointSize, try font(in: rich, at: "Some").pointSize)
        let gone = (rich.string as NSString).range(of: "gone")
        XCTAssertEqual(rich.attribute(.strikethroughStyle, at: gone.location, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        let link = (rich.string as NSString).range(of: "a link")
        XCTAssertEqual((rich.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString,
                       "https://example.com/a?b=1&c")
        let local = (rich.string as NSString).range(of: "local")
        XCTAssertNil(rich.attribute(.link, at: local.location, effectiveRange: nil), "only web and mail links")

        let html = try XCTUnwrap(pasteboard.string(forType: .html))
        XCTAssertTrue(html.contains("<h1>Title</h1>"), html)
        XCTAssertTrue(html.contains("<strong>bold</strong>"), html)
        XCTAssertTrue(html.contains("<em>italic</em>"), html)
        XCTAssertTrue(html.contains("<del>gone</del>"), html)
        XCTAssertTrue(html.contains("<code>code</code>"), html)
        XCTAssertTrue(html.contains("<a href=\"https://example.com/a?b=1&amp;c\">a link</a>"), html)
        XCTAssertTrue(html.contains(" or local.</p>"), html)
    }

    func testPartialSelectionAndCodeBlocks() throws {
        load("Before **strong text** after.\n\n```swift\nlet a = 1 < 2\n```")
        let paragraph = view.snapshot.document.blocks[0].text as NSString
        let start = paragraph.range(of: "ong").location
        canvas.setSelection(TextPosition(block: 0, offset: start)..<TextPosition(block: 1, offset: 5))
        let pasteboard = copied()
        XCTAssertEqual(pasteboard.string(forType: .string), "ong text after.\nlet a")
        let html = try XCTUnwrap(pasteboard.string(forType: .html))
        XCTAssertTrue(html.contains("<p><strong>ong text</strong> after.</p><pre><code>let a</code></pre>"), html)
        canvas.selectAll(nil)
        XCTAssertTrue(try XCTUnwrap(copied().string(forType: .html)).contains("<pre><code>let a = 1 &lt; 2</code></pre>"))
    }

    func testListsCopyWithoutMarkersAndTablesAsTables() throws {
        load("""
        - [x] done
        - second *item*

        | Name | Value |
        | --- | ---: |
        | a | **b** |
        | c | d |
        """)
        canvas.selectAll(nil)
        let pasteboard = copied()
        let plain = "done\nsecond item\nName\tValue\na\tb\nc\td"
        XCTAssertEqual(pasteboard.string(forType: .string), plain)
        XCTAssertEqual(try rtf(pasteboard).string, plain)
        let html = try XCTUnwrap(pasteboard.string(forType: .html))
        XCTAssertTrue(html.contains("<p>done</p><p>second <em>item</em></p>"), html)
        XCTAssertTrue(html.contains("<table><tr><th>Name</th><th align=\"right\">Value</th></tr>"
            + "<tr><td>a</td><td align=\"right\"><strong>b</strong></td></tr>"
            + "<tr><td>c</td><td align=\"right\">d</td></tr></table>"), html)
        XCTAssertFalse(html.contains("<li>"))

        // Within one cell, just its text.
        let table = view.snapshot.document.blocks[1].text as NSString
        let cell = table.range(of: "Value")
        canvas.setSelection(TextPosition(block: 1, offset: cell.location + 1)..<TextPosition(block: 1, offset: NSMaxRange(cell)))
        let inCell = try XCTUnwrap(copied().string(forType: .html))
        XCTAssertTrue(inCell.contains("<p>alue</p>") && !inCell.contains("<table>"), inCell)
    }

    // MARK: Dragging

    /// A point at mid-height of the line holding `offset` in `block`, `dx` right of its caret.
    private func point(_ block: Int, _ offset: Int, dx: CGFloat = 1) -> CGPoint {
        let snapshot = view.snapshot
        let layout = snapshot.layouts[block]
        let line = layout.lines[layout.lineIndex(containing: offset, upstream: false)]
        let x = CTLineGetOffsetForStringIndex(line.line, offset, nil)
        return CGPoint(x: snapshot.columnX + line.x + x + dx, y: snapshot.blockTops[block] + line.top + line.height / 2)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testDraggingStartsOnlyFromInsideTheSelection() throws {
        load("The first paragraph has several words.\n\nA second **paragraph** here.")
        var dragged: [NSDraggingItem] = []
        canvas.beginDragging = { _, items, _ in dragged = items }
        let selection = TextPosition(block: 0, offset: 4)..<TextPosition(block: 0, offset: 19)
        canvas.setSelection(selection)
        XCTAssertEqual(view.selectedText, "first paragraph")

        // From outside the selection, a drag selects.
        canvas.mouseDown(with: event(.leftMouseDown, at: point(0, 25)))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: point(0, 30)))
        canvas.mouseUp(with: event(.leftMouseUp, at: point(0, 30)))
        XCTAssertTrue(dragged.isEmpty)
        XCTAssertEqual(view.selection, TextPosition(block: 0, offset: 25)..<TextPosition(block: 0, offset: 30))

        // From inside it, the selected text drags out, after the pointer moves a little.
        canvas.setSelection(selection)
        canvas.mouseDown(with: event(.leftMouseDown, at: point(0, 8)))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: point(0, 8, dx: 2)))
        XCTAssertTrue(dragged.isEmpty, "within the drag distance")
        canvas.mouseDragged(with: event(.leftMouseDragged, at: point(1, 3)))
        canvas.mouseUp(with: event(.leftMouseUp, at: point(1, 3)))
        XCTAssertEqual(dragged.count, 1)
        XCTAssertEqual(view.selection, selection, "dragging keeps the selection")
        let item = try XCTUnwrap(dragged.first?.item as? NSPasteboardItem)
        XCTAssertEqual(item.string(forType: .string), "first paragraph")
        XCTAssertEqual(Set(item.types), [.string, .rtf, .html])
        XCTAssertFalse(dragged[0].draggingFrame.isEmpty)
        XCTAssertNotNil(dragged[0].imageComponents?.first?.contents)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("RichCopyTests-drag-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        XCTAssertTrue(try XCTUnwrap(pasteboard.string(forType: .html)).contains("first paragraph"))

        // A click inside the selection that does not drag selects nothing.
        dragged = []
        canvas.mouseDown(with: event(.leftMouseDown, at: point(0, 8)))
        canvas.mouseUp(with: event(.leftMouseUp, at: point(0, 8)))
        XCTAssertTrue(dragged.isEmpty)
        XCTAssertNil(view.selection)
    }
}
