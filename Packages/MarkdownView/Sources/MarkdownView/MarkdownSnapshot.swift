import CoreGraphics

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

    /// Positions `layouts` (one per block of `document`) top to bottom,
    /// collapsing adjacent margins as CSS does.
    public init(document: MarkdownDocument, layouts: [BlockLayout], width: CGFloat, typography: Typography,
                generation: UInt64) {
        precondition(layouts.count == document.blocks.count, "one layout per block")
        let column = typography.column(forWidth: width)
        var tops: [CGFloat] = []
        tops.reserveCapacity(layouts.count)
        var y = typography.topInset
        var pendingMargin: CGFloat = 0
        var complete = true
        for layout in layouts {
            complete = complete && layout.isFinal(for: column.width)
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
    }

    /// Lays out every block of `document` for a view `width`, in parallel.
    public static func layOut(_ document: MarkdownDocument, width: CGFloat, typography: Typography = .standard,
                              generation: UInt64 = 0) -> MarkdownSnapshot {
        let columnWidth = typography.column(forWidth: width).width
        let layouts = BlockLayout.layOut(document.blocks, columnWidth: columnWidth, typography: typography) ?? []
        return MarkdownSnapshot(document: document, layouts: layouts, width: width, typography: typography,
                                generation: generation)
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

    func with(generation: UInt64) -> MarkdownSnapshot {
        MarkdownSnapshot(document: document, layouts: layouts, width: width, typography: typography,
                         generation: generation)
    }

    /// A scroll position as a block index plus a fraction of that block's
    /// height, so it survives the block changing height. Above the block's top
    /// (in a margin), it keeps the distance in points instead.
    func anchor(atY y: CGFloat) -> ScrollAnchor? {
        let index = firstBlock(endingBelow: y)
        guard index < layouts.count else { return nil }
        let offset = y - blockTops[index]
        let height = layouts[index].height
        if offset < 0 || height <= 0 { return ScrollAnchor(block: index, fraction: 0, offset: min(offset, 0)) }
        return ScrollAnchor(block: index, fraction: offset / height, offset: 0)
    }

    func y(for anchor: ScrollAnchor) -> CGFloat {
        guard anchor.block < layouts.count else { return 0 }
        return blockTops[anchor.block] + anchor.offset + anchor.fraction * layouts[anchor.block].height
    }
}

struct ScrollAnchor: Equatable {
    var block: Int
    var fraction: CGFloat
    var offset: CGFloat
}
