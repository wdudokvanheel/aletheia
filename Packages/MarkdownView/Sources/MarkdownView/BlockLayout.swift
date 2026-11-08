import CoreGraphics
import CoreText
import Foundation

/// One laid-out line, positioned relative to its block's top.
struct LineLayout {
    let line: CTLine
    /// The line's UTF-16 range in the block's display text.
    let range: Range<Int>
    let top: CGFloat
    let height: CGFloat
    let baseline: CGFloat
    /// The `ColorIndex` of the whole line, or `nil` when colors are mixed and
    /// runs are colored one by one.
    let color: UInt8?
    /// Whether the line ends with a `\n` from a hard break or block separator.
    let endsWithNewline: Bool
    /// Inline code backgrounds, link underlines, and strikethroughs, in run order.
    let decorations: [Decoration]

    /// The last caret offset on the line: before its newline, if it has one.
    var caretEnd: Int { endsWithNewline ? range.upperBound - 1 : range.upperBound }
}

/// A rectangle drawn with a line's text. x is relative to the text's left
/// edge and y to the block's top, like the line itself.
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

/// A block laid out at one column width with Core Text. Immutable, so it can
/// be built off the main thread and shared between snapshots.
public final class BlockLayout: @unchecked Sendable {
    /// The text column width this layout was made for.
    public let columnWidth: CGFloat
    /// The height of the block's box, without margins.
    public let height: CGFloat
    public let marginTop: CGFloat
    public let marginBottom: CGFloat
    /// Line positions are relative to the block's top; x is this inset.
    let lines: [LineLayout]
    let textInset: CGFloat
    /// The length of the block's display text in UTF-16 units.
    let textLength: Int
    let styleRuns: [StyleRun]
    let drawsCodeBackground: Bool
    /// Dropped blocks (raw HTML) take no space and do not separate margins.
    let isDropped: Bool
    /// A placeholder with an estimated height and no lines, used for blocks
    /// that are not laid out yet during a visible-first open.
    let isEstimate: Bool

    public var lineCount: Int { lines.count }

    /// Whether this layout can be drawn and reused at `columnWidth`.
    func isFinal(for columnWidth: CGFloat) -> Bool { !isEstimate && self.columnWidth == columnWidth }

    /// Lays out `block` with `CTTypesetter` line breaking and CSS-style line
    /// boxes. Cost is proportional to the block's text.
    public convenience init(block: MarkdownBlock, columnWidth: CGFloat, typography: Typography) {
        let padding = block.kind == .codeBlock ? typography.codeBlockPadding : 0
        let lines = block.kind == .htmlBlock ? [] : Self.lines(for: block, width: max(columnWidth - 2 * padding, 1),
                                                               top: padding, typography: typography)
        self.init(block: block, columnWidth: columnWidth, typography: typography, lines: lines,
                  height: (lines.last.map { $0.top + $0.height } ?? padding) + padding, isEstimate: false)
    }

    /// A placeholder whose height is estimated from the text length, at a
    /// small fraction of the cost of a real layout.
    static func estimate(for block: MarkdownBlock, columnWidth: CGFloat, typography: Typography) -> BlockLayout {
        let padding = block.kind == .codeBlock ? typography.codeBlockPadding : 0
        var height = block.kind == .htmlBlock ? 0 : 2 * padding
        if !block.text.isEmpty, block.kind != .htmlBlock {
            let role = block.styleRuns.first?.role ?? .body
            let averageCharacterWidth = CTFontGetSize(typography.fonts[Int(role.rawValue)]) * (role == .code ? 0.6 : 0.5)
            let utf8 = block.text.utf8
            let newlines = utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            let wrapped = CGFloat(utf8.count) * averageCharacterWidth / max(columnWidth - 2 * padding, 1)
            height += CGFloat(newlines + 1 + Int(wrapped)) * typography.lineHeight(role)
        }
        return BlockLayout(block: block, columnWidth: columnWidth, typography: typography, lines: [],
                           height: height, isEstimate: true)
    }

    private init(block: MarkdownBlock, columnWidth: CGFloat, typography: Typography, lines: [LineLayout],
                 height: CGFloat, isEstimate: Bool) {
        self.columnWidth = columnWidth
        styleRuns = block.styleRuns
        isDropped = block.kind == .htmlBlock
        let margins = isDropped ? (top: 0, bottom: 0) : typography.margins(for: block.kind)
        marginTop = margins.top
        marginBottom = margins.bottom
        drawsCodeBackground = block.kind == .codeBlock
        textInset = drawsCodeBackground ? typography.codeBlockPadding : 0
        self.lines = lines
        self.height = height
        self.isEstimate = isEstimate
        textLength = block.text.utf16.count
    }

    private static func lines(for block: MarkdownBlock, width: CGFloat, top: CGFloat, typography: Typography) -> [LineLayout] {
        guard !block.text.isEmpty, let string = makeString(block, typography: typography) else { return [] }
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let length = CFAttributedStringGetLength(string)
        let characters = CFAttributedStringGetString(string)
        var lines: [LineLayout] = []
        var start = 0
        var y = top
        var runIndex = 0
        while start < length {
            let count = max(CTTypesetterSuggestLineBreak(typesetter, start, Double(width)), 1)
            let range = start..<min(start + count, length)
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: range.lowerBound, length: range.count))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

            // Roles and styles in this line, from the style runs (which are in order).
            let runs = block.styleRuns
            while runIndex < runs.count - 1, runs[runIndex].range.upperBound <= range.lowerBound { runIndex += 1 }
            let first = runs.isEmpty ? StyleRun(range: 0..<length, role: .body) : runs[runIndex]
            var color: UInt8? = ColorIndex.of(first.role, first.styles)
            var lineHeight = typography.lineHeight(first.role)
            var isDecorated = !first.styles.isDisjoint(with: Decoration.styles)
            var index = runIndex + 1
            while index < runs.count, runs[index].range.lowerBound < range.upperBound {
                let run = runs[index]
                if ColorIndex.of(run.role, run.styles) != color { color = nil }
                lineHeight = max(lineHeight, typography.lineHeight(run.role))
                isDecorated = isDecorated || !run.styles.isDisjoint(with: Decoration.styles)
                index += 1
            }

            let halfLeading = (lineHeight - (ascent + descent)) / 2
            let baseline = y + halfLeading + ascent
            lines.append(LineLayout(line: line, range: range, top: y, height: lineHeight, baseline: baseline,
                                    color: color,
                                    endsWithNewline: CFStringGetCharacterAtIndex(characters, range.upperBound - 1) == 0x0A,
                                    decorations: isDecorated ? decorations(of: line, baseline: baseline, block: block,
                                                                           typography: typography) : []))
            y += lineHeight
            start = range.upperBound
        }
        return lines
    }

    private static func makeString(_ block: MarkdownBlock, typography: Typography) -> CFAttributedString? {
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
    private static func decorations(of line: CTLine, baseline: CGFloat, block: MarkdownBlock,
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
    private static func styleRunIndex(in runs: [StyleRun], at offset: Int) -> Int {
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
