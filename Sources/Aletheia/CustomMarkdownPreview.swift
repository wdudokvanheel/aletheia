import AppKit
import MarkdownView

/// The experimental Core Text renderer from the MarkdownView package. Unlike
/// WebKit it stays alive in hidden windows: it keeps its snapshot and pauses.
///
/// It also keeps each document's last snapshot while another document is
/// shown and hands it back when that document is shown again, so its
/// unchanged blocks keep their layouts instead of starting cold.
///
/// It is the view's image provider: `PreviewImageLoader` loads images
/// relative to the shown document's folder under `PreviewFilePolicy`, and
/// HTTPS images under its remote rules. Fenced code is highlighted by
/// `PreviewCodeHighlighter` in the scheme's syntax colors.
@MainActor
final class CustomMarkdownPreview: NSObject, MarkdownPreviewing, MarkdownImageProvider {
    let preview = MarkdownPreviewView(frame: .zero)
    var view: NSView { preview }
    var focusView: NSView { preview.documentView ?? preview }
    var onOpen: ((URL) -> Void)?
    /// Opens web and mail links; replaced in tests.
    var openInSystem: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Loads the preview's images; shared by every window.
    private let imageLoader: PreviewImageLoader
    private weak var document: EditorDocument?
    /// The buffer changed since it was last pushed.
    private var stale = false
    /// The find bar's query and current match in the shown buffer, as the
    /// WebKit preview keeps them.
    private var searchQuery = ""
    private var searchRange: NSRange?
    private var visible = true
    private var nextFraction: Double?
    /// From showing a document until its complete snapshot installs, scroll
    /// positions belong to the old content and are not recorded.
    private var restoring = false
    /// The diagnostics overlay: the last update's phase times.
    let timingsLabel = NSTextField(labelWithString: "")
    /// The last snapshot of each document not shown, weakly keyed by the
    /// document: entries of documents that are gone are dropped on the next
    /// `show(_:)`.
    private var kept: [ObjectIdentifier: KeptSnapshot] = [:]
    /// The document the installed snapshot shows.
    private weak var installedDocument: EditorDocument?

    private struct KeptSnapshot {
        weak var document: EditorDocument?
        let snapshot: MarkdownSnapshot
    }

    /// Documents with a kept snapshot; for tests.
    var keptSnapshotCount: Int { kept.count }

    init(imageLoader: PreviewImageLoader = .shared) {
        self.imageLoader = imageLoader
        super.init()
        preview.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: preview.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(updateTimingsOverlay),
            name: AppSettings.previewTimingsDidChange, object: nil)
        preview.onTimings = { [weak self] _ in self?.updateTimingsOverlay() }
        preview.onInstall = { [weak self] snapshot in self?.didInstall(snapshot) }
        preview.onOpenLink = { [weak self] destination in self?.openLink(destination) }
        preview.codeHighlighter = PreviewCodeHighlighter()
        timingsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timingsLabel.textColor = .white
        timingsLabel.drawsBackground = true
        timingsLabel.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        timingsLabel.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(timingsLabel)
        NSLayoutConstraint.activate([
            timingsLabel.topAnchor.constraint(equalTo: preview.topAnchor, constant: 8),
            timingsLabel.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -20)
        ])
        applyTheme()
        updateTimingsOverlay()
    }

    func show(_ document: EditorDocument?) {
        let changed = self.document !== document || document == nil
        if changed { keepSnapshot() }
        self.document = document
        preview.imageProvider = self
        if changed {
            searchQuery = ""
            searchRange = nil
        }
        guard let document else {
            nextFraction = nil
            restoring = false
            stale = false
            preview.clearSearch()
            preview.setSource("")
            return
        }
        guard changed || stale else { return }
        stale = false
        guard changed else {
            preview.setSource(document.editor.string)
            sendSearch()
            return
        }
        let reusable = kept.removeValue(forKey: ObjectIdentifier(document)).flatMap {
            $0.document === document ? $0.snapshot : nil
        }
        preview.setSource(document.editor.string, reusing: reusable)
        preview.clearSelection()
        restoring = true
        // Set after the source, so it applies to that source's snapshot.
        if let fraction = nextFraction {
            nextFraction = nil
            preview.scrollFraction = fraction
        } else {
            preview.setScrollOffset(document.previewPosition.y)
        }
    }

    /// No debounce, unlike WebKit: every change goes to the view at once.
    /// The view runs one update at a time and coalesces sources set
    /// meanwhile, pausing after slow updates, so copying the buffer is the
    /// only work per keystroke here.
    func contentChanged() {
        guard document != nil else { return }
        stale = true
        pushIfStale()
    }

    /// Hidden previews stay stale until shown, so they copy nothing.
    private func pushIfStale() {
        guard visible, stale, let document else { return }
        stale = false
        preview.setSource(document.editor.string)
        sendSearch()
    }

    /// Code blocks take the scheme's syntax colors, as files in the editor do.
    func applyTheme() {
        let scheme = AppSettings.shared.selectedScheme
        let colors = scheme.palette
        // The System scheme follows the view's appearance with dynamic colors.
        var palette = colors.isDark == nil ? Palette.standard : Palette(
            background: colors.background, text: colors.foreground, headingText: colors.foreground,
            codeText: colors.foreground, codeBackground: colors.surface, mutedText: colors.muted,
            link: colors.accent)
        let syntax = scheme.syntaxPalette
        palette.codeComment = syntax.comment
        palette.codeString = syntax.string
        palette.codeKeyword = syntax.keyword
        palette.codeNumber = syntax.number
        palette.codeName = syntax.name
        palette.codeProperty = syntax.property
        palette.codeMarkup = syntax.markup
        palette.codeInvalid = syntax.invalid
        preview.palette = palette
    }

    /// The find bar matches in the source buffer and passes its query and
    /// current match here, as UTF-16 offsets, as it does to WebKit: the view
    /// selects the match where it is displayed and centers it.
    func setSearch(query: String, sourceRange: NSRange?) {
        let hadSearch = searchRange != nil
        if document != nil, !query.isEmpty, let sourceRange,
           sourceRange.location != NSNotFound, sourceRange.length > 0 {
            searchQuery = query
            searchRange = sourceRange
            sendSearch()
        } else {
            searchQuery = ""
            searchRange = nil
            // Without a search the selection is the user's, kept across updates.
            if hadSearch { preview.clearSearch() }
        }
    }

    /// Reveals the match in the source the view was last given, like the
    /// WebKit preview after each render: again after every change while it
    /// is still the query there, and otherwise only clearing the selection
    /// until the find bar sends the new match. A stale (hidden) preview
    /// waits until it pushes the buffer.
    private func sendSearch() {
        guard let range = searchRange, !stale, let text = document?.editor.textStorage?.mutableString else { return }
        if NSMaxRange(range) <= text.length, text.substring(with: range) == searchQuery {
            preview.reveal(sourceRange: range)
        } else {
            preview.clearSearch()
        }
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        preview.setVisible(visible)
        pushIfStale()
    }

    func prepareForRelease() {
        document = nil
        preview.setSource("")
        release(kept.values.map(\.snapshot))
        kept.removeAll()
    }

    /// Keeps the snapshot of the document being replaced, if the installed
    /// snapshot shows it, and drops those of documents that are gone.
    private func keepSnapshot() {
        let gone = kept.filter { $0.value.document == nil }
        for key in gone.keys { kept[key] = nil }
        release(gone.values.map(\.snapshot))
        guard let outgoing = document, installedDocument === outgoing else { return }
        kept[ObjectIdentifier(outgoing)] = KeptSnapshot(document: outgoing, snapshot: preview.snapshot)
    }

    /// Frees snapshots on a background queue, so their layouts never cost
    /// main-thread time.
    private func release(_ snapshots: [MarkdownSnapshot]) {
        guard !snapshots.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { withExtendedLifetime(snapshots) {} }
    }

    func scrollFraction() async -> Double? {
        guard document != nil, !restoring else { return nil }
        return preview.scrollFraction
    }

    func setScrollFraction(_ fraction: Double) { nextFraction = fraction }

    /// The library applies the position set in `show(_:)` on the shown
    /// document's complete snapshot, before this runs and before it draws.
    private func didInstall(_ snapshot: MarkdownSnapshot) {
        // After `show(_:)`, only the shown document's sources install.
        installedDocument = document
        guard restoring, snapshot.isComplete else { return }
        restoring = false
        recordPosition()
    }

    @objc private func boundsChanged() {
        guard !restoring else { return }
        recordPosition()
    }

    private func recordPosition() {
        document?.previewPosition = EditorDocument.validPosition(preview.contentView.bounds.origin)
    }

    /// Loads an image of the shown document. The loader resolves relative
    /// sources against its folder, refusing what `PreviewFilePolicy` refuses,
    /// and loads only HTTPS remotely; its errors pass through.
    func requestImage(source: String, displaySize: CGSize?, scale: CGFloat,
                      completion: @escaping @MainActor (Result<MarkdownImage, any Error>) -> Void)
        -> MarkdownImageRequest? {
        let directory = document?.file.url.deletingLastPathComponent()
        let task = imageLoader.image(for: source, relativeTo: directory, displaySize: displaySize,
                                     scale: scale) { (result: Result<PreviewImage, PreviewImageError>) in
            switch result {
            case .success(let image): completion(.success(Self.markdownImage(image)))
            case .failure(let error): completion(.failure(error))
            }
        }
        guard let task else { return nil }
        return MarkdownImageRequest { task.cancel() }
    }

    private nonisolated static func markdownImage(_ image: PreviewImage) -> MarkdownImage {
        guard image.frameCount > 1 else { return MarkdownImage(image: image.image, size: image.size, byteCount: image.cost) }
        return MarkdownImage(image: image.image, size: image.size, frameDelays: image.frameDelays, byteCount: image.cost,
                             frame: { @Sendable index in image.frame(at: index) })
    }

    /// The WebKit preview's click rules, through the same shared function.
    private func openLink(_ destination: String) {
        guard let document else { return }
        switch PreviewLink.action(forDestination: destination, directory: document.file.url.deletingLastPathComponent()) {
        case .system(let url): openInSystem(url)
        case .editor(let file): onOpen?(file)
        case nil: break
        }
    }

    @objc private func updateTimingsOverlay() {
        timingsLabel.isHidden = !AppSettings.shared.showsPreviewTimings
        guard !timingsLabel.isHidden else { return }
        guard let last = preview.lastTimings else { timingsLabel.stringValue = " waiting for an update "; return }
        func ms(_ duration: Duration) -> String {
            let (seconds, attoseconds) = duration.components
            return String(format: "%.1f", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
        }
        timingsLabel.stringValue = " parse \(ms(last.parse))  layout \(ms(last.layout))  install \(ms(last.install))"
            + "  draw \(ms(last.draw)) ms  \(last.blockCount) blocks, \(last.laidOutBlocks) laid out"
            + "\(last.isComplete ? "" : " (partial)") "
    }
}
