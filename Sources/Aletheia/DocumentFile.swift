import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Disk snapshots for tabs. Only text snapshots have a write path.
enum DocumentFile: Sendable {
    case text(TextFile)
    case preview(PreviewFile)

    var requestedURL: URL {
        switch self { case .text(let file): file.requestedURL; case .preview(let file): file.requestedURL }
    }
    var url: URL {
        switch self { case .text(let file): file.url; case .preview(let file): file.url }
    }
    var isText: Bool { if case .text = self { true } else { false } }
    var text: String { if case .text(let file) = self { file.text } else { "" } }
    var newline: String { if case .text(let file) = self { file.newline } else { "\n" } }

    static func read(_ url: URL) throws -> DocumentFile {
        if let kind = PreviewFile.Kind.forURL(url.resolvingSymlinksInPath()) {
            return .preview(try PreviewFile.read(url, kind: kind))
        }
        return .text(try TextFile.read(url))
    }

    func matches(_ other: DocumentFile) -> Bool {
        switch (self, other) {
        case (.text(let a), .text(let b)): a.matches(b)
        case (.preview(let a), .preview(let b)): a == b
        default: false
        }
    }

    func reread() throws -> DocumentFile {
        switch self {
        case .text(let file): .text(try TextFile.read(file.requestedURL))
        case .preview(let file): .preview(try PreviewFile.read(file.requestedURL, kind: file.kind))
        }
    }

    func save(_ text: String) throws -> DocumentFile {
        guard case .text(let file) = self else { throw PreviewFile.LoadError.readOnly }
        return .text(try file.save(text))
    }
}

struct PreviewFile: Sendable, Equatable {
    enum Kind: Sendable {
        case pdf, image

        static func forURL(_ url: URL) -> Kind? {
            guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .image) { return .image }
            return nil
        }
    }

    enum LoadError: LocalizedError {
        case invalidPDF, lockedPDF, invalidImage, readOnly
        var errorDescription: String? {
            switch self {
            case .invalidPDF: "This PDF could not be opened. It may be damaged or contain no pages."
            case .lockedPDF: "This PDF requires a password. Open it in Preview to unlock it."
            case .invalidImage: "This image could not be opened by macOS. It may be damaged or use an unsupported format."
            case .readOnly: "PDF and image tabs are read-only and cannot be saved."
            }
        }
    }

    let requestedURL: URL
    let url: URL
    let kind: Kind
    let data: Data
    private let inode: UInt64
    private let modified: Date

    static func read(_ requestedURL: URL, kind: Kind) throws -> PreviewFile {
        var result: Result<PreviewFile, Error>!
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: requestedURL, options: [], error: &coordinationError) { coordinated in
            result = Result {
                let url = coordinated.resolvingSymlinksInPath()
                let before = try FileManager.default.attributesOfItem(atPath: url.path)
                guard before[.type] as? FileAttributeType == .typeRegular else { throw TextFile.FileError.notRegular }
                let data = try Data(contentsOf: url)
                let after = try FileManager.default.attributesOfItem(atPath: url.path)
                for key in [FileAttributeKey.systemFileNumber, .systemNumber, .modificationDate, .size] {
                    guard (before[key] as? NSObject) == (after[key] as? NSObject) else { throw TextFile.FileError.changed }
                }
                switch kind {
                case .pdf:
                    guard let pdf = PDFDocument(data: data) else { throw LoadError.invalidPDF }
                    guard !pdf.isLocked else { throw LoadError.lockedPDF }
                    guard pdf.pageCount > 0 else { throw LoadError.invalidPDF }
                case .image:
                    guard let image = NSImage(data: data), image.isValid else { throw LoadError.invalidImage }
                }
                return PreviewFile(requestedURL: requestedURL, url: url, kind: kind, data: data,
                                   inode: (before[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                                   modified: before[.modificationDate] as? Date ?? .distantPast)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
