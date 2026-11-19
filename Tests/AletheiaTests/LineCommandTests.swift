import AppKit
import XCTest
@testable import Aletheia

final class LineCommandTests: XCTestCase {
    @MainActor private func document(_ text: String, caret: Int, length: Int = 0) throws -> EditorDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(file: try TextFile.read(url))
        document.editor.setSelectedRange(NSRange(location: caret, length: length))
        return document
    }

    @MainActor func testDuplicateCopiesLineOrSelectionAndUndoes() throws {
        let middle = try document("ab\ncd\nef", caret: 4)
        middle.duplicateLine()
        XCTAssertEqual(middle.editor.string, "ab\ncd\ncd\nef")
        XCTAssertEqual(middle.editor.selectedRange(), NSRange(location: 7, length: 0))
        middle.editor.undoManager?.undo()
        XCTAssertEqual(middle.editor.string, "ab\ncd\nef")

        let last = try document("ab\r\ncd", caret: 5)
        last.duplicateLine()
        XCTAssertEqual(last.editor.string, "ab\r\ncd\r\ncd")
        XCTAssertEqual(last.editor.selectedRange(), NSRange(location: 9, length: 0))

        let selection = try document("abc", caret: 1, length: 2)
        selection.duplicateLine()
        XCTAssertEqual(selection.editor.string, "abcbc")
        XCTAssertEqual(selection.editor.selectedRange(), NSRange(location: 3, length: 2))
    }

    @MainActor func testDeleteRemovesTouchedLinesAndKeepsColumn() throws {
        let middle = try document("ab\ncd\nef", caret: 4)
        middle.deleteLine()
        XCTAssertEqual(middle.editor.string, "ab\nef")
        XCTAssertEqual(middle.editor.selectedRange(), NSRange(location: 4, length: 0))
        middle.editor.undoManager?.undo()
        XCTAssertEqual(middle.editor.string, "ab\ncd\nef")

        let last = try document("abc\r\nd", caret: 6)
        last.deleteLine()
        XCTAssertEqual(last.editor.string, "abc")
        XCTAssertEqual(last.editor.selectedRange(), NSRange(location: 1, length: 0))

        let span = try document("ab\ncd\nef\n", caret: 1, length: 3)
        span.deleteLine()
        XCTAssertEqual(span.editor.string, "ef\n")

        let only = try document("abc", caret: 2)
        only.deleteLine()
        XCTAssertEqual(only.editor.string, "")
        only.deleteLine()
        XCTAssertEqual(only.editor.string, "")
    }

    @MainActor func testMoveSwapsTouchedLinesAndCarriesSelection() throws {
        let middle = try document("ab\ncd\nef", caret: 4)
        middle.moveLine(up: true)
        XCTAssertEqual(middle.editor.string, "cd\nab\nef")
        XCTAssertEqual(middle.editor.selectedRange(), NSRange(location: 1, length: 0))
        middle.moveLine(up: true)
        XCTAssertEqual(middle.editor.string, "cd\nab\nef")
        middle.editor.undoManager?.undo()
        XCTAssertEqual(middle.editor.string, "ab\ncd\nef")

        let last = try document("ab\r\ncd", caret: 5)
        last.moveLine(up: true)
        XCTAssertEqual(last.editor.string, "cd\r\nab")
        XCTAssertEqual(last.editor.selectedRange(), NSRange(location: 1, length: 0))
        last.moveLine(up: false)
        XCTAssertEqual(last.editor.string, "ab\r\ncd")
        XCTAssertEqual(last.editor.selectedRange(), NSRange(location: 5, length: 0))
        last.moveLine(up: false)
        XCTAssertEqual(last.editor.string, "ab\r\ncd")

        let span = try document("ab\ncd\nef\n", caret: 1, length: 3)
        span.moveLine(up: false)
        XCTAssertEqual(span.editor.string, "ef\nab\ncd\n")
        XCTAssertEqual(span.editor.selectedRange(), NSRange(location: 4, length: 3))
        span.moveLine(up: false)
        XCTAssertEqual(span.editor.string, "ef\nab\ncd\n")

        let lineOnly = try document("ab\ncd\nef", caret: 0, length: 3)
        lineOnly.moveLine(up: false)
        XCTAssertEqual(lineOnly.editor.string, "cd\nab\nef")
        XCTAssertEqual(lineOnly.editor.selectedRange(), NSRange(location: 3, length: 3))
    }
}
