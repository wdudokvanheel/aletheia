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

    public init(generation: UInt64) {
        self.generation = generation
    }
}

struct RenderRequest: Sendable {
    var generation: UInt64
    var sourceGeneration: UInt64
    var source: String
    var width: CGFloat
    /// Where the visible area starts, as a fraction of the document height.
    var scrollFraction: CGFloat
    var viewportHeight: CGFloat
    /// For a new source: lay out the visible area before the rest.
    var visibleFirst: Bool
    /// False during live resize, when only the visible area is laid out.
    var complete: Bool
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
    /// newer request exists.
    func process(_ request: RenderRequest, post: (RenderOutcome) -> Void) {
        let generation = request.generation
        guard !isSuperseded(generation) else { return }
        let columnWidth = typography.column(forWidth: request.width).width
        let isCancelled: @Sendable () -> Bool = { [self] in isSuperseded(generation) }
        var timings = Timings(generation: generation)
        let base: MarkdownSnapshot

        if let current, currentSourceGeneration == request.sourceGeneration {
            if current.width == request.width, current.isComplete {
                timings.blockCount = current.layouts.count
                post(.snapshot(current.with(generation: generation), sourceGeneration: request.sourceGeneration,
                               timings: timings))
                return
            }
            base = current
        } else {
            let start = ContinuousClock.now
            let document: MarkdownDocument
            do {
                document = try signposter.withIntervalSignpost("parse") { try MarkdownDocument.parse(request.source) }
            } catch {
                post(.failure(generation: generation, message: "\(error)"))
                return
            }
            timings.parse = ContinuousClock.now - start
            timings.blockCount = document.blocks.count
            if request.visibleFirst {
                let estimates = document.blocks.map { BlockLayout.estimate(for: $0, columnWidth: columnWidth, typography: typography) }
                base = MarkdownSnapshot(document: document, layouts: estimates, width: request.width,
                                        typography: typography, generation: generation)
            } else {
                let start = ContinuousClock.now
                let layouts = signposter.withIntervalSignpost("layout") {
                    BlockLayout.layOut(document.blocks, columnWidth: columnWidth, typography: typography,
                                       isCancelled: isCancelled)
                }
                guard let layouts else { return }
                timings.layout = ContinuousClock.now - start
                commit(MarkdownSnapshot(document: document, layouts: layouts, width: request.width,
                                        typography: typography, generation: generation),
                       request, timings, post: post)
                return
            }
        }
        timings.blockCount = base.layouts.count

        // Step 1: the blocks from the top of the visible area down, enough to
        // fill it, laid out serially.
        var start = ContinuousClock.now
        var layouts = base.layouts
        let blocks = base.document.blocks
        signposter.withIntervalSignpost("layout") {
            var index = base.firstBlock(endingBelow: request.scrollFraction * base.totalHeight)
            var covered: CGFloat = 0
            let target = max(request.viewportHeight, 400) * 1.5
            while index < layouts.count, covered < target {
                if !layouts[index].isFinal(for: columnWidth) {
                    layouts[index] = BlockLayout(block: blocks[index], columnWidth: columnWidth, typography: typography)
                }
                covered += layouts[index].height + layouts[index].marginBottom
                index += 1
            }
        }
        let visible = MarkdownSnapshot(document: base.document, layouts: layouts, width: request.width,
                                       typography: typography, generation: generation)
        timings.layout = ContinuousClock.now - start
        commit(visible, request, timings, post: post)
        guard !visible.isComplete, request.complete, !isCancelled() else { return }

        // Step 2: everything else, in parallel.
        start = ContinuousClock.now
        let all = signposter.withIntervalSignpost("layout") {
            BlockLayout.layOut(blocks, columnWidth: columnWidth, typography: typography, reusing: layouts,
                               isCancelled: isCancelled)
        }
        guard let all else { return }
        timings.layout += ContinuousClock.now - start
        commit(MarkdownSnapshot(document: base.document, layouts: all, width: request.width, typography: typography,
                                generation: generation),
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

    /// Queues a request and returns its generation, which supersedes every
    /// earlier one.
    @discardableResult
    func submit(sourceGeneration: UInt64, source: String, width: CGFloat, scrollFraction: CGFloat,
                viewportHeight: CGFloat, visibleFirst: Bool, complete: Bool) -> UInt64 {
        generation += 1
        isCancelled = false
        worker.latestGeneration.store(generation, ordering: .relaxed)
        let request = RenderRequest(generation: generation, sourceGeneration: sourceGeneration, source: source,
                                    width: width, scrollFraction: scrollFraction, viewportHeight: viewportHeight,
                                    visibleFirst: visibleFirst, complete: complete)
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
