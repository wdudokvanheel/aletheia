import XCTest
@testable import Aletheia

final class ProjectPickerTests: XCTestCase {
    func testSavedOrderThenCreationThenInactiveThenFolders() {
        let home = URL(fileURLWithPath: "/tmp/picker-home")
        let catalog = ProjectCatalog.assemble(
            sessions: "$11\tlater\t/tmp/later\n$2\tearly\t/tmp/early\n$8\tpinned\t/tmp/pinned\nmalformed",
            order: "missing\npinned\npinned\n", keys: "# comment\na early /tmp/ignored\nb sleeping ~/project with spaces\nc alias /tmp/pinned",
            folders: [URL(fileURLWithPath: "/tmp/pinned"), URL(fileURLWithPath: "/tmp/new")], home: home)
        XCTAssertEqual(catalog.projects.map(\.name), ["pinned", "early", "later", "sleeping", "alias", "new"])
        XCTAssertEqual(catalog.running.map(\.name), ["pinned", "early", "later"])
        XCTAssertEqual(catalog.projects[3].directory.path, home.appendingPathComponent("project with spaces").resolvingSymlinksInPath().path)
        XCTAssertEqual(catalog.projects[0].directory, catalog.projects[4].directory)
    }

    func testCanonicalDirectoryDeduplicatesSymlinkFolderButRetainsSessionAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let catalog = ProjectCatalog.assemble(sessions: "$1\tfirst\t\(link.path)\n$2\talias\t\(real.path)", order: "", keys: "", folders: [link, real], home: root)
        XCTAssertEqual(catalog.projects.count, 2)
        XCTAssertEqual(catalog.projects[0].directory, real.resolvingSymlinksInPath())
        XCTAssertEqual(catalog.projects[0].directory, catalog.projects[1].directory)
    }

    func testFuzzyQueryIncludesPathAndDigits() {
        let project = PickerProject(name: "Project 12", directory: URL(fileURLWithPath: "/tmp/workspace/hello"))
        XCTAssertTrue(ProjectCatalog.matches(project, query: ""))
        XCTAssertTrue(ProjectCatalog.matches(project, query: "Pj12"))
        XCTAssertTrue(ProjectCatalog.matches(project, query: "wshlo"))
        XCTAssertFalse(ProjectCatalog.matches(project, query: "21"))
    }

    @MainActor func testAssignmentsSeedOnceAndUserChangesRemainAuthoritative() throws {
        let suite = "ProjectSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ProjectSettings(defaults: defaults)
        let projects = (0..<12).map { PickerProject(name: "p\($0)", directory: URL(fileURLWithPath: "/tmp/p\($0)")) }
        settings.seedIfNeeded(projects)
        XCTAssertEqual(settings.assignments.compactMap { $0 }, Array(projects.prefix(10)))
        settings.assign(projects[11], to: 0)
        settings.assign(nil, to: 1)
        settings.seedIfNeeded(Array(projects.reversed()))
        let restored = ProjectSettings(defaults: defaults)
        XCTAssertEqual(restored.assignments[0], projects[11])
        XCTAssertNil(restored.assignments[1])
        XCTAssertEqual(restored.assignments[9], projects[9])
        settings.baseDirectory = URL(fileURLWithPath: "/tmp/custom-workspace")
        XCTAssertEqual(restored.baseDirectory, URL(fileURLWithPath: "/tmp/custom-workspace").resolvingSymlinksInPath())
    }

    @MainActor func testExplicitAssignmentBeforeLoadPreventsSeeding() throws {
        let suite = "ProjectSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ProjectSettings(defaults: defaults)
        settings.assign(nil, to: 0)
        settings.seedIfNeeded([PickerProject(name: "one", directory: URL(fileURLWithPath: "/tmp"))])
        XCTAssertTrue(settings.assignments.allSatisfy { $0 == nil })
    }
}
