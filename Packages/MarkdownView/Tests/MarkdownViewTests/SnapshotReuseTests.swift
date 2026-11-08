import AppKit
import XCTest
@testable import MarkdownView

/// A host keeps each document's last snapshot and hands it back when the
/// document is shown again, so unchanged blocks keep their layouts.
@MainActor
final class SnapshotReuseTests: XCTestCase {
    private let first = (0..<120).map { "## Section \($0)\n\nParagraph \($0) with enough words to wrap across the column." }
        .joined(separator: "\n\n") + "\n\n| a | b |\n| - | - |\n| 1 | 2 |"
    private let second = "# Other\n\nA small other document."

    /// Sets a source and waits for its complete snapshot, returning the
    /// timings of the update that installed it.
    private func show(_ view: MarkdownPreviewView, _ text: String, reusing snapshot: MarkdownSnapshot?? = .none,
                      offset: CGFloat = 0) -> Timings {
        let installed = expectation(description: "installed")
        var timings: Timings?
        let original = view.pipeline.onOutcome
        view.pipeline.onOutcome = { outcome in
            original?(outcome)
            if case .snapshot(let snapshot, _, let received) = outcome, snapshot.isComplete,
               snapshot.document.source == text {
                timings = received
                installed.fulfill()
            }
        }
        if case .some(let snapshot) = snapshot { view.setSource(text, reusing: snapshot) } else { view.setSource(text) }
        view.setScrollOffset(offset)
        wait(for: [installed], timeout: 10)
        view.pipeline.onOutcome = original
        return timings ?? Timings(generation: 0)
    }

    func testShowingADocumentAgainReusesEveryBlock() throws {
        let view = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let opened = show(view, first)
        XCTAssertEqual(opened.reusedBlocks, 0)
        let saved = view.snapshot
        _ = show(view, second)
        let runs = view.pipeline.runs
        let timings = show(view, first, reusing: saved)
        XCTAssertEqual(view.pipeline.runs - runs, 1)
        XCTAssertEqual(timings.blockCount, saved.layouts.count)
        XCTAssertEqual(timings.reusedBlocks, saved.layouts.count)
        XCTAssertEqual(timings.laidOutBlocks, 0)
        XCTAssertTrue(timings.isComplete, "one complete snapshot, no visible-first step")
        XCTAssertTrue(zip(view.snapshot.layouts, saved.layouts).allSatisfy { $0 === $1 })
        XCTAssertEqual(view.snapshot.document.blocks, saved.document.blocks)
        XCTAssertNil(view.selection)

        // At a position, too, and while another update is pending.
        _ = show(view, second)
        let y = saved.blockTops[150]
        let positioned = show(view, first, reusing: saved, offset: y)
        XCTAssertEqual(positioned.laidOutBlocks, 0)
        XCTAssertEqual(view.contentView.bounds.minY, y, accuracy: 0.5)
    }

    func testAChangedBlockIsLaidOutAgain() throws {
        let view = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        _ = show(view, first)
        let saved = view.snapshot
        _ = show(view, second)
        let edited = first.replacingOccurrences(of: "Paragraph 60 with", with: "Paragraph 60, edited elsewhere, with")
        let timings = show(view, edited, reusing: saved)
        XCTAssertEqual(timings.reusedBlocks, saved.layouts.count - 1)
        XCTAssertEqual(timings.laidOutBlocks, 1)
        let index = try XCTUnwrap(view.snapshot.document.blocks.firstIndex { $0.text.hasPrefix("Paragraph 60,") })
        XCTAssertFalse(view.snapshot.layouts[index] === saved.layouts[index])
        XCTAssertTrue(view.snapshot.layouts[index + 1] === saved.layouts[index + 1])
        let full = MarkdownSnapshot.layOut(try MarkdownDocument.parse(edited), width: view.snapshot.width)
        XCTAssertEqual(view.snapshot.blockTops, full.blockTops)

        // Another width keeps nothing but still lends tables their natural widths.
        _ = show(view, second)
        view.setFrameSize(NSSize(width: 500, height: 400))
        view.tile()
        let resized = show(view, edited, reusing: view.snapshot.document.source == edited ? nil : saved)
        XCTAssertEqual(resized.reusedBlocks, 0)
        XCTAssertEqual(view.snapshot.width, view.contentView.bounds.width)
    }

    func testAHiddenViewKeepsTheSnapshotToReuseUntilShown() {
        let view = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        _ = show(view, first)
        let saved = view.snapshot
        _ = show(view, second)
        view.setVisible(false)
        view.setSource(first, reusing: saved)
        XCTAssertEqual(view.snapshot.document.source, second, "nothing installs while hidden")
        let installed = expectation(description: "installed")
        var timings: Timings?
        let original = view.pipeline.onOutcome
        let source = first
        view.pipeline.onOutcome = { outcome in
            original?(outcome)
            if case .snapshot(let snapshot, _, let received) = outcome, snapshot.document.source == source {
                timings = received
                installed.fulfill()
            }
        }
        view.setVisible(true)
        wait(for: [installed], timeout: 10)
        XCTAssertEqual(timings?.laidOutBlocks, 0)
        XCTAssertEqual(timings?.reusedBlocks, saved.layouts.count)
        XCTAssertEqual(view.snapshot.document.source, first)
    }

    func testParsingAnUnchangedSourceReturnsTheSameBlocks() throws {
        let document = try MarkdownDocument.parse(first)
        let result = try MarkdownDocument.parse(first, reusing: document)
        XCTAssertEqual(result.document, document)
        XCTAssertEqual(result.match?.matchedCount, document.blocks.count)
        let end = (first as NSString).length
        XCTAssertEqual(result.edit, SourceEdit(old: end..<end, new: end..<end))
        // A bridged copy of the same text matches too.
        let bridged = NSMutableString(string: first).copy() as! NSString as String
        XCTAssertEqual(try MarkdownDocument.parse(bridged, reusing: document).match?.matchedCount, document.blocks.count)
    }
}
