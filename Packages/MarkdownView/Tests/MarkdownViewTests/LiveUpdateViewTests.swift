import AppKit
import XCTest
@testable import MarkdownView

/// Live typing in the view: one update in flight, the newest source next,
/// pacing after slow updates, scroll anchoring, and partial redraws.
@MainActor
final class LiveUpdateViewTests: XCTestCase {
    private var window: NSWindow!
    private var view: MarkdownPreviewView!
    private var canvas: MarkdownDocumentView { view.documentView as! MarkdownDocumentView }

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

    private func paragraphs(_ count: Int) -> [String] {
        (0..<count).map { "Paragraph \($0) with a few words in it." }
    }

    /// Waits until a complete snapshot of exactly `text` has installed and
    /// nothing else is pending.
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
        // The scroller appearing narrows the view once, on a later turn of
        // the run loop; let that settle too.
        window.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if view.snapshot.width != view.contentView.bounds.width {
            waitForInstall(of: text)
            window.display()
        }
        XCTAssertEqual(view.snapshot.width, view.contentView.bounds.width)
    }

    func testRapidSourcesCoalesceIntoAtMostTwoRuns() {
        view.updatePolicy = UpdatePolicy(budget: .seconds(60))
        load(paragraphs(20).joined(separator: "\n\n"))
        let runs = view.pipeline.runs
        let generation = view.pipeline.generation
        var texts: [String] = []
        for index in 1...10 {
            var edited = paragraphs(20)
            edited[5] += " edit \(index)"
            texts.append(edited.joined(separator: "\n\n"))
        }
        waitForInstall(of: texts[9]) {
            for text in texts { view.setSource(text) }
            XCTAssertEqual(view.pipeline.generation, generation + 1, "later sources wait for the first")
        }
        view.pipeline.queue.sync {}
        XCTAssertLessThanOrEqual(view.pipeline.runs - runs, 2)
        XCTAssertLessThanOrEqual(view.pipeline.generation - generation, 2)
        XCTAssertEqual(view.snapshot.document.blocks[5].text, "Paragraph 5 with a few words in it. edit 10")
    }

    func testSlowUpdatePausesTheNextSource() {
        // Every update is over budget, so the next one waits its cost, at least 150 ms here.
        view.updatePolicy = UpdatePolicy(budget: .zero, pauseFactor: 1000, maximumPause: .milliseconds(150))
        XCTAssertEqual(view.updatePolicy.pause(after: .milliseconds(1)), .milliseconds(150))
        XCTAssertEqual(UpdatePolicy.standard.pause(after: .milliseconds(10)), .zero)
        XCTAssertEqual(UpdatePolicy.standard.pause(after: .milliseconds(40)), .milliseconds(80))
        XCTAssertEqual(UpdatePolicy.standard.pause(after: .seconds(2)), .milliseconds(500))
        var installed: [ContinuousClock.Instant] = []
        view.onInstall = { _ in installed.append(.now) }
        load("# First\n\nBody.")
        let generation = view.pipeline.generation
        waitForInstall(of: "# Second\n\nBody.") {
            view.setSource("# Second\n\nBody.")
            XCTAssertEqual(view.pipeline.generation, generation, "waits for the pause")
        }
        XCTAssertGreaterThanOrEqual(installed[installed.count - 1] - installed[installed.count - 2], .milliseconds(145))
        view.onInstall = nil
        XCTAssertEqual(view.lastTimings?.pause, .milliseconds(150))
        XCTAssertGreaterThan(view.lastTimings?.wall ?? .zero, .zero)
        // Showing another document does not wait for the pause.
        let shown = ContinuousClock.now
        waitForInstall(of: "# Other") {
            view.setSource("# Other")
            view.setScrollOffset(0)
            XCTAssertEqual(view.pipeline.generation, generation + 2)
        }
        XCTAssertLessThan(ContinuousClock.now - shown, .milliseconds(150))
    }

    func testGrowingTheFirstBlockKeepsTheTopVisibleBlockInPlace() {
        var text = paragraphs(60)
        load(text.joined(separator: "\n\n"))
        view.setScrollOffset(view.snapshot.blockTops[20] + 10)
        let screenY = view.snapshot.blockTops[20] - view.contentView.bounds.minY
        text[0] += String(repeating: " and more words that wrap", count: 20)
        let grown = text.joined(separator: "\n\n")
        waitForInstall(of: grown) { view.setSource(grown) }
        XCTAssertGreaterThan(view.snapshot.layouts[0].height, view.snapshot.layouts[1].height * 2)
        XCTAssertEqual(view.snapshot.blockTops[20] - view.contentView.bounds.minY, screenY)
        // At the top, the view stays at the top while content above grows.
        view.setScrollOffset(0)
        text.insert("A new first paragraph.", at: 0)
        let inserted = text.joined(separator: "\n\n")
        waitForInstall(of: inserted) { view.setSource(inserted) }
        XCTAssertEqual(view.contentView.bounds.minY, 0)
    }

    func testEditRedrawsOnlyWhatChanged() throws {
        var text = paragraphs(40)
        load(text.joined(separator: "\n\n"))
        let snapshot = view.snapshot
        // Same height: only the edited block's band.
        text[3] = "Paragraph 3 with a few words in iT."
        var edited = text.joined(separator: "\n\n")
        waitForInstall(of: edited) { view.setSource(edited) }
        let rects = try XCTUnwrap(canvas.lastInvalidation)
        XCTAssertEqual(rects.count, 1)
        XCTAssertLessThan(rects[0].maxY, snapshot.blockTops[5])
        XCTAssertGreaterThan(rects[0].minY, snapshot.blockTops[2])
        window.display()
        // Taller: the block and everything below it in the visible area.
        text[3] += String(repeating: " more", count: 30)
        edited = text.joined(separator: "\n\n")
        waitForInstall(of: edited) { view.setSource(edited) }
        let grown = try XCTUnwrap(canvas.lastInvalidation)
        XCTAssertEqual(grown.map(\.maxY).max(), canvas.visibleRect.maxY)
        XCTAssertGreaterThan(grown.map(\.minY).min() ?? 0, snapshot.blockTops[2])
        window.display()
        // Off screen: nothing redraws, and the timings still arrive.
        text[35] += " x"
        edited = text.joined(separator: "\n\n")
        waitForInstall(of: edited) { view.setSource(edited) }
        XCTAssertEqual(canvas.lastInvalidation, [])
        let generation = view.snapshot.generation
        let reported = expectation(description: "timings")
        view.onTimings = { timings in
            if timings.generation == generation { reported.fulfill() }
        }
        wait(for: [reported], timeout: 5)
        XCTAssertEqual(view.lastTimings?.reusedBlocks, 39)
        XCTAssertEqual(view.lastTimings?.laidOutBlocks, 1)
        XCTAssertEqual(view.lastTimings?.draw, .zero)
    }

    #if DEBUG
    func testInstallMakesNoPassOverTheBlocks() {
        var text = (0..<10_000).map { "P\($0)" }
        load(text.joined(separator: "\n\n"))
        XCTAssertEqual(view.snapshot.layouts.count, 10_000)
        text[5_000] = "Edited"
        let edited = text.joined(separator: "\n\n")
        var passes: Int?
        let original = view.pipeline.onOutcome
        view.pipeline.onOutcome = { outcome in
            let before = MarkdownSnapshot.prefixSumPasses.load(ordering: .relaxed)
            original?(outcome)
            passes = MarkdownSnapshot.prefixSumPasses.load(ordering: .relaxed) - before
        }
        waitForInstall(of: edited) { view.setSource(edited) }
        view.pipeline.onOutcome = original
        XCTAssertEqual(passes, 0, "the y offsets were computed on the background queue")
        XCTAssertEqual(view.snapshot.update?.match?.matchedCount, 9_999)
        XCTAssertTrue(view.snapshot.isComplete)
    }
    #endif
}
