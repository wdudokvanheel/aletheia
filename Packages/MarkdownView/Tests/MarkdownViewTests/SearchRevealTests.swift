import AppKit
import XCTest
@testable import MarkdownView

/// `reveal(sourceRange:)`: the source occurrence the find bar matched is
/// selected where it is displayed and centered, or its block is centered
/// when it is not displayed; requests wait for their source's snapshot.
@MainActor
final class SearchRevealTests: XCTestCase {
    private var window: NSWindow!
    private var view: MarkdownPreviewView!

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

    /// Waits for a complete snapshot of exactly `text`, after `change`.
    private func waitForInstall(of text: String, after change: () -> Void = {}) {
        let installed = expectation(description: "installed")
        installed.assertForOverFulfill = false
        let original = view.pipeline.onOutcome
        view.pipeline.onOutcome = { [view] outcome in
            original?(outcome)
            if view!.snapshot.isComplete, view!.snapshot.document.source == text { installed.fulfill() }
        }
        change()
        wait(for: [installed], timeout: 10)
        view.pipeline.onOutcome = original
    }

    private func load(_ text: String) {
        waitForInstall(of: text) { view.setSource(text) }
        window.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if view.snapshot.width != view.contentView.bounds.width {
            waitForInstall(of: text)
        }
    }

    private func range(of query: String, in text: String, occurrence: Int = 0) -> NSRange {
        let source = text as NSString
        var start = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = source.range(of: query, options: .literal,
                                 range: NSRange(location: start, length: source.length - start))
            start = NSMaxRange(found)
        }
        return found
    }

    private func filler(_ count: Int, _ name: String) -> String {
        (0..<count).map { "\(name) filler paragraph \($0) with a few words." }.joined(separator: "\n\n")
    }

    /// The vertical middle of the visible area, in document coordinates.
    private var visibleMidY: CGFloat { view.contentView.bounds.midY }

    private func block(containing text: String) -> Int? {
        view.snapshot.document.blocks.firstIndex { $0.text.contains(text) }
    }

    func testSourceOccurrencesSelectWhereDisplayedAndCenter() throws {
        let body = "😀 first\r\n\r\n[repeat](repeat) repeat **repeat**\r\n\r\nrepeat\r\n\r\n[hidden]: destination"
        let text = filler(30, "Above") + "\r\n\r\n" + body + "\r\n\r\n" + filler(30, "Below")
        load(text)
        let linked = try XCTUnwrap(block(containing: "repeat repeat repeat"))
        let plain = linked + 1
        XCTAssertEqual(view.snapshot.document.blocks[plain].text, "repeat")
        // Occurrences 0, 2, and 3 are in the linked paragraph's text, 4 is the next paragraph;
        // the hidden destination (1) does not shift them.
        for (occurrence, expected) in [(0, (linked, 0)), (2, (linked, 7)), (3, (linked, 14)), (4, (plain, 0))] {
            view.reveal(sourceRange: range(of: "repeat", in: text, occurrence: occurrence))
            XCTAssertEqual(view.selection, TextPosition(block: expected.0, offset: expected.1)
                ..< TextPosition(block: expected.0, offset: expected.1 + 6), "occurrence \(occurrence)")
            XCTAssertEqual(view.selectedText, "repeat")
            let band = view.snapshot.lineBand(view.selection!.lowerBound, view.selection!.upperBound)
            XCTAssertEqual(visibleMidY, band.midY, accuracy: 1, "occurrence \(occurrence) centered")
        }
        // Not displayed: the link destination, markup, and a match across blocks select
        // nothing and center their block's line.
        for query in ["(repeat)", "**", "**repeat**\r\n\r\nrepeat"] {
            view.setScrollOffset(0)
            view.reveal(sourceRange: range(of: query, in: text))
            XCTAssertNil(view.selection, query)
            let band = view.snapshot.lineBand(TextPosition(block: linked, offset: 0), TextPosition(block: linked, offset: 0))
            XCTAssertEqual(visibleMidY, band.midY, accuracy: 1, query)
        }
        // In a link reference definition, which is no block: the next block shown.
        view.setScrollOffset(0)
        view.reveal(sourceRange: range(of: "destination", in: text))
        XCTAssertNil(view.selection)
        let next = try XCTUnwrap(block(containing: "Below filler paragraph 0 "))
        XCTAssertEqual(next, plain + 1)
        let band = view.snapshot.lineBand(TextPosition(block: next, offset: 0), TextPosition(block: next, offset: 0))
        XCTAssertEqual(visibleMidY, band.midY, accuracy: 1)
    }

    func testAMatchAfterTheLastBlockCentersTheLastBlock() {
        let text = filler(30, "Para") + "\n\n<div>\nraw html here\n</div>\n\n[hidden]: destination\n"
        load(text)
        let last = view.snapshot.document.blocks.lastIndex { $0.kind == .paragraph }!
        view.reveal(sourceRange: range(of: "raw html", in: text))
        XCTAssertNil(view.selection)
        XCTAssertEqual(view.contentView.bounds.maxY, view.snapshot.totalHeight, accuracy: 1, "scrolled to the end")
        view.setScrollOffset(0)
        view.reveal(sourceRange: range(of: "destination", in: text))
        XCTAssertNil(view.selection)
        XCTAssertGreaterThan(view.contentView.bounds.maxY, view.snapshot.blockTops[last])
    }

    func testUTF16OffsetsWithEmojiAndSurrogatesBeforeTheMatch() {
        let text = "# 👩‍👩‍👧 Family 🇳🇱\n\nEmoji 😀👍🏽 and 𝒳 before the target, then target again."
        load(text)
        let paragraph = view.snapshot.document.blocks[1].text
        for occurrence in 0...1 {
            view.reveal(sourceRange: range(of: "target", in: text, occurrence: occurrence))
            XCTAssertEqual(view.selectedText, "target")
            let expected = range(of: "target", in: paragraph, occurrence: occurrence)
            XCTAssertEqual(view.selection, TextPosition(block: 1, offset: expected.location)
                ..< TextPosition(block: 1, offset: NSMaxRange(expected)), "occurrence \(occurrence)")
        }
        view.reveal(sourceRange: range(of: "Family", in: text))
        XCTAssertEqual(view.selection?.lowerBound.block, 0)
        XCTAssertEqual(view.selectedText, "Family")
    }

    func testMatchesInTableCellsAndFrontMatter() {
        let text = """
        ---
        title: Hello World
        tags: one, two
        ---

        | Name | Value |
        | --- | :---: |
        | alpha | **beta** gamma |
        | delta | [link](https://example.com/beta) |
        """
        load(text)
        view.reveal(sourceRange: range(of: "World", in: text))
        XCTAssertEqual(view.selection?.lowerBound.block, 0)
        XCTAssertEqual(view.selectedText, "World")
        view.reveal(sourceRange: range(of: "beta", in: text))
        XCTAssertEqual(view.selection?.lowerBound.block, 1)
        XCTAssertEqual(view.selectedText, "beta")
        view.reveal(sourceRange: range(of: "gamma", in: text))
        XCTAssertEqual(view.selectedText, "gamma")
        // The cell's link destination is not displayed.
        view.reveal(sourceRange: range(of: "beta", in: text, occurrence: 1))
        XCTAssertNil(view.selection)
        // Front matter that is not key/value pairs shows as code, also searchable.
        let code = "---\n- first\n- second item\n---\n\nBody"
        load(code)
        view.reveal(sourceRange: range(of: "second", in: code))
        XCTAssertEqual(view.selectedText, "second")
    }

    func testAListMarkerOrEntitySelectsNothing() {
        let text = "- one\n- two &amp; three\n- four"
        load(text)
        view.reveal(sourceRange: range(of: "- two", in: text))
        XCTAssertNil(view.selection)
        view.reveal(sourceRange: range(of: "&amp;", in: text))
        XCTAssertNil(view.selection)
        view.reveal(sourceRange: range(of: "two", in: text))
        XCTAssertEqual(view.selectedText, "two")
        XCTAssertEqual(view.selection?.lowerBound.block, 0)
    }

    func testAPendingRevealAppliesWhenItsSnapshotInstalls() {
        let first = filler(40, "First")
        load(first)
        let second = first + "\n\nThe new target paragraph."
        waitForInstall(of: second) {
            view.setSource(second)
            view.reveal(sourceRange: range(of: "target", in: second))
            XCTAssertNil(view.selection, "waits for the snapshot of the new source")
        }
        XCTAssertEqual(view.selectedText, "target")
        XCTAssertEqual(view.contentView.bounds.maxY, view.snapshot.totalHeight, accuracy: 1)

        // A newer source drops a request not yet applied.
        view.clearSearch()
        XCTAssertNil(view.selection)
        let third = second + " More."
        let fourth = third + " Even more."
        waitForInstall(of: fourth) {
            view.setSource(third)
            view.reveal(sourceRange: range(of: "target", in: third))
            view.setSource(fourth)
        }
        XCTAssertNil(view.selection)
    }

    func testAnotherDocumentDropsThePendingRevealAndRevealCancelsAPendingPosition() {
        let first = filler(40, "First") + "\n\ntarget"
        load(first)
        let second = filler(40, "Second") + "\n\ntarget"
        waitForInstall(of: second) {
            view.setSource(second, reusing: nil)
            view.reveal(sourceRange: range(of: "target", in: first))
            view.setSource(second, reusing: nil)
        }
        XCTAssertNil(view.selection)

        // Showing a document at a stored position, then revealing near its top: the match wins.
        let third = "Near the top: target.\n\n" + filler(60, "Third")
        waitForInstall(of: third) {
            view.setSource(third, reusing: nil)
            view.setScrollOffset(2000)
            view.reveal(sourceRange: range(of: "target", in: third))
        }
        XCTAssertEqual(view.selectedText, "target")
        XCTAssertEqual(view.contentView.bounds.minY, 0, "the match near the top stays at the top")
        XCTAssertEqual(view.scrollOffset, 0)
    }

    func testClearSearchDeselectsAndInvalidRangesClear() {
        let text = "One target here."
        load(text)
        view.reveal(sourceRange: range(of: "target", in: text))
        XCTAssertEqual(view.selectedText, "target")
        view.clearSearch()
        XCTAssertNil(view.selection)
        view.reveal(sourceRange: range(of: "target", in: text))
        view.reveal(sourceRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNil(view.selection)
        // Past the end of the source: the last block, nothing selected.
        view.reveal(sourceRange: NSRange(location: 500, length: 3))
        XCTAssertNil(view.selection)
    }
}
