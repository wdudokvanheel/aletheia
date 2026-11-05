import Foundation
import XCTest
@testable import Aletheia

final class GitStatusTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/project", isDirectory: true)

    private func parse(_ value: String) -> GitStatusSnapshot {
        GitStatusSnapshot.parse(Data(value.utf8), repository: root)
    }

    func testLiteralSpacesNewlinesAndMixedIndexWorktreeStatus() {
        let snapshot = parse("MM src/a b.ts\0A  new.json\0 M line\nname.txt\0?? quote\".txt\0")
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("src/a b.ts")), [.staged, .unstaged])
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("new.json")), [.added, .staged])
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("line\nname.txt")), .unstaged)
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("quote\".txt")), .untracked)
    }

    func testRenameConsumesSourceAndAggregatesBothDirectories() {
        let snapshot = parse("R  new folder/new name.ts\0old folder/old name.ts\0 M next.ts\0")
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("new folder/new name.ts")), .staged)
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("old folder")), [.staged, .deleted])
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("next.ts")), .unstaged)
        XCTAssertEqual(snapshot.status(for: root), [.staged, .deleted, .unstaged])
    }

    func testCopyDoesNotMarkSourceDeleted() {
        let snapshot = parse("C  copied.ts\0original.ts\0")
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("copied.ts")), .staged)
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("original.ts")), [])
    }

    func testDeletedChildrenAggregateWithoutDiskEnumerationAndWithoutSiblingLeakage() {
        let snapshot = parse(" D src/nested/gone.ts\0M  src/staged.ts\0?? other/new.txt\0")
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("src/nested")), [.deleted, .unstaged])
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("src")), [.deleted, .unstaged, .staged])
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("src/clean.ts")), [])
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("other/clean.txt")), [])
    }

    func testCollapsedUntrackedDirectoryStatusIsInheritedOnlyFromDirectRecords() {
        let snapshot = parse("?? new folder/\0?? existing/untracked.txt\0")
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("new folder/deep/file.ts")), .untracked)
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("new folder/deep")), .untracked)
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("existing/clean.txt")), [])
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("new folder sibling/clean.txt")), [])
        XCTAssertEqual(snapshot.status(for: root.appendingPathComponent("clean.txt")), [])
    }

    func testAllConflictPairsAndIgnoredEntries() {
        for pair in ["DD", "AU", "UD", "UA", "DU", "AA", "UU"] {
            XCTAssertTrue(parse("\(pair) file\0").status(for: root.appendingPathComponent("file")).contains(.conflict))
        }
        XCTAssertEqual(parse("!! ignored/\0").status(for: root), [])
        XCTAssertEqual(parse("\0bad\0").status(for: root), [])
    }

    func testGitReadWithNestedRootAndUntrackedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--quiet", directory.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let nested = directory.appendingPathComponent("nested space", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("file name.ts")
        try Data("hello".utf8).write(to: file)
        let snapshot = GitStatusSnapshot.read(root: nested)
        XCTAssertEqual(snapshot.status(for: file.resolvingSymlinksInPath()), .untracked)
        XCTAssertEqual(GitStatusSnapshot.read(root: directory.appendingPathComponent("missing")).paths, [:])
    }
}
