import AppKit
import XCTest
@testable import Aletheia

final class ProjectSessionsTests: XCTestCase {
    func testMigrationRetainsAllProjectsButChoosesOnlyActiveForLaunch() throws {
        let suite = "ProjectSessionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = WindowSession(frame: .zero, rootPath: "/a", filePaths: ["/a/file"], selectedPath: "/a/file")
        let b = WindowSession(frame: .zero, rootPath: "/b", filePaths: [], selectedPath: nil)
        SessionState(windows: [a, b], activeWindowIndex: 1).save(to: defaults)
        var archive = ProjectSessions.load(from: defaults)
        XCTAssertEqual(archive.mostRecent, b)
        XCTAssertEqual(archive.session(for: URL(fileURLWithPath: "/a")), a)
        archive.remember(a, active: true)
        archive.save(to: defaults)
        XCTAssertEqual(ProjectSessions.load(from: defaults), archive)
        XCTAssertEqual(archive.projects.count, 2)
        archive.remember(WindowSession(frame: .zero, filePaths: [], selectedPath: nil), active: true)
        XCTAssertEqual(archive.mostRecent, a, "An empty startup window must not replace the last project")
    }

    func testProjectIdentityResolvesSymlinksAndKeepsClosedProjectState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        XCTAssertTrue(ProjectSessions.sameProject(project, alias))
        var archive = ProjectSessions()
        let saved = WindowSession(frame: .zero, rootPath: project.path, filePaths: ["file"], selectedPath: "file",
                                  treeState: FolderTreeState(expandedPaths: ["folder"], scrollOrigin: CGPoint(x: 0, y: 180)),
                                  scrollPositions: ["file": FileScrollPosition(source: CGPoint(x: 0, y: 400), preview: CGPoint(x: 0, y: 250))])
        archive.remember(saved, active: true)
        XCTAssertEqual(archive.session(for: alias), saved)
        let data = try JSONEncoder().encode(archive)
        XCTAssertEqual(try JSONDecoder().decode(ProjectSessions.self, from: data), archive)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), [])
    }

    func testOldWindowSnapshotDefaultsNewStateToNil() throws {
        let data = Data(#"{"frame":[[0,0],[800,600]],"rootPath":"/p","filePaths":[]}"#.utf8)
        let session = try JSONDecoder().decode(WindowSession.self, from: data)
        XCTAssertNil(session.treeState)
        XCTAssertNil(session.scrollPositions)
    }
}

extension ProjectSessionsTests {
    @MainActor func testProjectRoutingUsesOneWindowAndLaunchRestoresOnlyMostRecent() async throws {
        _ = NSApplication.shared
        let suite = "ProjectRoutingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppDelegate(defaults: defaults)
        app.openProject(a)
        XCTAssertEqual(app.windows.count, 1)
        let original = app.windows[0]
        app.openProject(alias)
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(app.windows[0] === original)
        app.openProject(b)
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertEqual(ProjectSessions.load(from: defaults).mostRecent?.rootPath, b.path)
        // Load a second delegate from the saved preferences to exercise launch selection.
        let reopened = AppDelegate(defaults: defaults)
        reopened.restoreSession()
        for _ in 0..<100 where reopened.windows.first?.projectURL == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reopened.windows.count, 1)
        XCTAssertEqual(reopened.windows.first?.projectURL?.path, b.path)
        for window in app.windows + reopened.windows { window.window?.close() }
    }
}
