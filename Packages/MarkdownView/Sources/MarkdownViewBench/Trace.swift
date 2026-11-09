import AppKit
import MarkdownView
import WebKit

// `trace`: replays the generator's typing traces (traces/*.json) edit by edit.

struct TraceOptions {
    var manifest: URL
    /// `all`, or trace names separated by commas.
    var names: String
    /// Milliseconds between edits; 0 fires each edit once the previous one has rendered.
    var interval: Double
}

/// One edit of one repetition. Edits are numbered from 1; text 0 is the base document.
struct TraceEditResult: Codable {
    let edit: Int
    /// When it was applied, from the first edit.
    let firedAtMs: Double
    var rendered = false
    /// The later edit whose render showed this one first.
    var coalescedInto: Int?
    /// Earlier edits this render showed first.
    var coalesced: Int?
    /// This edit's keystroke to rendered.
    var ms: Double?
    /// The oldest edit this render covered, keystroke to rendered; with `coalesced` only.
    var sinceOldestMs: Double?
    /// WebKit: from the end of the debounce.
    var workMs: Double?
    // Custom: from the library's Timings.
    var mainMs: Double?
    var wallMs: Double?
    var pauseMs: Double?
    var reusedBlocks: Int?
    var laidOutBlocks: Int?
    var library: LibraryTimings?
    /// Custom: false when no candidate text matched the snapshot's blocks, and the render
    /// was attributed to the newest edit set before it installed.
    var verified: Bool?
}

struct TraceRepetition: Codable {
    let openMs: Double
    /// Scroll offset of the preview before the first edit.
    let scrollY: Double
    var elapsedMs = 0.0
    var rendered = 0
    var coalesced = 0
    var unverified: Int?
    /// The last edit's keystroke to its render: the latency of the final state.
    var finalMs: Double?
    var edits: [TraceEditResult] = []
}

struct TraceResult: Codable {
    let name: String
    let description: String
    let path: String
    let baseBytes: Int
    let edits: Int
    var status = "ok"
    var error: String?
    var repetitions: [TraceRepetition] = []
    /// Pooled over repetitions: open, update (rendered edits), updateWork, updateMain, updateWall, pause, final.
    var ms: [String: Summary]?
    var laidOutBlocks: Summary?
    var fired = 0
    var rendered = 0
    var coalesced = 0
    var over16ms = 0
    var overMain4ms: Int?
}

struct TraceSettings: Codable {
    struct Policy: Codable { let budgetMs: Double; let pauseFactor: Double; let maximumPauseMs: Double }
    /// `sequential` (each edit after the previous render) or `burst` (a fixed interval).
    let mode: String
    let intervalMs: Double
    let updatePolicy: Policy?
}

struct TraceFileOutput: Encodable {
    let schema: String
    let run: RunHeader
    let trace: TraceSettings
    let traces: [TraceResult]
}

/// Blocks near each edit, captured when a custom snapshot installs, to tell later which
/// edit's text the snapshot shows.
struct TraceProbe {
    let range: Range<Int>
    let text: String

    func matches(_ text: NSString) -> Bool {
        range.upperBound <= text.length
            && text.substring(with: NSRange(location: range.lowerBound, length: range.count)) == self.text
    }
}

/// Wakes a waiter whenever a render is logged.
@MainActor
final class RenderSignal {
    private var continuation: CheckedContinuation<Void, Never>?

    func notify() {
        continuation?.resume()
        continuation = nil
    }

    func wait(timeout: Duration, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw BenchError.timeout }
            let timer = Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                self?.notify()
            }
            await withCheckedContinuation { continuation = $0 }
            timer.cancel()
        }
    }
}

/// Every snapshot a custom view installs during a trace, and its draw report.
///
/// The view runs one update at a time, and an update takes the newest source when it is
/// submitted: inside `setSource` when nothing runs, or right after the previous update's
/// install. So the text of install r is one of the edits from the newest at install r - 1
/// to the newest at install r. The view does not say which, so each install keeps the
/// blocks around the edits in that window, and `identify` later replays the texts and picks
/// the newest one those blocks match.
@MainActor
final class CustomTraceLog {
    struct Install {
        let generation: UInt64
        /// Candidate edits: the newest set when the previous snapshot installed, and now.
        let low: Int
        let high: Int
        let probes: [TraceProbe]
        var render: CustomRender?
        var match: Int?
    }

    let edits: [Generator.TraceEdit]
    let signal = RenderSignal()
    private(set) var installs: [Install] = []
    /// The newest edit passed to `setSource`.
    var latest = 0
    private var lastHigh = 0

    init(edits: [Generator.TraceEdit]) { self.edits = edits }

    func installed(_ snapshot: MarkdownSnapshot) {
        let low = lastHigh, high = latest
        lastHigh = high
        var probes: [TraceProbe] = []
        if low < high {
            let blocks = snapshot.document.blocks
            var seen = Set<Int>()
            for edit in edits[low..<high] {
                for index in Self.blocks(near: edit.location, edit.location + edit.replacement.utf16.count, in: blocks)
                where seen.insert(index).inserted {
                    probes.append(TraceProbe(range: blocks[index].sourceRange, text: blocks[index].sourceText))
                }
            }
        }
        installs.append(Install(generation: snapshot.generation, low: low, high: high, probes: probes))
    }

    func drew(_ render: CustomRender) {
        guard render.timings.isComplete,
              let index = installs.lastIndex(where: { $0.generation == render.timings.generation }),
              installs[index].render == nil else { return }
        installs[index].render = render
        signal.notify()
    }

    /// The block before `start`, the blocks over `start...end`, and the one after.
    static func blocks(near start: Int, _ end: Int, in blocks: [MarkdownBlock]) -> [Int] {
        var low = 0, high = blocks.count
        while low < high {
            let middle = (low + high) / 2
            if blocks[middle].sourceRange.upperBound < start { low = middle + 1 } else { high = middle }
        }
        var result = low > 0 ? [low - 1] : []
        var index = low
        while index < blocks.count, result.count < 6 {
            result.append(index)
            if blocks[index].sourceRange.lowerBound > end { break }
            index += 1
        }
        return result
    }

    /// Whether drawn install `install` shows `text`, the newest edit's.
    func shows(_ install: Install, newest: Int, text: NSString) -> Bool {
        install.high == newest && (install.low == newest || install.probes.allSatisfy { $0.matches(text) })
    }

    /// Picks each install's edit by replaying the trace from `base`.
    func identify(base: String) throws {
        let text = NSMutableString(string: base)
        for edit in 0...edits.count {
            if edit > 0 { try Runner.apply(edits[edit - 1], to: text) }
            for index in installs.indices where installs[index].low <= edit && edit <= installs[index].high {
                if installs[index].probes.isEmpty || installs[index].probes.allSatisfy({ $0.matches(text) }) {
                    installs[index].match = edit
                }
            }
        }
    }
}

extension Runner {
    static let traceDefinitions = [
        "trace": "a generated typing trace: the base document, then ordered edits, each a UTF-16 range in the text left by the previous edit and its replacement",
        "open": "a new preview showing the base document until rendered (as in run); each repetition opens a new preview",
        "scroll": "before the first edit the preview scrolls so the first edit's position is 30% down the viewport: custom from the snapshot's block tops (interpolated within a block), WebKit as a fraction of the page height; then a 300 ms settle",
        "sequential": "intervalMs 0: each edit is applied once the previous edit has rendered",
        "burst": "intervalMs > 0: edit k is applied at (k - 1) * intervalMs after the first, whether or not earlier edits have rendered; the replay ends when the last edit has rendered",
        "update": "an edit's keystroke (the edited text passed to setSource for custom, contentChanged() after the document text changed for WebKit) until the render that shows it",
        "coalesced": "an edit whose text never rendered because a later edit's render showed it first; its latency is attributed to that later edit (coalescedInto), whose sinceOldestMs times the oldest edit it covered",
        "final": "the last edit's keystroke until it rendered",
        "updateWork": "WebKit: from the end of the 200 ms debounce until rendered",
        "updateMain": "custom: install plus first draw from the library's Timings (Timings.mainThread)",
        "updateWall": "custom: Timings.wall, submission to the end of the install, which the view paces updates by",
        "pause": "custom: Timings.pause, how long the view held the next update after this one exceeded the UpdatePolicy budget",
        "identification": "custom: the view takes the newest source when an update starts, which the bench cannot observe; each install records the blocks around the candidate edits, and after the repetition the replayed texts decide which edit it showed (the newest that matches; texts differing only outside every block count as the newer one). verified false: none matched, attributed to the newest candidate",
        "over16ms": "rendered edits whose update exceeded 16 ms; overMain4ms: custom updates whose main-thread time exceeded 4 ms",
        "percentiles": "nearest rank, pooled over every rendered edit of every repetition"
    ]

    static func apply(_ edit: Generator.TraceEdit, to text: NSMutableString) throws {
        guard edit.location >= 0, edit.length >= 0, edit.location + edit.length <= text.length else {
            throw BenchError.unavailable("edit \(edit.location)+\(edit.length) is outside the text (\(text.length) UTF-16 units)")
        }
        text.replaceCharacters(in: NSRange(location: edit.location, length: edit.length), with: edit.replacement)
    }

    func runTraces(_ trace: TraceOptions) async throws {
        let started = now()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: trace.manifest)) as? [String: Any]
        let listed = (manifest?["traces"] as? [[String: Any]] ?? []).compactMap { item -> (String, String)? in
            guard let name = item["name"] as? String, let path = item["path"] as? String else { return nil }
            return (name, path)
        }
        let names = trace.names == "all" ? nil : Set(trace.names.split(separator: ",").map(String.init))
        let selected = listed.filter { names?.contains($0.0) ?? true }
        if let names, let missing = names.subtracting(selected.map(\.0)).first {
            throw BenchError.unavailable("trace \(missing) is not in \(trace.manifest.path); traces: "
                + listed.map(\.0).joined(separator: ", ") + " (run generate)")
        }
        guard !selected.isEmpty else { throw BenchError.unavailable("no traces in \(trace.manifest.path); run generate") }
        let root = trace.manifest.deletingLastPathComponent()

        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Markdown trace benchmark")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        window.orderFrontRegardless()
        if options.custom { imageProvider = await makeImageProvider(manifest: trace.manifest) }
        let baseline = Double(ProcessMetrics.ownFootprint()) / 1_048_576
        let firstOpen: Double
        if options.custom {
            firstOpen = try await openCustom(Self.otherText, timeout: .seconds(60)).open
            disposeCustom()
        } else {
            firstOpen = try await open(BenchDocument(url: scratchURL(), text: Self.otherText), timeout: .seconds(60)).open
            dispose()
        }
        let environment = Environment.current(repository: Paths.repository, webkitVersion: options.custom ? nil
            : Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        let policy = UpdatePolicy.standard
        let header = RunHeader(
            timestamp: ISO8601DateFormatter().string(from: Date()), renderer: options.renderer, set: "traces",
            manifest: trace.manifest.path, documents: selected.count, repetitions: options.repetitions,
            limit: nil, filter: names == nil ? nil : trace.names, skip: nil, idleSeconds: 0,
            debounceMs: options.custom ? 0 : 200,
            previewResources: options.custom ? nil : options.previewResources.path, machine: environment.machine,
            os: environment.os, build: environment.build, git: environment.git, webkit: environment.webkit,
            window: windowInfo(), firstPreviewMs: round2(firstOpen), baselineMemoryMiB: round1(baseline),
            helperAttribution: nil, watchdog: nil, definitions: Self.traceDefinitions, imageProvider: imageProviderInfo,
            codeHighlighter: options.custom ? options.highlighter : nil)
        let settings = TraceSettings(
            mode: trace.interval > 0 ? "burst" : "sequential", intervalMs: trace.interval,
            updatePolicy: options.custom ? .init(budgetMs: Self.ms(policy.budget), pauseFactor: policy.pauseFactor,
                                                 maximumPauseMs: Self.ms(policy.maximumPause)) : nil)
        print("\(options.renderer) traces (\(settings.mode)\(trace.interval > 0 ? String(format: ", %.0f ms", trace.interval) : "")): "
              + "\(selected.count) traces, \(options.repetitions) repetitions, first preview \(String(format: "%.1f", firstOpen)) ms")
        print(Self.traceTableHeader(custom: options.custom))

        var results: [TraceResult] = []
        for (name, path) in selected {
            let url = root.appendingPathComponent(path)
            var result: TraceResult
            do {
                let loaded = try JSONDecoder().decode(Generator.Trace.self, from: Data(contentsOf: url))
                result = TraceResult(name: name, description: loaded.description, path: path,
                                     baseBytes: loaded.base.utf8.count, edits: loaded.edits.count)
                do {
                    for _ in 0..<options.repetitions {
                        let repetition = try await interval("trace") {
                            options.custom ? try await replayCustom(loaded, url: url, interval: trace.interval)
                                : try await replayWebKit(loaded, url: url, interval: trace.interval)
                        }
                        result.repetitions.append(repetition)
                    }
                } catch {
                    result.status = "failed"
                    result.error = error.localizedDescription
                }
            } catch {
                result = TraceResult(name: name, description: "", path: path, baseBytes: 0, edits: 0,
                                     status: "failed", error: error.localizedDescription)
            }
            dispose()
            disposeCustom()
            Self.summarize(&result, custom: options.custom)
            results.append(result)
            print(Self.traceRow(result, custom: options.custom))
        }

        try FileManager.default.createDirectory(at: options.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(TraceFileOutput(schema: "aletheia-markdown-bench/3", run: header, trace: settings, traces: results))
            .write(to: options.output)
        print(String(format: "%d traces in %.1f s; wrote %@", results.count, milliseconds(started, now()) / 1000,
                     options.output.path))
    }

    /// Fires edit `k` (from 1) once `body` returns for the previous one, or on the burst schedule.
    private func fireEdits(_ trace: Generator.Trace, interval: Double, fire: (Int, NSMutableString) throws -> Void,
                           rendered: (Int) async throws -> Void) async throws -> [UInt64] {
        let text = NSMutableString(string: trace.base)
        var fired: [UInt64] = []
        let start = ContinuousClock.now
        for (index, edit) in trace.edits.enumerated() {
            if interval > 0, index > 0 {
                try await Task.sleep(until: start + .nanoseconds(Int64(interval * 1e6 * Double(index))), clock: .continuous)
            }
            try Self.apply(edit, to: text)
            signposter.emitEvent("keystroke")
            fired.append(now())
            try fire(index + 1, text)
            if interval == 0 { try await rendered(index + 1) }
        }
        if interval > 0 { try await rendered(trace.edits.count) }
        return fired
    }

    private func replayCustom(_ trace: Generator.Trace, url: URL, interval: Double) async throws -> TraceRepetition {
        let opened = try await openCustom(trace.base, directory: url.deletingLastPathComponent())
        guard let preview = customPreview else { throw BenchError.navigation("no preview") }
        let scrollY = Double(scrollCustom(preview, to: trace.edits.first?.location ?? 0))
        try await Task.sleep(for: .milliseconds(300))
        let log = CustomTraceLog(edits: trace.edits)
        preview.view.onInstall = { [weak log] in log?.installed($0) }
        preview.observer = { [weak log] in log?.drew($0) }
        let begin = now()
        var current: NSString = ""
        let fired = try await fireEdits(trace, interval: interval, fire: { edit, text in
            log.latest = edit
            current = text
            preview.view.setSource(text as String)
        }, rendered: { edit in
            let last = edit == trace.edits.count && interval > 0
            try await log.signal.wait(timeout: timeout) {
                log.installs.contains { install in
                    install.render != nil && (last ? log.shows(install, newest: edit, text: current) : install.high >= edit)
                }
            }
        })
        var repetition = TraceRepetition(openMs: round2(opened.open), scrollY: round1(scrollY))
        repetition.elapsedMs = round2(milliseconds(begin, now()))
        preview.view.onInstall = nil
        preview.observer = nil
        try log.identify(base: trace.base)

        var edits = fired.enumerated().map { TraceEditResult(edit: $0.offset + 1, firedAtMs: round2(milliseconds(fired[0], $0.element))) }
        var previous = 0
        var unverified = 0
        for install in log.installs {
            guard let render = install.render else { continue }
            let edit = install.match ?? install.high
            if install.match == nil { unverified += 1 }
            guard edit > previous else { continue }
            let timings = LibraryTimings(render.timings)
            var result = edits[edit - 1]
            result.rendered = true
            result.ms = round2(milliseconds(fired[edit - 1], render.at))
            if edit - previous > 1 {
                for index in previous + 1 ..< edit { edits[index - 1].coalescedInto = edit }
                result.coalesced = edit - previous - 1
                result.sinceOldestMs = round2(milliseconds(fired[previous], render.at))
            }
            result.mainMs = round2(timings.install + timings.draw)
            result.wallMs = round2(Self.ms(render.timings.wall))
            result.pauseMs = round2(Self.ms(render.timings.pause))
            result.reusedBlocks = render.timings.reusedBlocks
            result.laidOutBlocks = render.timings.laidOutBlocks
            result.library = timings
            result.verified = install.match != nil
            edits[edit - 1] = result
            previous = edit
        }
        repetition.edits = edits
        repetition.rendered = edits.filter(\.rendered).count
        repetition.coalesced = edits.filter { $0.coalescedInto != nil }.count
        repetition.unverified = unverified
        repetition.finalMs = edits.last?.ms
        return repetition
    }

    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Scrolls so `location` is 30% down the viewport, from the installed snapshot's block tops.
    private func scrollCustom(_ preview: CustomPreview, to location: Int) -> CGFloat {
        let snapshot = preview.view.snapshot
        let blocks = snapshot.document.blocks
        guard !blocks.isEmpty, snapshot.layouts.count == blocks.count, snapshot.blockTops.count >= blocks.count else { return 0 }
        let index = blocks.firstIndex { $0.sourceRange.upperBound >= location } ?? blocks.count - 1
        let range = blocks[index].sourceRange
        let within = range.isEmpty ? 0 : min(max(CGFloat(location - range.lowerBound) / CGFloat(range.count), 0), 1)
        let y = max(0, snapshot.blockTops[index] + within * snapshot.layouts[index].height
                    - preview.view.contentView.bounds.height * 0.3)
        preview.view.setScrollOffset(y)
        return preview.view.scrollOffset
    }

    private func replayWebKit(_ trace: Generator.Trace, url: URL, interval: Double) async throws -> TraceRepetition {
        let document = BenchDocument(url: url.deletingPathExtension().appendingPathExtension("md"), text: trace.base)
        let opened = try await open(document)
        guard let preview else { throw BenchError.navigation("no preview") }
        let length = (trace.base as NSString).length
        let scrollY = try await preview.scroll(toFraction: length > 0 ? Double(trace.edits.first?.location ?? 0) / Double(length) : 0)
        try await Task.sleep(for: .milliseconds(300))
        var renders: [RenderTiming] = []
        let signal = RenderSignal()
        preview.onRendered = { renders.append($0); signal.notify() }
        let begin = now()
        let fired = try await fireEdits(trace, interval: interval, fire: { edit, text in
            document.text = text as String
            document.revision = edit
            preview.contentChanged()
        }, rendered: { edit in
            try await signal.wait(timeout: timeout) { renders.contains { $0.revision >= edit } }
        })
        var repetition = TraceRepetition(openMs: round2(opened.open), scrollY: round1(scrollY))
        repetition.elapsedMs = round2(milliseconds(begin, now()))
        preview.onRendered = nil
        if let stalled = renders.first(where: { $0.visibility != "visible" }) { throw BenchError.stalled(stalled.visibility) }

        var edits = fired.enumerated().map { TraceEditResult(edit: $0.offset + 1, firedAtMs: round2(milliseconds(fired[0], $0.element))) }
        var previous = 0
        for render in renders where render.revision > previous {
            let edit = render.revision
            var result = edits[edit - 1]
            result.rendered = true
            result.ms = round2(milliseconds(fired[edit - 1], render.rendered))
            result.workMs = round2(milliseconds(render.start, render.rendered))
            if edit - previous > 1 {
                for index in previous + 1 ..< edit { edits[index - 1].coalescedInto = edit }
                result.coalesced = edit - previous - 1
                result.sinceOldestMs = round2(milliseconds(fired[previous], render.rendered))
            }
            edits[edit - 1] = result
            previous = edit
        }
        repetition.edits = edits
        repetition.rendered = edits.filter(\.rendered).count
        repetition.coalesced = edits.filter { $0.coalescedInto != nil }.count
        repetition.finalMs = edits.last?.ms
        return repetition
    }

    // MARK: Summary

    static func summarize(_ result: inout TraceResult, custom: Bool) {
        let edits = result.repetitions.flatMap(\.edits)
        let rendered = edits.filter(\.rendered)
        var ms: [String: Summary] = [:]
        ms["open"] = Summary(result.repetitions.map(\.openMs))
        ms["update"] = Summary(rendered.compactMap(\.ms))
        ms["final"] = Summary(result.repetitions.compactMap(\.finalMs))
        if custom {
            ms["updateMain"] = Summary(rendered.compactMap(\.mainMs))
            ms["updateWall"] = Summary(rendered.compactMap(\.wallMs))
            ms["pause"] = Summary(rendered.compactMap(\.pauseMs))
            result.laidOutBlocks = Summary(rendered.compactMap { $0.laidOutBlocks.map(Double.init) })
            result.overMain4ms = rendered.filter { ($0.mainMs ?? 0) > 4 }.count
        } else {
            ms["updateWork"] = Summary(rendered.compactMap(\.workMs))
        }
        result.ms = ms.isEmpty ? nil : ms
        result.fired = edits.count
        result.rendered = rendered.count
        result.coalesced = edits.filter { $0.coalescedInto != nil }.count
        result.over16ms = rendered.filter { ($0.ms ?? 0) > 16 }.count
    }

    static func traceTableHeader(custom: Bool) -> String {
        pad("trace", 28, left: true) + pad("KiB", 8) + pad("edits", 7) + pad("shown", 7) + pad("coal.", 7)
            + pad("open p50", 10) + pad("update p50/p95", 16) + pad("max", 8)
            + (custom ? pad("wall p50/p95", 14) + pad("main p50/p95", 14) + pad("pause max", 11) : pad("work p50/p95", 16))
            + pad("final p50/p95", 16) + pad(">16ms", 7)
    }

    static func traceRow(_ result: TraceResult, custom: Bool) -> String {
        let head = pad(result.name, 28, left: true) + pad(String(format: "%.1f", Double(result.baseBytes) / 1024), 8)
            + pad("\(result.fired)", 7)
        guard result.status == "ok", let ms = result.ms else { return head + "  \(result.status): \(result.error ?? "")" }
        return head + pad("\(result.rendered)", 7) + pad("\(result.coalesced)", 7)
            + pad(ms["open"].map { String(format: "%.1f", $0.p50) } ?? "-", 10) + pad(pair(ms["update"]), 16)
            + pad(ms["update"].map { String(format: "%.1f", $0.max) } ?? "-", 8)
            + (custom ? pad(pair(ms["updateWall"]), 14) + pad(pair(ms["updateMain"]), 14)
                + pad(ms["pause"].map { String(format: "%.1f", $0.max) } ?? "-", 11)
                : pad(pair(ms["updateWork"]), 16))
            + pad(pair(ms["final"]), 16) + pad("\(result.over16ms)", 7)
    }
}
