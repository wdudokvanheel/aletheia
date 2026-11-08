import CoreFoundation
import CoreGraphics
import CoreText
import Foundation

/// A caret position: a block index plus a UTF-16 offset in that block's
/// display text, from 0 to its length. Positions order by block, then offset,
/// which is document order. In a table the offset also names the cell: the
/// display text lists cells in row-major order, separated by tabs within a
/// row and newlines between rows, so the cell index is the one whose range
/// holds the offset and table positions order row-major.
public struct TextPosition: Sendable, Hashable, Comparable {
    public var block: Int
    public var offset: Int

    public init(block: Int, offset: Int) {
        self.block = block
        self.offset = offset
    }

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        lhs.block != rhs.block ? lhs.block < rhs.block : lhs.offset < rhs.offset
    }
}

/// What a click selects and a drag after it extends by: characters, words
/// (double-click), or paragraphs (triple-click).
enum SelectionGranularity {
    case character, word, paragraph
}

extension MarkdownSnapshot {
    /// Whether a block has text to select. Raw HTML, rules, and empty code
    /// blocks do not; hit-testing passes over them.
    func isSelectable(_ block: Int) -> Bool { layouts[block].textLength > 0 }

    func start(of block: Int) -> TextPosition { TextPosition(block: block, offset: 0) }
    func end(of block: Int) -> TextPosition { TextPosition(block: block, offset: layouts[block].textLength) }

    /// All selectable text, or nil when there is none.
    var fullRange: Range<TextPosition>? {
        guard let first = layouts.indices.first(where: isSelectable),
              let last = layouts.indices.last(where: isSelectable) else { return nil }
        return start(of: first)..<end(of: last)
    }

    // MARK: Hit-testing

    /// The caret position nearest to `point`, in view coordinates, with code
    /// blocks scrolled by `codeOffsets`. Points left or right of a line
    /// resolve to its ends, points between lines or blocks to the nearer one,
    /// and points above or below all text to its start or end. Nil when
    /// nothing is selectable.
    func position(at point: CGPoint, codeOffsets: CodeOffsets = [:]) -> TextPosition? {
        let index = firstBlock(endingBelow: point.y)
        if index < layouts.count, blockTops[index] <= point.y, isSelectable(index) {
            return position(inBlock: index, at: point, codeOffsets: codeOffsets)
        }
        let above = layouts.indices[..<index].last(where: isSelectable)
        let below = layouts.indices[index...].first(where: isSelectable)
        switch (above, below) {
        case (nil, nil):
            return nil
        case (let above?, nil):
            return end(of: above)
        case (nil, let below?):
            return start(of: below)
        case (let above?, let below?):
            let gapAbove = point.y - (blockTops[above] + layouts[above].height)
            return gapAbove <= blockTops[below] - point.y ? end(of: above) : start(of: below)
        }
    }

    private func position(inBlock index: Int, at point: CGPoint, codeOffsets: CodeOffsets) -> TextPosition {
        let layout = layouts[index]
        let y = point.y - blockTops[index]
        var lineIndex = layout.lines.isEmpty ? -1 : min(layout.firstLine(endingBelow: y), layout.lines.count - 1)
        // Between two lines, as between list items or paragraphs in a quote.
        if lineIndex > 0, y < layout.lines[lineIndex].top {
            let above = layout.lines[lineIndex - 1]
            if y - (above.top + above.height) < layout.lines[lineIndex].top - y { lineIndex -= 1 }
        }
        // In a table, or nearer to one than to the nearest line.
        if let (table, distance) = nearestTable(inBlock: index, toY: y) {
            let lineDistance = lineIndex < 0 ? .greatestFiniteMagnitude
                : max(layout.lines[lineIndex].top - y, y - layout.lines[lineIndex].top - layout.lines[lineIndex].height, 0)
            if distance == 0 || distance < lineDistance {
                let origin = tableOrigin(table, inBlock: index, codeOffsets)
                return TextPosition(block: index, offset: table.offset(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y)))
            }
        }
        guard lineIndex >= 0 else {
            // An estimate that is not laid out yet.
            return point.y < blockTops[index] + layout.height / 2 ? start(of: index) : end(of: index)
        }
        let line = layout.lines[lineIndex]
        let x = point.x - columnX - line.x + codeOffset(of: line, inBlock: index, codeOffsets)
        return TextPosition(block: index, offset: layout.offset(on: line, atX: x))
    }

    /// How far `line` of block `index` is scrolled left: its code block's offset.
    func codeOffset(of line: LineLayout, inBlock index: Int, _ codeOffsets: CodeOffsets) -> CGFloat {
        guard line.codeBlock >= 0, !codeOffsets.isEmpty else { return 0 }
        return codeOffsets[CodeBlockID(block: index, code: Int(line.codeBlock))] ?? 0
    }

    // MARK: Tables

    /// The table of block `index` nearest to `y` (block coordinates), and
    /// how far `y` is outside it.
    func nearestTable(inBlock index: Int, toY y: CGFloat) -> (table: TableLayout, distance: CGFloat)? {
        var best: (table: TableLayout, distance: CGFloat)?
        for table in layouts[index].tables {
            let distance = max(table.rect.minY - y, y - table.rect.maxY, 0)
            if best.map({ distance < $0.distance }) ?? true { best = (table, distance) }
        }
        return best
    }

    /// The table of block `index` whose box holds `y` (block coordinates).
    func table(inBlock index: Int, atY y: CGFloat) -> TableLayout? {
        layouts[index].tables.first { $0.rect.minY <= y && y < $0.rect.maxY }
    }

    /// The table of block `index` whose cells hold display offset `offset`,
    /// counting the end of its last cell.
    func table(inBlock index: Int, containing offset: Int) -> TableLayout? {
        layouts[index].tables.first {
            let range = $0.structure.displayRange
            return range.lowerBound <= offset && offset <= range.upperBound
        }
    }

    /// The top-left of a table of block `index` in view coordinates, moved
    /// left by how far it is scrolled.
    func tableOrigin(_ table: TableLayout, inBlock index: Int, _ codeOffsets: CodeOffsets) -> CGPoint {
        let offset = codeOffsets.isEmpty ? 0 : codeOffsets[CodeBlockID(block: index, code: table.scrollIndex)] ?? 0
        return CGPoint(x: columnX + table.rect.minX - offset, y: blockTops[index] + table.rect.minY)
    }

    /// Whether `point` is over a line of selectable text rather than a margin
    /// or a list marker.
    func isOverText(_ point: CGPoint, codeOffsets: CodeOffsets = [:]) -> Bool {
        let index = firstBlock(endingBelow: point.y)
        guard index < layouts.count, blockTops[index] <= point.y, isSelectable(index) else { return false }
        let layout = layouts[index]
        let y = point.y - blockTops[index]
        if let table = table(inBlock: index, atY: y) {
            let origin = tableOrigin(table, inBlock: index, codeOffsets)
            return table.line(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y)) != nil
        }
        let lineIndex = layout.firstLine(endingBelow: y)
        guard lineIndex < layout.lines.count, layout.lines[lineIndex].top <= y else { return false }
        let line = layout.lines[lineIndex]
        return point.x >= columnX + line.x && point.x < columnX + line.maxX
    }

    // MARK: Words and paragraphs

    /// The range a click at `position` selects at `granularity`: nothing for
    /// characters, the word under it by system word boundaries, or its
    /// paragraph, which is the block's text between line separators: a whole
    /// paragraph or heading, a list item, or a code line; in a table, the
    /// cell. `forward` takes the word before the caret, for drags past the
    /// anchor.
    func unitRange(at position: TextPosition, granularity: SelectionGranularity,
                   forward: Bool = false) -> Range<TextPosition> {
        guard granularity != .character, position.block < layouts.count, isSelectable(position.block) else {
            return position..<position
        }
        let text = document.blocks[position.block].text as NSString
        let offset = min(max(position.offset, 0), text.length)
        var start = 0
        var contentsEnd = 0
        text.getParagraphStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
        var range = start..<contentsEnd
        if let table = document.blocks[position.block].tables.first(where: {
            $0.displayRange.lowerBound <= offset && offset <= $0.displayRange.upperBound
        }), let cell = table.cell(containing: offset) {
            range = table.cell(cell.row, cell.column)
        }
        if granularity == .word, !range.isEmpty {
            // Within the unit, which in a table is the cell: a cell can hold
            // U+2029, which ends the paragraph Foundation finds.
            let index = min(max(forward ? offset - 1 : offset, range.lowerBound), range.upperBound - 1)
            range = Self.wordRange(in: text, at: index, within: range)
            // An image is a word: its whole alt text.
            if let image = document.blocks[position.block].images.first(where: { $0.range.overlaps(range) }) {
                range = min(range.lowerBound, image.range.lowerBound)..<max(range.upperBound, image.range.upperBound)
            }
        }
        return TextPosition(block: position.block, offset: range.lowerBound)
            ..< TextPosition(block: position.block, offset: range.upperBound)
    }

    /// The word-boundary token holding the character at `index`: a word,
    /// a run of spaces, or a punctuation mark. CJK text splits by dictionary
    /// words, and emoji sequences stay whole.
    private static func wordRange(in text: NSString, at index: Int, within paragraph: Range<Int>) -> Range<Int> {
        let tokenizer = CFStringTokenizerCreate(nil, text, CFRange(location: paragraph.lowerBound, length: paragraph.count),
                                                kCFStringTokenizerUnitWordBoundary, CFLocaleCopyCurrent())
        if CFStringTokenizerGoToTokenAtIndex(tokenizer, index) != [] {
            let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if token.location != kCFNotFound, token.length > 0 { return token.location..<(token.location + token.length) }
        }
        guard index >= 0, index < text.length else { return paragraph }
        let composed = text.rangeOfComposedCharacterSequence(at: index)
        return max(composed.location, paragraph.lowerBound)..<min(composed.location + composed.length, paragraph.upperBound)
    }

    // MARK: Drawing and invalidation

    /// Highlight rectangles for `range` in the blocks that intersect
    /// `minY..<maxY`: one per line at full line height, between the caret
    /// offsets of its ends, and reaching the right edge of the line's text
    /// area on lines the selection continues past. Lines of code blocks
    /// scrolled by `codeOffsets` move with them and are clipped to the box.
    func selectionRects(for range: Range<TextPosition>, minY: CGFloat, maxY: CGFloat,
                        codeOffsets: CodeOffsets = [:]) -> [CGRect] {
        let visible = blockRange(intersecting: minY, maxY)
        let first = max(visible.lowerBound, range.lowerBound.block)
        let last = min(visible.upperBound - 1, range.upperBound.block)
        guard first <= last else { return [] }
        var rects: [CGRect] = []
        for index in first...last {
            let layout = layouts[index]
            let top = blockTops[index]
            let start = index == range.lowerBound.block ? range.lowerBound.offset : 0
            let end = index == range.upperBound.block ? range.upperBound.offset : Int.max
            let continuesToNextBlock = index < range.upperBound.block
            for table in layout.tables where top + table.rect.maxY > minY && top + table.rect.minY < maxY {
                let origin = tableOrigin(table, inBlock: index, codeOffsets)
                let box = table.rect.offsetBy(dx: columnX, dy: top)
                let isScrollable = table.width > table.rect.width
                for rect in table.selectionRects(start, end, minY: minY - origin.y, maxY: maxY - origin.y) {
                    var rect = rect.offsetBy(dx: origin.x, dy: origin.y)
                    if isScrollable { rect = rect.intersection(box) }
                    if !rect.isNull, !rect.isEmpty { rects.append(rect) }
                }
            }
            var lineIndex = layout.firstLine(endingBelow: minY - top)
            while lineIndex < layout.lines.count, top + layout.lines[lineIndex].top < maxY {
                let line = layout.lines[lineIndex]
                lineIndex += 1
                let isLast = lineIndex == layout.lines.count
                let from = max(start, line.range.lowerBound)
                let to = min(end, line.range.upperBound)
                // A selection that starts at the very end of the block still
                // covers the separator to the next one.
                guard from < to || (isLast && continuesToNextBlock && from == line.range.upperBound) else { continue }
                let x1 = CTLineGetOffsetForStringIndex(line.line, from, nil)
                let x2 = CTLineGetOffsetForStringIndex(line.line, to, nil)
                let left = columnX + line.x - codeOffset(of: line, inBlock: index, codeOffsets)
                var minX = left + min(x1, x2)
                var maxX = left + max(x1, x2)
                if end > line.range.upperBound || (isLast && continuesToNextBlock) { maxX = max(maxX, columnX + line.maxX) }
                if line.codeBlock >= 0 {
                    let box = layout.codeBlocks[Int(line.codeBlock)].rect
                    minX = max(minX, columnX + box.minX)
                    maxX = min(maxX, columnX + box.maxX)
                    guard maxX > minX else { continue }
                }
                rects.append(CGRect(x: minX, y: top + line.top, width: maxX - minX, height: line.height))
            }
        }
        return rects
    }

    /// What to redraw when the selection changes from `old` to `new`: the
    /// column-wide band of lines between the ends that moved.
    func selectionDirtyRects(from old: Range<TextPosition>?, to new: Range<TextPosition>?) -> [CGRect] {
        switch (old, new) {
        case (nil, nil):
            return []
        case (let range?, nil), (nil, let range?):
            return [lineBand(range.lowerBound, range.upperBound)]
        case (let old?, let new?):
            if old == new { return [] }
            if old.lowerBound == new.lowerBound {
                return [lineBand(min(old.upperBound, new.upperBound), max(old.upperBound, new.upperBound))]
            }
            if old.upperBound == new.upperBound {
                return [lineBand(min(old.lowerBound, new.lowerBound), max(old.lowerBound, new.lowerBound))]
            }
            return [lineBand(old.lowerBound, old.upperBound), lineBand(new.lowerBound, new.upperBound)]
        }
    }

    /// The column-wide band from the line holding `lower` to the one holding
    /// `upper`. At a soft wrap it includes the line the position ends.
    func lineBand(_ lower: TextPosition, _ upper: TextPosition) -> CGRect {
        lineBox(lower, upstream: true).union(lineBox(upper, upstream: false))
    }

    private func lineBox(_ position: TextPosition, upstream: Bool) -> CGRect {
        guard position.block < layouts.count else { return .null }
        let layout = layouts[position.block]
        let top = blockTops[position.block]
        if let table = table(inBlock: position.block, containing: position.offset), !table.rows.isEmpty,
           let cell = table.structure.cell(containing: position.offset), cell.row < table.rows.count {
            let band = table.rowBand(cell.row)
            return CGRect(x: columnX, y: top + table.rect.minY + band.top, width: columnWidth, height: band.height)
        }
        guard !layout.lines.isEmpty else { return CGRect(x: columnX, y: top, width: columnWidth, height: layout.height) }
        let line = layout.lines[layout.lineIndex(containing: position.offset, upstream: upstream)]
        return CGRect(x: columnX, y: top + line.top, width: columnWidth, height: line.height)
    }

    /// Where the text at `position` sits: its baseline origin in view
    /// coordinates and its style, for showing a definition over it.
    func baselineOrigin(of position: TextPosition, codeOffsets: CodeOffsets = [:]) -> (point: CGPoint, style: StyleRun)? {
        guard position.block < layouts.count else { return nil }
        let layout = layouts[position.block]
        if let table = table(inBlock: position.block, containing: position.offset),
           let caret = table.caretOrigin(of: position.offset) {
            let origin = tableOrigin(table, inBlock: position.block, codeOffsets)
            return (CGPoint(x: origin.x + caret.x, y: origin.y + caret.y), layout.styleRun(at: position.offset))
        }
        guard !layout.lines.isEmpty else { return nil }
        let line = layout.lines[layout.lineIndex(containing: position.offset, upstream: false)]
        let x = CTLineGetOffsetForStringIndex(line.line, position.offset, nil)
            - codeOffset(of: line, inBlock: position.block, codeOffsets)
        return (CGPoint(x: columnX + line.x + x, y: blockTops[position.block] + line.baseline),
                layout.styleRun(at: position.offset))
    }

    // MARK: Links

    /// The destination of the live link whose text is under `point`, in view
    /// coordinates: within a line box, between the link's glyph edges, or
    /// on an image inside the link.
    func linkDestination(at point: CGPoint, codeOffsets: CodeOffsets = [:]) -> String? {
        guard let hit = linkOrImage(at: point, codeOffsets: codeOffsets) else { return nil }
        let block = document.blocks[hit.block]
        guard let link = hit.kind == .underline ? hit.index : enclosingLink(ofImage: hit.index, in: block),
              block.links[link].isLive else { return nil }
        return block.links[link].destination
    }

    /// The title of the live link or the image under `point`, for its
    /// tooltip: an image's own title, else that of the link around it.
    func toolTip(at point: CGPoint, codeOffsets: CodeOffsets = [:]) -> String? {
        guard let hit = linkOrImage(at: point, codeOffsets: codeOffsets) else { return nil }
        let block = document.blocks[hit.block]
        var title = hit.kind == .underline ? block.links[hit.index].title : block.images[hit.index].title
        if title.isEmpty, hit.kind == .image, let link = enclosingLink(ofImage: hit.index, in: block) {
            title = block.links[link].title
        }
        return title.isEmpty ? nil : title
    }

    private func enclosingLink(ofImage image: Int, in block: MarkdownBlock) -> Int? {
        BlockLayout.linkIndex(in: block.links[...], at: block.images[image].range.lowerBound)
    }

    /// The link underline or placed image under `point`, in view
    /// coordinates, with its block and its index in the block's links or
    /// images.
    private func linkOrImage(at point: CGPoint, codeOffsets: CodeOffsets) -> (block: Int, kind: Decoration.Kind, index: Int)? {
        let index = firstBlock(endingBelow: point.y)
        guard index < layouts.count, blockTops[index] <= point.y else { return nil }
        let layout = layouts[index]
        let block = document.blocks[index]
        guard !block.links.isEmpty || !block.images.isEmpty else { return nil }
        let y = point.y - blockTops[index]
        let hit: (Decoration.Kind, Int)?
        if let table = table(inBlock: index, atY: y) {
            let origin = tableOrigin(table, inBlock: index, codeOffsets)
            guard let line = table.line(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y)) else { return nil }
            hit = linkOrImage(on: line.line, atX: point.x - origin.x - line.origin.x, in: block)
        } else {
            let lineIndex = layout.firstLine(endingBelow: y)
            guard lineIndex < layout.lines.count, layout.lines[lineIndex].top <= y else { return nil }
            // Code blocks have no links or images, so scrolling never moves one.
            hit = linkOrImage(on: layout.lines[lineIndex], atX: point.x - columnX - layout.lines[lineIndex].x, in: block)
        }
        return hit.map { (index, $0.0, $0.1) }
    }

    /// The link underline or image under `x` on a line of `block`.
    private func linkOrImage(on line: LineLayout, atX x: CGFloat, in block: MarkdownBlock) -> (Decoration.Kind, Int)? {
        for decoration in line.decorations where decoration.rect.minX <= x && x < decoration.rect.maxX {
            let tag = Int(decoration.tag)
            switch decoration.kind {
            case .underline where block.links.indices.contains(tag): return (.underline, tag)
            case .image where block.images.indices.contains(tag): return (.image, tag)
            default: break
            }
        }
        return nil
    }

    // MARK: Copy

    /// The plain text of `range` for copying: the selected display text of
    /// each block with text, joined by newlines. Display text never contains
    /// list markers or task boxes; table cells are separated by tabs and rows
    /// by newlines. An image copies as its alt text, and one without alt
    /// text as nothing.
    func text(in range: Range<TextPosition>) -> String {
        guard range.lowerBound.block < layouts.count else { return "" }
        var pieces: [String] = []
        for index in range.lowerBound.block...min(range.upperBound.block, layouts.count - 1) where isSelectable(index) {
            let text = document.blocks[index].text as NSString
            let start = index == range.lowerBound.block ? min(range.lowerBound.offset, text.length) : 0
            let end = index == range.upperBound.block ? min(range.upperBound.offset, text.length) : text.length
            var piece = start < end ? text.substring(with: NSRange(location: start, length: end - start)) : ""
            if !document.blocks[index].images.isEmpty { piece = piece.replacingOccurrences(of: "\u{FFFC}", with: "") }
            pieces.append(piece)
        }
        return pieces.joined(separator: "\n")
    }

    // MARK: Across updates

    /// Maps a range from `old`, a snapshot of an earlier source, onto this
    /// one. An unchanged block keeps its offsets even when blocks above it
    /// changed. In an edited block, offsets before and after the edit follow
    /// the text and offsets inside it are clamped. Nil when a selected block
    /// vanished or was replaced, as when another document is shown.
    ///
    /// When `old` is this snapshot's base, the diff answers directly: matched
    /// blocks keep their offsets at their new index, and other positions
    /// follow the source edit through the blocks' source maps. Otherwise
    /// blocks are matched by their source ranges and text.
    func mapRange(_ range: Range<TextPosition>, from old: MarkdownSnapshot) -> Range<TextPosition>? {
        let lower: TextPosition?
        let upper: TextPosition?
        if let update = update(from: old) {
            lower = map(range.lowerBound, from: old, through: update, upstream: false)
            upper = map(range.upperBound, from: old, through: update, upstream: true)
        } else {
            lower = map(range.lowerBound, from: old)
            upper = map(range.upperBound, from: old)
        }
        guard let lower, let upper else { return nil }
        return lower <= upper ? lower..<upper : nil
    }

    /// A position carried through the diff from `old`, the base. A block the
    /// edit replaced entirely is gone. Elsewhere in an edited block, a
    /// position outside the edited span goes through its source map, the
    /// source edit, and the new block's source map, which also follows
    /// blocks that were split or merged. Inside the span, which can cover
    /// unchanged text when edits at several places coalesced, the block is
    /// paired by its place among the changed blocks and the offset follows
    /// the display text, clamped, or is dropped when the text was replaced.
    private func map(_ position: TextPosition, from old: MarkdownSnapshot, through update: BlockUpdate,
                     upstream: Bool) -> TextPosition? {
        let oldBlocks = old.document.blocks
        guard oldBlocks.indices.contains(position.block) else { return nil }
        if let index = update.match?.newIndex(ofOld: position.block) {
            return TextPosition(block: index, offset: min(position.offset, layouts[index].textLength))
        }
        let block = oldBlocks[position.block]
        let edit = update.edit
        if !edit.old.isEmpty, edit.old.lowerBound <= block.sourceRange.lowerBound,
           block.sourceRange.upperBound <= edit.old.upperBound {
            return nil
        }
        let source = block.sourceOffset(forDisplayOffset: position.offset)
        guard source <= edit.old.lowerBound || source >= edit.old.upperBound else {
            let paired = update.match.map { $0.pairedNewIndex(ofOld: position.block) }
                ?? (position.block < layouts.count ? position.block : nil)
            guard let index = paired, isSelectable(index),
                  let offset = Self.mapOffset(position.offset, from: block.text, to: document.blocks[index].text)
            else { return nil }
            return TextPosition(block: index, offset: offset)
        }
        let mapped = edit.map(source, upstream: upstream)
        let index = firstBlock(endingAtOrAfterSource: mapped)
        guard index < layouts.count, document.blocks[index].sourceRange.lowerBound <= mapped,
              isSelectable(index) else { return nil }
        let offset = document.blocks[index].displayOffset(forSourceOffset: mapped)
        return TextPosition(block: index, offset: min(max(offset, 0), layouts[index].textLength))
    }

    private func map(_ position: TextPosition, from old: MarkdownSnapshot) -> TextPosition? {
        let oldBlocks = old.document.blocks
        let blocks = document.blocks
        guard oldBlocks.indices.contains(position.block) else { return nil }
        let index = position.block
        let block = oldBlocks[index]
        // Unchanged, with any edit below it.
        if blocks.indices.contains(index), blocks[index].sourceRange == block.sourceRange,
           blocks[index].sourceText == block.sourceText {
            return position
        }
        // Unchanged, moved by an edit above it.
        let shift = blocks.count - oldBlocks.count
        if blocks.indices.contains(index + shift), blocks[index + shift].sourceRange.count == block.sourceRange.count,
           blocks[index + shift].sourceText == block.sourceText {
            return TextPosition(block: index + shift, offset: position.offset)
        }
        // Edited: a block still starts where it did. When blocks were removed
        // and it is the next block moved up into place, the old one vanished.
        guard blocks.indices.contains(index), blocks[index].sourceRange.lowerBound == block.sourceRange.lowerBound else {
            return nil
        }
        if shift < 0, oldBlocks.indices.contains(index - shift), oldBlocks[index - shift].sourceText == blocks[index].sourceText {
            return nil
        }
        return Self.mapOffset(position.offset, from: block.text, to: blocks[index].text)
            .map { TextPosition(block: index, offset: $0) }
    }

    /// An offset in `old` carried into `new`: kept before the changed span,
    /// shifted after it, and clamped inside it. Nil when the texts share less
    /// than half of the shorter one, so the block was replaced, not edited.
    static func mapOffset(_ offset: Int, from old: String, to new: String) -> Int? {
        let old = Array(old.utf16)
        let new = Array(new.utf16)
        let limit = min(old.count, new.count)
        var prefix = 0
        while prefix < limit, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        guard 2 * (prefix + suffix) >= limit else { return nil }
        var mapped = offset <= prefix ? offset
            : offset >= old.count - suffix ? offset + new.count - old.count
            : min(offset, new.count - suffix)
        mapped = min(max(mapped, 0), new.count)
        // Never split a surrogate pair.
        if mapped > 0, mapped < new.count, UTF16.isTrailSurrogate(new[mapped]) { mapped -= 1 }
        return mapped
    }
}
