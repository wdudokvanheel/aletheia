import AppKit
import XCTest
@testable import MarkdownView

/// Code blocks wider than their box scroll horizontally on their own, from
/// the scroll wheel or a trackpad gesture, and keep working with selection.
@MainActor
final class CodeScrollViewTests: XCTestCase {
    private var window: NSWindow!
    private var view: MarkdownPreviewView!
    private var canvas: MarkdownDocumentView { view.documentView as! MarkdownDocumentView }
    private let code = "```\n" + (0..<120).map { "token\($0)" }.joined(separator: " ") + "\nshort line\n```"
    private var source: String { "Intro paragraph.\n\n" + code + "\n\nOutro paragraph." }
    private let id = CodeBlockID(block: 1, code: 0)

    override func setUp() async throws {
        // At the screen's origin, window and screen coordinates agree.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
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
        view.onInstall = { snapshot in
            if snapshot.isComplete, snapshot.document.source == text { installed.fulfill() }
        }
        view.setSource(text)
        wait(for: [installed], timeout: 5)
        view.onInstall = nil
    }

    private var codeCenter: CGPoint {
        let box = view.snapshot.codeBlockRect(id)!
        return CGPoint(x: box.midX, y: box.midY)
    }

    /// A pixel-precise scroll event at `point` (canvas coordinates), with an
    /// optional gesture or momentum phase as the trackpad sends them.
    private func scroll(at point: CGPoint, dx: Int32, dy: Int32 = 0, phase: Int64? = nil, momentum: Int64? = nil) {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
        let screen = window.convertPoint(toScreen: canvas.convert(point, to: nil))
        event.location = CGPoint(x: screen.x, y: NSScreen.screens[0].frame.height - screen.y)
        if let phase { event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase) }
        if let momentum { event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum) }
        canvas.scrollWheel(with: NSEvent(cgEvent: event)!)
    }

    private var offset: CGFloat { canvas.codeOffsets[id] ?? 0 }

    func testHorizontalScrollOverACodeBlockMovesOnlyThatBlock() throws {
        load(source)
        let maximum = try XCTUnwrap(view.snapshot.codeBlockLayout(id)).maxOffset
        XCTAssertGreaterThan(maximum, 500)
        let top = view.contentView.bounds.minY
        scroll(at: codeCenter, dx: -120)
        XCTAssertEqual(offset, 120)
        XCTAssertEqual(canvas.codeScroller, id, "the overlay scroller shows while it moves")
        XCTAssertEqual(view.contentView.bounds.minY, top)
        scroll(at: codeCenter, dx: 50)
        XCTAssertEqual(offset, 70)
        scroll(at: codeCenter, dx: -100_000)
        XCTAssertEqual(offset, maximum, "clamped to the widest line")
        scroll(at: codeCenter, dx: 100_000)
        XCTAssertNil(canvas.codeOffsets[id])
        // Over a paragraph, horizontal movement does nothing to code blocks.
        let paragraph = CGPoint(x: view.snapshot.columnX + 20, y: view.snapshot.blockTops[0] + 5)
        scroll(at: paragraph, dx: -120)
        XCTAssertTrue(canvas.codeOffsets.isEmpty)
    }

    func testAGestureKeepsTheAxisOfItsFirstMovementThroughItsMomentum() {
        load(source)
        let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4
        scroll(at: codeCenter, dx: 0, phase: began)
        scroll(at: codeCenter, dx: -40, dy: -5, phase: changed)
        XCTAssertEqual(offset, 40)
        // Turning mostly vertical keeps scrolling the code block sideways.
        scroll(at: codeCenter, dx: -10, dy: -30, phase: changed)
        XCTAssertEqual(offset, 50)
        scroll(at: codeCenter, dx: 0, phase: ended)
        scroll(at: codeCenter, dx: -20, momentum: 1)
        scroll(at: codeCenter, dx: -20, momentum: 2)
        XCTAssertEqual(offset, 90)
        scroll(at: codeCenter, dx: 0, momentum: 3)
        // A gesture that starts vertically scrolls the document, even sideways later.
        scroll(at: codeCenter, dx: 0, phase: began)
        scroll(at: codeCenter, dx: 0, dy: -20, phase: changed)
        scroll(at: codeCenter, dx: -60, dy: 0, phase: changed)
        scroll(at: codeCenter, dx: 0, phase: ended)
        XCTAssertEqual(offset, 90)
    }

    func testTheOverlayScrollerHidesAfterScrolling() {
        load(source)
        scroll(at: codeCenter, dx: -80)
        XCTAssertEqual(canvas.codeScroller, id)
        let knob = canvas.scrollerRect(of: id)
        XCTAssertNotNil(knob)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: MarkdownDocumentView.codeScrollerDuration + 0.3))
        XCTAssertNil(canvas.codeScroller)
        XCTAssertEqual(offset, 80, "the offset stays")
    }

    func testClickingInAScrolledCodeBlockSelectsTheTextUnderThePointer() throws {
        load(source)
        scroll(at: codeCenter, dx: -200)
        let snapshot = view.snapshot
        let line = snapshot.layouts[1].lines[0]
        let point = CGPoint(x: snapshot.columnX + line.x + 30, y: snapshot.blockTops[1] + line.top + line.height / 2)
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        canvas.mouseDown(with: mouse(.leftMouseDown, point, clicks: 2))
        canvas.mouseUp(with: mouse(.leftMouseUp, point, clicks: 2))
        let index = CTLineGetStringIndexForPosition(line.line, CGPoint(x: 230, y: 0))
        let expected = snapshot.unitRange(at: TextPosition(block: 1, offset: index), granularity: .word)
        XCTAssertEqual(view.selection, expected)
        XCTAssertTrue(view.selectedText.hasPrefix("token"), view.selectedText)
    }

    func testAnEditElsewhereKeepsTheOffsetAndAnEditToTheBlockResetsIt() {
        load(source)
        scroll(at: codeCenter, dx: -150)
        load("A new first paragraph.\n\n" + source)
        XCTAssertEqual(canvas.codeOffsets, [CodeBlockID(block: 2, code: 0): 150])
        load("A new first paragraph.\n\n" + source.replacingOccurrences(of: "token1 ", with: "tokenOne "))
        XCTAssertTrue(canvas.codeOffsets.isEmpty)
    }
}
