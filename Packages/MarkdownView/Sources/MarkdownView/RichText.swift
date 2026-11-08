import AppKit
import Synchronization

/// Rich copies of a selection, for pasting into Mail or Pages: an attributed
/// string for RTF and an HTML fragment. Both follow the plain-text rules:
/// blocks in order, no list markers or task boxes, images as their alt text,
/// and in RTF table cells separated by tabs. HTML adds headings, paragraphs,
/// preformatted code, and tables. Links keep their destinations only for
/// web and mail addresses; other link text stays plain. Colors are left to
/// the receiving app.
extension MarkdownSnapshot {
    /// One stretch of selected text with a single role, styles, and link.
    private struct Piece {
        var text: String
        var role: TextRole
        var styles: InlineStyle
        var link: URL?
    }

    /// The selected display range of each selected block with text.
    private func selectedBlocks(in range: Range<TextPosition>) -> [(index: Int, range: Range<Int>)] {
        guard range.lowerBound.block < layouts.count else { return [] }
        return (range.lowerBound.block...min(range.upperBound.block, layouts.count - 1)).compactMap { index in
            guard isSelectable(index) else { return nil }
            let length = layouts[index].textLength
            let start = index == range.lowerBound.block ? min(range.lowerBound.offset, length) : 0
            let end = index == range.upperBound.block ? min(range.upperBound.offset, length) : length
            return (index, start..<max(start, end))
        }
    }

    /// The pieces of `range` in block `index`, split where the style run or
    /// link changes, without the placeholders of images without alt text.
    private func pieces(inBlock index: Int, _ range: Range<Int>) -> [Piece] {
        let block = document.blocks[index]
        let text = block.text as NSString
        var pieces: [Piece] = []
        var offset = range.lowerBound
        var run = BlockLayout.styleRunIndex(in: block.styleRuns, at: offset)
        while offset < range.upperBound {
            let style = run < block.styleRuns.count ? block.styleRuns[run]
                : StyleRun(range: offset..<range.upperBound, role: .body)
            var end = min(style.range.upperBound, range.upperBound)
            var link: URL?
            let next = BlockLayout.firstLink(in: block.links[...], endingAfter: offset)
            if next < block.links.count {
                let candidate = block.links[next]
                if candidate.range.lowerBound <= offset {
                    end = min(end, candidate.range.upperBound)
                    link = Self.copiedLink(candidate.destination)
                } else {
                    end = min(end, candidate.range.lowerBound)
                }
            }
            end = max(end, offset + 1)
            var piece = text.substring(with: NSRange(location: offset, length: end - offset))
            if !block.images.isEmpty { piece = piece.replacingOccurrences(of: "\u{FFFC}", with: "") }
            if !piece.isEmpty {
                pieces.append(Piece(text: piece, role: style.role, styles: style.styles.subtracting([.image, .quoted]),
                                    link: link))
            }
            offset = end
            if offset >= style.range.upperBound { run += 1 }
        }
        return pieces
    }

    /// A link destination worth keeping outside the preview: web and mail
    /// addresses only, as the preview itself opens no others there.
    private static func copiedLink(_ destination: String) -> URL? {
        guard let url = URL(string: destination), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    // MARK: RTF

    /// The selection with fonts by role and style (headings, bold, italic,
    /// monospaced code), strikethrough, and links: the plain text of
    /// `text(in:)` with attributes.
    func attributedText(in range: Range<TextPosition>) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let separator = NSAttributedString(string: "\n", attributes: [.font: typography.font(.body, []) as NSFont])
        for (number, selected) in selectedBlocks(in: range).enumerated() {
            if number > 0 { result.append(separator) }
            for piece in pieces(inBlock: selected.index, selected.range) {
                var attributes: [NSAttributedString.Key: Any] = [.font: copiedFont(piece.role, piece.styles)]
                if piece.styles.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if let link = piece.link { attributes[.link] = link }
                result.append(NSAttributedString(string: piece.text, attributes: attributes))
            }
        }
        return result
    }

    /// The view's font for a role and styles, except that code uses Menlo:
    /// RTF names fonts, and other apps cannot find the system's monospaced
    /// font by its private name. (The system font is written as Helvetica
    /// Neue.)
    private func copiedFont(_ role: TextRole, _ styles: InlineStyle) -> NSFont {
        let font = typography.font(role, styles)
        guard role == .code || styles.contains(.code) else { return font as NSFont }
        let traits = CTFontGetSymbolicTraits(font).intersection([.traitBold, .traitItalic])
        let menlo = CTFontCreateWithName("Menlo-Regular" as CFString, CTFontGetSize(font), nil)
        return (CTFontCreateCopyWithSymbolicTraits(menlo, 0, nil, traits, traits) ?? menlo) as NSFont
    }

    /// `attributedText(in:)` as RTF.
    func rtf(in range: Range<TextPosition>) -> Data? {
        let text = attributedText(in: range)
        return text.rtf(from: NSRange(location: 0, length: text.length),
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    // MARK: HTML

    /// The selection as an HTML document: a heading, paragraph, or `pre`
    /// per selected leaf block, inline `strong`, `em`, `del`, `code`, and
    /// `a`, and a `table` for cells of more than one cell; a selection
    /// inside one cell is a paragraph.
    func html(in range: Range<TextPosition>) -> String {
        var html = "<html><head><meta charset=\"utf-8\"></head><body>"
        for selected in selectedBlocks(in: range) {
            let block = document.blocks[selected.index]
            let segments = block.segments.isEmpty
                ? BlockLayoutBuilder.segments(of: block, textLength: layouts[selected.index].textLength) : block.segments
            var table = 0
            for segment in segments {
                if segment.kind == .table { table += 1 }
                let part = segment.range.clamped(to: selected.range)
                guard !part.isEmpty else { continue }
                switch segment.kind {
                case .heading:
                    let level = min(max(Int(segment.level), 1), 6)
                    html += "<h\(level)>" + inlineHTML(inBlock: selected.index, part) + "</h\(level)>"
                case .code:
                    let text = (block.text as NSString).substring(with: NSRange(location: part.lowerBound, length: part.count))
                    html += "<pre><code>" + Self.escaped(text) + "</code></pre>"
                case .table where table - 1 < block.tables.count:
                    html += tableHTML(block.tables[table - 1], inBlock: selected.index, part)
                case .paragraph, .table:
                    html += "<p>" + inlineHTML(inBlock: selected.index, part) + "</p>"
                case .rule, .emptyItem:
                    break
                }
            }
        }
        return html + "</body></html>"
    }

    /// The cells of `table` that `range` covers, clipped to it, in rows; a
    /// header row's cells are `th`, aligned as the table says.
    private func tableHTML(_ table: TableStructure, inBlock index: Int, _ range: Range<Int>) -> String {
        guard let first = table.cell(containing: range.lowerBound), let last = table.cell(containing: range.upperBound - 1)
        else { return "" }
        if first == last { return "<p>" + inlineHTML(inBlock: index, range) + "</p>" }
        var html = "<table>"
        for row in first.row...last.row {
            html += "<tr>"
            for column in 0..<table.columnCount {
                let cell = table.cell(row, column)
                guard cell.upperBound >= range.lowerBound, cell.lowerBound <= range.upperBound else { continue }
                let tag = table.hasHeader && row == 0 ? "th" : "td"
                let align = switch table.alignments[column] {
                case .none: ""
                case .left: " align=\"left\""
                case .center: " align=\"center\""
                case .right: " align=\"right\""
                }
                html += "<\(tag)\(align)>" + inlineHTML(inBlock: index, cell.clamped(to: range)) + "</\(tag)>"
            }
            html += "</tr>"
        }
        return html + "</table>"
    }

    /// The pieces of `range` with their inline markup; line breaks become `br`.
    private func inlineHTML(inBlock index: Int, _ range: Range<Int>) -> String {
        var html = ""
        for piece in pieces(inBlock: index, range) {
            var text = Self.escaped(piece.text).replacingOccurrences(of: "\n", with: "<br>")
            for (style, tag) in [(InlineStyle.code, "code"), (.strikethrough, "del"), (.emphasis, "em"),
                                 (.strong, "strong")] where piece.styles.contains(style) {
                text = "<\(tag)>" + text + "</\(tag)>"
            }
            if let link = piece.link { text = "<a href=\"" + Self.escaped(link.absoluteString) + "\">" + text + "</a>" }
            html += text
        }
        return html
    }

    private static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text.unicodeScalars {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.unicodeScalars.append(character)
            }
        }
        return result
    }
}

/// Provides the rich flavors of a copied or dragged selection only when a
/// receiver asks for them, from the snapshot it was made from, so copying
/// costs only the plain text on the main thread.
final class RichTextProvider: NSObject, NSPasteboardItemDataProvider, Sendable {
    static let types: [NSPasteboard.PasteboardType] = [.rtf, .html]

    let snapshot: MarkdownSnapshot
    let range: Range<TextPosition>

    /// Providers a pasteboard may still ask, kept until it says it is done.
    private static let live = Mutex<[RichTextProvider]>([])

    init(snapshot: MarkdownSnapshot, range: Range<TextPosition>) {
        self.snapshot = snapshot
        self.range = range
    }

    /// A pasteboard item with the plain text now and the rich flavors on
    /// demand.
    static func item(for snapshot: MarkdownSnapshot, range: Range<TextPosition>) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(snapshot.text(in: range), forType: .string)
        let provider = RichTextProvider(snapshot: snapshot, range: range)
        if item.setDataProvider(provider, forTypes: types) { live.withLock { $0.append(provider) } }
        return item
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .rtf:
            if let data = snapshot.rtf(in: range) { item.setData(data, forType: .rtf) }
        case .html:
            item.setString(snapshot.html(in: range), forType: .html)
        default:
            break
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        Self.live.withLock { $0.removeAll { $0 === self } }
    }
}
