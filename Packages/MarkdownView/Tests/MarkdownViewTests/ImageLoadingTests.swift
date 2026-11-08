import AppKit
import Synchronization
import XCTest
@testable import MarkdownView

/// Frames decoded for an animated image, from any thread.
private final class FrameCounter: Sendable {
    let count = Atomic<Int>(0)
}

/// A provider that loads nothing: it records requests and answers when the
/// test says, with images of the sizes it is given.
@MainActor
private final class StubImageProvider: MarkdownImageProvider {
    struct Request {
        let source: String
        let displaySize: CGSize?
        let scale: CGFloat
        let completion: @MainActor (Result<MarkdownImage, any Error>) -> Void
        var isCancelled = false
        var isAnswered = false
    }

    struct Failure: Error {}

    var requests: [Request] = []
    /// Natural sizes to answer with; other sources fail.
    var sizes: [String: CGSize] = [:]
    /// Sources answered as soon as they are asked for, before returning.
    var immediate: Set<String> = []
    var animated: [String: (delays: [TimeInterval], frames: FrameCounter)] = [:]

    var pending: [Int] { requests.indices.filter { !requests[$0].isCancelled && !requests[$0].isAnswered } }
    var cancelled: [String] { requests.filter(\.isCancelled).map(\.source) }
    func count(_ source: String) -> Int { requests.count(where: { $0.source == source }) }

    func requestImage(source: String, displaySize: CGSize?, scale: CGFloat,
                      completion: @escaping @MainActor (Result<MarkdownImage, any Error>) -> Void)
        -> MarkdownImageRequest? {
        requests.append(Request(source: source, displaySize: displaySize, scale: scale, completion: completion))
        let index = requests.count - 1
        if immediate.contains(source) {
            answer(index)
            return nil
        }
        return MarkdownImageRequest { [weak self] in
            MainActor.assumeIsolated { self?.requests[index].isCancelled = true }
        }
    }

    func answer(_ index: Int) {
        guard !requests[index].isCancelled, !requests[index].isAnswered else { return }
        requests[index].isAnswered = true
        let source = requests[index].source
        guard let size = sizes[source] else { return requests[index].completion(.failure(Failure())) }
        let image = Self.bitmap(size)
        if let animation = animated[source] {
            let frames = animation.frames
            requests[index].completion(.success(MarkdownImage(image: image, size: size, frameDelays: animation.delays) { _ in
                frames.count.add(1, ordering: .relaxed)
                return image
            }))
        } else {
            requests[index].completion(.success(MarkdownImage(image: image, size: size)))
        }
    }

    func answerAll() { pending.forEach(answer) }

    static func bitmap(_ size: CGSize) -> CGImage {
        let context = CGContext(data: nil, width: max(Int(size.width), 1), height: max(Int(size.height), 1),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()!
    }
}

/// Loading images through the host's provider: alt text first, visible
/// images first, nothing while hidden, merged and cancelled requests,
/// remembered failures, animation only while visible, and eviction.
@MainActor
final class ImageLoadingTests: XCTestCase {
    private var window: NSWindow!
    private var view: MarkdownPreviewView!
    private var stub: StubImageProvider!
    private var canvas: MarkdownDocumentView { view.documentView as! MarkdownDocumentView }
    private var store: ImageStore { canvas.images }

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = MarkdownPreviewView(frame: window.contentLayoutRect)
        window.contentView = view
        stub = StubImageProvider()
        view.imageProvider = stub
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        view = nil
        stub = nil
    }

    private func paragraphs(_ count: Int, images: [Int: String] = [:]) -> String {
        (0..<count).map { index in
            images[index].map { "![\($0)](\($0).png)" } ?? "Paragraph \(index) with a few words in it."
        }.joined(separator: "\n\n")
    }

    private func load(_ text: String) {
        let installed = expectation(description: "installed")
        installed.assertForOverFulfill = false
        view.onInstall = { snapshot in
            if snapshot.isComplete, snapshot.document.source == text { installed.fulfill() }
        }
        view.setSource(text)
        wait(for: [installed], timeout: 10)
        view.onInstall = nil
        settle()
    }

    /// Turns the run loop until `condition` holds.
    private func waitUntil(_ message: String = "condition", timeout: TimeInterval = 5, _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func settle(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func scroll(toBlock index: Int, offset: CGFloat = 0) {
        view.setScrollOffset(view.snapshot.blockTops[index] + offset)
        settle()
    }

    func testAltTextShowsUntilTheImageLoadsWithoutDelayingTheInstall() throws {
        stub.sizes = ["files/valid.png": CGSize(width: 64, height: 48)]
        load("# PNG image\n\n![PNG, block](files/valid.png)\n\nAfter.")
        // Installed and drawn with the alt text: the request comes after.
        XCTAssertFalse(view.snapshot.layouts[1].drawsImages)
        XCTAssertEqual(view.snapshot.layouts[1].height, Typography.standard.lineHeight(.body))
        waitUntil { stub.requests.count == 1 }
        let request = stub.requests[0]
        XCTAssertEqual(request.source, "files/valid.png")
        XCTAssertEqual(request.displaySize?.width, view.snapshot.columnWidth)
        XCTAssertEqual(request.displaySize?.height, .infinity)
        XCTAssertEqual(request.scale, window.backingScaleFactor)
        stub.answer(0)
        waitUntil { view.snapshot.layouts[1].drawsImages }
        XCTAssertEqual(view.snapshot.layouts[1].height, 48)
        XCTAssertEqual(view.retainedImageCount, 1)
        XCTAssertEqual(view.retainedImageBytes, 64 * 48 * 4, accuracy: 64 * 4)
        window.display()
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testALoadRelaysOutOnlyItsBlockAndKeepsTheTopVisibleBlockInPlace() throws {
        stub.sizes = ["a.png": CGSize(width: 200, height: 150)]
        load(paragraphs(60, images: [10: "a"]))
        // The image is just above the visible area, within a screen of it.
        scroll(toBlock: 12, offset: 5)
        let before = view.snapshot
        let screenY = before.blockTops[12] - view.contentView.bounds.minY
        waitUntil { stub.requests.count == 1 }
        stub.answer(0)
        waitUntil { view.snapshot.layouts[10].drawsImages && view.snapshot.isComplete }
        let after = view.snapshot
        XCTAssertEqual(after.layouts.indices.filter { after.layouts[$0] !== before.layouts[$0] }, [10])
        XCTAssertEqual(after.blockTops[12] - view.contentView.bounds.minY, screenY)
        XCTAssertEqual(after.layouts[10].height, 150)
        window.display()
        waitUntil { view.lastTimings?.generation == view.pipeline.generation }
        XCTAssertEqual(view.lastTimings?.laidOutBlocks, 1)
        XCTAssertEqual(view.lastTimings?.reusedBlocks, 59)
        XCTAssertEqual(view.lastTimings?.parse, .zero)
    }

    func testVisibleImagesAreRequestedFirstInDisplayOrder() throws {
        store.maximumRequests = 100
        view.imageProvider = nil
        // A and B are on screen, C within a screen below, D within one above, E and F far away.
        load(paragraphs(120, images: [5: "E", 25: "D", 31: "A", 35: "B", 45: "C", 100: "F"]))
        scroll(toBlock: 30)
        view.imageProvider = stub
        waitUntil { stub.requests.count == 4 }
        settle()
        XCTAssertEqual(stub.requests.map(\.source), ["A.png", "B.png", "C.png", "D.png"])
        // Far away, requests are cancelled, and what is near there is asked for.
        view.setScrollOffset(view.snapshot.totalHeight)
        waitUntil { stub.requests.count == 5 }
        XCTAssertEqual(Set(stub.cancelled), ["A.png", "B.png", "C.png", "D.png"])
        XCTAssertEqual(stub.requests.last?.source, "F.png")
    }

    func testRequestsWaitForRoomInDisplayOrder() throws {
        store.maximumRequests = 2
        load((0..<6).map { "![i\($0)](i\($0).png)" }.joined(separator: " "))
        waitUntil { stub.requests.count == 2 }
        settle()
        XCTAssertEqual(stub.requests.map(\.source), ["i0.png", "i1.png"])
        stub.answer(0)
        waitUntil { stub.requests.count == 3 }
        XCTAssertEqual(stub.requests[2].source, "i2.png")
    }

    func testNothingIsRequestedWhileHiddenAndRequestsStartWhenShown() throws {
        view.imageProvider = nil
        load(paragraphs(10, images: [1: "a", 2: "b"]))
        view.setVisible(false)
        view.imageProvider = stub
        settle(0.2)
        XCTAssertTrue(stub.requests.isEmpty)
        view.setVisible(true)
        waitUntil { stub.requests.count == 2 }
        // Hiding cancels the loads in flight.
        view.setVisible(false)
        XCTAssertEqual(Set(stub.cancelled), ["a.png", "b.png"])
        settle(0.2)
        XCTAssertEqual(stub.requests.count, 2)
    }

    func testOneSourceInSeveralPlacesIsOneRequest() throws {
        stub.sizes = ["same.png": CGSize(width: 40, height: 30)]
        load("![one](same.png) and ![two](same.png)\n\n![three](same.png)")
        waitUntil { stub.requests.count == 1 }
        settle()
        XCTAssertEqual(stub.requests.count, 1)
        stub.answer(0)
        waitUntil { view.snapshot.layouts.allSatisfy(\.drawsImages) }
        let placed = view.snapshot.layouts.flatMap { $0.lines.flatMap { $0.decorations.filter { $0.kind == .image } } }
        XCTAssertEqual(placed.count, 3)
        XCTAssertEqual(view.retainedImageCount, 1)
        settle()
        XCTAssertEqual(stub.count("same.png"), 1)
    }

    func testShowingAnotherDocumentCancelsItsRequests() throws {
        load(paragraphs(10, images: [1: "a", 3: "b"]))
        waitUntil { stub.requests.count == 2 }
        let other = paragraphs(5, images: [2: "c"])
        let installed = expectation(description: "installed")
        installed.assertForOverFulfill = false
        view.onInstall = { if $0.document.source == other, $0.isComplete { installed.fulfill() } }
        view.setSource(other, reusing: nil)
        XCTAssertEqual(Set(stub.cancelled), ["a.png", "b.png"])
        wait(for: [installed], timeout: 5)
        waitUntil { stub.requests.count == 3 }
        XCTAssertEqual(stub.requests[2].source, "c.png")
    }

    func testAFailedImageKeepsItsAltTextAndIsNotAskedForAgain() throws {
        let text = "Before.\n\n![Missing](missing.png)\n\nAfter."
        load(text)
        waitUntil { stub.requests.count == 1 }
        let snapshot = view.snapshot
        let generation = view.pipeline.generation
        stub.answer(0)
        settle(0.1)
        // No relayout: the alt text was already there.
        XCTAssertEqual(view.pipeline.generation, generation)
        XCTAssertTrue(view.snapshot.layouts[1] === snapshot.layouts[1])
        // Edits and scrolling ask for nothing more.
        load("Before, edited.\n\n![Missing](missing.png)\n\nAfter.")
        view.setScrollOffset(10)
        settle(0.1)
        XCTAssertEqual(stub.count("missing.png"), 1)
        // A changed source is a new image.
        load("Before, edited.\n\n![Missing](missing-2.png)\n\nAfter.")
        waitUntil { stub.count("missing-2.png") == 1 }
        // Another document starts over.
        view.setSource(text, reusing: nil)
        waitUntil { stub.count("missing.png") == 2 }
    }

    func testAnimationRunsOnlyWhileAnAnimatedImageIsVisible() throws {
        let counter = FrameCounter()
        stub.sizes = ["anim.png": CGSize(width: 64, height: 48), "still.png": CGSize(width: 64, height: 48)]
        stub.animated = ["anim.png": ([0.03, 0.03, 0.03], counter)]
        load(paragraphs(80, images: [0: "anim", 60: "still"]))
        waitUntil { stub.requests.count == 1 }
        stub.answer(0)
        waitUntil { store.isAnimating }
        waitUntil("frames step") { counter.count.load(ordering: .relaxed) >= 3 }
        // Scrolled away, the timer stops; a still image never starts it.
        scroll(toBlock: 60)
        waitUntil { !store.isAnimating }
        waitUntil { stub.count("still.png") == 1 }
        stub.answer(stub.requests.count - 1)
        waitUntil { view.snapshot.layouts[60].drawsImages }
        settle(0.1)
        XCTAssertFalse(store.isAnimating)
        let stepped = counter.count.load(ordering: .relaxed)
        settle(0.15)
        XCTAssertEqual(counter.count.load(ordering: .relaxed), stepped, "paused while not visible")
        // Back in view it plays; hidden, it stops.
        scroll(toBlock: 0)
        waitUntil { store.isAnimating }
        view.setVisible(false)
        XCTAssertFalse(store.isAnimating)
    }

    func testEvictedImagesAreRequestedAgainWhenNeeded() throws {
        store.limits = ImageStore.Limits(count: 2, bytes: .max)
        stub.sizes = ["a.png": CGSize(width: 50, height: 50), "b.png": CGSize(width: 50, height: 50),
                      "c.png": CGSize(width: 50, height: 50)]
        load(paragraphs(140, images: [10: "a", 70: "b", 130: "c"]))
        for (block, source) in [(10, "a.png"), (70, "b.png"), (130, "c.png")] {
            scroll(toBlock: block)
            waitUntil { stub.count(source) == 1 }
            stub.answerAll()
            waitUntil { view.snapshot.layouts[block].drawsImages }
            settle()
        }
        XCTAssertEqual(view.retainedImageCount, 2)
        XCTAssertNil(store.image(for: "a.png"), "the least recently visible goes first")
        XCTAssertNotNil(store.image(for: "c.png"))
        // Its size stays, so coming back lays out nothing and asks for the image again.
        let layout = view.snapshot.layouts[10]
        scroll(toBlock: 10)
        waitUntil { stub.count("a.png") == 2 }
        XCTAssertEqual(stub.requests.last?.displaySize, CGSize(width: 50, height: 50))
        stub.answerAll()
        waitUntil { store.image(for: "a.png") != nil }
        XCTAssertTrue(view.snapshot.layouts[10] === layout)
    }

    func testShowingADocumentAgainKeepsItsImageLayouts() throws {
        stub.sizes = ["a.png": CGSize(width: 120, height: 90)]
        let text = paragraphs(10, images: [2: "a"])
        load(text)
        waitUntil { stub.requests.count == 1 }
        stub.answer(0)
        waitUntil { view.snapshot.layouts[2].drawsImages && view.snapshot.isComplete }
        let saved = view.snapshot
        let other = "# Other"
        let shown = expectation(description: "other")
        shown.assertForOverFulfill = false
        view.onInstall = { if $0.document.source == other { shown.fulfill() } }
        view.setSource(other, reusing: nil)
        wait(for: [shown], timeout: 5)
        let again = expectation(description: "again")
        again.assertForOverFulfill = false
        view.onInstall = { if $0.document.source == text, $0.isComplete { again.fulfill() } }
        stub.immediate = ["a.png"]
        view.setSource(text, reusing: saved)
        wait(for: [again], timeout: 5)
        // Laid out as before, image and all, and the image comes back.
        XCTAssertTrue(zip(view.snapshot.layouts, saved.layouts).allSatisfy { $0 === $1 })
        waitUntil { store.image(for: "a.png") != nil }
        settle(0.1)
        XCTAssertTrue(view.snapshot.layouts[2] === saved.layouts[2])
    }
}
