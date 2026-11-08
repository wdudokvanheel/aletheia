import CryptoKit
import Foundation

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
        let pending: [String: String]
    }

    let output: URL
    let seed: UInt64
    private(set) var files: [File] = []
    private(set) var traces: [TraceFile] = []

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
        // Phase 7: image fixtures (PNG, JPEG, GIF, WebP, AVIF, SVG, animated GIF, missing, corrupt,
        // 10,000 x 10,000, 500 small images, remote badges and blocks served by the test stub) go here.
        try writeTraces(mixed100k: mixed100k, table1500: table1500)

        let manifest = GeneratedManifest(
            generator: "MarkdownViewBench generate", version: 1, seed: seed, root: ".",
            sets: ["generated": files], traces: traces,
            pending: ["images": "Phase 7: image fixtures are not generated yet"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: output.appendingPathComponent("generated-manifest.json"))
        let total = files.reduce(0) { $0 + $1.bytes }
        print(String(format: "wrote %d documents (%.1f MiB) and %d traces in %.1f s; manifest %@",
                     files.count, Double(total) / 1_048_576, traces.count, milliseconds(started, now()) / 1000,
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

    mutating func writeTraces(mixed100k: String, table1500: String) throws {
        var list: [Trace] = []
        let end = (mixed100k as NSString).length
        list.append(Trace(name: "append-paragraph", description: "Type a new paragraph at the end of sizes/mixed-100k.md.",
                          base: mixed100k,
                          edits: Self.typing("\nA new paragraph typed at the end of the document, one key at a time.", at: end)))

        let table = table1500 as NSString
        let row = table.range(of: "\n| 750 | ")
        let lineEnd = table.range(of: "\n", range: NSRange(location: row.location + 1, length: table.length - row.location - 1)).location
        // The end of the third cell: skip "| 750 | ", then two unescaped pipes.
        var cursor = row.location + 1
        var pipes = 0
        while cursor < lineEnd, pipes < 4 {
            if table.character(at: cursor) == 0x7C, table.character(at: cursor - 1) != 0x5C { pipes += 1 }
            cursor += 1
        }
        let cellEnd = cursor - 2 // before " |"
        var tableEdits = Self.typing(" edited", at: cellEnd)
        for index in 0..<3 { tableEdits.append(TraceEdit(location: cellEnd + 6 - index, length: 1, replacement: "")) }
        list.append(Trace(name: "table-cell", description: "Type into the third cell of row 750 of tables/rows-1500-cols-4.md, then delete three characters.",
                          base: table1500, edits: tableEdits))

        let fenceAt = Self.middleBlockStart(mixed100k, paragraph: true)
        var fence = Self.typing("```\n", at: fenceAt)
        fence += Self.typing("let value = 1\n", at: fenceAt + 4)
        fence += Self.typing("```\n", at: fenceAt + 18)
        list.append(Trace(name: "fence-open-close", description: "Open a code fence in the middle of sizes/mixed-100k.md, type a line, then close it.",
                          base: mixed100k, edits: fence))

        var deletions: [TraceEdit] = []
        var current = mixed100k as NSString
        let blockAt = Self.middleBlockStart(mixed100k)
        for _ in 0..<3 {
            let next = current.range(of: "\n\n", range: NSRange(location: blockAt, length: current.length - blockAt))
            let length = (next.location == NSNotFound ? current.length : next.location + 2) - blockAt
            deletions.append(TraceEdit(location: blockAt, length: length, replacement: ""))
            current = current.replacingCharacters(in: NSRange(location: blockAt, length: length), with: "") as NSString
        }
        list.append(Trace(name: "delete-block", description: "Delete three consecutive blocks in the middle of sizes/mixed-100k.md, one edit each.",
                          base: mixed100k, edits: deletions))

        var maker = stream("link-reference-definition")
        var referenced = ""
        for (index, block) in mixed100k.components(separatedBy: "\n\n").enumerated() {
            referenced += (index == 0 ? "" : "\n\n") + block
            if index % 25 == 12 { referenced += "\n\n\(maker.sentence()) See [the bench reference][bench-ref] for details." }
        }
        let referencedEnd = (referenced as NSString).length
        list.append(Trace(name: "link-reference-definition",
                          description: "Type a link reference definition at the end; earlier [bench-ref] uses become links.",
                          base: referenced, edits: Self.typing("\n[bench-ref]: https://example.com/reference", at: referencedEnd)))

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
