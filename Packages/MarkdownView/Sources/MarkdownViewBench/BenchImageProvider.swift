import AppKit
import ImageIO
import MarkdownView

/// Why an image did not load, named as the generated manifest's `expected` outcomes.
enum BenchImageFailure: String, Error, Sendable {
    /// Not a permitted source: a scheme other than a relative path or HTTPS, an absolute path,
    /// traversal out of the document's folder, an escaping symlink, a non-raster local file, or
    /// credentials in the URL.
    case blocked
    case missing
    /// The bytes are not a decodable image.
    case corrupt
    /// Over the pixel or response cap.
    case tooLarge = "too-large"
    /// A remote image the fixture server does not have.
    case network
}

/// The bench's stand-in for the network: serves `https://img.example.invalid/...` from the
/// generated corpus, so remote documents render offline and the same on every run.
///
/// `/fixtures/NAME` is `images/files/NAME`. Every other remote reference in the manifest is
/// synthesized once, at the `width` and `height` the manifest gives it: PNG, JPEG and GIF by
/// ImageIO, SVG (and extensionless badges, as badge services serve) as a hand-written SVG, and
/// WebP as PNG bytes, since ImageIO has no WebP encoder (the decoder sniffs the bytes).
final class RemoteFixtures: Sendable {
    struct Response: Sendable {
        let data: Data
        let mimeType: String
    }

    static let host = "img.example.invalid"
    private let files: URL?
    private let responses: [String: Response]

    static let empty = RemoteFixtures(files: nil, responses: [:])

    private init(files: URL?, responses: [String: Response]) {
        self.files = files
        self.responses = responses
    }

    struct Item: Sendable {
        let kind: String
        let width: Int
        let height: Int
    }

    /// The manifest's remote references to synthesize, by URL path.
    static func items(in manifest: [String: Any]) -> [String: Item] {
        guard let images = manifest["images"] as? [String: Any],
              let references = images["references"] as? [[String: Any]] else { return [:] }
        var wanted: [String: Item] = [:]
        for reference in references {
            guard let source = reference["source"] as? String, let url = URL(string: source),
                  url.scheme == "https", url.host == host, !url.path.hasPrefix("/fixtures/"),
                  let kind = reference["kind"] as? String, let width = reference["width"] as? Int,
                  let height = reference["height"] as? Int else { continue }
            wanted[url.path] = Item(kind: kind, width: width, height: height)
        }
        return wanted
    }

    /// Synthesizes `wanted`, off the main thread and in parallel.
    static func load(_ wanted: [String: Item], root: URL) async -> RemoteFixtures {
        guard !wanted.isEmpty else { return .empty }
        let made = await withTaskGroup(of: (String, Response?).self) { group in
            for (path, item) in wanted {
                group.addTask { (path, synthesize(kind: item.kind, width: item.width, height: item.height)) }
            }
            var made: [String: Response] = [:]
            for await (path, response) in group { made[path] = response }
            return made
        }
        return RemoteFixtures(files: root.appendingPathComponent("images/files"), responses: made)
    }

    var count: Int { responses.count }

    /// What the server answers for `url`, or nil for a 404.
    func response(for url: URL) -> Response? {
        guard url.host?.lowercased() == Self.host else { return nil }
        if url.path.hasPrefix("/fixtures/"), let files {
            let name = String(url.path.dropFirst("/fixtures/".count))
            guard !name.contains("/"), !name.hasPrefix("."),
                  let data = try? Data(contentsOf: files.appendingPathComponent(name)) else { return nil }
            return Response(data: data, mimeType: Self.mimeType(name))
        }
        return responses[url.path]
    }

    private static func mimeType(_ name: String) -> String {
        ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
         "webp": "image/webp", "avif": "image/avif", "svg": "image/svg+xml"][(name as NSString).pathExtension.lowercased()]
            ?? "application/octet-stream"
    }

    private static func synthesize(kind: String, width: Int, height: Int) -> Response? {
        switch kind {
        case "remote-svg", "remote-badge":
            let svg = """
                <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">\
                <rect width="\(width)" height="\(height)" rx="3" fill="#555"/>\
                <rect x="\(width / 2)" width="\(width - width / 2)" height="\(height)" fill="#4c1"/>\
                <text x="4" y="\(height * 3 / 4)" font-family="Helvetica" font-size="\(max(8, height / 2))" fill="#fff">bench</text></svg>
                """
            return Response(data: Data(svg.utf8), mimeType: "image/svg+xml")
        case "remote-jpeg": return raster(width, height, type: "public.jpeg", mime: "image/jpeg")
        case "remote-gif": return raster(width, height, type: "com.compuserve.gif", mime: "image/gif")
        case "remote-webp": return raster(width, height, type: "public.png", mime: "image/webp")
        default: return raster(width, height, type: "public.png", mime: "image/png")
        }
    }

    /// A flat image with two bands, encoded by ImageIO.
    private static func raster(_ width: Int, _ height: Int, type: String, mime: String) -> Response? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.45, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.6, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 3, width: width, height: height / 3))
        context.fill(CGRect(x: width / 3, y: 0, width: width / 3, height: height))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Response(data: data as Data, mimeType: mime)
    }
}

/// A small `MarkdownImageProvider` for the bench, following the plan's Phase 7 rules (the app's
/// `PreviewImageLoader` is not imported): local sources resolve against the document's folder and
/// must stay inside it, raster types only; remote sources are HTTPS only and come from
/// `RemoteFixtures`, after `latencyMs`; `http:`, `data:`, `file:` and absolute paths are blocked.
/// Decoding runs off the main thread with ImageIO downsampling to the display size times the
/// scale; animated GIF and WebP keep their source and decode frames on demand. There is no
/// decoded-image cache, so every request decodes.
@MainActor
final class BenchImageProvider: MarkdownImageProvider {
    struct Stats {
        var requested = 0
        var loaded = 0
        var failed = 0
        var cancelled = 0
        var failures: [String: Int] = [:]
        var inFlight = 0
        /// `now()` of the last request, completion or cancel.
        var lastActivity: UInt64 = 0
        /// `now()` of the last load or failure delivered to the view.
        var lastCompletion: UInt64?
    }

    nonisolated static let maxPixels = 50_000_000
    nonisolated static let maxResponseBytes = 10 << 20
    nonisolated static let rasterTypes: Set<String> = ["public.png", "public.jpeg", "com.compuserve.gif",
                                                       "org.webmproject.webp", "public.avif"]
    nonisolated static let rasterExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "avif"]

    /// Where relative sources resolve; set before each document is shown.
    var documentDirectory: URL?
    let latencyMs: Double
    let remote: RemoteFixtures
    private(set) var stats = Stats()
    /// Every request since the provider was made, for the document line.
    private(set) var totalRequested = 0

    init(latencyMs: Double, remote: RemoteFixtures) {
        self.latencyMs = latencyMs
        self.remote = remote
    }

    func resetStats() {
        let inFlight = stats.inFlight
        stats = Stats()
        stats.inFlight = inFlight
    }

    func requestImage(source: String, displaySize: CGSize?, scale: CGFloat,
                      completion: @escaping @MainActor (Result<MarkdownImage, any Error>) -> Void)
        -> MarkdownImageRequest? {
        stats.requested += 1
        stats.inFlight += 1
        stats.lastActivity = now()
        totalRequested += 1
        let directory = documentDirectory, remote = remote, latency = latencyMs
        let task = Task { [weak self] in
            let result = await Self.load(source, directory: directory, displaySize: displaySize, scale: scale,
                                         remote: remote, latencyMs: latency)
            guard let self else { return }
            self.stats.inFlight -= 1
            self.stats.lastActivity = now()
            if Task.isCancelled {
                self.stats.cancelled += 1
                return
            }
            switch result {
            case .success(let image):
                self.stats.loaded += 1
                self.stats.lastCompletion = now()
                completion(.success(image))
            case .failure(let failure):
                self.stats.failed += 1
                self.stats.failures[failure.rawValue, default: 0] += 1
                self.stats.lastCompletion = now()
                completion(.failure(failure))
            }
        }
        return MarkdownImageRequest { task.cancel() }
    }

    // MARK: Loading, off the main thread

    @concurrent
    nonisolated static func load(_ source: String, directory: URL?, displaySize: CGSize?, scale: CGFloat,
                                 remote: RemoteFixtures, latencyMs: Double) async -> Result<MarkdownImage, BenchImageFailure> {
        do throws(BenchImageFailure) {
            switch try location(of: source, directory: directory) {
            case .file(let file):
                guard let image = CGImageSourceCreateWithURL(file as CFURL, sourceOptions) else { throw .corrupt }
                return .success(try decodeRaster(image, displaySize: displaySize, scale: scale, extraBytes: 0))
            case .remote(let url):
                if latencyMs > 0 { try? await Task.sleep(for: .milliseconds(latencyMs)) }
                guard !Task.isCancelled else { throw .network }
                guard let response = remote.response(for: url) else { throw .network }
                guard response.data.count <= maxResponseBytes else { throw .tooLarge }
                let image = CGImageSourceCreateWithData(response.data as CFData, sourceOptions)
                let sniffed = image.flatMap { CGImageSourceGetType($0) as String? } ?? ""
                if response.mimeType == "image/svg+xml", !rasterTypes.contains(sniffed) {
                    return .success(try decodeSVG(response.data, displaySize: displaySize, scale: scale))
                }
                guard let image else { throw .corrupt }
                return .success(try decodeRaster(image, displaySize: displaySize, scale: scale,
                                                 extraBytes: response.data.count))
            }
        } catch {
            return .failure(error)
        }
    }

    enum Location { case file(URL), remote(URL) }

    /// Resolves `source` as a page would, against a per-call document base whose first path
    /// component is a fresh token: only paths that stay under it name files, so `..` out of the
    /// folder and absolute paths fail the token check.
    nonisolated static func location(of source: String, directory: URL?) throws(BenchImageFailure) -> Location {
        let token = UUID().uuidString
        guard let base = URL(string: "bench-document://document/\(token)/"),
              let url = URL(string: source, relativeTo: base)?.absoluteURL else { throw .blocked }
        switch url.scheme?.lowercased() {
        case "https":
            guard url.host?.isEmpty == false, url.user == nil, url.password == nil else { throw .blocked }
            return .remote(url)
        case "bench-document":
            guard let directory, url.host == "document", url.pathComponents.count >= 3,
                  url.pathComponents[1] == token else { throw .blocked }
            return .file(try localFile(url.pathComponents.dropFirst(2).joined(separator: "/"), in: directory))
        default:
            throw .blocked // http:, data:, file:, and every other scheme
        }
    }

    /// The canonical file for `path` inside `directory`: symlinks resolved, still inside the
    /// canonical folder, a regular file with a raster extension.
    nonisolated static func localFile(_ path: String, in directory: URL) throws(BenchImageFailure) -> URL {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let lexical = root.appendingPathComponent(path).standardizedFileURL
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard lexical.path.hasPrefix(prefix) else { throw .blocked }
        let file = lexical.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
        // A link that leaves the folder is blocked whether or not its target exists.
        guard file.path.hasPrefix(prefix) else { throw .blocked }
        guard exists, !isDirectory.boolValue else { throw .missing }
        guard rasterExtensions.contains(file.pathExtension.lowercased()) else { throw .blocked }
        return file
    }

    nonisolated static var sourceOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    nonisolated static func thumbnailOptions(_ maxPixelSize: Int) -> CFDictionary {
        [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
         kCGImageSourceCreateThumbnailWithTransform: true,
         kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary
    }

    /// The factor that fits `size` inside `box` without enlarging it.
    nonisolated static func fit(_ size: CGSize, in box: CGSize?) -> CGFloat {
        guard let box, box.width > 0, box.height > 0 else { return 1 }
        return min(1, box.width / size.width, box.height / size.height)
    }

    /// Reads the size from the header, refuses images over the pixel cap or not completely
    /// decodable, and downsamples the first frame. Animated images keep `source` for their frames.
    nonisolated static func decodeRaster(_ source: CGImageSource, displaySize: CGSize?, scale: CGFloat,
                                         extraBytes: Int) throws(BenchImageFailure) -> MarkdownImage {
        guard let type = CGImageSourceGetType(source) as String? else { throw .corrupt }
        guard rasterTypes.contains(type) else { throw .blocked }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw .corrupt }
        guard width * height <= maxPixels else { throw .tooLarge }
        let rotated = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        let size = rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let factor = min(1, fit(size, in: displaySize) * scale)
        let maxPixelSize = max(1, Int((CGFloat(max(width, height)) * factor).rounded(.up)))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(maxPixelSize)),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw .corrupt }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return MarkdownImage(image: image, size: size) }
        let frames = FrameSource(source, maxPixelSize: maxPixelSize)
        return MarkdownImage(image: image, size: size, frameDelays: (0..<count).map { delay(source, at: $0) },
                             byteCount: image.bytesPerRow * image.height + extraBytes,
                             frame: { frames.frame($0) })
    }

    nonisolated static func delay(_ source: CGImageSource, at index: Int) -> TimeInterval {
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

    /// Remote SVG only: AppKit's renderer, rasterized here at the display size.
    nonisolated static func decodeSVG(_ data: Data, displaySize: CGSize?, scale: CGFloat) throws(BenchImageFailure) -> MarkdownImage {
        guard data.range(of: Data("<svg".utf8)) != nil, let svg = NSImage(data: data),
              svg.size.width > 0, svg.size.height > 0 else { throw .corrupt }
        let factor = fit(svg.size, in: displaySize) * scale
        let width = (svg.size.width * factor).rounded(.up), height = (svg.size.height * factor).rounded(.up)
        guard width.isFinite, height.isFinite, width * height <= CGFloat(maxPixels) else { throw .tooLarge }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: max(1, Int(width)), height: max(1, Int(height)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw .corrupt }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        svg.draw(in: CGRect(x: 0, y: 0, width: context.width, height: context.height),
                 from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.current = previous
        guard let image = context.makeImage() else { throw .corrupt }
        return MarkdownImage(image: image, size: svg.size)
    }
}

/// An animated image's source, decoding one frame at a time under a lock.
private final class FrameSource: @unchecked Sendable {
    private let source: CGImageSource
    private let maxPixelSize: Int
    private let lock = NSLock()

    init(_ source: CGImageSource, maxPixelSize: Int) {
        self.source = source
        self.maxPixelSize = maxPixelSize
    }

    func frame(_ index: Int) -> CGImage? {
        lock.withLock {
            CGImageSourceCreateThumbnailAtIndex(source, index, BenchImageProvider.thumbnailOptions(maxPixelSize))
        }
    }
}

// MARK: Self-check

/// `run --verify-images`: loads every image reference of the generated manifest through the
/// provider and compares the outcome with its `expected`, plus the natural size of each `ok`
/// image, the frame count of animated files and downsampling to a smaller display size.
@MainActor
enum ImageVerification {
    static func run(manifest url: URL, latencyMs: Double) async throws -> Bool {
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let images = json["images"] as? [String: Any],
              let references = images["references"] as? [[String: Any]] else {
            throw BenchError.unavailable("\(url.path) has no images section; run generate")
        }
        let rootValue = json["root"] as? String ?? "."
        let root = rootValue.hasPrefix("/") ? URL(fileURLWithPath: rootValue)
            : url.deletingLastPathComponent().appendingPathComponent(rootValue).standardizedFileURL
        let frames = Dictionary((images["files"] as? [[String: Any]] ?? []).compactMap { file -> (String, Int)? in
            guard let path = file["path"] as? String, let count = file["frames"] as? Int else { return nil }
            return (path, count)
        }, uniquingKeysWith: { first, _ in first })
        let provider = BenchImageProvider(latencyMs: latencyMs, remote: await RemoteFixtures.load(RemoteFixtures.items(in: json), root: root))
        var checked = Set<String>()
        var mismatches: [String] = []
        var outcomes: [String: Int] = [:]
        for reference in references {
            guard let document = reference["document"] as? String, let source = reference["source"] as? String,
                  let expected = reference["expected"] as? String else { continue }
            guard checked.insert(document + "\u{0}" + source).inserted else { continue }
            provider.documentDirectory = root.appendingPathComponent(document).deletingLastPathComponent()
            let result = await load(provider, source, displaySize: nil, scale: 1)
            let outcome: String
            switch result {
            case .success: outcome = "ok"
            case .failure(let error): outcome = (error as? BenchImageFailure)?.rawValue ?? "\(error)"
            }
            outcomes[outcome, default: 0] += 1
            let label = "\(document): \(source.prefix(80))"
            guard outcome == expected else {
                mismatches.append("\(label): expected \(expected), got \(outcome)")
                continue
            }
            guard case .success(let image) = result else { continue }
            if let width = reference["width"] as? Int, let height = reference["height"] as? Int,
               image.size != CGSize(width: width, height: height) {
                mismatches.append("\(label): size \(image.size), manifest \(width) x \(height)")
            }
            if let path = reference["path"] as? String, let count = frames[path], count > 1 {
                if image.frameCount != count || image.frame(at: count - 1) == nil {
                    mismatches.append("\(label): \(image.frameCount) frames, manifest \(count)")
                }
            }
            // Downsampled to half the natural width at scale 1.
            let half = CGSize(width: max(1, image.size.width / 2), height: .infinity)
            if case .success(let small) = await load(provider, source, displaySize: half, scale: 1),
               CGFloat(small.image.width) > ceil(half.width) + 1 {
                mismatches.append("\(label): \(small.image.width) px wide for a \(half.width) pt box at scale 1")
            }
        }
        print("verify-images: \(checked.count) references from \(url.path), remote fixtures \(provider.remote.count), "
              + outcomes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        for line in mismatches { print("  mismatch: \(line)") }
        print(mismatches.isEmpty ? "verify-images: all outcomes as expected" : "verify-images: \(mismatches.count) mismatches")
        return mismatches.isEmpty
    }

    private static func load(_ provider: BenchImageProvider, _ source: String, displaySize: CGSize?,
                             scale: CGFloat) async -> Result<MarkdownImage, any Error> {
        await withCheckedContinuation { continuation in
            let request = provider.requestImage(source: source, displaySize: displaySize, scale: scale) {
                continuation.resume(returning: $0)
            }
            _ = request
        }
    }
}
