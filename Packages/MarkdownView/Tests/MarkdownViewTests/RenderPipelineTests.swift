import AppKit
import XCTest
@testable import MarkdownView

@MainActor
final class RenderPipelineTests: XCTestCase {
    private let longSource = (0..<300).map { "Paragraph \($0) with enough words to wrap at narrow widths, twice over." }
        .joined(separator: "\n\n")

    /// Collects outcomes from `pipeline` until `isDone` accepts one.
    private func outcomes(of pipeline: RenderPipeline, after submit: () -> Void,
                          until isDone: @escaping (RenderOutcome) -> Bool) -> [RenderOutcome] {
        var received: [RenderOutcome] = []
        let done = expectation(description: "outcome")
        pipeline.onOutcome = { outcome in
            received.append(outcome)
            if isDone(outcome) { done.fulfill() }
        }
        submit()
        wait(for: [done], timeout: 5)
        // Let anything still queued on either side arrive, so extra outcomes would be seen.
        pipeline.queue.sync {}
        let flushed = expectation(description: "flushed")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)
        return received
    }

    private func submit(_ pipeline: RenderPipeline, _ source: String, sourceGeneration: UInt64, width: CGFloat = 500,
                        visibleFirst: Bool = false) -> UInt64 {
        pipeline.submit(sourceGeneration: sourceGeneration, source: source, width: width, scrollFraction: 0,
                        viewportHeight: 300, visibleFirst: visibleFirst, complete: true)
    }

    private func isComplete(_ outcome: RenderOutcome) -> Bool {
        if case .snapshot(let snapshot, _, _) = outcome { snapshot.isComplete } else { true }
    }

    func testFinishedOlderGenerationIsDiscardedOnMainThread() {
        let pipeline = RenderPipeline(typography: .standard)
        var latest: UInt64 = 0
        let received = outcomes(of: pipeline, after: {
            _ = submit(pipeline, "# One", sourceGeneration: 1)
            // The first result is finished and queued for the main thread
            // before the second request exists.
            pipeline.queue.sync {}
            latest = submit(pipeline, "# Two", sourceGeneration: 2)
        }, until: { $0.generation == latest })
        XCTAssertEqual(received.map(\.generation), [latest])
        guard case .snapshot(let snapshot, let sourceGeneration, _) = received.first else { return XCTFail() }
        XCTAssertEqual(sourceGeneration, 2)
        XCTAssertEqual(snapshot.document.blocks.first?.text, "Two")
    }

    func testQueuedRequestsCoalesceToTheLatest() {
        let pipeline = RenderPipeline(typography: .standard)
        let gate = DispatchSemaphore(value: 0)
        var latest: UInt64 = 0
        let received = outcomes(of: pipeline, after: {
            pipeline.queue.async { gate.wait() }
            for generation in 1...3 {
                latest = submit(pipeline, "Text \(generation)", sourceGeneration: UInt64(generation))
            }
            gate.signal()
        }, until: { $0.generation == latest })
        XCTAssertEqual(received.map(\.generation), [3])
    }

    func testVisibleFirstOpenInstallsTopThenEverything() {
        let pipeline = RenderPipeline(typography: .standard)
        let received = outcomes(of: pipeline, after: {
            _ = submit(pipeline, longSource, sourceGeneration: 1, visibleFirst: true)
        }, until: isComplete)
        XCTAssertEqual(received.count, 2)
        guard case .snapshot(let visible, _, let visibleTimings) = received[0],
              case .snapshot(let complete, _, let completeTimings) = received[1] else { return XCTFail() }
        XCTAssertEqual(visible.generation, complete.generation)
        XCTAssertFalse(visible.isComplete)
        XCTAssertFalse(visibleTimings.isComplete)
        XCTAssertTrue(visible.layouts[0].isFinal(for: visible.columnWidth))
        XCTAssertTrue(visible.layouts[299].isEstimate)
        XCTAssertTrue(complete.isComplete)
        XCTAssertTrue(completeTimings.isComplete)
        XCTAssertEqual(completeTimings.blockCount, 300)
        XCTAssertGreaterThan(completeTimings.parse, .zero)
        XCTAssertTrue(visible.layouts[0] === complete.layouts[0], "visible layouts are reused")
    }

    func testResizeRelaysOutWithoutParsing() {
        let pipeline = RenderPipeline(typography: .standard)
        _ = outcomes(of: pipeline, after: { _ = submit(pipeline, longSource, sourceGeneration: 1) }, until: isComplete)
        let received = outcomes(of: pipeline, after: {
            _ = submit(pipeline, longSource, sourceGeneration: 1, width: 300)
        }, until: isComplete)
        XCTAssertEqual(received.count, 2)
        guard case .snapshot(let snapshot, _, let timings) = received[1] else { return XCTFail() }
        XCTAssertEqual(snapshot.width, 300)
        XCTAssertEqual(timings.parse, .zero)
        XCTAssertGreaterThan(timings.layout, .zero)
    }

    // MARK: View

    private func waitForInstall(_ view: MarkdownPreviewView, where isDone: @escaping (MarkdownSnapshot) -> Bool) {
        let installed = expectation(description: "installed")
        let original = view.pipeline.onOutcome
        view.pipeline.onOutcome = { outcome in
            original?(outcome)
            if isDone(view.snapshot) { installed.fulfill() }
        }
        wait(for: [installed], timeout: 5)
        view.pipeline.onOutcome = original
    }

    func testHiddenPreviewCoalescesSourcesIntoOneUpdate() {
        let view = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertEqual(view.documentView?.frame.width, view.contentView.bounds.width, "tracks the clip view width")
        XCTAssertGreaterThan(view.contentView.bounds.width, 500)
        view.setVisible(false)
        for text in ["# a", "# b", "# c"] { view.setSource(text) }
        XCTAssertEqual(view.pipeline.generation, 0)
        view.setVisible(true)
        XCTAssertEqual(view.pipeline.generation, 1)
        waitForInstall(view) { $0.document.blocks.first?.text == "c" && $0.isComplete }
        XCTAssertEqual(view.documentView?.frame.height, view.snapshot.totalHeight)
    }

    func testScrollFractionSetBeforeRenderAppliesOnInstall() {
        let view = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.setSource(longSource)
        view.scrollFraction = 0.5
        XCTAssertEqual(view.scrollFraction, 0.5)
        waitForInstall(view) { $0.isComplete && !$0.layouts.isEmpty }
        XCTAssertEqual(view.scrollFraction, 0.5, accuracy: 0.001)
        view.scrollFraction = 0.25
        XCTAssertEqual(view.scrollFraction, 0.25, accuracy: 0.001)
    }

    func testScrollOffsetSetBeforeRenderAppliesToTheNewContent() {
        let view = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.setSource("# Short\n\nOld content.")
        waitForInstall(view) { $0.isComplete && !$0.layouts.isEmpty }
        view.setSource(longSource)
        view.setScrollOffset(1200)
        XCTAssertEqual(view.scrollOffset, 1200)
        var installed: [(complete: Bool, offset: CGFloat, height: CGFloat)] = []
        view.onInstall = { snapshot in
            installed.append((snapshot.isComplete, view.contentView.bounds.minY, view.documentView!.frame.height))
        }
        waitForInstall(view) { $0.isComplete && $0.layouts.count == 300 }
        XCTAssertEqual(view.contentView.bounds.minY, 1200)
        XCTAssertEqual(view.scrollOffset, 1200)
        // Called after the install sized the view and applied the offset.
        XCTAssertEqual(installed.last?.complete, true)
        XCTAssertEqual(installed.last?.offset, 1200)
        XCTAssertEqual(installed.last?.height, view.snapshot.totalHeight)
        view.setScrollOffset(300)
        XCTAssertEqual(view.contentView.bounds.minY, 300)
        view.setScrollOffset(.greatestFiniteMagnitude)
        XCTAssertEqual(view.contentView.bounds.maxY, view.snapshot.totalHeight, accuracy: 0.5)
    }

    func testScrollFractionSetOnTheVisibleStepAppliesToTheCompleteSnapshot() {
        let view = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var setOnVisibleStep = false
        view.onInstall = { snapshot in
            guard !snapshot.isComplete, !setOnVisibleStep else { return }
            setOnVisibleStep = true
            view.scrollFraction = 0.5
        }
        view.setSource(longSource)
        waitForInstall(view) { $0.isComplete && !$0.layouts.isEmpty }
        XCTAssertTrue(setOnVisibleStep, "an open at the top lays out the visible area first")
        XCTAssertEqual(view.contentView.bounds.minY, view.snapshot.totalHeight * 0.5, accuracy: 0.5)
        XCTAssertEqual(view.scrollFraction, 0.5, accuracy: 0.001)
    }

    func testSourceSetWhileHiddenDropsOlderWork() {
        let view = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.setSource("# Old")
        view.setVisible(false)
        view.setSource("# New")
        var installs = 0
        view.onInstall = { _ in installs += 1 }
        view.pipeline.queue.sync {}
        let flushed = expectation(description: "flushed")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)
        XCTAssertEqual(installs, 0, "the old source does not install after a newer one was set")
        view.setVisible(true)
        waitForInstall(view) { $0.document.blocks.first?.text == "New" && $0.isComplete }
    }

    func testKeyboardScrollsByPage() throws {
        let view = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.setSource(longSource)
        waitForInstall(view) { $0.isComplete && !$0.layouts.isEmpty }
        let canvas = try XCTUnwrap(view.documentView)
        func press(_ characters: String, _ flags: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                       timestamp: 0, windowNumber: 0, context: nil,
                                                       characters: characters, charactersIgnoringModifiers: characters,
                                                       isARepeat: false, keyCode: 0))
            canvas.keyDown(with: event)
        }
        let page = 400 - Typography.standard.lineHeight(.body)
        XCTAssertEqual(view.contentView.bounds.minY, 0, "a visible-first open stays at the top")
        try press(" ")
        XCTAssertEqual(view.contentView.bounds.minY, page, accuracy: 0.5)
        try press(" ", .shift)
        XCTAssertEqual(view.contentView.bounds.minY, 0, accuracy: 0.5)
        try press(String(UnicodeScalar(UInt16(NSEndFunctionKey))!))
        XCTAssertEqual(view.contentView.bounds.maxY, canvas.frame.height, accuracy: 0.5)
        try press(String(UnicodeScalar(UInt16(NSHomeFunctionKey))!))
        XCTAssertEqual(view.contentView.bounds.minY, 0, accuracy: 0.5)
    }

    func testDrawsTextIntoTheFirstBlock() throws {
        let view = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.palette.background = .white
        view.palette.text = .black
        view.palette.headingText = .black
        view.setSource("# Heading\n\nSome body text.")
        waitForInstall(view) { $0.isComplete && $0.layouts.count == 2 }
        let canvas = try XCTUnwrap(view.documentView)
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let snapshot = view.snapshot
        let scale = CGFloat(bitmap.pixelsHigh) / canvas.bounds.height
        var inked = 0
        let top = Int(snapshot.blockTops[0] * scale)
        let bottom = Int((snapshot.blockTops[0] + snapshot.layouts[0].height) * scale)
        for y in top..<bottom {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let color = bitmap.colorAt(x: x, y: y), color.brightnessComponent < 0.5 { inked += 1 }
            }
        }
        XCTAssertGreaterThan(inked, 50)
    }
}
