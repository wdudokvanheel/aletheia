import CoreGraphics
import Foundation

/// Where a search match in the source shows in a snapshot: the block to
/// center, and the match's display text there, if it has any.
struct RevealTarget: Equatable {
    var block: Int
    /// The match as displayed, or nil when its source is not shown as is: a
    /// link destination, markup, a list marker, or a match across blocks.
    var selection: Range<TextPosition>?
    /// The display offset in `block` nearest to the match, for centering
    /// when there is no selection.
    var offset: Int
}

extension MarkdownSnapshot {
    /// The display text of the UTF-16 source range `range`, as the WebKit
    /// preview finds it. A match inside a block's displayed text selects
    /// exactly that text, so hidden link destinations and earlier
    /// occurrences cannot shift it. A match that is not displayed as is
    /// (markup, a link destination, a list marker, or a match across
    /// blocks) selects nothing and centers its block. A match outside every
    /// shown block (a link reference definition, raw HTML, blank lines)
    /// centers the next shown block, or the last one. Nil when no block is
    /// shown. A binary search plus work proportional to the block.
    func revealTarget(forSourceRange range: Range<Int>) -> RevealTarget? {
        let blocks = document.blocks
        let location = range.lowerBound
        var low = 0
        var high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if blocks[mid].sourceRange.lowerBound <= location { low = mid + 1 } else { high = mid }
        }
        if low > 0, location < blocks[low - 1].sourceRange.upperBound, !layouts[low - 1].isDropped {
            let index = low - 1
            let selection = displayRange(ofSourceRange: range, inBlock: index)
            return RevealTarget(block: index, selection: selection,
                                offset: selection?.lowerBound.offset ?? nearestOffset(to: location, inBlock: index))
        }
        guard let index = layouts.indices[low...].first(where: { !layouts[$0].isDropped })
            ?? layouts.indices.last(where: { !layouts[$0].isDropped }) else { return nil }
        return RevealTarget(block: index, selection: nil, offset: nearestOffset(to: location, inBlock: index))
    }

    /// The display range in block `index` showing exactly the source text of
    /// `range`, or nil. The source map takes the start and end across; the
    /// start must map back to itself, which offsets inside markup do not,
    /// and the display text must equal the source text, which rules out
    /// markup, entities, and soft breaks inside the range.
    private func displayRange(ofSourceRange range: Range<Int>, inBlock index: Int) -> Range<TextPosition>? {
        let block = document.blocks[index]
        guard !range.isEmpty, range.upperBound <= block.sourceRange.upperBound else { return nil }
        let start = block.displayOffset(forSourceOffset: range.lowerBound)
        let end = block.displayOffset(forSourceOffset: range.upperBound)
        guard start < end, end <= layouts[index].textLength,
              block.sourceOffset(forDisplayOffset: start) == range.lowerBound else { return nil }
        let source = block.sourceText as NSString
        let local = NSRange(location: range.lowerBound - block.sourceRange.lowerBound, length: range.count)
        guard NSMaxRange(local) <= source.length,
              (block.text as NSString).substring(with: NSRange(location: start, length: end - start))
                == source.substring(with: local) else { return nil }
        return TextPosition(block: index, offset: start)..<TextPosition(block: index, offset: end)
    }

    /// The display offset in block `index` that a source offset maps to,
    /// clamped to the block's text: its start for an offset above the block
    /// and its end for one below.
    private func nearestOffset(to location: Int, inBlock index: Int) -> Int {
        min(max(document.blocks[index].displayOffset(forSourceOffset: location), 0), layouts[index].textLength)
    }

    /// The area to center for `target`, in view coordinates: the lines of
    /// its selection, else the line at its offset, else the whole block
    /// (a rule, or a block without text).
    func revealRect(for target: RevealTarget) -> CGRect {
        if let selection = target.selection { return lineBand(selection.lowerBound, selection.upperBound) }
        guard isSelectable(target.block) else {
            return CGRect(x: columnX, y: blockTops[target.block], width: columnWidth,
                          height: layouts[target.block].height)
        }
        let position = TextPosition(block: target.block, offset: target.offset)
        return lineBand(position, position)
    }
}
