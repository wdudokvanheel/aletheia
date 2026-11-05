import XCTest
@testable import Aletheia

final class ProjectPickerTests: XCTestCase {
    func testCatalogReadsOnlyVisibleImmediateFoldersAndDeduplicatesPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: real)
        let catalog = ProjectCatalog.read(base: root)
        XCTAssertNil(catalog.notice)
        XCTAssertEqual(catalog.projects.count, 1)
        XCTAssertEqual(catalog.projects.first?.directory.path, real.resolvingSymlinksInPath().path)
    }

    func testFuzzyQueryIncludesPathAndDigits() {
        let project = PickerProject(name: "Project 12", directory: URL(fileURLWithPath: "/tmp/workspace/hello"))
        XCTAssertTrue(ProjectCatalog.matches(project, query: ""))
        XCTAssertTrue(ProjectCatalog.matches(project, query: "Pj12"))
        XCTAssertTrue(ProjectCatalog.matches(project, query: "wshlo"))
        XCTAssertFalse(ProjectCatalog.matches(project, query: "21"))
    }

    func testNameMatchesRankAheadOfIncidentalPathMatches() {
        let tattoo = PickerProject(name: "tattoo agenda", directory: URL(fileURLWithPath: "/tmp/dudok/workspace/tattoo-agenda"))
        let fuzzy = PickerProject(name: "dark", directory: URL(fileURLWithPath: "/tmp/dark"))
        let dkdmk = PickerProject(name: "dkdmk", directory: URL(fileURLWithPath: "/tmp/dkdmk"))
        let exact = PickerProject(name: "dk", directory: URL(fileURLWithPath: "/tmp/dk"))
        let input = [tattoo, fuzzy, dkdmk, exact]
        XCTAssertEqual(ProjectCatalog.ranked(input, query: "dk").map(\.name), ["dk", "dkdmk", "dark", "tattoo agenda"])
        XCTAssertEqual(ProjectCatalog.ranked(input, query: ""), input)
        XCTAssertEqual(ProjectCatalog.ranked(input, query: "  DK  ").first, exact)
    }

    func testQueryCannotMatchAcrossNameAndUnrelatedPath() {
        let project = PickerProject(name: "dog", directory: URL(fileURLWithPath: "/tmp/kite"))
        XCTAssertFalse(ProjectCatalog.matches(project, query: "dk"))
    }

    @MainActor func testExplicitAssignmentsPersist() throws {
        let suite = "ProjectSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ProjectSettings(defaults: defaults)
        let projects = (0..<12).map { PickerProject(name: "p\($0)", directory: URL(fileURLWithPath: "/tmp/p\($0)")) }
        XCTAssertTrue(settings.assignments.allSatisfy { $0 == nil })
        settings.assign(projects[9], to: 9)
        settings.assign(projects[11], to: 0)
        settings.assign(nil, to: 1)
        let restored = ProjectSettings(defaults: defaults)
        XCTAssertEqual(restored.assignments[0], projects[11])
        XCTAssertNil(restored.assignments[1])
        XCTAssertEqual(restored.assignments[9], projects[9])
        settings.baseDirectory = URL(fileURLWithPath: "/tmp/custom-workspace")
        XCTAssertEqual(restored.baseDirectory, URL(fileURLWithPath: "/tmp/custom-workspace").resolvingSymlinksInPath())
    }

}
