import Foundation

/// The local files a Markdown preview may read: regular files inside the document's
/// canonical directory, after resolving `..` and symlinks.
enum PreviewFilePolicy {
    static func localURL(for relativePath: String, in directory: URL) -> URL? {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path == "/" ? "/" : root.path + "/"),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }

    /// The MIME type of a raster image the preview may show, or nil for any other file.
    static func imageType(of file: URL) -> String? {
        ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
         "gif": "image/gif", "webp": "image/webp", "avif": "image/avif"][file.pathExtension.lowercased()]
    }
}

/// What a click on a preview link does, the same in both renderers: web and
/// mail links open in the system, links to regular files inside the document's
/// directory open in the editor, and anything else is ignored.
enum PreviewLink: Equatable {
    case system(URL)
    case editor(URL)

    /// What relative links resolve against: a document URL whose first path
    /// component is a per-page token, so only paths that stay under it name files.
    static func base(token: String) -> URL { URL(string: "aletheia-preview://document/\(token)/")! }

    /// The file a link resolved against `base(token:)` names, if the file policy allows it.
    static func localFile(_ url: URL, token: String, directory: URL?) -> URL? {
        guard url.scheme == "aletheia-preview", url.host == "document",
              let directory, url.pathComponents.count >= 3,
              url.pathComponents[1] == token else { return nil }
        return PreviewFilePolicy.localURL(for: url.pathComponents.dropFirst(2).joined(separator: "/"), in: directory)
    }

    /// The action for a link already resolved against `base(token:)`, as the
    /// WebKit page resolves every href.
    static func action(for url: URL, token: String, directory: URL?) -> PreviewLink? {
        if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { return .system(url) }
        return localFile(url, token: token, directory: directory).map(PreviewLink.editor)
    }

    /// The action for a destination as written in the Markdown, resolved the
    /// way the WebKit page resolves it, against a fresh token.
    static func action(forDestination destination: String, directory: URL?) -> PreviewLink? {
        let token = UUID().uuidString
        guard let url = URL(string: destination, relativeTo: base(token: token))?.absoluteURL else { return nil }
        return action(for: url, token: token, directory: directory)
    }
}
