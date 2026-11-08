import AppKit
import ImageIO
import Synchronization
import XCTest
@testable import Aletheia

/// Serves canned responses keyed by absolute URL and records every request; never the internet.
private final class ImageStub: URLProtocol {
    struct Route {
        var status = 200
        var type: String? = "image/png"
        var body = Data()
        var sendsLength = true
        var redirect: String?
        var hangs = false
    }

    private struct State {
        var routes: [String: Route] = [:]
        var requests: [String] = []
    }

    private static let state = Mutex(State())
    static var requests: [String] { state.withLock { $0.requests } }
    static func serve(_ url: String, _ route: Route) { state.withLock { $0.routes[url] = route } }
    static func reset() { state.withLock { $0 = State() } }

    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let route = Self.state.withLock { state in
            state.requests.append(url.absoluteString)
            return state.routes[url.absoluteString]
        }
        guard let route else { return client.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)) }
        if route.hangs { return }
        if let redirect = route.redirect, let target = URL(string: redirect) {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": redirect])!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client.urlProtocolDidFinishLoading(self)
            return
        }
        var headers = ["Cache-Control": "no-store"]
        headers["Content-Type"] = route.type
        if route.sendsLength { headers["Content-Length"] = String(route.body.count) }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: route.body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PreviewImageLoaderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        ImageStub.reset()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("doc/sub"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var document: URL { folder.appendingPathComponent("doc") }

    @MainActor private func makeLoader(timeout: TimeInterval = 5,
                                       maxResponseBytes: Int = PreviewImageLoader.maxResponseBytes) -> PreviewImageLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageStub.self]
        return PreviewImageLoader(configuration: configuration, cache: nil, timeout: timeout,
                                  maxResponseBytes: maxResponseBytes)
    }

    @MainActor private func load(_ loader: PreviewImageLoader, _ source: String, directory: URL? = nil,
                                 displaySize: CGSize? = nil) async -> Result<PreviewImage, PreviewImageError> {
        await withCheckedContinuation { continuation in
            loader.image(for: source, relativeTo: directory, displaySize: displaySize, scale: 2) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func failure(_ result: Result<PreviewImage, PreviewImageError>) -> PreviewImageError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    // MARK: Fixtures

    private func bitmap(width: Int, height: Int, red: CGFloat = 1) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: red, green: 0, blue: 1 - red, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func encode(_ frames: [CGImage], type: String, delay: Double? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type as CFString, frames.count, nil)!
        let properties = delay.map {
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: $0]] as CFDictionary
        }
        for frame in frames { CGImageDestinationAddImage(destination, frame, properties) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func png(width: Int = 40, height: Int = 20) -> Data {
        encode([bitmap(width: width, height: height)], type: "public.png")
    }

    /// A valid PNG whose header claims `width` × `height`, without the pixels. ImageIO
    /// ignores a header implausibly large for its file, so trailing padding makes it plausible.
    private func pngHeader(width: UInt32, height: UInt32) -> Data {
        var bytes = [UInt8](png(width: 1, height: 1))
        for (offset, value) in [(16, width), (20, height)] {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        crc = ~crc
        for index in 0..<4 { bytes[29 + index] = UInt8(truncatingIfNeeded: crc >> (24 - 8 * index)) }
        return Data(bytes + [UInt8](repeating: 0, count: 200_000))
    }

    private func write(_ data: Data, _ path: String) throws {
        try data.write(to: folder.appendingPathComponent(path))
    }

    // MARK: Local images

    @MainActor func testLocalImageLoadsDownsampledToDisplaySize() async throws {
        try write(png(width: 400, height: 200), "doc/sub/wide.png")
        let loader = makeLoader()
        for source in ["sub/wide.png", "./sub/wide.png", "sub/../sub/wide.png",
                       document.appendingPathComponent("sub/wide.png").absoluteString,
                       document.resolvingSymlinksInPath().appendingPathComponent("sub/wide.png").absoluteString] {
            let image = try await load(loader, source, directory: document, displaySize: CGSize(width: 100, height: 100))
                .get()
            XCTAssertEqual(image.size, CGSize(width: 400, height: 200), source)
            XCTAssertEqual(image.image.width, 200, source)
            XCTAssertEqual(image.image.height, 100, source)
            XCTAssertEqual(image.frameCount, 1, source)
        }
        let natural = try await load(loader, "sub/wide.png", directory: document).get()
        XCTAssertEqual(natural.image.width, 400)
        XCTAssertTrue(ImageStub.requests.isEmpty)
    }

    @MainActor func testTraversalAndEscapingSymlinksAreBlocked() async throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("outside"),
                                                withIntermediateDirectories: true)
        try write(png(), "outside.png")
        try write(png(), "outside/inner.png")
        try FileManager.default.createSymbolicLink(at: document.appendingPathComponent("escape.png"),
            withDestinationURL: folder.appendingPathComponent("outside.png"))
        try FileManager.default.createSymbolicLink(at: document.appendingPathComponent("linked"),
            withDestinationURL: folder.appendingPathComponent("outside"))
        let loader = makeLoader()
        for source in ["../outside.png", "sub/../../outside.png", "%2E%2E/outside.png", "escape.png",
                       "linked/inner.png", folder.appendingPathComponent("outside.png").path,
                       folder.appendingPathComponent("outside.png").absoluteString,
                       document.appendingPathComponent("../outside.png").absoluteString] {
            let result = await load(loader, source, directory: document)
            XCTAssertEqual(failure(result), .blocked, source)
        }
        try write(png(), "doc/inside.png")
        let withoutFolder = await load(loader, "inside.png")
        XCTAssertEqual(failure(withoutFolder), .blocked)
        let missing = await load(loader, "missing.png", directory: document)
        XCTAssertEqual(failure(missing), .notFound)
    }

    @MainActor func testNonImageLocalFilesAreRefused() async throws {
        try Data("secret".utf8).write(to: document.appendingPathComponent("notes.txt"))
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8).write(to: document.appendingPathComponent("logo.svg"))
        try write(encode([bitmap(width: 2, height: 2)], type: "public.tiff"), "doc/tiff.png")
        try FileManager.default.createSymbolicLink(at: document.appendingPathComponent("notes.png"),
            withDestinationURL: document.appendingPathComponent("notes.txt"))
        let loader = makeLoader()
        for source in ["notes.txt", "logo.svg", "tiff.png", "notes.png"] {
            let result = await load(loader, source, directory: document)
            XCTAssertEqual(failure(result), .badType, source)
        }
    }

    @MainActor func testHugePixelSizeIsTooLargeWithoutDecoding() async throws {
        try write(pngHeader(width: 10_000, height: 10_000), "doc/huge.png")
        let loader = makeLoader()
        let result = await load(loader, "huge.png", directory: document, displaySize: CGSize(width: 100, height: 100))
        XCTAssertEqual(failure(result), .tooLarge)
    }

    // MARK: Remote images

    @MainActor func testHTTPSImageLoads() async throws {
        ImageStub.serve("https://img.test/a.png", .init(body: png(width: 40, height: 20)))
        let image = try await load(makeLoader(), "https://img.test/a.png").get()
        XCTAssertEqual(image.size, CGSize(width: 40, height: 20))
        XCTAssertEqual(image.image.width, 40)
        XCTAssertEqual(ImageStub.requests, ["https://img.test/a.png"])
    }

    @MainActor func testOtherSchemesAreRejectedWithoutARequest() async throws {
        ImageStub.serve("http://img.test/a.png", .init(body: png()))
        let base64 = png().base64EncodedString()
        let loader = makeLoader()
        for source in ["http://img.test/a.png", "HTTP://img.test/a.png", "//img.test/a.png",
                       "data:image/png;base64,\(base64)", "ftp://img.test/a.png", "javascript:alert(1)",
                       "https://user:secret@img.test/a.png", "aletheia-preview://bundle/preview.js"] {
            let result = await load(loader, source, directory: document)
            XCTAssertEqual(failure(result), .blocked, source)
        }
        XCTAssertTrue(ImageStub.requests.isEmpty)
    }

    @MainActor func testRedirectsFollowOnlyHTTPS() async throws {
        ImageStub.serve("https://img.test/moved.png", .init(redirect: "https://cdn.test/a.png"))
        ImageStub.serve("https://cdn.test/a.png", .init(body: png()))
        ImageStub.serve("https://img.test/downgrade.png", .init(redirect: "http://cdn.test/a.png"))
        ImageStub.serve("http://cdn.test/a.png", .init(body: png()))
        let loader = makeLoader()
        _ = try await load(loader, "https://img.test/moved.png").get()
        let downgrade = await load(loader, "https://img.test/downgrade.png")
        XCTAssertEqual(failure(downgrade), .blocked)
        XCTAssertEqual(ImageStub.requests, ["https://img.test/moved.png", "https://cdn.test/a.png",
                                            "https://img.test/downgrade.png"])
    }

    @MainActor func testWrongContentTypeIsRejected() async throws {
        ImageStub.serve("https://img.test/page", .init(type: "text/html", body: png()))
        ImageStub.serve("https://img.test/none", .init(type: nil, body: Data("<html><body>hi</body></html>".utf8)))
        ImageStub.serve("https://img.test/sniffed", .init(type: nil, body: png()))
        ImageStub.serve("https://img.test/tiff", .init(type: "image/png",
                                                       body: encode([bitmap(width: 2, height: 2)], type: "public.tiff")))
        let loader = makeLoader()
        for source in ["https://img.test/page", "https://img.test/none", "https://img.test/tiff"] {
            let result = await load(loader, source)
            XCTAssertEqual(failure(result), .badType, source)
        }
        // Without a Content-Type header, the URL loading system's sniffed type decides.
        _ = try await load(loader, "https://img.test/sniffed").get()
    }

    @MainActor func testOversizedResponseIsRejectedWhileStreaming() async throws {
        let body = Data(repeating: 0, count: 4096)
        ImageStub.serve("https://img.test/declared.png", .init(body: body))
        ImageStub.serve("https://img.test/streamed.png", .init(body: body, sendsLength: false))
        ImageStub.serve("https://img.test/fits.png", .init(body: png()))
        let loader = makeLoader(maxResponseBytes: 1024)
        for source in ["https://img.test/declared.png", "https://img.test/streamed.png"] {
            let result = await load(loader, source)
            XCTAssertEqual(failure(result), .tooLarge, source)
        }
        _ = try await load(loader, "https://img.test/fits.png").get()
    }

    @MainActor func testSlowResponseTimesOut() async throws {
        ImageStub.serve("https://img.test/slow.png", .init(hangs: true))
        let started = Date()
        let result = await load(makeLoader(timeout: 0.5), "https://img.test/slow.png")
        XCTAssertEqual(failure(result), .network(.timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    @MainActor func testServerErrorsFail() async throws {
        ImageStub.serve("https://img.test/error.png", .init(status: 500, body: png()))
        ImageStub.serve("https://img.test/gone.png", .init(status: 404, type: "text/html"))
        let loader = makeLoader()
        let error = await load(loader, "https://img.test/error.png")
        XCTAssertEqual(failure(error), .network(.badServerResponse))
        let gone = await load(loader, "https://img.test/gone.png")
        XCTAssertEqual(failure(gone), .notFound)
        let unknownHost = await load(loader, "https://nowhere.test/a.png")
        XCTAssertEqual(failure(unknownHost), .network(.cannotFindHost))
    }

    @MainActor func testSVGDecodesWithoutExternalRequests() async throws {
        let svg = """
            <?xml version="1.0" encoding="UTF-8"?>
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="90" height="20">
              <style>@import url("https://evil.test/style.css"); rect { fill: url("https://evil.test/p.svg#p") }</style>
              <rect width="90" height="20" style="fill:#ff0000"/>
              <image href="https://evil.test/tracker.png" xlink:href="https://evil.test/tracker2.png" width="10" height="10"/>
              <use href="https://evil.test/sprite.svg#icon"/>
            </svg>
            """
        ImageStub.serve("https://img.shields.test/badge", .init(type: "image/svg+xml", body: Data(svg.utf8)))
        // Registered process-wide too, so a load by the SVG renderer itself would be recorded.
        URLProtocol.registerClass(ImageStub.self)
        defer { URLProtocol.unregisterClass(ImageStub.self) }
        let image = try await load(makeLoader(), "https://img.shields.test/badge").get()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(ImageStub.requests, ["https://img.shields.test/badge"])
        XCTAssertEqual(image.size, CGSize(width: 90, height: 20))
        XCTAssertEqual(image.image.width, 180)
        XCTAssertEqual(image.image.height, 40)
        let pixel = NSBitmapImageRep(cgImage: image.image).colorAt(x: 170, y: 2) // components as stored, sRGB
        XCTAssertEqual(pixel?.redComponent ?? 0, 1, accuracy: 0.05)
        XCTAssertEqual(pixel?.greenComponent ?? 1, 0, accuracy: 0.05)
    }

    @MainActor func testAnimatedGIFReportsFrames() async throws {
        let frames = [bitmap(width: 8, height: 8, red: 1), bitmap(width: 8, height: 8, red: 0.5),
                      bitmap(width: 8, height: 8, red: 0)]
        ImageStub.serve("https://img.test/spin.gif", .init(type: "image/gif",
                                                           body: encode(frames, type: "com.compuserve.gif", delay: 0.05)))
        let image = try await load(makeLoader(), "https://img.test/spin.gif").get()
        XCTAssertEqual(image.frameCount, 3)
        XCTAssertEqual(image.frameDelays.count, 3)
        XCTAssertEqual(image.frameDelays[1], 0.05, accuracy: 0.001)
        XCTAssertEqual(image.frame(at: 2)?.width, 8)
        XCTAssertNil(image.frame(at: 3))
    }

    @MainActor func testCorruptDataFailsToDecode() async throws {
        ImageStub.serve("https://img.test/garbage.png", .init(body: Data("not an image".utf8)))
        ImageStub.serve("https://img.test/truncated.png", .init(body: png(width: 64, height: 64).prefix(40)))
        ImageStub.serve("https://img.test/broken.svg", .init(type: "image/svg+xml", body: Data("<svg <<".utf8)))
        try write(Data("not an image".utf8), "doc/fake.png")
        let loader = makeLoader()
        for source in ["https://img.test/garbage.png", "https://img.test/truncated.png",
                       "https://img.test/broken.svg", "fake.png"] {
            let result = await load(loader, source, directory: document)
            XCTAssertEqual(failure(result), .decode, source)
        }
    }

    @MainActor func testCacheHitCompletesImmediatelyWithoutASecondRequest() async throws {
        ImageStub.serve("https://img.test/a.png", .init(body: png()))
        let loader = makeLoader()
        let size = CGSize(width: 20, height: 20)
        let first = try await load(loader, "https://img.test/a.png", displaySize: size).get()
        var hit: PreviewImage?
        let task = loader.image(for: "https://img.test/a.png", relativeTo: nil, displaySize: size, scale: 2) {
            hit = try? $0.get()
        }
        XCTAssertNil(task)
        XCTAssertTrue(hit === first)
        _ = try await load(loader, "https://img.test/a.png", displaySize: CGSize(width: 10, height: 10)).get()
        XCTAssertEqual(ImageStub.requests.count, 2)
    }

    @MainActor func testCancelledLoadNeverCompletes() async throws {
        ImageStub.serve("https://img.test/slow.png", .init(hangs: true))
        var completed = false
        let task = makeLoader().image(for: "https://img.test/slow.png", relativeTo: nil, displaySize: nil,
                                      scale: 2) { _ in completed = true }
        try await Task.sleep(for: .milliseconds(100))
        task?.cancel()
        await task?.value
        XCTAssertFalse(completed)
    }

    @MainActor func testSessionSendsNoCookiesOrCredentials() {
        let configuration = makeLoader(timeout: 7).session.configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 7)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 7)
        XCTAssertEqual(PreviewImageLoader.timeout, 15)
        XCTAssertEqual(PreviewImageLoader.maxResponseBytes, 10 * 1024 * 1024)
    }
}
