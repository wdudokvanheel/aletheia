import AppKit
import XCTest
@testable import MarkdownView

@MainActor
final class SelectionViewTests: XCTestCase {
    private var window: NSWindow!
    private var view: MarkdownPreviewView!
    private var canvas: MarkdownDocumentView { view.documentView as! MarkdownDocumentView }

    private let source = """
    # Heading

    The first paragraph has several words.

    - one
    - two

    Last paragraph.
    """

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
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

    /// A point at mid-height of the line holding `offset` in `block`, `dx` right of its caret.
    private func point(_ block: Int, _ offset: Int, dx: CGFloat = 1) -> CGPoint {
        let snapshot = view.snapshot
        let layout = snapshot.layouts[block]
        let line = layout.lines[layout.lineIndex(containing: offset, upstream: false)]
        let x = CTLineGetOffsetForStringIndex(line.line, offset, nil)
        return CGPoint(x: snapshot.columnX + line.x + x + dx, y: snapshot.blockTops[block] + line.top + line.height / 2)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: flags,
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func drag(from start: CGPoint, to end: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) {
        canvas.mouseDown(with: event(.leftMouseDown, at: start, clicks: clicks, flags: flags))
        if start != end { canvas.mouseDragged(with: event(.leftMouseDragged, at: end, clicks: clicks, flags: flags)) }
        canvas.mouseUp(with: event(.leftMouseUp, at: end, clicks: clicks, flags: flags))
    }

    private func pasteboardText() -> String? {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MarkdownViewTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        guard canvas.writeSelection(to: pasteboard, types: [.string]) else { return nil }
        return pasteboard.string(forType: .string)
    }

    private func isEnabled(_ action: Selector) -> Bool {
        canvas.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

    func testDragSelectsAcrossBlocksAndAClickClears() {
        load(source)
        drag(from: point(1, 4), to: point(2, 2))
        XCTAssertEqual(view.selection, TextPosition(block: 1, offset: 4)..<TextPosition(block: 2, offset: 2))
        XCTAssertEqual(view.selectedText, "first paragraph has several words.\non")
        XCTAssertEqual(pasteboardText(), "first paragraph has several words.\non")
        XCTAssertTrue(isEnabled(#selector(MarkdownDocumentView.copy(_:))))
        drag(from: point(1, 8), to: point(1, 8))
        XCTAssertNil(view.selection)
        XCTAssertFalse(isEnabled(#selector(MarkdownDocumentView.copy(_:))))
        XCTAssertNil(pasteboardText())
    }

    func testDoubleAndTripleClickSelectByWordAndParagraph() {
        load(source)
        drag(from: point(1, 6), to: point(1, 6), clicks: 2)
        XCTAssertEqual(view.selectedText, "first")
        // Dragging after a double-click extends by whole words.
        drag(from: point(1, 6), to: point(1, 18), clicks: 2)
        XCTAssertEqual(view.selectedText, "first paragraph")
        drag(from: point(1, 18), to: point(1, 6), clicks: 2)
        XCTAssertEqual(view.selectedText, "first paragraph")
        drag(from: point(2, 5), to: point(2, 5), clicks: 3)
        XCTAssertEqual(view.selectedText, "two")
        drag(from: point(1, 2), to: point(3, 2), clicks: 3)
        XCTAssertEqual(view.selectedText, "The first paragraph has several words.\none\ntwo\nLast paragraph.")
    }

    func testShiftClickExtendsFromTheFarEnd() {
        load(source)
        drag(from: point(1, 4), to: point(1, 9))
        XCTAssertEqual(view.selectedText, "first")
        drag(from: point(3, 4), to: point(3, 4), flags: .shift)
        XCTAssertEqual(view.selection, TextPosition(block: 1, offset: 4)..<TextPosition(block: 3, offset: 4))
        drag(from: point(0, 2), to: point(0, 2), flags: .shift)
        XCTAssertEqual(view.selection, TextPosition(block: 0, offset: 2)..<TextPosition(block: 3, offset: 4))
    }

    func testSelectAllAndMenuValidation() {
        load(source)
        XCTAssertTrue(isEnabled(#selector(NSResponder.selectAll(_:))))
        XCTAssertFalse(isEnabled(#selector(MarkdownDocumentView.copy(_:))))
        canvas.selectAll(nil)
        XCTAssertEqual(view.selectedText, "Heading\nThe first paragraph has several words.\none\ntwo\nLast paragraph.")
        XCTAssertTrue(isEnabled(#selector(MarkdownDocumentView.copy(_:))))
        XCTAssertTrue(canvas.validRequestor(forSendType: .string, returnType: nil) as AnyObject? === canvas)
        XCTAssertNil(canvas.validRequestor(forSendType: .string, returnType: .string))
    }

    func testContextMenuSelectsTheWordUnderThePointer() throws {
        load(source)
        let menu = try XCTUnwrap(canvas.menu(for: event(.rightMouseDown, at: point(1, 12))))
        XCTAssertEqual(view.selectedText, "paragraph")
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles.first, "Look Up “paragraph”")
        XCTAssertTrue(titles.contains("Copy"))
        // Inside the selection, the selection is kept.
        drag(from: point(1, 4), to: point(1, 19))
        _ = canvas.menu(for: event(.rightMouseDown, at: point(1, 12)))
        XCTAssertEqual(view.selectedText, "first paragraph")
    }

    func testSelectionSurvivesAnUpdateAbove() {
        load(source)
        drag(from: point(1, 10), to: point(1, 19))
        XCTAssertEqual(view.selectedText, "paragraph")
        load(source.replacingOccurrences(of: "# Heading", with: "# A longer heading\n\nAnd a new paragraph."))
        XCTAssertEqual(view.selection?.lowerBound.block, 2)
        XCTAssertEqual(view.selectedText, "paragraph")
        load("Something else entirely.")
        XCTAssertNil(view.selection)
    }

    func testDraggingBelowTheVisibleAreaAutoscrolls() {
        load((0..<80).map { "Paragraph \($0) with some words in it." }.joined(separator: "\n\n"))
        let start = point(0, 2)
        canvas.mouseDown(with: event(.leftMouseDown, at: start))
        let below = CGPoint(x: start.x, y: canvas.visibleRect.maxY + 30)
        canvas.mouseDragged(with: event(.leftMouseDragged, at: below))
        XCTAssertNotNil(canvas.autoscrollTimer)
        let before = view.contentView.bounds.minY
        let selectedBefore = view.selection?.upperBound
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        XCTAssertGreaterThan(view.contentView.bounds.minY, before)
        XCTAssertGreaterThan(try XCTUnwrap(view.selection?.upperBound), try XCTUnwrap(selectedBefore))
        canvas.mouseUp(with: event(.leftMouseUp, at: below))
        XCTAssertNil(canvas.autoscrollTimer)
    }

    func testSelectionDrawsBehindTextInTheSelectionColor() throws {
        load(source)
        view.palette.background = .white
        drag(from: point(1, 0), to: point(1, 9))
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / canvas.bounds.height
        // Sample in the line's top half-leading, above the glyphs.
        let line = try XCTUnwrap(view.snapshot.layouts[1].lines.first)
        let y = view.snapshot.blockTops[1] + line.top + 1
        // Raw components: the cached bitmap is tagged with a calibrated color
        // space, so converting it would shift the values drawn in sRGB.
        func color(atX x: CGFloat) -> NSColor? { bitmap.colorAt(x: Int(x * scale), y: Int(y * scale)) }
        var expected: NSColor?
        canvas.effectiveAppearance.performAsCurrentDrawingAppearance {
            expected = NSColor.unemphasizedSelectedTextBackgroundColor.usingColorSpace(.sRGB)
        }
        let system = try XCTUnwrap(expected)
        let highlight = try XCTUnwrap(color(atX: point(1, 4).x))
        XCTAssertEqual(highlight.redComponent, system.redComponent, accuracy: 0.03)
        XCTAssertEqual(highlight.blueComponent, system.blueComponent, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(color(atX: point(1, 20).x)).brightnessComponent, 1, accuracy: 0.01)
    }

    /// Measures the main-thread cost of one drag step: hit-testing, updating
    /// the selection, and redrawing the invalidated lines.
    func testDragRedrawCostPerFrame() throws {
        let paragraphs = (0..<400).map { index in
            index % 9 == 0 ? "## Section \(index)"
                : index % 9 == 4 ? "```\nlet value\(index) = compute(\(index))\nprint(value\(index))\n```"
                : "Paragraph \(index) " + String(repeating: "with enough words to wrap across lines ", count: 4)
        }
        load(paragraphs.joined(separator: "\n\n"))
        view.scrollFraction = 0.4
        let visible = canvas.visibleRect
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: visible))
        let start = CGPoint(x: visible.minX + 60, y: visible.minY + 20)
        canvas.beginSelection(at: start, clickCount: 1, extending: false)
        var durations: [Duration] = []
        let steps = 120
        for step in 1...steps {
            let point = CGPoint(x: visible.minX + 40 + CGFloat(step % 30) * 15,
                                y: visible.minY + 20 + CGFloat(step) * (visible.height - 40) / CGFloat(steps))
            let clock = ContinuousClock.now
            let old = canvas.selection
            canvas.extendSelection(to: point)
            let dirty = view.snapshot.selectionDirtyRects(from: old, to: canvas.selection)
                .reduce(CGRect.null) { $0.union($1) }.intersection(visible)
            if !dirty.isNull, !dirty.isEmpty { canvas.cacheDisplay(in: dirty, to: bitmap) }
            durations.append(ContinuousClock.now - clock)
        }
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[sorted.count * 95 / 100]
        // The worst case per frame: the whole visible area redrawn with a
        // selection covering it, as when autoscroll exposes a new page.
        var screens: [Duration] = []
        for _ in 0..<20 {
            let clock = ContinuousClock.now
            canvas.cacheDisplay(in: visible, to: bitmap)
            screens.append(ContinuousClock.now - clock)
        }
        screens.sort()
        print("Drag step (selection update + redraw of dirty lines): median \(median), p95 \(p95), max \(sorted.last!)")
        print("Full visible redraw with selection: median \(screens[10]), max \(screens.last!)")
        XCTAssertNotNil(canvas.selection)
        XCTAssertLessThan(p95, .milliseconds(16))
    }
}
