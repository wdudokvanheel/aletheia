import AppKit
import WebKit

/// Serves only trusted bundle files and raster images inside the selected
/// document's canonical directory. Each selection gets a new path capability.
@MainActor
final class PreviewResources: NSObject, WKURLSchemeHandler {
    static let origin = URL(string: "aletheia-preview://bundle/index.html")!
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    var directory: URL?
    var token = UUID().uuidString
    var base: String { "aletheia-preview://document/\(token)/" }

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
            file = mime == nil ? nil : Bundle.module.url(forResource: url.lastPathComponent,
                                                         withExtension: nil, subdirectory: "Preview")
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

@MainActor
private final class PreviewScrollHandler: NSObject, WKScriptMessageHandler {
    weak var owner: MarkdownPreview?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        owner?.receiveScroll(body)
    }
}

@MainActor
final class MarkdownPreview: NSObject, WKNavigationDelegate, MarkdownPreviewing {
    let webView: WKWebView
    var view: NSView { webView }
    var focusView: NSView { webView }
    let resources = PreviewResources()
    private weak var document: EditorDocument?
    private var pending: Task<Void, Never>?
    private(set) var generation = 0
    private(set) var renderCount = 0
    private(set) var ready = false
    private var committedGeneration: Int?
    private var resetScroll = true
    private var searchQuery = ""
    private var searchRange: NSRange?
    private var nextFraction: Double?
    /// Replaces the stored offset on the shown document's first render.
    private var carriedFraction: Double?
    private let scrollHandler = PreviewScrollHandler()
    var onOpen: ((URL) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(resources, forURLScheme: "aletheia-preview")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        scrollHandler.owner = self
        configuration.userContentController.add(scrollHandler, name: "previewScroll")
        webView.navigationDelegate = self
        webView.allowsLinkPreview = false
        webView.load(URLRequest(url: PreviewResources.origin))
    }

    func receiveScroll(_ body: [String: Any]) {
        guard let token = body["token"] as? String, token == resources.token,
              let value = body["generation"] as? Int,
              value == generation || value == committedGeneration,
              let x = body["x"] as? Double, let y = body["y"] as? Double,
              x.isFinite, y.isFinite, let document else { return }
        document.previewPosition = EditorDocument.validPosition(CGPoint(x: x, y: y))
    }

    func show(_ document: EditorDocument?) {
        let changed = self.document !== document || document == nil
        self.document = document
        if changed {
            searchQuery = ""
            searchRange = nil
            committedGeneration = nil
            resources.directory = document?.file.url.deletingLastPathComponent()
            resources.token = UUID().uuidString
            resetScroll = true
            carriedFraction = document == nil ? nil : nextFraction
            nextFraction = nil
        }
        schedule(clear: changed, immediately: true)
    }

    func applyTheme() {
        let palette = AppSettings.shared.palette
        webView.underPageBackgroundColor = palette.background
        guard ready else { return }
        func css(_ color: NSColor) -> String {
            let rgb = color.usingColorSpace(.sRGB) ?? color
            return "rgb(\(Int(rgb.redComponent * 255)), \(Int(rgb.greenComponent * 255)), \(Int(rgb.blueComponent * 255)))"
        }
        let colors: [String: String] = palette.isDark == nil ? [:] : [
            "--background": css(palette.background), "--foreground": css(palette.foreground),
            "--surface": css(palette.surface), "--muted": css(palette.muted), "--accent": css(palette.accent)
        ]
        webView.callAsyncJavaScript("""
            const style = document.documentElement.style;
            for (const key of ['--background', '--foreground', '--surface', '--muted', '--accent']) {
                if (colors[key]) style.setProperty(key, colors[key]); else style.removeProperty(key);
            }
            style.colorScheme = scheme;
            """, arguments: ["colors": colors, "scheme": palette.isDark.map { $0 ? "dark" : "light" } ?? "light dark"],
            in: nil, in: .page) { _ in }
    }

    /// The native source search owns matching; JavaScript receives UTF-16 offsets.
    func setSearch(query: String, sourceRange: NSRange?) {
        if document != nil, !query.isEmpty, let sourceRange,
           sourceRange.location != NSNotFound, sourceRange.length > 0 {
            searchQuery = query
            searchRange = sourceRange
        } else {
            searchQuery = ""
            searchRange = nil
        }
        sendSearch()
    }

    private func sendSearch() {
        guard ready else { return }
        let range: Any = searchRange.map { ["location": $0.location, "length": $0.length] as Any } ?? NSNull()
        webView.callAsyncJavaScript("setPreviewSearch(query, range, token, value)",
            arguments: ["query": searchQuery, "range": range,
                        "token": resources.token, "value": generation], in: nil, in: .page) { _ in }
    }

    func contentChanged() { schedule(clear: false) }

    /// WebKit content is released by the window's occlusion handling instead.
    func setVisible(_ visible: Bool) {}

    func prepareForRelease() { webView.stopLoading() }

    func scrollFraction() async -> Double? {
        guard ready, document != nil, committedGeneration != nil,
              let values = try? await webView.callAsyncJavaScript(
                  "return [window.scrollY, document.documentElement.scrollHeight]",
                  arguments: [:], in: nil, contentWorld: .page) as? [Double],
              values.count == 2, values[0].isFinite, values[1].isFinite, values[1] > 0 else { return nil }
        return min(max(values[0] / values[1], 0), 1)
    }

    func setScrollFraction(_ fraction: Double) { nextFraction = fraction }

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
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            guard let self, !Task.isCancelled, value == self.generation,
                  let document = self.document else { return }
            do {
                // Copy the unsaved buffer only after the debounce, never on every key.
                self.renderCount += 1
                let source = document.editor.string
                let html = try await self.webView.callAsyncJavaScript(
                    "return renderMarkdown(markdown, base)",
                    arguments: ["markdown": source, "base": self.resources.base],
                    in: nil, contentWorld: .page)
                guard !Task.isCancelled, value == self.generation, self.document === document,
                      let html = html as? String else { return }
                _ = try await self.webView.callAsyncJavaScript(
                    "return commitPreview(html, value, reset, token, position, source)",
                    arguments: ["html": html, "source": source, "value": value, "reset": self.resetScroll,
                                "token": self.resources.token,
                                "position": ["x": document.previewPosition.x, "y": document.previewPosition.y,
                                             "fraction": self.carriedFraction.map { $0 as Any } ?? NSNull()]],
                    in: nil, contentWorld: .page)
                if value == self.generation {
                    self.committedGeneration = value
                    self.resetScroll = false
                    self.carriedFraction = nil
                }
            } catch {
                guard value == self.generation else { return }
                // Keep the editor usable and make a renderer failure visible.
                _ = try? await self.webView.callAsyncJavaScript(
                    "document.getElementById('content').textContent = message",
                    arguments: ["message": "Markdown preview unavailable: \(error.localizedDescription)"],
                    in: nil, contentWorld: .page)
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        ready = false
        pending?.cancel()
        committedGeneration = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
        decisionHandler(.cancel)
        guard action.navigationType == .linkActivated else { return }
        if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        } else if let local = resources.localURL(url) {
            onOpen?(local)
        }
    }
}
