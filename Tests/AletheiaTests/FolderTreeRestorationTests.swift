import AppKit
import XCTest
@testable import Aletheia

final class FolderTreeRestorationTests: XCTestCase {
    private func canonical(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    @MainActor func testRevealExpandsOnlyAncestorsAndScrollsWithoutOpening() async throws {
        _ = NSApplication.shared
        var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
        let nested = root.appendingPathComponent("parent/nested")
        let untouched = root.appendingPathComponent("untouched")
        for directory in [nested, untouched] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<80 { try Data().write(to: nested.appendingPathComponent("file\(index).txt")) }
        let target = nested.appendingPathComponent("file79.txt")
        let tree = FolderTree()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 250),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tree.scroll
        defer { window.close() }
        var opened = false
        tree.onOpen = { _ in opened = true }
        tree.setRoot(root)
        // Reveal takes precedence over a pending restored selection and scroll position.
        tree.restore(FolderTreeState(expandedPaths: [], selectedPath: nil, scrollOrigin: .zero))
        tree.reveal(target)
        let outline = try XCTUnwrap(tree.scroll.documentView as? NSOutlineView)
        let deadline = Date().addingTimeInterval(5)
        while canonical(tree.session.selectedPath) != canonical(target.path) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(canonical(tree.session.selectedPath), canonical(target.path))
        XCTAssertEqual(Set(tree.session.expandedPaths.compactMap(canonical)), Set([nested.deletingLastPathComponent().path, nested.path].compactMap(canonical)))
        XCTAssertTrue(outline.visibleRect.contains(outline.rect(ofRow: outline.selectedRow)))
        XCTAssertGreaterThan(tree.session.scrollOrigin.y, 0)
        let unrelated = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FolderNode }
            .first { canonical($0.url.path) == canonical(untouched.path) }
        XCTAssertNotNil(unrelated)
        XCTAssertNil(unrelated?.children)
        XCTAssertFalse(opened)

        // Collapsed, already-loaded parents must reopen too.
        let parent = try XCTUnwrap((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FolderNode }
            .first { canonical($0.url.path) == canonical(nested.deletingLastPathComponent().path) })
        outline.collapseItem(parent)
        tree.reveal(target)
        XCTAssertEqual(canonical(tree.session.selectedPath), canonical(target.path))
        XCTAssertTrue(outline.isItemExpanded(parent))
        XCTAssertTrue(outline.visibleRect.contains(outline.rect(ofRow: outline.selectedRow)))
    }

    @MainActor func testNewRevealOrCancellationSupersedesPendingLoads() async throws {
        _ = NSApplication.shared
        var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
        let nested = root.appendingPathComponent("parent/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = nested.appendingPathComponent("first.txt")
        let latest = root.appendingPathComponent("latest.txt")
        for file in [first, latest] { try Data().write(to: file) }
        let tree = FolderTree()
        tree.scroll.frame = CGRect(x: 0, y: 0, width: 300, height: 250)
        let outline = try XCTUnwrap(tree.scroll.documentView as? NSOutlineView)
        tree.setRoot(root)
        tree.reveal(first)
        tree.reveal(latest)
        let deadline = Date().addingTimeInterval(5)
        while canonical(tree.session.selectedPath) != canonical(latest.path) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(canonical(tree.session.selectedPath), canonical(latest.path))
        tree.reveal(first) // Starts a directory read.
        tree.reveal(nil) // Turning the option off cancels that reveal.
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(canonical(tree.session.selectedPath), canonical(latest.path))
        tree.reveal(root.deletingLastPathComponent().appendingPathComponent("outside.txt"))
        tree.reveal(root.appendingPathComponent("missing.txt"))
        XCTAssertEqual(canonical(tree.session.selectedPath), canonical(latest.path))
        XCTAssertGreaterThan(outline.selectedRow, -1)
    }

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
        let added = nested.appendingPathComponent("added.txt")
        try Data().write(to: added)
        try FileManager.default.removeItem(at: nested.appendingPathComponent("file0.txt"))
        tree.refresh(changedPaths: [added.path, nested.appendingPathComponent("file0.txt").path])
        let refreshDeadline = Date().addingTimeInterval(5)
        while !(0..<outline.numberOfRows).contains(where: {
            (outline.item(atRow: $0) as? FolderNode)?.url.resolvingSymlinksInPath().path == added.resolvingSymlinksInPath().path
        }), Date() < refreshDeadline { try await Task.sleep(for: .milliseconds(20)) }
        let visible = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FolderNode }
        XCTAssertTrue(visible.contains { $0.url.resolvingSymlinksInPath().path == added.resolvingSymlinksInPath().path })
        XCTAssertFalse(visible.contains { $0.url.lastPathComponent == "file0.txt" })
        XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? FolderNode)?.url.resolvingSymlinksInPath().path, selected.resolvingSymlinksInPath().path)
        XCTAssertEqual(tree.session.expandedPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.sorted(), state.expandedPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.sorted())
        XCTAssertNil(untouchedNode?.children)
        XCTAssertFalse(opened)

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
