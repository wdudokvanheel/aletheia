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
    /// The single role of the whole line, or `nil` when roles are mixed and
    /// runs are colored one by one.
    let role: TextRole?
    /// Whether the line ends with a `\n` from a hard break or block separator.
    let endsWithNewline: Bool

    /// The last caret offset on the line: before its newline, if it has one.
    var caretEnd: Int { endsWithNewline ? range.upperBound - 1 : range.upperBound }
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

            // Roles in this line, from the style runs (which are in order).
            let runs = block.styleRuns
            while runIndex < runs.count - 1, runs[runIndex].range.upperBound <= range.lowerBound { runIndex += 1 }
            var role: TextRole? = runs.isEmpty ? .body : runs[runIndex].role
            var lineHeight = typography.lineHeight(role ?? .body)
            var index = runIndex + 1
            while index < runs.count, runs[index].range.lowerBound < range.upperBound {
                if runs[index].role != role { role = nil }
                lineHeight = max(lineHeight, typography.lineHeight(runs[index].role))
                index += 1
            }

            let halfLeading = (lineHeight - (ascent + descent)) / 2
            lines.append(LineLayout(line: line, range: range, top: y, height: lineHeight,
                                    baseline: y + halfLeading + ascent, role: role,
                                    endsWithNewline: CFStringGetCharacterAtIndex(characters, range.upperBound - 1) == 0x0A))
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
        if runs.count <= 1 {
            let attributes = typography.attributes[Int((runs.first?.role ?? .body).rawValue)]
            return CFAttributedStringCreate(nil, string, attributes)
        }
        guard let attributed = CFAttributedStringCreateMutable(nil, 0) else { return nil }
        CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), string)
        CFAttributedStringBeginEditing(attributed)
        let length = CFStringGetLength(string)
        for run in runs where run.range.lowerBound < length {
            let range = CFRange(location: run.range.lowerBound, length: min(run.range.upperBound, length) - run.range.lowerBound)
            CFAttributedStringSetAttributes(attributed, range, typography.attributes[Int(run.role.rawValue)], true)
        }
        CFAttributedStringEndEditing(attributed)
        return attributed
    }

    /// The role at a UTF-16 offset of the display text.
    func role(at offset: Int) -> TextRole {
        var low = 0
        var high = styleRuns.count
        while low < high {
            let mid = (low + high) / 2
            if styleRuns[mid].range.upperBound <= offset { low = mid + 1 } else { high = mid }
        }
        return low < styleRuns.count ? styleRuns[low].role : .body
    }

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
        let count = blocks.count
        guard count > 0 else { return [] }
        let results = ResultBuffer(count: count)
        defer { results.free() }
        DispatchQueue.concurrentPerform(iterations: count) { index in
            guard !isCancelled() else { return }
            if let existing, existing[index].isFinal(for: columnWidth) {
                results.store(existing[index], at: index)
            } else {
                results.store(BlockLayout(block: blocks[index], columnWidth: columnWidth, typography: typography), at: index)
            }
        }
        return results.collect()
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
