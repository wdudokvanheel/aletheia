import AppKit
import WebKit
import os

// A copy of the app's WebKit preview path (Sources/Aletheia/MarkdownPreview.swift and
// PreviewFilePolicy.swift) with the bundle read from a directory instead of Bundle.module.
// Lines marked "Bench:" only observe; everything else must stay in step with the app.

/// Mirrors `PreviewFilePolicy`.
enum PreviewFilePolicy {
    static func localURL(for relativePath: String, in directory: URL) -> URL? {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path == "/" ? "/" : root.path + "/"),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }

    static func imageType(of file: URL) -> String? {
        ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
         "gif": "image/gif", "webp": "image/webp", "avif": "image/avif"][file.pathExtension.lowercased()]
    }
}

/// Mirrors the app's `PreviewResources` scheme handler.
@MainActor
final class PreviewResources: NSObject, WKURLSchemeHandler {
    static let origin = URL(string: "aletheia-preview://bundle/index.html")!
    let bundleDirectory: URL
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    var directory: URL?
    var token = UUID().uuidString
    var base: String { "aletheia-preview://document/\(token)/" }

    init(bundleDirectory: URL) {
        self.bundleDirectory = bundleDirectory
        super.init()
    }

    func localURL(_ url: URL) -> URL? {
        guard url.scheme == "aletheia-preview", url.host == "document",
              let directory, url.pathComponents.count >= 3,
              url.pathComponents[1] == token else { return nil }
        return PreviewFilePolicy.localURL(for: url.pathComponents.dropFirst(2).joined(separator: "/"), in: directory)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let file: URL?
        let mime: String?
        if url.host == "bundle" {
            let types = ["index.html": "text/html", "preview.css": "text/css",
                         "preview.js": "text/javascript", "marked.umd.js": "text/javascript",
                         "purify.min.js": "text/javascript"]
            mime = types[String(url.path.dropFirst())]
            let candidate = bundleDirectory.appendingPathComponent(url.lastPathComponent)
            file = mime == nil || !FileManager.default.fileExists(atPath: candidate.path) ? nil : candidate
        } else {
            file = localURL(url)
            mime = file.flatMap(PreviewFilePolicy.imageType)
        }
        guard let file, let mime else {
            task.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        let id = ObjectIdentifier(task)
        requests[id] = Task {
            let result = await Task.detached(priority: .userInitiated) {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    return Result<Data, Error>.failure(URLError(.noPermissionsToReadFile))
                }
                return Result { try Data(contentsOf: file) }
            }.value
            guard !Task.isCancelled else { return }
            requests[id] = nil
            switch result {
            case .success(let data):
                task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                    textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
                task.didReceive(data)
                task.didFinish()
            case .failure(let error): task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        requests.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }
}

/// The part of `EditorDocument` the preview reads.
@MainActor
final class BenchDocument {
    let url: URL
    var text: String
    var previewPosition: CGPoint = .zero
    /// Bench: the trace edit `text` holds, reported with the render that showed it.
    var revision = 0

    init(url: URL, text: String) {
        self.url = url
        self.text = text
    }
}

/// Bench: timestamps of one completed render, from `now()`.
struct RenderTiming {
    /// When the render task started work, after any debounce.
    let start: UInt64
    /// When `commitPreview` returned to the app process; the app observes nothing later.
    let committed: UInt64
    /// When the forced layout and the next animation frame finished.
    let rendered: UInt64
    let visibility: String
    /// The document's `revision` when the render copied its text.
    var revision = 0
}

enum BenchError: LocalizedError {
    case timeout, stalled(String), navigation(String), unavailable(String)
    var errorDescription: String? {
        switch self {
        case .timeout: "render timed out"
        case .stalled(let state): "no animation frame (page \(state)); the page must be visible"
        case .navigation(let message): "preview page failed: \(message)"
        case .unavailable(let message): message
        }
    }
}

@MainActor
private final class PreviewScrollHandler: NSObject, WKScriptMessageHandler {
    weak var owner: WebKitPreview?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        owner?.receiveScroll(body)
    }
}

/// Mirrors the app's `MarkdownPreview` with the system palette, plus render observation.
@MainActor
final class WebKitPreview: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let resources: PreviewResources
    private weak var document: BenchDocument?
    private var pending: Task<Void, Never>?
    private(set) var generation = 0
    private(set) var renderCount = 0
    private(set) var ready = false
    private var committedGeneration: Int?
    private var resetScroll = true
    private var searchQuery = ""
    private var searchRange: NSRange?
    private let scrollHandler = PreviewScrollHandler()

    // Bench: observation state.
    private(set) var readyAt: UInt64?
    private var waiter: CheckedContinuation<RenderTiming, Error>?
    private var waiterID = 0
    private var startup: OSSignpostIntervalState?
    /// Bench: every render, whether or not anyone waits; the trace replay logs them all.
    var onRendered: ((RenderTiming) -> Void)?

    /// Bench: forces style and layout, then resolves after the next animation frame's
    /// rendering update (requestAnimationFrame, then a zero timeout).
    private static let frameScript = """
        void document.documentElement.offsetHeight;
        return await new Promise(resolve => {
            const fallback = setTimeout(() => resolve('stalled:' + document.visibilityState), 5000);
            requestAnimationFrame(() => setTimeout(() => { clearTimeout(fallback); resolve(document.visibilityState); }, 0));
        });
        """

    init(resources directory: URL, occlusionDetection: Bool) {
        startup = signposter.beginInterval("startup", id: signposter.makeSignpostID())
        resources = PreviewResources(bundleDirectory: directory)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(resources, forURLScheme: "aletheia-preview")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        // Bench: a transparent window, or any window while the display sleeps, counts as occluded,
        // and WebKit stops animation frames for hidden pages. The app's preview is measured while
        // its window is visible, so this SPI makes WebKit treat the page as visible.
        if !occlusionDetection { Self.setWindowOcclusionDetection(webView, enabled: false) }
        scrollHandler.owner = self
        configuration.userContentController.add(scrollHandler, name: "previewScroll")
        webView.navigationDelegate = self
        webView.allowsLinkPreview = false
        webView.load(URLRequest(url: PreviewResources.origin))
    }

    private static func setWindowOcclusionDetection(_ webView: WKWebView, enabled: Bool) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, enabled)
    }

    func receiveScroll(_ body: [String: Any]) {
        guard let token = body["token"] as? String, token == resources.token,
              let value = body["generation"] as? Int,
              value == generation || value == committedGeneration,
              let x = body["x"] as? Double, let y = body["y"] as? Double,
              x.isFinite, y.isFinite, let document else { return }
        document.previewPosition = CGPoint(x: max(0, x), y: max(0, y))
    }

    func show(_ document: BenchDocument?) {
        let changed = self.document !== document || document == nil
        self.document = document
        if changed {
            searchQuery = ""
            searchRange = nil
            committedGeneration = nil
            resources.directory = document?.url.deletingLastPathComponent()
            resources.token = UUID().uuidString
            resetScroll = true
        }
        schedule(clear: changed, immediately: true)
    }

    /// The app's `applyTheme()` with the default "System" palette.
    func applyTheme() {
        webView.underPageBackgroundColor = .textBackgroundColor
        guard ready else { return }
        let colors: [String: String] = [:]
        webView.callAsyncJavaScript("""
            const style = document.documentElement.style;
            for (const key of ['--background', '--foreground', '--surface', '--muted', '--accent']) {
                if (colors[key]) style.setProperty(key, colors[key]); else style.removeProperty(key);
            }
            style.colorScheme = scheme;
            """, arguments: ["colors": colors, "scheme": "light dark"], in: nil, in: .page) { _ in }
    }

    private func sendSearch() {
        guard ready else { return }
        let range: Any = searchRange.map { ["location": $0.location, "length": $0.length] as Any } ?? NSNull()
        webView.callAsyncJavaScript("setPreviewSearch(query, range, token, value)",
            arguments: ["query": searchQuery, "range": range,
                        "token": resources.token, "value": generation], in: nil, in: .page) { _ in }
    }

    func contentChanged() { schedule(clear: false) }

    func prepareForRelease() { webView.stopLoading() }

    private func schedule(clear: Bool, immediately: Bool = false) {
        generation += 1
        pending?.cancel()
        pending = nil
        let value = generation
        if ready {
            webView.callAsyncJavaScript("invalidatePreview(value, clear)",
                arguments: ["value": value, "clear": clear], in: nil, in: .page) { _ in }
        }
        sendSearch()
        guard document != nil, ready else { return }
        pending = Task { [weak self] in
            if !immediately {
                do {
                    try await interval("debounce") { try await Task.sleep(for: .milliseconds(200)) }
                } catch { return }
            }
            guard let self, !Task.isCancelled, value == self.generation,
                  let document = self.document else { return }
            let start = now() // Bench
            do {
                // Copy the unsaved buffer only after the debounce, never on every key.
                self.renderCount += 1
                let source = document.text
                let revision = document.revision // Bench
                let html = try await interval("renderMarkdown") {
                    try await self.webView.callAsyncJavaScript(
                        "return renderMarkdown(markdown, base)",
                        arguments: ["markdown": source, "base": self.resources.base],
                        in: nil, contentWorld: .page)
                }
                guard !Task.isCancelled, value == self.generation, self.document === document,
                      let html = html as? String else { return }
                _ = try await interval("commitPreview") {
                    try await self.webView.callAsyncJavaScript(
                        "return commitPreview(html, value, reset, token, position, source)",
                        arguments: ["html": html, "source": source, "value": value, "reset": self.resetScroll,
                                    "token": self.resources.token,
                                    "position": ["x": document.previewPosition.x, "y": document.previewPosition.y]],
                        in: nil, contentWorld: .page)
                }
                if value == self.generation {
                    self.committedGeneration = value
                    self.resetScroll = false
                    await self.observeRendered(start: start, revision: revision) // Bench
                }
            } catch {
                guard value == self.generation else { return }
                // Keep the editor usable and make a renderer failure visible.
                _ = try? await self.webView.callAsyncJavaScript(
                    "document.getElementById('content').textContent = message",
                    arguments: ["message": "Markdown preview unavailable: \(error.localizedDescription)"],
                    in: nil, contentWorld: .page)
                self.finish(.failure(error)) // Bench
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        ready = false
        pending?.cancel()
        committedGeneration = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Bench: page startup ends here.
        readyAt = now()
        if let startup { signposter.endInterval("startup", startup) }
        startup = nil
        ready = true
        applyTheme()
        schedule(clear: true, immediately: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url == PreviewResources.origin,
           action.navigationType == .other || action.navigationType == .reload {
            decisionHandler(.allow); return
        }
        // The bench never activates links.
        decisionHandler(.cancel)
    }

    // Bench: failures the app does not handle, reported instead of waiting for the timeout.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(BenchError.navigation(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(BenchError.navigation(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(BenchError.navigation("web content process terminated")))
    }

    // MARK: Bench observation

    private func observeRendered(start: UInt64, revision: Int) async {
        let committed = now()
        let state = await interval("frame") {
            (try? await webView.callAsyncJavaScript(Self.frameScript, in: nil, contentWorld: .page)) as? String
        } ?? "error"
        let timing = RenderTiming(start: start, committed: committed, rendered: now(), visibility: state, revision: revision)
        onRendered?(timing)
        finish(.success(timing))
    }

    /// Scrolls the page so `fraction` of its height is 30% down the viewport; returns the scroll offset.
    func scroll(toFraction fraction: Double) async throws -> Double {
        let y = try await webView.callAsyncJavaScript("""
            window.scrollTo(0, Math.max(0, fraction * document.documentElement.scrollHeight - innerHeight * 0.3));
            return window.scrollY;
            """, arguments: ["fraction": fraction], in: nil, contentWorld: .page)
        return (y as? Double) ?? 0
    }

    /// Waits for the next render of the current generation.
    func nextRender(timeout: Duration) async throws -> RenderTiming {
        waiterID += 1
        let id = waiterID
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, id == self.waiterID else { return }
            self.finish(.failure(BenchError.timeout))
        }
        defer { timer.cancel() }
        let timing = try await withCheckedThrowingContinuation { waiter = $0 }
        if timing.visibility != "visible" { throw BenchError.stalled(timing.visibility) }
        return timing
    }

    private func finish(_ result: Result<RenderTiming, Error>) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(with: result)
    }
}
