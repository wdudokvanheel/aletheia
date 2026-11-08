import CoreFoundation
import Foundation

/// The role of a stretch of display text. Layout picks fonts by role and the
/// view picks colors by role at draw time, so a theme switch is only a redraw.
public enum TextRole: UInt8, Sendable, CaseIterable {
    case body
    case heading1, heading2, heading3, heading4, heading5, heading6
    case code
    case quote

    /// The heading role for a level from 1 to 6, clamped.
    public static func heading(_ level: Int) -> TextRole {
        TextRole(rawValue: TextRole.heading1.rawValue + UInt8(min(max(level, 1), 6) - 1))!
    }
}

/// Inline formatting on top of a run's role. Fonts take bold, italic, and
/// monospace traits from it; strikethrough, link underlines, and code
/// backgrounds are drawn as decorations, and links take the link color.
public struct InlineStyle: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let emphasis = InlineStyle(rawValue: 1 << 0)
    public static let strong = InlineStyle(rawValue: 1 << 1)
    public static let strikethrough = InlineStyle(rawValue: 1 << 2)
    public static let code = InlineStyle(rawValue: 1 << 3)
    public static let link = InlineStyle(rawValue: 1 << 4)
    /// Heading or code text inside a block quote, which takes the quote's
    /// color as in the WebKit stylesheet. Body text there has the `quote` role.
    public static let quoted = InlineStyle(rawValue: 1 << 5)

    /// One past the largest raw value, for tables indexed by style.
    static let combinations = 64
}

/// A role and inline styles applied to a UTF-16 range of a block's display text.
public struct StyleRun: Sendable, Equatable {
    public var range: Range<Int>
    public var role: TextRole
    public var styles: InlineStyle

    public init(range: Range<Int>, role: TextRole, styles: InlineStyle = []) {
        self.range = range
        self.role = role
        self.styles = styles
    }
}

/// A link in a block's display text: the UTF-16 range of its text and its
/// destination as written, with entities and escapes decoded and relative
/// paths left unresolved. Autolinks and email links carry the URL cmark gives
/// them (`http://www.…`, `mailto:…`).
public struct MarkdownLink: Sendable, Equatable {
    public var range: Range<Int>
    public var destination: String

    public init(range: Range<Int>, destination: String) {
        self.range = range
        self.destination = destination
    }
}

/// Maps a block's display text to its Markdown source, both as UTF-16 offsets
/// relative to their starts. It is piecewise: from each anchor, display and
/// source advance together until the next anchor's source offset. Markup
/// between pieces of text (`**`, `](url)`, list markers) is skipped, and an
/// entity or escape maps to the start of its source.
public struct SourceMap: Sendable, Equatable {
    struct Anchor: Sendable, Equatable {
        var display: Int32
        var source: Int32
    }

    /// Display offsets strictly increase and source offsets never decrease.
    private(set) var anchors: [Anchor]
    public let displayLength: Int
    public let sourceLength: Int

    /// The identity mapping, clamped to `sourceLength`: a fallback for blocks
    /// built by hand.
    public init(displayLength: Int, sourceLength: Int) {
        self.init(anchors: [Anchor(display: 0, source: 0)], displayLength: displayLength, sourceLength: sourceLength)
    }

    init(anchors: [Anchor], displayLength: Int, sourceLength: Int) {
        self.anchors = anchors
        self.displayLength = displayLength
        self.sourceLength = sourceLength
    }

    /// The source offset of a display offset. Positions at the end of a piece
    /// of text map past the markup that follows it, to the next piece's start.
    public func sourceOffset(forDisplayOffset offset: Int) -> Int {
        guard let index = lastAnchor(where: { Int($0.display) <= offset }) else { return 0 }
        let anchor = anchors[index]
        let limit = index + 1 < anchors.count ? Int(anchors[index + 1].source) : sourceLength
        let display = min(max(offset, Int(anchor.display)), displayLength)
        return max(min(Int(anchor.source) + display - Int(anchor.display), limit), Int(anchor.source))
    }

    /// The display offset of a source offset. Offsets inside markup map to the
    /// next piece of text.
    public func displayOffset(forSourceOffset offset: Int) -> Int {
        guard let index = lastAnchor(where: { Int($0.source) <= offset }) else {
            return anchors.first.map { Int($0.display) } ?? 0
        }
        let anchor = anchors[index]
        let limit = index + 1 < anchors.count ? Int(anchors[index + 1].display) : displayLength
        let source = min(offset, sourceLength)
        return min(Int(anchor.display) + source - Int(anchor.source), limit)
    }

    /// The index of the last anchor `isBefore` accepts; anchors are sorted for both keys.
    private func lastAnchor(where isBefore: (Anchor) -> Bool) -> Int? {
        var low = 0
        var high = anchors.count
        while low < high {
            let mid = (low + high) / 2
            if isBefore(anchors[mid]) { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
}

/// A leaf block inside a top-level list or block quote, in display order: a
/// paragraph, heading, code block, table, or rule, or the line an empty list
/// item takes. Its text is a range of the block's display text, without the
/// newline that separates it from the next text.
struct BlockSegment: Sendable, Equatable {
    enum Kind: UInt8, Sendable {
        case paragraph, heading, code, table, rule, emptyItem
    }

    var kind: Kind
    /// For headings, the level from 1 to 6.
    var level: UInt8 = 0
    /// A paragraph directly inside an item of a tight list, which has no margins.
    var isTight = false
    var start: Int32
    var end: Int32

    var range: Range<Int> { Int(start)..<Int(end) }
}

/// How a table column aligns its cells, from the table's delimiter row.
enum TableAlignment: UInt8, Sendable {
    case none, left, center, right
}

/// A table's grid inside its block: where each cell's text is in the
/// block's display text, and each row's source line. The display text
/// lists the cells in row-major order, separated by tabs within a row and
/// by newlines between rows, so a display offset names its cell and display
/// order is row-major.
struct TableStructure: Sendable, Equatable {
    var alignments: [TableAlignment]
    /// Whether the first row is a header row; front matter tables have none.
    var hasHeader: Bool
    /// Inside a block quote, where the text takes the quote's role.
    var isQuoted: Bool
    /// UTF-16 ranges in the block's display text, `columnCount` per row.
    var cells: [Range<Int32>] = []
    /// Each row's source line, without its line break, as UTF-8 offsets
    /// into the block's source text. Rows with equal lines (and the same
    /// column count, header flag, and quoting) display the same cells.
    var rowLines: [Range<Int32>] = []
    /// Each row's start as a UTF-16 offset into the block's source text.
    var rowSourceStarts: [Int32] = []

    var columnCount: Int { alignments.count }
    var rowCount: Int { rowLines.count }

    func cell(_ row: Int, _ column: Int) -> Range<Int> {
        let range = cells[row * columnCount + column]
        return Int(range.lowerBound)..<Int(range.upperBound)
    }

    /// From the first cell's start to the last cell's end.
    var displayRange: Range<Int> {
        guard let first = cells.first, let last = cells.last else { return 0..<0 }
        return Int(first.lowerBound)..<Int(last.upperBound)
    }

    /// The row and column of the cell holding a display offset: the last
    /// cell starting at or before it, so an offset between two cells (at a
    /// tab or newline) belongs to the cell it ends.
    func cell(containing offset: Int) -> (row: Int, column: Int)? {
        guard !cells.isEmpty, columnCount > 0 else { return nil }
        var low = 0
        var high = cells.count
        while low < high {
            let mid = (low + high) / 2
            if Int(cells[mid].lowerBound) <= offset { low = mid + 1 } else { high = mid }
        }
        let index = max(low - 1, 0)
        return (index / columnCount, index % columnCount)
    }

    /// The row whose source line starts at `offset` (UTF-16, relative to the
    /// block's source), or nil.
    func row(startingAtSource offset: Int) -> Int? {
        var low = 0
        var high = rowSourceStarts.count
        while low < high {
            let mid = (low + high) / 2
            if Int(rowSourceStarts[mid]) < offset { low = mid + 1 } else { high = mid }
        }
        return low < rowSourceStarts.count && Int(rowSourceStarts[low]) == offset ? low : nil
    }
}

/// A block quote, list, or list item around a run of segments. Containers are
/// listed parents first, in document order.
struct BlockContainer: Sendable, Equatable {
    enum Kind: UInt8, Sendable {
        case quote
        case list
        /// A list inside another list, which has no margins of its own.
        case nestedList
        case item
    }

    var kind: Kind
    /// For list items.
    var marker: ListMarker = .none
    var firstSegment: Int32
    var endSegment: Int32

    var segments: Range<Int> { Int(firstSegment)..<Int(endSegment) }
}

/// What a list item draws beside its first line. Markers are decorations,
/// never part of the display text.
enum ListMarker: Sendable, Equatable {
    case none
    /// A disc at level 0, a circle at level 1, and a square deeper, counting
    /// the lists around the item's list.
    case bullet(level: UInt8)
    case number(Int)
    /// A task box, display-only.
    case task(checked: Bool)
}

/// One top-level Markdown block: its kind, where it came from in the source,
/// and the text it displays.
public struct MarkdownBlock: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case paragraph
        case heading(level: Int)
        case codeBlock
        case blockQuote
        case list
        case table
        case thematicBreak
        /// Raw HTML blocks are parsed but never displayed.
        case htmlBlock
        case other
    }

    public var kind: Kind
    /// UTF-16 offsets into the source string passed to `MarkdownDocument.parse`.
    public var sourceRange: Range<Int>
    public var sourceText: String
    /// The plain display text. Hard breaks and block separators are `\n`;
    /// table cells are separated by `\t`.
    public var text: String
    /// Roles and inline styles covering `text` contiguously, in order, as
    /// UTF-16 ranges.
    public var styleRuns: [StyleRun]
    /// Links in `text`, in order and not overlapping.
    public var links: [MarkdownLink]
    /// From `text` to `sourceText`, relative to their starts.
    public var sourceMap: SourceMap
    /// The whitespace before the block on its first line. Indentation
    /// changes how the rest of the block parses, so blocks with the same
    /// source text are only interchangeable with equal indentation.
    var indentation = ""
    /// The leaf blocks and containers of a list or block quote. Empty for
    /// other blocks, which are one segment of their kind.
    var segments: [BlockSegment] = []
    var containers: [BlockContainer] = []
    /// The grid of each table in the block, in display order: one for a
    /// table block, any number in a list or quote.
    var tables: [TableStructure] = []

    /// Without a source map, display offsets map to the same source offsets.
    public init(kind: Kind, sourceRange: Range<Int>, sourceText: String, text: String, styleRuns: [StyleRun],
                links: [MarkdownLink] = [], sourceMap: SourceMap? = nil) {
        self.kind = kind
        self.sourceRange = sourceRange
        self.sourceText = sourceText
        self.text = text
        self.styleRuns = styleRuns
        self.links = links
        self.sourceMap = sourceMap ?? SourceMap(displayLength: text.utf16.count, sourceLength: sourceRange.count)
    }

    /// The document UTF-16 offset of a display offset in this block.
    public func sourceOffset(forDisplayOffset offset: Int) -> Int {
        sourceRange.lowerBound + sourceMap.sourceOffset(forDisplayOffset: offset)
    }

    /// The display offset in this block of a document UTF-16 offset.
    public func displayOffset(forSourceOffset offset: Int) -> Int {
        sourceMap.displayOffset(forSourceOffset: offset - sourceRange.lowerBound)
    }
}

/// A parsed Markdown document: its top-level blocks in source order.
public struct MarkdownDocument: Sendable, Equatable {
    public var blocks: [MarkdownBlock]
    /// The source this was parsed from, as contiguous UTF-8, for diffing the
    /// next parse against. Empty for documents built by hand.
    private(set) var source = ""
    private(set) var sourceUTF16Count = 0
    /// Every part of the source that can hold a link reference definition,
    /// which the display text of every block can depend on. Nil for
    /// documents built by hand, which never match a parse.
    private(set) var definitions: [UInt8]?

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    /// Parses GitHub-flavored Markdown with cmark-gfm. Safe to call off the
    /// main thread; cost is proportional to the source length.
    public static func parse(_ source: String) throws -> MarkdownDocument {
        try parse(source, reusing: nil).document
    }

    /// Parses `source` in full and diffs its top-level blocks against
    /// `previous`: blocks equal to one of `previous` keep that block's display
    /// content instead of building it again, unless the link reference
    /// definitions differ, since every block's display text depends on them.
    static func parse(_ source: String, reusing previous: MarkdownDocument?) throws -> ParseResult {
        let source = contiguousUTF8(source)
        let result = try source.utf8.withContiguousStorageIfAvailable { bytes in
            try MarkdownParser.parse(utf8: bytes, previous: previous)
        }
        guard var result else { throw MarkdownError.parserUnavailable }
        result.document.source = source
        return result
    }

    /// `source` as contiguous UTF-8. Text bridged from an `NSString`, like an
    /// `NSTextView`'s, converts through Core Foundation, about eight times
    /// faster than the standard library's general path; text it rejects
    /// (lone surrogates) takes that path instead, which repairs it.
    static func contiguousUTF8(_ source: String) -> String {
        if source.isContiguousUTF8 { return source }
        let string = source as NSString as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(string))
        let encoding = CFStringBuiltInEncodings.UTF8.rawValue
        var needed: CFIndex = 0
        if CFStringGetBytes(string, range, encoding, 0, false, nil, 0, &needed) == range.length {
            let converted = String(unsafeUninitializedCapacity: needed) { buffer in
                var used: CFIndex = 0
                CFStringGetBytes(string, range, encoding, 0, false, buffer.baseAddress, needed, &used)
                return used
            }
            if converted.utf8.count == needed { return converted }
        }
        var repaired = source
        repaired.makeContiguousUTF8()
        return repaired
    }

    struct ParseResult {
        var document: MarkdownDocument
        /// How the blocks line up with `previous`'s; nil when nothing could
        /// be reused.
        var match: BlockMatch?
        /// The changed span of the source since `previous`.
        var edit: SourceEdit
    }

    init(blocks: [MarkdownBlock], sourceUTF16Count: Int, definitions: [UInt8]) {
        self.blocks = blocks
        self.sourceUTF16Count = sourceUTF16Count
        self.definitions = definitions
    }
}

public enum MarkdownError: Error, Sendable, Equatable, CustomStringConvertible {
    case parserUnavailable
    case extensionUnavailable(String)

    public var description: String {
        switch self {
        case .parserUnavailable: "The Markdown parser could not be created."
        case .extensionUnavailable(let name): "The Markdown extension \(name) is unavailable."
        }
    }
}
