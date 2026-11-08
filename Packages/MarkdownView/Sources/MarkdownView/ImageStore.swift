import AppKit

/// Requests, keeps, and animates the images of one view's document through
/// the host's `MarkdownImageProvider`. It never delays an install: images
/// are asked for after a snapshot is shown, and the layout picks them up in
/// a later relayout.
///
/// - **Scheduling:** after an install, a scroll, a load, or showing the
///   view, one pass on the next turn of the run loop asks for the images on
///   the visible lines first, then those within a screen below and above, in
///   display order, at most `maximumRequests` at a time. Requests go by
///   source, so one source in several places, or at several sizes, is one
///   request. Requests for images more than two screens away are cancelled,
///   and so is everything when the view is hidden or shows another
///   document. Nothing is asked for while hidden.
/// - **Sizes:** a loaded image's natural size goes into `sizes`, an input of
///   layout, and the view lays out again only the blocks holding it.
/// - **Failures** are remembered by source until another document is shown,
///   so the alt text stays and nothing is asked again; a changed source is a
///   new request.
/// - **Retention:** decoded images are kept up to `limits` (512 images and
///   16 MiB of pixels per view), evicting the least recently visible first.
///   Images on screen are never evicted, so a screen full of images can
///   exceed the limits, by at most the screen's pixels. An evicted image
///   keeps its size, so layout does not change, and is asked for again when
///   needed, from the host's cache if it has one.
/// - **Animation:** one timer steps the frames of the animated images on
///   screen, decoding each next frame off the main thread, and redraws only
///   their rectangles. It stops when none is on screen or the view is hidden.
@MainActor
final class ImageStore {
    struct Limits {
        var count = 512
        var bytes = 16 << 20
    }

    private(set) weak var provider: (any MarkdownImageProvider)?
    var limits = Limits()
    var maximumRequests = 8
    /// Called when `sizes` changed, to lay out again.
    var onSizesChanged: (@MainActor () -> Void)?
    /// The natural sizes of the loaded images: what layout sees.
    private(set) var sizes = ImageSizes.none
    private(set) var retainedBytes = 0
    /// Requests made per source, cancelled or not; for tests.
    private(set) var requestCounts: [String: Int] = [:]

    private unowned let view: MarkdownDocumentView
    /// Sizes changed since `sizes`, published on the next turn of the run
    /// loop so that loads finishing together lay out once.
    private var pendingSizes: [String: CGSize]?
    private var failed: Set<String> = []
    private var retained: [String: Retained] = [:]
    private var requests: [String: Pending] = [:]
    private var nextToken = 0
    /// Counts passes, for least-recently-visible eviction.
    private var clock: UInt64 = 0
    /// Where the images on screen at the last pass are drawn, by source,
    /// for those laid out with a size.
    private var onScreen: [String: [CGRect]] = [:]
    /// Every image on the visible lines at the last pass, which eviction
    /// passes over.
    private var visibleSources: Set<String> = []
    private var animating: Set<String> = []
    private var isShown = true
    /// After another document is shown, nothing is asked for until the
    /// snapshot of this source generation installs.
    private var awaitedSource: UInt64 = 0
    private var installedSource: UInt64 = 0
    private var isPassScheduled = false
    private var timer: Timer?
    private let frameQueue = DispatchQueue(label: "MarkdownView.frames", qos: .utility)

    private struct Retained {
        let image: MarkdownImage
        /// The width in points and the scale it was asked for.
        let shownWidth: CGFloat
        let scale: CGFloat
        var lastUse: UInt64
        var current: CGImage
        var frame = 0
        var next: CGImage?
        var isDecoding = false
        /// When the next frame is due, while it animates.
        var due: TimeInterval?
        /// A frame failed to decode, so it stays on the current one.
        var isStill = false
    }

    private struct Pending {
        let token: Int
        var handle: MarkdownImageRequest?
    }

    init(view: MarkdownDocumentView) {
        self.view = view
    }

    /// The backing scale to load images for instead of the window's; for tests.
    var scaleOverride: CGFloat?

    var retainedCount: Int { retained.count }
    var requestsInFlight: Int { requests.count }
    var isAnimating: Bool { timer != nil }

    /// The frame to draw for `source`, if its image is kept.
    func image(for source: String) -> CGImage? { retained[source]?.current }

    func setProvider(_ provider: (any MarkdownImageProvider)?) {
        guard provider !== self.provider else { return }
        cancelAll()
        failed.removeAll()
        self.provider = provider
        schedulePass()
    }

    /// Another document is shown, whose source generation is `source`:
    /// nothing of the last one applies, except `sizes`, the sizes its
    /// reused snapshot was laid out with, so its layouts stay.
    func reset(sizes: ImageSizes, source: UInt64) {
        cancelAll()
        stopAnimating()
        failed.removeAll()
        retained.removeAll()
        retainedBytes = 0
        onScreen.removeAll()
        visibleSources.removeAll()
        pendingSizes = nil
        self.sizes = sizes
        awaitedSource = source
    }

    /// A snapshot of `source` installed.
    func didInstall(source: UInt64) {
        installedSource = max(installedSource, source)
        schedulePass()
    }

    func setShown(_ shown: Bool) {
        isShown = shown
        if shown {
            schedulePass()
        } else {
            cancelAll()
            stopAnimating()
        }
    }

    func schedulePass() {
        guard !isPassScheduled else { return }
        isPassScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.pass() }
        }
    }

    // MARK: Requests

    private func pass() {
        isPassScheduled = false
        let snapshot = view.snapshot
        let visible = view.visibleRect
        guard isShown, installedSource >= awaitedSource, let provider, !visible.isEmpty else {
            onScreen.removeAll()
            visibleSources.removeAll()
            return updateAnimation()
        }
        clock += 1
        let scale = scaleOverride ?? view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let margin = max(visible.height, 200)
        let blocks = snapshot.document.blocks
        // What is wanted, in order: the visible lines, then a screen below and above.
        var wanted: [(source: String, width: CGFloat)] = []
        var slots: [String: Int] = [:]
        visibleSources.removeAll(keepingCapacity: true)
        for (index, window) in [(visible.minY, visible.maxY), (visible.maxY, visible.maxY + margin),
                                (visible.minY - margin, visible.minY)].enumerated() {
            snapshot.forEachImage(in: window.0, window.1) { block, image, width in
                let source = blocks[block].images[image].source
                if index == 0 {
                    visibleSources.insert(source)
                    retained[source]?.lastUse = clock
                }
                if let slot = slots[source] {
                    wanted[slot].width = max(wanted[slot].width, width)
                } else {
                    slots[source] = wanted.count
                    wanted.append((source, width))
                }
            }
        }
        if !requests.isEmpty {
            var kept = Set(slots.keys)
            snapshot.forEachImage(in: visible.minY - 2 * margin, visible.maxY + 2 * margin) { block, image, _ in
                kept.insert(blocks[block].images[image].source)
            }
            for (source, pending) in requests where !kept.contains(source) {
                pending.handle?.cancel()
                requests[source] = nil
            }
        }
        for need in wanted {
            guard requests.count < maximumRequests else { break }
            guard need.width > 0, requests[need.source] == nil, !failed.contains(need.source),
                  !isAdequate(need.source, width: need.width, scale: scale) else { continue }
            start(need.source, width: need.width, scale: scale, provider: provider)
        }
        collectOnScreen(snapshot, in: visible)
        updateAnimation()
    }

    /// Whether the kept image of `source` is sharp enough at `width` points
    /// and `scale`: it was asked for at least that large, or it has every
    /// pixel the image has.
    private func isAdequate(_ source: String, width: CGFloat, scale: CGFloat) -> Bool {
        guard let entry = retained[source] else { return false }
        let shown = ImageSizes.displaySize(entry.image.size, fitting: width).width
        return (shown <= entry.shownWidth + 0.5 && scale <= entry.scale)
            || CGFloat(entry.image.image.width) >= entry.image.size.width * scale - 0.5
    }

    private func start(_ source: String, width: CGFloat, scale: CGFloat, provider: any MarkdownImageProvider) {
        nextToken += 1
        let token = nextToken
        // Once the natural size is known, the exact size it shows at.
        let size = currentSize(source).map { ImageSizes.displaySize($0, fitting: width) }
            ?? CGSize(width: width, height: .infinity)
        requests[source] = Pending(token: token)
        requestCounts[source, default: 0] += 1
        let handle = provider.requestImage(source: source, displaySize: size, scale: scale) { [weak self] result in
            self?.finish(source, token: token, width: width, scale: scale, result: result)
        }
        // A completion before returning already removed the request.
        if requests[source]?.token == token { requests[source]?.handle = handle }
    }

    private func finish(_ source: String, token: Int, width: CGFloat, scale: CGFloat,
                        result: Result<MarkdownImage, any Error>) {
        guard requests[source]?.token == token else { return }
        requests[source] = nil
        if case .success(let image) = result, ImageSizes.isValid(image.size) {
            retain(image, for: source, shownWidth: ImageSizes.displaySize(image.size, fitting: width).width, scale: scale)
            if currentSize(source) != image.size {
                setSize(image.size, for: source)
            } else {
                for rect in onScreen[source] ?? [] { view.setNeedsDisplay(rect) }
            }
        } else {
            failed.insert(source)
            release(source)
            if currentSize(source) != nil { setSize(nil, for: source) }
        }
        schedulePass()
    }

    private func cancelAll() {
        for pending in requests.values { pending.handle?.cancel() }
        requests.removeAll()
    }

    // MARK: Sizes

    private func currentSize(_ source: String) -> CGSize? {
        pendingSizes.map { $0[source] } ?? sizes[source]
    }

    private func setSize(_ size: CGSize?, for source: String) {
        if pendingSizes == nil {
            pendingSizes = sizes.sizes
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.publishSizes() }
            }
        }
        pendingSizes?[source] = size
    }

    private func publishSizes() {
        guard let pending = pendingSizes else { return }
        pendingSizes = nil
        sizes = ImageSizes(pending)
        onSizesChanged?()
    }

    // MARK: Retention

    private func retain(_ image: MarkdownImage, for source: String, shownWidth: CGFloat, scale: CGFloat) {
        release(source)
        retained[source] = Retained(image: image, shownWidth: shownWidth, scale: scale, lastUse: clock,
                                    current: image.image)
        retainedBytes += image.byteCount
        while retained.count > limits.count || retainedBytes > limits.bytes {
            var victim: String?
            var oldest = UInt64.max
            for (key, entry) in retained
                where entry.lastUse < oldest && !visibleSources.contains(key) && key != source {
                victim = key
                oldest = entry.lastUse
            }
            guard let victim else { break }
            release(victim)
        }
    }

    private func release(_ source: String) {
        guard let entry = retained.removeValue(forKey: source) else { return }
        retainedBytes -= entry.image.byteCount
        animating.remove(source)
    }

    /// Where each image on the visible lines is drawn.
    private func collectOnScreen(_ snapshot: MarkdownSnapshot, in visible: CGRect) {
        onScreen.removeAll(keepingCapacity: true)
        let offsets = view.codeOffsets
        for index in snapshot.blockRange(intersecting: visible.minY, visible.maxY)
            where snapshot.layouts[index].drawsImages {
            let images = snapshot.document.blocks[index].images
            let origin = CGPoint(x: snapshot.columnX, y: snapshot.blockTops[index])
            snapshot.layouts[index].forEachImage(intersecting: visible, at: origin, codeOffset: {
                offsets.isEmpty ? 0 : offsets[CodeBlockID(block: index, code: $0)] ?? 0
            }) { image, rect, _ in
                guard images.indices.contains(image) else { return }
                onScreen[images[image].source, default: []].append(rect)
            }
        }
    }

    // MARK: Animation

    /// Starts the animated images on screen and pauses the others.
    private func updateAnimation() {
        let now = ProcessInfo.processInfo.systemUptime
        let shown = Set(onScreen.keys.filter { retained[$0]?.image.isAnimated == true && retained[$0]?.isStill == false })
        for source in animating.subtracting(shown) { retained[source]?.due = nil }
        for source in shown.subtracting(animating) {
            guard let entry = retained[source] else { continue }
            retained[source]?.due = now + Self.delay(of: entry)
            prefetch(source)
        }
        animating = shown
        scheduleTimer()
    }

    private func stopAnimating() {
        for source in animating { retained[source]?.due = nil }
        animating.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private static func delay(of entry: Retained) -> TimeInterval {
        let delays = entry.image.frameDelays
        return max(delays.indices.contains(entry.frame) ? delays[entry.frame] : 0.1, 0.02)
    }

    /// One timer for the earliest frame due, with some tolerance.
    private func scheduleTimer() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let earliest = animating.compactMap({ retained[$0]?.due }).min() else {
            timer?.invalidate()
            timer = nil
            return
        }
        let interval = max(earliest - now, 0.001)
        if let timer, timer.isValid, abs(timer.fireDate.timeIntervalSinceNow - interval) < 0.002 { return }
        timer?.invalidate()
        let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        next.tolerance = min(interval * 0.1, 0.01)
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func tick() {
        timer = nil
        let now = ProcessInfo.processInfo.systemUptime
        for source in animating {
            guard var entry = retained[source], let due = entry.due, due <= now + 0.002 else { continue }
            if let next = entry.next {
                entry.current = next
                entry.next = nil
                entry.frame = (entry.frame + 1) % entry.image.frameCount
                let delay = Self.delay(of: entry)
                entry.due = due + delay < now ? now + delay : due + delay
                retained[source] = entry
                for rect in onScreen[source] ?? [] { view.setNeedsDisplay(rect) }
                prefetch(source)
            } else {
                // The next frame is still decoding.
                entry.due = now + 0.01
                retained[source] = entry
                prefetch(source)
            }
        }
        scheduleTimer()
    }

    /// Decodes the frame after the current one on the frame queue.
    private func prefetch(_ source: String) {
        guard var entry = retained[source], !entry.isDecoding, entry.next == nil else { return }
        entry.isDecoding = true
        retained[source] = entry
        let image = entry.image
        let index = (entry.frame + 1) % image.frameCount
        frameQueue.async { [weak self] in
            let frame = image.frame(at: index)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.decoded(frame, index: index, of: image, for: source) }
            }
        }
    }

    private func decoded(_ frame: CGImage?, index: Int, of image: MarkdownImage, for source: String) {
        guard var entry = retained[source], entry.image === image else { return }
        entry.isDecoding = false
        if let frame {
            if (entry.frame + 1) % image.frameCount == index { entry.next = frame }
        } else {
            entry.isStill = true
            entry.due = nil
            animating.remove(source)
        }
        retained[source] = entry
    }
}

extension MarkdownSnapshot {
    /// Calls `body` with each image on the lines and table rows laid out in
    /// `minY..<maxY` (view coordinates), in display order: its block, its
    /// index in the block's images, and the widest it may be shown there.
    /// Work is proportional to the lines and rows in the window, plus a
    /// binary search per block; estimates are passed over.
    func forEachImage(in minY: CGFloat, _ maxY: CGFloat, _ body: (_ block: Int, _ image: Int, _ width: CGFloat) -> Void) {
        guard maxY > minY else { return }
        for index in blockRange(intersecting: minY, maxY) {
            let images = document.blocks[index].images
            let layout = layouts[index]
            guard !images.isEmpty, !layout.isEstimate, layout.imageWidths.count == images.count else { continue }
            let top = blockTops[index]
            var lower = Int.max
            var upper = Int.min
            var line = layout.firstLine(endingBelow: minY - top)
            while line < layout.lines.count, top + layout.lines[line].top < maxY {
                lower = min(lower, layout.lines[line].range.lowerBound)
                upper = max(upper, layout.lines[line].range.upperBound)
                line += 1
            }
            for table in layout.tables where top + table.rect.maxY > minY && top + table.rect.minY < maxY {
                let rows = table.rows(intersecting: minY - top - table.rect.minY, maxY - top - table.rect.minY)
                guard !rows.isEmpty else { continue }
                lower = min(lower, table.structure.cell(rows.lowerBound, 0).lowerBound)
                upper = max(upper, table.structure.cell(rows.upperBound - 1, table.structure.columnCount - 1).upperBound)
            }
            guard lower < upper else { continue }
            var low = 0
            var high = images.count
            while low < high {
                let mid = (low + high) / 2
                if images[mid].range.upperBound <= lower { low = mid + 1 } else { high = mid }
            }
            while low < images.count, images[low].range.lowerBound < upper {
                body(index, low, layout.imageWidths[low])
                low += 1
            }
        }
    }
}
