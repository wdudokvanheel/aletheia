import AppKit
import XCTest
@testable import Aletheia

final class TextFileTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("example.txt") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.removeItem(at: directory)
    }

    func testBOMCRLFAndPermissionsSurviveAtomicSave() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("α\r\nsecond\r\n".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let file = try TextFile.read(url)
        XCTAssertTrue(file.hasBOM)
        XCTAssertEqual(file.newline, "\r\n")
        XCTAssertEqual(file.text, "α\r\nsecond\r\n")
        let saved = try file.save(file.text + "third\r\n")
        XCTAssertEqual(try Data(contentsOf: url), original + Data("third\r\n".utf8))
        XCTAssertEqual(saved.text, file.text + "third\r\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    func testExternalChangeRefusesOverwriteEvenWithRestoredTimestamp() throws {
        try Data("original".utf8).write(to: url)
        let file = try TextFile.read(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try Data("external".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: url.path)
        XCTAssertThrowsError(try file.save("my edits")) { error in
            guard case TextFile.FileError.changed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
    }

    func testSymlinkSaveKeepsLinkAndRetargetingRefusesOverwrite() throws {
        try Data("original".utf8).write(to: url)
        let link = directory.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let saved = try TextFile.read(link).save("first edit")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), url.path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first edit")
        let other = directory.appendingPathComponent("other.txt")
        try Data("other".utf8).write(to: other)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        XCTAssertThrowsError(try saved.save("second edit"))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "other")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "first edit")
    }

    @MainActor func testNativeEditsPreserveCRLFAndUndoReturnsToSavedState() async throws {
        try Data("first\r\n".utf8).write(to: url)
        let document = EditorDocument(file: try TextFile.read(url))
        XCTAssertNotNil(document.editor.undoManager)
        document.editor.insertText("second\n", replacementRange: NSRange(location: document.editor.string.utf16.count, length: 0))
        document.editor.breakUndoCoalescing()
        XCTAssertEqual(document.editor.string, "first\r\nsecond\r\n")
        XCTAssertTrue(document.isDirty)
        document.editor.undoManager?.undo()
        XCTAssertEqual(document.editor.string, "first\r\n")
        XCTAssertFalse(document.isDirty)
        document.editor.undoManager?.redo()
        document.file = try document.file.save(document.editor.string)
        XCTAssertFalse(document.isDirty)
        document.editor.undoManager?.undo()
        XCTAssertTrue(document.isDirty)
        document.editor.undoManager?.redo()
        XCTAssertFalse(document.isDirty)
    }

    @MainActor func testFailedSaveRetainsDirtyBufferAndOriginalBytes() async throws {
        try Data("original".utf8).write(to: url)
        let document = EditorDocument(file: try TextFile.read(url))
        document.editor.insertText("edit", replacementRange: NSRange(location: 0, length: 0))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        // Directory is unwritable; atomic replacement must fail without consuming the buffer.
        XCTAssertThrowsError(try document.file.save(document.editor.string))
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.editor.string, "editoriginal")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    @MainActor func testAcceptingDiskVersionAllowsSaveButPreservesUndo() async throws {
        try Data("original".utf8).write(to: url)
        let document = EditorDocument(file: try TextFile.read(url))
        document.editor.insertText("local ", replacementRange: NSRange(location: 0, length: 0))
        document.editor.breakUndoCoalescing()
        try Data("external".utf8).write(to: url, options: .atomic)
        document.file = .text(try TextFile.read(url))
        XCTAssertEqual(document.editor.string, "local original")
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(document.editor.undoManager!.canUndo)
        document.file = try document.file.save(document.editor.string)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "local original")
    }

    func testInvalidUTF8AndBinaryAreRejectedWithoutModification() throws {
        for bytes in [Data([0xFF, 0xFE, 0x41]), Data([0x41, 0x00, 0x42])] {
            try bytes.write(to: url)
            XCTAssertThrowsError(try TextFile.read(url))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
}
