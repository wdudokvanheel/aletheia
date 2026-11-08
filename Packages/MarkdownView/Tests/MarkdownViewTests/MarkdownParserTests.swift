import Foundation
import XCTest
@testable import MarkdownView

final class MarkdownParserTests: XCTestCase {
    func testParsesGFMExtensionsIntoTopLevelBlocks() throws {
        let markdown = """
        # Title

        | a | b |
        | - | - |
        | 1 | 2 |

        - [ ] open
        - [x] done

        ~~gone~~ see https://example.com
        """
        let kinds = try MarkdownDocument.parse(markdown).blocks.map(\.kind)
        XCTAssertEqual(kinds, [.heading(level: 1), .table, .list, .paragraph])
    }

    func testBlockSourceRangesAndTextUseUTF16Offsets() throws {
        let markdown = "## Caf\u{E9} \u{1F600}\n\nnext line\nwraps\n\n---\n"
        let document = try MarkdownDocument.parse(markdown)
        let source = markdown as NSString
        XCTAssertEqual(document.blocks.map(\.kind), [.heading(level: 2), .paragraph, .thematicBreak])
        for block in document.blocks {
            let range = NSRange(location: block.sourceRange.lowerBound, length: block.sourceRange.count)
            XCTAssertEqual(source.substring(with: range), block.sourceText)
        }
        XCTAssertEqual(document.blocks[0].sourceRange, 0..<10)
        XCTAssertEqual(document.blocks[0].text, "Caf\u{E9} \u{1F600}")
        XCTAssertEqual(document.blocks[0].styleRuns, [StyleRun(range: 0..<7, role: .heading2)])
        XCTAssertEqual(document.blocks[1].sourceText, "next line\nwraps")
        XCTAssertEqual(document.blocks[1].text, "next line wraps")
        XCTAssertEqual(document.blocks[2].sourceText, "---")
        XCTAssertEqual(document.blocks[2].text, "")
    }

    func testCRLFLineEndings() throws {
        let markdown = "first\r\n\r\n```\r\ncode\r\n```\r\n"
        let document = try MarkdownDocument.parse(markdown)
        XCTAssertEqual(document.blocks.map(\.sourceRange), [0..<5, 9..<23])
        XCTAssertEqual(document.blocks[1].sourceText, "```\r\ncode\r\n```")
    }

    func testTableDisplaysTabSeparatedRows() throws {
        let markdown = """
        | Name | Value |
        | :--- | ----: |
        | *pi* | 3.14 |
        | e | `2.71` |
        """
        let block = try XCTUnwrap(MarkdownDocument.parse(markdown).blocks.first)
        XCTAssertEqual(block.kind, .table)
        XCTAssertEqual(block.text, "Name\tValue\npi\t3.14\ne\t2.71")
        XCTAssertEqual(block.styleRuns, [StyleRun(range: 0..<11, role: .body),
                                         StyleRun(range: 11..<13, role: .body, styles: .emphasis),
                                         StyleRun(range: 13..<21, role: .body),
                                         StyleRun(range: 21..<25, role: .body, styles: .code)])
    }

    func testImageDisplaysAltTextAndHTMLIsDropped() throws {
        let markdown = """
        ![a *small* logo](logo.png "Logo")

        Some <b>bold</b> words.

        <div align="center">
        hidden
        </div>
        """
        let blocks = try MarkdownDocument.parse(markdown).blocks
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .paragraph, .htmlBlock])
        XCTAssertEqual(blocks[0].text, "a small logo")
        XCTAssertEqual(blocks[1].text, "Some bold words.")
        XCTAssertEqual(blocks[2].text, "")
        XCTAssertTrue(blocks[2].styleRuns.isEmpty)
    }

    func testContainersFlattenWithRolesPerLine() throws {
        let markdown = """
        > Quoted
        > text
        >
        > ```
        > let x = 1
        > ```

        1. one
        2. two
           - nested
           - [x] task
        """
        let blocks = try MarkdownDocument.parse(markdown).blocks
        XCTAssertEqual(blocks.map(\.kind), [.blockQuote, .list])
        XCTAssertEqual(blocks[0].text, "Quoted text\nlet x = 1")
        XCTAssertEqual(blocks[0].styleRuns, [StyleRun(range: 0..<12, role: .quote), StyleRun(range: 12..<21, role: .code)])
        XCTAssertEqual(blocks[1].text, "one\ntwo\nnested\ntask")
    }

    func testEmptySource() throws {
        XCTAssertEqual(try MarkdownDocument.parse("").blocks, [])
        XCTAssertEqual(try MarkdownDocument.parse("\n\n  \n").blocks, [])
    }

    func testBridgedSourcesParseLikeNativeOnes() throws {
        let native = "# Héllo 👍\n\nשלום and 日本語 with `code`.\n"
        let bridged = NSMutableString(string: native).copy() as! NSString as String
        XCTAssertFalse(bridged.isContiguousUTF8)
        XCTAssertEqual(MarkdownDocument.contiguousUTF8(bridged), native)
        XCTAssertTrue(MarkdownDocument.contiguousUTF8(bridged).isContiguousUTF8)
        XCTAssertEqual(try MarkdownDocument.parse(bridged), try MarkdownDocument.parse(native))
        // A lone surrogate is repaired, keeping UTF-16 offsets.
        let lone = NSString(characters: [0x61, 0xD800, 0x62], length: 3) as String
        XCTAssertEqual(MarkdownDocument.contiguousUTF8(lone), "a\u{FFFD}b")
        XCTAssertEqual(try MarkdownDocument.parse(lone).blocks.first?.sourceRange, 0..<3)
    }
}
