import AppKit
import XCTest
@testable import Aletheia

final class FolderTreeRestorationTests: XCTestCase {
    @MainActor func testLazyBranchesSelectionAndScrollRestoreWithoutOpeningFiles() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let expanded = root.appendingPathComponent("expanded")
        let nested = expanded.appendingPathComponent("nested")
        let untouched = root.appendingPathComponent("untouched")
        for url in [nested, untouched] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<80 { try Data().write(to: nested.appendingPathComponent("file\(index).txt")) }
        let selected = nested.appendingPathComponent("file60.txt")
        let state = FolderTreeState(expandedPaths: [expanded.path, nested.path],
                                    selectedPath: selected.path, scrollOrigin: CGPoint(x: 0, y: 650))
        let tree = FolderTree()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tree.scroll
        defer { window.close() }
        var opened = false
        tree.onOpen = { _ in opened = true }
        tree.setRoot(root)
        tree.restore(state)
        XCTAssertEqual(tree.session, state, "Pending loads must preserve the complete requested snapshot")
        let outline = try XCTUnwrap(tree.scroll.documentView as? NSOutlineView)
        let deadline = Date().addingTimeInterval(5)
        while outline.selectedRow < 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? FolderNode)?.url.resolvingSymlinksInPath().path, selected.resolvingSymlinksInPath().path)
        XCTAssertEqual(tree.session.expandedPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.sorted(), state.expandedPaths.sorted())
        XCTAssertEqual(tree.scroll.contentView.bounds.origin.y, 650, accuracy: 1)
        XCTAssertFalse(opened)
        let untouchedNode = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FolderNode }
            .first { $0.url.resolvingSymlinksInPath().path == untouched.path }
        XCTAssertNotNil(untouchedNode)
        XCTAssertNil(untouchedNode?.children, "Unexpanded branches must never be enumerated")
    }

    @MainActor func testMissingBranchFinishesAndClampsScroll() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = FolderTree()
        tree.scroll.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        tree.setRoot(root)
        tree.restore(FolderTreeState(expandedPaths: [root.appendingPathComponent("missing").path],
                                    selectedPath: "/missing", scrollOrigin: CGPoint(x: -5, y: 1e9)))
        let deadline = Date().addingTimeInterval(5)
        while !tree.session.expandedPaths.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(tree.session.expandedPaths.isEmpty)
        XCTAssertNil(tree.session.selectedPath)
        XCTAssertEqual(tree.session.scrollOrigin, .zero)
    }
}
