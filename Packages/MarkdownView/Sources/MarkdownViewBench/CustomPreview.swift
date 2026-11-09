import AppKit
import MarkdownView

/// One `onTimings` callback, stamped when it reached the bench.
struct CustomRender {
    let at: UInt64
    let timings: Timings
}

/// The library's phase times for one repetition, in milliseconds.
struct LibraryTimings: Codable {
    let blocks: Int
    let complete: Bool
    let parse: Double
    let layout: Double
    let install: Double
    let draw: Double

    init(_ timings: Timings) {
        func ms(_ duration: Duration) -> Double {
            round2(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
        }
        blocks = timings.blockCount
        complete = timings.isComplete
        parse = ms(timings.parse)
        layout = ms(timings.layout)
        install = ms(timings.install)
        draw = ms(timings.draw)
    }
}

struct ScrollResult: Codable {
    let passes: Int
    let frames: Int
    let documentHeight: Double
    let viewportHeight: Double
    /// Frames over 1000/144 ms, the owner's display rate.
    let over144Hz: Int
    /// Frames over 16.7 ms.
    let over60Hz: Int
}

/// Hosts a `MarkdownPreviewView` and waits for its renders, as `WebKitPreview` does for WebKit.
@MainActor
final class CustomPreview {
    let view: MarkdownPreviewView
    private var waiter: CheckedContinuation<(first: CustomRender, complete: CustomRender), Error>?
    private var waiterID = 0
    /// A render that finished before anyone waited.
    private var ready: (first: CustomRender, complete: CustomRender)?
    private var first: CustomRender?
    private var finishedGeneration: UInt64 = 0
    /// Every report, before `nextRender` filters them; the trace replay logs them all.
    var observer: ((CustomRender) -> Void)?
    /// `now()` of the last report, and of the last complete one: image loads lay out and draw again.
    private(set) var lastReportAt: UInt64 = 0
    private(set) var lastCompleteAt: UInt64 = 0

    init(frame: NSRect) {
        view = MarkdownPreviewView(frame: frame)
        view.onTimings = { [weak self] timings in self?.receive(timings) }
    }

    /// The view reports after the first draw of each installed snapshot: on an open, the visible
    /// area first (not complete), then everything.
    private func receive(_ timings: Timings) {
        let render = CustomRender(at: now(), timings: timings)
        lastReportAt = render.at
        if timings.isComplete { lastCompleteAt = render.at }
        observer?(render)
        guard timings.generation > finishedGeneration else { return }
        if first?.timings.generation != timings.generation { first = render }
        guard timings.isComplete else { return }
        finishedGeneration = timings.generation
        let result = (first: first ?? render, complete: render)
        first = nil
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: result)
        } else {
            ready = result
        }
    }

    /// Shows another document at its top, the way the app's `CustomMarkdownPreview.show` does:
    /// the source, then the document's scroll fraction, which waits for that source's snapshot.
    func show(_ text: String) {
        view.setSource(text)
        view.scrollFraction = 0
    }

    /// Forgets renders nobody waited for, such as the relayouts after image loads, so the next
    /// `nextRender` waits for the next source.
    func discardReady() {
        ready = nil
        first = nil
    }

    /// Waits for the next source to be drawn completely, returning its first and complete draws.
    func nextRender(timeout: Duration) async throws -> (first: CustomRender, complete: CustomRender) {
        if let ready {
            self.ready = nil
            return ready
        }
        waiterID += 1
        let id = waiterID
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, id == self.waiterID, let waiter = self.waiter else { return }
            self.waiter = nil
            waiter.resume(throwing: BenchError.timeout)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}

struct CustomOpen {
    let startup: Double
    let firstScreen: Double
    let open: Double
    let first: Timings
    let complete: Timings
    /// When the open asked for images: how long they took to settle.
    let images: ImageSettle?
}

/// The image loads after a render, timed from the render's start.
struct ImageSettle {
    /// The last load or failure delivered to the view.
    let loaded: Double?
    /// The view's last complete draw by the time the images settled: the open's own render when
    /// every load finished before it, else the last relayout for image sizes. Earlier than
    /// `loaded` when the last load only replaced an image with a sharper copy, which redraws
    /// without a relayout.
    let shown: Double?
}

/// Per document: the image requests of one open, and what the view keeps.
struct ImageResult: Codable {
    var requested: Int
    var loaded: Int
    var failed: Int
    /// Custom: requests the view cancelled.
    var cancelled: Int?
    /// Custom: failures by reason (`blocked`, `missing`, `corrupt`, `too-large`, `network`).
    var failures: [String: Int]?
    /// Custom: `retainedImageCount` and `retainedImageBytes` once that open's images settled.
    var retainedCount: Int?
    var retainedBytes: Int?
    /// Custom: the same at the end, after the scroll passes and the idle sample.
    var endRetainedCount: Int?
    var endRetainedBytes: Int?
    /// Custom: requests over the whole document's measurement (opens, tab switches, scrolls).
    var documentRequests: Int?
    /// WebKit: image files the scheme handler served and refused over the whole measurement.
    var served: Int?
    var refused: Int?
}

/// The image provider in the header.
struct ImageProviderInfo: Codable {
    let provider: String
    let latencyMs: Double
    let remoteFixtures: Int
}

/// Lets one run loop turn pass, so display, timers and the watchdog's observer run.
@MainActor
func nextRunLoopTurn() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        RunLoop.main.perform { continuation.resume() }
    }
}

extension Runner {
    static let customDefinitions = [
        "rendered": "the view's onTimings callback for the complete snapshot (Timings.isComplete) of the source; the view sends it from the main queue right after the first draw that follows the install",
        "startup": "new MarkdownPreviewView set as the window's content view and tiled, before setSource",
        "firstScreen": "setSource on a new view until onTimings for the first snapshot drawn: the visible-area step of an open, or the complete snapshot when that covers the visible area",
        "open": "new view until the document is rendered; includes startup",
        "tabSwitch": "warm view showing a small other document: setSource(document), then scrollFraction = 0 as the app's adapter does, until rendered",
        "update": "one keystroke inserted in the paragraph line nearest the middle, then the bench's 200 ms debounce (the app's Phase 1 debounce; the library has none), then setSource, until rendered",
        "updateWork": "update from setSource, after the debounce, until rendered",
        "updateMain": "the update's main-thread phases from the library's Timings: install plus the first draw",
        "scrollFrame": "one step of a top-to-bottom pass in viewport-height steps: NSView.scroll, setNeedsDisplay(visibleRect), window.displayIfNeeded and CATransaction.flush, with a run loop turn between frames; passes repeat up to the repetitions, stopping after 5,000 frames once a pass is complete",
        "scrollDraw": "after each scrollFrame, the view drawing the same visible area into a bitmap (cacheDisplay): the draw without the commit",
        "scroll": "over144Hz counts frames over 1000/144 ms, over60Hz frames over 16.7 ms",
        "library": "per repetition, the library's Timings in ms from onTimings: parse, layout (both steps of an open), install and draw of the snapshot reported; firstScreen holds the first report of an open, open the complete one",
        "memoryMiB": "process: phys_footprint of the bench after the idle sample, with one view showing the document; view: footprint after a new view rendered the edited document and settled 1 s, minus the footprint before it was created (no other view, 0.5 s settle, malloc pressure relief); viewHeap: malloc size_in_use over the same span; no helper processes. With idleSeconds 0, process only, right after the scroll passes",
        "idleCPUPercent": "user+system CPU of the bench over idleSeconds, starting 1 s after the scroll passes, as percent of one core",
        "percentiles": "nearest rank over the repetitions; aggregate pools every repetition of every ok document",
        "imagesLoaded": "per open that asked for images: new view until the last image load or failure reached the view, once the view had no request in flight and nothing happened for 150 ms; covers the visible images and the screen below and above that the view asks for next",
        "imagesShown": "per open with a loaded image: new view until the view's last complete draw (onTimings) by the time its images settled: the open's render when every load finished before it, else the last relayout for image sizes; earlier than imagesLoaded when the last load only replaced an image with a sharper copy, which redraws without a relayout",
        "images": "custom: requests of the last open (requested, loaded, failed, cancelled, failures by reason), retainedImageCount/Bytes once its images settled and again at the end (endRetained*), and documentRequests over the whole measurement; the bench's provider decodes every request (no decoded cache), and remote https://img.example.invalid images come from the generated fixtures after --image-latency"
    ]
    static let scrollFrameLimit = 5_000

    func disposeCustom() {
        guard let customPreview else { return }
        customPreview.view.onTimings = nil
        customPreview.view.removeFromSuperview()
        window.contentView = NSView()
        self.customPreview = nil
    }

    /// The provider for custom mode, with the remote fixtures of `manifest` when it has an
    /// `images` section (the generated manifest).
    func makeImageProvider(manifest url: URL) async -> BenchImageProvider {
        let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
        let rootValue = json["root"] as? String ?? "."
        let root = rootValue.hasPrefix("/") ? URL(fileURLWithPath: rootValue)
            : url.deletingLastPathComponent().appendingPathComponent(rootValue).standardizedFileURL
        return BenchImageProvider(latencyMs: options.imageLatency, remote: await RemoteFixtures.load(RemoteFixtures.items(in: json), root: root))
    }

    var imageProviderInfo: ImageProviderInfo? {
        imageProvider.map { ImageProviderInfo(provider: "BenchImageProvider", latencyMs: $0.latencyMs,
                                              remoteFixtures: $0.remote.count) }
    }

    /// `directory` is the document's folder, where relative image sources resolve.
    func openCustom(_ text: String, directory: URL? = nil, timeout: Duration? = nil) async throws -> CustomOpen {
        dispose()
        disposeCustom()
        let opened = try await interval("open") {
            let start = now()
            imageProvider?.documentDirectory = directory
            imageProvider?.resetStats()
            let preview = CustomPreview(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
            preview.view.imageProvider = imageProvider
            preview.view.codeHighlighter = options.codeHighlighter
            customPreview = preview
            window.contentView = preview.view
            preview.view.tile()
            let ready = now()
            preview.show(text)
            let render = try await preview.nextRender(timeout: timeout ?? self.timeout)
            return (start, render.complete.at, CustomOpen(startup: milliseconds(start, ready), firstScreen: milliseconds(ready, render.first.at),
                                      open: milliseconds(start, render.complete.at), first: render.first.timings,
                                      complete: render.complete.timings, images: nil))
        }
        guard let preview = customPreview,
              let images = try await interval("images", {
                  try await settleImages(preview, since: opened.0, renderedAt: opened.1)
              }) else { return opened.2 }
        let open = opened.2
        return CustomOpen(startup: open.startup, firstScreen: open.firstScreen, open: open.open, first: open.first,
                          complete: open.complete, images: images)
    }

    /// Waits until the view has no image request in flight and neither the provider nor the
    /// view did anything for 150 ms, then drops the relayout renders. Nil when nothing was asked
    /// for since `start`.
    func settleImages(_ preview: CustomPreview, since start: UInt64, renderedAt: UInt64? = nil) async throws -> ImageSettle? {
        guard let provider = imageProvider else { return nil }
        // The view asks on the run loop turn after an install.
        await nextRunLoopTurn()
        await nextRunLoopTurn()
        guard provider.stats.inFlight > 0 || provider.stats.lastActivity >= start else { return nil }
        let deadline = now() + UInt64(options.timeout * 1e9)
        while provider.stats.inFlight > 0 || milliseconds(max(provider.stats.lastActivity, preview.lastReportAt), now()) < 150 {
            guard now() < deadline else { throw BenchError.unavailable("images did not settle") }
            try await Task.sleep(for: .milliseconds(5))
        }
        preview.discardReady()
        let completion = provider.stats.lastCompletion.flatMap { $0 >= start ? $0 : nil }
        let relayout = renderedAt.flatMap { provider.stats.loaded > 0 ? max($0, preview.lastCompleteAt) : nil }
        return ImageSettle(loaded: completion.map { round2(milliseconds(start, $0)) },
                           shown: relayout.map { round2(milliseconds(start, $0)) })
    }

    func measureCustom(_ entry: ManifestEntry) async -> (DocumentResult, [String: [Double]]) {
        var result = DocumentResult(path: entry.path, name: entry.name)
        guard let url = entry.url else {
            result.status = "skipped"
            result.error = "missing from the manifest"
            return (result, [:])
        }
        let (read, bytes, problem) = Self.read(url)
        result.bytes = bytes
        guard var text = read else {
            result.status = "skipped"
            result.error = problem
            return (result, [:])
        }
        var samples: [String: [Double]] = [:]
        var library: [String: [LibraryTimings]] = [:]
        let directory = url.deletingLastPathComponent()
        let requestsBefore = imageProvider?.totalRequested ?? 0
        do {
            for _ in 0..<options.repetitions {
                let opened = try await openCustom(text, directory: directory)
                samples["startup", default: []].append(opened.startup)
                samples["firstScreen", default: []].append(opened.firstScreen)
                samples["open", default: []].append(opened.open)
                library["firstScreen", default: []].append(LibraryTimings(opened.first))
                library["open", default: []].append(LibraryTimings(opened.complete))
                if let images = opened.images {
                    if let loaded = images.loaded { samples["imagesLoaded", default: []].append(loaded) }
                    if let shown = images.shown { samples["imagesShown", default: []].append(shown) }
                }
            }
            guard let preview = customPreview else { throw BenchError.navigation("no preview") }
            if let provider = imageProvider, provider.stats.requested > 0 {
                let stats = provider.stats
                result.images = ImageResult(requested: stats.requested, loaded: stats.loaded, failed: stats.failed,
                                            cancelled: stats.cancelled, failures: stats.failures,
                                            retainedCount: preview.view.retainedImageCount,
                                            retainedBytes: preview.view.retainedImageBytes)
            }
            for _ in 0..<options.repetitions {
                preview.show(Self.otherText)
                _ = try await preview.nextRender(timeout: timeout)
                _ = try await settleImages(preview, since: now())
                let (start, render) = try await interval("tabSwitch") {
                    let start = now()
                    preview.show(text)
                    return (start, try await preview.nextRender(timeout: timeout))
                }
                samples["tabSwitch", default: []].append(milliseconds(start, render.complete.at))
                library["tabSwitch", default: []].append(LibraryTimings(render.complete.timings))
                _ = try await settleImages(preview, since: start)
            }
            let edit = EditPoint.find(in: text)
            result.edit = edit
            for index in 0..<options.repetitions {
                let typed = NSMutableString(string: text)
                typed.insert(String(Self.keystrokes[index % Self.keystrokes.count]), at: edit.offset + index)
                text = typed as String
                let start = now()
                try await interval("debounce") { try await Task.sleep(for: .milliseconds(200)) }
                let (work, render) = try await interval("update") {
                    let work = now()
                    preview.view.setSource(text)
                    return (work, try await preview.nextRender(timeout: timeout))
                }
                let timings = LibraryTimings(render.complete.timings)
                samples["update", default: []].append(milliseconds(start, render.complete.at))
                samples["updateWork", default: []].append(milliseconds(work, render.complete.at))
                samples["updateMain", default: []].append(timings.install + timings.draw)
                library["update", default: []].append(timings)
                _ = try await settleImages(preview, since: work)
            }
            let scrollStart = now()
            let (scroll, frames, draws) = await interval("scroll") { await scrollThrough(preview) }
            result.scroll = scroll
            samples["scrollFrame"] = frames
            samples["scrollDraw"] = draws
            _ = try await settleImages(preview, since: scrollStart)
            if options.idleSeconds > 0 {
                try await Task.sleep(for: .seconds(1)) // settle
                result.idleCPUPercent = try await interval("idle") { try await ProcessMetrics.idleCPU(seconds: options.idleSeconds) }
                let process = round1(Double(ProcessMetrics.ownFootprint()) / 1_048_576)
                recordEndImages(&result, preview, requestsBefore: requestsBefore)
                result.memoryMiB = try await viewMemory(text, directory: directory, process: process)
            } else {
                recordEndImages(&result, preview, requestsBefore: requestsBefore)
                let process = round1(Double(ProcessMetrics.ownFootprint()) / 1_048_576)
                result.memoryMiB = Memory(process: process, helpers: 0, total: process, helpersByKind: [:], helperProcesses: 0)
            }
        } catch {
            result.status = "failed"
            result.error = error.localizedDescription
        }
        disposeCustom()
        result.library = library.isEmpty ? nil : library
        result.ms = Dictionary(uniqueKeysWithValues: samples.compactMap { key, values in Summary(values).map { (key, $0) } })
        return (result, samples)
    }

    /// Scrolls from the top to the bottom in viewport-height steps, drawing the visible area each
    /// step. Returns each frame's time and, measured after it, the time the view takes to draw the
    /// same area into a bitmap.
    private func scrollThrough(_ preview: CustomPreview) async -> (ScrollResult, [Double], [Double]) {
        let viewport = preview.view.contentView.bounds.height
        guard let canvas = preview.view.documentView, viewport > 0 else {
            return (ScrollResult(passes: 0, frames: 0, documentHeight: 0, viewportHeight: 0, over144Hz: 0, over60Hz: 0), [], [])
        }
        let height = canvas.frame.height
        let last = max(height - viewport, 0)
        var frames: [Double] = []
        var draws: [Double] = []
        let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.visibleRect)
        var passes = 0
        while passes == 0 || (passes < options.repetitions && frames.count < Self.scrollFrameLimit) {
            var y: CGFloat = 0
            while true {
                let start = now()
                canvas.scroll(NSPoint(x: 0, y: y))
                canvas.setNeedsDisplay(canvas.visibleRect)
                window.displayIfNeeded()
                CATransaction.flush()
                frames.append(milliseconds(start, now()))
                if let bitmap {
                    let draw = now()
                    canvas.cacheDisplay(in: canvas.visibleRect, to: bitmap)
                    draws.append(milliseconds(draw, now()))
                }
                await nextRunLoopTurn()
                if y >= last { break }
                y = min(y + viewport, last)
            }
            passes += 1
        }
        canvas.scroll(.zero)
        return (ScrollResult(passes: passes, frames: frames.count, documentHeight: Double(height),
                             viewportHeight: Double(viewport),
                             over144Hz: frames.filter { $0 > 1000.0 / 144 }.count,
                             over60Hz: frames.filter { $0 > 16.7 }.count), frames, draws)
    }

    private func recordEndImages(_ result: inout DocumentResult, _ preview: CustomPreview, requestsBefore: Int) {
        guard result.images != nil, let provider = imageProvider else { return }
        result.images?.endRetainedCount = preview.view.retainedImageCount
        result.images?.endRetainedBytes = preview.view.retainedImageBytes
        result.images?.documentRequests = provider.totalRequested - requestsBefore
    }

    /// Footprint growth from one more view showing `text`, measured with no other view open.
    private func viewMemory(_ text: String, directory: URL, process: Double) async throws -> Memory {
        disposeCustom()
        try await Task.sleep(for: .milliseconds(500))
        ProcessMetrics.relieveHeap()
        let footprint = ProcessMetrics.ownFootprint()
        let heap = ProcessMetrics.heapInUse()
        _ = try await openCustom(text, directory: directory)
        try await Task.sleep(for: .seconds(1))
        let mib = 1_048_576.0
        return Memory(process: process, helpers: 0, total: process, helpersByKind: [:], helperProcesses: 0,
                      view: round1(Double(Int64(ProcessMetrics.ownFootprint()) - Int64(footprint)) / mib),
                      viewHeap: round1(Double(Int64(ProcessMetrics.heapInUse()) - Int64(heap)) / mib))
    }
}
