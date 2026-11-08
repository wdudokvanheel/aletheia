import Dispatch
import Foundation
import os
import Synchronization

/// Signpost intervals named parse, layout, install, and draw, for Instruments.
let signposter = OSSignposter(subsystem: "MarkdownView", category: .pointsOfInterest)

/// How long each phase of the last preview update took.
public struct Timings: Sendable, Equatable {
    public var generation: UInt64
    public var blockCount = 0
    /// Zero when the update only re-laid out existing blocks, as on resize.
    public var parse = Duration.zero
    /// Off the main thread, summed over both steps of an open or resize.
    public var layout = Duration.zero
    public var install = Duration.zero
    /// The first draw after the install.
    public var draw = Duration.zero
    /// False for the visible-only first step of an open or resize.
    public var isComplete = true
    /// Blocks that kept their layout from the previous snapshot.
    public var reusedBlocks = 0
    /// Blocks laid out by this update, summed over both steps of an open or resize.
    public var laidOutBlocks = 0
    /// From submitting the update to the end of its install, including the
    /// wait for the main thread: the cost the view paces updates by.
    public var wall = Duration.zero
    /// How long the next update waits because this one exceeded the
    /// `UpdatePolicy` budget; zero within budget.
    public var pause = Duration.zero

    /// Time this update took on the main thread: the install plus the first draw.
    public var mainThread: Duration { install + draw }

    public init(generation: UInt64) {
        self.generation = generation
    }
}

/// How a `MarkdownPreviewView` paces updates while its source keeps changing.
///
/// There is no debounce: a new source starts processing as soon as no update
/// is running. At most one update is in flight; sources set meanwhile
/// coalesce, and only the newest is processed once it finishes, so nothing
/// queues up. After an update whose wall time (submission to the end of its
/// install, `Timings.wall`) exceeds `budget`, the next one waits for the
/// excess, `pauseFactor × (wall − budget)` clamped to `0...maximumPause`,
/// from the end of that install. An update just over budget then delays the
/// next one only a little, while very large documents still update at a
/// bounded rate instead of keeping a core busy while the user types: a 1 MiB
/// document whose updates take 18 ms waits 2 ms, not 36. Showing another
/// document (`setSource` followed by a scroll position) does not wait.
public struct UpdatePolicy: Sendable, Equatable {
    public var budget: Duration
    /// How many times the excess over `budget` the next update waits.
    public var pauseFactor: Double
    public var maximumPause: Duration

    public init(budget: Duration = .milliseconds(16), pauseFactor: Double = 1,
                maximumPause: Duration = .milliseconds(500)) {
        self.budget = budget
        self.pauseFactor = pauseFactor
        self.maximumPause = maximumPause
    }

    public static let standard = UpdatePolicy()

    /// The pause an update that took `wall` imposes on the next one.
    public func pause(after wall: Duration) -> Duration {
        wall > budget ? min((wall - budget) * max(pauseFactor, 0), maximumPause) : .zero
    }
}

/// What a request for a new source lays out first. The view can change it
/// until the worker reads it after parsing, so a scroll position set right
/// after `setSource`, as when another document is shown, decides it.
final class RenderPlan: Sendable {
    enum FirstStep: Sendable, Equatable {
        /// Everything that changed, at once: typing.
        case everything
        /// The area at a position in points, after every block above it, so
        /// the position is exact; the rest follows. The top of an open is 0.
        case offset(CGFloat)
        /// The area at a fraction of the height, and every block above it.
        /// Estimates below make the position approximate until the rest
        /// follows.
        case fraction(CGFloat)
    }

    private let state: Mutex<(step: FirstStep, isRead: Bool)>

    init(_ step: FirstStep) {
        state = Mutex((step, false))
    }

    /// Replaces the first step, unless the worker has read it.
    func set(_ step: FirstStep) {
        state.withLock { if !$0.isRead { $0.step = step } }
    }

    func read() -> FirstStep {
        state.withLock {
            $0.isRead = true
            return $0.step
        }
    }
}

struct RenderRequest: Sendable {
    var generation: UInt64
    var sourceGeneration: UInt64
    var source: String
    var width: CGFloat
    /// For a relayout of the same source: where the visible area starts, as a
    /// fraction of the document height.
    var scrollFraction: CGFloat
    var viewportHeight: CGFloat
    /// For a new source: what to lay out first.
    var plan: RenderPlan
    /// False during live resize, when only the visible area is laid out.
    var complete: Bool
    /// The installed snapshot, which a new source is diffed against.
    var base: MarkdownSnapshot
    /// The natural sizes of the images loaded so far. A relayout of the same
    /// source with new sizes lays out only the blocks whose images changed.
    var images: ImageSizes = .none
}

enum RenderOutcome: Sendable {
    case snapshot(MarkdownSnapshot, sourceGeneration: UInt64, timings: Timings)
    case failure(generation: UInt64, message: String)

    var generation: UInt64 {
        switch self {
        case .snapshot(let snapshot, _, _): snapshot.generation
        case .failure(let generation, _): generation
        }
    }
}

/// Parses and lays out on the pipeline's serial queue. Everything except
/// `latestGeneration` is only touched on that queue.
final class RenderWorker: @unchecked Sendable {
    let latestGeneration = Atomic<UInt64>(0)
    /// Requests that started work, rather than finding themselves superseded.
    let runs = Atomic<Int>(0)
    private let typography: Typography
    private var current: MarkdownSnapshot?
    private var currentSourceGeneration: UInt64 = 0

    init(typography: Typography) {
        self.typography = typography
    }

    func isSuperseded(_ generation: UInt64) -> Bool {
        latestGeneration.load(ordering: .relaxed) != generation
    }

    /// Produces one or two snapshots for `request`: a visible-area snapshot
    /// first when that helps, then the complete one. Gives up as soon as a
    /// newer request exists. A long table in the visible area is laid out
    /// only down to its bottom at first, with estimated heights for the rest
    /// of its rows until the complete snapshot.
    func process(_ request: RenderRequest, post: (RenderOutcome) -> Void) {
        let generation = request.generation
        guard !isSuperseded(generation) else { return }
        runs.add(1, ordering: .relaxed)
        let columnWidth = typography.column(forWidth: request.width).width
        let images = request.images
        let isCancelled: @Sendable () -> Bool = { [self] in isSuperseded(generation) }
        var timings = Timings(generation: generation)
        let base: MarkdownSnapshot
        /// Nil for a relayout, which starts at the current position.
        var firstStep: RenderPlan.FirstStep?
        /// For blocks whose layout in `base` is an estimate, earlier layouts
        /// whose tables lend rows and natural widths.
        var lent: [BlockLayout?]?

        if let current, currentSourceGeneration == request.sourceGeneration {
            if current.width == request.width, current.isComplete, current.images === images {
                timings.blockCount = current.layouts.count
                timings.reusedBlocks = current.layouts.count
                post(.snapshot(current.with(generation: generation), sourceGeneration: request.sourceGeneration,
                               timings: timings))
                return
            }
            base = current
        } else {
            // A new source: parse it in full, diff it against the installed
            // snapshot, and keep the layouts of unchanged blocks.
            let start = ContinuousClock.now
            let parsed: MarkdownDocument.ParseResult
            do {
                parsed = try signposter.withIntervalSignpost("parse") {
                    try MarkdownDocument.parse(request.source, reusing: request.base.document)
                }
            } catch {
                post(.failure(generation: generation, message: "\(error)"))
                return
            }
            timings.parse = ContinuousClock.now - start
            let document = parsed.document
            let update = BlockUpdate(baseID: request.base.id, match: parsed.match, edit: parsed.edit)
            let (reused, hints) = MarkdownSnapshot.reusableLayouts(from: request.base, match: parsed.match,
                                                                   blocks: document.blocks, columnWidth: columnWidth,
                                                                   typography: typography, images: images)
            timings.blockCount = document.blocks.count
            timings.reusedBlocks = reused.count(where: { $0 != nil })
            firstStep = request.plan.read()
            if firstStep != .everything {
                let layouts = reused.indices.map {
                    reused[$0] ?? BlockLayout.estimate(for: document.blocks[$0], columnWidth: columnWidth,
                                                       typography: typography)
                }
                base = MarkdownSnapshot(document: document, layouts: layouts, width: request.width,
                                        typography: typography, generation: generation, update: update, images: images)
                lent = hints
            } else {
                let start = ContinuousClock.now
                let layouts = signposter.withIntervalSignpost("layout") {
                    BlockLayout.layOut(document.blocks, filling: reused, hints: hints, columnWidth: columnWidth,
                                       typography: typography, images: images, isCancelled: isCancelled)
                }
                guard let layouts else { return }
                timings.layout = ContinuousClock.now - start
                timings.laidOutBlocks = layouts.count - timings.reusedBlocks
                commit(MarkdownSnapshot(document: document, layouts: layouts, width: request.width,
                                        typography: typography, generation: generation, update: update, images: images),
                       request, timings, post: post)
                return
            }
        }
        timings.blockCount = base.layouts.count
        let blocks = base.document.blocks
        /// Whether a layout of block `index` can stay.
        func isFinal(_ layout: BlockLayout, _ index: Int) -> Bool {
            layout.isFinal(for: columnWidth, images: images, block: blocks[index])
        }
        if base.generation != generation {
            timings.reusedBlocks = base.layouts.indices.count(where: { isFinal(base.layouts[$0], $0) })
        }

        // Step 1: the visible area before the rest.
        var start = ContinuousClock.now
        var layouts = base.layouts
        let target = max(request.viewportHeight, 400) * 1.5
        /// What a block's next layout can reuse: its own layout, unless that
        /// is an estimate.
        func hint(_ index: Int) -> BlockLayout? { layouts[index].isEstimate ? lent?[index] : layouts[index] }
        signposter.withIntervalSignpost("layout") {
            guard let firstStep else {
                // A relayout: from the top of the visible area down, enough
                // to fill it, serially. A table there starts at the row at
                // the top; the scroll anchor holds that row in place.
                let top = request.scrollFraction * base.totalHeight
                var index = base.firstBlock(endingBelow: top)
                var covered: CGFloat = 0
                while index < layouts.count, covered < target {
                    if !isFinal(layouts[index], index) {
                        var rows = TableRows.all
                        if blocks[index].kind == .table, let table = layouts[index].tables.first {
                            let y = top - base.blockTops[index] - table.rect.minY
                            rows = .covering(first: y > 0 ? table.row(atY: y) : 0, height: target - covered)
                        }
                        guard let layout = BlockLayout.make(blocks[index], columnWidth: columnWidth, typography: typography,
                                                            hint: hint(index), tableRows: rows, images: images,
                                                            isCancelled: isCancelled)
                        else { return }
                        layouts[index] = layout
                        timings.laidOutBlocks += 1
                    }
                    covered += layouts[index].height + layouts[index].marginBottom
                    index += 1
                }
                return
            }
            // A new source: every block down to the bottom of the area at the
            // position, in parallel, so everything above the area is laid
            // out. Estimates decide how far that is, so repeat until the laid
            // out blocks reach it. The last block goes after the others, from
            // its exact top: a table there stops at the area's bottom.
            var done = 0
            while done < layouts.count, !isCancelled() {
                var partial = MarkdownSnapshot(document: base.document, layouts: layouts, width: request.width,
                                               typography: typography, generation: generation, update: nil,
                                               images: images)
                let top: CGFloat = switch firstStep {
                case .offset(let y): y
                case .fraction(let fraction): fraction * partial.totalHeight
                case .everything: 0
                }
                let end = min(partial.firstBlock(endingBelow: top + target) + 1, layouts.count)
                guard end > done else { break }
                let last = end - 1
                if last > done {
                    let range = done..<last
                    let kept = range.map { isFinal(layouts[$0], $0) ? layouts[$0] : nil }
                    guard let laidOut = BlockLayout.layOut(Array(blocks[range]), filling: kept, hints: range.map(hint),
                                                           columnWidth: columnWidth, typography: typography,
                                                           images: images, isCancelled: isCancelled) else { return }
                    layouts.replaceSubrange(range, with: laidOut)
                    timings.laidOutBlocks += kept.count(where: { $0 == nil })
                    partial = MarkdownSnapshot(document: base.document, layouts: layouts, width: request.width,
                                               typography: typography, generation: generation, update: nil,
                                               images: images)
                }
                if !isFinal(layouts[last], last) {
                    let rows = TableRows.covering(first: 0, height: top + target - partial.blockTops[last])
                    guard let layout = BlockLayout.make(blocks[last], columnWidth: columnWidth, typography: typography,
                                                        hint: hint(last), tableRows: rows, images: images,
                                                        isCancelled: isCancelled)
                    else { return }
                    layouts[last] = layout
                    timings.laidOutBlocks += 1
                }
                done = end
            }
        }
        guard !isCancelled() else { return }
        let visible = MarkdownSnapshot(document: base.document, layouts: layouts, width: request.width,
                                       typography: typography, generation: generation, update: base.update,
                                       images: images)
        timings.layout = ContinuousClock.now - start
        commit(visible, request, timings, post: post)
        guard !visible.isComplete, request.complete, !isCancelled() else { return }

        // Step 2: everything else, in parallel, including the rest of a
        // partly laid out table.
        start = ContinuousClock.now
        let kept = layouts.indices.map { isFinal(layouts[$0], $0) ? layouts[$0] : nil }
        let hints = layouts.indices.map(hint)
        let all = signposter.withIntervalSignpost("layout") {
            BlockLayout.layOut(blocks, filling: kept, hints: hints, columnWidth: columnWidth, typography: typography,
                               images: images, isCancelled: isCancelled)
        }
        guard let all else { return }
        timings.layout += ContinuousClock.now - start
        timings.laidOutBlocks += kept.count(where: { $0 == nil })
        commit(MarkdownSnapshot(document: base.document, layouts: all, width: request.width, typography: typography,
                                generation: generation, update: base.update, images: images),
               request, timings, post: post)
    }

    private func commit(_ snapshot: MarkdownSnapshot, _ request: RenderRequest, _ timings: Timings,
                        post: (RenderOutcome) -> Void) {
        current = snapshot
        currentSourceGeneration = request.sourceGeneration
        var timings = timings
        timings.isComplete = snapshot.isComplete
        post(.snapshot(snapshot, sourceGeneration: request.sourceGeneration, timings: timings))
    }
}

/// One serial background queue per view. The main thread submits requests;
/// only outcomes for the latest request reach `onOutcome`, so older results
/// never install.
@MainActor
final class RenderPipeline {
    let queue = DispatchQueue(label: "MarkdownView.render", qos: .userInitiated)
    private let worker: RenderWorker
    private(set) var generation: UInt64 = 0
    /// Set by `cancel()` until the next request.
    private var isCancelled = false
    var onOutcome: (@MainActor (RenderOutcome) -> Void)?

    init(typography: Typography) {
        worker = RenderWorker(typography: typography)
    }

    /// Requests that started work on the background queue.
    var runs: Int { worker.runs.load(ordering: .relaxed) }

    /// Queues a request and returns its generation, which supersedes every
    /// earlier one. A new source is diffed against `base`, which should be
    /// the installed snapshot, and lays out first what `plan` says by the
    /// time it is parsed; without a plan, the top when `visibleFirst`.
    @discardableResult
    func submit(sourceGeneration: UInt64, source: String, width: CGFloat, scrollFraction: CGFloat,
                viewportHeight: CGFloat, visibleFirst: Bool, complete: Bool,
                base: MarkdownSnapshot = .empty, plan: RenderPlan? = nil, images: ImageSizes = .none) -> UInt64 {
        generation += 1
        isCancelled = false
        worker.latestGeneration.store(generation, ordering: .relaxed)
        let request = RenderRequest(generation: generation, sourceGeneration: sourceGeneration, source: source,
                                    width: width, scrollFraction: scrollFraction, viewportHeight: viewportHeight,
                                    plan: plan ?? RenderPlan(visibleFirst ? .offset(0) : .everything),
                                    complete: complete, base: base, images: images)
        let post: @Sendable (RenderOutcome) -> Void = { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(outcome) }
            }
        }
        queue.async { [worker] in worker.process(request, post: post) }
        return generation
    }

    /// Stops the work for every request so far and drops its outcomes,
    /// without starting another.
    func cancel() {
        isCancelled = true
        worker.latestGeneration.store(generation &+ 1, ordering: .relaxed)
    }

    /// Releases a replaced snapshot on the background queue, so freeing its
    /// layouts never costs main-thread time.
    func release(_ snapshot: MarkdownSnapshot) {
        queue.async { withExtendedLifetime(snapshot) {} }
    }

    private func receive(_ outcome: RenderOutcome) {
        guard !isCancelled, outcome.generation == generation else { return }
        onOutcome?(outcome)
    }
}
