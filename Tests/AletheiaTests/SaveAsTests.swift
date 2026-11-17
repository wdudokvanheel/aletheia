import AppKit
import XCTest
@testable import Aletheia

final class SaveAsTests: XCTestCase {
    func testSaveAsWritesBOMAndReadsBackTheNewFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("a.txt")
        try Data([0xEF, 0xBB, 0xBF] + Array("one\r\n".utf8)).write(to: original)
        let target = directory.appendingPathComponent("b.txt")
        let saved = try TextFile.read(original).save("two\r\n", as: target)
        XCTAssertEqual(try Data(contentsOf: target), Data([0xEF, 0xBB, 0xBF] + Array("two\r\n".utf8)))
        XCTAssertEqual(saved.text, "two\r\n")
        XCTAssertEqual(saved.newline, "\r\n")
        XCTAssertEqual(try Data(contentsOf: original), Data([0xEF, 0xBB, 0xBF] + Array("one\r\n".utf8)))
    }

    @MainActor func testSaveAsMovesTheTabAndLeavesTheOriginal() async throws {
        _ = NSApplication.shared
        var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("a.txt"), other = root.appendingPathComponent("other.txt")
        try Data("one".utf8).write(to: original)
        try Data("other".utf8).write(to: other)
        let controller = EditorWindow()
        defer { controller.window?.performClose(nil) }
        let state = WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600), rootPath: root.path,
                                  filePaths: [other.path, original.path], selectedPath: original.path)
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(state) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(failures.isEmpty)
        let document = try XCTUnwrap(controller.documents.first { $0.file.url == original })
        document.editor.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(document.isDirty)

        // Another tab's file is refused and left alone.
        controller.saveSelected(as: other)
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "other")
        controller.window?.attachedSheet.map { controller.window?.endSheet($0) }

        let target = root.appendingPathComponent("b.md")
        controller.saveSelected(as: target)
        let deadline = Date().addingTimeInterval(5)
        while document.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "edited one")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "one")
        XCTAssertEqual(document.file.url, target)
        XCTAssertFalse(document.isDirty)
        XCTAssertTrue(document.isMarkdown)
        XCTAssertEqual(controller.session.selectedPath, target.path)
        XCTAssertTrue(document.editor.undoManager?.canUndo == true, "Save As keeps the undo history")
    }
}
