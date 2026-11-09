import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// SplitMix64 with its own range math, so output does not depend on the standard library.
struct Random {
    private var state: UInt64

    /// Each file gets its own stream so adding a file never changes the others.
    init(seed: UInt64, name: String) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        state = seed ^ hash
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }
    mutating func pick<T>(_ items: [T]) -> T { items[int(0...items.count - 1)] }
}

/// Deterministic Markdown text built from small vocabularies.
struct TextMaker {
    var random: Random

    static let words = """
        the a of to and in is it for on with as by at from that this be are was or an not have has \
        render layout preview editor document window table list quote block heading paragraph \
        source scroll update frame memory latency theme cursor selection tab split width height \
        line text font color link image code fence parser tree node cache result snapshot value \
        quick small large native fast stable visible hidden empty simple direct static current \
        build measure check compare report keep move open close write read show draw copy find
        """.split(separator: " ").map(String.init)
    static let identifiers = ["value", "count", "index", "result", "buffer", "width", "offset",
                              "layout", "range", "item", "node", "cache", "frame", "total", "block"]

    mutating func word() -> String { random.pick(Self.words) }
    mutating func identifier() -> String { random.pick(Self.identifiers) + (random.chance(30) ? "\(random.int(1...9))" : "") }

    mutating func words(_ range: ClosedRange<Int>) -> String {
        (0..<random.int(range)).map { _ in word() }.joined(separator: " ")
    }

    mutating func inlineSpan() -> String {
        switch random.int(0...6) {
        case 0: "**\(words(1...3))**"
        case 1: "*\(words(1...2))*"
        case 2: "`\(identifier())()`"
        case 3: "[\(words(1...3))](https://example.com/\(word())/\(random.int(1...999)))"
        case 4: "~~\(word())~~"
        case 5: "_\(word())_"
        default: "`\(identifier()).\(identifier())`"
        }
    }

    mutating func sentence(inline: Bool = false) -> String {
        var parts: [String] = []
        for _ in 0..<random.int(6...16) { parts.append(inline && random.chance(8) ? inlineSpan() : word()) }
        let text = parts.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst() + random.pick([".", ".", ".", "?", "!", ":"])
    }

    mutating func paragraph(inline: Bool = false, sentences: ClosedRange<Int> = 2...6, wrap: Int? = nil) -> String {
        let text = (0..<random.int(sentences)).map { _ in sentence(inline: inline) }.joined(separator: " ")
        guard let wrap else { return text }
        var lines: [String] = []
        var line = ""
        for piece in text.split(separator: " ") {
            if !line.isEmpty, line.count + piece.count + 1 > wrap { lines.append(line); line = "" }
            line += (line.isEmpty ? "" : " ") + piece
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    mutating func heading(_ level: Int) -> String {
        let text = words(2...6)
        return String(repeating: "#", count: level) + " " + text.prefix(1).uppercased() + text.dropFirst()
    }

    mutating func list(ordered: Bool = false, tasks: Bool = false) -> String {
        var lines: [String] = []
        for index in 1...random.int(3...8) {
            let marker = ordered ? "\(index)." : random.pick(["-", "-", "*"])
            let task = tasks ? (random.chance(40) ? "[x] " : "[ ] ") : ""
            lines.append("\(marker) \(task)\(sentence(inline: true))")
            if random.chance(20) {
                let indent = String(repeating: " ", count: marker.count + 1)
                for _ in 0..<random.int(1...3) { lines.append("\(indent)- \(task.isEmpty ? "" : "[ ] ")\(sentence(inline: true))") }
            }
        }
        return lines.joined(separator: "\n")
    }

    mutating func codeBlock(language chosen: String? = nil) -> String {
        let language = chosen ?? random.pick(["swift", "typescript", "javascript", "json", "bash", "python", "rust", ""])
        var lines: [String] = []
        let count = random.int(4...24)
        switch language {
        case "json":
            lines.append("{")
            for index in 0..<count {
                let comma = index == count - 1 ? "" : ","
                lines.append("  \"\(identifier())\": " + random.pick(["\(random.int(0...9999))", "\"\(word())\"", "true", "null"]) + comma)
            }
            lines.append("}")
        case "bash":
            for _ in 0..<count {
                lines.append(random.pick(["swift build -c release", "git status --short", "ls -la \(word())/",
                                          "export \(identifier().uppercased())=\(random.int(1...99))",
                                          "./scripts/\(word()).sh --\(word())", "# \(sentence())"]))
            }
        case "python":
            lines.append("def \(identifier())(\(identifier()), \(identifier())=\(random.int(0...9))):")
            for _ in 0..<count { lines.append("    \(identifier()) = \(identifier())(\(random.int(0...99))) + \(identifier())") }
            lines.append("    return \(identifier())")
        default:
            let keyword = ["swift": "func", "rust": "fn", "typescript": "function", "javascript": "function"][language] ?? "function"
            lines.append("\(keyword) \(identifier())(\(identifier())) {")
            var depth = 1
            for _ in 0..<count {
                let indent = String(repeating: "    ", count: depth)
                switch random.int(0...5) {
                case 0 where depth < 4:
                    lines.append("\(indent)if \(identifier()) > \(random.int(0...99)) {")
                    depth += 1
                case 1 where depth > 1:
                    depth -= 1
                    lines.append(String(repeating: "    ", count: depth) + "}")
                case 2: lines.append("\(indent)// \(sentence())")
                default: lines.append("\(indent)let \(identifier()) = \(identifier())(\(identifier()), \(random.int(0...999)))")
                }
            }
            while depth > 0 { depth -= 1; lines.append(String(repeating: "    ", count: depth) + "}") }
        }
        return "```\(language)\n" + lines.joined(separator: "\n") + "\n```"
    }

    static let alignments = ["---", ":---", ":---:", "---:"]

    mutating func cell(long: Bool) -> String {
        if long { return sentence(inline: true) + (random.chance(50) ? " " + sentence() : "") }
        switch random.int(0...9) {
        case 0: return "`\(identifier())`"
        case 1: return "**\(word())**"
        case 2: return "[\(word())](https://example.com/\(random.int(1...999)))"
        case 3: return "\(word()) \\| \(word())"
        case 4: return ""
        case 5: return "\(random.int(0...99_999))"
        case 6: return "2026-\(random.int(10...12))-\(random.int(10...28))"
        default: return words(1...3)
        }
    }

    /// Column 1 always holds a long cell; any other cell is long 2% of the time.
    mutating func table(rows: Int, columns: Int) -> String {
        let header = (0..<columns).map { $0 == 0 ? "ID" : $0 == 1 ? "Description" : "Field \($0)" }
        var lines = ["| " + header.joined(separator: " | ") + " |",
                     "| " + (0..<columns).map { Self.alignments[$0 % 4] }.joined(separator: " | ") + " |"]
        lines.reserveCapacity(rows + 2)
        for row in 1...rows {
            let cells = (0..<columns).map { column in
                column == 0 ? "\(row)" : cell(long: column == 1 || random.chance(2))
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    mutating func smallTable() -> String {
        let columns = random.int(2...5)
        let rows = random.int(2...10)
        var lines = ["| " + (0..<columns).map { _ in word().capitalized }.joined(separator: " | ") + " |",
                     "| " + (0..<columns).map { _ in random.pick(Self.alignments) }.joined(separator: " | ") + " |"]
        for _ in 0..<rows { lines.append("| " + (0..<columns).map { _ in cell(long: random.chance(10)) }.joined(separator: " | ") + " |") }
        return lines.joined(separator: "\n")
    }

    mutating func quote() -> String {
        paragraph(inline: true, sentences: 1...3).split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
    }

    // MARK: Document styles

    mutating func proseBlock(index: Int) -> String {
        index % random.int(5...9) == 0 ? heading(2) : paragraph(sentences: 3...8, wrap: 80)
    }

    mutating func mixedBlock(index: Int) -> String {
        switch random.int(0...99) {
        case 0..<34: paragraph(inline: true)
        case 34..<44: heading(random.int(2...4))
        case 44..<56: list()
        case 56..<62: list(ordered: true)
        case 62..<66: list(tasks: true)
        case 66..<78: codeBlock()
        case 78..<86: smallTable()
        case 86..<92: quote()
        case 92..<95: "---"
        case 95..<98: "<details>\n<summary>\(words(2...4))</summary>\n\n\(paragraph(inline: true))\n\n</details>"
        default: "<p align=\"center\">\(words(3...8))</p>"
        }
    }

    mutating func codeHeavyBlock(index: Int) -> String {
        switch random.int(0...99) {
        case 0..<60: codeBlock()
        case 60..<75: paragraph(inline: true, sentences: 1...3)
        case 75..<88: heading(random.int(2...3))
        default: (0..<random.int(2...6)).map { _ in "- `\(identifier()) --\(word())`: \(sentence())" }.joined(separator: "\n")
        }
    }

    /// Blocks until `target` UTF-8 bytes, stopping early rather than overshooting a nearly full file.
    mutating func document(title: String, target: Int, block: (inout TextMaker, Int) -> String) -> String {
        var text = "# \(title)\n\n"
        var index = 1
        while text.utf8.count < target {
            let next = block(&self, index) + "\n\n"
            if text.utf8.count + next.utf8.count > target, text.utf8.count >= target * 9 / 10 { break }
            text += next
            index += 1
        }
        return String(text.dropLast()) // one trailing newline
    }
}

struct Generator {
    struct File: Codable {
        let name: String
        let group: String
        let path: String
        let bytes: Int
        let sha256: String
    }

    struct TraceEdit: Codable {
        /// UTF-16 range in the text after the previous edits.
        let location: Int
        let length: Int
        let replacement: String
    }

    struct Trace: Codable {
        let name: String
        let description: String
        let base: String
        let edits: [TraceEdit]
    }

    struct TraceFile: Codable {
        let name: String
        let path: String
        let baseBytes: Int
        let edits: Int
    }

    struct GeneratedManifest: Codable {
        let generator: String
        let version: Int
        let seed: UInt64
        /// Relative to this manifest's directory.
        let root: String
        let sets: [String: [File]]
        let traces: [TraceFile]
        let images: ImageManifest
    }

    let output: URL
    let seed: UInt64
    private(set) var files: [File] = []
    private(set) var traces: [TraceFile] = []
    private(set) var imageFiles: [String: ImageFile] = [:]
    private(set) var imageReferences: [ImageReference] = []
    private(set) var imageEncoders: [String: String] = [:]

    init(output: URL, seed: UInt64) {
        self.output = output
        self.seed = seed
    }

    static let sizes: [(String, Int)] = [("1k", 1 << 10), ("10k", 10 << 10), ("100k", 100 << 10),
                                         ("1m", 1 << 20), ("10m", 10 << 20)]

    func stream(_ name: String) -> TextMaker { TextMaker(random: Random(seed: seed, name: name)) }

    mutating func write(_ group: String, _ name: String, _ text: String) throws {
        let directory = output.appendingPathComponent(group)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(text.utf8)
        try data.write(to: directory.appendingPathComponent(name + ".md"))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        files.append(File(name: name, group: group, path: "\(group)/\(name).md", bytes: data.count, sha256: sha))
        print("  \(group)/\(name).md".padding(toLength: 44, withPad: " ", startingAt: 0) + String(format: "%10.1f KiB", Double(data.count) / 1024))
    }

    mutating func run() throws {
        let started = now()
        print("generating into \(output.path) (seed \(seed))")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var mixed100k = ""
        var mixed1m = ""
        var code100k = ""
        for (label, bytes) in Self.sizes {
            for style in ["prose", "mixed", "code"] {
                let name = "\(style)-\(label)"
                var maker = stream(name)
                let title = "\(style.capitalized) document, \(label.uppercased())"
                let text = signposter.withIntervalSignpost("generate") {
                    switch style {
                    case "prose": maker.document(title: title, target: bytes) { $0.proseBlock(index: $1) }
                    case "mixed": maker.document(title: title, target: bytes) { $0.mixedBlock(index: $1) }
                    default: maker.document(title: title, target: bytes) { $0.codeHeavyBlock(index: $1) }
                    }
                }
                if name == "mixed-100k" { mixed100k = text }
                if name == "code-100k" { code100k = text }
                if name == "mixed-1m" { mixed1m = text }
                try write("sizes", name, text)
            }
        }
        var table1500 = ""
        for rows in [160, 1_500, 15_000] {
            for columns in [4, 20] {
                let name = "rows-\(rows)-cols-\(columns)"
                var maker = stream(name)
                let table = maker.table(rows: rows, columns: columns)
                let text = "# Table with \(rows) rows and \(columns) columns\n\n\(maker.paragraph(inline: true))\n\n\(table)\n\n\(maker.paragraph())\n"
                if rows == 1_500, columns == 4 { table1500 = text }
                try write("tables", name, text)
            }
        }
        try write("nesting", "lists-20-deep", nestedLists(stream("lists-20-deep")))
        try write("nesting", "quotes-20-deep", nestedQuotes(stream("quotes-20-deep")))
        try write("unicode", "mixed-scripts", unicode(stream("mixed-scripts")))
        try write("links", "autolinks-1000", autolinks(stream("autolinks-1000")))
        try write("links", "reference-links-1000", referenceLinks(stream("reference-links-1000")))
        try pathological(mixed100k: mixed100k)
        try images()
        // The 1 MiB traces (Phase 4 exit) repeat the five edits on sizes/mixed-1m.md and a
        // 7,200-row table of about 1 MiB, which is only written as the trace's base.
        var tableMaker = stream("rows-7200-cols-4")
        let rows7200 = tableMaker.table(rows: 7_200, columns: 4)
        let table7200 = "# Table with 7200 rows and 4 columns\n\n\(tableMaker.paragraph(inline: true))\n\n\(rows7200)\n\n\(tableMaker.paragraph())\n"
        try writeTraces(mixed: mixed100k, mixedName: "sizes/mixed-100k.md", table: table1500,
                        tableName: "tables/rows-1500-cols-4.md", tableRow: 750, suffix: "")
        try writeTraces(mixed: mixed1m, mixedName: "sizes/mixed-1m.md", table: table7200,
                        tableName: "a 7,200-row, 4-column table (about 1 MiB)", tableRow: 3_600, suffix: "-1m")
        try writeCodeTrace(code: code100k, codeName: "sizes/code-100k.md")

        let manifest = GeneratedManifest(
            generator: "MarkdownViewBench generate", version: 2, seed: seed, root: ".",
            sets: ["generated": files], traces: traces,
            images: ImageManifest(encoders: imageEncoders, files: imageFiles.values.sorted { $0.path < $1.path },
                                  references: imageReferences))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: output.appendingPathComponent("generated-manifest.json"))
        let total = files.reduce(0) { $0 + $1.bytes }
        let imageBytes = imageFiles.values.reduce(0) { $0 + ($1.bytes ?? 0) }
        print(String(format: "wrote %d documents (%.1f MiB), %d image files (%.1f MiB), %d image references and %d traces in %.1f s; manifest %@",
                     files.count, Double(total) / 1_048_576, imageFiles.count, Double(imageBytes) / 1_048_576,
                     imageReferences.count, traces.count, milliseconds(started, now()) / 1000,
                     output.appendingPathComponent("generated-manifest.json").path))
    }

    // MARK: Structure

    /// Lists nested 20 levels deep, mixing bullets and ordered markers, with loose items
    /// and continuation paragraphs, then siblings on the way back out.
    func nestedLists(_ maker: TextMaker) -> String {
        var maker = maker
        var text = "# Lists nested 20 levels deep\n"
        for round in 1...12 {
            text += "\n\(maker.paragraph(inline: true))\n\n"
            var indents: [Int] = []
            var markers: [String] = []
            var indent = 0
            for level in 1...20 {
                let marker = level % 3 == 0 ? "\(level)." : (level % 2 == 0 ? "*" : "-")
                let pad = String(repeating: " ", count: indent)
                let task = round % 3 == 0 && level % 2 == 0 ? "[ ] " : ""
                text += "\(pad)\(marker) \(task)Level \(level): \(maker.sentence(inline: true))\n"
                if level % 5 == 0 {
                    text += "\n" + String(repeating: " ", count: indent + marker.count + 1) + maker.sentence() + "\n\n"
                }
                indents.append(indent)
                markers.append(marker)
                indent += marker.count + 1
            }
            for level in stride(from: 19, through: 0, by: -1) {
                let marker = markers[level].hasSuffix(".") ? "\(level + 2)." : markers[level]
                text += String(repeating: " ", count: indents[level]) + "\(marker) Back at level \(level + 1): \(maker.sentence())\n"
            }
        }
        return text
    }

    /// Block quotes nested 20 levels deep, with a list and a code fence inside.
    func nestedQuotes(_ maker: TextMaker) -> String {
        var maker = maker
        var text = "# Block quotes nested 20 levels deep\n"
        for _ in 1...12 {
            text += "\n\(maker.paragraph(inline: true))\n\n"
            for level in 1...20 {
                let prefix = String(repeating: "> ", count: level)
                text += "\(prefix)Quote level \(level): \(maker.sentence(inline: true))\n"
                if level == 7 { text += "\(prefix)\n\(prefix)- \(maker.sentence())\n\(prefix)- \(maker.sentence())\n\(prefix)\n" }
                if level == 12 { text += "\(prefix)\n\(prefix)```swift\n\(prefix)let level = \(level)\n\(prefix)```\n\(prefix)\n" }
            }
        }
        return text
    }

    func unicode(_ maker: TextMaker) -> String {
        var maker = maker
        let chinese = ["这是一个用于测试的段落。", "渲染速度和内存占用是首要目标。", "表格、列表和代码块都需要正确显示。",
                       "文字选择和复制必须准确无误。", "预览会在每次编辑后更新。"]
        let japanese = ["これはテスト用の段落です。", "日本語の文章には漢字、ひらがな、カタカナが混在します。",
                        "プレビューは編集のたびに更新されます。", "選択とコピーが正しく動作する必要があります。"]
        let korean = ["이것은 테스트용 문단입니다.", "한국어 문장은 띄어쓰기를 사용합니다.", "미리 보기는 편집할 때마다 갱신됩니다."]
        let arabic = ["هذا نص تجريبي باللغة العربية.", "يجب أن يظهر النص من اليمين إلى اليسار.", "المعاينة تتحدث بعد كل تعديل."]
        let hebrew = ["זהו טקסט לדוגמה בעברית.", "הטקסט צריך להופיע מימין לשמאל.", "התצוגה המקדימה מתעדכנת אחרי כל עריכה."]
        let emoji = ["👨‍👩‍👧‍👦", "👩🏽‍💻", "🧑🏿‍🚀", "🏳️‍🌈", "🏴‍☠️", "👁️‍🗨️", "❤️‍🔥", "🇳🇱", "🇯🇵", "1️⃣", "👍🏻",
                     "🙋🏾‍♀️", "🤝🏼", "🐻‍❄️", "😀", "✅", "🚀"]
        let combining = ["e\u{301}", "n\u{303}", "a\u{30A}", "o\u{308}\u{304}", "q\u{323}\u{307}", "Tiếng Việt",
                         "Z\u{335}\u{321}\u{34E}a\u{336}\u{31B}l\u{337}\u{360}g\u{338}\u{35C}o\u{334}\u{30F}",
                         "नमस्ते दुनिया", "สวัสดีชาวโลก", "Ελληνικά", "Ру́сский"]
        var text = "# Unicode: CJK, right-to-left, emoji and combining marks\n\n"
        var section = 0
        while text.utf8.count < 100 << 10 {
            section += 1
            switch section % 6 {
            case 1:
                text += "## 中文 \(section)\n\n" + (0..<maker.random.int(3...8)).map { _ in maker.random.pick(chinese) }.joined() + "\n\n"
                text += "## 日本語と한국어 \(section)\n\n" + (0..<maker.random.int(3...6)).map { _ in maker.random.pick(japanese) }.joined()
                    + "\n\n" + (0..<maker.random.int(2...5)).map { _ in maker.random.pick(korean) }.joined(separator: " ") + "\n\n"
            case 2:
                text += "## Mixed direction \(section)\n\n"
                for _ in 0..<4 {
                    text += "The phrase \(maker.random.pick(arabic)) sits between English words, and so does "
                        + "\(maker.random.pick(hebrew)) with `code` and **bold** text.\n\n"
                }
                text += (0..<3).map { _ in maker.random.pick(arabic) }.joined(separator: " ") + "\n\n"
                text += "> " + (0..<3).map { _ in maker.random.pick(hebrew) }.joined(separator: " ") + "\n\n"
            case 3:
                text += "## Emoji \(section)\n\n"
                for _ in 0..<5 {
                    text += (0..<12).map { _ in maker.random.chance(40) ? maker.random.pick(emoji) : maker.word() }.joined(separator: " ") + "\n\n"
                }
                text += (0..<6).map { _ in "- \(maker.random.pick(emoji)) \(maker.sentence())" }.joined(separator: "\n") + "\n\n"
            case 4:
                text += "## Combining marks \(section)\n\n"
                text += (0..<40).map { _ in maker.random.pick(combining) }.joined(separator: " ") + "\n\n"
            case 5:
                text += "| Script | Sample | Emoji |\n| :--- | :---: | ---: |\n"
                for _ in 0..<8 {
                    let sample = maker.random.pick([chinese, japanese, korean, arabic, hebrew, combining])
                    text += "| \(maker.word()) | \(maker.random.pick(sample)) | \(maker.random.pick(emoji)) |\n"
                }
                text += "\n"
            default:
                text += "### \(maker.random.pick(chinese)) \(maker.random.pick(emoji)) \(maker.random.pick(arabic))\n\n"
                text += "1. \(maker.random.pick(japanese))\n2. \(maker.random.pick(hebrew))\n3. \(maker.random.pick(combining))\n\n"
            }
        }
        return text
    }

    func autolinks(_ maker: TextMaker) -> String {
        var maker = maker
        var text = "# 1,000 autolinks\n\n"
        for group in 0..<200 {
            var parts: [String] = []
            for item in 0..<5 {
                let index = group * 5 + item
                let link = switch index % 5 {
                case 0: "<https://example.com/docs/\(index)>"
                case 1: "https://example.org/path/\(index)?query=\(index)#section"
                case 2: "www.example.net/page/\(index)"
                case 3: "contact\(index)@example.com"
                default: "<mailto:team\(index)@example.com>"
                }
                parts.append("\(maker.words(2...6)) \(link)")
            }
            text += group % 4 == 3 ? parts.map { "- " + $0 }.joined(separator: "\n") + "\n\n" : parts.joined(separator: " ") + ".\n\n"
        }
        return text
    }

    func referenceLinks(_ maker: TextMaker) -> String {
        var maker = maker
        var text = "# 1,000 reference-style links\n\n"
        for group in 0..<200 {
            var parts: [String] = []
            for item in 0..<5 {
                let index = group * 5 + item
                let link = switch index % 3 {
                case 0: "[\(maker.words(1...3))][ref-\(index)]"
                case 1: "[ref-\(index)][]"
                default: "[ref-\(index)]"
                }
                parts.append("\(maker.words(2...6)) \(link)")
            }
            text += parts.joined(separator: " ") + ".\n\n"
        }
        for index in 0..<1_000 { text += "[ref-\(index)]: https://example.com/reference/\(index) \"Reference \(index)\"\n" }
        return text
    }

    mutating func pathological(mixed100k: String) throws {
        try write("pathological", "unclosed-fence-top", "```\n" + mixed100k)
        var maker = stream("long-line-1m")
        var line = ""
        while line.utf8.count < 1 << 20 { line += maker.sentence(inline: true) + " " }
        try write("pathological", "long-line-1m", line + "\n")
        try write("pathological", "empty-lines-100k",
                  "# 100,000 empty lines\n" + String(repeating: "\n", count: 100_000) + "The last paragraph.\n")
        maker = stream("headings-10k")
        try write("pathological", "headings-10k", (0..<10_000).map { maker.heading($0 % 6 + 1) }.joined(separator: "\n\n") + "\n")
        maker = stream("tasks-5k")
        var tasks = "# 5,000 task items\n\n"
        for index in 0..<5_000 {
            let indent = index % 10 >= 7 ? "  " : ""
            tasks += "\(indent)- \(maker.random.chance(40) ? "[x]" : "[ ]") Task \(index + 1): \(maker.sentence(inline: true))\n"
        }
        try write("pathological", "tasks-5k", tasks)
    }

    // MARK: Typing traces

    /// Edits that type `string` one UTF-16 unit at a time from `location`.
    static func typing(_ string: String, at location: Int) -> [TraceEdit] {
        var edits: [TraceEdit] = []
        var offset = location
        for character in string {
            let unit = String(character)
            edits.append(TraceEdit(location: offset, length: 0, replacement: unit))
            offset += unit.utf16.count
        }
        return edits
    }

    /// The UTF-16 offset of the first block after the middle, optionally the first paragraph
    /// (a block starting with a letter).
    static func middleBlockStart(_ text: String, paragraph: Bool = false) -> Int {
        let source = text as NSString
        var location = source.length / 2
        while true {
            let after = source.range(of: "\n\n", range: NSRange(location: location, length: source.length - location))
            guard after.location != NSNotFound, after.location + 2 < source.length else { return source.length }
            location = after.location + 2
            let unit = source.character(at: location)
            if !paragraph || (65...90).contains(unit) || (97...122).contains(unit) { return location }
        }
    }

    /// The five typing traces on `mixed` and `table`, named with `suffix`.
    mutating func writeTraces(mixed: String, mixedName: String, table tableText: String, tableName: String,
                              tableRow: Int, suffix: String) throws {
        var list: [Trace] = []
        let end = (mixed as NSString).length
        list.append(Trace(name: "append-paragraph" + suffix, description: "Type a new paragraph at the end of \(mixedName).",
                          base: mixed,
                          edits: Self.typing("\nA new paragraph typed at the end of the document, one key at a time.", at: end)))

        let table = tableText as NSString
        let row = table.range(of: "\n| \(tableRow) | ")
        let lineEnd = table.range(of: "\n", range: NSRange(location: row.location + 1, length: table.length - row.location - 1)).location
        // The end of the third cell: skip "| <row> | ", then two unescaped pipes.
        var cursor = row.location + 1
        var pipes = 0
        while cursor < lineEnd, pipes < 4 {
            if table.character(at: cursor) == 0x7C, table.character(at: cursor - 1) != 0x5C { pipes += 1 }
            cursor += 1
        }
        let cellEnd = cursor - 2 // before " |"
        var tableEdits = Self.typing(" edited", at: cellEnd)
        for index in 0..<3 { tableEdits.append(TraceEdit(location: cellEnd + 6 - index, length: 1, replacement: "")) }
        list.append(Trace(name: "table-cell" + suffix, description: "Type into the third cell of row \(tableRow) of \(tableName), then delete three characters.",
                          base: tableText, edits: tableEdits))

        let fenceAt = Self.middleBlockStart(mixed, paragraph: true)
        var fence = Self.typing("```\n", at: fenceAt)
        fence += Self.typing("let value = 1\n", at: fenceAt + 4)
        fence += Self.typing("```\n", at: fenceAt + 18)
        list.append(Trace(name: "fence-open-close" + suffix, description: "Open a code fence in the middle of \(mixedName), type a line, then close it.",
                          base: mixed, edits: fence))

        var deletions: [TraceEdit] = []
        var current = mixed as NSString
        let blockAt = Self.middleBlockStart(mixed)
        for _ in 0..<3 {
            let next = current.range(of: "\n\n", range: NSRange(location: blockAt, length: current.length - blockAt))
            let length = (next.location == NSNotFound ? current.length : next.location + 2) - blockAt
            deletions.append(TraceEdit(location: blockAt, length: length, replacement: ""))
            current = current.replacingCharacters(in: NSRange(location: blockAt, length: length), with: "") as NSString
        }
        list.append(Trace(name: "delete-block" + suffix, description: "Delete three consecutive blocks in the middle of \(mixedName), one edit each.",
                          base: mixed, edits: deletions))

        var maker = stream("link-reference-definition" + suffix)
        var referenced = ""
        for (index, block) in mixed.components(separatedBy: "\n\n").enumerated() {
            referenced += (index == 0 ? "" : "\n\n") + block
            if index % 25 == 12 { referenced += "\n\n\(maker.sentence()) See [the bench reference][bench-ref] for details." }
        }
        let referencedEnd = (referenced as NSString).length
        list.append(Trace(name: "link-reference-definition" + suffix,
                          description: "Type a link reference definition at the end; earlier [bench-ref] uses become links.",
                          base: referenced, edits: Self.typing("\n[bench-ref]: https://example.com/reference", at: referencedEnd)))

        try write(list)
    }

    /// Typing inside a code block (Phase 10): a new line after the first line of the first
    /// fenced block with a language after the middle of `code`.
    mutating func writeCodeTrace(code: String, codeName: String) throws {
        let text = code as NSString
        var location = text.length / 2
        var fence = NSRange(location: NSNotFound, length: 0)
        while location < text.length {
            fence = text.range(of: "\n```", range: NSRange(location: location, length: text.length - location))
            guard fence.location != NSNotFound, fence.upperBound < text.length else { break }
            let unit = text.character(at: fence.upperBound)
            if (97...122).contains(unit) { break }
            location = fence.upperBound
        }
        guard fence.location != NSNotFound else { return }
        let opening = text.range(of: "\n", range: NSRange(location: fence.upperBound, length: text.length - fence.upperBound))
        let firstLine = text.range(of: "\n", range: NSRange(location: opening.upperBound, length: text.length - opening.upperBound))
        try write([Trace(name: "code-block-typing", description: "Type a new line inside the first code block with a language after the middle of \(codeName).",
                         base: code, edits: Self.typing("\n    let typed = value + 1", at: firstLine.location))])
    }

    private mutating func write(_ list: [Trace]) throws {
        let directory = output.appendingPathComponent("traces")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for trace in list {
            try encoder.encode(trace).write(to: directory.appendingPathComponent(trace.name + ".json"))
            traces.append(TraceFile(name: trace.name, path: "traces/\(trace.name).json",
                                    baseBytes: trace.base.utf8.count, edits: trace.edits.count))
            print("  traces/\(trace.name).json".padding(toLength: 44, withPad: " ", startingAt: 0) + "\(trace.edits.count) edits")
        }
    }
}

// MARK: Images (Phase 7)

extension Generator {
    /// An image file the generator wrote, or a symbolic link it made.
    struct ImageFile: Codable {
        /// Relative to the manifest's root.
        let path: String
        let kind: String
        let width: Int?
        let height: Int?
        let frames: Int?
        let bytes: Int?
        let sha256: String?
        /// For a symbolic link: its destination as written, relative to the link's directory.
        let symlink: String?
    }

    /// One image in a generated document, in document order.
    struct ImageReference: Codable {
        /// The Markdown file, relative to the manifest's root.
        let document: String
        /// The destination exactly as written in the Markdown.
        let source: String
        /// `block` (alone in its paragraph) or `inline` (inside a line of text).
        let placement: String
        let kind: String
        /// For a relative source: the path it names, relative to the manifest's root, with `..` resolved.
        /// It starts with `..` when the source escapes the root.
        let path: String?
        /// The pixel size of the file, or for a remote source the size the test stub should serve.
        let width: Int?
        let height: Int?
        /// ok, missing, corrupt, too-large or blocked.
        let expected: String
    }

    struct ImageManifest: Codable {
        /// How each format was written: the ImageIO type, `embedded`, `hand-written`, or `unavailable`.
        let encoders: [String: String]
        let files: [ImageFile]
        let references: [ImageReference]
    }

    struct ImageCase {
        let title: String
        let source: String
        let kind: String
        let expected: String
        var width: Int? = nil
        var height: Int? = nil
    }

    /// ImageIO cannot write WebP, so these were made once with `cwebp`/`img2webp` 1.6.0
    /// (`-lossless -metadata none`): a 48 x 32 blue rectangle on off-white, and three 24 x 24
    /// frames of 200 ms each, looping.
    static let webpStill = "UklGRjQAAABXRUJQVlA4TCgAAAAvL8AHAA9wP/jjwL97ff7jAWraNoLaHn9Oxyz7PXtE/ydAIxugPtJI"
    static let webpAnimated = """
        UklGRhABAABXRUJQVlA4WAoAAAASAAAAFwAAFwAAQU5JTQYAAAD/////AABBTk1GPAAAAAAAAAAAABcAABcAAMgAAAJWUDhMJAAAAC8XwAUAD/Ce\
        /3f/f+Z//uMBato2YCCEP9eONxAi+j8B14nlA0FOTUZMAAAAAAAAAAAAFwAAFwAAyAAAAFZQOEwzAAAALxfABRAXIBBI8lcZcg2BQJLY/lgLBJIU\
        94d5/gP+FSho24ahWJJ3UDsCEf2fgHsIrq0DAEFOTUZMAAAAAAAAAAAAFwAAFwAAyAAAAFZQOEwzAAAALxfABRAXIBBI8tyfYw2BQJLT/mwLBJL8\
        9QZ6/gP+FSho24ahWJJ3UDsCEf2fgPsIro0DAA==
        """

    static let svgValid = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="64" height="48" viewBox="0 0 64 48">
          <rect width="64" height="48" fill="#f0f0eb"/>
          <rect x="6" y="7" width="29" height="34" rx="3" fill="#2f6fc8"/>
          <circle cx="44" cy="24" r="12" fill="#d94c33"/>
        </svg>

        """

    /// Every way an SVG could ask for more: decoding it must fetch nothing.
    static let svgExternal = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="64" height="48" viewBox="0 0 64 48">
          <style>
            @import url("https://example.invalid/import.css");
            @font-face { font-family: Remote; src: url("https://example.invalid/font.woff2"); }
            .remote { fill: url("https://example.invalid/paint.svg#p"); font-family: Remote; }
          </style>
          <rect width="64" height="48" fill="#f0f0eb"/>
          <image href="https://example.invalid/x.png" x="0" y="0" width="32" height="48"/>
          <image xlink:href="https://example.invalid/y.png" x="32" y="0" width="32" height="48"/>
          <use href="https://example.invalid/sprite.svg#icon"/>
          <circle class="remote" cx="44" cy="24" r="12" fill="#d94c33"/>
          <text class="remote" x="4" y="44" font-size="8">remote</text>
        </svg>

        """

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    /// A 1 x 1 GIF, for the `data:` scheme.
    static let dataURL = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    mutating func images() throws {
        let started = now()
        let encodable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        let picture = Self.picture(width: 64, height: 48)
        var available: Set<String> = ["webp", "svg"]
        for (kind, type, ext) in [("png", UTType.png.identifier, "png"), ("jpeg", UTType.jpeg.identifier, "jpg"),
                                  ("gif", UTType.gif.identifier, "gif"), ("avif", "public.avif", "avif")] {
            let quality: [String: Any] = kind == "jpeg" || kind == "avif"
                ? [kCGImageDestinationLossyCompressionQuality as String: 0.9] : [:]
            guard encodable.contains(type), let data = Self.encode([(picture, quality)], type: type) else {
                imageEncoders[kind] = "unavailable"
                continue
            }
            imageEncoders[kind] = "ImageIO \(type)"
            available.insert(kind)
            try writeImage("images/files/valid.\(ext)", kind: kind, data, width: 64, height: 48, frames: 1)
        }
        imageEncoders["webp"] = "embedded (cwebp 1.6.0; ImageIO has no WebP encoder)"
        imageEncoders["webp-animated"] = "embedded (img2webp 1.6.0)"
        imageEncoders["svg"] = "hand-written"
        try writeImage("images/files/valid.webp", kind: "webp", Data(base64Encoded: Self.webpStill)!, width: 48, height: 32, frames: 1)
        try writeImage("images/files/animated.webp", kind: "webp-animated", Data(base64Encoded: Self.webpAnimated)!,
                       width: 24, height: 24, frames: 3)
        try writeImage("images/files/valid.svg", kind: "svg", Data(Self.svgValid.utf8), width: 64, height: 48)
        try writeImage("images/files/external.svg", kind: "svg", Data(Self.svgExternal.utf8), width: 64, height: 48)

        let delays = [0.1, 0.2, 0.3, 0.5]
        let gifFrames: [(CGImage, [String: Any])] = delays.indices.map { index in
            (Self.picture(width: 64, height: 48, frame: index),
             [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delays[index]]])
        }
        let animated = Self.encode(gifFrames, type: UTType.gif.identifier,
                                   properties: [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]])
        guard let animated else { throw BenchError.unavailable("ImageIO could not write an animated GIF") }
        imageEncoders["gif-animated"] = "ImageIO \(UTType.gif.identifier)"
        try writeImage("images/files/animated.gif", kind: "gif-animated", animated, width: 64, height: 48, frames: delays.count)

        // A valid signature and IHDR (64 x 48, so header-first sizing succeeds), then seeded noise.
        var random = Random(seed: seed, name: "corrupt.png")
        let header: [UInt8] = Self.bigEndian(64) + Self.bigEndian(48) + [8, 2, 0, 0, 0]
        let ihdr = Array("IHDR".utf8) + header
        var corrupt = Self.pngSignature + Self.bigEndian(UInt32(header.count)) + ihdr + Self.bigEndian(Self.crc32(ihdr))
        corrupt += (0..<4_096).map { _ in UInt8(truncatingIfNeeded: random.next()) }
        try writeImage("images/files/corrupt.png", kind: "corrupt", Data(corrupt), width: 64, height: 48)

        // A real 10,000 x 10,000 PNG: flat gray, streamed from a sequential provider (no 100 MB buffer).
        guard let huge = Self.encode([(Self.flatGray(width: 10_000, height: 10_000), [:])], type: UTType.png.identifier) else {
            throw BenchError.unavailable("ImageIO could not write the 10,000 x 10,000 PNG")
        }
        try writeImage("images/files/huge-10000.png", kind: "huge", huge, width: 10_000, height: 10_000, frames: 1)

        var colors = Random(seed: seed, name: "small-images")
        for index in 0..<500 {
            let image = Self.small(red: colors.int(0...255), green: colors.int(0...255), blue: colors.int(0...255), mark: index % 4)
            guard let data = Self.encode([(image, [:])], type: UTType.png.identifier) else {
                throw BenchError.unavailable("ImageIO could not write a small PNG")
            }
            try writeImage(String(format: "images/small/%03d.png", index), kind: "png", data, width: 16, height: 16, frames: 1, quiet: true)
        }
        let smallBytes = imageFiles.values.filter { $0.path.hasPrefix("images/small/") }.reduce(0) { $0 + ($1.bytes ?? 0) }
        print("  images/small/ (500 PNG files)".padding(toLength: 44, withPad: " ", startingAt: 0)
              + String(format: "%10.1f KiB", Double(smallBytes) / 1024))

        // A real image outside the images folder, reached by `..` and by an escaping link.
        guard let real = Self.encode([(picture, [:])], type: UTType.png.identifier) else {
            throw BenchError.unavailable("ImageIO could not write a PNG")
        }
        try writeImage("images-outside/real.png", kind: "png", real, width: 64, height: 48, frames: 1)
        try writeSymlink("images/files/escape.png", to: "../../images-outside/real.png", kind: "symlink-escape",
                         target: "images-outside/real.png")
        try writeSymlink("images/files/inside-link.png", to: "valid.png", kind: "symlink-inside", target: "images/files/valid.png")

        // One document per fixture type, each with a block and an inline image.
        let local: [(String, String, String, String)] = [
            ("png", "PNG", "files/valid.png", "png"), ("jpeg", "JPEG", "files/valid.jpg", "jpeg"),
            ("gif", "GIF", "files/valid.gif", "gif"), ("webp", "WebP", "files/valid.webp", "webp"),
            ("avif", "AVIF", "files/valid.avif", "avif"), ("gif-animated", "Animated GIF", "files/animated.gif", "gif-animated"),
            ("webp-animated", "Animated WebP", "files/animated.webp", "webp-animated"),
        ]
        for (name, title, source, kind) in local {
            try imageDocument(name, title: "\(title) image", intro: "A local \(title) file next to the document.",
                              cases: [ImageCase(title: title, source: source, kind: kind,
                                                expected: available.contains(kind) || kind.hasSuffix("animated") ? "ok" : "missing")])
        }
        try imageDocument("svg", title: "SVG image",
                          intro: "Local images are raster only, so the local SVG shows its alt text; the same file over HTTPS shows.",
                          cases: [ImageCase(title: "Local SVG", source: "files/valid.svg", kind: "svg", expected: "blocked"),
                                  ImageCase(title: "Remote SVG", source: "https://img.example.invalid/fixtures/valid.svg",
                                            kind: "remote-svg", expected: "ok", width: 64, height: 48)])
        try imageDocument("svg-external", title: "SVG with external references",
                          intro: "The SVG names remote images, an `@import`, a font and a paint server. Decoding it fetches nothing.",
                          cases: [ImageCase(title: "Local SVG", source: "files/external.svg", kind: "svg", expected: "blocked"),
                                  ImageCase(title: "Remote SVG", source: "https://img.example.invalid/fixtures/external.svg",
                                            kind: "remote-svg", expected: "ok", width: 64, height: 48)])
        try imageDocument("missing", title: "Missing image", intro: "The file does not exist.",
                          cases: [ImageCase(title: "Missing", source: "files/does-not-exist.png", kind: "missing", expected: "missing")])
        try imageDocument("corrupt", title: "Corrupt image", intro: "A PNG signature and header, then random bytes.",
                          cases: [ImageCase(title: "Corrupt", source: "files/corrupt.png", kind: "corrupt", expected: "corrupt")])
        try imageDocument("huge", title: "10,000 x 10,000 image", intro: "A real 10,000 x 10,000 PNG of one flat gray.",
                          cases: [ImageCase(title: "Huge", source: "files/huge-10000.png", kind: "huge", expected: "too-large")])
        try imageDocument("traversal", title: "Paths that leave the folder",
                          intro: "Only relative paths that stay inside the document's folder load, after resolving links.",
                          cases: [ImageCase(title: "Parent traversal", source: "../../etc/passwd.png", kind: "traversal", expected: "blocked"),
                                  ImageCase(title: "Traversal to a real image", source: "../images-outside/real.png",
                                            kind: "traversal", expected: "blocked"),
                                  ImageCase(title: "Absolute file URL", source: "file:///etc/passwd.png", kind: "file-url", expected: "blocked"),
                                  ImageCase(title: "Absolute path", source: "/etc/passwd.png", kind: "absolute-path", expected: "blocked"),
                                  ImageCase(title: "Escaping link", source: "files/escape.png", kind: "symlink-escape", expected: "blocked"),
                                  ImageCase(title: "Link inside the folder", source: "files/inside-link.png",
                                            kind: "symlink-inside", expected: "ok")])
        try images500()
        try badges()
        try remoteBlocks()
        print(String(format: "  images in %.1f s", milliseconds(started, now()) / 1000))
    }

    mutating func images500() throws {
        var maker = stream("images-500")
        var text = "# 500 small images\n\nFive hundred 16 x 16 PNG files, all inline, twenty to a paragraph.\n"
        for row in 0..<25 {
            text += "\nRow \(row + 1):"
            for column in 0..<20 {
                let source = String(format: "small/%03d.png", row * 20 + column)
                text += " ![s\(row * 20 + column)](\(source))"
                reference("images/images-500.md", source, placement: "inline", kind: "png", expected: "ok")
            }
            text += " \(maker.sentence())\n"
        }
        try write(Self.imagesGroup, "images-500", text)
    }

    mutating func badges() throws {
        let document = "images/badges.md"
        var random = Random(seed: seed, name: "badges")
        var text = """
            # Badges

            Rows of remote badges, as at the top of a README. The host `img.example.invalid` cannot resolve,
            so only the test stub serves them.

            """
        var number = 0
        func badge(_ random: inout Random) -> (String, String) {
            defer { number += 1 }
            switch random.int(0...9) {
            case 0...6: return ("https://img.example.invalid/badge/\(number).svg", "remote-svg")
            case 7, 8: return ("https://img.example.invalid/badge/\(number)", "remote-badge")
            default: return ("https://img.example.invalid/badge/\(number).png", "remote-png")
            }
        }
        for _ in 0..<30 {
            var row: [String] = []
            for _ in 0..<random.int(4...10) {
                let (source, kind) = badge(&random)
                row.append("[![badge \(number - 1)](\(source))](https://example.invalid/project/\(number - 1))")
                reference(document, source, placement: "inline", kind: kind, expected: "ok", width: 90, height: 20)
            }
            text += "\n" + row.joined(separator: " ") + "\n"
        }
        let (build, buildKind) = badge(&random)
        let (coverage, coverageKind) = badge(&random)
        text += "\nBadges inside a sentence: the build is ![build](\(build)) and coverage is ![coverage](\(coverage)) today.\n"
        reference(document, build, placement: "inline", kind: buildKind, expected: "ok", width: 90, height: 20)
        reference(document, coverage, placement: "inline", kind: coverageKind, expected: "ok", width: 90, height: 20)

        text += "\n## Blocked schemes\n\nHTTP and `data:` images show their alt text.\n\n"
        var blocked: [String] = []
        for index in 0..<3 {
            let source = "http://img.example.invalid/badge/http-\(index).svg"
            blocked.append("![http badge \(index)](\(source))")
            reference(document, source, placement: "inline", kind: "http", expected: "blocked")
        }
        blocked.append("![data badge](\(Self.dataURL))")
        reference(document, Self.dataURL, placement: "inline", kind: "data", expected: "blocked")
        text += blocked.joined(separator: " ") + "\n"
        try write(Self.imagesGroup, "badges", text)
    }

    mutating func remoteBlocks() throws {
        var maker = stream("remote-block")
        var text = "# Remote block images\n\nLarge remote images, each alone in its paragraph. The test stub serves them.\n"
        let blocks: [(Int, Int, String, String)] = [
            (1600, 900, "png", "remote-png"), (2400, 1600, "jpg", "remote-jpeg"), (3840, 2160, "png", "remote-png"),
            (4000, 3000, "jpg", "remote-jpeg"), (1200, 4000, "png", "remote-png"), (2000, 500, "svg", "remote-svg"),
            (1280, 720, "gif", "remote-gif"), (3000, 2000, "webp", "remote-webp"),
        ]
        for (width, height, ext, kind) in blocks {
            let source = "https://img.example.invalid/block/\(width)x\(height).\(ext)"
            text += "\n\(maker.paragraph())\n\n![\(width) x \(height) \(ext)](\(source))\n"
            reference("images/remote-block.md", source, placement: "block", kind: kind, expected: "ok", width: width, height: height)
        }
        text += "\n\(maker.paragraph())\n"
        try write(Self.imagesGroup, "remote-block", text)
    }

    static let imagesGroup = "images"

    mutating func imageDocument(_ name: String, title: String, intro: String, cases: [ImageCase]) throws {
        var text = "# \(title)\n\n\(intro)\n"
        let document = "\(Self.imagesGroup)/\(name).md"
        for item in cases {
            if cases.count > 1 { text += "\n## \(item.title)\n" }
            text += "\nA block image, alone in its paragraph:\n\n![\(item.title), block](\(item.source))\n"
            text += "\nAn inline image ![\(item.title), inline](\(item.source)) sits in this line of text, and the line goes on after it.\n"
            for placement in ["block", "inline"] {
                reference(document, item.source, placement: placement, kind: item.kind, expected: item.expected,
                          width: item.width, height: item.height)
            }
        }
        try write(Self.imagesGroup, name, text)
    }

    mutating func reference(_ document: String, _ source: String, placement: String, kind: String, expected: String,
                            width: Int? = nil, height: Int? = nil) {
        let relative = !source.hasPrefix("/") && !source.contains(":")
        let path = relative ? Self.normalized((document as NSString).deletingLastPathComponent + "/" + source) : nil
        let file = path.flatMap { imageFiles[$0] }
        imageReferences.append(ImageReference(document: document, source: source, placement: placement, kind: kind, path: path,
                                              width: width ?? file?.width, height: height ?? file?.height, expected: expected))
    }

    /// Resolves `.` and `..` in a relative path; leading `..` stay when it climbs above the root.
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == "..", let last = parts.last, last != ".." { parts.removeLast() } else { parts.append(part) }
        }
        return parts.joined(separator: "/")
    }

    mutating func writeImage(_ path: String, kind: String, _ data: Data, width: Int?, height: Int?, frames: Int? = nil,
                             quiet: Bool = false) throws {
        let url = output.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        imageFiles[path] = ImageFile(path: path, kind: kind, width: width, height: height, frames: frames, bytes: data.count,
                                     sha256: sha, symlink: nil)
        if !quiet {
            print("  \(path)".padding(toLength: 44, withPad: " ", startingAt: 0) + String(format: "%10.1f KiB", Double(data.count) / 1024))
        }
    }

    /// `target` is the file the link resolves to, relative to the manifest's root.
    mutating func writeSymlink(_ path: String, to destination: String, kind: String, target: String) throws {
        let url = output.appendingPathComponent(path)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        let file = imageFiles[target]
        imageFiles[path] = ImageFile(path: path, kind: kind, width: file?.width, height: file?.height, frames: file?.frames,
                                     bytes: nil, sha256: nil, symlink: destination)
        print("  \(path) -> \(destination)")
    }

    static func encode(_ frames: [(CGImage, [String: Any])], type: String, properties: [String: Any] = [:]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, frames.count, nil) else {
            return nil
        }
        CGImageDestinationSetProperties(destination, properties as CFDictionary)
        for (image, frameProperties) in frames { CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary) }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func context(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    }

    /// An off-white background, a blue rectangle and a red circle; `frame` moves the circle.
    static func picture(width: Int, height: Int, frame: Int = 0) -> CGImage {
        let context = context(width: width, height: height)
        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(red: 0.94, green: 0.94, blue: 0.92, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(red: 0.18, green: 0.44, blue: 0.78, alpha: 1)
        context.fill(CGRect(x: w * 0.1, y: h * 0.15, width: w * 0.45, height: h * 0.7))
        context.setFillColor(red: 0.85, green: 0.3, blue: 0.2, alpha: 1)
        context.fillEllipse(in: CGRect(x: w * 0.5 + CGFloat(frame) * w * 0.08, y: h * 0.25, width: h * 0.5, height: h * 0.5))
        return context.makeImage()!
    }

    /// One color with a small white square in one of four corners.
    static func small(red: Int, green: Int, blue: Int, mark: Int) -> CGImage {
        let context = context(width: 16, height: 16)
        context.setFillColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: mark % 2 == 0 ? 2 : 9, y: mark < 2 ? 2 : 9, width: 5, height: 5))
        return context.makeImage()!
    }

    /// A flat 8-bit gray image whose rows are produced on demand.
    static func flatGray(width: Int, height: Int) -> CGImage {
        var callbacks = CGDataProviderSequentialCallbacks(
            version: 0,
            getBytes: { _, buffer, count in memset(buffer, 0x6c, count); return count },
            skipForward: { _, count in count },
            rewind: { _ in },
            releaseInfo: { _ in })
        let provider = CGDataProvider(sequentialInfo: nil, callbacks: &callbacks)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> UInt32($0)) } }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
