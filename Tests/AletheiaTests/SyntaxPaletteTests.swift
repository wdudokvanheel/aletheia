import AppKit
import XCTest
@testable import Aletheia

final class SyntaxPaletteTests: XCTestCase {
    @MainActor func testEverySchemeHasDedicatedSyntaxColors() throws {
        XCTAssertEqual(Set(SyntaxPalette.bundled.keys), Set(AppSettings.schemes.map(\.id).filter { $0 != "system" }))
        for scheme in AppSettings.schemes {
            for style in SyntaxStyle.allCases {
                let alpha = style.color(scheme.syntaxPalette).alphaComponent
                if scheme.id == "system" { XCTAssertGreaterThan(alpha, 0) }
                else { XCTAssertEqual(alpha, 1, "\(scheme.id) \(style)") }
            }
        }
        func hex(_ color: NSColor) throws -> UInt32 {
            let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
            return UInt32((rgb.redComponent * 255).rounded()) << 16
                | UInt32((rgb.greenComponent * 255).rounded()) << 8
                | UInt32((rgb.blueComponent * 255).rounded())
        }
        // Regression: Git conflict/add/change colors are not syntax roles.
        let dracula = try XCTUnwrap(SyntaxPalette.bundled["dracula"])
        XCTAssertEqual(try hex(dracula.keyword), 0xff79c6)
        XCTAssertEqual(try hex(dracula.string), 0xf1fa8c)
        XCTAssertEqual(try hex(dracula.number), 0xbd93f9)
        XCTAssertEqual(try hex(dracula.name), 0x50fa7b)
        XCTAssertEqual(try hex(try XCTUnwrap(SyntaxPalette.bundled["one-light"]).number), 0xc18401)
        XCTAssertEqual(try hex(try XCTUnwrap(SyntaxPalette.bundled["catppuccin-mocha"]).number), 0xfab387)
        XCTAssertEqual(try hex(try XCTUnwrap(SyntaxPalette.bundled["rose-pine-dawn"]).keyword), 0x286983)
    }

    @MainActor func testChangingSchemeRecolorsOpenEditorWithoutEditingOrReparsing() async throws {
        _ = NSApplication.shared
        let savedScheme = AppSettings.shared.selectedSchemeID
        defer { AppSettings.shared.selectScheme(id: savedScheme) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("colors.ts")
        let source = "// A comment\nconst message = \"hello\";\nfunction greet() { return 42; }\n"
        try source.write(to: url, atomically: true, encoding: .utf8)
        let controller = EditorWindow()
        defer { controller.window?.performClose(nil) }
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                             rootPath: root.path, filePaths: [url.path], selectedPath: url.path)) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(failures.isEmpty)
        let editor = try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
        let layout = try XCTUnwrap(editor.layoutManager)
        let keyword = (source as NSString).range(of: "const")
        for _ in 0..<200 {
            if layout.temporaryAttribute(.foregroundColor, atCharacterIndex: keyword.location, effectiveRange: nil) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let runs = SyntaxHighlighting.runs(in: source, languageID: "typescript")
        XCTAssertFalse(runs.isEmpty)
        for scheme in AppSettings.schemes {
            // The window observes the real Settings notification. No manual applyTheme call.
            AppSettings.shared.selectScheme(id: scheme.id)
            for run in runs {
                XCTAssertEqual(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: run.range.location, effectiveRange: nil) as? NSColor,
                               run.style.color(scheme.syntaxPalette), "\(scheme.id) \(run.style)")
            }
            XCTAssertEqual(editor.backgroundColor, scheme.palette.background)
            XCTAssertEqual(editor.string, source)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
            XCTAssertFalse(editor.undoManager!.canUndo)
        }
    }
}
