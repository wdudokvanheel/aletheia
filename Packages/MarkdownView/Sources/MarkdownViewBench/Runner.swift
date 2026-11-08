import AppKit
import MarkdownView
import WebKit

struct RunOptions {
    var manifest: URL
    var set: String
    var renderer: String
    var repetitions: Int
    var output: URL
    var limit: Int?
    var filter: String?
    var skip: Int
    var previewResources: URL
    var idleSeconds: Double
    var timeout: Double
    var onscreen: Bool
    /// The run loop watchdog and the 1 s check; on for the smoke set.
    var watchdog: Bool
    var custom: Bool { renderer == "custom" }
}

struct ManifestEntry {
    let path: String
    let name: String?
    let url: URL?
}

enum Manifest {
    /// Entries of `set`, whose paths are relative to the manifest's `root`. Set entries are
    /// paths, or objects with `path` (null when a curated file is missing) and `name`.
    static func load(_ url: URL, set: String) throws -> (URL, [ManifestEntry]) {
        var url = url
        var json = try object(url)
        var sets = json["sets"] as? [String: Any] ?? [:]
        if sets[set] == nil, set == "generated" {
            url = url.deletingLastPathComponent().appendingPathComponent("generated/generated-manifest.json")
            json = try object(url)
            sets = json["sets"] as? [String: Any] ?? [:]
        }
        guard let items = sets[set] as? [Any] else {
            throw BenchError.unavailable("set \(set) is not in \(url.path); sets: \(sets.keys.sorted().joined(separator: ", "))")
        }
        let rootValue = json["root"] as? String ?? "."
        let root = rootValue.hasPrefix("/") ? URL(fileURLWithPath: rootValue)
            : url.deletingLastPathComponent().appendingPathComponent(rootValue).standardizedFileURL
        return (url, items.map { item in
            let path = (item as? String) ?? ((item as? [String: Any])?["path"] as? String)
            let name = (item as? [String: Any])?["name"] as? String
            return ManifestEntry(path: path ?? "(\(name ?? "unnamed") missing)", name: name,
                                 url: path.map { root.appendingPathComponent($0) })
        })
    }

    private static func object(_ url: URL) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw BenchError.unavailable("\(url.path) is not a manifest object")
        }
        return json
    }
}

struct EditPoint: Codable {
    /// UTF-16 offset of the first keystroke; later repetitions type after it.
    let offset: Int
    /// `paragraph`: end of the paragraph line nearest the middle; `end`: end of the document.
    let kind: String

    static func find(in text: String) -> EditPoint {
        let units = Array(text.utf16)
        let middle = units.count / 2
        var best: Int?
        var fence: (UInt16, Int)?
        var start = 0
        while start < units.count {
            var end = start
            while end < units.count, units[end] != 10, units[end] != 13 { end += 1 }
            var first = start
            while first < end, first - start < 4, units[first] == 32 { first += 1 }
            if first < end, first - start < 4 {
                let unit = units[first]
                var run = first
                while run < end, units[run] == unit { run += 1 }
                if (unit == 96 || unit == 126), run - first >= 3 {
                    if let open = fence { if open.0 == unit, run - first >= open.1 { fence = nil } }
                    else { fence = (unit, run - first) }
                } else if fence == nil, (65...90).contains(unit) || (97...122).contains(unit)
                            || (unit >= 0xC0 && !(0xD800...0xDFFF).contains(unit)) {
                    if best.map({ abs(end - middle) < abs($0 - middle) }) ?? true { best = end }
                }
            }
            start = end + (end + 1 < units.count && units[end] == 13 && units[end + 1] == 10 ? 2 : 1)
        }
        if let best { return EditPoint(offset: best, kind: "paragraph") }
        var end = units.count
        while end > 0, units[end - 1] == 10 || units[end - 1] == 13 { end -= 1 }
        return EditPoint(offset: end, kind: "end")
    }
}

struct DocumentResult: Codable {
    let path: String
    var name: String?
    var bytes: Int?
    var status = "ok"
    var error: String?
    var edit: EditPoint?
    var ms: [String: Summary]?
    var memoryMiB: Memory?
    var idleCPUPercent: IdleCPU?
    /// Custom: the library's Timings per repetition, by metric.
    var library: [String: [LibraryTimings]]?
    var scroll: ScrollResult?
    /// With the watchdog: the longest main run loop busy span while measuring this document.
    var blockedMs: Double?
}

struct WindowInfo: Codable {
    let width: Double
    let height: Double
    let backingScale: Double
    let screenRefreshHz: Int
    /// While the display sleeps WebKit paces frames with a timer instead of the display.
    let displayAsleep: Bool
    /// `transparent`: alpha 0 and click-through on the main screen; `onscreen`: visible.
    let placement: String
    /// At the start of the run. AppKit displays an occluded window at a slower cadence than the
    /// screen's refresh, which lengthens every custom latency that waits for a draw.
    let occluded: Bool
    /// WebKit only.
    let occlusionDetection: Bool?
    /// Custom only: `overlay` or `legacy`, which takes width from the text column.
    let scrollerStyle: String?
}

struct WatchdogSettings: Codable {
    let limitMs: Double
    let hangSeconds: Double
}

struct RunHeader: Codable {
    let timestamp: String
    let renderer: String
    let set: String
    let manifest: String
    let documents: Int
    let repetitions: Int
    let limit: Int?
    let filter: String?
    let skip: Int?
    let idleSeconds: Double
    let debounceMs: Int
    let previewResources: String?
    let machine: Environment.Machine
    let os: Environment.OS
    let build: String
    let git: Environment.Git?
    let webkit: String?
    let window: WindowInfo
    let firstPreviewMs: Double
    let baselineMemoryMiB: Double
    let helperAttribution: String?
    let watchdog: WatchdogSettings?
    let definitions: [String: String]
}

struct AggregateLatency: Codable {
    let n: Int
    let p50: Double
    let p95: Double
    let max: Double
    let worstP95: Double
    let worstDocument: String
}

struct Aggregate: Codable {
    let documents: Int
    let ok: Int
    let failed: Int
    let skipped: Int
    let elapsedSeconds: Double
    let ms: [String: AggregateLatency]
    let memoryTotalMiB: Summary?
    /// Custom: the per-view footprint growth (`memoryMiB.view`) over documents.
    let memoryViewMiB: Summary?
    let idleCPUTotalPercent: Summary?
    let scroll: ScrollTotals?
    let watchdog: WatchdogSummary?
}

struct ScrollTotals: Codable {
    let frames: Int
    let over144Hz: Int
    let over60Hz: Int
}

struct OverLimit: Codable {
    let path: String
    let blockedMs: Double
    let openMs: Double
}

struct WatchdogSummary: Codable {
    let limitMs: Double
    /// Documents whose longest main-thread busy span or slowest open exceeded the limit.
    let over: [OverLimit]
    let worstBlockedMs: Double
    let worstBlockedDocument: String
    let worstOpenMs: Double
    let worstOpenDocument: String
}

/// Streams one result file: the header, then a line per document, then the aggregate. While a
/// document is measured its line is `{"path":...,"status":"running"}`, so a killed run names it.
final class ResultWriter {
    static let schema = "aletheia-markdown-bench/2"
    private let handle: FileHandle
    private let url: URL
    private var first = true
    private var running: UInt64?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(_ url: URL, header: RunHeader) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw BenchError.unavailable("cannot write \(url.path)")
        }
        handle = try FileHandle(forWritingTo: url)
        self.url = url
        try write("{\"schema\":\"\(Self.schema)\",\"run\":\(encode(header)),\"documents\":[\n")
    }

    private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func write(_ text: String) throws { try handle.write(contentsOf: Data(text.utf8)) }

    /// Writes the running line for document `index` and arms what replaces it on a crash or hang.
    func begin(_ path: String, index: Int) throws {
        let offset = try handle.offset()
        let separator = first ? "" : ",\n"
        let quoted = try encode(path)
        try write(separator + "{\"path\":\(quoted),\"status\":\"running\"}")
        running = offset
        func tail(_ status: String, _ error: String) -> String {
            separator + "{\"error\":\"\(error)\",\"path\":\(quoted),\"status\":\"\(status)\"}\n],\"aggregate\":null,"
                + "\"interrupted\":{\"document\":\(quoted),\"index\":\(index),\"reason\":\"\(status)\"}}\n"
        }
        Interruption.arm(fd: handle.fileDescriptor, offset: offset,
                         crashed: tail("crashed", Interruption.signalPlaceholder),
                         hung: tail("hung", "the main thread stopped returning to its run loop"),
                         message: "\nerror: interrupted while measuring document \(index) (0-based, after --filter): \(path)\n"
                            + "the result file ends with it: \(url.path)\ncontinue after it with --skip \(index + 1)\n")
    }

    func append(_ result: DocumentResult) throws {
        if let running {
            try handle.truncate(atOffset: running)
            try handle.seek(toOffset: running)
            self.running = nil
        }
        try write((first ? "" : ",\n") + encode(result))
        first = false
    }

    func finish(_ aggregate: Aggregate) throws {
        Interruption.disarm()
        try write("\n],\"aggregate\":\(encode(aggregate))}\n")
        try handle.close()
    }
}

@MainActor
final class Runner {
    static let metrics = ["startup", "firstScreen", "open", "tabSwitch", "update", "updateWork", "updateMain", "scrollFrame"]
    /// The watchdog's limit for a busy main thread or an open.
    static let limitMs = 1000.0
    static let watchdogDefinition = "blockedMs: longest span the main thread spent between run loop activities (CFRunLoopObserver, waits excluded) while measuring the document; a document is over the limit when that or any open exceeds limitMs. A span over hangSeconds ends the run, marking the document hung"
    static let definitions = [
        "rendered": "commitPreview returned to the bench (the last point the app observes), then one more callAsyncJavaScript that forces style and layout and resolves after the next requestAnimationFrame plus a zero timeout, so the frame's rendering update has run. Images are not awaited.",
        "startup": "new preview (WKWebView, configuration, scheme handler, index.html load) until didFinish",
        "open": "new preview until the document is rendered; includes startup",
        "tabSwitch": "warm preview showing a small other document: show(document) until rendered",
        "update": "one keystroke inserted in the paragraph line nearest the middle, contentChanged() until rendered; includes the app's 200 ms debounce",
        "updateWork": "update from the end of the debounce until rendered",
        "memoryMiB": "phys_footprint after the settle and idle sample (right after the last update when idleSeconds is 0), with one preview showing the document: the bench (task_info TASK_VM_INFO) plus WebKit helpers (proc_pid_rusage)",
        "idleCPUPercent": "user+system CPU over idleSeconds, starting 1 s after the last update rendered, as percent of one core, bench and helpers",
        "percentiles": "nearest rank over the repetitions; aggregate pools every repetition of every ok document"
    ]
    static let otherText = """
        # Other tab

        A short document shown before switching back, so the tab switch renders the measured document from a cleared preview.
        """
    static let keystrokes = Array(" quick brown fox jumps over the lazy dog")

    let options: RunOptions
    let window: NSWindow
    var preview: WebKitPreview?
    var customPreview: CustomPreview?
    var timeout: Duration { .milliseconds(Int(options.timeout * 1000)) }

    init(options: RunOptions) {
        self.options = options
        // On the main screen for its scale and display refresh. By default the window is fully
        // transparent and click-through, and the preview ignores occlusion (see WebKitPreview).
        let screen = NSScreen.main?.visibleFrame ?? .zero
        window = NSWindow(contentRect: NSRect(origin: screen.origin, size: NSSize(width: 900, height: 1200)),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.alphaValue = options.onscreen ? 1 : 0
    }

    func run() async throws {
        let started = now()
        let (manifest, all) = try Manifest.load(options.manifest, set: options.set)
        var entries = all
        if let filter = options.filter { entries = entries.filter { $0.path.contains(filter) || ($0.name ?? "").contains(filter) } }
        entries = Array(entries.dropFirst(options.skip))
        if let limit = options.limit { entries = Array(entries.prefix(limit)) }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Markdown preview benchmark")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        window.orderFrontRegardless()

        let baseline = Double(ProcessMetrics.ownFootprint()) / 1_048_576
        // The first preview after launch: for WebKit it also starts the shared GPU and networking helpers.
        let firstOpen: Double
        if options.custom {
            firstOpen = try await openCustom(Self.otherText, timeout: .seconds(60)).open
            disposeCustom()
        } else {
            do {
                firstOpen = try await open(BenchDocument(url: scratchURL(), text: Self.otherText), timeout: .seconds(60)).open
            } catch BenchError.stalled(let state) {
                throw BenchError.unavailable("the preview page is \(state), so WebKit does not render frames; "
                    + (options.onscreen ? "--onscreen needs an awake, unlocked display" : "the occlusion override failed"))
            }
            dispose()
        }

        let environment = Environment.current(repository: Paths.repository, webkitVersion: options.custom ? nil
            : Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        let header = RunHeader(
            timestamp: ISO8601DateFormatter().string(from: Date()), renderer: options.renderer, set: options.set,
            manifest: manifest.path, documents: entries.count, repetitions: options.repetitions,
            limit: options.limit, filter: options.filter, skip: options.skip > 0 ? options.skip : nil,
            idleSeconds: options.idleSeconds, debounceMs: 200,
            previewResources: options.custom ? nil : options.previewResources.path, machine: environment.machine,
            os: environment.os, build: environment.build, git: environment.git, webkit: environment.webkit,
            window: windowInfo(),
            firstPreviewMs: round2(firstOpen), baselineMemoryMiB: round1(baseline),
            helperAttribution: options.custom ? nil : ProcessMetrics.attribution,
            watchdog: options.watchdog ? WatchdogSettings(limitMs: Self.limitMs, hangSeconds: options.timeout) : nil,
            definitions: (options.custom ? Self.customDefinitions : Self.definitions)
                .merging(options.watchdog ? ["watchdog": Self.watchdogDefinition] : [:]) { $1 })
        let writer = try ResultWriter(options.output, header: header)
        Interruption.installHandlers()
        let watchdog = options.watchdog ? Watchdog(hangSeconds: options.timeout) : nil
        watchdog?.start()
        print("\(options.renderer) \(options.set): \(entries.count) documents, \(options.repetitions) repetitions, "
              + "first preview \(String(format: "%.1f", firstOpen)) ms")
        // The smoke set prints only failures, documents over the limit, and progress.
        let quiet = options.set == "smoke"
        print(options.custom ? Self.customTableHeader : Self.tableHeader)

        var pooled: [String: [Double]] = [:]
        var worst: [String: (Double, String)] = [:]
        var memory: [Double] = []
        var viewMemory: [Double] = []
        var idle: [Double] = []
        var counts = ["ok": 0, "failed": 0, "skipped": 0]
        var scroll = ScrollTotals(frames: 0, over144Hz: 0, over60Hz: 0)
        var over: [OverLimit] = []
        var worstBlocked = (0.0, "")
        var worstOpen = (0.0, "")
        var failures: [String] = []
        for (index, entry) in entries.enumerated() {
            try writer.begin(entry.path, index: options.skip + index)
            _ = watchdog?.takeLongest()
            var (result, samples) = await interval("document") {
                options.custom ? await measureCustom(entry) : await measure(entry)
            }
            var isOver = false
            if let watchdog {
                let blocked = round2(watchdog.takeLongest())
                let open = result.ms?["open"]?.max ?? 0
                result.blockedMs = blocked
                if blocked > worstBlocked.0 { worstBlocked = (blocked, result.path) }
                if open > worstOpen.0 { worstOpen = (open, result.path) }
                if blocked > Self.limitMs || open > Self.limitMs {
                    isOver = true
                    over.append(OverLimit(path: result.path, blockedMs: blocked, openMs: open))
                }
            }
            try writer.append(result)
            if !quiet || result.status == "failed" || isOver { print(Self.row(result, custom: options.custom)) }
            if quiet, (index + 1) % 500 == 0 {
                print("  \(index + 1)/\(entries.count) documents, \(failures.count) failed, \(over.count) over 1 s, "
                      + String(format: "%.0f s", milliseconds(started, now()) / 1000))
            }
            counts[result.status, default: 0] += 1
            if result.status == "failed" { failures.append(result.path) }
            guard result.status == "ok" else { continue }
            for (metric, values) in samples { pooled[metric, default: []] += values }
            for (metric, summary) in result.ms ?? [:] where summary.p95 > (worst[metric]?.0 ?? -1) {
                worst[metric] = (summary.p95, result.path)
            }
            if let total = result.memoryMiB?.total { memory.append(total) }
            if let view = result.memoryMiB?.view { viewMemory.append(view) }
            if let total = result.idleCPUPercent?.total { idle.append(total) }
            if let frames = result.scroll {
                scroll = ScrollTotals(frames: scroll.frames + frames.frames, over144Hz: scroll.over144Hz + frames.over144Hz,
                                      over60Hz: scroll.over60Hz + frames.over60Hz)
            }
        }
        var latency: [String: AggregateLatency] = [:]
        for (metric, values) in pooled {
            guard let summary = Summary(values), let worst = worst[metric] else { continue }
            latency[metric] = AggregateLatency(n: summary.n, p50: summary.p50, p95: summary.p95, max: summary.max,
                                               worstP95: worst.0, worstDocument: worst.1)
        }
        let aggregate = Aggregate(
            documents: entries.count, ok: counts["ok"] ?? 0, failed: counts["failed"] ?? 0,
            skipped: counts["skipped"] ?? 0, elapsedSeconds: round1(milliseconds(started, now()) / 1000),
            ms: latency, memoryTotalMiB: Summary(memory), memoryViewMiB: Summary(viewMemory),
            idleCPUTotalPercent: Summary(idle), scroll: options.custom ? scroll : nil,
            watchdog: watchdog.map { _ in
                WatchdogSummary(limitMs: Self.limitMs, over: over, worstBlockedMs: worstBlocked.0,
                                worstBlockedDocument: worstBlocked.1, worstOpenMs: worstOpen.0, worstOpenDocument: worstOpen.1)
            })
        try writer.finish(aggregate)
        print(Self.summary(aggregate))
        for path in failures.prefix(20) { print("failed: \(path)") }
        if failures.count > 20 { print("... \(failures.count - 20) more failed documents") }
        print("wrote \(options.output.path)")
    }

    func windowInfo() -> WindowInfo {
        WindowInfo(width: window.frame.width, height: window.frame.height, backingScale: window.backingScaleFactor,
                   screenRefreshHz: window.screen?.maximumFramesPerSecond ?? 0,
                   displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
                   placement: options.onscreen ? "onscreen" : "transparent",
                   occluded: !window.occlusionState.contains(.visible),
                   occlusionDetection: options.custom ? nil : options.onscreen,
                   scrollerStyle: options.custom ? (NSScroller.preferredScrollerStyle == .overlay ? "overlay" : "legacy") : nil)
    }

    func scratchURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("markdown-bench-other.md")
    }

    func open(_ document: BenchDocument, timeout: Duration? = nil) async throws -> (startup: Double, open: Double) {
        dispose()
        return try await interval("open") {
            let start = now()
            let preview = WebKitPreview(resources: options.previewResources, occlusionDetection: options.onscreen)
            self.preview = preview
            window.contentView = preview.webView
            preview.show(document)
            let timing = try await preview.nextRender(timeout: timeout ?? self.timeout)
            guard let ready = preview.readyAt else { throw BenchError.navigation("no didFinish") }
            return (milliseconds(start, ready), milliseconds(start, timing.rendered))
        }
    }

    func dispose() {
        guard let preview else { return }
        preview.show(nil)
        preview.prepareForRelease()
        preview.webView.removeFromSuperview()
        window.contentView = NSView()
        self.preview = nil
    }

    /// Reads a file the way the app does, refusing what the app refuses to open.
    static func read(_ url: URL) -> (text: String?, bytes: Int, problem: String?) {
        guard let data = try? Data(contentsOf: url) else { return (nil, 0, "unreadable") }
        let content = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        guard let text = String(data: content, encoding: .utf8),
              !text.unicodeScalars.contains(where: {
                  $0.value == 0 || ($0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13)
              }) else { return (nil, data.count, "not UTF-8 text") }
        return (text, data.count, nil)
    }

    private func measure(_ entry: ManifestEntry) async -> (DocumentResult, [String: [Double]]) {
        var result = DocumentResult(path: entry.path, name: entry.name)
        guard let url = entry.url else {
            result.status = "skipped"
            result.error = "missing from the manifest"
            return (result, [:])
        }
        let (text, bytes, problem) = Self.read(url)
        result.bytes = bytes
        guard let text else {
            result.status = "skipped"
            result.error = problem
            return (result, [:])
        }
        let document = BenchDocument(url: url.resolvingSymlinksInPath(), text: text)
        let other = BenchDocument(url: document.url.deletingLastPathComponent().appendingPathComponent(".bench-other.md"),
                                  text: Self.otherText)
        var samples: [String: [Double]] = [:]
        do {
            for _ in 0..<options.repetitions {
                let opened = try await open(document)
                samples["startup", default: []].append(opened.startup)
                samples["open", default: []].append(opened.open)
            }
            guard let preview else { throw BenchError.navigation("no preview") }
            for _ in 0..<options.repetitions {
                preview.show(other)
                _ = try await preview.nextRender(timeout: timeout)
                let timing = try await interval("tabSwitch") {
                    let start = now()
                    preview.show(document)
                    let timing = try await preview.nextRender(timeout: timeout)
                    return (start, timing)
                }
                samples["tabSwitch", default: []].append(milliseconds(timing.0, timing.1.rendered))
            }
            let edit = EditPoint.find(in: text)
            result.edit = edit
            for index in 0..<options.repetitions {
                let typed = NSMutableString(string: document.text)
                typed.insert(String(Self.keystrokes[index % Self.keystrokes.count]), at: edit.offset + index)
                document.text = typed as String
                let (start, timing) = try await interval("update") {
                    let start = now()
                    preview.contentChanged()
                    return (start, try await preview.nextRender(timeout: timeout))
                }
                samples["update", default: []].append(milliseconds(start, timing.rendered))
                samples["updateWork", default: []].append(milliseconds(timing.start, timing.rendered))
            }
            if options.idleSeconds > 0 {
                try await Task.sleep(for: .seconds(1)) // settle
                result.idleCPUPercent = try await interval("idle") { try await ProcessMetrics.idleCPU(seconds: options.idleSeconds) }
            }
            result.memoryMiB = ProcessMetrics.memory()
        } catch {
            result.status = "failed"
            result.error = error.localizedDescription
        }
        dispose()
        result.ms = Dictionary(uniqueKeysWithValues: samples.compactMap { key, values in Summary(values).map { (key, $0) } })
        return (result, samples)
    }

    // MARK: Summary table

    static func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        let clipped = text.count > width ? "…" + text.suffix(width - 1) : text
        let space = String(repeating: " ", count: max(0, width - clipped.count))
        return left ? clipped + space : space + clipped
    }

    static func pair(_ summary: Summary?) -> String {
        summary.map { String(format: "%.1f/%.1f", $0.p50, $0.p95) } ?? "-"
    }

    static let tableHeader = pad("document", 34, left: true) + pad("KiB", 8) + pad("open p50/p95", 16)
        + pad("tab p50/p95", 14) + pad("update p50/p95", 16) + pad("work p95", 10) + pad("MiB", 7) + pad("idle%", 7)

    static let customTableHeader = pad("document", 34, left: true) + pad("KiB", 8) + pad("first p50/p95", 15)
        + pad("open p50/p95", 15) + pad("tab p50/p95", 14) + pad("update p50/p95", 16) + pad("work p95", 10)
        + pad("main p95", 10) + pad("scroll p95", 11) + pad(">144Hz", 8) + pad("view MiB", 10) + pad("idle%", 7)

    static func row(_ result: DocumentResult, custom: Bool) -> String {
        let label = result.name ?? result.path.split(separator: "/").suffix(2).joined(separator: "/")
        let kib = result.bytes.map { String(format: "%.1f", Double($0) / 1024) } ?? "-"
        let blocked = result.blockedMs.map { $0 > limitMs ? String(format: "  blocked %.0f ms", $0) : "" } ?? ""
        guard result.status == "ok", let ms = result.ms else {
            return pad(label, 34, left: true) + pad(kib, 8) + "  \(result.status): \(result.error ?? "")" + blocked
        }
        func p95(_ metric: String) -> String { ms[metric].map { String(format: "%.1f", $0.p95) } ?? "-" }
        if custom {
            return pad(label, 34, left: true) + pad(kib, 8) + pad(pair(ms["firstScreen"]), 15) + pad(pair(ms["open"]), 15)
                + pad(pair(ms["tabSwitch"]), 14) + pad(pair(ms["update"]), 16) + pad(p95("updateWork"), 10)
                + pad(p95("updateMain"), 10) + pad(p95("scrollFrame"), 11)
                + pad(result.scroll.map { "\($0.over144Hz)" } ?? "-", 8)
                + pad(result.memoryMiB?.view.map { String(format: "%.1f", $0) } ?? "-", 10)
                + pad(result.idleCPUPercent.map { String(format: "%.2f", $0.total) } ?? "-", 7) + blocked
        }
        return pad(label, 34, left: true) + pad(kib, 8) + pad(pair(ms["open"]), 16) + pad(pair(ms["tabSwitch"]), 14)
            + pad(pair(ms["update"]), 16) + pad(ms["updateWork"].map { String(format: "%.1f", $0.p95) } ?? "-", 10)
            + pad(result.memoryMiB.map { String(format: "%.1f", $0.total) } ?? "-", 7)
            + pad(result.idleCPUPercent.map { String(format: "%.2f", $0.total) } ?? "-", 7) + blocked
    }

    static func summary(_ aggregate: Aggregate) -> String {
        var lines = ["\n\(aggregate.ok) ok, \(aggregate.failed) failed, \(aggregate.skipped) skipped in \(aggregate.elapsedSeconds) s",
                     pad("all repetitions (ms)", 22, left: true) + pad("n", 7) + pad("p50", 9) + pad("p95", 9)
                        + pad("max", 10) + pad("worst doc p95", 15) + "  worst document"]
        for metric in metrics {
            guard let value = aggregate.ms[metric] else { continue }
            lines.append(pad(metric, 22, left: true) + pad("\(value.n)", 7) + pad(String(format: "%.1f", value.p50), 9)
                         + pad(String(format: "%.1f", value.p95), 9) + pad(String(format: "%.1f", value.max), 10)
                         + pad(String(format: "%.1f", value.worstP95), 15) + "  " + value.worstDocument)
        }
        if let memory = aggregate.memoryTotalMiB {
            lines.append(String(format: "memory total MiB: p50 %.1f, p95 %.1f, max %.1f", memory.p50, memory.p95, memory.max))
        }
        if let memory = aggregate.memoryViewMiB {
            lines.append(String(format: "memory per view MiB: p50 %.1f, p95 %.1f, max %.1f", memory.p50, memory.p95, memory.max))
        }
        if let scroll = aggregate.scroll {
            lines.append("scroll frames: \(scroll.frames), over 1000/144 ms: \(scroll.over144Hz), over 16.7 ms: \(scroll.over60Hz)")
        }
        if let watchdog = aggregate.watchdog {
            lines.append("over \(Int(watchdog.limitMs)) ms: \(watchdog.over.count) documents; "
                + String(format: "longest main-thread block %.1f ms (%@), slowest open %.1f ms (%@)",
                         watchdog.worstBlockedMs, watchdog.worstBlockedDocument, watchdog.worstOpenMs, watchdog.worstOpenDocument))
            for item in watchdog.over.prefix(20) {
                lines.append(String(format: "  over: blocked %.1f ms, open %.1f ms  %@", item.blockedMs, item.openMs, item.path))
            }
        }
        if let idle = aggregate.idleCPUTotalPercent {
            lines.append(String(format: "idle CPU %%: p50 %.2f, p95 %.2f, max %.2f", idle.p50, idle.p95, idle.max))
        }
        return lines.joined(separator: "\n")
    }
}
