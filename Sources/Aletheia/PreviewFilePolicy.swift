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
