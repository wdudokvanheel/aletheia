/// What a stretch of code is, for its color: the eight kinds a host maps its
/// tokenizer's scopes onto. Each has its own color in `Palette`.
public enum CodeTokenKind: UInt8, Sendable, CaseIterable {
    case comment, string, keyword, number, name, property, markup, invalid
}

/// A token in a code segment's text: a UTF-16 range of that text and its kind.
public struct CodeToken: Sendable, Equatable {
    public var range: Range<Int>
    public var kind: CodeTokenKind

    public init(range: Range<Int>, kind: CodeTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// Where a `MarkdownPreviewView` gets the tokens that color code blocks.
///
/// The view asks for the tokens of each code segment of a block that changed:
/// a fenced or indented code block, also inside a list or block quote, or
/// front matter shown as code. Blocks unchanged since the last update keep
/// their tokens, so tokens must depend only on the text and info string. The
/// view calls it on its render queue, never on the main thread, possibly from
/// several threads at once and while the host tokenizes elsewhere, so it must
/// be safe to call concurrently.
public protocol MarkdownCodeHighlighter: Sendable {
    /// The tokens of `code`, a code segment's display text, as UTF-16 ranges
    /// of it, or nil to leave it plain. `info` is the fence's whole info
    /// string without the whitespace around it (`java`, `ts title="x"`,
    /// `{python}`), and empty for indented code and front matter.
    ///
    /// Tokens are clipped to the text and to scalar boundaries. A token that
    /// overlaps one starting before it, or at the same offset earlier in the
    /// array, is dropped. Code over 256 KiB of UTF-16 units is not asked for.
    func tokens(for code: String, info: String) -> [CodeToken]?
}

/// The view's highlighter, wrapped once each time it is set, so a document
/// can tell whether its tokens came from the highlighter set now.
final class CodeHighlighting: Sendable, Equatable {
    let highlighter: any MarkdownCodeHighlighter

    init(_ highlighter: any MarkdownCodeHighlighter) {
        self.highlighter = highlighter
    }

    static func == (a: CodeHighlighting, b: CodeHighlighting) -> Bool { a === b }
}

extension MarkdownBlock {
    /// Code segments longer than this, in UTF-16 units, are not highlighted:
    /// a block that size in a Markdown file is a log paste, not code.
    static let highlightLimit = 256 * 1024

    /// Asks `highlighter` for the tokens of each code segment and splits the
    /// style runs at them, each tokenized run carrying its kind.
    mutating func highlightCode(with highlighter: any MarkdownCodeHighlighter) {
        guard !codeInfo.isEmpty else { return }
        let length = text.utf16.count
        let ranges = segments.isEmpty ? [0..<length] : segments.filter { $0.kind == .code }.map(\.range)
        guard ranges.count == codeInfo.count else { return }
        var tokens: [CodeToken] = []
        let utf16 = text.utf16
        var index = utf16.startIndex
        var indexOffset = 0
        for (range, info) in zip(ranges, codeInfo) where !range.isEmpty && range.count <= Self.highlightLimit {
            let code: String
            if range == 0..<length {
                code = text
            } else {
                let start = utf16.index(index, offsetBy: range.lowerBound - indexOffset)
                index = utf16.index(start, offsetBy: range.count)
                indexOffset = range.upperBound
                code = String(Substring(utf16[start..<index]))
            }
            guard let found = highlighter.tokens(for: code, info: info), !found.isEmpty else { continue }
            for token in Self.clipped(found, to: code, length: range.count) {
                tokens.append(CodeToken(range: (token.range.lowerBound + range.lowerBound)..<(token.range.upperBound + range.lowerBound),
                                        kind: token.kind))
            }
        }
        guard !tokens.isEmpty else { return }
        styleRuns = Self.split(styleRuns, at: tokens)
    }

    /// `tokens` of `code` (`length` UTF-16 units) in order, clipped to it and
    /// to scalar boundaries, without empty tokens or tokens that overlap an
    /// earlier one.
    static func clipped(_ tokens: [CodeToken], to code: String, length: Int) -> [CodeToken] {
        var tokens = tokens
        if !tokens.indices.dropFirst().allSatisfy({ tokens[$0 - 1].range.lowerBound <= tokens[$0].range.lowerBound }) {
            tokens = tokens.enumerated().sorted {
                ($0.element.range.lowerBound, $0.offset) < ($1.element.range.lowerBound, $1.offset)
            }.map(\.element)
        }
        // Only text with characters outside the Basic Multilingual Plane has
        // offsets inside a surrogate pair.
        let units = code.utf8.contains(where: { $0 >= 0xF0 }) ? Array(code.utf16) : []
        func isInsidePair(_ offset: Int) -> Bool {
            !units.isEmpty && offset > 0 && offset < units.count && UTF16.isTrailSurrogate(units[offset])
        }
        var result: [CodeToken] = []
        result.reserveCapacity(tokens.count)
        var end = 0
        for token in tokens {
            var lower = max(token.range.lowerBound, 0)
            var upper = min(token.range.upperBound, length)
            if isInsidePair(lower) { lower += 1 }
            if isInsidePair(upper) { upper -= 1 }
            guard lower < upper else { continue }
            guard lower >= end else { continue }
            result.append(CodeToken(range: lower..<upper, kind: token.kind))
            end = upper
        }
        return result
    }

    /// `runs` split at `tokens` (in order, not overlapping), the code text
    /// inside each token taking its kind. Pieces that end up alike merge.
    static func split(_ runs: [StyleRun], at tokens: [CodeToken]) -> [StyleRun] {
        var result: [StyleRun] = []
        result.reserveCapacity(runs.count + 2 * tokens.count)
        func append(_ run: StyleRun, _ range: Range<Int>, _ token: CodeTokenKind?) {
            guard !range.isEmpty else { return }
            if let last = result.last, last.range.upperBound == range.lowerBound, last.role == run.role,
               last.styles == run.styles, last.token == token {
                result[result.count - 1].range = last.range.lowerBound..<range.upperBound
            } else {
                result.append(StyleRun(range: range, role: run.role, styles: run.styles, token: token))
            }
        }
        var next = 0
        for run in runs {
            var start = run.range.lowerBound
            while next < tokens.count, tokens[next].range.upperBound <= start { next += 1 }
            while next < tokens.count, tokens[next].range.lowerBound < run.range.upperBound {
                let token = tokens[next]
                let lower = max(start, token.range.lowerBound)
                let upper = min(token.range.upperBound, run.range.upperBound)
                append(run, start..<lower, run.token)
                append(run, lower..<upper, run.role == .code ? token.kind : run.token)
                start = upper
                // A token running on past this run continues in the next.
                if token.range.upperBound > run.range.upperBound { break }
                next += 1
            }
            append(run, start..<run.range.upperBound, run.token)
        }
        return result
    }
}
