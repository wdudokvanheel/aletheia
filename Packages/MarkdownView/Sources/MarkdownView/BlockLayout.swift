import CoreGraphics
import CoreText
import Foundation

/// One laid-out line, positioned relative to its block's top and the text
/// column's left edge.
struct LineLayout {
    let line: CTLine
    /// The line's UTF-16 range in the block's display text.
    let range: Range<Int>
    /// Where the text starts: the indent of its lists and quotes, plus a code
    /// block's padding. A scrolled code block moves its lines left of this.
    let x: CGFloat
    /// The right edge of the line's text area, which a selection continuing
    /// past the line reaches.
    let maxX: CGFloat
    let top: CGFloat
    let height: CGFloat
    let baseline: CGFloat
    /// The `ColorIndex` of the whole line, or `nil` when colors are mixed and
    /// runs are colored one by one.
    let color: UInt8?
    /// Whether the line ends with a `\n` from a hard break or block separator.
    let endsWithNewline: Bool
    /// The line's code block in `BlockLayout.codeBlocks`, or -1.
    let codeBlock: Int32
    /// Inline code backgrounds, link underlines, and strikethroughs, in run order.
    let decorations: [Decoration]

    /// The last caret offset on the line: before its newline, if it has one.
    var caretEnd: Int { endsWithNewline ? range.upperBound - 1 : range.upperBound }
}

/// A rectangle drawn with a line's text. x is relative to the line's `x` and
/// y to the block's top, like the line itself.
struct Decoration {
    enum Kind: UInt8 {
        case codeBackground, underline, strikethrough
    }

    static let styles: InlineStyle = [.code, .link, .strikethrough]

    let kind: Kind
    var rect: CGRect
    /// The `ColorIndex` of an underline or strikethrough.
    let color: UInt8
    /// For an underline, the link's index in the block's links; for a code
    /// background, its style run's index.
    let tag: Int32
}

/// A rectangle drawn behind a block's text, relative to the block's top and
/// the column's left edge: a code block's background, a quote's bar, or a
/// thematic break.
struct BlockBox {
    enum Kind: UInt8 {
        case codeBackground, quoteBar, rule
    }

    let kind: Kind
    let rect: CGRect
}

/// A list item's bullet, number, or task box beside its first line, relative
/// to the block's top and the column's left edge. Never part of the text.
struct MarkerLayout {
    enum Kind {
        case disc, circle, square
        case number(CTLine)
        case task(checked: Bool)
    }

    let kind: Kind
    /// The shape, or a number's typographic bounds.
    let rect: CGRect
    /// The baseline of the item's first line.
    let baseline: CGFloat
    /// The `ColorIndex` of a bullet or number.
    let color: UInt8
}

/// A code block's background box, relative to the block's top and the
/// column's left edge. Its lines never wrap; when the widest is wider than
/// the box, the view scrolls the block horizontally on its own.
struct CodeBlockLayout {
    let rect: CGRect
    /// The widest line plus the padding on both sides.
    let contentWidth: CGFloat

    /// How far the lines can scroll left.
    var maxOffset: CGFloat { max((contentWidth - rect.width).rounded(.up), 0) }
}

/// A block laid out at one column width with Core Text. Immutable, so it can
/// be built off the main thread and shared between snapshots. It depends only
/// on the block, the width, and the typography, so unchanged blocks keep it
/// across edits.
public final class BlockLayout: @unchecked Sendable {
    /// The text column width this layout was made for.
    public let columnWidth: CGFloat
    /// The height of the block's box, without margins.
    public let height: CGFloat
    /// The margins above and below, each the largest of the margins that meet
    /// there, as CSS collapses them through lists and quotes.
    public let marginTop: CGFloat
    public let marginBottom: CGFloat
    /// Line positions are relative to the block's top, in display order.
    let lines: [LineLayout]
    let boxes: [BlockBox]
    /// In display order, so their baselines never decrease.
    let markers: [MarkerLayout]
    /// In display order, top to bottom.
    let codeBlocks: [CodeBlockLayout]
    /// The length of the block's display text in UTF-16 units.
    let textLength: Int
    let styleRuns: [StyleRun]
    /// Dropped blocks (raw HTML) take no space and do not separate margins.
    let isDropped: Bool
    /// A placeholder with an estimated height and no lines, used for blocks
    /// that are not laid out yet during a visible-first open.
    let isEstimate: Bool

    public var lineCount: Int { lines.count }

    /// Whether this layout can be drawn and reused at `columnWidth`.
    func isFinal(for columnWidth: CGFloat) -> Bool { !isEstimate && self.columnWidth == columnWidth }

    /// Lays out `block`: paragraphs and headings with `CTTypesetter` line
    /// breaking and CSS-style line boxes, code blocks one line per source
    /// line, inside the indents of their lists and quotes and with collapsed
    /// margins between them. Cost is proportional to the block's text.
    public convenience init(block: MarkdownBlock, columnWidth: CGFloat, typography: Typography) {
        self.init(block: block, columnWidth: columnWidth, typography: typography, isEstimate: false)
    }

    /// A placeholder whose height is estimated from the text length, at a
    /// small fraction of the cost of a real layout.
    static func estimate(for block: MarkdownBlock, columnWidth: CGFloat, typography: Typography) -> BlockLayout {
        BlockLayout(block: block, columnWidth: columnWidth, typography: typography, isEstimate: true)
    }

    private init(block: MarkdownBlock, columnWidth: CGFloat, typography: Typography, isEstimate: Bool) {
        self.columnWidth = columnWidth
        styleRuns = block.styleRuns
        isDropped = block.kind == .htmlBlock
        textLength = block.text.utf16.count
        self.isEstimate = isEstimate
        var builder = BlockLayoutBuilder(block: block, textLength: textLength, columnWidth: columnWidth,
                                         typography: typography, isEstimate: isEstimate)
        let metrics = isDropped ? (height: 0, top: 0, bottom: 0) : builder.build()
        height = metrics.height
        marginTop = metrics.top
        marginBottom = metrics.bottom
        lines = builder.lines
        boxes = builder.boxes
        markers = builder.markers
        codeBlocks = builder.codeBlocks
    }

    static func makeString(_ block: MarkdownBlock, typography: Typography) -> CFAttributedString? {
        var text = block.text
        let string: CFString? = text.withUTF8 { bytes in
            CFStringCreateWithBytes(nil, bytes.baseAddress, bytes.count, CFStringBuiltInEncodings.UTF8.rawValue, false)
        }
        guard let string else { return nil }
        let runs = block.styleRuns
        if runs.count <= 1, runs.first?.styles.contains(.code) != true {
            let run = runs.first
            return CFAttributedStringCreate(nil, string, typography.attributes(run?.role ?? .body, run?.styles ?? []))
        }
        guard let attributed = CFAttributedStringCreateMutable(nil, 0) else { return nil }
        CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), string)
        CFAttributedStringBeginEditing(attributed)
        let length = CFStringGetLength(string)
        for run in runs where run.range.lowerBound < length {
            let range = CFRange(location: run.range.lowerBound, length: min(run.range.upperBound, length) - run.range.lowerBound)
            CFAttributedStringSetAttributes(attributed, range, typography.attributes(run.role, run.styles), true)
        }
        // Room for the padding beside inline code, as kerning after the
        // character before it and after its last character.
        let padding = typography.inlineCodePadding as NSNumber
        for run in runs where run.styles.contains(.code) && run.range.upperBound <= length {
            let before = run.range.lowerBound - 1
            if before >= 0, CFStringGetCharacterAtIndex(string, before) != 0x0A {
                CFAttributedStringSetAttribute(attributed, CFRange(location: before, length: 1), kCTKernAttributeName, padding)
            }
            CFAttributedStringSetAttribute(attributed, CFRange(location: run.range.upperBound - 1, length: 1),
                                           kCTKernAttributeName, padding)
        }
        CFAttributedStringEndEditing(attributed)
        return attributed
    }

    /// The decorations of one line, from its glyph runs, so they follow the
    /// glyphs' visual positions. Nothing is decorated under the trailing
    /// whitespace of a wrapped line.
    static func decorations(of line: CTLine, baseline: CGFloat, block: MarkdownBlock,
                            typography: Typography) -> [Decoration] {
        let visibleWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
        var decorations: [Decoration] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] where CTRunGetGlyphCount(run) > 0 {
            let location = CTRunGetStringRange(run).location
            let styleIndex = styleRunIndex(in: block.styleRuns, at: location)
            guard styleIndex < block.styleRuns.count else { continue }
            let style = block.styleRuns[styleIndex]
            guard !style.styles.isDisjoint(with: Decoration.styles) else { continue }
            var origin = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &origin)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(), &ascent, &descent, nil))
            let minX = origin.x
            let maxX = min(origin.x + width, visibleWidth)
            guard maxX > minX else { continue }
            let base = typography.fonts[Int(style.role.rawValue)]
            let thickness = max(CTFontGetUnderlineThickness(base), 1)
            if style.styles.contains(.code) {
                let padding = typography.inlineCodePadding
                let left = location == style.range.lowerBound ? minX - padding : minX
                let rect = CGRect(x: left, y: baseline - ascent - padding / 2, width: maxX - left,
                                  height: ascent + descent + padding)
                if let last = decorations.last, last.kind == .codeBackground, last.tag == Int32(styleIndex),
                   abs(last.rect.maxX - left) < 0.5 {
                    decorations[decorations.count - 1].rect = last.rect.union(rect)
                } else {
                    decorations.append(Decoration(kind: .codeBackground, rect: rect, color: 0, tag: Int32(styleIndex)))
                }
            }
            if style.styles.contains(.link), let link = linkIndex(in: block.links, at: location) {
                let y = baseline - CTFontGetUnderlinePosition(base) - thickness / 2
                decorations.append(Decoration(kind: .underline, rect: CGRect(x: minX, y: y, width: maxX - minX, height: thickness),
                                              color: ColorIndex.link, tag: Int32(link)))
            }
            if style.styles.contains(.strikethrough) {
                let y = baseline - CTFontGetXHeight(typography.font(style.role, style.styles)) / 2 - thickness / 2
                decorations.append(Decoration(kind: .strikethrough, rect: CGRect(x: minX, y: y, width: maxX - minX, height: thickness),
                                              color: ColorIndex.of(style.role, style.styles), tag: -1))
            }
        }
        return decorations
    }

    /// The index of the style run holding a UTF-16 offset, or the count.
    static func styleRunIndex(in runs: [StyleRun], at offset: Int) -> Int {
        var low = 0
        var high = runs.count
        while low < high {
            let mid = (low + high) / 2
            if runs[mid].range.upperBound <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func linkIndex(in links: [MarkdownLink], at offset: Int) -> Int? {
        var low = 0
        var high = links.count
        while low < high {
            let mid = (low + high) / 2
            if links[mid].range.upperBound <= offset { low = mid + 1 } else { high = mid }
        }
        return low < links.count && links[low].range.contains(offset) ? low : nil
    }

    /// The style run at a UTF-16 offset of the display text.
    func styleRun(at offset: Int) -> StyleRun {
        let index = Self.styleRunIndex(in: styleRuns, at: offset)
        return index < styleRuns.count ? styleRuns[index] : StyleRun(range: offset..<offset, role: .body)
    }

    /// The role at a UTF-16 offset of the display text.
    func role(at offset: Int) -> TextRole { styleRun(at: offset).role }

    /// The index of the first line whose box ends below `y` (block coordinates).
    func firstLine(endingBelow y: CGFloat) -> Int {
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].top + lines[mid].height <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The index of the line holding a caret `offset`. At a soft wrap the
    /// offset ends one line and starts the next: `upstream` picks the first.
    /// Requires at least one line.
    func lineIndex(containing offset: Int, upstream: Bool) -> Int {
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            let start = lines[mid].range.lowerBound
            if upstream ? start < offset : start <= offset { low = mid + 1 } else { high = mid }
        }
        return max(low - 1, 0)
    }

    /// The caret offset on `line` nearest to `x` (relative to the text's left
    /// edge), never after the line's newline.
    func offset(on line: LineLayout, atX x: CGFloat) -> Int {
        let index = CTLineGetStringIndexForPosition(line.line, CGPoint(x: x, y: 0))
        guard index != kCFNotFound else { return line.range.lowerBound }
        return min(max(index, line.range.lowerBound), line.caretEnd)
    }
}

extension BlockLayout {
    /// Lays out many blocks in parallel on all cores, in index order so the
    /// top of the document is ready first. Layouts in `reusing` that already
    /// match `columnWidth` are kept. Returns `nil` if `isCancelled` reports
    /// true before every block is done.
    static func layOut(_ blocks: [MarkdownBlock], columnWidth: CGFloat, typography: Typography,
                       reusing existing: [BlockLayout]? = nil,
                       isCancelled: @Sendable () -> Bool = { false }) -> [BlockLayout]? {
        let kept = existing?.map { $0.isFinal(for: columnWidth) ? $0 : nil }
            ?? [BlockLayout?](repeating: nil, count: blocks.count)
        return layOut(blocks, filling: kept, columnWidth: columnWidth, typography: typography, isCancelled: isCancelled)
    }

    /// Lays out the blocks whose entry in `layouts` is nil, in parallel when
    /// there are several, and keeps the others. Work is proportional to the
    /// blocks laid out, plus one pass over `layouts`.
    static func layOut(_ blocks: [MarkdownBlock], filling layouts: [BlockLayout?], columnWidth: CGFloat,
                       typography: Typography, isCancelled: @Sendable () -> Bool = { false }) -> [BlockLayout]? {
        precondition(layouts.count == blocks.count, "one layout per block")
        let missing = layouts.indices.filter { layouts[$0] == nil }
        var layouts = layouts
        if missing.count == 1, !isCancelled() {
            layouts[missing[0]] = BlockLayout(block: blocks[missing[0]], columnWidth: columnWidth, typography: typography)
        } else if missing.count > 1 {
            let results = ResultBuffer(count: missing.count)
            defer { results.free() }
            DispatchQueue.concurrentPerform(iterations: missing.count) { slot in
                guard !isCancelled() else { return }
                let index = missing[slot]
                results.store(BlockLayout(block: blocks[index], columnWidth: columnWidth, typography: typography), at: slot)
            }
            guard let laidOut = results.collect() else { return nil }
            for (slot, index) in missing.enumerated() { layouts[index] = laidOut[slot] }
        }
        var result: [BlockLayout] = []
        result.reserveCapacity(layouts.count)
        for layout in layouts {
            guard let layout else { return nil }
            result.append(layout)
        }
        return result
    }
}

/// Write-once slots filled concurrently, one index per worker iteration.
private struct ResultBuffer: @unchecked Sendable {
    private let slots: UnsafeMutableBufferPointer<BlockLayout?>

    init(count: Int) {
        slots = .allocate(capacity: count)
        slots.initialize(repeating: nil)
    }

    func store(_ layout: BlockLayout, at index: Int) { slots[index] = layout }

    func collect() -> [BlockLayout]? {
        var layouts: [BlockLayout] = []
        layouts.reserveCapacity(slots.count)
        for slot in slots {
            guard let slot else { return nil }
            layouts.append(slot)
        }
        return layouts
    }

    func free() {
        slots.deinitialize()
        slots.deallocate()
    }
}
