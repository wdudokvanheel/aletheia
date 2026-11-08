import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
    Usage:
      MarkdownViewBench generate [--out DIR] [--seed N]
      MarkdownViewBench run [--set curated|own|smoke|generated] [--renderer webkit|custom] [--reps N]
                            [--limit N] [--filter TEXT] [--skip N] [--manifest PATH] [--out PATH]
                            [--preview-resources DIR] [--idle-seconds S] [--timeout S] [--onscreen]
                            [--image-latency MS]
      MarkdownViewBench run --verify-images [--manifest PATH] [--image-latency MS]
      MarkdownViewBench trace [--renderer webkit|custom] [--trace NAME[,NAME...]|all] [--reps N] [--interval MS]
                              [--manifest PATH] [--out PATH] [--preview-resources DIR] [--timeout S]
                              [--image-latency MS]

    Paths default to the repository that contains the working directory:
      generated files   build/markdown-corpus/generated/
      manifest          build/markdown-corpus/manifest.json (set "generated" reads generated/generated-manifest.json)
      results           build/markdown-corpus/results/<renderer>-<set>.json
      trace results     build/markdown-corpus/results/<renderer>-traces.json (-traces-<MS>ms.json with --interval)
      trace manifest    build/markdown-corpus/generated/generated-manifest.json
      preview resources Sources/Aletheia/Resources/Preview (WebKit only)
    The smoke set defaults to --idle-seconds 0 and --timeout 30 and runs the watchdog.
    Custom mode loads images through the bench's provider; --image-latency delays each remote image.
    run --verify-images checks the provider against the generated manifest's expected outcomes and exits.
    trace replays the generated typing traces, 5 repetitions; --interval 0 (the default) applies each
    edit once the previous one rendered, a positive interval fires edits on that schedule.
    Run in Release: swift run -c release MarkdownViewBench ...
    """

enum Paths {
    /// The nearest directory above the working directory that holds `.git`.
    static let repository: URL = {
        let start = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var url = start
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url }
            url.deleteLastPathComponent()
        }
        return start
    }()
    static let corpus = repository.appendingPathComponent("build/markdown-corpus")
}

struct Arguments {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>, options: Set<String>, flags known: Set<String> = []) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if known.contains(argument) {
                flags.insert(argument)
            } else if options.contains(argument), let value = iterator.next() {
                values[argument] = value
            } else {
                throw BenchError.unavailable("unknown or incomplete argument \(argument)\n\n\(usage)")
            }
        }
    }

    func string(_ name: String) -> String? { values[name] }
    func flag(_ name: String) -> Bool { flags.contains(name) }
    func path(_ name: String) -> URL? { values[name].map { URL(fileURLWithPath: $0).standardizedFileURL } }

    func number<T: LosslessStringConvertible>(_ name: String, default value: T) throws -> T {
        guard let text = values[name] else { return value }
        guard let number = T(text) else { throw BenchError.unavailable("\(name) needs a number, not \(text)") }
        return number
    }
}

func fail(_ error: Error) -> Never {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

let command = CommandLine.arguments.dropFirst().first
let rest = CommandLine.arguments.dropFirst(2)
switch command {
case "generate":
    do {
        let arguments = try Arguments(rest, options: ["--out", "--seed"])
        var generator = Generator(output: arguments.path("--out") ?? Paths.corpus.appendingPathComponent("generated"),
                                  seed: try arguments.number("--seed", default: 1))
        try generator.run()
    } catch { fail(error) }
case "run":
    let options: RunOptions
    do {
        let arguments = try Arguments(rest, options: ["--set", "--renderer", "--reps", "--limit", "--filter", "--skip",
                                                      "--manifest", "--out", "--preview-resources", "--idle-seconds",
                                                      "--timeout", "--image-latency"],
                                      flags: ["--onscreen", "--verify-images"])
        if arguments.flag("--verify-images") {
            let manifest = arguments.path("--manifest") ?? Paths.corpus.appendingPathComponent("generated/generated-manifest.json")
            let latency = max(0, try arguments.number("--image-latency", default: 0.0))
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task { @MainActor in
                do { exit(try await ImageVerification.run(manifest: manifest, latencyMs: latency) ? 0 : 1) } catch { fail(error) }
            }
            app.run()
        }
        let set = arguments.string("--set") ?? "curated"
        let renderer = arguments.string("--renderer") ?? "webkit"
        guard ["curated", "own", "smoke", "generated"].contains(set) else { throw BenchError.unavailable("unknown set \(set)") }
        guard ["webkit", "custom"].contains(renderer) else { throw BenchError.unavailable("unknown renderer \(renderer)") }
        let smoke = set == "smoke"
        options = RunOptions(
            manifest: arguments.path("--manifest") ?? Paths.corpus.appendingPathComponent("manifest.json"),
            set: set, renderer: renderer, repetitions: max(1, try arguments.number("--reps", default: 20)),
            output: arguments.path("--out") ?? Paths.corpus.appendingPathComponent("results/\(renderer)-\(set).json"),
            limit: try arguments.string("--limit").map { _ in try arguments.number("--limit", default: 0) },
            filter: arguments.string("--filter"),
            skip: max(0, try arguments.number("--skip", default: 0)),
            previewResources: arguments.path("--preview-resources")
                ?? Paths.repository.appendingPathComponent("Sources/Aletheia/Resources/Preview"),
            idleSeconds: try arguments.number("--idle-seconds", default: smoke ? 0 : 3.0),
            timeout: try arguments.number("--timeout", default: smoke ? 30 : 300.0),
            onscreen: arguments.flag("--onscreen"),
            watchdog: smoke,
            imageLatency: max(0, try arguments.number("--image-latency", default: 0.0)))
        guard renderer == "custom"
                || FileManager.default.fileExists(atPath: options.previewResources.appendingPathComponent("index.html").path) else {
            throw BenchError.unavailable("no index.html in \(options.previewResources.path); pass --preview-resources")
        }
    } catch {
        fputs("error: \(error.localizedDescription)\n", stderr)
        exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await Runner(options: options).run() } catch { fail(error) }
        exit(0)
    }
    app.run()
case "trace":
    let options: RunOptions
    let trace: TraceOptions
    do {
        let arguments = try Arguments(rest, options: ["--renderer", "--trace", "--reps", "--interval", "--manifest", "--out",
                                                      "--preview-resources", "--timeout", "--image-latency"])
        let renderer = arguments.string("--renderer") ?? "webkit"
        guard ["webkit", "custom"].contains(renderer) else { throw BenchError.unavailable("unknown renderer \(renderer)") }
        let interval = max(0, try arguments.number("--interval", default: 0.0))
        trace = TraceOptions(
            manifest: arguments.path("--manifest") ?? Paths.corpus.appendingPathComponent("generated/generated-manifest.json"),
            names: arguments.string("--trace") ?? "all", interval: interval)
        let name = interval > 0 ? "\(renderer)-traces-\(String(format: "%g", interval))ms.json" : "\(renderer)-traces.json"
        options = RunOptions(
            manifest: trace.manifest, set: "traces", renderer: renderer,
            repetitions: max(1, try arguments.number("--reps", default: 5)),
            output: arguments.path("--out") ?? Paths.corpus.appendingPathComponent("results/\(name)"),
            limit: nil, filter: nil, skip: 0,
            previewResources: arguments.path("--preview-resources")
                ?? Paths.repository.appendingPathComponent("Sources/Aletheia/Resources/Preview"),
            idleSeconds: 0, timeout: try arguments.number("--timeout", default: 60.0), onscreen: false, watchdog: false,
            imageLatency: max(0, try arguments.number("--image-latency", default: 0.0)))
        guard renderer == "custom"
                || FileManager.default.fileExists(atPath: options.previewResources.appendingPathComponent("index.html").path) else {
            throw BenchError.unavailable("no index.html in \(options.previewResources.path); pass --preview-resources")
        }
    } catch {
        fputs("error: \(error.localizedDescription)\n", stderr)
        exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await Runner(options: options).runTraces(trace) } catch { fail(error) }
        exit(0)
    }
    app.run()
default:
    print(usage)
    exit(command == nil || command == "help" || command == "--help" ? 0 : 2)
}
