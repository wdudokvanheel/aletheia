import AppKit
import XCTest
@testable import Aletheia

final class SessionStateTests: XCTestCase {
    func testRoundTripPreservesWindowOrderFilesAndSelection() throws {
        let name = "AletheiaSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = WindowSession(frame: CGRect(x: -700, y: 40, width: 800, height: 600),
                                  rootPath: "/project", filePaths: ["/project/b.md", "/project/a.ts"],
                                  selectedPath: "/project/a.ts", treeWidth: 310, editorFraction: 0.4)
        let second = WindowSession(frame: CGRect(x: 50, y: 60, width: 900, height: 700),
                                   rootPath: nil, filePaths: [], selectedPath: nil)
        let state = SessionState(windows: [first, second], activeWindowIndex: 1)
        state.save(to: defaults)
        XCTAssertEqual(SessionState.load(from: defaults), state)
        var unsupported = state
        unsupported.version = 2
        unsupported.save(to: defaults)
        XCTAssertNil(SessionState.load(from: defaults))
        defaults.set(Data("broken".utf8), forKey: "lastSession")
        XCTAssertNil(SessionState.load(from: defaults))
    }

    func testFrameClampingHandlesRemovedScreenAndInvalidGeometry() {
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
        var window = WindowSession(frame: CGRect(x: -3000, y: -1000, width: 2500, height: 1800),
                                   rootPath: nil, filePaths: [], selectedPath: nil)
        XCTAssertEqual(window.visibleFrame(on: [screen]), screen)
        window.frame = CGRect(x: 1400, y: 850, width: 800, height: 600)
        XCTAssertEqual(window.visibleFrame(on: [screen]), CGRect(x: 640, y: 300, width: 800, height: 600))
        window.frame = CGRect(x: CGFloat.nan, y: 0, width: 0, height: 0)
        let repaired = window.visibleFrame(on: [screen])
        XCTAssertTrue(screen.contains(repaired))
        XCTAssertEqual(repaired.size, CGSize(width: 1080, height: 720))
        let external = CGRect(x: -1600, y: 0, width: 1600, height: 1000)
        window.frame = CGRect(x: -1500, y: 100, width: 900, height: 700)
        XCTAssertEqual(window.visibleFrame(on: [screen, external]), window.frame)
    }

    @MainActor func testRestoreReadsDiskInOrderSelectsAndSkipsMissingItems() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("b.txt")
        let second = directory.appendingPathComponent("a.txt")
        let missing = directory.appendingPathComponent("missing.txt")
        try Data("first on disk".utf8).write(to: first)
        try Data("selected on disk".utf8).write(to: second)
        let state = WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                  rootPath: directory.path,
                                  filePaths: [first.path, missing.path, second.path, first.path],
                                  selectedPath: second.path)
        let controller = EditorWindow()
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(state) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(controller.session.rootPath, directory.resolvingSymlinksInPath().path)
        XCTAssertEqual(controller.session.filePaths, [first.path, second.path])
        XCTAssertEqual(controller.session.selectedPath, second.path)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains(missing.path))
        XCTAssertEqual((controller.window?.firstResponder as? NSTextView)?.string, "selected on disk")
        controller.window?.performClose(nil)
    }

    @MainActor func testMissingRootAndSelectedFileFallBackToAvailableTab() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("available".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let missing = file.path + ".missing"
        let controller = EditorWindow()
        let state = WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                                  rootPath: missing, filePaths: [missing, file.path], selectedPath: missing)
        let failures: [String] = await withCheckedContinuation { continuation in
            controller.restore(state) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(controller.session.rootPath)
        XCTAssertEqual(controller.session.filePaths, [file.path])
        XCTAssertEqual(controller.session.selectedPath, file.path)
        XCTAssertEqual(failures.count, 2)
        controller.window?.performClose(nil)
    }
}
