import AppKit
import XCTest
@testable import Aletheia

final class FileIconsTests: XCTestCase {
    @MainActor func testCatalogAndEveryGlyphLoad() throws {
        let icons = FileIcons.shared
        XCTAssertEqual(icons.rules.count, 2088)
        XCTAssertEqual(icons.catalog.icons.count, 935)
        let missingGlyphs: Set<String> = ["arttext4-icon", "bikeshed-icon", "dotenv-icon", "figma-icon", "imgbot-icon", "mint-icon", "mixin-icon", "photorec-icon", "shellcheck-icon", "windi-icon"]
        for name in icons.catalog.icons.keys.sorted() {
            if missingGlyphs.contains(name) {
                XCTAssertNil(icons.image(for: name), name)
                continue
            }
            let image = try XCTUnwrap(icons.image(for: name), name)
            XCTAssertTrue(image.isTemplate, name)
            XCTAssertNotNil(image.tiffRepresentation, name)
        }
    }

    @MainActor func testCommonTypesSpecialNamesAndFallback() {
        let examples = ["main.ts": "ts-icon", "main.js": "js-icon",
                        "README.md": "book-icon", "notes.md": "markdown-icon", "app.swift": "swift-icon",
                        "main.rs": "rust-icon", "main.py": "python-icon",
                        "Dockerfile": "docker-icon", ".gitignore": "git-icon",
                        "package.json": "npm-icon", "style.css": "css3-icon", "src/component.tsx": "tsx-icon",
                        "archive.tar.gz": "zip-icon", "tsconfig.json": "config-ts-icon",
                        "CMakeLists.txt": "cmake-icon", "Cargo.toml": "package-icon",
                        ".clang-format-ignore": "llvm-icon", "日本語.py": "python-icon"]
        for (name, expected) in examples {
            XCTAssertEqual(FileIcons.shared.rule(for: URL(fileURLWithPath: "/project/" + name))?.icon, expected, name)
        }
        XCTAssertNil(FileIcons.shared.rule(for: URL(fileURLWithPath: "/project/unknown.unrecognized-aletheia")))
        XCTAssertEqual(FileIcons.shared.rule(for: URL(fileURLWithPath: "/project/MAIN.TS"))?.icon, "ts-icon")
    }

    @MainActor func testFilenameMatchingCost() {
        let icons = FileIcons.shared
        let start = ContinuousClock.now
        for index in 0..<1000 {
            _ = icons.rule(for: URL(fileURLWithPath: "/project/file\(index).ts"))
        }
        print("File icons: 1,000 uncached TypeScript filenames: \(start.duration(to: .now))")
    }
}
