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

/// A role applied to a UTF-16 range of a block's display text.
public struct StyleRun: Sendable, Equatable {
    public var range: Range<Int>
    public var role: TextRole

    public init(range: Range<Int>, role: TextRole) {
        self.range = range
        self.role = role
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
    /// Roles covering `text` contiguously, in order, as UTF-16 ranges.
    public var styleRuns: [StyleRun]

    public init(kind: Kind, sourceRange: Range<Int>, sourceText: String, text: String, styleRuns: [StyleRun]) {
        self.kind = kind
        self.sourceRange = sourceRange
        self.sourceText = sourceText
        self.text = text
        self.styleRuns = styleRuns
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
