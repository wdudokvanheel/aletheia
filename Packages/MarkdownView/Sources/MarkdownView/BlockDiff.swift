import CoreGraphics

/// How the top-level blocks of a parse line up with the previous parse's:
/// runs of equal blocks at the start and at the end, and between them equal
/// blocks found by hash, which also catches moved blocks. Equal means the
/// same kind, indentation, and source text. A single edit costs the blocks it
/// touched plus comparisons proportional to the source length.
struct BlockMatch: Sendable, Equatable {
    let oldCount: Int
    let newCount: Int
    /// Equal blocks at the start, which keep their indices.
    let prefix: Int
    /// Equal blocks at the end, whose indices shift by `newCount - oldCount`.
    let suffix: Int
    /// For each old block in `prefix..<oldCount - suffix`, its equal new block, or -1.
    private let oldMiddle: [Int32]
    /// For each new block in `prefix..<newCount - suffix`, its equal old block, or -1.
    private let newMiddle: [Int32]

    init(oldCount: Int, newCount: Int, equal: (_ old: Int, _ new: Int) -> Bool,
         oldHash: (Int) -> Int, newHash: (Int) -> Int) {
        self.oldCount = oldCount
        self.newCount = newCount
        let limit = min(oldCount, newCount)
        var prefix = 0
        while prefix < limit, equal(prefix, prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, equal(oldCount - 1 - suffix, newCount - 1 - suffix) { suffix += 1 }
        self.prefix = prefix
        self.suffix = suffix
        var oldMiddle = [Int32](repeating: -1, count: oldCount - suffix - prefix)
        var newMiddle = [Int32](repeating: -1, count: newCount - suffix - prefix)
        if !oldMiddle.isEmpty, !newMiddle.isEmpty {
            var buckets: [Int: [Int]] = [:]
            for old in prefix..<(oldCount - suffix) { buckets[oldHash(old), default: []].append(old) }
            // Equal blocks are taken in order; the cursor skips those already taken.
            var cursors: [Int: Int] = [:]
            for new in prefix..<(newCount - suffix) {
                let hash = newHash(new)
                guard let bucket = buckets[hash] else { continue }
                var cursor = cursors[hash, default: 0]
                while cursor < bucket.count, oldMiddle[bucket[cursor] - prefix] >= 0 { cursor += 1 }
                cursors[hash] = cursor
                for old in bucket[cursor...] where oldMiddle[old - prefix] < 0 && equal(old, new) {
                    oldMiddle[old - prefix] = Int32(new)
                    newMiddle[new - prefix] = Int32(old)
                    break
                }
            }
        }
        self.oldMiddle = oldMiddle
        self.newMiddle = newMiddle
    }

    /// The new index of an old block that is unchanged, or nil.
    func newIndex(ofOld index: Int) -> Int? {
        guard index >= 0, index < oldCount else { return nil }
        if index < prefix { return index }
        if index >= oldCount - suffix { return index + newCount - oldCount }
        let new = oldMiddle[index - prefix]
        return new >= 0 ? Int(new) : nil
    }

    /// The old index of a new block that is unchanged, or nil.
    func oldIndex(ofNew index: Int) -> Int? {
        guard index >= 0, index < newCount else { return nil }
        if index < prefix { return index }
        if index >= newCount - suffix { return index + oldCount - newCount }
        let old = newMiddle[index - prefix]
        return old >= 0 ? Int(old) : nil
    }

    /// The number of new blocks equal to an old one.
    var matchedCount: Int { prefix + suffix + newMiddle.count(where: { $0 >= 0 }) }

    /// How far the lookups below walk through changed blocks, so they stay
    /// cheap on the main thread.
    private static let walkLimit = 64

    /// The nearest old block before `index` that is unchanged, within
    /// `walkLimit` blocks; -1 for the start of the document.
    func lastMatchedOld(before index: Int) -> Int? {
        var above = index - 1
        while above >= 0, newIndex(ofOld: above) == nil {
            guard index - above < Self.walkLimit else { return nil }
            above -= 1
        }
        return above
    }

    /// The new block at the same place in its run of changed blocks as the
    /// changed old block `index`: runs start after the nearest unchanged
    /// block above, in both documents. Nil when the new run is shorter.
    func pairedNewIndex(ofOld index: Int) -> Int? {
        guard let above = lastMatchedOld(before: index) else { return nil }
        let start = above >= 0 ? (newIndex(ofOld: above) ?? 0) + 1 : 0
        let candidate = start + index - above - 1
        guard candidate < newCount else { return nil }
        for new in start...candidate where oldIndex(ofNew: new) != nil { return nil }
        return candidate
    }
}

/// The part of the source that changed between two parses, in UTF-16
/// offsets: `old` in the previous source became `new` in this one. Both
/// start at the same offset, and everything after them shifted.
struct SourceEdit: Sendable, Equatable {
    var old: Range<Int>
    var new: Range<Int>

    /// Carries an offset in the previous source into this one: kept before
    /// the edit, shifted after it, and clamped inside it. At the edit's start,
    /// `upstream` keeps the offset before inserted text, and otherwise it
    /// moves past it, so typing at either end of a range does not extend it.
    func map(_ offset: Int, upstream: Bool) -> Int {
        if offset < old.lowerBound || (upstream && offset == old.lowerBound) { return offset }
        if offset >= old.upperBound { return offset + new.count - old.count }
        return min(offset, new.upperBound)
    }
}

/// How a snapshot of an edited source relates to the snapshot it was diffed
/// against, its base, so the selection and scroll position carry across.
struct BlockUpdate: Sendable {
    /// The `MarkdownSnapshot.id` of the base.
    let baseID: UInt64
    /// Unchanged blocks; nil when none could be reused, as when the link
    /// reference definitions changed.
    let match: BlockMatch?
    let edit: SourceEdit
}

/// The number of equal bytes at the start of `a` and `b`.
func commonPrefixLength(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
    let count = min(a.count, b.count)
    guard count > 0, let first = a.baseAddress, let second = b.baseAddress else { return 0 }
    let left = UnsafeRawPointer(first)
    let right = UnsafeRawPointer(second)
    var index = 0
    while index + 8 <= count,
          left.loadUnaligned(fromByteOffset: index, as: UInt64.self)
            == right.loadUnaligned(fromByteOffset: index, as: UInt64.self) {
        index += 8
    }
    while index < count, first[index] == second[index] { index += 1 }
    return index
}

/// The number of equal bytes at the end of `a` and `b`, at most `limit`.
func commonSuffixLength(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>, limit: Int) -> Int {
    let count = min(a.count, b.count, max(limit, 0))
    guard count > 0, let first = a.baseAddress, let second = b.baseAddress else { return 0 }
    let left = UnsafeRawPointer(first + a.count)
    let right = UnsafeRawPointer(second + b.count)
    var length = 0
    while length + 8 <= count,
          left.loadUnaligned(fromByteOffset: -length - 8, as: UInt64.self)
            == right.loadUnaligned(fromByteOffset: -length - 8, as: UInt64.self) {
        length += 8
    }
    while length < count, first[a.count - 1 - length] == second[b.count - 1 - length] { length += 1 }
    return length
}

extension MarkdownSnapshot {
    /// The layouts of `base` that still fit the blocks of a new parse:
    /// those of blocks the diff matched, when laid out at the same column
    /// width with the same typography. Nil entries need a layout. For those,
    /// `hints` holds an earlier layout whose tables lend what still applies:
    /// a matched block's layout at another width or partly laid out, and
    /// for an edited table, the old table at its place among the changed
    /// blocks, so only its edited rows are measured again.
    static func reusableLayouts(from base: MarkdownSnapshot, match: BlockMatch?, blocks: [MarkdownBlock],
                                columnWidth: CGFloat, typography: Typography)
        -> (layouts: [BlockLayout?], hints: [BlockLayout?]) {
        let newCount = blocks.count
        var layouts = [BlockLayout?](repeating: nil, count: newCount)
        var hints = [BlockLayout?](repeating: nil, count: newCount)
        guard let match, base.typography === typography, match.oldCount == base.layouts.count else { return (layouts, hints) }
        for index in 0..<newCount {
            guard let old = match.oldIndex(ofNew: index) else { continue }
            let layout = base.layouts[old]
            if layout.isFinal(for: columnWidth) {
                layouts[index] = layout
            } else if !layout.isEstimate, !layout.tables.isEmpty {
                hints[index] = layout
            }
        }
        if match.prefix < match.oldCount - match.suffix {
            for old in match.prefix..<(match.oldCount - match.suffix) where match.newIndex(ofOld: old) == nil {
                let layout = base.layouts[old]
                guard !layout.isEstimate, !layout.tables.isEmpty, let new = match.pairedNewIndex(ofOld: old),
                      layouts[new] == nil, hints[new] == nil, !blocks[new].tables.isEmpty else { continue }
                hints[new] = layout
            }
        }
        return (layouts, hints)
    }

    /// Parses `source` and lays it out at `width`, rebuilding and laying out
    /// only the blocks that changed since `base`. Equivalent to laying out
    /// `MarkdownDocument.parse(source)` from scratch.
    static func updating(_ base: MarkdownSnapshot, to source: String, width: CGFloat,
                         typography: Typography = .standard, generation: UInt64 = 0) throws
        -> (snapshot: MarkdownSnapshot, reused: Int, laidOut: Int) {
        let parsed = try MarkdownDocument.parse(source, reusing: base.document)
        let columnWidth = typography.column(forWidth: width).width
        let (reused, hints) = reusableLayouts(from: base, match: parsed.match, blocks: parsed.document.blocks,
                                              columnWidth: columnWidth, typography: typography)
        let layouts = BlockLayout.layOut(parsed.document.blocks, filling: reused, hints: hints, columnWidth: columnWidth,
                                         typography: typography) ?? []
        let reusedCount = reused.count(where: { $0 != nil })
        let snapshot = MarkdownSnapshot(document: parsed.document, layouts: layouts, width: width,
                                        typography: typography, generation: generation,
                                        update: BlockUpdate(baseID: base.id, match: parsed.match, edit: parsed.edit))
        return (snapshot, reusedCount, layouts.count - reusedCount)
    }

    /// The update relating this snapshot to `old`, if `old` is its base.
    func update(from old: MarkdownSnapshot) -> BlockUpdate? {
        guard let update, update.baseID == old.id else { return nil }
        return update
    }

    /// The index of the block holding a source offset, counting the offset
    /// just past a block's end as inside it, or the first block after it.
    func firstBlock(endingAtOrAfterSource offset: Int) -> Int {
        let blocks = document.blocks
        var low = 0
        var high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if blocks[mid].sourceRange.upperBound < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: Scroll anchoring

    /// Where to scroll after `old`, scrolled to `y`, is replaced by this
    /// snapshot of the edited source: the block at the top of the visible area
    /// stays at the same screen position, so edits above it do not move what
    /// is being read. That block is followed through the diff when unchanged,
    /// and otherwise through the source edit, which finds the block now
    /// holding its start. When the edit began above that start (edits
    /// coalesced from several places), the nearest unchanged block above it
    /// stays in place instead. At the very top the view stays at the top, as
    /// CSS scroll anchoring does. Constant work apart from binary searches.
    func anchoredY(_ y: CGFloat, from old: MarkdownSnapshot, through update: BlockUpdate) -> CGFloat {
        guard y > 0 else { return y }
        let index = old.firstBlock(endingBelow: y)
        guard index < old.layouts.count else { return y }
        let offset = y - old.blockTops[index]
        if let new = update.match?.newIndex(ofOld: index) { return blockTops[new] + offset }
        let edit = update.edit
        if let row = tableRowY(offset, inBlock: index, from: old, through: edit) { return row }
        let start = old.document.blocks[index].sourceRange.lowerBound
        if start <= edit.old.lowerBound || start >= edit.old.upperBound {
            let new = firstBlock(endingAtOrAfterSource: edit.map(start, upstream: true))
            return new < layouts.count ? blockTops[new] + offset : y
        }
        if let match = update.match, let above = match.lastMatchedOld(before: index), above >= 0,
           let new = match.newIndex(ofOld: above) {
            return blockTops[new] + y - old.blockTops[above]
        }
        return y
    }

    /// For a point `offset` into an edited table block of `old`, the same
    /// point in the row that now holds that row's source line, so a table
    /// row stays put when rows above it change height.
    private func tableRowY(_ offset: CGFloat, inBlock index: Int, from old: MarkdownSnapshot,
                           through edit: SourceEdit) -> CGFloat? {
        guard let table = old.table(inBlock: index, atY: offset), !table.rows.isEmpty else { return nil }
        let row = table.row(atY: offset - table.rect.minY)
        let start = old.document.blocks[index].sourceRange.lowerBound + Int(table.structure.rowSourceStarts[row])
        guard start <= edit.old.lowerBound || start >= edit.old.upperBound else { return nil }
        let mapped = edit.map(start, upstream: true)
        let new = firstBlock(endingAtOrAfterSource: mapped)
        guard new < layouts.count else { return nil }
        let local = mapped - document.blocks[new].sourceRange.lowerBound
        for candidate in layouts[new].tables where candidate.rows.count == candidate.structure.rowCount {
            guard let newRow = candidate.structure.row(startingAtSource: local) else { continue }
            return blockTops[new] + candidate.rect.minY + candidate.rowTops[newRow]
                + offset - table.rect.minY - table.rowTops[row]
        }
        return nil
    }

    // MARK: Invalidation

    /// What to redraw within `visible` (view coordinates, after scrolling)
    /// when this snapshot replaces `old`, its base: every block whose layout
    /// is new, with the gaps around it, and everything from the first block
    /// that moved down to the bottom of `visible`. Unchanged blocks above the
    /// first height change keep their pixels. Nil when everything must redraw:
    /// `old` is not the base, or the column moved.
    func changedRects(from old: MarkdownSnapshot, in visible: CGRect) -> [CGRect]? {
        guard let update = update(from: old), columnX == old.columnX, columnWidth == old.columnWidth else { return nil }
        // Glyphs overhang their line boxes a little; draw clips 8 pt wider too.
        let overhang: CGFloat = 8
        var rects: [CGRect] = []
        func band(_ minY: CGFloat, _ maxY: CGFloat) {
            let rect = CGRect(x: visible.minX, y: minY - overhang, width: visible.width,
                              height: maxY - minY + 2 * overhang).intersection(visible)
            if !rect.isNull, !rect.isEmpty { rects.append(rect) }
        }
        func bottom(ofBlockAbove index: Int) -> CGFloat {
            index > 0 ? blockTops[index - 1] + layouts[index - 1].height : 0
        }
        let range = blockRange(intersecting: visible.minY - overhang, visible.maxY + overhang)
        guard !range.isEmpty else {
            band(visible.minY, visible.maxY)
            return rects
        }
        var lastOld: Int?
        for index in range {
            let oldIndex = update.match?.oldIndex(ofNew: index)
            guard let oldIndex, old.layouts[oldIndex] === layouts[index] else {
                band(bottom(ofBlockAbove: index), index + 1 < layouts.count ? blockTops[index + 1] : totalHeight)
                lastOld = nil
                continue
            }
            if old.blockTops[oldIndex] != blockTops[index] {
                band(bottom(ofBlockAbove: index), visible.maxY)
                return rects
            }
            lastOld = oldIndex
        }
        // Below the last block, old content may remain where nothing is now.
        if range.upperBound == layouts.count, lastOld != old.layouts.count - 1 || totalHeight != old.totalHeight {
            band(bottom(ofBlockAbove: layouts.count), visible.maxY)
        }
        return rects
    }
}
