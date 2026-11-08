import CoreText
import Darwin
import Dispatch
import os
import Synchronization

/// The `CTLine`s typeset from one string, which can be dropped and typeset
/// again: a window of a block's text or a run of table rows.
///
/// A line keeps the shaping of the whole string it was typeset from, so the
/// lines of large documents take most of their layout's memory. A layout
/// keeps each line's geometry, which never changes; the lines themselves
/// live here, one set per string, and are kept within `LineCache`'s budget.
/// A set that was dropped is typeset again from the same string at the
/// same ranges, without breaking lines again, when one of its lines is
/// drawn or hit-tested, or ahead of time as the view scrolls toward it.
/// Each string is at most a few thousand units long, so that costs about a
/// millisecond.
final class LineSet: @unchecked Sendable {
    private struct State {
        var ranges: [CFRange] = []
        /// Nil while dropped.
        var lines: [CTLine]?
        /// What the kept lines cost, counted in `LineCache`.
        var cost = 0
    }

    /// The length of the string, in UTF-16 units.
    let length: Int
    /// Called with the lock held, so never concurrently.
    private let typeset: () -> CTTypesetter?
    /// Guarded by `lock`. Core Text objects are not `Sendable`, which
    /// `Mutex` would require of them.
    private var storage = State()
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        return lock
    }()
    /// When a line was last used, in uptime milliseconds; 0 for lines laid
    /// out ahead of being needed.
    let lastUse = Atomic<UInt64>(0)

    /// A set for a string `length` units long, which `typeset` typesets
    /// again exactly as the lines appended to it were typeset. A set whose
    /// lines are laid out ahead of being drawn (not `isWarm`) is among the
    /// first dropped, and starts dropped when the budget is already spent.
    init(length: Int, isWarm: Bool, typeset: @escaping () -> CTTypesetter?) {
        self.length = length
        self.typeset = typeset
        if isWarm { lastUse.store(LineCache.now(), ordering: .relaxed) }
        storage.lines = isWarm || !LineCache.isOverBudget ? [] : nil
    }

    deinit {
        if storage.cost > 0 { LineCache.remove(ObjectIdentifier(self), cost: storage.cost) }
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    private func withLock<Result>(_ body: (inout State) -> Result) -> Result {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body(&storage)
    }

    /// Whether the set keeps its lines; a dropped set only records the
    /// ranges of the lines appended to it.
    var isKept: Bool { withLock { $0.lines != nil } }

    /// Adds a line typeset from the set's typesetter at `range`, while it is
    /// being built, and returns its index. `line` may be nil when the set
    /// is not kept.
    func append(_ line: CTLine?, range: CFRange) -> Int32 {
        withLock { state in
            state.ranges.append(range)
            let index = Int32(state.ranges.count - 1)
            guard state.lines != nil else { return index }
            guard let line else {
                // Without its line the set cannot be kept as it is.
                if state.cost > 0 { LineCache.remove(ObjectIdentifier(self), cost: state.cost) }
                state.lines = nil
                state.cost = 0
                return index
            }
            state.lines?.append(line)
            let isNew = state.cost == 0
            let added = (isNew ? Self.stringCost(length) : 0) + Self.lineCost
            state.cost += added
            LineCache.add(self, cost: added, isNew: isNew)
            return index
        }
    }

    /// Line `index`, typeset again first if it was dropped.
    func line(at index: Int32) -> CTLine {
        lastUse.store(LineCache.now(), ordering: .relaxed)
        return withLock { state in
            if let lines = state.lines { return lines[Int(index)] }
            let lines = keep(makeLines(state.ranges), &state)
            return lines[Int(index)]
        }
    }

    /// Typesets the lines again if they were dropped, and marks them used.
    func prefetch() {
        lastUse.store(LineCache.now(), ordering: .relaxed)
        withLock { state in
            if state.lines == nil { _ = keep(makeLines(state.ranges), &state) }
        }
    }

    /// Keeps `lines`, typeset again, and counts them. The cache's books
    /// change with the lines, under the lock, so a drop and a typesetting
    /// on two threads cannot leave a cost the cache no longer knows of.
    private func keep(_ lines: [CTLine], _ state: inout State) -> [CTLine] {
        state.lines = lines
        let cost = Self.stringCost(length) + Self.lineCost * lines.count
        if cost != state.cost {
            if state.cost > 0 { LineCache.remove(ObjectIdentifier(self), cost: state.cost) }
            state.cost = cost
            LineCache.add(self, cost: cost, isNew: true)
        }
        return lines
    }

    /// Drops the lines unless they were used since `cutoff`.
    fileprivate func drop(unlessUsedSince cutoff: UInt64) {
        let lines = withLock { state -> [CTLine]? in
            guard state.lines != nil, lastUse.load(ordering: .relaxed) < cutoff else { return nil }
            let lines = state.lines
            if state.cost > 0 { LineCache.remove(ObjectIdentifier(self), cost: state.cost) }
            state.lines = nil
            state.cost = 0
            return lines
        }
        // Freed outside the lock.
        withExtendedLifetime(lines) {}
    }

    private func makeLines(_ ranges: [CFRange]) -> [CTLine] {
        guard let typesetter = typeset() else {
            let empty = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "" as CFString, nil))
            return ranges.map { _ in empty }
        }
        return ranges.map { CTTypesetterCreateLine(typesetter, $0) }
    }

    /// About what Core Text keeps for a set's string, which every line keeps
    /// alive, and for each line's own runs.
    private static func stringCost(_ length: Int) -> Int { 2_048 + 24 * length }
    private static let lineCost = 640
}

/// The budget for the lines kept by every view, shared, so a window that
/// shows a huge document leaves room for the others. Once their cost
/// exceeds it, lines are dropped down to three quarters of it: first those
/// laid out ahead of being needed, then the least recently used, sparing
/// lines used in the last second.
enum LineCache {
    /// About 48 MiB of lines: several screens of each of many windows, and
    /// every line of documents up to a few MiB.
    static let budget = 48 << 20
    private static let total = Atomic<Int>(0)
    private static let isTrimScheduled = Atomic<Bool>(false)
    private static let isRetryScheduled = Atomic<Bool>(false)
    private static let registry = Mutex<[ObjectIdentifier: WeakSet]>([:])
    private static let queue = DispatchQueue(label: "MarkdownView.lines", qos: .utility)

    private struct WeakSet {
        weak var set: LineSet?
    }

    /// What the kept lines cost, estimated.
    static var keptCost: Int { total.load(ordering: .relaxed) }

    static var isOverBudget: Bool { total.load(ordering: .relaxed) > budget }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000 }

    fileprivate static func add(_ set: LineSet, cost: Int, isNew: Bool) {
        if isNew { registry.withLock { $0[ObjectIdentifier(set)] = WeakSet(set: set) } }
        let kept = total.add(cost, ordering: .relaxed).newValue
        if kept > budget, !isTrimScheduled.exchange(true, ordering: .relaxed) {
            queue.async { trim() }
        }
    }

    fileprivate static func remove(_ id: ObjectIdentifier, cost: Int) {
        registry.withLock { _ = $0.removeValue(forKey: id) }
        total.subtract(cost, ordering: .relaxed)
    }

    /// Drops the least recently used lines until they fit three quarters of
    /// the budget. When only lines used in the last second are left over
    /// the budget, it tries once more a second later, when they may no
    /// longer be in use; nothing runs again while idle.
    static func trim(to target: Int = budget * 3 / 4, sparingMilliseconds recent: UInt64 = 1_000) {
        isTrimScheduled.store(false, ordering: .relaxed)
        guard total.load(ordering: .relaxed) > target else { return }
        let sets = registry.withLock { registry in
            registry.values.compactMap { entry in entry.set.map { ($0, $0.lastUse.load(ordering: .relaxed)) } }
        }
        let cutoff = now() &- recent &+ (recent == 0 ? 1 : 0)
        var isSparing = false
        for (set, used) in sets.sorted(by: { $0.1 < $1.1 }) {
            guard total.load(ordering: .relaxed) > target else { return }
            guard used < cutoff else {
                isSparing = true
                break
            }
            set.drop(unlessUsedSince: cutoff)
        }
        if isSparing, total.load(ordering: .relaxed) > budget, !isRetryScheduled.exchange(true, ordering: .relaxed) {
            queue.asyncAfter(deadline: .now() + 1.1) {
                isRetryScheduled.store(false, ordering: .relaxed)
                trim()
            }
        }
    }

    /// Marks `sets` used, and typesets those that were dropped again off the
    /// main thread, so lines near the view are kept and ready.
    static func prefetch(_ sets: [LineSet]) {
        let now = now()
        for set in sets { set.lastUse.store(now, ordering: .relaxed) }
        let dropped = sets.filter { !$0.isKept }
        guard !dropped.isEmpty else { return }
        queue.async {
            for set in dropped { set.prefetch() }
        }
    }
}
