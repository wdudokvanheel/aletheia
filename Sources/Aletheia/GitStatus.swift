import Foundation

/// Both index and worktree states are retained, including mixed staged/unstaged changes.
struct GitStatus: OptionSet, Sendable, Equatable {
    let rawValue: UInt8
    static let added = Self(rawValue: 1 << 0)
    static let deleted = Self(rawValue: 1 << 1)
    static let staged = Self(rawValue: 1 << 2)
    static let unstaged = Self(rawValue: 1 << 3)
    static let untracked = Self(rawValue: 1 << 4)
    static let conflict = Self(rawValue: 1 << 5)

    var description: String {
        var labels: [String] = []
        if contains(.conflict) { labels.append("Conflict") }
        if contains(.added) { labels.append("Added") }
        if contains(.deleted) { labels.append("Deleted") }
        if contains(.staged) { labels.append("Staged") }
        if contains(.unstaged) { labels.append("Unstaged") }
        if contains(.untracked) { labels.append("Untracked") }
        return labels.joined(separator: ", ")
    }
}

struct GitStatusSnapshot: Sendable {
    var paths: [String: GitStatus] = [:]
    private var untrackedDirectories: Set<String> = []

    func status(for url: URL) -> GitStatus {
        var path = url.standardizedFileURL
        if let status = paths[path.path] { return status }
        while path.path != "/" {
            if untrackedDirectories.contains(path.path) { return .untracked }
            path.deleteLastPathComponent()
        }
        return []
    }

    /// Porcelain v1 -z emits destination then source for renames, with literal paths.
    static func parse(_ data: Data, repository: URL) -> Self {
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        var snapshot = Self()
        var index = 0
        while index < records.count {
            let record = Array(records[index])
            index += 1
            guard record.count > 3, record[2] == 32 else { continue }
            let x = record[0], y = record[1]
            let path = String(decoding: record.dropFirst(3), as: UTF8.self)
            var status: GitStatus = []
            if x == 63 && y == 63 { status = .untracked }
            else if x == 33 && y == 33 { continue }
            else {
                if x != 32 && x != 63 { status.insert(.staged) }
                if y != 32 && y != 63 { status.insert(.unstaged) }
                if x == 65 || y == 65 { status.insert(.added) }
                if x == 68 || y == 68 { status.insert(.deleted) }
                if x == 85 || y == 85 || (x == 65 && y == 65) || (x == 68 && y == 68) {
                    status.insert(.conflict)
                }
            }
            if status == .untracked && path.hasSuffix("/") {
                snapshot.untrackedDirectories.insert(repository.appendingPathComponent(path).standardizedFileURL.path)
            }
            snapshot.insert(status, path: path, repository: repository)
            if x == 82 || y == 82 || x == 67 || y == 67 {
                guard index < records.count else { continue }
                let source = String(decoding: records[index], as: UTF8.self)
                index += 1
                // The old directory still reflects the removal when a rename crosses folders.
                if x == 82 || y == 82 {
                    snapshot.insert(status.union(.deleted), path: source, repository: repository)
                }
            }
        }
        return snapshot
    }

    private mutating func insert(_ status: GitStatus, path: String, repository: URL) {
        guard !path.isEmpty, !status.isEmpty else { return }
        let root = repository.standardizedFileURL.path
        var url = repository.appendingPathComponent(path).standardizedFileURL
        guard url.path == root || url.path.hasPrefix(root + "/") else { return }
        while true {
            paths[url.path, default: []].formUnion(status)
            if url.path == root { break }
            url.deleteLastPathComponent()
        }
    }

    /// Run only on a worker queue. Git handles ignored/untracked directories; the app never crawls them.
    static func read(root: URL) -> Self {
        guard let top = runGit(["rev-parse", "--show-toplevel"], at: root),
              var path = String(data: top, encoding: .utf8) else { return Self() }
        // Remove Git's one output terminator, preserving whitespace in the actual directory name.
        if path.hasSuffix("\n") { path.removeLast() }
        guard !path.isEmpty,
              let data = runGit(["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--", "."], at: root)
        else { return Self() }
        return parse(data, repository: URL(fileURLWithPath: path, isDirectory: true))
    }

    private static func runGit(_ arguments: [String], at root: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-C", root.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch { return nil }
    }
}
