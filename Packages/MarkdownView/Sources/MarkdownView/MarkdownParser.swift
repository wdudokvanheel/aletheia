import cmark_gfm
import cmark_gfm_extensions
import Darwin

/// Bridge to cmark-gfm with exactly the extensions the renderer supports.
enum MarkdownParser {
    static let extensionNames = ["table", "strikethrough", "tasklist", "autolink"]

    /// Parses UTF-8 Markdown with source positions into top-level blocks.
    static func blocks(utf8 bytes: UnsafeBufferPointer<UInt8>) throws -> [MarkdownBlock] {
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
        var blocks: [MarkdownBlock] = []
        var node = cmark_node_first_child(document)
        while let block = node {
            let start = lines.offsets(bytes, line: cmark_node_get_start_line(block),
                                      byteInLine: Int(cmark_node_get_start_column(block)) - 1)
            var end = lines.offsets(bytes, line: cmark_node_get_end_line(block),
                                    byteInLine: Int(cmark_node_get_end_column(block)))
            if end.utf8 < start.utf8 { end = start }
            let kind = Self.kind(of: block)
            var display = DisplayText()
            if kind != .htmlBlock { display.append(block) }
            blocks.append(MarkdownBlock(
                kind: kind,
                sourceRange: start.utf16..<end.utf16,
                sourceText: String(decoding: UnsafeBufferPointer(rebasing: bytes[start.utf8..<end.utf8]), as: UTF8.self),
                text: String(decoding: display.bytes, as: UTF8.self),
                styleRuns: display.runs
            ))
            node = cmark_node_next(block)
        }
        return blocks
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

/// The GFM table nodes, whose type values cmark assigns at registration time.
private enum ExtensionNode {
    case table, row, cell

    init?(_ node: UnsafeMutablePointer<cmark_node>) {
        guard let name = cmark_node_get_type_string(node) else { return nil }
        if strcmp(name, "table_cell") == 0 { self = .cell }
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

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
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

/// UTF-16 units contributed by one UTF-8 byte: lead bytes count, and 4-byte
/// sequences become surrogate pairs.
@inline(__always)
private func utf16Width(_ byte: UInt8) -> Int {
    byte & 0xC0 == 0x80 ? 0 : (byte >= 0xF0 ? 2 : 1)
}

/// Builds a block's plain display text and role runs from its cmark subtree.
private struct DisplayText {
    var bytes: [UInt8] = []
    var runs: [StyleRun] = []
    private var utf16Count = 0
    private var role = TextRole.body
    private var quoteDepth = 0

    mutating func append(_ root: UnsafeMutablePointer<cmark_node>) {
        guard let iterator = cmark_iter_new(root) else { return }
        defer { cmark_iter_free(iterator) }
        while true {
            let event = cmark_iter_next(iterator)
            guard event != CMARK_EVENT_DONE else { break }
            guard let node = cmark_iter_get_node(iterator) else { continue }
            let type = cmark_node_get_type(node)
            if type == CMARK_NODE_BLOCK_QUOTE {
                quoteDepth += event == CMARK_EVENT_ENTER ? 1 : -1
                continue
            }
            // Leaf nodes only get an enter event; container exits need no work.
            guard event == CMARK_EVENT_ENTER else { continue }
            switch type {
            case CMARK_NODE_PARAGRAPH:
                separate()
                role = quoteDepth > 0 ? .quote : .body
            case CMARK_NODE_HEADING:
                separate()
                role = .heading(Int(cmark_node_get_heading_level(node)))
            case CMARK_NODE_CODE_BLOCK:
                separate()
                role = .code
                appendLiteral(node, droppingTrailingNewline: true)
            case CMARK_NODE_TEXT, CMARK_NODE_CODE:
                appendLiteral(node, droppingTrailingNewline: false)
            case CMARK_NODE_SOFTBREAK:
                appendByte(0x20)
            case CMARK_NODE_LINEBREAK:
                appendByte(0x0A)
            case CMARK_NODE_DOCUMENT, CMARK_NODE_LIST, CMARK_NODE_ITEM, CMARK_NODE_THEMATIC_BREAK,
                 CMARK_NODE_HTML_BLOCK, CMARK_NODE_HTML_INLINE, CMARK_NODE_EMPH, CMARK_NODE_STRONG,
                 CMARK_NODE_LINK, CMARK_NODE_IMAGE:
                // Raw HTML is dropped; links and images contribute their text
                // (an image's children are its alt text).
                break
            default:
                switch ExtensionNode(node) {
                case .table: role = quoteDepth > 0 ? .quote : .body
                case .row: separate()
                case .cell: if cmark_node_previous(node) != nil { appendByte(0x09) }
                case nil: break
                }
            }
        }
    }

    /// Starts a new line before a block after the first, keeping the newline
    /// in the previous role so it does not change that line's metrics.
    private mutating func separate() {
        if !bytes.isEmpty { appendByte(0x0A) }
    }

    private mutating func appendByte(_ byte: UInt8) {
        bytes.append(byte)
        extendRun(by: 1)
    }

    private mutating func appendLiteral(_ node: UnsafeMutablePointer<cmark_node>, droppingTrailingNewline: Bool) {
        guard let literal = cmark_node_get_literal(node) else { return }
        var length = strlen(literal)
        if droppingTrailingNewline, length > 0, literal[length - 1] == 0x0A { length -= 1 }
        guard length > 0 else { return }
        var units = 0
        literal.withMemoryRebound(to: UInt8.self, capacity: length) { pointer in
            let buffer = UnsafeBufferPointer(start: pointer, count: length)
            bytes.append(contentsOf: buffer)
            for byte in buffer { units += utf16Width(byte) }
        }
        extendRun(by: units)
    }

    private mutating func extendRun(by units: Int) {
        let start = utf16Count
        utf16Count += units
        if let last = runs.last, last.role == role, last.range.upperBound == start {
            runs[runs.count - 1].range = last.range.lowerBound..<utf16Count
        } else {
            runs.append(StyleRun(range: start..<utf16Count, role: role))
        }
    }
}
