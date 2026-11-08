import CoreGraphics
import Synchronization

/// An immutable, fully positioned document: block layouts, their y offsets as
/// prefix sums, the total height, and the width and generation it was made for.
public struct MarkdownSnapshot: Sendable {
    public static let empty = MarkdownSnapshot(document: MarkdownDocument(blocks: []), layouts: [], width: 0,
                                               typography: .standard, generation: 0)

    /// The update this snapshot answers; newer generations replace older ones.
    public let generation: UInt64
    /// The view width it was laid out for.
    public let width: CGFloat
    public let columnX: CGFloat
    public let columnWidth: CGFloat
    public let document: MarkdownDocument
    /// Parallel to `document.blocks`.
    public let layouts: [BlockLayout]
    /// The top of each block's box, in view coordinates.
    public let blockTops: [CGFloat]
    public let totalHeight: CGFloat
    /// False while some blocks still carry estimated layouts or layouts for
    /// another width, between the two steps of an open or a resize.
    public let isComplete: Bool
    let typography: Typography
    /// Unique per snapshot, so an update can name its base.
    let id: UInt64
    /// How `document` relates to the snapshot it was diffed against, kept by
    /// every relayout of the same document.
    let update: BlockUpdate?
    /// The natural sizes of the loaded images it was laid out with.
    let images: ImageSizes

    private static let ids = Atomic<UInt64>(0)
    #if DEBUG
    /// Passes over every layout to compute y offsets, counted so tests can
    /// check that installing a snapshot on the main thread makes none.
    static let prefixSumPasses = Atomic<Int>(0)
    #endif

    /// Positions `layouts` (one per block of `document`) top to bottom,
    /// collapsing adjacent margins as CSS does.
    public init(document: MarkdownDocument, layouts: [BlockLayout], width: CGFloat, typography: Typography,
                generation: UInt64) {
        self.init(document: document, layouts: layouts, width: width, typography: typography,
                  generation: generation, update: nil)
    }

    /// Computes the y offsets as prefix sums, in one pass over the layouts.
    /// Snapshots are built off the main thread; installing one only reads them.
    init(document: MarkdownDocument, layouts: [BlockLayout], width: CGFloat, typography: Typography,
         generation: UInt64, update: BlockUpdate?, images: ImageSizes = .none) {
        precondition(layouts.count == document.blocks.count, "one layout per block")
        #if DEBUG
        Self.prefixSumPasses.add(1, ordering: .relaxed)
        #endif
        let column = typography.column(forWidth: width)
        var tops: [CGFloat] = []
        tops.reserveCapacity(layouts.count)
        var y = typography.topInset
        var pendingMargin: CGFloat = 0
        var complete = true
        for (index, layout) in layouts.enumerated() {
            complete = complete && layout.isFinal(for: column.width, images: images, block: document.blocks[index])
            if layout.isDropped {
                tops.append(y)
                continue
            }
            let top = y + max(pendingMargin, layout.marginTop)
            tops.append(top)
            y = top + layout.height
            pendingMargin = layout.marginBottom
        }
        self.generation = generation
        self.width = width
        columnX = column.x
        columnWidth = column.width
        self.document = document
        self.layouts = layouts
        blockTops = tops
        totalHeight = (y + pendingMargin + typography.bottomInset).rounded(.up)
        isComplete = complete
        self.typography = typography
        id = Self.ids.add(1, ordering: .relaxed).newValue
        self.update = update
        self.images = images
    }

    /// Lays out every block of `document` for a view `width`, in parallel.
    public static func layOut(_ document: MarkdownDocument, width: CGFloat, typography: Typography = .standard,
                              generation: UInt64 = 0) -> MarkdownSnapshot {
        layOut(document, width: width, typography: typography, generation: generation, images: .none)
    }

    /// The same, with the images loaded in `images`.
    static func layOut(_ document: MarkdownDocument, width: CGFloat, typography: Typography = .standard,
                       generation: UInt64 = 0, images: ImageSizes) -> MarkdownSnapshot {
        let columnWidth = typography.column(forWidth: width).width
        let layouts = BlockLayout.layOut(document.blocks, columnWidth: columnWidth, typography: typography,
                                         images: images) ?? []
        return MarkdownSnapshot(document: document, layouts: layouts, width: width, typography: typography,
                                generation: generation, update: nil, images: images)
    }

    /// The blocks whose boxes intersect `minY..<maxY`, found by binary search.
    public func blockRange(intersecting minY: CGFloat, _ maxY: CGFloat) -> Range<Int> {
        let first = firstBlock(endingBelow: minY)
        var low = first
        var high = blockTops.count
        while low < high {
            let mid = (low + high) / 2
            if blockTops[mid] < maxY { low = mid + 1 } else { high = mid }
        }
        return first..<max(first, low)
    }

    /// The index of the first block whose box ends below `y`, or the count.
    func firstBlock(endingBelow y: CGFloat) -> Int {
        var low = 0
        var high = blockTops.count
        while low < high {
            let mid = (low + high) / 2
            if blockTops[mid] + layouts[mid].height <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The sets holding the lines of the blocks and table rows that
    /// intersect `minY..<maxY`, each once.
    func lineSets(intersecting minY: CGFloat, _ maxY: CGFloat) -> [LineSet] {
        var sets: [LineSet] = []
        var seen = Set<ObjectIdentifier>()
        func add(_ set: LineSet) {
            if sets.last === set { return }
            if seen.insert(ObjectIdentifier(set)).inserted { sets.append(set) }
        }
        for index in blockRange(intersecting: minY, maxY) {
            let layout = layouts[index]
            let top = blockTops[index]
            var line = layout.firstLine(endingBelow: minY - top)
            while line < layout.lines.count, top + layout.lines[line].top < maxY {
                add(layout.lines[line].lineSet)
                line += 1
            }
            for table in layout.tables {
                let tableTop = top + table.rect.minY
                for row in table.rows(intersecting: minY - tableTop, maxY - tableTop) {
                    for cellLine in table.rows[row].lines { add(cellLine.lineSet) }
                }
            }
        }
        return sets
    }

    func with(generation: UInt64) -> MarkdownSnapshot {
        MarkdownSnapshot(document: document, layouts: layouts, width: width, typography: typography,
                         generation: generation, update: update, images: images)
    }

    /// A scroll position as a block index plus a fraction of that block's
    /// height, so it survives the block changing height. Above the block's top
    /// (in a margin), it keeps the distance in points instead.
    /// In a table, it is a row and the distance into it instead, so rows
    /// above changing height, as when they are laid out after estimates,
    /// do not move what is shown.
    func anchor(atY y: CGFloat) -> ScrollAnchor? {
        let index = firstBlock(endingBelow: y)
        guard index < layouts.count else { return nil }
        let offset = y - blockTops[index]
        let height = layouts[index].height
        if offset < 0 || height <= 0 { return ScrollAnchor(block: index, fraction: 0, offset: min(offset, 0)) }
        if let tableIndex = layouts[index].tables.firstIndex(where: { $0.rect.minY <= offset && offset < $0.rect.maxY }) {
            let table = layouts[index].tables[tableIndex]
            if !table.rows.isEmpty {
                let row = table.row(atY: offset - table.rect.minY)
                return ScrollAnchor(block: index, fraction: 0, offset: offset - table.rect.minY - table.rowTops[row],
                                    table: tableIndex, row: row)
            }
        }
        return ScrollAnchor(block: index, fraction: offset / height, offset: 0)
    }

    func y(for anchor: ScrollAnchor) -> CGFloat {
        guard anchor.block < layouts.count else { return 0 }
        let layout = layouts[anchor.block]
        if anchor.table >= 0, anchor.table < layout.tables.count, anchor.row < layout.tables[anchor.table].rows.count {
            let table = layout.tables[anchor.table]
            return blockTops[anchor.block] + table.rect.minY + table.rowTops[anchor.row] + anchor.offset
        }
        return blockTops[anchor.block] + anchor.offset + anchor.fraction * layout.height
    }
}

struct ScrollAnchor: Equatable {
    var block: Int
    var fraction: CGFloat
    var offset: CGFloat
    /// A table of the block and a row of it that `offset` counts from, or -1.
    var table = -1
    var row = 0
}
