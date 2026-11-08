import cmark_gfm
import cmark_gfm_extensions
import Darwin
import Dispatch

/// Bridge to cmark-gfm with exactly the extensions the renderer supports.
enum MarkdownParser {
    static let extensionNames = ["table", "strikethrough", "tasklist", "autolink"]

    /// A top-level block as cmark positions it, before its display content
    /// is built.
    private struct Span {
        let node: UnsafeMutablePointer<cmark_node>
        let kind: MarkdownBlock.Kind
        let start: (utf8: Int, utf16: Int)
        let end: (utf8: Int, utf16: Int)
        /// The UTF-8 offset of the start of the block's first line.
        let lineStart: Int
        /// False for blocks cmark gives no source position, which never match.
        var isPositioned = true

        var text: Range<Int> { start.utf8..<end.utf8 }
        var indentation: Range<Int> { lineStart..<start.utf8 }
    }

    /// Parses UTF-8 Markdown with source positions into top-level blocks.
    /// Blocks equal to one of `previous` (same kind, indentation, and source
    /// text) take its display content instead of building it again, as long
    /// as both have the same link reference definitions.
    static func parse(utf8 bytes: UnsafeBufferPointer<UInt8>,
                      previous: MarkdownDocument?) throws -> MarkdownDocument.ParseResult {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_SOURCEPOS) else { throw MarkdownError.parserUnavailable }
        defer { cmark_parser_free(parser) }
        for name in extensionNames {
            guard let syntaxExtension = cmark_find_syntax_extension(name) else {
                throw MarkdownError.extensionUnavailable(name)
            }
            cmark_parser_attach_syntax_extension(parser, syntaxExtension)
        }
        bytes.withMemoryRebound(to: CChar.self) { cmark_parser_feed(parser, $0.baseAddress, $0.count) }
        guard let document = cmark_parser_finish(parser) else { throw MarkdownError.parserUnavailable }
        defer { cmark_node_free(document) }

        let lines = LineIndex(bytes)
        var spans: [Span] = []
        var node = cmark_node_first_child(document)
        while let block = node {
            node = cmark_node_next(block)
            let startLine = cmark_node_get_start_line(block)
            guard startLine > 0, cmark_node_get_end_line(block) > 0 else {
                // The table extension splits text before a header row into a
                // paragraph without a position. An empty range where the
                // previous block ends keeps ranges in source order.
                let at = spans.last?.end ?? (utf8: 0, utf16: 0)
                var span = Span(node: block, kind: Self.kind(of: block), start: at, end: at, lineStart: at.utf8)
                span.isPositioned = false
                spans.append(span)
                continue
            }
            let start = lines.offsets(bytes, line: startLine, byteInLine: Int(cmark_node_get_start_column(block)) - 1)
            var end = lines.offsets(bytes, line: cmark_node_get_end_line(block),
                                    byteInLine: Int(cmark_node_get_end_column(block)))
            if end.utf8 < start.utf8 { end = start }
            spans.append(Span(node: block, kind: Self.kind(of: block), start: start, end: end,
                              lineStart: min(lines.utf8Start(ofLine: startLine) ?? start.utf8, start.utf8)))
        }

        let definitions = Self.definitions(in: bytes, spans: spans)
        var match: BlockMatch?
        if let previous, let old = previous.definitions, old == definitions {
            match = BlockMatch(oldCount: previous.blocks.count, newCount: spans.count,
                               equal: { isEqual(previous.blocks[$0], spans[$1], bytes) },
                               oldHash: { hash(previous.blocks[$0]) },
                               newHash: { hash(spans[$0], bytes) })
        }

        // Blocks the diff did not match get their display content built,
        // in parallel when there are several: each walks only its own
        // subtree, and the only thing cmark changes during a walk is the
        // cached C string of a node in that subtree.
        let unmatched = spans.indices.filter { match?.oldIndex(ofNew: $0) == nil }
        let built = UnsafeMutableBufferPointer<MarkdownBlock>.allocate(capacity: unmatched.count)
        defer { built.deallocate() }
        let context = BuildContext(bytes: bytes, lines: lines, spans: spans, unmatched: unmatched, built: built)
        if unmatched.count < 8 {
            for slot in unmatched.indices { context.build(slot) }
        } else {
            DispatchQueue.concurrentPerform(iterations: unmatched.count) { context.build($0) }
        }
        var blocks: [MarkdownBlock] = []
        blocks.reserveCapacity(spans.count)
        var slot = 0
        for (index, span) in spans.enumerated() {
            if let previous, let old = match?.oldIndex(ofNew: index) {
                var block = previous.blocks[old]
                block.sourceRange = span.start.utf16..<span.end.utf16
                blocks.append(block)
            } else {
                blocks.append(built.moveElement(from: slot))
                slot += 1
            }
        }
        return MarkdownDocument.ParseResult(
            document: MarkdownDocument(blocks: blocks, sourceUTF16Count: lines.utf16Count, definitions: definitions),
            match: match,
            edit: sourceEdit(from: previous, to: bytes, lines: lines))
    }

    /// What building display content needs, shared read-only across
    /// threads; each slot of `built` is written by one of them.
    private struct BuildContext: @unchecked Sendable {
        let bytes: UnsafeBufferPointer<UInt8>
        let lines: LineIndex
        let spans: [Span]
        let unmatched: [Int]
        let built: UnsafeMutableBufferPointer<MarkdownBlock>

        func build(_ slot: Int) {
            (built.baseAddress! + slot).initialize(to: MarkdownParser.block(for: spans[unmatched[slot]], bytes, lines))
        }
    }

    /// A block's display text, style runs, links, and source map, from its
    /// cmark subtree.
    private static func block(for span: Span, _ bytes: UnsafeBufferPointer<UInt8>, _ lines: LineIndex) -> MarkdownBlock {
        let sourceRange = span.start.utf16..<span.end.utf16
        var display = DisplayText(source: bytes, lines: lines, start: span.start, end: span.end.utf8)
        if span.kind != .htmlBlock { display.append(span.node) }
        var block = MarkdownBlock(
            kind: span.kind,
            sourceRange: sourceRange,
            sourceText: String(decoding: UnsafeBufferPointer(rebasing: bytes[span.text]), as: UTF8.self),
            text: String(decoding: display.bytes, as: UTF8.self),
            styleRuns: display.runs,
            links: display.links,
            sourceMap: SourceMap(anchors: display.anchors, displayLength: display.utf16Count,
                                 sourceLength: sourceRange.count)
        )
        if !span.indentation.isEmpty {
            block.indentation = String(decoding: UnsafeBufferPointer(rebasing: bytes[span.indentation]), as: UTF8.self)
        }
        return block
    }

    // MARK: Diffing

    /// Every part of the source that can hold a link reference definition,
    /// concatenated: text between top-level blocks that is not whitespace
    /// (definitions alone in a paragraph leave no block), and blocks whose
    /// source contains `]:`, which every definition does. Code and HTML
    /// blocks cannot hold definitions.
    private static func definitions(in bytes: UnsafeBufferPointer<UInt8>, spans: [Span]) -> [UInt8] {
        var key: [UInt8] = []
        func add(_ range: Range<Int>) {
            key.append(contentsOf: bytes[range])
            key.append(0)
        }
        func addGap(_ range: Range<Int>) {
            let isBlank = bytes[range].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
            if !isBlank { add(range) }
        }
        var cursor = 0
        for span in spans {
            if cursor < span.start.utf8 { addGap(cursor..<span.start.utf8) }
            if span.kind != .codeBlock, span.kind != .htmlBlock, contains(bytes, span.text, "]:") { add(span.text) }
            cursor = max(cursor, span.end.utf8)
        }
        if cursor < bytes.count { addGap(cursor..<bytes.count) }
        return key
    }

    private static func contains(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, _ needle: StaticString) -> Bool {
        guard range.count >= needle.utf8CodeUnitCount, let base = bytes.baseAddress else { return false }
        return memmem(base + range.lowerBound, range.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    private static func isEqual(_ block: MarkdownBlock, _ span: Span, _ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let text = span.text
        guard span.isPositioned, !text.isEmpty, block.sourceText.utf8.count == text.count, block.kind == span.kind,
              block.indentation.utf8.elementsEqual(bytes[span.indentation]) else { return false }
        guard let base = bytes.baseAddress else { return false }
        var sourceText = block.sourceText
        return sourceText.withUTF8 { memcmp($0.baseAddress, base + text.lowerBound, text.count) == 0 }
    }

    /// Hashes indentation and source text the same way for old and new blocks.
    private static func hash(_ block: MarkdownBlock) -> Int {
        var hasher = Hasher()
        var indentation = block.indentation
        var sourceText = block.sourceText
        indentation.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        sourceText.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        return hasher.finalize()
    }

    private static func hash(_ span: Span, _ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var hasher = Hasher()
        hasher.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: bytes[span.indentation])))
        hasher.combine(bytes: UnsafeRawBufferPointer(UnsafeBufferPointer(rebasing: bytes[span.text])))
        return hasher.finalize()
    }

    /// The span that changed since `previous`: everything between the
    /// longest common prefix and suffix of the two sources, on scalar
    /// boundaries.
    private static func sourceEdit(from previous: MarkdownDocument?, to bytes: UnsafeBufferPointer<UInt8>,
                                   lines: LineIndex) -> SourceEdit {
        guard var old = previous?.source, !old.isEmpty, let oldCount = previous?.sourceUTF16Count else {
            return SourceEdit(old: 0..<(previous?.sourceUTF16Count ?? 0), new: 0..<lines.utf16Count)
        }
        return old.withUTF8 { old in
            var prefix = commonPrefixLength(old, bytes)
            while prefix > 0, (prefix < bytes.count && isContinuation(bytes[prefix]))
                    || (prefix < old.count && isContinuation(old[prefix])) {
                prefix -= 1
            }
            var suffix = commonSuffixLength(old, bytes, limit: min(old.count, bytes.count) - prefix)
            while suffix > 0, isContinuation(bytes[bytes.count - suffix]) { suffix -= 1 }
            let start = lines.utf16Offset(ofUTF8: prefix)
            let newEnd = lines.utf16Offset(ofUTF8: bytes.count - suffix)
            let oldEnd = oldCount - (lines.utf16Count - newEnd)
            return SourceEdit(old: start..<max(oldEnd, start), new: start..<newEnd)
        }
    }

    private static func kind(of node: UnsafeMutablePointer<cmark_node>) -> MarkdownBlock.Kind {
        switch cmark_node_get_type(node) {
        case CMARK_NODE_PARAGRAPH: .paragraph
        case CMARK_NODE_HEADING: .heading(level: Int(cmark_node_get_heading_level(node)))
        case CMARK_NODE_CODE_BLOCK: .codeBlock
        case CMARK_NODE_BLOCK_QUOTE: .blockQuote
        case CMARK_NODE_LIST: .list
        case CMARK_NODE_THEMATIC_BREAK: .thematicBreak
        case CMARK_NODE_HTML_BLOCK: .htmlBlock
        default: ExtensionNode(node) == .table ? .table : .other
        }
    }
}

/// The GFM extension nodes, whose type values cmark assigns at registration time.
private enum ExtensionNode {
    case table, row, cell, strikethrough

    init?(_ node: UnsafeMutablePointer<cmark_node>) {
        guard let name = cmark_node_get_type_string(node) else { return nil }
        if strcmp(name, "table_cell") == 0 { self = .cell }
        else if strcmp(name, "strikethrough") == 0 { self = .strikethrough }
        else if strcmp(name, "table_row") == 0 { self = .row }
        else if strcmp(name, "table") == 0 { self = .table }
        else { return nil }
    }
}

/// Line starts in UTF-8 and UTF-16 units, for converting cmark's 1-based line
/// and byte-column positions to UTF-16 offsets. Lines end at LF, CR, or CRLF,
/// as in cmark.
private struct LineIndex {
    private var utf8Starts = [0]
    private var utf16Starts = [0]
    private let bytes: UnsafeBufferPointer<UInt8>
    /// The length of the whole source in UTF-16 units.
    private(set) var utf16Count = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
        var utf16 = 0
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            utf16 += utf16Width(byte)
            if byte == 0x0A || (byte == 0x0D && (index == bytes.count || bytes[index] != 0x0A)) {
                utf8Starts.append(index)
                utf16Starts.append(utf16)
            }
        }
        utf16Count = utf16
    }

    /// The UTF-16 offset of a UTF-8 offset on a scalar boundary.
    func utf16Offset(ofUTF8 target: Int) -> Int {
        var low = 0
        var high = utf8Starts.count
        while low < high {
            let mid = (low + high) / 2
            if utf8Starts[mid] <= target { low = mid + 1 } else { high = mid }
        }
        let line = max(low - 1, 0)
        var utf16 = utf16Starts[line]
        for index in utf8Starts[line]..<min(target, bytes.count) { utf16 += utf16Width(bytes[index]) }
        return utf16
    }

    /// The UTF-8 offset of a 1-based line's start, or nil past the last line.
    func utf8Start(ofLine line: Int32) -> Int? {
        line >= 1 && Int(line) <= utf8Starts.count ? utf8Starts[Int(line) - 1] : nil
    }

    func offsets(_ bytes: UnsafeBufferPointer<UInt8>, line: Int32, byteInLine: Int) -> (utf8: Int, utf16: Int) {
        let line = min(max(Int(line) - 1, 0), utf8Starts.count - 1)
        let lineStart = utf8Starts[line]
        let target = min(max(lineStart + byteInLine, lineStart), bytes.count)
        var utf16 = utf16Starts[line]
        for index in lineStart..<target { utf16 += utf16Width(bytes[index]) }
        return (target, utf16)
    }
}

@inline(__always)
private func isContinuation(_ byte: UInt8) -> Bool { byte & 0xC0 == 0x80 }

/// The length of the UTF-8 sequence a lead byte starts.
@inline(__always)
private func utf8Length(_ byte: UInt8) -> Int {
    byte < 0xC0 ? 1 : byte < 0xE0 ? 2 : byte < 0xF0 ? 3 : 4
}

@inline(__always)
private func isASCIIPunctuation(_ byte: UInt8) -> Bool {
    (0x21...0x2F).contains(byte) || (0x3A...0x40).contains(byte) || (0x5B...0x60).contains(byte)
        || (0x7B...0x7E).contains(byte)
}

/// UTF-16 units contributed by one UTF-8 byte: lead bytes count, and 4-byte
/// sequences become surrogate pairs.
@inline(__always)
private func utf16Width(_ byte: UInt8) -> Int {
    byte & 0xC0 == 0x80 ? 0 : (byte >= 0xF0 ? 2 : 1)
}

/// Builds a block's plain display text, style runs, links, and source map
/// from its cmark subtree.
private struct DisplayText {
    var bytes: [UInt8] = []
    var runs: [StyleRun] = []
    var links: [MarkdownLink] = []
    var anchors: [SourceMap.Anchor] = []
    private(set) var utf16Count = 0
    private var role = TextRole.body
    private var styles: InlineStyle = []
    private var quoteDepth = 0
    private var emphasisDepth = 0
    private var strongDepth = 0
    private var strikethroughDepth = 0
    /// Links nest only through image descriptions; the outermost one counts.
    private var linkDepth = 0
    private var linkStart = 0
    private var linkDestination = ""

    /// The whole document and the block's UTF-8 range in it.
    private let source: UnsafeBufferPointer<UInt8>
    private let lines: LineIndex
    private let blockStart: (utf8: Int, utf16: Int)
    private let blockEnd: Int
    /// Source before this UTF-8 offset is already mapped.
    private var cursor: Int
    /// A UTF-8 offset and its UTF-16 offset, for converting forward.
    private var converted: (utf8: Int, utf16: Int)

    init(source: UnsafeBufferPointer<UInt8>, lines: LineIndex, start: (utf8: Int, utf16: Int), end: Int) {
        self.source = source
        self.lines = lines
        blockStart = start
        blockEnd = max(end, start.utf8)
        cursor = start.utf8
        converted = start
    }

    mutating func append(_ root: UnsafeMutablePointer<cmark_node>) {
        guard let iterator = cmark_iter_new(root) else { return }
        defer { cmark_iter_free(iterator) }
        while true {
            let event = cmark_iter_next(iterator)
            guard event != CMARK_EVENT_DONE else { break }
            guard let node = cmark_iter_get_node(iterator) else { continue }
            // Leaf nodes only get an enter event; containers get both.
            let entering = event == CMARK_EVENT_ENTER
            let step = entering ? 1 : -1
            switch cmark_node_get_type(node) {
            case CMARK_NODE_BLOCK_QUOTE:
                quoteDepth += step
            case CMARK_NODE_EMPH:
                emphasisDepth += step
                updateStyles()
            case CMARK_NODE_STRONG:
                strongDepth += step
                updateStyles()
            case CMARK_NODE_LINK:
                linkDepth += step
                if entering, linkDepth == 1 {
                    linkStart = utf16Count
                    linkDestination = cmark_node_get_url(node).map { String(cString: $0) } ?? ""
                } else if !entering, linkDepth == 0, linkStart < utf16Count {
                    links.append(MarkdownLink(range: linkStart..<utf16Count, destination: linkDestination))
                }
                updateStyles()
            case CMARK_NODE_PARAGRAPH:
                guard entering else { break }
                separate()
                role = quoteDepth > 0 ? .quote : .body
            case CMARK_NODE_HEADING:
                guard entering else { break }
                separate()
                role = .heading(Int(cmark_node_get_heading_level(node)))
            case CMARK_NODE_CODE_BLOCK:
                separate()
                role = .code
                appendCodeBlock(node)
            case CMARK_NODE_TEXT:
                appendLiteral(node, isCode: false)
            case CMARK_NODE_CODE:
                appendLiteral(node, isCode: true)
            case CMARK_NODE_SOFTBREAK:
                appendByte(0x20)
            case CMARK_NODE_LINEBREAK:
                appendByte(0x0A)
            case CMARK_NODE_DOCUMENT, CMARK_NODE_LIST, CMARK_NODE_ITEM, CMARK_NODE_THEMATIC_BREAK,
                 CMARK_NODE_HTML_BLOCK, CMARK_NODE_HTML_INLINE, CMARK_NODE_IMAGE:
                // Raw HTML is dropped and the text between tags kept; images
                // contribute their alt text, which is their children.
                break
            default:
                switch ExtensionNode(node) {
                case .strikethrough:
                    strikethroughDepth += step
                    updateStyles()
                case .table where entering: role = quoteDepth > 0 ? .quote : .body
                case .row where entering: separate()
                case .cell where entering: if cmark_node_previous(node) != nil { appendByte(0x09) }
                default: break
                }
            }
        }
    }

    private mutating func updateStyles() {
        var styles: InlineStyle = []
        if emphasisDepth > 0 { styles.insert(.emphasis) }
        if strongDepth > 0 { styles.insert(.strong) }
        if strikethroughDepth > 0 { styles.insert(.strikethrough) }
        if linkDepth > 0 { styles.insert(.link) }
        self.styles = styles
    }

    /// Starts a new line before a block after the first, keeping the newline
    /// in the previous role so it does not change that line's metrics.
    private mutating func separate() {
        if !bytes.isEmpty { appendByte(0x0A) }
    }

    private mutating func appendByte(_ byte: UInt8) {
        bytes.append(byte)
        extendRun(by: 1, styles: styles)
    }

    private mutating func appendLiteral(_ node: UnsafeMutablePointer<cmark_node>, isCode: Bool) {
        guard let literal = cmark_node_get_literal(node) else { return }
        let length = strlen(literal)
        guard length > 0 else { return }
        literal.withMemoryRebound(to: UInt8.self, capacity: length) { pointer in
            let text = UnsafeBufferPointer(start: pointer, count: length)
            let span = span(of: node)
            if isCode {
                mapCode(text, span: span)
            } else if let span, align(text, from: span.lowerBound, to: span.upperBound) {
                // Mapped piece by piece.
            } else {
                mapBySearch(text)
            }
            append(text, styles: isCode ? styles.union(.code) : styles)
        }
    }

    /// Code block lines are mapped one by one, since containers and fence
    /// indentation strip a prefix from each source line.
    private mutating func appendCodeBlock(_ node: UnsafeMutablePointer<cmark_node>) {
        guard let literal = cmark_node_get_literal(node) else { return }
        var length = strlen(literal)
        if length > 0, literal[length - 1] == 0x0A { length -= 1 }
        guard length > 0 else { return }
        literal.withMemoryRebound(to: UInt8.self, capacity: length) { pointer in
            let text = UnsafeBufferPointer(start: pointer, count: length)
            var lineStart = 0
            while lineStart <= length {
                let lineEnd = text[lineStart...].firstIndex(of: 0x0A) ?? length
                if lineEnd > lineStart { mapBySearch(UnsafeBufferPointer(rebasing: text[lineStart..<lineEnd])) }
                append(UnsafeBufferPointer(rebasing: text[lineStart..<min(lineEnd + 1, length)]), styles: [])
                lineStart = lineEnd + 1
            }
        }
    }

    private mutating func append(_ text: UnsafeBufferPointer<UInt8>, styles: InlineStyle) {
        guard !text.isEmpty else { return }
        bytes.append(contentsOf: text)
        var units = 0
        for byte in text { units += utf16Width(byte) }
        extendRun(by: units, styles: styles)
    }

    private mutating func extendRun(by units: Int, styles: InlineStyle) {
        let start = utf16Count
        utf16Count += units
        if let last = runs.last, last.role == role, last.styles == styles, last.range.upperBound == start {
            runs[runs.count - 1].range = last.range.lowerBound..<utf16Count
        } else {
            runs.append(StyleRun(range: start..<utf16Count, role: role, styles: styles))
        }
    }

    // MARK: Source map

    /// The UTF-8 range cmark reports for an inline node, if it lies in the
    /// unmapped rest of the block.
    private func span(of node: UnsafeMutablePointer<cmark_node>) -> Range<Int>? {
        guard let startLine = lines.utf8Start(ofLine: cmark_node_get_start_line(node)),
              let endLine = lines.utf8Start(ofLine: cmark_node_get_end_line(node)) else { return nil }
        let start = startLine + Int(cmark_node_get_start_column(node)) - 1
        let end = endLine + Int(cmark_node_get_end_column(node))
        guard cursor <= start, start < end, end <= blockEnd else { return nil }
        return start..<end
    }

    /// Anchors a text literal about to be appended by walking it against
    /// its source span. cmark merges adjacent text, so one literal can hold
    /// escapes and entities: each gets an anchor where its source starts and
    /// one after it. False, with nothing anchored, when the source does not
    /// hold the text there, as when cmark's position is off in some
    /// containers and for autolinks.
    private mutating func align(_ text: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Bool {
        var pieces = [(display: 0, utf8: start)]
        var index = 0
        var position = start
        var units = 0
        while index < text.count {
            guard position < end else { return false }
            let byte = source[position]
            if byte == 0x5C, position + 1 < end, isASCIIPunctuation(source[position + 1]),
               text[index] == source[position + 1] {
                // An escape: the backslash is skipped.
                position += 1
                pieces.append((units, position))
            } else if byte == 0x26, let entityEnd = entityEnd(at: position, before: end),
                      !text[index...].starts(with: source[position..<entityEnd]) {
                // An entity decoded to one character.
                pieces.append((units, position))
                let characterEnd = min(index + utf8Length(text[index]), text.count)
                for unit in text[index..<characterEnd] { units += utf16Width(unit) }
                index = characterEnd
                position = entityEnd
                pieces.append((units, position))
                continue
            }
            guard text[index] == source[position] else { return false }
            units += utf16Width(text[index])
            index += 1
            position += 1
        }
        let display = utf16Count
        for piece in pieces {
            addAnchor(display: display + piece.display, source: utf16Offset(ofUTF8: piece.utf8) - blockStart.utf16)
        }
        cursor = position
        return true
    }

    /// Anchors inline code at its text inside the span, past the backticks.
    /// Code that spans lines has its line endings turned into spaces, so it
    /// is anchored where it starts.
    private mutating func mapCode(_ text: UnsafeBufferPointer<UInt8>, span: Range<Int>?) {
        guard let span else { return mapBySearch(text) }
        var location = span.lowerBound
        if let found = find(text, in: span) {
            location = found
        } else {
            while location < span.upperBound, source[location] == 0x60 { location += 1 }
        }
        addAnchor(display: utf16Count, source: utf16Offset(ofUTF8: location) - blockStart.utf16)
        cursor = span.upperBound
    }

    /// Anchors text found verbatim in the source after the last mapped text,
    /// or at that point when it is not found nearby.
    private mutating func mapBySearch(_ text: UnsafeBufferPointer<UInt8>) {
        var location = cursor
        if let found = find(text, in: cursor..<min(blockEnd, cursor + 4096)) {
            location = found
            cursor = found + text.count
        }
        addAnchor(display: utf16Count, source: utf16Offset(ofUTF8: location) - blockStart.utf16)
    }

    /// The end of a character reference starting at `start`: `&name;`,
    /// `&#digits;`, or `&#xhex;`.
    private func entityEnd(at start: Int, before end: Int) -> Int? {
        var position = start + 1
        let limit = min(end, start + 34)
        while position < limit {
            let byte = source[position]
            if byte == 0x3B { return position > start + 1 ? position + 1 : nil }
            guard (byte >= 0x30 && byte <= 0x39) || ((byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A)
                    || (byte == 0x23 && position == start + 1) else { return nil }
            position += 1
        }
        return nil
    }

    private mutating func addAnchor(display: Int, source: Int) {
        var source = source
        if let last = anchors.last {
            source = max(source, Int(last.source))
            // Contiguous with the previous piece: no anchor needed.
            if source - Int(last.source) == display - Int(last.display) { return }
            if Int(last.display) == display { anchors.removeLast() }
        }
        anchors.append(SourceMap.Anchor(display: Int32(clamping: display), source: Int32(clamping: source)))
    }

    /// The first UTF-8 offset in `range` where `text` occurs in the source.
    private func find(_ text: UnsafeBufferPointer<UInt8>, in range: Range<Int>) -> Int? {
        guard !text.isEmpty, range.count >= text.count, let base = source.baseAddress,
              let match = memmem(base + range.lowerBound, range.count, text.baseAddress, text.count) else { return nil }
        return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(match))
    }

    /// Converts forward from the last conversion, so mapping a block stays
    /// linear in its length.
    private mutating func utf16Offset(ofUTF8 target: Int) -> Int {
        if target < converted.utf8 { converted = blockStart }
        var utf16 = converted.utf16
        for index in converted.utf8..<target { utf16 += utf16Width(source[index]) }
        converted = (target, utf16)
        return utf16
    }
}
