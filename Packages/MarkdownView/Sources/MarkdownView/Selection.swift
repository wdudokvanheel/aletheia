import CoreFoundation
import CoreGraphics
import CoreText
import Foundation

/// A caret position: a block index plus a UTF-16 offset in that block's
/// display text, from 0 to its length. Positions order by block, then offset,
/// which is document order. When tables lay out per cell, a cell index will
/// order between the two.
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
        guard !layout.lines.isEmpty else {
            // An estimate that is not laid out yet.
            return point.y < blockTops[index] + layout.height / 2 ? start(of: index) : end(of: index)
        }
        let y = point.y - blockTops[index]
        var lineIndex = min(layout.firstLine(endingBelow: y), layout.lines.count - 1)
        // Between two lines, as between list items or paragraphs in a quote.
        if lineIndex > 0, y < layout.lines[lineIndex].top {
            let above = layout.lines[lineIndex - 1]
            if y - (above.top + above.height) < layout.lines[lineIndex].top - y { lineIndex -= 1 }
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

    /// Whether `point` is over a line of selectable text rather than a margin
    /// or a list marker.
    func isOverText(_ point: CGPoint) -> Bool {
        let index = firstBlock(endingBelow: point.y)
        guard index < layouts.count, blockTops[index] <= point.y, isSelectable(index) else { return false }
        let layout = layouts[index]
        let y = point.y - blockTops[index]
        let lineIndex = layout.firstLine(endingBelow: y)
        guard lineIndex < layout.lines.count, layout.lines[lineIndex].top <= y else { return false }
        let line = layout.lines[lineIndex]
        return point.x >= columnX + line.x && point.x < columnX + line.maxX
    }

    // MARK: Words and paragraphs

    /// The range a click at `position` selects at `granularity`: nothing for
    /// characters, the word under it by system word boundaries, or its
    /// paragraph, which is the block's text between line separators: a whole
    /// paragraph or heading, a list item, a code line, or a table row.
    /// `forward` takes the word before the caret, for drags past the anchor.
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
        if granularity == .word, !range.isEmpty {
            let index = min(max(forward ? offset - 1 : offset, start), contentsEnd - 1)
            range = Self.wordRange(in: text, at: index, within: range)
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
        let composed = text.rangeOfComposedCharacterSequence(at: index)
        return composed.location..<(composed.location + composed.length)
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
        guard !layout.lines.isEmpty else { return CGRect(x: columnX, y: top, width: columnWidth, height: layout.height) }
        let line = layout.lines[layout.lineIndex(containing: position.offset, upstream: upstream)]
        return CGRect(x: columnX, y: top + line.top, width: columnWidth, height: line.height)
    }

    /// Where the text at `position` sits: its baseline origin in view
    /// coordinates and its style, for showing a definition over it.
    func baselineOrigin(of position: TextPosition, codeOffsets: CodeOffsets = [:]) -> (point: CGPoint, style: StyleRun)? {
        guard position.block < layouts.count else { return nil }
        let layout = layouts[position.block]
        guard !layout.lines.isEmpty else { return nil }
        let line = layout.lines[layout.lineIndex(containing: position.offset, upstream: false)]
        let x = CTLineGetOffsetForStringIndex(line.line, position.offset, nil)
            - codeOffset(of: line, inBlock: position.block, codeOffsets)
        return (CGPoint(x: columnX + line.x + x, y: blockTops[position.block] + line.baseline),
                layout.styleRun(at: position.offset))
    }

    // MARK: Links

    /// The destination of the link whose text is under `point`, in view
    /// coordinates: within a line box, between the link's glyph edges.
    func linkDestination(at point: CGPoint) -> String? {
        let index = firstBlock(endingBelow: point.y)
        guard index < layouts.count, blockTops[index] <= point.y else { return nil }
        let layout = layouts[index]
        let links = document.blocks[index].links
        guard !links.isEmpty else { return nil }
        let y = point.y - blockTops[index]
        let lineIndex = layout.firstLine(endingBelow: y)
        guard lineIndex < layout.lines.count, layout.lines[lineIndex].top <= y else { return nil }
        // Code blocks have no links, so scrolling never moves one.
        let x = point.x - columnX - layout.lines[lineIndex].x
        for decoration in layout.lines[lineIndex].decorations where decoration.kind == .underline {
            if decoration.rect.minX <= x, x < decoration.rect.maxX, links.indices.contains(Int(decoration.tag)) {
                return links[Int(decoration.tag)].destination
            }
        }
        return nil
    }

    // MARK: Copy

    /// The plain text of `range` for copying: the selected display text of
    /// each block with text, joined by newlines. Display text never contains
    /// list markers or task boxes; table cells are separated by tabs and rows
    /// by newlines.
    func text(in range: Range<TextPosition>) -> String {
        guard range.lowerBound.block < layouts.count else { return "" }
        var pieces: [String] = []
        for index in range.lowerBound.block...min(range.upperBound.block, layouts.count - 1) where isSelectable(index) {
            let text = document.blocks[index].text as NSString
            let start = index == range.lowerBound.block ? min(range.lowerBound.offset, text.length) : 0
            let end = index == range.upperBound.block ? min(range.upperBound.offset, text.length) : text.length
            pieces.append(start < end ? text.substring(with: NSRange(location: start, length: end - start)) : "")
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
