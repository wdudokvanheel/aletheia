import XCTest
@testable import MarkdownView

final class MarkdownParserTests: XCTestCase {
    func testParsesGFMExtensionsIntoTopLevelBlocks() {
        let markdown = """
        # Title

        | a | b |
        | - | - |
        | 1 | 2 |

        - [ ] open
        - [x] done

        ~~gone~~ see https://example.com
        """
        XCTAssertEqual(MarkdownParser.topLevelBlockKinds(of: markdown), ["heading", "table", "list", "paragraph"])
    }
}
