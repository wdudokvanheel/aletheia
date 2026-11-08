import CoreText
import Foundation
import XCTest
@testable import MarkdownView

/// Seeded random GFM through parsing, layout, selection, and incremental
/// updates, checking the invariants the Phase 9 sweep checked. A modest
/// number of cases runs by default; `MARKDOWNVIEW_FUZZ_CASES` and
/// `MARKDOWNVIEW_FUZZ_EDITS` scale it up, and `MARKDOWNVIEW_FUZZ_SEED`
/// picks another seed, which a failure names.
final class FuzzTests: XCTestCase {
    private static func setting(_ name: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init) ?? fallback
    }

    private static var seed: UInt64 { UInt64(setting("MARKDOWNVIEW_FUZZ_SEED", 20_261_108)) }

    func testRandomDocumentsKeepTheLayoutInvariants() throws {
        let cases = Self.setting("MARKDOWNVIEW_FUZZ_CASES", 60)
        let widths: [CGFloat] = [1, 120, 375, 700, 1600]
        var failures = 0
        for index in 0..<cases {
            let caseSeed = Self.seed &+ UInt64(index) &* 0x9E37_79B9
            var generator = MarkdownGenerator(seed: caseSeed)
            let text = generator.document()
            let document = try MarkdownDocument.parse(text)
            var random = SplitMix64(seed: caseSeed ^ 0xABCD)
            for width in widths {
                let snapshot = MarkdownSnapshot.layOut(document, width: width)
                let problems = Invariants.check(snapshot, source: text, random: &random)
                if let problem = problems.first {
                    failures += 1
                    XCTFail("seed \(caseSeed) width \(width): \(problem) (\(problems.count) problems)")
                    break
                }
            }
            // Incrementally from nothing, then relaid out at another width.
            let first = try MarkdownSnapshot.updating(.empty, to: text, width: widths[3]).snapshot
            let relaid = try MarkdownSnapshot.updating(first, to: text, width: widths[4]).snapshot
            let full = MarkdownSnapshot.layOut(document, width: widths[4])
            if let difference = Invariants.difference(relaid, full) {
                failures += 1
                XCTFail("seed \(caseSeed): relayout differs from a full layout: \(difference)")
            }
            if failures > 5 { break }
        }
    }

    func testRandomEditsMatchAFullRebuild() throws {
        let steps = Self.setting("MARKDOWNVIEW_FUZZ_EDITS", 150)
        var random = SplitMix64(seed: Self.seed ^ 0xED17)
        var generator = MarkdownGenerator(seed: Self.seed ^ 0xD0C)
        let text = NSMutableString(string: generator.document())
        let widths: [CGFloat] = [700, 320, 1200]
        var snapshot = MarkdownSnapshot.layOut(try MarkdownDocument.parse(text as String), width: widths[0])
        var failures = 0
        for step in 0..<steps {
            if step % 60 == 59 { text.setString(generator.document()) }
            let edit = Self.randomEdit(text, &random)
            text.replaceCharacters(in: NSRange(location: edit.location, length: edit.length), with: edit.replacement)
            let source = text as String
            let width = step % 7 == 6 ? widths[Int(random.next() % 3)] : snapshot.width
            let old = snapshot
            snapshot = try MarkdownSnapshot.updating(snapshot, to: source, width: width).snapshot
            let full = MarkdownSnapshot.layOut(try MarkdownDocument.parse(source), width: width)
            if let difference = Invariants.difference(snapshot, full) {
                failures += 1
                XCTFail("step \(step) edit \(edit): \(difference)")
                snapshot = full
                if failures > 5 { return }
                continue
            }
            guard let update = snapshot.update(from: old), !old.layouts.isEmpty else { continue }
            for _ in 0..<3 {
                let a = Int(random.next() % UInt64(old.layouts.count))
                let b = Int(random.next() % UInt64(old.layouts.count))
                let pa = TextPosition(block: a, offset: Int(random.next() % UInt64(old.layouts[a].textLength + 1)))
                let pb = TextPosition(block: b, offset: Int(random.next() % UInt64(old.layouts[b].textLength + 1)))
                if let mapped = snapshot.mapRange(min(pa, pb)..<max(pa, pb), from: old) {
                    XCTAssertLessThan(mapped.upperBound.block, snapshot.layouts.count)
                    XCTAssertLessThanOrEqual(mapped.upperBound.offset, snapshot.layouts[mapped.upperBound.block].textLength)
                }
                let y = snapshot.anchoredY(CGFloat(random.next() % UInt64(max(old.totalHeight, 1))), from: old,
                                           through: update)
                XCTAssertTrue(y.isFinite && y >= 0, "step \(step): anchored y \(y)")
            }
        }
    }

    private static let editFragments = [
        "a", "word ", " ", "\n", "\n\n", "# ", "## ", "- ", "1. ", "> ", "```", "```\n", "~~~\n", "`", "*", "**", "_",
        "~~", "[", "]", "](https://example.com)", "[ref]", "[ref]: https://example.com/r\n", "|", " | ",
        "\n| a | b |\n| --- | :-: |\n| 1 | 2 |\n", "---\n", "***", "<div>\n", "</div>", "<b>", "    ", "\t", "  ", "é",
        "👍", "日本語", "שלום", "مرحبا", "&amp;", "\\", "- [ ] ", "===\n", "  \n", "\r\n", "\r", "www.example.com",
        "---\nk: v\n---\n", "![i](x.png)", "e\u{301}", "👨‍👩‍👧", "\u{2029}", "\u{0000}", "\u{FEFF}", "| x |", "\n|---|\n",
    ]

    /// One random edit at UTF-16 offsets, which sometimes splits a surrogate
    /// pair, as raw `NSString` edits can.
    private static func randomEdit(_ text: NSString, _ random: inout SplitMix64)
        -> (location: Int, length: Int, replacement: String) {
        let length = text.length
        var location = Int(random.next() % UInt64(length + 1))
        let raw = random.next() % 33 == 0
        if !raw, location > 0, location < length, UTF16.isTrailSurrogate(text.character(at: location)) { location -= 1 }
        let fragment = editFragments[Int(random.next() % UInt64(editFragments.count))]
        switch random.next() % 5 {
        case 0, 1:
            return (location, 0, fragment)
        case 2:
            var count = min(Int(random.next() % 40) + 1, length - location)
            if !raw, location + count < length, UTF16.isTrailSurrogate(text.character(at: location + count)) { count += 1 }
            return (location, max(count, 0), "")
        case 3:
            var count = min(Int(random.next() % 8), length - location)
            if !raw, location + count < length, UTF16.isTrailSurrogate(text.character(at: location + count)) { count += 1 }
            return (location, max(count, 0), fragment)
        default:
            let lineStart = text.lineRange(for: NSRange(location: min(location, max(length - 1, 0)), length: 0)).location
            return (min(lineStart, length), 0, ["# ", "- ", "> ", "| ", "    ", "```\n", "1. "][Int(random.next() % 7)])
        }
    }
}

/// The invariants of a laid-out snapshot, as the sweep checked them.
enum Invariants {
    /// Problems found in `snapshot`, laid out from `source`; empty when none.
    static func check(_ snapshot: MarkdownSnapshot, source: String, random: inout SplitMix64) -> [String] {
        var problems: [String] = []
        func fail(_ problem: @autoclosure () -> String) { if problems.count < 20 { problems.append(problem()) } }
        let units = Array(MarkdownDocument.withoutNUL(MarkdownDocument.contiguousUTF8(source)).utf16)
        let blocks = snapshot.document.blocks
        let layouts = snapshot.layouts
        if !snapshot.totalHeight.isFinite || snapshot.totalHeight < 0 { fail("total height \(snapshot.totalHeight)") }
        if !snapshot.isComplete { fail("not complete") }
        var previousTop = -CGFloat.infinity
        var previousEnd = 0
        for (index, block) in blocks.enumerated() {
            let layout = layouts[index]
            let top = snapshot.blockTops[index]
            if !top.isFinite || top < previousTop { fail("block \(index): top \(top) above \(previousTop)") }
            previousTop = top
            if !layout.height.isFinite || layout.height < 0 { fail("block \(index): height \(layout.height)") }
            let range = block.sourceRange
            if range.lowerBound < previousEnd || range.upperBound > units.count || range.isEmpty && range.lowerBound > units.count {
                fail("block \(index) \(block.kind): source range \(range) after \(previousEnd) of \(units.count)")
            } else if !range.isEmpty, String(decoding: units[range], as: UTF16.self) != block.sourceText {
                fail("block \(index): source text differs from the source at \(range)")
            }
            previousEnd = max(previousEnd, range.upperBound)
            let text = block.text as NSString
            let length = text.length
            if layout.textLength != length { fail("block \(index): text length \(layout.textLength) vs \(length)") }
            if length > 0, let string = BlockLayout.makeText(block), CFStringGetLength(string) != length {
                fail("block \(index): Core Text string length \(CFStringGetLength(string)) vs \(length)")
            }
            var expected = 0
            for run in block.styleRuns {
                if run.range.lowerBound != expected || run.range.isEmpty { fail("block \(index): style run \(run.range)"); break }
                expected = run.range.upperBound
            }
            if length > 0, expected != length { fail("block \(index): style runs end at \(expected) of \(length)") }
            var linkEnd = 0
            for link in block.links where link.range.lowerBound < linkEnd || link.range.upperBound > length || link.range.isEmpty {
                fail("block \(index): link \(link.range)")
                linkEnd = link.range.upperBound
            }
            for image in block.images where image.range.upperBound > length || image.range.isEmpty {
                fail("block \(index): image \(image.range)")
            }
            let map = block.sourceMap
            var last = -1
            for offset in stride(from: 0, through: length, by: max(1, length / 500)) {
                let mapped = map.sourceOffset(forDisplayOffset: offset)
                if mapped < 0 || mapped > range.count || mapped < last { fail("block \(index): display \(offset) maps to \(mapped)"); break }
                last = mapped
            }
            last = -1
            for offset in stride(from: 0, through: range.count, by: max(1, range.count / 500)) {
                let mapped = map.displayOffset(forSourceOffset: offset)
                if mapped < 0 || mapped > length || mapped < last { fail("block \(index): source \(offset) maps to \(mapped)"); break }
                last = mapped
            }
            var lineEnd = 0
            var covered = [Bool](repeating: false, count: length)
            for line in layout.lines {
                if line.range.lowerBound < lineEnd || line.range.upperBound > length {
                    fail("block \(index): line \(line.range) after \(lineEnd) of \(length)")
                    break
                }
                lineEnd = line.range.upperBound
                if line.range.lowerBound > 0, line.range.lowerBound < length, UTF16.isTrailSurrogate(text.character(at: line.range.lowerBound)) {
                    fail("block \(index): line starts inside a surrogate pair at \(line.range.lowerBound)")
                }
                if !line.height.isFinite || !line.baseline.isFinite || line.top + line.height > layout.height + 0.5 {
                    fail("block \(index): line box \(line.top) \(line.height) in \(layout.height)")
                }
                for offset in line.range { covered[offset] = true }
            }
            for table in layout.tables {
                let structure = table.structure
                if table.rows.count != structure.rowCount || table.rowTops.count != table.rows.count + 1 || table.isPartial {
                    fail("block \(index): table rows \(table.rows.count) of \(structure.rowCount)")
                    continue
                }
                for row in table.rows.indices {
                    for column in 0..<structure.columnCount {
                        let start = table.textOffset(row: row, column: column)
                        for line in table.rows[row].lines(ofCell: column) {
                            for offset in line.range where start + offset >= 0 && start + offset < length {
                                covered[start + offset] = true
                            }
                        }
                    }
                }
            }
            if !layout.isDropped, let missing = covered.indices.first(where: {
                !covered[$0] && text.character(at: $0) != 0x0A && text.character(at: $0) != 0x09
            }) {
                fail("block \(index) \(block.kind): display offset \(missing) is on no line")
            }
        }
        guard !layouts.isEmpty else { return problems }
        if let full = snapshot.fullRange {
            let expected = blocks.indices.filter(snapshot.isSelectable)
                .map { blocks[$0].images.isEmpty ? blocks[$0].text : blocks[$0].text.replacingOccurrences(of: "\u{FFFC}", with: "") }
                .joined(separator: "\n")
            if snapshot.text(in: full) != expected { fail("copy of everything differs from the block texts") }
        }
        for _ in 0..<12 {
            let a = Int(random.next() % UInt64(layouts.count))
            let b = Int(random.next() % UInt64(layouts.count))
            let pa = TextPosition(block: a, offset: Int(random.next() % UInt64(layouts[a].textLength + 1)))
            let pb = TextPosition(block: b, offset: Int(random.next() % UInt64(layouts[b].textLength + 1)))
            let range = min(pa, pb)..<max(pa, pb)
            _ = snapshot.text(in: range)
            let top = snapshot.blockTops[range.lowerBound.block]
            for rect in snapshot.selectionRects(for: range, minY: top, maxY: top + 2_000)
                where !rect.width.isFinite || rect.width < 0 || !rect.minX.isFinite {
                fail("selection rect \(rect)")
            }
            for granularity in [SelectionGranularity.word, .paragraph] {
                for forward in [false, true] {
                    let unit = snapshot.unitRange(at: pa, granularity: granularity, forward: forward)
                    if unit.lowerBound.block != pa.block || unit.upperBound.offset > layouts[pa.block].textLength
                        || unit.lowerBound.offset < 0 {
                        fail("unit range \(unit) at \(pa)")
                    }
                }
            }
            let point = CGPoint(x: CGFloat(random.next() % UInt64(max(snapshot.width, 1) + 40)) - 20,
                                y: CGFloat(random.next() % UInt64(max(snapshot.totalHeight, 1))))
            _ = snapshot.linkDestination(at: point)
            _ = snapshot.isOverText(point)
            if let hit = snapshot.position(at: point), hit.block >= layouts.count || hit.offset > layouts[hit.block].textLength {
                fail("hit \(hit) at \(point)")
            }
            _ = snapshot.baselineOrigin(of: pa)
            if let anchor = snapshot.anchor(atY: point.y), abs(snapshot.y(for: anchor) - point.y) > 1 {
                fail("scroll anchor at \(point.y) comes back at \(snapshot.y(for: anchor))")
            }
        }
        return problems
    }

    /// The first difference between an incrementally updated snapshot and a
    /// full layout of the same source, or nil.
    static func difference(_ incremental: MarkdownSnapshot, _ full: MarkdownSnapshot) -> String? {
        let a = incremental.document.blocks
        let b = full.document.blocks
        if a.count != b.count { return "block count \(a.count) vs \(b.count)" }
        if let index = a.indices.first(where: { a[$0] != b[$0] }) {
            return "block \(index) differs: \(a[index].sourceRange) vs \(b[index].sourceRange), \(b[index].text.prefix(40).debugDescription)"
        }
        for index in a.indices {
            let x = incremental.layouts[index]
            let y = full.layouts[index]
            if x.height != y.height { return "block \(index) height \(x.height) vs \(y.height)" }
            if x.lines.map(\.range) != y.lines.map(\.range) { return "block \(index) line ranges" }
            if x.marginTop != y.marginTop || x.marginBottom != y.marginBottom { return "block \(index) margins" }
            for (s, t) in zip(x.tables, y.tables) {
                if s.columnWidths != t.columnWidths { return "block \(index) column widths" }
                if s.rowTops != t.rowTops { return "block \(index) row tops" }
            }
        }
        if incremental.blockTops != full.blockTops { return "block tops" }
        if incremental.totalHeight != full.totalHeight { return "total height" }
        return incremental.isComplete ? nil : "incomplete"
    }
}

/// Seeded random GFM documents, from the Phase 9 sweep: every block kind,
/// nesting, malformed markup, many scripts and control characters, long
/// lines, deep nesting, random bytes, lone surrogates, and mixed line endings.
struct MarkdownGenerator {
    private var random: SplitMix64

    init(seed: UInt64) { random = SplitMix64(seed: seed) }

    private mutating func int(_ count: Int) -> Int { count <= 1 ? 0 : Int(random.next() % UInt64(count)) }
    private mutating func range(_ low: Int, _ high: Int) -> Int { low + int(high - low + 1) }
    private mutating func chance(_ p: Double) -> Bool { Double(random.next() % 1_000_000) / 1_000_000 < p }
    private mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }

    static let words = ["word", "preview", "the", "a", "layout", "text", "wrapping", "Line", "x", "AVATAR", "WAVE", "ffi", "fl"]
    static let unicode = [
        "é", "e\u{301}", "n\u{303}\u{308}", "👍", "👍🏽", "👨‍👩‍👧‍👦", "🏳️‍🌈", "🇳🇱", "🇯🇵🇺🇸", "❤️", "1️⃣", "🧑🏿‍🚀",
        "日本語のテキスト", "中文字符和标点，句号。", "한국어 텍스트", "مرحبا بالعالم", "שלום עולם", "سلام ١٢٣ world",
        "\u{202E}reversed\u{202C}", "\u{2066}isolate\u{2069}", "\u{200F}", "\u{200E}", "\u{200B}", "\u{200D}", "\u{FEFF}",
        "\u{FFFC}", "\u{FFFD}", "\u{2028}", "\u{2029}", "\u{0085}", "\u{0000}", "\u{0001}", "\u{001F}", "\u{007F}", "\u{00A0}",
        "\u{3000}", "𝕏𝔸", "𐍈", "\u{1F3FB}", "\u{FE0F}", "\u{0301}", "ﷺ", "ไทยภาษา", "हिन्दी", "\u{E000}", "\t", "ß", "ﬁ",
    ]

    private mutating func atom() -> String {
        switch int(22) {
        case 0...5: return pick(Self.words)
        case 6, 7, 8: return pick(Self.unicode)
        case 9:
            return pick(["*\(atom())*", "**\(atom())**", "_\(atom())_", "~~\(atom())~~", "*", "**", "_a_b_", "a*b*c"])
        case 10: return pick(["`code`", "`` a ` b ``", "`", "` x `", "`a|b`", "`\(pick(Self.unicode))`"])
        case 11:
            let destination = pick(["https://example.com", "<a b>", "url \"title\"", "javascript:alert(1)", "", "#frag",
                                    "https://例え.jp/パス?q=日本#x", "a\\)b", "mailto:a@b.c", "(nested)"])
            return pick(["[\(atom())](\(destination))", "[](\(destination))", "[**b** `c` \(atom())](\(destination))",
                         "[\(atom())]", "[", "](x)"])
        case 12:
            let source = pick(["img.png", "x.png", "<>", "", "a b.png"])
            return pick(["![\(atom())](\(source))", "![](\(source))", "[![badge](\(source))](https://x)", "!["])
        case 13: return pick(["[ref]", "[ref][]", "[text][ref]", "[undefined]", "[^1]"])
        case 14: return pick(["<https://a.b/c>", "www.example.com/path?x=1.", "user@example.com", "http://", "www."])
        case 15: return pick(["&amp;", "&lt;", "&#123;", "&#x1F600;", "&#0;", "&bogus;", "&nbsp;", "&", "&#32;"])
        case 16: return pick(["\\*", "\\\\", "\\[", "\\|", "\\", "\\`"])
        case 17: return pick(["<span>x</span>", "<b>bold</b>", "<!-- comment -->", "<br>", "</div>", "<", ">"])
        case 18: return pick(["  \n", "\\\n", "\n", " ", "   "])
        case 19: return String(repeating: pick(["a", "🙂", "日", "ب", "e\u{301}", "👨‍👩‍👧"]), count: range(20, 300))
        default: return pick(["1.", "-", "+", "#", ">", "|", "---", "===", "    ", "[x]", "[ ]"])
        }
    }

    private mutating func inline(_ count: Int) -> String {
        (0..<count).map { _ in atom() }.joined(separator: chance(0.15) ? "" : " ")
    }

    private mutating func paragraph() -> String {
        (0..<range(1, 4)).map { _ in inline(range(1, 14)) }.joined(separator: "\n")
    }

    private mutating func table(prefix: String = "") -> String {
        let columns = chance(0.05) ? range(10, 24) : range(1, 6)
        func row(_ count: Int) -> String {
            let cells = (0..<max(count, 0)).map { _ in chance(0.1) ? "" : inline(range(1, 3)).replacingOccurrences(of: "\n", with: " ") }
            return (chance(0.8) ? "| " : "") + cells.joined(separator: pick([" | ", "|", " \\| "])) + (chance(0.8) ? " |" : "")
        }
        var lines = [row(columns)]
        lines.append("|" + (0..<columns).map { _ in pick(["---", ":--", "--:", ":-:"]) }.joined(separator: "|") + "|")
        for _ in 0..<range(0, chance(0.1) ? 120 : 10) { lines.append(row(columns + range(-2, 2))) }
        return lines.map { prefix + $0 }.joined(separator: "\n")
    }

    private mutating func code() -> String {
        if chance(0.25) {
            return (0..<range(1, 4)).map { _ in pick(["    ", "\t"]) + inline(range(1, 5)).replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\n")
        }
        let fence = String(repeating: chance(0.7) ? "`" : "~", count: range(3, 4))
        let body = (0..<range(0, 6)).map { _ in
            chance(0.1) ? String(repeating: "x", count: range(200, 3_000))
                : pick(["\tlet x = 1", "  indented()", "", "// \(atom())", "| a | b |", "```", "// 1392 بهمن 22"])
        }
        return fence + pick(["", "swift", "{.class}"]) + "\n" + body.joined(separator: "\n") + (chance(0.85) ? "\n" + fence : "")
    }

    private mutating func list(depth: Int) -> String {
        let ordered = chance(0.4)
        let start = pick([0, 1, 7, 999_999_999])
        let loose = chance(0.3)
        var items: [String] = []
        for index in 0..<range(1, 5) {
            let marker = ordered ? "\(start + index)." : pick(["-", "*", "+"])
            let indent = String(repeating: " ", count: marker.count + 1)
            var content = [(chance(0.25) ? pick(["[ ] ", "[x] "]) : "") + inline(range(1, 8))]
            if depth < 3, chance(0.4) {
                switch int(4) {
                case 0, 1: content.append(list(depth: depth + 1))
                case 2: content.append(code())
                default: content.append(table())
                }
            }
            let lines = content.joined(separator: loose ? "\n\n" : "\n").components(separatedBy: "\n")
            items.append(marker + " " + lines.enumerated().map { $0.offset == 0 ? $0.element : indent + $0.element }
                .joined(separator: "\n"))
        }
        return items.joined(separator: loose ? "\n\n" : "\n")
    }

    private mutating func quote(depth: Int) -> String {
        let inner = (0..<range(1, 3)).map { _ in
            depth < 3 && chance(0.3) ? quote(depth: depth + 1) : chance(0.2) ? table() : chance(0.2) ? code() : paragraph()
        }
        return inner.joined(separator: "\n\n").components(separatedBy: "\n").map { chance(0.07) ? $0 : "> " + $0 }
            .joined(separator: "\n")
    }

    private mutating func block() -> String {
        switch int(19) {
        case 0...4: return paragraph()
        case 5: return String(repeating: "#", count: range(1, 7)) + " " + inline(range(0, 5))
        case 6: return inline(range(1, 4)) + "\n" + pick(["===", "---", "-"])
        case 7: return pick(["---", "***", "- - -"])
        case 8, 9: return code()
        case 10, 11: return list(depth: 0)
        case 12: return quote(depth: 0)
        case 13, 14: return table()
        case 15: return pick(["<div>\n\(paragraph())\n</div>", "<!-- comment\nmulti -->", "<details>"])
        case 16: return pick(["[ref]: https://example.com \"title\"", "[Ref]:\n  /x", "[^1]: footnote"])
        case 17: return String(repeating: pick(["\n", " \n", "\t\n"]), count: range(1, 4))
        default: return table(prefix: pick(["", "> ", "- "]))
        }
    }

    mutating func document() -> String {
        var text: String
        switch int(100) {
        case 0..<4:
            let pieces = ["", "#", "-", "`", "|", ">", "*", "\r", "\n", "\u{0000}", "\u{FEFF}", "\r\n", "---", "```", "1.", "[",
                          "a", "é", "👨‍👩‍👧‍👦", "\u{0301}", "| a |\n|-|", "- [ ]", "<"]
            text = (0..<range(0, 3)).map { _ in pick(pieces) }.joined()
        case 4..<8:
            let unit = pick(["a", "🙂", "日本", "ب", "word ", "`c` ", "**b** ", "[l](x) ", "مرحبا ", "a  b "])
            text = (chance(0.3) ? "- " : "") + String(repeating: unit, count: range(500, 3_000))
        case 8..<11:
            let depth = range(20, 80)
            text = chance(0.5) ? (0..<depth).map { String(repeating: "  ", count: $0) + "- item \($0) " + atom() }.joined(separator: "\n")
                : (0..<depth).map { String(repeating: "> ", count: $0) + atom() }.joined(separator: "\n")
        case 11..<13:
            var bytes: [UInt8] = []
            for _ in 0..<range(1, 3_000) { bytes.append(chance(0.6) ? UInt8(range(0x20, 0x7E)) : UInt8(int(256))) }
            text = String(decoding: bytes, as: UTF8.self)
        case 13..<15:
            var units = Array(paragraph().utf16)
            for _ in 0..<range(1, 4) {
                units.insert(UInt16(chance(0.5) ? 0xD800 + int(0x400) : 0xDC00 + int(0x400)), at: int(units.count + 1))
            }
            text = NSString(characters: units, length: units.count) as String
        default:
            var parts: [String] = []
            if chance(0.1) { parts.append(pick(["---\nkey: value\n---\n", "---\n---\n", "\u{FEFF}---\nk: v\n---\n"])) }
            for _ in 0..<range(1, 30) { parts.append(block()) }
            text = parts.joined(separator: pick(["\n\n", "\n", "\n\n\n"]))
        }
        switch int(10) {
        case 0, 1: text = text.replacingOccurrences(of: "\n", with: "\r\n")
        case 2: text = text.replacingOccurrences(of: "\n", with: "\r")
        default: break
        }
        return text
    }
}
