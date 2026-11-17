import Foundation

/// Rename and paste for the file tree. Neither ever replaces an existing item.
enum FileOperations {
    enum OperationError: LocalizedError {
        case intoItself(String)

        var errorDescription: String? {
            switch self {
            case .intoItself(let name): "“\(name)” cannot be pasted into itself or one of its folders."
            }
        }
    }

    /// Rejects names that would leave the folder or name no item, like New File does.
    static func checkName(_ name: String, for url: URL) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// Returns the new location, or `url` when the name is unchanged.
    static func rename(_ url: URL, to name: String) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        try checkName(name, for: destination)
        guard name != url.lastPathComponent else { return url }
        // A case-only rename on a case-insensitive volume finds the item itself there.
        if exists(destination), !sameItem(url, destination) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Copies each item into `directory` under a free name, in order. Returns the copies.
    static func paste(_ sources: [URL], into directory: URL) throws -> [URL] {
        let target = directory.resolvingSymlinksInPath().standardizedFileURL.path
        // Checked first, so a rejected paste copies nothing. A symlink is copied as a link.
        for source in sources {
            let path = canonical(source).path
            if target == path || target.hasPrefix(path + "/") {
                throw OperationError.intoItself(source.lastPathComponent)
            }
        }
        return try sources.map { source in
            let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
            let destination = freeURL(for: source.lastPathComponent, in: directory, isDirectory: isDirectory)
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }
    }

    /// Finder's naming: "name.ext", then "name copy.ext", "name copy 2.ext", and so on.
    static func freeURL(for name: String, in directory: URL, isDirectory: Bool) -> URL {
        let plain = directory.appendingPathComponent(name)
        guard exists(plain) else { return plain }
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var number = 1
        while true {
            let candidate = directory.appendingPathComponent(
                stem + (number == 1 ? " copy" : " copy \(number)") + (ext.isEmpty ? "" : "." + ext))
            if !exists(candidate) { return candidate }
            number += 1
        }
    }

    /// The parent's real location with the item's own name, so a symlink is not followed.
    static func canonical(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(url.lastPathComponent)
    }

    /// Counts broken symlinks too, unlike `fileExists`.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func sameItem(_ a: URL, _ b: URL) -> Bool {
        guard let first = try? FileManager.default.attributesOfItem(atPath: a.path),
              let second = try? FileManager.default.attributesOfItem(atPath: b.path) else { return false }
        return first[.systemFileNumber] as? NSNumber == second[.systemFileNumber] as? NSNumber
            && first[.systemNumber] as? NSNumber == second[.systemNumber] as? NSNumber
    }
}
