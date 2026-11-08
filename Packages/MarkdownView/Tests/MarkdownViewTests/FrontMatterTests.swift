import XCTest
@testable import MarkdownView

/// Front matter at the top of a file shows as a key/value table, or as a
/// monospaced block when it is not simple pairs, and the rest of the file
/// keeps its source offsets.
final class FrontMatterTests: XCTestCase {
    private func parse(_ source: String) throws -> [MarkdownBlock] {
        try MarkdownDocument.parse(source).blocks
    }

    private func snapshot(_ source: String) throws -> MarkdownSnapshot {
        MarkdownSnapshot.layOut(try MarkdownDocument.parse(source), width: 700)
    }

    func testSimplePairsShowAsAKeyValueTable() throws {
        let source = "---\ntitle: Hello, world\nlayout:   post  \n\nempty:\nurl: https://example.com/a:b\n---\n\n# Heading\n\nText"
        let blocks = try parse(source)
        XCTAssertEqual(blocks.map(\.kind), [.table, .heading(level: 1), .paragraph])
        let matter = blocks[0]
        XCTAssertTrue(matter.isFrontMatter)
        XCTAssertFalse(blocks[1].isFrontMatter)
        XCTAssertEqual(matter.sourceRange, 0..<(source as NSString).range(of: "\n---\n").upperBound - 1)
        XCTAssertEqual(matter.text, "title\tHello, world\nlayout\tpost\nempty\t\nurl\thttps://example.com/a:b")
        let table = try XCTUnwrap(matter.tables.first)
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertFalse(table.hasHeader, "no header row")
        XCTAssertEqual(table.rowCount, 4)
        // Keys take the muted quote role; values the body.
        XCTAssertEqual(matter.styleRuns.first, StyleRun(range: 0..<5, role: .quote))
        XCTAssertEqual(matter.styleRuns[1].role, .body)
        // Display offsets map back to the source.
        let value = (matter.text as NSString).range(of: "post").location
        XCTAssertEqual(matter.sourceOffset(forDisplayOffset: value), (source as NSString).range(of: "post").location)
        let key = (matter.text as NSString).range(of: "url").location
        XCTAssertEqual(matter.sourceOffset(forDisplayOffset: key), (source as NSString).range(of: "url").location)

        let snapshot = try snapshot(source)
        let layout = try XCTUnwrap(snapshot.layouts[0].tables.first)
        XCTAssertEqual(layout.rows.count, 4)
        XCTAssertEqual(snapshot.text(in: try XCTUnwrap(snapshot.fullRange)),
                       "title\tHello, world\nlayout\tpost\nempty\t\nurl\thttps://example.com/a:b\nHeading\nText")
    }

    func testNestedYAMLShowsAsAMonospacedBlock() throws {
        for content in ["author:\n  name: Someone", "tags:\n- one\n- two", "# a comment", "plain words", "[a, b]",
                        "key: |\n  folded"] {
            let source = "---\n\(content)\n---\nAfter."
            let blocks = try parse(source)
            XCTAssertEqual(blocks.map(\.kind), [.codeBlock, .paragraph], content)
            XCTAssertTrue(blocks[0].isFrontMatter)
            XCTAssertEqual(blocks[0].text, content)
            XCTAssertEqual(blocks[0].styleRuns.map(\.role), [.code])
            XCTAssertEqual(blocks[1].text, "After.", "the closing line ends it, with no blank line needed")
        }
        let snapshot = try snapshot("---\nauthor:\n  name: Someone\n---\n\nText")
        XCTAssertEqual(snapshot.layouts[0].codeBlocks.count, 1, "drawn like a code block")
        XCTAssertEqual(snapshot.layouts[0].lineCount, 2)
        let line = try XCTUnwrap(snapshot.layouts[0].lines.last)
        XCTAssertEqual(snapshot.document.blocks[0].sourceOffset(forDisplayOffset: line.range.lowerBound + 2),
                       ("---\nauthor:\n  name" as NSString).range(of: "name").location)
    }

    func testWithoutAClosingLineItIsOrdinaryMarkdown() throws {
        let blocks = try parse("---\ntitle: Hello\n\n# Heading")
        XCTAssertEqual(blocks.map(\.kind), [.thematicBreak, .paragraph, .heading(level: 1)])
        XCTAssertTrue(blocks.allSatisfy { !$0.isFrontMatter })
        XCTAssertEqual(try parse("---").map(\.kind), [.thematicBreak])
        XCTAssertEqual(try parse(" ---\na: b\n---").first?.isFrontMatter, false, "only at the very start")
        XCTAssertEqual(try parse("\n---\na: b\n---").first?.isFrontMatter, false)
        XCTAssertEqual(try parse("----\na: b\n---").first?.isFrontMatter, false)
    }

    func testThreeDotsCloseIt() throws {
        let blocks = try parse("---\ntitle: Dots\n...\nText")
        XCTAssertEqual(blocks.map(\.kind), [.table, .paragraph])
        XCTAssertEqual(blocks[0].text, "title\tDots")
        XCTAssertEqual(try parse("...\ntitle: x\n...").first?.isFrontMatter, false, "it must open with dashes")
    }

    func testBlocksAfterItKeepTheirSourceOffsets() throws {
        let body = "# Heading\n\nSome [link](https://example.com) text.\n\n- item\n"
        let source = "---\ntitle: Offsets\nlist: x\n---\n\n" + body
        let blocks = try parse(source)
        let start = ("---\ntitle: Offsets\nlist: x\n---\n\n" as NSString).length
        let plain = try parse(body)
        XCTAssertEqual(Array(blocks.dropFirst().map(\.sourceRange)), plain.map { ($0.sourceRange.lowerBound + start)..<($0.sourceRange.upperBound + start) })
        XCTAssertEqual(Array(blocks.dropFirst().map(\.text)), plain.map(\.text))
        let link = blocks[2]
        let offset = (link.text as NSString).range(of: "text").location
        XCTAssertEqual(link.sourceOffset(forDisplayOffset: offset), (source as NSString).range(of: "text.").location)
    }

    func testCRLFLineEndings() throws {
        let source = "---\r\ntitle: Windows\r\nlayout: post\r\n---\r\n\r\nBody\r\n"
        let blocks = try parse(source)
        XCTAssertEqual(blocks.map(\.kind), [.table, .paragraph])
        XCTAssertEqual(blocks[0].text, "title\tWindows\nlayout\tpost")
        XCTAssertEqual(blocks[0].sourceRange, 0..<(source as NSString).range(of: "\r\n---").upperBound)
        XCTAssertEqual(blocks[1].sourceRange.lowerBound, (source as NSString).range(of: "Body").location)
        XCTAssertEqual(try parse("---\r\nauthor:\r\n  name: x\r\n---\r\n").first?.text, "author:\n  name: x")
    }

    func testAnEmptyBlockTakesNoSpace() throws {
        for source in ["---\n---\n\nText", "---\n\n   \n---\nText"] {
            let blocks = try parse(source)
            XCTAssertEqual(blocks.count, 2)
            XCTAssertTrue(blocks[0].isFrontMatter)
            XCTAssertEqual(blocks[0].text, "")
            let snapshot = try snapshot(source)
            XCTAssertEqual(snapshot.layouts[0].height, 0)
            XCTAssertEqual(snapshot.blockTops[1], try self.snapshot("Text").blockTops[0], "as if it were not there")
            XCTAssertEqual(snapshot.fullRange, TextPosition(block: 1, offset: 0)..<TextPosition(block: 1, offset: 4))
        }
    }

    func testALaterRuleIsOnlyARule() throws {
        XCTAssertEqual(try parse("Intro\n\n---\n\nMore\n\n---\n").map(\.kind), [.paragraph, .thematicBreak, .paragraph, .thematicBreak])
        XCTAssertEqual(try parse("# Title\n---\na: b\n---").first?.isFrontMatter, false)
        let blocks = try parse("---\na: b\n---\n\nText\n\n---\n\nMore")
        XCTAssertEqual(blocks.map(\.kind), [.table, .paragraph, .thematicBreak, .paragraph])
        XCTAssertEqual(blocks.map(\.isFrontMatter), [true, false, false, false])
    }

    func testEditsDiffItLikeAnyBlock() throws {
        let source = "---\ntitle: One\n---\n\n# Heading\n\nText."
        let base = try snapshot(source)
        let body = try MarkdownSnapshot.updating(base, to: source.replacingOccurrences(of: "Text.", with: "Text!"), width: 700)
        XCTAssertEqual(body.reused, 2)
        XCTAssertTrue(body.snapshot.layouts[0] === base.layouts[0])
        let matter = try MarkdownSnapshot.updating(base, to: source.replacingOccurrences(of: "One", with: "Two"), width: 700)
        XCTAssertEqual(matter.reused, 2)
        XCTAssertEqual(matter.snapshot.document.blocks[0].text, "title\tTwo")
        // Breaking it turns the file into ordinary Markdown.
        let broken = try MarkdownSnapshot.updating(base, to: source.replacingOccurrences(of: "---\n\n#", with: "\n\n#"), width: 700)
        XCTAssertEqual(broken.snapshot.document.blocks.map(\.kind), [.thematicBreak, .paragraph, .heading(level: 1), .paragraph])
        XCTAssertEqual(broken.snapshot.layouts.map(\.height), try snapshot(source.replacingOccurrences(of: "---\n\n#", with: "\n\n#"))
            .layouts.map(\.height))
    }
}
