import Foundation
import XCTest
@testable import MarkdownView

/// Incremental updates must produce the same snapshot as laying out the new
/// source from scratch, while reusing what did not change.
final class IncrementalUpdateTests: XCTestCase {
    private let width: CGFloat = 700

    private static let generated = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/markdown-corpus/generated")

    private func generatedFile(_ path: String) throws -> URL {
        let url = Self.generated.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Run `swift run -c release MarkdownViewBench generate` in Packages/MarkdownView for \(path)")
        }
        return url
    }

    private func full(_ source: String) throws -> MarkdownSnapshot {
        MarkdownSnapshot.layOut(try MarkdownDocument.parse(source), width: width)
    }

    private func assertEquivalent(_ incremental: MarkdownSnapshot, _ full: MarkdownSnapshot, _ context: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(incremental.document.blocks.count, full.document.blocks.count, context, file: file, line: line)
        guard incremental.document.blocks.count == full.document.blocks.count else { return }
        for (index, (a, b)) in zip(incremental.document.blocks, full.document.blocks).enumerated() where a != b {
            XCTFail("\(context): block \(index) differs: \(a.text.prefix(60).debugDescription) vs "
                    + "\(b.text.prefix(60).debugDescription)", file: file, line: line)
            return
        }
        XCTAssertEqual(incremental.layouts.map(\.height), full.layouts.map(\.height), context, file: file, line: line)
        XCTAssertEqual(incremental.layouts.map(\.lineCount), full.layouts.map(\.lineCount), context, file: file, line: line)
        XCTAssertEqual(incremental.blockTops, full.blockTops, context, file: file, line: line)
        XCTAssertEqual(incremental.totalHeight, full.totalHeight, context, file: file, line: line)
        XCTAssertTrue(incremental.isComplete, context, file: file, line: line)
    }

    /// Applies `edits` one by one, each against the snapshot of the previous
    /// step, and compares with a full rebuild every `checkEvery` steps and at
    /// the end. Returns the layouts reused over all steps.
    @discardableResult
    private func replay(_ base: String, _ edits: [(location: Int, length: Int, replacement: String)], _ name: String,
                        checkEvery: Int = 1, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        var text = base
        var snapshot = try full(text)
        var reused = 0
        for (step, edit) in edits.enumerated() {
            text = (text as NSString).replacingCharacters(in: NSRange(location: edit.location, length: edit.length),
                                                          with: edit.replacement)
            let result = try MarkdownSnapshot.updating(snapshot, to: text, width: width)
            snapshot = result.snapshot
            reused += result.reused
            XCTAssertEqual(result.reused + result.laidOut, snapshot.layouts.count, file: file, line: line)
            if step % checkEvery == 0 || step == edits.count - 1 {
                assertEquivalent(snapshot, try full(text), "\(name) step \(step)", file: file, line: line)
            }
        }
        return reused
    }

    // MARK: Equivalence

    func testTypingTracesMatchAFullRebuild() throws {
        struct Trace: Decodable {
            struct Edit: Decodable {
                let location: Int
                let length: Int
                let replacement: String
            }
            let name: String
            let base: String
            let edits: [Edit]
        }
        let directory = try generatedFile("traces")
        // The five traces on 100 KiB documents; their 1 MiB versions are for the bench.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") && !$0.hasSuffix("-1m.json") }.sorted()
        XCTAssertEqual(names.count, 5)
        for name in names {
            let trace = try JSONDecoder().decode(Trace.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
            let reused = try replay(trace.base, trace.edits.map { ($0.location, $0.length, $0.replacement) }, trace.name,
                                    checkEvery: trace.edits.count > 20 ? 4 : 1)
            if trace.name != "link-reference-definition" {
                XCTAssertGreaterThan(reused, 0, trace.name)
            }
        }
    }

    func testOneCharacterEditsInCorpusDocumentsMatchAFullRebuild() throws {
        for path in ["sizes/mixed-10k.md", "sizes/prose-10k.md", "sizes/code-10k.md", "sizes/mixed-100k.md",
                     "nesting/lists-20-deep.md", "nesting/quotes-20-deep.md", "unicode/mixed-scripts.md",
                     "links/reference-links-1000.md", "links/autolinks-1000.md", "tables/rows-160-cols-4.md",
                     "pathological/unclosed-fence-top.md"] {
            let text = try String(contentsOf: try generatedFile(path), encoding: .utf8)
            let length = (text as NSString).length
            // Typing, deleting, and splitting a block at a few places.
            var edits: [(Int, Int, String)] = []
            for fraction in [0.0, 0.31, 0.5, 0.77, 1.0] {
                var location = Int(Double(length) * fraction)
                if location > 0, location < length, UTF16.isTrailSurrogate((text as NSString).character(at: location)) {
                    location -= 1
                }
                edits += [(location, 0, "x"), (location, 1, ""), (location, 0, "\n\n")]
            }
            // Each edit applies to the original text.
            for edit in edits where edit.0 + edit.1 <= length {
                try replay(text, [edit], "\(path) \(edit)")
            }
        }
    }

    func testRandomEditsMatchAFullRebuild() throws {
        try randomEdits(seed: 4, documents: 6, steps: 60)
    }

    /// Random insertions, deletions, and replacements of Markdown fragments,
    /// each compared with a full rebuild, with selections and scroll
    /// positions carried across.
    func randomEdits(seed: UInt64, documents: Int, steps: Int) throws {
        let fragments = ["a", "word ", " ", "\n", "\n\n", "# ", "## ", "- ", "1. ", "> ", "```", "```\n", "~~~\n", "`",
                         "*", "**", "_", "~~", "[", "]", "](https://example.com)", "[ref]", "[ref]: https://example.com/r\n",
                         "[Ref]:\n/x\n", "|", " | ", "\n| a | b |\n| --- | :-: |\n| 1 | 2 |\n", "---\n", "***", "<div>\n",
                         "</div>", "<b>", "    ", "\t", "  ", "é", "👍", "日本語", "שלום", "&amp;", "&#x1F44D;", "\\", "\\*",
                         "- [ ] ", "- [x] ", "===\n", "  \n", "\r\n", "www.example.com", "<https://a.b>"]
        var random = SplitMix64(seed: seed)
        for document in 0..<documents {
            var text = Self.corpusLikeDocument(&random, blocks: 40 + document * 10)
            var snapshot = try full(text)
            for step in 0..<steps {
                var scalars = Array(text.unicodeScalars)
                let position = Int(random.next() % UInt64(scalars.count + 1))
                switch random.next() % 4 {
                case 0, 1:
                    scalars.insert(contentsOf: fragments[Int(random.next() % UInt64(fragments.count))].unicodeScalars,
                                   at: position)
                case 2:
                    let length = min(Int(random.next() % 40) + 1, scalars.count - position)
                    scalars.removeSubrange(position..<(position + length))
                default:
                    let length = min(Int(random.next() % 8), scalars.count - position)
                    scalars.replaceSubrange(position..<(position + length),
                                            with: fragments[Int(random.next() % UInt64(fragments.count))].unicodeScalars)
                }
                text = String(String.UnicodeScalarView(scalars))
                let old = snapshot
                snapshot = try MarkdownSnapshot.updating(snapshot, to: text, width: width).snapshot
                assertEquivalent(snapshot, try full(text), "seed \(seed) document \(document) step \(step)")
                // Selections and scroll positions carry across into valid places.
                let update = try XCTUnwrap(snapshot.update(from: old))
                for _ in 0..<4 where !old.layouts.isEmpty {
                    func randomPosition() -> TextPosition {
                        let block = Int(random.next() % UInt64(old.layouts.count))
                        return TextPosition(block: block, offset: Int(random.next() % UInt64(old.layouts[block].textLength + 1)))
                    }
                    let ends = [randomPosition(), randomPosition()].sorted()
                    if let mapped = snapshot.mapRange(ends[0]..<ends[1], from: old) {
                        XCTAssertLessThanOrEqual(mapped.lowerBound, mapped.upperBound)
                        XCTAssertLessThan(mapped.upperBound.block, snapshot.layouts.count)
                        XCTAssertLessThanOrEqual(mapped.upperBound.offset, snapshot.layouts[mapped.upperBound.block].textLength)
                    }
                    let y = snapshot.anchoredY(CGFloat(random.next() % UInt64(max(old.totalHeight, 1))), from: old, through: update)
                    XCTAssertTrue(y.isFinite && y >= 0)
                }
            }
        }
    }

    /// Headings, paragraphs with inline markup, lists, quotes, code, tables,
    /// rules, HTML, and reference links with their definitions.
    private static func corpusLikeDocument(_ random: inout SplitMix64, blocks: Int) -> String {
        let words = ["preview", "layout", "block", "*emphasis*", "**strong**", "`code`", "[link](https://example.com)",
                     "[ref]", "~~gone~~", "text", "wrapping", "line", "é", "日本", "👍"]
        func sentence(_ count: Int) -> String {
            (0..<count).map { _ in words[Int(random.next() % UInt64(words.count))] }.joined(separator: " ")
        }
        var parts: [String] = []
        for _ in 0..<blocks {
            switch random.next() % 10 {
            case 0: parts.append("## " + sentence(3))
            case 1: parts.append((0..<3).map { _ in "- " + sentence(4) }.joined(separator: "\n"))
            case 2: parts.append("> " + sentence(12))
            case 3: parts.append("```\nlet x = 1\n  indented()\n```")
            case 4: parts.append("| a | b |\n| --- | --- |\n| " + sentence(2) + " | " + sentence(2) + " |")
            case 5: parts.append("---")
            case 6: parts.append("<div>\nraw\n</div>")
            case 7: parts.append("    indented code")
            default: parts.append(sentence(20))
            }
        }
        parts.append("[ref]: https://example.com/ref")
        return parts.joined(separator: "\n\n")
    }

    // MARK: Reuse

    private let document = """
    # Title

    First paragraph.

    Second paragraph with a [link](https://example.com).

    - one
    - two

    ```
    code
    ```

    Last paragraph.
    """

    func testEditingOneParagraphReusesEveryOtherLayout() throws {
        let base = try full(document)
        let edited = document.replacingOccurrences(of: "Second paragraph", with: "Second, longer paragraph")
        let (snapshot, reused, laidOut) = try MarkdownSnapshot.updating(base, to: edited, width: width)
        XCTAssertEqual(reused, 5)
        XCTAssertEqual(laidOut, 1)
        for index in snapshot.layouts.indices where index != 2 {
            XCTAssertTrue(snapshot.layouts[index] === base.layouts[index], "block \(index)")
        }
        XCTAssertFalse(snapshot.layouts[2] === base.layouts[2])
        XCTAssertEqual(snapshot.document.blocks[2].text, "Second, longer paragraph with a link.")
        assertEquivalent(snapshot, try full(edited), "paragraph edit")
    }

    func testInsertedAndMovedBlocksAreMatchedByContent() throws {
        let base = try full(document)
        // A new block at the top shifts every index; swapping two blocks moves them.
        let inserted = try MarkdownSnapshot.updating(base, to: "New.\n\n" + document, width: width)
        XCTAssertEqual(inserted.reused, 6)
        XCTAssertTrue(inserted.snapshot.layouts[1] === base.layouts[0])
        let swapped = document.replacingOccurrences(of: "First paragraph.\n\nSecond paragraph with a [link](https://example.com).",
                                                    with: "Second paragraph with a [link](https://example.com).\n\nFirst paragraph.")
        let moved = try MarkdownSnapshot.updating(base, to: swapped, width: width)
        XCTAssertEqual(moved.reused, 6)
        XCTAssertTrue(moved.snapshot.layouts[1] === base.layouts[2])
        XCTAssertTrue(moved.snapshot.layouts[2] === base.layouts[1])
        assertEquivalent(moved.snapshot, try full(swapped), "swap")
    }

    func testAddingALinkReferenceDefinitionRebuildsEverything() throws {
        let source = "Uses [ref] here.\n\nAnother paragraph.\n\n# Heading"
        let base = try full(source)
        XCTAssertEqual(base.document.blocks[0].links, [])
        let defined = source + "\n\n[ref]: https://example.com"
        let (snapshot, reused, laidOut) = try MarkdownSnapshot.updating(base, to: defined, width: width)
        XCTAssertEqual(reused, 0)
        XCTAssertEqual(laidOut, 3)
        XCTAssertNil(snapshot.update?.match)
        XCTAssertEqual(snapshot.document.blocks[0].text, "Uses ref here.")
        XCTAssertEqual(snapshot.document.blocks[0].links.map(\.destination), ["https://example.com"])
        assertEquivalent(snapshot, try full(defined), "definition added")
        // Editing another block afterwards reuses again.
        let edited = defined.replacingOccurrences(of: "Another", with: "One more")
        XCTAssertEqual(try MarkdownSnapshot.updating(snapshot, to: edited, width: width).reused, 2)
        // Changing the definition rebuilds again, even inside another block.
        let nested = defined.replacingOccurrences(of: "# Heading", with: "> [other]: /x\n> quoted")
        XCTAssertEqual(try MarkdownSnapshot.updating(snapshot, to: nested, width: width).reused, 0)
    }

    func testWidthChangeRebuildsEveryLayout() throws {
        let base = try full(document)
        let edited = document.replacingOccurrences(of: "Last", with: "Final")
        let (snapshot, reused, laidOut) = try MarkdownSnapshot.updating(base, to: edited, width: 400)
        XCTAssertEqual(reused, 0)
        XCTAssertEqual(laidOut, 6)
        XCTAssertTrue(zip(snapshot.layouts, base.layouts).allSatisfy { $0 !== $1 })
        XCTAssertEqual(snapshot.layouts.map(\.columnWidth), Array(repeating: snapshot.columnWidth, count: 6))
    }

    func testBlocksWithoutSourcePositionsNeverMatch() throws {
        // cmark-gfm splits the line before a table header into a paragraph
        // without a position; two of them must not pass for equal.
        let base = "Intro.\n\nfirst line\n| a | b |\n| --- | --- |\n| 1 | 2 |"
        let parsed = try MarkdownDocument.parse(base)
        XCTAssertEqual(parsed.blocks.map(\.kind), [.paragraph, .paragraph, .table])
        XCTAssertEqual(parsed.blocks[1].text, "first line")
        XCTAssertTrue(parsed.blocks[1].sourceRange.isEmpty)
        XCTAssertEqual(parsed.blocks[1].sourceRange.lowerBound, parsed.blocks[0].sourceRange.upperBound,
                       "ranges stay in source order")
        let edited = base.replacingOccurrences(of: "first line", with: "second line")
        let (snapshot, reused, _) = try MarkdownSnapshot.updating(full(base), to: edited, width: width)
        XCTAssertEqual(reused, 1)
        assertEquivalent(snapshot, try full(edited), "positionless paragraph")
    }

    func testIndentationChangeRebuildsTheBlock() throws {
        // The same list text: the indentation decides whether `b` is code.
        let indented = "Intro.\n\n  - a\n\n      b"
        let plain = "Intro.\n\n- a\n\n      b"
        XCTAssertEqual(try MarkdownDocument.parse(indented).blocks[1].sourceText,
                       try MarkdownDocument.parse(plain).blocks[1].sourceText)
        let base = try full(indented)
        let (snapshot, reused, _) = try MarkdownSnapshot.updating(base, to: plain, width: width)
        XCTAssertEqual(reused, 1)
        XCTAssertNotEqual(snapshot.document.blocks[1].styleRuns, base.document.blocks[1].styleRuns)
        assertEquivalent(snapshot, try full(plain), "indentation")
    }

    // MARK: Selection and scrolling across updates

    private func position(_ block: Int, _ offset: Int) -> TextPosition {
        TextPosition(block: block, offset: offset)
    }

    func testDeletingABlockMapsTheSelection() throws {
        let source = "Intro.\n\nDoomed block.\n\nThe selected words are here.\n\nTail."
        let base = try full(source)
        let selected = position(2, 4)..<position(2, 18)
        XCTAssertEqual(base.text(in: selected), "selected words")
        let removed = source.replacingOccurrences(of: "Doomed block.\n\n", with: "")
        let snapshot = try MarkdownSnapshot.updating(base, to: removed, width: width).snapshot
        let mapped = try XCTUnwrap(snapshot.mapRange(selected, from: base))
        XCTAssertEqual(mapped, position(1, 4)..<position(1, 18))
        // A selection inside the deleted block clears; one reaching into it is gone too.
        XCTAssertNil(snapshot.mapRange(position(1, 0)..<position(1, 6), from: base))
        XCTAssertNil(snapshot.mapRange(position(0, 2)..<position(1, 3), from: base))
        // Across the deleted block, both ends survive.
        XCTAssertEqual(snapshot.mapRange(position(0, 2)..<position(2, 3), from: base), position(0, 2)..<position(1, 3))
    }

    func testEditingAboveTheSelectionShiftsIt() throws {
        let source = "Intro.\n\nMiddle.\n\nThe selected words are here.\n\nTail."
        let base = try full(source)
        let selected = position(2, 4)..<position(2, 18)
        let edited = source.replacingOccurrences(of: "Intro.", with: "A much longer introduction.\n\nAnd a new block.")
        let snapshot = try MarkdownSnapshot.updating(base, to: edited, width: width).snapshot
        let mapped = try XCTUnwrap(snapshot.mapRange(selected, from: base))
        XCTAssertEqual(mapped, position(3, 4)..<position(3, 18))
        XCTAssertEqual(snapshot.text(in: mapped), "selected words")
    }

    func testEditingInsideTheSelectedBlockFollowsTheSourceEdit() throws {
        let source = "Intro.\n\nThe **selected** words are here.\n\nTail."
        let base = try full(source)
        let selected = position(1, 4)..<position(1, 18)
        XCTAssertEqual(base.text(in: selected), "selected words")
        func mapped(_ edited: String) throws -> String? {
            let snapshot = try MarkdownSnapshot.updating(base, to: edited, width: width).snapshot
            return snapshot.mapRange(selected, from: base).map { snapshot.text(in: $0) }
        }
        // Before, after, and inside the selection; typing at its ends does not extend it.
        XCTAssertEqual(try mapped("Intro.\n\nSo The **selected** words are here.\n\nTail."), "selected words")
        XCTAssertEqual(try mapped("Intro.\n\nThe **selected** words, edited, are here.\n\nTail."), "selected words")
        XCTAssertEqual(try mapped("Intro.\n\nThe **selected** few words are here.\n\nTail."), "selected few words")
        XCTAssertEqual(try mapped("Intro.\n\nThe x**selected** words are here.\n\nTail."), "selected words")
        XCTAssertEqual(try mapped("Intro.\n\nThe **selected** wordsy are here.\n\nTail."), "selected words")
        XCTAssertEqual(try mapped("Intro.\n\nThe **selectedy** words are here.\n\nTail."), "selectedy words")
        // Splitting the block keeps both ends in the parts they were in.
        XCTAssertEqual(try mapped("Intro.\n\nThe **selected**\n\nwords are here.\n\nTail."), "selected\nwords")
        // Edits coalesced from two places: positions between them follow the text.
        XCTAssertEqual(try mapped("Intro, changed.\n\nThe **selected** words are here, too.\n\nTail."),
                       "selected words")
        // Replacing the whole block clears it.
        XCTAssertNil(try mapped("Intro.\n\nSomething else.\n\nTail."))
        XCTAssertNil(try mapped("Intro.\n\nTail."))
    }

    func testSourceEditMapsOffsets() {
        let insertion = SourceEdit(old: 5..<5, new: 5..<8)
        XCTAssertEqual(insertion.map(4, upstream: false), 4)
        XCTAssertEqual(insertion.map(5, upstream: true), 5)
        XCTAssertEqual(insertion.map(5, upstream: false), 8)
        XCTAssertEqual(insertion.map(9, upstream: true), 12)
        let replacement = SourceEdit(old: 4..<12, new: 4..<6)
        XCTAssertEqual(replacement.map(6, upstream: false), 6)
        XCTAssertEqual(replacement.map(10, upstream: true), 6)
        XCTAssertEqual(replacement.map(12, upstream: true), 6)
        XCTAssertEqual(replacement.map(13, upstream: false), 7)
    }

    func testSourceEditFallsOnScalarBoundaries() throws {
        let old = "Before 👍 after."
        let base = try MarkdownDocument.parse(old)
        // The two emoji share their first three UTF-8 bytes.
        let edit = try MarkdownDocument.parse("Before 👎 after.", reusing: base).edit
        XCTAssertEqual(edit, SourceEdit(old: 7..<9, new: 7..<9))
        XCTAssertEqual(try MarkdownDocument.parse("Before 👍👍 after.", reusing: base).edit.new.count, 2)
        XCTAssertEqual(try MarkdownDocument.parse(old, reusing: base).edit, SourceEdit(old: 16..<16, new: 16..<16))
    }

    func testAnchoringFollowsTheTopVisibleBlock() throws {
        let paragraphs = (0..<30).map { "Paragraph \($0) with a few words." }
        let base = try full(paragraphs.joined(separator: "\n\n"))
        let y = base.blockTops[10] + 5
        var grown = paragraphs
        grown[0] += String(repeating: " more words to wrap", count: 20)
        grown[12] += " and below"
        let snapshot = try MarkdownSnapshot.updating(base, to: grown.joined(separator: "\n\n"), width: width).snapshot
        let update = try XCTUnwrap(snapshot.update)
        XCTAssertGreaterThan(snapshot.blockTops[10], base.blockTops[10])
        XCTAssertEqual(snapshot.anchoredY(y, from: base, through: update), snapshot.blockTops[10] + 5)
        // At the top, the view stays at the top.
        XCTAssertEqual(snapshot.anchoredY(0, from: base, through: update), 0)
        // An edited top block keeps its top in place, also when the edit was
        // coalesced with one above it.
        let inside = base.blockTops[12] + 3
        XCTAssertEqual(snapshot.anchoredY(inside, from: base, through: update), snapshot.blockTops[12] + 3)
        var typed = paragraphs
        typed[12] += " typed"
        let single = try MarkdownSnapshot.updating(base, to: typed.joined(separator: "\n\n"), width: width).snapshot
        XCTAssertEqual(single.anchoredY(inside, from: base, through: try XCTUnwrap(single.update)),
                       single.blockTops[12] + 3)
        // A deleted top block leaves the next one where it started.
        var deleted = paragraphs
        deleted.remove(at: 12)
        let removed = try MarkdownSnapshot.updating(base, to: deleted.joined(separator: "\n\n"), width: width).snapshot
        XCTAssertEqual(removed.anchoredY(inside, from: base, through: try XCTUnwrap(removed.update)),
                       removed.blockTops[12] + 3)
    }

    func testChangedRectsCoverTheEditedBlockAndWhatMoved() throws {
        let paragraphs = (0..<30).map { "Paragraph \($0) with a few words." }
        let base = try full(paragraphs.joined(separator: "\n\n"))
        let visible = CGRect(x: 0, y: base.blockTops[4], width: width, height: 400)
        var same = paragraphs
        same[6] = "Paragraph 6 with a few wordz."
        let sameHeight = try MarkdownSnapshot.updating(base, to: same.joined(separator: "\n\n"), width: width).snapshot
        let rects = try XCTUnwrap(sameHeight.changedRects(from: base, in: visible))
        XCTAssertEqual(rects.count, 1)
        XCTAssertLessThanOrEqual(rects[0].minY, sameHeight.blockTops[6])
        XCTAssertGreaterThanOrEqual(rects[0].maxY, sameHeight.blockTops[6] + sameHeight.layouts[6].height)
        XCTAssertLessThan(rects[0].maxY, sameHeight.blockTops[8])
        var taller = paragraphs
        taller[6] += String(repeating: " more words to wrap", count: 10)
        let grown = try MarkdownSnapshot.updating(base, to: taller.joined(separator: "\n\n"), width: width).snapshot
        let grownRects = try XCTUnwrap(grown.changedRects(from: base, in: visible))
        XCTAssertEqual(grownRects.map(\.maxY).max(), visible.maxY)
        XCTAssertGreaterThan(grownRects.map(\.minY).min() ?? 0, base.blockTops[5])
        // An edit outside the visible area redraws nothing; another base redraws everything.
        var below = paragraphs
        below[28] += " x"
        let offscreen = try MarkdownSnapshot.updating(base, to: below.joined(separator: "\n\n"), width: width).snapshot
        XCTAssertEqual(offscreen.changedRects(from: base, in: visible), [])
        XCTAssertNil(offscreen.changedRects(from: grown, in: visible))
    }
}

/// A small seeded generator, so random edits replay identically.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
