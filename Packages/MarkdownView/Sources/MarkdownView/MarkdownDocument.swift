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

    /// One past the largest raw value, for tables indexed by style.
    static let combinations = 32
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

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    /// Parses GitHub-flavored Markdown with cmark-gfm. Safe to call off the
    /// main thread; cost is proportional to the source length.
    public static func parse(_ source: String) throws -> MarkdownDocument {
        var source = source
        source.makeContiguousUTF8()
        let blocks = try source.utf8.withContiguousStorageIfAvailable { bytes in
            try MarkdownParser.blocks(utf8: bytes)
        }
        return MarkdownDocument(blocks: blocks ?? [])
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
