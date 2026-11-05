import Foundation

/// The exact bytes and filesystem identity last read or saved. No file watcher or autosave.
struct TextFile: Sendable {
    let requestedURL: URL
    let url: URL
    let text: String
    let hasBOM: Bool
    let newline: String
    private let bytes: Data
    private let identity: Identity

    private struct Identity: Equatable, Sendable {
        let inode: UInt64
        let device: UInt64
        let modified: Date
        let permissions: UInt16

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw FileError.notRegular
            }
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
            modified = attributes[.modificationDate] as? Date ?? .distantPast
            permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        }
    }

    enum FileError: LocalizedError {
        case notText, notRegular, changed

        var errorDescription: String? {
            switch self {
            case .notText: return "This file is not supported UTF-8 text. Binary files and other encodings cannot be edited."
            case .notRegular: return "Only existing regular text files can be opened."
            case .changed: return "The file changed outside Aletheia, or its path now points to another file. Your edits have not been saved."
            }
        }
    }

    static func read(_ requestedURL: URL) throws -> TextFile {
        var result: Result<TextFile, Error>!
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: requestedURL, options: [], error: &coordinationError) { coordinated in
            result = Result { try readUncoordinated(requestedURL: requestedURL, url: coordinated.resolvingSymlinksInPath()) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private static func readUncoordinated(requestedURL: URL, url: URL) throws -> TextFile {
        let before = try Identity(url)
        let bytes = try Data(contentsOf: url)
        guard before == (try Identity(url)) else { throw FileError.changed }
        let bom = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        let content = bom ? bytes.dropFirst(3) : bytes[...]
        guard let text = String(data: content, encoding: .utf8),
              !text.unicodeScalars.contains(where: {
                  $0.value == 0 || ($0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13)
              }) else { throw FileError.notText }
        // Keep every original newline verbatim. New edits use the first existing newline style.
        let newline: String
        if let index = text.firstIndex(where: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            newline = String(text[index])
        } else {
            newline = "\n"
        }
        return TextFile(requestedURL: requestedURL, url: url, text: text, hasBOM: bom,
                        newline: newline, bytes: bytes, identity: before)
    }

    func save(_ text: String) throws -> TextFile {
        var result: Result<TextFile, Error>!
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            result = Result {
                // Follow the original alias only while it still names the opened target.
                guard requestedURL.resolvingSymlinksInPath() == url,
                      coordinated.resolvingSymlinksInPath() == url,
                      try Identity(url) == identity,
                      try Data(contentsOf: url) == bytes else { throw FileError.changed }
                var output = Data()
                if hasBOM { output.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
                output.append(contentsOf: text.utf8)
                let manager = FileManager.default
                // A same-volume replacement directory gives rename-based atomic replacement.
                let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: url, create: true)
                defer { try? manager.removeItem(at: directory) }
                let temporary = directory.appendingPathComponent("content")
                try output.write(to: temporary)
                try manager.setAttributes([.posixPermissions: NSNumber(value: identity.permissions)],
                                          ofItemAtPath: temporary.path)
                // Recheck immediately before replacement as well as before staging the write.
                guard requestedURL.resolvingSymlinksInPath() == url,
                      coordinated.resolvingSymlinksInPath() == url,
                      try Identity(url) == identity,
                      try Data(contentsOf: url) == bytes else { throw FileError.changed }
                _ = try manager.replaceItemAt(url, withItemAt: temporary)
                return try Self.readUncoordinated(requestedURL: requestedURL, url: url)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func insertingNewlines(in text: String, style: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: style)
    }
}
