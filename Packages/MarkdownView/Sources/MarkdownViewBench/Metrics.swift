import Darwin
import Foundation
import os

let signposter = OSSignposter(subsystem: "local.aletheia.MarkdownViewBench", category: .pointsOfInterest)

/// Runs `body` inside a signpost interval visible in Instruments' Points of Interest.
@MainActor
func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
    let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
    defer { signposter.endInterval(name, state) }
    return try await body()
}

/// Monotonic nanoseconds.
func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func milliseconds(_ start: UInt64, _ end: UInt64) -> Double { Double(end &- start) / 1_000_000 }

/// A WebKit helper process attributed to this process.
struct Helper: Hashable {
    let pid: pid_t
    /// `WebContent`, `Networking`, `GPU`, ...
    let kind: String
}

enum ProcessMetrics {
    private static let ticks: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    /// libquarantine's `responsibility_get_pid_responsible_for_pid`. XPC helpers are children of
    /// launchd, but they share the responsible process of the client that launched them.
    private static let responsible: ResponsibleFunction? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    static var attribution: String {
        (responsible == nil ? "" : "same responsible process, ") + "com.apple.WebKit.* started after the bench"
    }

    private static func usage(_ pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return result == 0 ? info : nil
    }

    /// The bench's own physical footprint, as `task_info(TASK_VM_INFO).phys_footprint`.
    static func ownFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func footprint(_ pid: pid_t) -> UInt64? { usage(pid)?.ri_phys_footprint }

    /// User plus system CPU time; rusage reports mach ticks.
    static func cpuNanoseconds(_ pid: pid_t) -> UInt64? {
        usage(pid).map { ($0.ri_user_time + $0.ri_system_time) * ticks.numer / ticks.denom }
    }

    private static func startTime(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    private static let ownStart = startTime(getpid()) ?? 0

    static func helpers() -> [Helper] {
        let own = getpid()
        let owner = responsible?(own)
        var pids = [pid_t](repeating: 0, count: 16_384)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        var path = [CChar](repeating: 0, count: 4096)
        var result: [Helper] = []
        for pid in pids.prefix(max(count, 0)) where pid > 0 && pid != own {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let name = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }.split(separator: "/").last ?? ""
            guard name.hasPrefix("com.apple.WebKit."), let start = startTime(pid), start >= ownStart,
                  owner == nil || responsible?(pid) == owner else { continue }
            result.append(Helper(pid: pid, kind: String(name.dropFirst("com.apple.WebKit.".count))))
        }
        return result
    }

    static func memory() -> Memory {
        let mib = 1_048_576.0
        let helpers = helpers()
        var byKind: [String: Double] = [:]
        var total: UInt64 = 0
        for helper in helpers {
            let bytes = footprint(helper.pid) ?? 0
            total += bytes
            byKind[helper.kind, default: 0] += Double(bytes) / mib
        }
        let process = Double(ownFootprint()) / mib
        return Memory(process: round1(process), helpers: round1(Double(total) / mib),
                      total: round1(process + Double(total) / mib),
                      helpersByKind: byKind.mapValues(round1), helperProcesses: helpers.count)
    }

    /// CPU nanoseconds of the bench and of each helper alive at both ends of `seconds`.
    static func idleCPU(seconds: Double) async throws -> IdleCPU {
        let helpers = helpers()
        func sample() -> (UInt64?, [pid_t: UInt64]) {
            (cpuNanoseconds(getpid()), Dictionary(uniqueKeysWithValues: helpers.compactMap { h in
                cpuNanoseconds(h.pid).map { (h.pid, $0) } }))
        }
        let (ownBefore, before) = sample()
        let start = now()
        try await Task.sleep(for: .seconds(seconds))
        let (ownAfter, after) = sample()
        let wall = Double(now() - start)
        let process = Double((ownAfter ?? 0) &- (ownBefore ?? 0)) / wall * 100
        var byKind: [String: Double] = [:]
        for helper in helpers {
            guard let start = before[helper.pid], let end = after[helper.pid] else { continue }
            byKind[helper.kind, default: 0] += Double(end &- start) / wall * 100
        }
        let helper = byKind.values.reduce(0, +)
        return IdleCPU(seconds: seconds, process: round2(process), helpers: round2(helper), total: round2(process + helper),
                       helpersByKind: byKind.mapValues(round2))
    }
}

struct Memory: Codable {
    let process: Double
    let helpers: Double
    let total: Double
    let helpersByKind: [String: Double]
    let helperProcesses: Int
}

struct IdleCPU: Codable {
    let seconds: Double
    let process: Double
    let helpers: Double
    let total: Double
    let helpersByKind: [String: Double]
}

func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

/// Nearest-rank percentiles over the repetitions of one measurement.
struct Summary: Codable {
    let n: Int
    let p50: Double
    let p95: Double
    let min: Double
    let max: Double

    init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        n = sorted.count
        p50 = round2(percentile(sorted, 0.50))
        p95 = round2(percentile(sorted, 0.95))
        min = round2(sorted[0])
        max = round2(sorted[sorted.count - 1])
    }
}

func percentile(_ sorted: [Double], _ q: Double) -> Double {
    sorted[Swift.max(0, Swift.min(sorted.count - 1, Int((q * Double(sorted.count)).rounded(.up)) - 1))]
}

/// Machine, OS, build and source revision for a result file.
struct Environment: Codable {
    struct Machine: Codable { let model: String; let cpu: String; let cores: Int; let memoryGiB: Int }
    struct OS: Codable { let version: String; let build: String }
    struct Git: Codable { let commit: String; let dirty: Bool }
    let machine: Machine
    let os: OS
    let build: String
    let git: Git?
    let webkit: String?

    @MainActor
    static func current(repository: URL, webkitVersion: String?) -> Environment {
        func string(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
            return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
        func integer(_ name: String) -> Int64 {
            var value: Int64 = 0
            var size = MemoryLayout<Int64>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : 0
        }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        let commit = git(["rev-parse", "HEAD"], in: repository)
        let status = git(["status", "--porcelain", "--untracked-files=no"], in: repository)
        return Environment(
            machine: Machine(model: string("hw.model"), cpu: string("machdep.cpu.brand_string"),
                             cores: Int(integer("hw.ncpu")), memoryGiB: Int(integer("hw.memsize") >> 30)),
            os: OS(version: string("kern.osproductversion"), build: string("kern.osversion")),
            build: build, git: commit.map { Git(commit: $0, dirty: status.map { !$0.isEmpty } ?? false) },
            webkit: webkitVersion)
    }

    private static func git(_ arguments: [String], in directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
