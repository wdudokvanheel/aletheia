import AppKit
import ImageIO
import Synchronization

/// Why a preview image did not load; the view shows its alt text instead.
enum PreviewImageError: Error, Equatable {
    /// Not a permitted source: a path outside the document's folder or through an
    /// escaping symlink, a scheme other than a relative path, `file:` or HTTPS,
    /// credentials in the URL, or a redirect away from HTTPS.
    case blocked
    /// No file at the path, or the server answered 404 or 410.
    case notFound
    /// Over the response cap or the pixel cap.
    case tooLarge
    /// Not an image type the preview shows, by extension, content type or contents.
    case badType
    /// The request failed, timed out, or the server answered with an error status.
    case network(URLError.Code)
    /// The bytes are not a decodable image.
    case decode
}

/// A decoded preview image, ready to draw.
final class PreviewImage: Sendable {
    /// The first frame, downsampled to at most the requested display size times the scale.
    let image: CGImage
    /// The natural size in points, as a browser lays the image out: the pixel size
    /// of a raster image, the declared size of an SVG.
    let size: CGSize
    /// Per-frame delays of an animated GIF, WebP or PNG; empty for a still image.
    let frameDelays: [TimeInterval]
    /// What the image costs the memory cache, in bytes.
    let cost: Int
    private let frames: Mutex<CGImageSource?>
    private let maxPixelSize: Int

    var frameCount: Int { max(1, frameDelays.count) }

    fileprivate init(image: CGImage, size: CGSize, frameDelays: [TimeInterval] = [],
                     frames: sending CGImageSource? = nil, maxPixelSize: Int = 0, retainedBytes: Int = 0) {
        self.image = image
        self.size = size
        self.frameDelays = frameDelays
        self.frames = Mutex(frames)
        self.maxPixelSize = maxPixelSize
        cost = image.bytesPerRow * image.height + retainedBytes
    }

    /// Frame `index` of an animated image, decoded on the calling thread at the size of `image`.
    func frame(at index: Int) -> CGImage? {
        guard index == 0 || frameDelays.indices.contains(index) else { return nil }
        return frames.withLock { source in
            guard let source else { return index == 0 ? image : nil }
            return CGImageSourceCreateThumbnailAtIndex(source, index, PreviewImageLoader.thumbnailOptions(maxPixelSize))
        }
    }
}

/// Loads images for the Custom Markdown preview: raster files inside the
/// document's folder, checked by `PreviewFilePolicy`, and HTTPS images.
///
/// It is main-actor bound: requests start and complete on the main thread, and
/// fetching and decoding run on the concurrent pool. One instance serves the
/// app, so windows share its session, disk cache and decoded-image cache.
/// It never loads anything but the image bytes, and it never retries.
@MainActor
final class PreviewImageLoader {
    static let shared = PreviewImageLoader()

    /// Remote limits from the plan's Phase 7, then the decode and cache caps.
    nonisolated static let timeout: TimeInterval = 15
    nonisolated static let maxResponseBytes = 10 << 20
    nonisolated static let maxPixels = 50_000_000
    nonisolated static let memoryCacheBytes = 64 << 20
    nonisolated static let diskCacheBytes = 100 << 20

    nonisolated static let rasterTypes: Set<String> = ["public.png", "public.jpeg", "com.compuserve.gif",
                                                       "org.webmproject.webp", "public.avif"]
    nonisolated static let remoteTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp",
                                                       "image/avif", "image/svg+xml"]

    let session: URLSession
    private let maxResponseBytes: Int
    private let decoded = NSCache<NSString, PreviewImage>()

    /// The configuration's cookie, credential, cache and timeout settings are
    /// replaced; tests pass one with a stub protocol, a short timeout and no cache.
    init(configuration: URLSessionConfiguration = .default, cache: URLCache? = PreviewImageLoader.diskCache(),
         timeout: TimeInterval = PreviewImageLoader.timeout,
         maxResponseBytes: Int = PreviewImageLoader.maxResponseBytes) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = cache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpAdditionalHeaders = ["Accept": Self.remoteTypes.sorted().joined(separator: ",")]
        session = URLSession(configuration: configuration)
        self.maxResponseBytes = maxResponseBytes
        decoded.totalCostLimit = Self.memoryCacheBytes
    }

    deinit { session.invalidateAndCancel() }

    /// Remote image bytes on disk under `~/Library/Caches`, honoring HTTP cache headers.
    nonisolated static func diskCache() -> URLCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Aletheia")
            .appendingPathComponent("PreviewImages", isDirectory: true)
        return URLCache(memoryCapacity: 0, diskCapacity: diskCacheBytes, directory: directory)
    }

    /// Loads the image a Markdown image source names, resolving relative paths
    /// against `documentDirectory`, and decodes it to fit `displaySize` (points;
    /// nil keeps the natural size) at `scale` pixels per point.
    ///
    /// A memory-cache hit completes before this returns, and returns nil.
    /// Otherwise cancelling the returned task stops the load, and `completion`
    /// then never runs. Failures are not cached.
    @discardableResult
    func image(for source: String, relativeTo documentDirectory: URL?, displaySize: CGSize?, scale: CGFloat,
               completion: @escaping @MainActor (Result<PreviewImage, PreviewImageError>) -> Void) -> Task<Void, Never>? {
        let key = Self.cacheKey(source, documentDirectory, displaySize, scale)
        if let image = decoded.object(forKey: key) {
            completion(.success(image))
            return nil
        }
        let session = session, maxResponseBytes = maxResponseBytes
        return Task {
            let result = await Self.load(source, relativeTo: documentDirectory, displaySize: displaySize,
                                         scale: scale, session: session, maxResponseBytes: maxResponseBytes)
            guard !Task.isCancelled else { return }
            if case .success(let image) = result { decoded.setObject(image, forKey: key, cost: image.cost) }
            completion(result)
        }
    }

    /// Absolute HTTPS sources are shared between documents; others belong to their folder.
    private static func cacheKey(_ source: String, _ directory: URL?, _ displaySize: CGSize?,
                                 _ scale: CGFloat) -> NSString {
        let folder = source.lowercased().hasPrefix("https:") ? "" : directory?.standardizedFileURL.path ?? ""
        let box = displaySize.map { "\($0.width)x\($0.height)" } ?? "natural"
        return "\(folder)\u{0}\(source)\u{0}\(box)@\(scale)" as NSString
    }

    @concurrent
    private nonisolated static func load(_ source: String, relativeTo directory: URL?, displaySize: CGSize?,
                                         scale: CGFloat, session: URLSession,
                                         maxResponseBytes: Int) async -> Result<PreviewImage, PreviewImageError> {
        do throws(PreviewImageError) {
            switch try location(of: source, relativeTo: directory) {
            case .file(let file):
                guard let image = CGImageSourceCreateWithURL(file as CFURL, sourceOptions) else { throw .decode }
                return .success(try decodeRaster(image, displaySize: displaySize, scale: scale, retainedBytes: 0))
            case .remote(let url):
                let (data, type) = try await fetch(url, session: session, maxResponseBytes: maxResponseBytes)
                if Task.isCancelled { throw .network(.cancelled) }
                // The bytes decide the decoder; a declared SVG that sniffs as an allowed raster type is raster.
                let image = CGImageSourceCreateWithData(data as CFData, sourceOptions)
                let sniffed = image.flatMap { CGImageSourceGetType($0) as String? } ?? ""
                if type == "image/svg+xml", !rasterTypes.contains(sniffed) {
                    return .success(try decodeSVG(data, displaySize: displaySize, scale: scale))
                }
                guard let image else { throw .decode }
                return .success(try decodeRaster(image, displaySize: displaySize, scale: scale,
                                                 retainedBytes: data.count))
            }
        } catch {
            return .failure(error)
        }
    }

    private enum Location { case file(URL), remote(URL) }

    /// Resolves a source the way the WebKit page resolves image sources: against
    /// a per-call document base, so only paths that stay under it name files.
    nonisolated private static func location(of source: String,
                                             relativeTo directory: URL?) throws(PreviewImageError) -> Location {
        let token = UUID().uuidString
        guard let url = URL(string: source, relativeTo: PreviewLink.base(token: token))?.absoluteURL else {
            throw .blocked
        }
        switch url.scheme?.lowercased() {
        case "https":
            guard url.host?.isEmpty == false, url.user == nil, url.password == nil else { throw .blocked }
            return .remote(url)
        case "aletheia-preview":
            guard let directory, url.host == "document", url.pathComponents.count >= 3,
                  url.pathComponents[1] == token else { throw .blocked }
            return .file(try localFile(url.pathComponents.dropFirst(2).joined(separator: "/"), in: directory))
        case "file":
            // Allowed only for files that pass the same check relative to the document folder.
            guard let directory, (url.host ?? "").isEmpty || url.host == "localhost" else { throw .blocked }
            let path = url.standardizedFileURL.path
            for root in [directory.standardizedFileURL.path, directory.resolvingSymlinksInPath().path] {
                let prefix = root.hasSuffix("/") ? root : root + "/"
                if path.hasPrefix(prefix) { return .file(try localFile(String(path.dropFirst(prefix.count)), in: directory)) }
            }
            throw .blocked
        default:
            throw .blocked
        }
    }

    nonisolated private static func localFile(_ path: String, in directory: URL) throws(PreviewImageError) -> URL {
        guard let file = PreviewFilePolicy.localURL(for: path, in: directory) else {
            // Tell a missing file from one the policy refuses, such as an escaping symlink.
            throw FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path)
                ? .blocked : .notFound
        }
        guard PreviewFilePolicy.imageType(of: file) != nil else { throw .badType }
        return file
    }

    /// The image bytes and content type, read while streaming up to the response cap.
    @concurrent
    nonisolated private static func fetch(_ url: URL, session: URLSession,
                                          maxResponseBytes: Int) async throws(PreviewImageError) -> (Data, String) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        let redirects = HTTPSRedirects()
        do { (bytes, response) = try await session.bytes(from: url, delegate: redirects) } catch {
            throw redirects.refused ? .blocked : failure(error)
        }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.url?.scheme?.lowercased() == "https" else {
            throw .blocked
        }
        switch http.statusCode {
        case 200..<300: break
        case 300..<400: throw .blocked // a redirect `HTTPSRedirects` refused, or one it never saw
        case 404, 410: throw .notFound
        default: throw .network(.badServerResponse)
        }
        guard let type = http.mimeType?.lowercased(), remoteTypes.contains(type) else { throw .badType }
        guard http.expectedContentLength <= Int64(maxResponseBytes) else { throw .tooLarge }
        var data = [UInt8]()
        data.reserveCapacity(max(0, Int(http.expectedContentLength)))
        do {
            for try await byte in bytes {
                guard data.count < maxResponseBytes else { throw PreviewImageError.tooLarge }
                data.append(byte)
            }
        } catch let error as PreviewImageError {
            throw error
        } catch {
            throw failure(error)
        }
        return (Data(data), type)
    }

    nonisolated private static func failure(_ error: any Error) -> PreviewImageError {
        guard let error = error as? URLError else { return .network(.unknown) }
        return error.code == .appTransportSecurityRequiresSecureConnection ? .blocked : .network(error.code)
    }

    nonisolated private static var sourceOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    nonisolated static func thumbnailOptions(_ maxPixelSize: Int) -> CFDictionary {
        [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
         kCGImageSourceCreateThumbnailWithTransform: true,
         kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary
    }

    /// The factor that fits `size` inside `box` without enlarging it.
    nonisolated private static func fit(_ size: CGSize, in box: CGSize?) -> CGFloat {
        guard let box else { return 1 }
        return min(1, box.width / size.width, box.height / size.height)
    }

    /// Reads the pixel size from the header, refuses images over the pixel cap,
    /// and downsamples the rest with ImageIO.
    nonisolated private static func decodeRaster(_ source: sending CGImageSource, displaySize: CGSize?, scale: CGFloat,
                                                 retainedBytes: Int) throws(PreviewImageError) -> PreviewImage {
        guard let type = CGImageSourceGetType(source) as String? else { throw .decode }
        guard rasterTypes.contains(type) else { throw .badType }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw .decode }
        guard width * height <= maxPixels else { throw .tooLarge }
        let rotated = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        let size = rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let factor = min(1, fit(size, in: displaySize) * scale)
        let maxPixelSize = max(1, Int((CGFloat(max(width, height)) * factor).rounded(.up)))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(maxPixelSize)) else {
            throw .decode
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return PreviewImage(image: image, size: size) }
        return PreviewImage(image: image, size: size, frameDelays: (0..<count).map { delay(source, at: $0) },
                            frames: source, maxPixelSize: maxPixelSize, retainedBytes: retainedBytes)
    }

    nonisolated private static func delay(_ source: CGImageSource, at index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let keys = [(kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
                    (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
                    (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)]
        for (dictionary, unclamped, clamped) in keys {
            guard let frame = properties?[dictionary] as? [CFString: Any],
                  let delay = (frame[unclamped] ?? frame[clamped]) as? Double else { continue }
            return delay < 0.011 ? 0.1 : delay // browsers play near-zero delays at 10 fps
        }
        return 0.1
    }

    /// Decodes SVG with AppKit's native renderer, which ImageIO lacks, and
    /// rasterizes it here, off the main thread, at the display size.
    nonisolated private static func decodeSVG(_ data: Data, displaySize: CGSize?,
                                              scale: CGFloat) throws(PreviewImageError) -> PreviewImage {
        guard data.range(of: Data("<svg".utf8)) != nil, let svg = NSImage(data: data),
              svg.size.width > 0, svg.size.height > 0 else { throw .decode }
        let factor = fit(svg.size, in: displaySize) * scale
        let width = (svg.size.width * factor).rounded(.up), height = (svg.size.height * factor).rounded(.up)
        guard width.isFinite, height.isFinite, width * height <= CGFloat(maxPixels) else { throw .tooLarge }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: max(1, Int(width)), height: max(1, Int(height)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw .decode }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        svg.draw(in: CGRect(x: 0, y: 0, width: context.width, height: context.height),
                 from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.current = previous
        guard let image = context.makeImage() else { throw .decode }
        return PreviewImage(image: image, size: svg.size)
    }
}

/// One load's redirect policy: follow only to HTTPS, and remember a refusal so
/// the load reports it as blocked however the refused task then ends.
private final class HTTPSRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    private let refusal = Mutex(false)
    var refused: Bool { refusal.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard request.url?.scheme?.lowercased() == "https" else {
            refusal.withLock { $0 = true }
            return nil
        }
        return request
    }
}
