import CoreGraphics
import CoreText
import Foundation

/// One laid-out line, positioned relative to its block's top and the text
/// column's left edge. Its geometry is kept; its `CTLine` is kept in its
/// `LineSet` while there is room, and typeset again when needed.
struct LineLayout {
    /// The set holding the line's `CTLine`, and its index there.
    let lineSet: LineSet
    let index: Int32
    /// What to subtract from an offset in `range` for the index in the
    /// line's string: where a block's window of text starts.
    let base: Int32
    private let start: Int32
    private let end: Int32
    /// The line's code block in `BlockLayout.codeBlocks`, or -1.
    let codeBlock: Int32
    /// Kept small, as there is one per line: x positions within a column
    /// or cell fit a `Float`.
    private let storedX: Float
    private let storedMinX: Float
    private let storedMaxX: Float
    let top: CGFloat
    let height: CGFloat
    let baseline: CGFloat
    /// The `ColorIndex` of the whole line, or `nil` when colors are mixed and
    /// runs are colored one by one.
    let color: UInt8?
    /// Whether the line ends with a `\n` from a hard break or block separator.
    let endsWithNewline: Bool
    /// Whether its paragraph reads right to left, by its first strong character.
    let isRightToLeft: Bool
    /// Inline code backgrounds, link underlines, and strikethroughs, in run order.
    let decorations: [Decoration]

    init(lineSet: LineSet, index: Int32, range: Range<Int>, base: Int32, x: CGFloat, minX: CGFloat, maxX: CGFloat,
         top: CGFloat, height: CGFloat, baseline: CGFloat, color: UInt8?, endsWithNewline: Bool, isRightToLeft: Bool,
         codeBlock: Int32, decorations: [Decoration]) {
        self.lineSet = lineSet
        self.index = index
        self.base = base
        start = Int32(clamping: range.lowerBound)
        end = Int32(clamping: range.upperBound)
        self.codeBlock = codeBlock
        storedX = Float(x)
        storedMinX = Float(minX)
        storedMaxX = Float(maxX)
        self.top = top
        self.height = height
        self.baseline = baseline
        self.color = color
        self.endsWithNewline = endsWithNewline
        self.isRightToLeft = isRightToLeft
        self.decorations = decorations
    }

    /// The line's UTF-16 range in the block's display text.
    var range: Range<Int> { Int(start)..<Int(end) }
    /// Where the text starts: the indent of its lists and quotes, plus a code
    /// block's padding, or for a right-to-left paragraph, far enough right
    /// to end at `maxX`. A scrolled code block moves its lines left of this.
    var x: CGFloat { CGFloat(storedX) }
    /// The left and right edges of the line's text area, which a selection
    /// continuing past the line reaches: on the right, or on the left for
    /// a right-to-left paragraph.
    var minX: CGFloat { CGFloat(storedMinX) }
    var maxX: CGFloat { CGFloat(storedMaxX) }

    /// The Core Text line, typeset again first if its set was dropped.
    var line: CTLine { lineSet.line(at: index) }

    /// The last caret offset on the line: before its newline, if it has one.
    var caretEnd: Int { endsWithNewline ? range.upperBound - 1 : range.upperBound }

    /// The x of the caret before `offset` (an offset in `range`'s terms),
    /// relative to `x`.
    func caretX(_ offset: Int) -> CGFloat { CTLineGetOffsetForStringIndex(line, offset - Int(base), nil) }

    /// The caret offset nearest to `x` (relative to `x`), in `range`'s terms.
    func offset(atX x: CGFloat) -> Int? {
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        return index == kCFNotFound ? nil : index + Int(base)
    }

    /// The same line in its set at `index`, for a line appended to it later.
    func indexed(_ index: Int32) -> LineLayout {
        LineLayout(lineSet: lineSet, index: index, range: range, base: base, x: x, minX: minX, maxX: maxX, top: top,
                   height: height, baseline: baseline, color: color, endsWithNewline: endsWithNewline,
                   isRightToLeft: isRightToLeft, codeBlock: codeBlock, decorations: decorations)
    }
}

/// A rectangle drawn with a line's text. x is relative to the line's `x` and
/// y to the block's top, like the line itself.
struct Decoration {
    enum Kind: UInt8 {
        case codeBackground, underline, strikethrough
        /// A loaded image, in the place its run delegate reserved.
        case image
    }

    static let styles: InlineStyle = [.code, .link, .strikethrough]

    let kind: Kind
    var rect: CGRect
    /// The `ColorIndex` of an underline or strikethrough.
    let color: UInt8
    /// For an underline, the link's index in the block's links; for a code
    /// background, its style run's index; for an image, its index in the
    /// block's images.
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
        /// Drawn as `MarkerNumbers` typesets it.
        case number(Int)
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

/// A box that scrolls horizontally on its own when its content is wider:
/// a code block's background, whose lines never wrap, or a table's box.
/// Relative to the block's top and the column's left edge.
struct CodeBlockLayout {
    let rect: CGRect
    /// The widest line plus the padding on both sides, or the table's width.
    let contentWidth: CGFloat
    /// The box of one of the block's `tables`.
    var isTable = false

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
    /// In display order, top to bottom: code blocks and tables.
    let codeBlocks: [CodeBlockLayout]
    /// The block's tables, laid out per cell, in display order.
    let tables: [TableLayout]
    /// The length of the block's display text in UTF-16 units.
    let textLength: Int
    let styleRuns: [StyleRun]
    /// Dropped blocks (raw HTML, empty front matter) take no space and do
    /// not separate margins.
    let isDropped: Bool
    /// A placeholder with an estimated height and no lines, used for blocks
    /// that are not laid out yet during a visible-first open.
    let isEstimate: Bool
    /// A table with rows that are not laid out yet, whose heights are
    /// estimated; the rest follows in the background.
    let isPartial: Bool
    /// The natural size each of the block's images was laid out with, nil
    /// for one not loaded, whose alt text shows; empty without images.
    let imageSizes: [CGSize?]
    /// The widest each image may be shown where it is: the text width of
    /// its paragraph, or the widest a cell of its table gets. Zero for
    /// images not laid out.
    let imageWidths: [CGFloat]
    /// Whether any line places an image.
    let drawsImages: Bool

    /// Lines of text, counting each line in table cells.
    public var lineCount: Int {
        lines.count + tables.reduce(0) { $0 + $1.rows.reduce(0) { $0 + $1.lines.count } }
    }

    /// Whether this layout can be drawn and reused at `columnWidth`.
    func isFinal(for columnWidth: CGFloat) -> Bool { !isEstimate && !isPartial && self.columnWidth == columnWidth }

    /// Whether this layout of `block` can be drawn and reused at
    /// `columnWidth` with the images loaded in `images`.
    func isFinal(for columnWidth: CGFloat, images: ImageSizes, block: MarkdownBlock) -> Bool {
        isFinal(for: columnWidth) && hasImageSizes(images, of: block)
    }

    /// Whether `block`'s images have the sizes in `images` that this layout
    /// used. Constant for blocks without images.
    func hasImageSizes(_ images: ImageSizes, of block: MarkdownBlock) -> Bool {
        guard !block.images.isEmpty else { return imageSizes.isEmpty }
        guard imageSizes.count == block.images.count else { return false }
        for index in imageSizes.indices where Self.size(block.images[index].source, in: images) != imageSizes[index] {
            return false
        }
        return true
    }

    /// The size layout uses for an image: its loaded size, if valid.
    static func size(_ source: String, in images: ImageSizes) -> CGSize? {
        images[source].flatMap { ImageSizes.isValid($0) ? $0 : nil }
    }

    /// Lays out `block`: paragraphs and headings with `CTTypesetter` line
    /// breaking and CSS-style line boxes, code blocks one line per source
    /// line, tables per cell, inside the indents of their lists and quotes
    /// and with collapsed margins between them. Cost is proportional to the
    /// block's text.
    public convenience init(block: MarkdownBlock, columnWidth: CGFloat, typography: Typography) {
        var builder = BlockLayoutBuilder(block: block, textLength: block.text.utf16.count, columnWidth: columnWidth,
                                         typography: typography, isEstimate: false)
        let metrics = builder.build(isCancelled: { false })
        self.init(block: block, builder: builder, metrics: metrics)
    }

    /// Lays out `block` like the public initializer, with the images loaded
    /// in `images`. `hint`, an earlier layout of the same or an edited block
    /// at any width, lends tables the rows and natural cell widths that still
    /// apply; one whose images were sized differently lends nothing. A table
    /// block lays out only `tableRows` and estimates the rest. Nil when
    /// `isCancelled` reports true during a table. Lines laid out ahead of
    /// being drawn (not `linesWarm`) are the first to be dropped when there
    /// is no room for them; see `LineSet`.
    static func make(_ block: MarkdownBlock, columnWidth: CGFloat, typography: Typography, hint: BlockLayout? = nil,
                     tableRows: TableRows = .all, images: ImageSizes = .none, linesWarm: Bool = true,
                     isCancelled: () -> Bool = { false }) -> BlockLayout? {
        var builder = BlockLayoutBuilder(block: block, textLength: block.text.utf16.count, columnWidth: columnWidth,
                                         typography: typography, isEstimate: false)
        builder.images = images
        builder.linesWarm = linesWarm
        builder.hint = hint.flatMap {
            guard !$0.isEstimate, !$0.tables.isEmpty else { return nil }
            // Rows keep their images' sizes, which depend on the width too.
            let placesImages = $0.imageSizes.contains { $0 != nil }
                || block.images.contains { size($0.source, in: images) != nil }
            return !placesImages || ($0.columnWidth == columnWidth && $0.hasImageSizes(images, of: block)) ? $0 : nil
        }
        builder.tableRows = block.kind == .table ? tableRows : .all
        let metrics = builder.build(isCancelled: isCancelled)
        guard !builder.isCancelled else { return nil }
        return BlockLayout(block: block, builder: builder, metrics: metrics)
    }

    /// A placeholder whose height is estimated from the text length, at a
    /// small fraction of the cost of a real layout.
    static func estimate(for block: MarkdownBlock, columnWidth: CGFloat, typography: Typography) -> BlockLayout {
        var builder = BlockLayoutBuilder(block: block, textLength: block.text.utf16.count, columnWidth: columnWidth,
                                         typography: typography, isEstimate: true)
        let metrics = builder.build(isCancelled: { false })
        return BlockLayout(block: block, builder: builder, metrics: metrics)
    }

    private init(block: MarkdownBlock, builder: BlockLayoutBuilder, metrics: (height: CGFloat, top: CGFloat, bottom: CGFloat)) {
        columnWidth = builder.columnWidth
        styleRuns = block.styleRuns
        isDropped = builder.isDropped
        textLength = builder.textLength
        isEstimate = builder.isEstimate
        height = metrics.height
        marginTop = metrics.top
        marginBottom = metrics.bottom
        lines = builder.lines
        boxes = builder.boxes
        markers = builder.markers
        codeBlocks = builder.codeBlocks
        tables = builder.tables
        isPartial = builder.tables.contains { $0.isPartial }
        imageSizes = builder.imageSizes
        imageWidths = builder.imageWidths
        drawsImages = builder.drawsImages || builder.tables.contains { $0.drawsImages }
    }

    /// The block's display text as a Core Foundation string of the same
    /// length, so offsets in the display text are offsets in it.
    static func makeText(_ block: MarkdownBlock) -> CFString? {
        makeText(block.text, length: block.text.utf16.count)
    }

    /// `text`, `length` UTF-16 units long, as a Core Foundation string of
    /// that length. Converting UTF-8 is fastest, but Core Foundation reads
    /// a leading U+FEFF there as a byte order mark and drops it; that text
    /// is converted from UTF-16 instead.
    static func makeText(_ text: String, length: Int) -> CFString? {
        var text = text
        if !text.utf8.starts(with: [0xEF, 0xBB, 0xBF]),
           let string = text.withUTF8({ bytes in
               CFStringCreateWithBytes(nil, bytes.baseAddress, bytes.count, CFStringBuiltInEncodings.UTF8.rawValue, false)
           }), CFStringGetLength(string) == length {
            return string
        }
        let units = Array(text.utf16)
        let string = CFStringCreateWithCharacters(nil, units, units.count)
        assert(string.map(CFStringGetLength) == length, "the Core Text string keeps the display length")
        return string
    }

    /// UTF-16 units `range` of `text`, which is `length` units long, as a
    /// Core Foundation string.
    static func substring(of text: String, _ range: Range<Int>, length: Int) -> CFString? {
        if range == 0..<length { return makeText(text, length: length) }
        let utf16 = text.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let end = utf16.index(start, offsetBy: range.count)
        let units = Array(utf16[start..<end])
        return CFStringCreateWithCharacters(nil, units, units.count)
    }

    /// `string` with the fonts of `runs`, which cover it in order, without
    /// kerning unless `kerned`, with `images` in their places, and with the
    /// base writing direction of each paragraph in `directions`, which
    /// others leave to Core Text: the direction of its first strong character.
    static func makeString(_ string: CFString, runs: [StyleRun], typography: Typography,
                           kerned: Bool = true, images: ImageText? = nil,
                           directions: [ParagraphDirection] = []) -> CFAttributedString? {
        if runs.count <= 1, runs.first?.styles.contains(.code) != true, runs.first?.styles.contains(.image) != true,
           directions.isEmpty {
            let run = runs.first
            return CFAttributedStringCreate(nil, string, typography.attributes(run?.role ?? .body, run?.styles ?? [],
                                                                               kerned: kerned))
        }
        guard let attributed = CFAttributedStringCreateMutable(nil, 0) else { return nil }
        CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), string)
        CFAttributedStringBeginEditing(attributed)
        let length = CFStringGetLength(string)
        for run in runs where run.range.lowerBound < length {
            let range = CFRange(location: run.range.lowerBound, length: min(run.range.upperBound, length) - run.range.lowerBound)
            CFAttributedStringSetAttributes(attributed, range, typography.attributes(run.role, run.styles, kerned: kerned), true)
            if run.styles.contains(.image) {
                CFAttributedStringSetAttribute(attributed, range, Typography.imageAttribute, kCFBooleanTrue)
            }
        }
        images?.apply(to: attributed)
        for direction in directions {
            let lower = max(direction.range.lowerBound, 0)
            let upper = min(direction.range.upperBound, length)
            guard lower < upper else { continue }
            CFAttributedStringSetAttribute(attributed, CFRange(location: lower, length: upper - lower),
                                           kCTParagraphStyleAttributeName, typography.paragraphStyle(direction.isRightToLeft))
        }
        // Room for the padding beside inline code, as kerning after the
        // character before it and after its last character: on the whole
        // composed character, since an attribute run that splits a
        // surrogate pair or a cluster leaves Core Text nothing to shape.
        let padding = typography.inlineCodePadding as NSNumber
        for run in runs where run.styles.contains(.code) && run.range.upperBound <= length {
            let before = run.range.lowerBound - 1
            if before >= 0, CFStringGetCharacterAtIndex(string, before) != 0x0A {
                CFAttributedStringSetAttribute(attributed, CFStringGetRangeOfComposedCharactersAtIndex(string, before),
                                               kCTKernAttributeName, padding)
            }
            CFAttributedStringSetAttribute(attributed, CFStringGetRangeOfComposedCharactersAtIndex(string, run.range.upperBound - 1),
                                           kCTKernAttributeName, padding)
        }
        CFAttributedStringEndEditing(attributed)
        return attributed
    }

    /// A laid-out line for `range` of a string covered by `runs`, with its
    /// line box: the tallest line height of the roles in it, with the glyphs
    /// centered in it as CSS does. The line is `index` in `set`. `range`,
    /// `runs`, and `links` index the text the string's index `base` starts
    /// at. `runIndex` is the run the line starts in or one before it, and
    /// moves forward. Without `maxX`, the line's right edge is its visible
    /// width. A right-to-left line ends at `maxX`. Also returns that visible
    /// width. With `hasImages`, images on the line are placed; see `imageBox`.
    static func lineLayout(_ line: CTLine, in set: LineSet, index: Int32, range: Range<Int>, base: Int = 0,
                           string: CFString, runs: [StyleRun], runIndex: inout Int, links: ArraySlice<MarkdownLink>,
                           linkOffset: Int, x: CGFloat, maxX: CGFloat?, top: CGFloat, codeBlock: Int32,
                           typography: Typography, hasImages: Bool = false,
                           isRightToLeft: Bool = false) -> (layout: LineLayout, width: CGFloat) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let visibleWidth = width - CGFloat(CTLineGetTrailingWhitespaceWidth(line))

        // Roles and styles in this line, from the style runs (which are in order).
        while runIndex < runs.count - 1, runs[runIndex].range.upperBound <= range.lowerBound { runIndex += 1 }
        let first = runs.isEmpty ? StyleRun(range: range, role: .body) : runs[runIndex]
        var color: UInt8? = ColorIndex.of(first.role, first.styles)
        var lineHeight = typography.lineHeight(first.role)
        var isDecorated = !first.styles.isDisjoint(with: Decoration.styles)
        var next = runIndex + 1
        while next < runs.count, runs[next].range.lowerBound < range.upperBound {
            let run = runs[next]
            if ColorIndex.of(run.role, run.styles) != color { color = nil }
            lineHeight = max(lineHeight, typography.lineHeight(run.role))
            isDecorated = isDecorated || !run.styles.isDisjoint(with: Decoration.styles)
            next += 1
        }

        var height = lineHeight
        var baseline = top + (lineHeight - (ascent + descent)) / 2 + ascent
        var images: [Decoration] = []
        if hasImages, let box = imageBox(of: line, string: string, lineHeight: lineHeight) {
            // Drawn run by run, past the images' runs.
            color = nil
            if !box.images.isEmpty {
                height = box.height
                baseline = top + box.above
                images = box.images.map {
                    Decoration(kind: .image, rect: CGRect(x: $0.x, y: baseline - $0.size.height, width: $0.size.width,
                                                          height: $0.size.height), color: 0, tag: $0.index)
                }
            }
        }
        let endsWithNewline = !range.isEmpty && CFStringGetCharacterAtIndex(string, range.upperBound - 1 - base) == 0x0A
        var lineDecorations = isDecorated ? decorations(of: line, baseline: baseline, runs: runs, links: links,
                                                        linkOffset: linkOffset, base: base, typography: typography) : []
        lineDecorations.append(contentsOf: images)
        var lineX = x
        if isRightToLeft, let maxX { lineX += CGFloat(CTLineGetPenOffsetForFlush(line, 1, Double(maxX - x))) }
        let layout = LineLayout(lineSet: set, index: index, range: range, base: Int32(clamping: base), x: lineX, minX: x,
                                maxX: maxX ?? visibleWidth, top: top, height: height, baseline: baseline, color: color,
                                endsWithNewline: endsWithNewline, isRightToLeft: isRightToLeft, codeBlock: codeBlock,
                                decorations: lineDecorations)
        return (layout, codeBlock >= 0 ? visibleWidth : width)
    }

    /// The line box of a line with images, as CSS builds it: images sit on
    /// the baseline and the text keeps its line height (the strut), so the
    /// box reaches from the higher of the images' tops and the strut's top
    /// down to the strut's bottom. A line with nothing but images, such as
    /// an image alone in its paragraph, has no strut and is exactly as tall
    /// as its tallest image. Nil without run delegates on the line; without
    /// images, as with only the placeholder of an image without alt text.
    private static func imageBox(of line: CTLine, string: CFString, lineHeight: CGFloat)
        -> (above: CGFloat, height: CGFloat, images: [(x: CGFloat, size: CGSize, index: Int32)])? {
        var images: [(x: CGFloat, size: CGSize, index: Int32)] = []
        var imageHeight: CGFloat = 0
        var textAscent: CGFloat = 0
        var textDescent: CGFloat = 0
        var hasText = false
        var hasDelegates = false
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] where CTRunGetGlyphCount(run) > 0 {
            if let box = ImageText.box(of: run) {
                hasDelegates = true
                guard box.size.width > 0, box.size.height > 0 else { continue }
                var origin = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &origin)
                images.append((origin.x, box.size, box.index))
                imageHeight = max(imageHeight, box.size.height)
                continue
            }
            let range = CTRunGetStringRange(run)
            // Line separators and the joiners of an image are not text.
            guard (range.location..<(range.location + range.length)).contains(where: {
                let character = CFStringGetCharacterAtIndex(string, $0)
                return character != 0x0A && character != 0x2060
            }) else { continue }
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTRunGetTypographicBounds(run, CFRange(), &ascent, &descent, nil)
            textAscent = max(textAscent, ascent)
            textDescent = max(textDescent, descent)
            hasText = true
        }
        guard hasDelegates else { return nil }
        guard !images.isEmpty else { return (0, 0, []) }
        guard hasText else { return (imageHeight, imageHeight, images) }
        let strutAbove = textAscent + (lineHeight - textAscent - textDescent) / 2
        let above = max(strutAbove, imageHeight)
        return (above, above + lineHeight - strutAbove, images)
    }

    /// The decorations of one line, from its glyph runs, so they follow the
    /// glyphs' visual positions. Nothing is decorated under the trailing
    /// whitespace of a wrapped line. `runs` and `links` index the line's
    /// string; an underline's tag is its link's index plus `linkOffset`.
    static func decorations(of line: CTLine, baseline: CGFloat, runs: [StyleRun], links: ArraySlice<MarkdownLink>,
                            linkOffset: Int, base: Int = 0, typography: Typography) -> [Decoration] {
        let visibleWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
        var decorations: [Decoration] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] where CTRunGetGlyphCount(run) > 0 {
            let location = CTRunGetStringRange(run).location + base
            let styleIndex = styleRunIndex(in: runs, at: location)
            guard styleIndex < runs.count else { continue }
            let style = runs[styleIndex]
            guard !style.styles.isDisjoint(with: Decoration.styles) else { continue }
            // A placed image is not underlined or struck through.
            if style.styles.contains(.image), ImageText.box(of: run) != nil { continue }
            var origin = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &origin)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(), &ascent, &descent, nil))
            // Trailing whitespace hangs: past the visible width, or left of
            // zero in a right-to-left line.
            let minX = max(origin.x, 0)
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
            if style.styles.contains(.link), let link = linkIndex(in: links, at: location), links[link].isLive {
                let y = baseline - CTFontGetUnderlinePosition(base) - thickness / 2
                decorations.append(Decoration(kind: .underline,
                                              rect: CGRect(x: minX, y: y, width: maxX - minX, height: thickness),
                                              color: ColorIndex.of(style.role, style.styles),
                                              tag: Int32(link - links.startIndex + linkOffset)))
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

    /// The index in `links` of the link holding a UTF-16 offset.
    static func linkIndex(in links: ArraySlice<MarkdownLink>, at offset: Int) -> Int? {
        let index = firstLink(in: links, endingAfter: offset)
        return index < links.endIndex && links[index].range.contains(offset) ? index : nil
    }

    /// The index of the first link that ends after `offset`, or the end index.
    static func firstLink(in links: ArraySlice<MarkdownLink>, endingAfter offset: Int) -> Int {
        var low = links.startIndex
        var high = links.endIndex
        while low < high {
            let mid = (low + high) / 2
            if links[mid].range.upperBound <= offset { low = mid + 1 } else { high = mid }
        }
        return low
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
        guard let index = line.offset(atX: x) else { return line.range.lowerBound }
        return min(max(index, line.range.lowerBound), line.caretEnd)
    }
}

extension BlockLayout {
    /// Lays out many blocks in parallel on all cores, in index order so the
    /// top of the document is ready first. Layouts in `reusing` that already
    /// match `columnWidth` are kept. Returns `nil` if `isCancelled` reports
    /// true before every block is done.
    static func layOut(_ blocks: [MarkdownBlock], columnWidth: CGFloat, typography: Typography,
                       reusing existing: [BlockLayout]? = nil, images: ImageSizes = .none,
                       isCancelled: @Sendable () -> Bool = { false }) -> [BlockLayout]? {
        let kept = existing.map { existing in
            existing.indices.map { existing[$0].isFinal(for: columnWidth, images: images, block: blocks[$0]) ? existing[$0] : nil }
        } ?? [BlockLayout?](repeating: nil, count: blocks.count)
        return layOut(blocks, filling: kept, hints: existing, columnWidth: columnWidth, typography: typography,
                      images: images, isCancelled: isCancelled)
    }

    /// Lays out the blocks whose entry in `layouts` is nil, in parallel when
    /// there are several, and keeps the others. Work is proportional to the
    /// blocks laid out, plus one pass over `layouts`. `hints` (one per block)
    /// lend tables what still applies of an earlier layout.
    static func layOut(_ blocks: [MarkdownBlock], filling layouts: [BlockLayout?], hints: [BlockLayout?]? = nil,
                       columnWidth: CGFloat, typography: Typography, images: ImageSizes = .none, linesWarm: Bool = true,
                       isCancelled: @Sendable () -> Bool = { false }) -> [BlockLayout]? {
        precondition(layouts.count == blocks.count, "one layout per block")
        let missing = layouts.indices.filter { layouts[$0] == nil }
        var layouts = layouts
        if missing.count == 1, !isCancelled() {
            let index = missing[0]
            layouts[index] = make(blocks[index], columnWidth: columnWidth, typography: typography, hint: hints?[index],
                                  images: images, linesWarm: linesWarm, isCancelled: isCancelled)
        } else if missing.count > 1 {
            let results = ResultBuffer(count: missing.count)
            defer { results.free() }
            DispatchQueue.concurrentPerform(iterations: missing.count) { slot in
                guard !isCancelled() else { return }
                let index = missing[slot]
                if let layout = make(blocks[index], columnWidth: columnWidth, typography: typography, hint: hints?[index],
                                     images: images, linesWarm: linesWarm, isCancelled: isCancelled) {
                    results.store(layout, at: slot)
                }
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
