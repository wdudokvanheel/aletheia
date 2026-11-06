import AppKit
import XCTest
@testable import Aletheia

final class FileWatcherTests: XCTestCase {
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition())
    }

    @MainActor func testEventsSurviveAtomicReplacementAndStop() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.txt")
        let watcher = FileWatcher()
        var paths = Set<String>()
        watcher.onChange = { paths.formUnion($0) }
        try watcher.watch([root])
        try Data("first".utf8).write(to: file, options: .atomic)
        try await waitUntil { !paths.isEmpty }
        paths.removeAll()
        try Data("second".utf8).write(to: file, options: .atomic)
        try await waitUntil { !paths.isEmpty }
        paths.removeAll()
        try FileManager.default.removeItem(at: file)
        try await waitUntil { !paths.isEmpty }
        watcher.stop()
        paths.removeAll()
        try Data().write(to: file)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(paths.isEmpty)
    }

    @MainActor func testWindowReloadsCleanFileAndPromptsBeforeDiscardingEdits() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.txt")
        try Data("original".utf8).write(to: file)
        let controller = EditorWindow()
        controller.openFile(file)
        try await waitUntil { controller.documents.count == 1 }
        let document = try XCTUnwrap(controller.documents.first)
        try Data("external".utf8).write(to: file, options: .atomic)
        try await waitUntil { document.editor.string == "external" }
        XCTAssertFalse(document.isDirty)
        document.editor.insertText("local ", replacementRange: NSRange(location: 0, length: 0))
        try Data("other version".utf8).write(to: file, options: .atomic)
        try await waitUntil { controller.window?.attachedSheet != nil }
        XCTAssertEqual(document.editor.string, "local external")
        XCTAssertTrue(document.isDirty)
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let sheet = try XCTUnwrap(controller.window?.attachedSheet)
        let keep = try XCTUnwrap(buttons(sheet.contentView!).first { $0.title == "Keep Editing and Overwrite on Save" })
        keep.performClick(nil)
        try await waitUntil { !document.busy && document.file.text == "other version" }
        XCTAssertEqual(document.editor.string, "local external")
        // Approval is only for the observed version, never an unconditional overwrite.
        try Data("newer version".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try document.file.save(document.editor.string))
        try await waitUntil { controller.window?.attachedSheet != nil }
        let reloadSheet = try XCTUnwrap(controller.window?.attachedSheet)
        let reload = try XCTUnwrap(buttons(reloadSheet.contentView!).first { $0.title == "Discard Changes and Reload" })
        reload.performClick(nil)
        try await waitUntil { document.editor.string == "newer version" && !document.busy }
        XCTAssertFalse(document.isDirty)
        controller.window?.close()
    }
}
