import AppKit
import XCTest
@testable import MarkdownView

@MainActor
final class LinkViewTests: XCTestCase {
    private var window: NSWindow!
    private var view: MarkdownPreviewView!
    private var canvas: MarkdownDocumentView { view.documentView as! MarkdownDocumentView }
    private var opened: [String] = []

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = MarkdownPreviewView(frame: window.contentLayoutRect)
        window.contentView = view
        opened = []
        view.onOpenLink = { [weak self] in self?.opened.append($0) }
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        view = nil
    }

    private func load(_ text: String = "Read the [linked words here](docs/guide.md) and more text after it.") {
        let installed = expectation(description: "installed")
        installed.assertForOverFulfill = false
        view.onInstall = { snapshot in
            if snapshot.isComplete, !snapshot.layouts.isEmpty { installed.fulfill() }
        }
        view.setSource(text)
        wait(for: [installed], timeout: 5)
        view.onInstall = nil
    }

    /// A point at mid-height of the first block's line holding `offset`, `dx` right of its caret.
    private func point(_ offset: Int, dx: CGFloat = 1) -> CGPoint {
        let snapshot = view.snapshot
        let layout = snapshot.layouts[0]
        let line = layout.lines[layout.lineIndex(containing: offset, upstream: false)]
        let x = CTLineGetOffsetForStringIndex(line.line, offset, nil)
        return CGPoint(x: snapshot.columnX + line.x + x + dx, y: snapshot.blockTops[0] + line.top + line.height / 2)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: flags,
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func click(at start: CGPoint, dragTo end: CGPoint? = nil, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        canvas.mouseDown(with: event(.leftMouseDown, at: start, clicks: clicks, flags: flags))
        if let end { canvas.mouseDragged(with: event(.leftMouseDragged, at: end, clicks: clicks, flags: flags)) }
        canvas.mouseUp(with: event(.leftMouseUp, at: end ?? start, clicks: clicks, flags: flags))
    }

    func testClickOnALinkOpensItsDestination() {
        load()
        XCTAssertEqual(view.snapshot.document.blocks[0].text, "Read the linked words here and more text after it.")
        click(at: point(12))
        XCTAssertEqual(opened, ["docs/guide.md"])
        XCTAssertNil(view.selection)
        // A small wobble is still a click.
        click(at: point(12), dragTo: point(12, dx: 3))
        XCTAssertEqual(opened, ["docs/guide.md", "docs/guide.md"])
        XCTAssertNil(view.selection)
        // Outside the link text nothing opens.
        click(at: point(2))
        click(at: point(40))
        XCTAssertEqual(opened.count, 2)
    }

    func testDragStartingOnALinkSelectsInsteadOfOpening() {
        load()
        click(at: point(9, dx: 1), dragTo: point(35))
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(view.selectedText, "linked words here and more")
    }

    func testDoubleAndTripleClickOnALinkSelect() {
        load()
        // The first click of a double-click opens, as in WebKit; the second selects.
        click(at: point(17))
        click(at: point(17), clicks: 2)
        XCTAssertEqual(view.selectedText, "words")
        click(at: point(17), clicks: 3)
        XCTAssertEqual(view.selectedText, "Read the linked words here and more text after it.")
        XCTAssertEqual(opened.count, 1)
        // Shift-click on a link extends the selection without opening.
        click(at: point(1), dragTo: point(4))
        opened = []
        click(at: point(12), flags: .shift)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(view.selectedText, "ead the lin")
    }

    func testClearSelection() {
        load()
        canvas.selectAll(nil)
        XCTAssertNotNil(view.selection)
        view.clearSelection()
        XCTAssertNil(view.selection)
        XCTAssertNil(canvas.selectionAnchor)
    }
}
