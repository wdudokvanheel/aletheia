import CoreGraphics
import CoreText
import Dispatch
import Foundation
import Synchronization

/// Which rows of a table block a layout lays out now. The others get
/// estimated heights, from their cells' natural widths, until a later layout
/// fills them in.
enum TableRows: Sendable, Equatable {
    case all
    /// From row `first` down until the laid-out rows are `height` tall.
    case covering(first: Int, height: CGFloat)
}

/// One table row at its columns' widths. Immutable, so layouts of edited or
/// resized tables share the rows that still fit.
///
/// Cell lines are relative to the cell's text: `x` is 0, since alignment is
/// applied where the row is placed; `maxX` is the line's visible width; and
/// tops start at the text's top. Their ranges index the string Core Text
/// shaped them in, a run of rows, where the row's text starts at the cell's
/// `bases` entry.
final class TableRowLayout: @unchecked Sendable {
    /// Each cell's width on one line, without trailing whitespace.
    let naturalWidths: [CGFloat]
    /// The column text widths the row was laid out at.
    let widths: [CGFloat]
    /// Every cell's lines, cell after cell.
    let lines: [LineLayout]
    /// Cell `c`'s lines are `lines[lineStarts[c]..<lineStarts[c + 1]]`.
    let lineStarts: [Int32]
    /// Where the row's text starts in the string of each cell's lines.
    let bases: [Int32]
    let cellHeights: [CGFloat]
    /// The tallest cell: the row's height inside its padding.
    let contentHeight: CGFloat
    /// Cells that must wrap are not laid out yet; their heights are estimated.
    let isEstimate: Bool

    init(naturalWidths: [CGFloat], widths: [CGFloat], lines: [LineLayout], lineStarts: [Int32], bases: [Int32],
         cellHeights: [CGFloat], isEstimate: Bool) {
        self.naturalWidths = naturalWidths
        self.widths = widths
        self.lines = lines
        self.lineStarts = lineStarts
        self.bases = bases
        self.cellHeights = cellHeights
        contentHeight = cellHeights.max() ?? 0
        self.isEstimate = isEstimate
    }

    func lines(ofCell column: Int) -> ArraySlice<LineLayout> {
        lines[Int(lineStarts[column])..<Int(lineStarts[column + 1])]
    }

    /// Whether the cell sits on its natural line, which fits any width at
    /// least as wide.
    func isNatural(_ column: Int) -> Bool { naturalWidths[column] <= widths[column] }

    /// Whether the row stands as it is at column widths `newWidths`: each
    /// cell still fits on its natural line, or wraps at the same width.
    func fits(_ newWidths: [CGFloat]) -> Bool {
        guard !isEstimate, newWidths.count == widths.count else { return false }
        for column in widths.indices {
            let fitsNow = naturalWidths[column] <= newWidths[column]
            guard fitsNow == isNatural(column), fitsNow || newWidths[column] == widths[column] else { return false }
        }
        return true
    }
}

/// A table laid out per cell, positioned in its block. Columns are as wide
/// as their widest cell's natural (unwrapped) width; when that is wider than
/// the space there is, the space is shared in proportion to those widths
/// with a minimum, cells wrap, and a table still too wide scrolls in its box
/// like a code block. Rows are found by binary search on their tops, so
/// only visible rows are drawn.
///
/// Building reuses what an earlier layout (`hint`) has: rows whose source
/// line is unchanged keep their natural widths, and their layout too when
/// the column widths still fit it. Editing a cell then measures and lays out
/// only its row, and a column-width change only re-wraps what it must.
final class TableLayout: @unchecked Sendable {
    /// The box the table shows in, relative to the block's top and the
    /// column's left edge: as wide as the space it has, as tall as the table.
    let rect: CGRect
    /// The left edge of each column's left border, relative to the table's
    /// left edge; the last is the right border.
    let columnEdges: [CGFloat]
    /// Each column's text width.
    let columnWidths: [CGFloat]
    let alignments: [TableAlignment]
    let hasHeader: Bool
    let rows: [TableRowLayout]
    /// The top of each row's top border, relative to the table's top; the
    /// last is the top of the bottom border.
    let rowTops: [CGFloat]
    /// The table's own width, borders included.
    let width: CGFloat
    /// Rows whose heights are estimates.
    let estimatedRows: Int
    /// The table's box in its block's `codeBlocks`.
    let scrollIndex: Int
    /// What the next layout compares its rows with.
    let structure: TableStructure
    let sourceText: String
    let typography: Typography
    /// Rows this layout measured, and rows it built rather than kept from
    /// its hint; for tests.
    let measuredRows: Int
    let builtRows: Int
    /// Whether a cell places an image.
    let drawsImages: Bool

    var isPartial: Bool { estimatedRows > 0 }

    private init(rect: CGRect, columnEdges: [CGFloat], columnWidths: [CGFloat], structure: TableStructure,
                 rows: [TableRowLayout], rowTops: [CGFloat], width: CGFloat, estimatedRows: Int, scrollIndex: Int,
                 sourceText: String, typography: Typography, measuredRows: Int, builtRows: Int, drawsImages: Bool) {
        self.rect = rect
        self.columnEdges = columnEdges
        self.columnWidths = columnWidths
        alignments = structure.alignments
        hasHeader = structure.hasHeader
        self.rows = rows
        self.rowTops = rowTops
        self.width = width
        self.estimatedRows = estimatedRows
        self.scrollIndex = scrollIndex
        self.structure = structure
        self.sourceText = sourceText
        self.typography = typography
        self.measuredRows = measuredRows
        self.builtRows = builtRows
        self.drawsImages = drawsImages
    }

    /// The height of a table whose rows are one line each, for estimates.
    static func estimatedHeight(of structure: TableStructure, typography: Typography) -> CGFloat {
        CGFloat(structure.rowCount) * (typography.lineHeight(.body) + rowChrome(typography)) + typography.tableBorderWidth
    }

    /// A row's border and padding.
    private static func rowChrome(_ typography: Typography) -> CGFloat {
        typography.tableBorderWidth + 2 * typography.tableCellVerticalPadding
    }

    // MARK: Building

    /// Lays out the table at `top` in a box `width` wide at `x`, with the
    /// block's `images` in their cells. Nil when `isCancelled` reports true;
    /// work is checked between chunks of rows.
    static func build(_ structure: TableStructure, block: MarkdownBlock, text: CFString, x: CGFloat, top: CGFloat,
                      width available: CGFloat, scrollIndex: Int, typography: Typography, hint: TableLayout?,
                      rows request: TableRows, images: ImageText? = nil, linesWarm: Bool = true,
                      isCancelled: () -> Bool) -> TableLayout? {
        let rowCount = structure.rowCount
        let columns = structure.columnCount
        var source = RowsSource(structure: structure, block: block, text: text, typography: typography, images: images,
                                linesWarm: linesWarm)
        let kept = hint.map { matchRows(of: $0, to: structure, sourceText: block.sourceText, typography: typography) }
        func keptRow(_ row: Int) -> TableRowLayout? {
            guard let kept, let hint, kept[row] >= 0 else { return nil }
            return hint.rows[Int(kept[row])]
        }

        // Natural widths: kept rows bring theirs, the others are measured,
        // shaped in runs of rows. A run likely laid out now is kept for that.
        let measuredWidths = SharedBuffer<CGFloat>(repeating: 0, count: rowCount * columns)
        let measuredLines = SharedBuffer<PendingLine?>(repeating: nil, count: rowCount * columns)
        let shaped = SharedBuffer<RowsText?>(repeating: nil, count: rowCount)
        let runBases = SharedBuffer<Int32>(repeating: 0, count: rowCount)
        var measure: [Int] = []
        for row in 0..<rowCount {
            if let old = keptRow(row) {
                for column in 0..<columns { measuredWidths[row * columns + column] = old.naturalWidths[column] }
            } else {
                measure.append(row)
            }
        }
        let shapedRows: Range<Int> = switch request {
        case .all: 0..<rowCount
        case .covering(let first, let height):
            // At most as many rows as fit the height on one line each.
            min(max(first, 0), rowCount)
                ..< min(max(first, 0) + Int(max(height, 0) / (typography.lineHeight(.body) + rowChrome(typography))) + 8,
                        rowCount)
        }
        // Only the lines of rows likely shown now are about to be drawn.
        source.warmRows = linesWarm ? shapedRows : 0..<0
        let measureRuns = source.runs(of: measure)
        guard forEachChunk(measureRuns.count, minimum: 1, isCancelled: isCancelled, { range in
            for run in range.map({ measureRuns[$0] }) {
                guard let text = source.text(of: run) else { continue }
                for row in run {
                    runBases[row] = text.base(ofRow: row)
                    for column in 0..<columns {
                        guard let line = text.naturalLine(row, column, typography: typography) else { continue }
                        measuredWidths[row * columns + column] = line.layout.maxX
                        measuredLines[row * columns + column] = line
                    }
                    if shapedRows.contains(row) { shaped[row] = text }
                }
            }
        }) else { return nil }
        let naturalWidths = measuredWidths.array
        let naturalLines = measuredLines.array
        let measuredBases = runBases.array

        var natural = [CGFloat](repeating: 0, count: columns)
        for row in 0..<rowCount {
            for column in 0..<columns { natural[column] = max(natural[column], naturalWidths[row * columns + column]) }
        }
        let border = typography.tableBorderWidth
        let chrome = CGFloat(columns) * (border + 2 * typography.tableCellHorizontalPadding) + border
        let widths = columnWidths(natural: natural.map { $0.rounded(.up) }, available: max(available - chrome, 0),
                                  minimum: typography.tableMinimumColumnWidth)

        // Rows: kept ones that still fit, then the requested ones laid out,
        // then the rest on their natural lines or with estimated heights.
        let laidOut = SharedBuffer<TableRowLayout?>(repeating: nil, count: rowCount)
        var keptCount = 0
        for row in 0..<rowCount {
            if let old = keptRow(row), old.fits(widths) {
                laidOut[row] = old
                keptCount += 1
            }
        }
        let lineHeight = typography.lineHeight(.body)
        /// Lays out a row, with `text` shaping the rows around it when needed.
        func makeRow(_ row: Int, wrap: Bool, text: () -> RowsText?) -> TableRowLayout {
            let old = keptRow(row)
            let base = row * columns
            var lines: [LineLayout] = []
            var starts = [Int32](repeating: 0, count: columns + 1)
            var bases = [Int32](repeating: 0, count: columns)
            var heights = [CGFloat](repeating: 0, count: columns)
            var isEstimate = false
            for column in 0..<columns {
                starts[column] = Int32(lines.count)
                guard !structure.cell(row, column).isEmpty else { continue }
                let first = lines.count
                let width = widths[column]
                if naturalWidths[base + column] <= width {
                    if let line = naturalLines[base + column] {
                        lines.append(line.take())
                        bases[column] = measuredBases[row]
                    } else if let old, old.isNatural(column), !old.lines(ofCell: column).isEmpty {
                        lines.append(contentsOf: old.lines(ofCell: column))
                        bases[column] = old.bases[column]
                    } else if let text = text(), let line = text.naturalLine(row, column, typography: typography) {
                        lines.append(line.take())
                        bases[column] = text.base(ofRow: row)
                    }
                } else if wrap {
                    if let old, !old.isNatural(column), old.widths[column] == width, !old.lines(ofCell: column).isEmpty {
                        lines.append(contentsOf: old.lines(ofCell: column))
                        bases[column] = old.bases[column]
                    } else if let text = text() {
                        lines.append(contentsOf: text.wrappedLines(row, column, width: width, typography: typography))
                        bases[column] = text.base(ofRow: row)
                    }
                } else {
                    isEstimate = true
                    heights[column] = (naturalWidths[base + column] / max(width, 1)).rounded(.up) * lineHeight
                    continue
                }
                if lines.count > first, let last = lines.last { heights[column] = last.top + last.height }
            }
            starts[columns] = Int32(lines.count)
            return TableRowLayout(naturalWidths: old?.naturalWidths ?? Array(naturalWidths[base..<(base + columns)]),
                                  widths: widths, lines: lines, lineStarts: starts, bases: bases, cellHeights: heights,
                                  isEstimate: isEstimate)
        }
        func layOut(_ rows: Range<Int>, wrap: Bool) -> Bool {
            let pending = rows.filter { laidOut[$0].map { wrap && $0.isEstimate } ?? true }
            let runs = source.runs(of: pending)
            return forEachChunk(runs.count, minimum: 1, isCancelled: isCancelled) { range in
                for run in range.map({ runs[$0] }) {
                    // One string for the run, shaped only if a row needs it.
                    var text: RowsText??
                    for row in run {
                        laidOut[row] = makeRow(row, wrap: wrap) {
                            if let shaped = shaped[row] { return shaped }
                            if text == nil { text = .some(source.text(of: run)) }
                            return text ?? nil
                        }
                    }
                }
            }
        }
        let rowChrome = rowChrome(typography)
        switch request {
        case .all:
            guard layOut(0..<rowCount, wrap: true) else { return nil }
        case .covering(let first, let height):
            func estimatedHeight(ofRow row: Int) -> CGFloat {
                var tallest: CGFloat = 0
                for column in 0..<columns where !structure.cell(row, column).isEmpty {
                    let natural = naturalWidths[row * columns + column]
                    tallest = max(tallest, max((natural / max(widths[column], 1)).rounded(.up), 1) * lineHeight)
                }
                return tallest + rowChrome
            }
            // Estimates pick how many rows reach the height; repeat until laid-out rows do.
            var next = min(max(first, 0), rowCount)
            var covered: CGFloat = 0
            while next < rowCount, covered < height {
                var end = next
                var estimate: CGFloat = 0
                while end < rowCount, covered + estimate < height {
                    estimate += estimatedHeight(ofRow: end)
                    end += 1
                }
                end = min(end + 4, rowCount)
                guard layOut(next..<end, wrap: true) else { return nil }
                for row in next..<end { covered += (laidOut[row]?.contentHeight ?? 0) + rowChrome }
                next = end
            }
            guard layOut(0..<rowCount, wrap: false) else { return nil }
        }

        var rows: [TableRowLayout] = []
        rows.reserveCapacity(rowCount)
        var rowTops: [CGFloat] = []
        rowTops.reserveCapacity(rowCount + 1)
        var y: CGFloat = 0
        var estimated = 0
        for row in 0..<rowCount {
            guard let layout = laidOut[row] else { return nil }
            rows.append(layout)
            rowTops.append(y)
            y += rowChrome + layout.contentHeight
            if layout.isEstimate { estimated += 1 }
        }
        rowTops.append(y)
        var edges: [CGFloat] = []
        edges.reserveCapacity(columns + 1)
        var edge: CGFloat = 0
        for width in widths {
            edges.append(edge)
            edge += border + 2 * typography.tableCellHorizontalPadding + width
        }
        edges.append(edge)
        let drawsImages = images?.hasLoaded == true
            && rows.contains { $0.lines.contains { $0.decorations.contains { $0.kind == .image } } }
        return TableLayout(rect: CGRect(x: x, y: top, width: available, height: y + border), columnEdges: edges,
                           columnWidths: widths, structure: structure, rows: rows, rowTops: rowTops, width: edge + border,
                           estimatedRows: estimated, scrollIndex: scrollIndex, sourceText: block.sourceText,
                           typography: typography, measuredRows: measure.count, builtRows: rowCount - keptCount,
                           drawsImages: drawsImages)
    }

    /// Column text widths: the natural widths when they fit `available`;
    /// otherwise shares of it in proportion to the natural widths, in whole
    /// points. A column no wider than an equal share keeps its natural
    /// width, so only wide columns wrap, and none gets narrower than
    /// `minimum`. When even that does not fit, the table scrolls anyway, so
    /// each column keeps its natural width up to half of `available`, and
    /// at least three times `minimum`.
    static func columnWidths(natural: [CGFloat], available: CGFloat, minimum: CGFloat) -> [CGFloat] {
        guard natural.reduce(0, +) > available, !natural.isEmpty else { return natural }
        let share = available / CGFloat(natural.count)
        let minimums = natural.map { $0 <= share ? $0 : min($0, minimum) }
        guard minimums.reduce(0, +) < available else {
            let cap = max(3 * minimum, (available / 2).rounded(.down))
            return natural.map { min($0, cap) }
        }
        var fixed = [Bool](repeating: false, count: natural.count)
        var widths = natural
        while true {
            var fixedWidth: CGFloat = 0
            var flexible: CGFloat = 0
            for index in natural.indices {
                if fixed[index] { fixedWidth += minimums[index] } else { flexible += natural[index] }
            }
            let share = flexible > 0 ? (available - fixedWidth) / flexible : 0
            var changed = false
            for index in natural.indices where !fixed[index] {
                widths[index] = natural[index] * share
                if widths[index] < minimums[index] {
                    fixed[index] = true
                    changed = true
                }
            }
            if !changed { break }
        }
        return natural.indices.map { fixed[$0] ? minimums[$0] : max(widths[$0].rounded(.down), minimums[$0]) }
    }

    /// For each row of `structure`, the row of `hint` with the same source
    /// line, or -1: the runs of equal rows at the start and the end, which
    /// cover everything but the edited rows. Rows only match within tables
    /// of the same shape, typography, and quoting.
    static func matchRows(of hint: TableLayout, to structure: TableStructure, sourceText: String,
                          typography: Typography) -> [Int32] {
        let count = structure.rowCount
        var kept = [Int32](repeating: -1, count: count)
        let old = hint.structure
        guard hint.typography === typography, old.columnCount == structure.columnCount,
              old.hasHeader == structure.hasHeader, old.isQuoted == structure.isQuoted,
              hint.rows.count == old.rowCount else { return kept }
        var oldText = hint.sourceText
        var newText = sourceText
        oldText.withUTF8 { oldBytes in
            newText.withUTF8 { newBytes in
                func equal(_ oldRow: Int, _ newRow: Int) -> Bool {
                    guard !structure.hasHeader || (oldRow == 0) == (newRow == 0) else { return false }
                    let a = old.rowLines[oldRow]
                    let b = structure.rowLines[newRow]
                    guard a.count == b.count else { return false }
                    guard a.count > 0, let left = oldBytes.baseAddress, let right = newBytes.baseAddress else { return true }
                    return memcmp(left + Int(a.lowerBound), right + Int(b.lowerBound), a.count) == 0
                }
                let oldCount = old.rowCount
                let limit = min(oldCount, count)
                var prefix = 0
                while prefix < limit, equal(prefix, prefix) {
                    kept[prefix] = Int32(prefix)
                    prefix += 1
                }
                var suffix = 0
                while suffix < limit - prefix, equal(oldCount - 1 - suffix, count - 1 - suffix) {
                    kept[count - 1 - suffix] = Int32(oldCount - 1 - suffix)
                    suffix += 1
                }
            }
        }
        return kept
    }

    /// Runs `body` over chunks of `0..<count`, in parallel when there are
    /// several. False when `isCancelled` reported true, which it then keeps
    /// reporting.
    private static func forEachChunk(_ count: Int, minimum: Int, isCancelled: () -> Bool,
                                     _ body: (Range<Int>) -> Void) -> Bool {
        guard count > 0 else { return !isCancelled() }
        let size = max(minimum, count / (ProcessInfo.processInfo.activeProcessorCount * 4) + 1)
        let chunks = (count + size - 1) / size
        if chunks == 1 {
            guard !isCancelled() else { return false }
            body(0..<count)
        } else {
            // The work only reads shared immutable state and writes disjoint
            // slots, and `concurrentPerform` returns when all of it is done.
            withoutActuallyEscaping(isCancelled) { isCancelled in
                withoutActuallyEscaping(body) { body in
                    let work = Unchecked(value: (isCancelled, body))
                    DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                        guard !work.value.0() else { return }
                        work.value.1((chunk * size)..<min((chunk + 1) * size, count))
                    }
                }
            }
        }
        return !isCancelled()
    }

    // MARK: Geometry

    /// The row at `y`, relative to the table's top, clamped to the rows.
    func row(atY y: CGFloat) -> Int {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rowTops[mid] <= y { low = mid + 1 } else { high = mid }
        }
        return min(max(low - 1, 0), max(rows.count - 1, 0))
    }

    /// The column at `x`, relative to the table's left edge, clamped.
    func column(atX x: CGFloat) -> Int {
        var low = 0
        var high = columnWidths.count
        while low < high {
            let mid = (low + high) / 2
            if columnEdges[mid] <= x { low = mid + 1 } else { high = mid }
        }
        return min(max(low - 1, 0), max(columnWidths.count - 1, 0))
    }

    /// The rows that intersect `minY..<maxY`, relative to the table's top.
    func rows(intersecting minY: CGFloat, _ maxY: CGFloat) -> Range<Int> {
        guard !rows.isEmpty, maxY > 0, minY < rowTops[rows.count] + typography.tableBorderWidth else { return 0..<0 }
        let first = row(atY: minY)
        var last = first
        while last < rows.count, rowTops[last] < maxY { last += 1 }
        return first..<max(last, first + 1)
    }

    /// Where a cell's text starts, relative to the table's top-left: inside
    /// the border and padding, and centered vertically in its row.
    func textOrigin(row: Int, column: Int) -> CGPoint {
        let layout = rows[row]
        let border = typography.tableBorderWidth
        return CGPoint(x: columnEdges[column] + border + typography.tableCellHorizontalPadding,
                       y: rowTops[row] + border + typography.tableCellVerticalPadding
                        + (layout.contentHeight - layout.cellHeights[column]) / 2)
    }

    /// How far a cell's line sits right of the cell's text origin. Header
    /// cells of unaligned columns are centered, as WebKit shows `th`.
    func alignmentOffset(of line: LineLayout, row: Int, column: Int) -> CGFloat {
        var alignment = alignments[column]
        if alignment == .none, hasHeader, row == 0 { alignment = .center }
        // A right-to-left cell starts on the right, as `text-align: start` does.
        if alignment == .none, line.isRightToLeft { alignment = .right }
        let room = max(columnWidths[column] - line.maxX, 0)
        switch alignment {
        case .center: return (room / 2).rounded()
        case .right: return room
        case .none, .left: return 0
        }
    }

    /// The row's box from its top border to the next row's, relative to the
    /// table's top.
    func rowBand(_ row: Int) -> (top: CGFloat, height: CGFloat) {
        (rowTops[row], rowTops[row + 1] - rowTops[row] + typography.tableBorderWidth)
    }

    // MARK: Hit-testing and selection

    /// The display offset where a row's text starts.
    func textStart(ofRow row: Int) -> Int { structure.cell(row, 0).lowerBound }

    /// The display offset of string index 0 of a cell's lines, which index
    /// the string they were shaped in.
    func textOffset(row: Int, column: Int) -> Int { textStart(ofRow: row) - Int(rows[row].bases[column]) }

    /// The display offset in the block nearest to `point`, relative to the
    /// table's top-left with its scrolling applied: in the cell under it, on
    /// the nearest of its lines. A cell without lines yields its start.
    func offset(at point: CGPoint) -> Int {
        guard !rows.isEmpty else { return structure.displayRange.lowerBound }
        let row = row(atY: point.y)
        let column = column(atX: point.x)
        let cell = structure.cell(row, column)
        let lines = rows[row].lines(ofCell: column)
        guard !lines.isEmpty else { return cell.lowerBound }
        let origin = textOrigin(row: row, column: column)
        var index = lines.startIndex
        while index + 1 < lines.endIndex, origin.y + lines[index].top + lines[index].height <= point.y { index += 1 }
        let line = lines[index]
        let x = point.x - origin.x - alignmentOffset(of: line, row: row, column: column)
        let local = line.offset(atX: x).map { min(max($0, line.range.lowerBound), line.caretEnd) } ?? line.range.lowerBound
        return textOffset(row: row, column: column) + local
    }

    /// The line of text under `point` (as for `offset(at:)`), with where it
    /// starts, if the point is over it.
    func line(at point: CGPoint) -> (line: LineLayout, origin: CGPoint)? {
        guard !rows.isEmpty, point.y >= 0, point.y < rowTops[rows.count] else { return nil }
        let row = row(atY: point.y)
        let column = column(atX: point.x)
        let origin = textOrigin(row: row, column: column)
        for line in rows[row].lines(ofCell: column) {
            let x = origin.x + alignmentOffset(of: line, row: row, column: column)
            let y = origin.y + line.top
            if point.y >= y, point.y < y + line.height, point.x >= x, point.x < x + line.maxX {
                return (line, CGPoint(x: x, y: origin.y))
            }
        }
        return nil
    }

    /// The baseline origin of the caret at display offset `offset`,
    /// relative to the table's top-left, unscrolled.
    func caretOrigin(of offset: Int) -> CGPoint? {
        guard let (row, column) = structure.cell(containing: offset), row < rows.count else { return nil }
        let local = offset - textOffset(row: row, column: column)
        let lines = rows[row].lines(ofCell: column)
        guard let line = lines.last(where: { $0.range.lowerBound <= local }) ?? lines.first else { return nil }
        let origin = textOrigin(row: row, column: column)
        return CGPoint(x: origin.x + alignmentOffset(of: line, row: row, column: column) + line.caretX(local),
                       y: origin.y + line.baseline)
    }

    /// Highlight rectangles for display offsets `lower..<upper` of the block
    /// in the rows that intersect `minY..<maxY`, all relative to the table's
    /// top-left, unscrolled: per cell, one per selected line, reaching the
    /// column's right edge on lines the selection continues past.
    func selectionRects(_ lower: Int, _ upper: Int, minY: CGFloat, maxY: CGFloat) -> [CGRect] {
        var rects: [CGRect] = []
        let columns = structure.columnCount
        for row in rows(intersecting: minY, maxY) {
            for column in 0..<columns {
                let cell = structure.cell(row, column)
                guard cell.lowerBound < upper, cell.upperBound > lower else { continue }
                let start = textOffset(row: row, column: column)
                let from = max(lower, cell.lowerBound) - start
                let to = min(upper, cell.upperBound) - start
                let continues = upper > cell.upperBound
                let origin = textOrigin(row: row, column: column)
                for line in rows[row].lines(ofCell: column) {
                    let start = max(from, line.range.lowerBound)
                    let end = min(to, line.range.upperBound)
                    guard start < end else { continue }
                    let x = origin.x + alignmentOffset(of: line, row: row, column: column)
                    var spans = line.highlightSpans(start, end)
                    if end == line.range.upperBound, to > line.range.upperBound || continues {
                        // On to the cell's edge after the line's end.
                        let edge = line.continuationX
                        if line.isRightToLeft {
                            spans.append((origin.x - x, edge))
                        } else {
                            spans.append((edge, origin.x + columnWidths[column] - x))
                        }
                    }
                    for span in LineLayout.merged(spans) where span.maxX > span.minX {
                        rects.append(CGRect(x: x + span.minX, y: origin.y + line.top, width: span.maxX - span.minX,
                                            height: line.height))
                    }
                }
            }
        }
        return rects
    }

    // MARK: Drawing

    /// Calls `body` with each line of the visible rows that intersects
    /// `clip`, the x where it starts, the y its tops count from, and the
    /// display offset of its string's start, with the table's top-left at
    /// `origin` (view coordinates, scrolled). Rows still estimated draw no
    /// text.
    func forEachLine(intersecting clip: CGRect, origin: CGPoint,
                     _ body: (LineLayout, _ x: CGFloat, _ top: CGFloat, _ textOffset: Int) -> Void) {
        for row in rows(intersecting: clip.minY - origin.y, clip.maxY - origin.y) where !rows[row].isEstimate {
            for column in columnWidths.indices {
                let left = origin.x + columnEdges[column]
                guard left < clip.maxX, origin.x + columnEdges[column + 1] > clip.minX else { continue }
                let text = textOrigin(row: row, column: column)
                let start = textOffset(row: row, column: column)
                for line in rows[row].lines(ofCell: column) {
                    let top = origin.y + text.y
                    guard top + line.top < clip.maxY, top + line.top + line.height > clip.minY else { continue }
                    body(line, origin.x + text.x + alignmentOffset(of: line, row: row, column: column), top, start)
                }
            }
        }
    }

    /// The borders of the visible rows, snapped to device pixels and filled
    /// one by one: filled together, or off the pixel grid, thin rectangles
    /// are rasterized through a coverage mask as large as all of them.
    func drawBorders(in context: CGContext, origin: CGPoint, clip: CGRect, color: CGColor) {
        let visible = rows(intersecting: clip.minY - origin.y, clip.maxY - origin.y)
        guard !visible.isEmpty else { return }
        let border = typography.tableBorderWidth
        var rects: [CGRect] = []
        rects.reserveCapacity(visible.count + columnEdges.count + 1)
        for row in visible.lowerBound...visible.upperBound {
            rects.append(CGRect(x: origin.x, y: origin.y + rowTops[row], width: width, height: border))
        }
        let top = origin.y + rowTops[visible.lowerBound]
        let height = rowTops[visible.upperBound] - rowTops[visible.lowerBound] + border
        for edge in columnEdges {
            rects.append(CGRect(x: origin.x + edge, y: top, width: border, height: height))
        }
        context.setFillColor(color)
        let device = context.userSpaceToDeviceSpaceTransform
        let user = device.inverted()
        for rect in rects {
            let pixels = rect.applying(device)
            context.fill(CGRect(x: pixels.minX.rounded(), y: pixels.minY.rounded(), width: max(pixels.width.rounded(), 1),
                                height: max(pixels.height.rounded(), 1)).applying(user))
        }
    }
}

/// Cuts runs of rows' text from the block's display text.
private struct RowsSource {
    let structure: TableStructure
    let block: MarkdownBlock
    let text: CFString
    let typography: Typography
    let images: ImageText?
    let linesWarm: Bool
    /// The rows whose lines are about to be drawn, rather than laid out ahead.
    var warmRows = 0..<0
    /// Tables this long keep no lines laid out ahead: measuring lays out
    /// every cell, and keeping each line until its row is built would hold
    /// the shaping of the whole table at once.
    static let largeLength = 131_072

    /// About this many UTF-16 units of rows go into one string: enough to
    /// save most of the cost of a typesetter per row, and few enough to
    /// shape runs in parallel and to typeset one again within a frame.
    static let runLength = 4_000

    /// `rows` (ascending) split into runs of consecutive rows about
    /// `runLength` long.
    func runs(of rows: [Int]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start = -1
        var previous = -2
        var length = 0
        for row in rows {
            if start >= 0, row != previous + 1 || length >= Self.runLength {
                runs.append(start..<(previous + 1))
                start = -1
                length = 0
            }
            if start < 0 { start = row }
            length += structure.cell(row, structure.columnCount - 1).upperBound - structure.cell(row, 0).lowerBound + 1
            previous = row
        }
        if start >= 0 { runs.append(start..<(previous + 1)) }
        return runs
    }

    func text(of rows: Range<Int>) -> RowsText? {
        let isWarm = rows.overlaps(warmRows)
        return RowsText(rows: rows, structure: structure, block: block, text: text, typography: typography,
                        images: images, isWarm: isWarm,
                        keepsLines: isWarm || structure.displayRange.count < Self.largeLength)
    }
}

/// A cell's line on one line, laid out but not yet in its set: measuring
/// lays out every cell on one line, and a cell that wraps never uses it.
private struct PendingLine {
    let layout: LineLayout
    let line: CTLine?
    let location: CFRange

    /// The line, added to its set.
    func take() -> LineLayout { layout.indexed(layout.lineSet.append(line, range: location)) }

    /// The same without its Core Text line, for a set that does not keep it.
    var unkept: PendingLine { PendingLine(layout: layout, line: nil, location: location) }
}

/// The text of a run of rows, from the first row's first cell to the last
/// row's last cell, with its style runs and links, for one typesetter. Header
/// cells are bold, and nothing is kerned. Each cell is typeset as its own
/// paragraph, so its direction is that of its first strong character. Cell
/// lines come from ranges of it.
private final class RowsText: @unchecked Sendable {
    let structure: TableStructure
    /// The display offset of the string's start.
    let start: Int
    let plain: CFString
    /// The text as typeset, with loaded images replaced and cells separated
    /// by paragraph separators.
    let typeset: CFString
    let runs: [StyleRun]
    let links: [MarkdownLink]
    /// The index in the block's links of the first link here.
    let linkOffset: Int
    let typesetter: CTTypesetter
    /// The images in the string, relative to its start.
    let images: ImageText?
    /// Where cells end within a row, and the cells that read right to left,
    /// relative to the string.
    private let separators: [Int32]
    private let directions: [ParagraphDirection]
    let set: LineSet
    private let isWarm: Bool
    /// Whether lines laid out now keep their Core Text lines; see
    /// `RowsSource.largeLength`.
    private let keepsLines: Bool
    private let typography: Typography

    init?(rows: Range<Int>, structure: TableStructure, block: MarkdownBlock, text: CFString, typography: Typography,
          images blockImages: ImageText?, isWarm: Bool, keepsLines: Bool) {
        let columns = structure.columnCount
        let start = structure.cell(rows.lowerBound, 0).lowerBound
        let end = structure.cell(rows.upperBound - 1, columns - 1).upperBound
        guard end > start, let plain = CFStringCreateWithSubstring(nil, text, CFRange(location: start, length: end - start))
        else { return nil }
        // The header row's runs end where it does, to be made bold.
        let headerEnd = structure.hasHeader && rows.lowerBound == 0 ? structure.cell(0, columns - 1).upperBound : start
        var runs: [StyleRun] = []
        let blockRuns = block.styleRuns
        var index = BlockLayout.styleRunIndex(in: blockRuns, at: start)
        while index < blockRuns.count, blockRuns[index].range.lowerBound < end {
            let run = blockRuns[index]
            let lower = max(run.range.lowerBound, start)
            let upper = min(run.range.upperBound, end)
            let split = min(max(headerEnd, lower), upper)
            for piece in [lower..<split, split..<upper] where !piece.isEmpty {
                let styles = piece.lowerBound < headerEnd ? run.styles.union(.strong) : run.styles
                runs.append(StyleRun(range: (piece.lowerBound - start)..<(piece.upperBound - start), role: run.role,
                                     styles: styles))
            }
            index += 1
        }
        let first = BlockLayout.firstLink(in: block.links[...], endingAfter: start)
        var links: [MarkdownLink] = []
        var next = first
        while next < block.links.count, block.links[next].range.lowerBound < end {
            let link = block.links[next]
            let lower = max(link.range.lowerBound, start) - start
            links.append(MarkdownLink(range: lower..<max(min(link.range.upperBound, end) - start, lower),
                                      destination: link.destination))
            next += 1
        }
        var separators: [Int32] = []
        var directions: [ParagraphDirection] = []
        let hasRightToLeft = TextDirection.scan(plain, 0..<(end - start)).hasRightToLeft
        for row in rows {
            for column in 0..<columns {
                let cell = structure.cell(row, column)
                let local = (cell.lowerBound - start)..<(cell.upperBound - start)
                if column + 1 < columns { separators.append(Int32(local.upperBound)) }
                if hasRightToLeft, !local.isEmpty, TextDirection.scan(plain, local).isRightToLeft {
                    directions.append(ParagraphDirection(range: local.lowerBound..<min(local.upperBound + 1, end - start),
                                                         isRightToLeft: true))
                }
            }
        }
        let images = blockImages.map { $0.slice(start..<end) }
        guard let (string, typesetter) = Self.typeset(plain, runs: runs, images: images, separators: separators,
                                                      directions: directions, typography: typography) else { return nil }
        self.images = images
        self.structure = structure
        self.start = start
        self.plain = plain
        typeset = CFAttributedStringGetString(string)
        self.runs = runs
        self.links = links
        linkOffset = first
        self.typesetter = typesetter
        self.separators = separators
        self.directions = directions
        self.isWarm = isWarm
        self.keepsLines = keepsLines
        self.typography = typography
        set = LineSet(length: end - start, isWarm: isWarm) { [runs, separators, directions] in
            Self.typeset(plain, runs: runs, images: images, separators: separators, directions: directions,
                         typography: typography)?.typesetter
        }
    }

    /// `plain` with `runs`, `images`, and paragraph separators in place of
    /// the tabs at `separators`, and its typesetter: shaped in full however
    /// long, as a short string is, since past about 10,000 characters Core
    /// Text otherwise shapes line by line and ignores kerning attributes,
    /// which pad inline code.
    private static func typeset(_ plain: CFString, runs: [StyleRun], images: ImageText?, separators: [Int32],
                                directions: [ParagraphDirection], typography: Typography)
        -> (string: CFAttributedString, typesetter: CTTypesetter)? {
        let length = CFStringGetLength(plain)
        var units = [UniChar](repeating: 0, count: length)
        CFStringGetCharacters(plain, CFRange(location: 0, length: length), &units)
        for separator in separators where Int(separator) < length && units[Int(separator)] == 0x09 {
            units[Int(separator)] = 0x2029
        }
        guard let separated = CFStringCreateWithCharacters(nil, units, length),
              let string = BlockLayout.makeString(separated, runs: runs, typography: typography, kerned: false,
                                                  images: images, directions: directions) else { return nil }
        let options = [kCTTypesetterOptionAllowUnboundedLayout: kCFBooleanTrue!] as CFDictionary
        let typesetter = CTTypesetterCreateWithAttributedStringAndOptions(string, options)
            ?? CTTypesetterCreateWithAttributedString(string)
        return (string, typesetter)
    }

    /// Where a row's text starts in the string.
    func base(ofRow row: Int) -> Int32 { Int32(clamping: structure.cell(row, 0).lowerBound - start) }

    private func cell(_ row: Int, _ column: Int) -> Range<Int> {
        let cell = structure.cell(row, column)
        return (cell.lowerBound - start)..<(cell.upperBound - start)
    }

    private func isRightToLeft(_ range: Range<Int>) -> Bool {
        directions.contains { $0.range.lowerBound == range.lowerBound }
    }

    /// A line for `range` of a cell, not yet added to `set`.
    private func pendingLine(_ range: Range<Int>, top: CGFloat, typography: Typography, cell: Range<Int>,
                             shaped: (typesetter: CTTypesetter, typeset: CFString, set: LineSet)? = nil) -> PendingLine {
        let location = CFRange(location: range.lowerBound, length: range.count)
        let line = CTTypesetterCreateLine(shaped?.typesetter ?? typesetter, location)
        var runIndex = BlockLayout.styleRunIndex(in: runs, at: range.lowerBound)
        let layout = BlockLayout.lineLayout(line, in: shaped?.set ?? set, index: -1, range: range,
                                            string: shaped?.typeset ?? typeset, runs: runs, runIndex: &runIndex,
                                            links: links[...], linkOffset: linkOffset, x: 0, maxX: nil, top: top,
                                            codeBlock: -1, typography: typography,
                                            hasImages: images?.items.isEmpty == false,
                                            isRightToLeft: !directions.isEmpty && isRightToLeft(cell)).layout
        let pending = PendingLine(layout: layout, line: line, location: location)
        return keepsLines && (shaped?.set ?? set).isKept ? pending : pending.unkept
    }

    /// A cell on one line, however wide, not yet added to the set; nil for
    /// an empty cell.
    func naturalLine(_ row: Int, _ column: Int, typography: Typography) -> PendingLine? {
        let range = cell(row, column)
        return range.isEmpty ? nil : pendingLine(range, top: 0, typography: typography, cell: range)
    }

    /// A cell wrapped at `width`, one line box per line. Breaks found in
    /// the string stop at the cell's end.
    func wrappedLines(_ row: Int, _ column: Int, width: CGFloat, typography: Typography) -> [LineLayout] {
        let cell = cell(row, column)
        var lines: [LineLayout] = []
        var start = cell.lowerBound
        var top: CGFloat = 0
        // Images wider than the column shrink to it, as `max-width: 100%`
        // fits them to their cell: the run is shaped again for this cell,
        // and its lines go into a set of their own.
        var shaped: (typesetter: CTTypesetter, typeset: CFString, set: LineSet)?
        if let fitted = images?.fitting(cell, to: width) {
            let make = { [plain, runs, separators, directions] in
                Self.typeset(plain, runs: runs, images: fitted, separators: separators, directions: directions,
                             typography: typography)
            }
            if let made = make() {
                let set = LineSet(length: CFStringGetLength(plain), isWarm: isWarm) { make()?.typesetter }
                shaped = (made.typesetter, CFAttributedStringGetString(made.string), set)
            }
        }
        while start < cell.upperBound {
            let count = max(CTTypesetterSuggestLineBreak(shaped?.typesetter ?? typesetter, start, Double(width)), 1)
            let end = images.map { $0.lineEnd(start + count) } ?? start + count
            let line = pendingLine(start..<min(end, cell.upperBound), top: top, typography: typography, cell: cell,
                                   shaped: shaped).take()
            lines.append(line)
            top += line.height
            start = line.range.upperBound
        }
        return lines
    }
}

/// Closures handed to `concurrentPerform`, which runs them before returning.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// Write-once slots filled concurrently, each index by one worker.
private final class SharedBuffer<Element>: @unchecked Sendable {
    private let slots: UnsafeMutableBufferPointer<Element>

    init(repeating value: Element, count: Int) {
        slots = .allocate(capacity: count)
        slots.initialize(repeating: value)
    }

    deinit {
        slots.deinitialize()
        slots.deallocate()
    }

    subscript(index: Int) -> Element {
        get { slots[index] }
        set { slots[index] = newValue }
    }

    var array: [Element] { Array(slots) }
}
