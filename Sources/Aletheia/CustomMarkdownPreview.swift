import AppKit
import MarkdownView

/// The experimental Core Text renderer from the MarkdownView package. Unlike
/// WebKit it stays alive in hidden windows: it keeps its snapshot and pauses.
@MainActor
final class CustomMarkdownPreview: NSObject, MarkdownPreviewing {
    let preview = MarkdownPreviewView(frame: .zero)
    var view: NSView { preview }
    var focusView: NSView { preview.documentView ?? preview }
    var onOpen: ((URL) -> Void)?
    /// Opens web and mail links; replaced in tests.
    var openInSystem: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private weak var document: EditorDocument?
    /// The buffer changed since it was last pushed.
    private var stale = false
    private var visible = true
    private var nextFraction: Double?
    /// From showing a document until its complete snapshot installs, scroll
    /// positions belong to the old content and are not recorded.
    private var restoring = false
    /// The diagnostics overlay: the last update's phase times.
    let timingsLabel = NSTextField(labelWithString: "")

    override init() {
        super.init()
        preview.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: preview.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(updateTimingsOverlay),
            name: AppSettings.previewTimingsDidChange, object: nil)
        preview.onTimings = { [weak self] _ in self?.updateTimingsOverlay() }
        preview.onInstall = { [weak self] snapshot in self?.didInstall(snapshot) }
        preview.onOpenLink = { [weak self] destination in self?.openLink(destination) }
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
        self.document = document
        guard let document else {
            nextFraction = nil
            restoring = false
            stale = false
            preview.clearSelection()
            preview.setSource("")
            return
        }
        guard changed || stale else { return }
        stale = false
        preview.setSource(document.editor.string)
        guard changed else { return }
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
    }

    func applyTheme() {
        let palette = AppSettings.shared.palette
        // The System scheme follows the view's appearance with dynamic colors.
        preview.palette = palette.isDark == nil ? .standard : Palette(
            background: palette.background, text: palette.foreground, headingText: palette.foreground,
            codeText: palette.foreground, codeBackground: palette.surface, mutedText: palette.muted,
            link: palette.accent)
    }

    /// Find in the preview arrives in Phase 8.
    func setSearch(query: String, sourceRange: NSRange?) {}

    func setVisible(_ visible: Bool) {
        self.visible = visible
        preview.setVisible(visible)
        pushIfStale()
    }

    func prepareForRelease() {
        document = nil
        preview.setSource("")
    }

    func scrollFraction() async -> Double? {
        guard document != nil, !restoring else { return nil }
        return preview.scrollFraction
    }

    func setScrollFraction(_ fraction: Double) { nextFraction = fraction }

    /// The library applies the position set in `show(_:)` on the shown
    /// document's complete snapshot, before this runs and before it draws.
    private func didInstall(_ snapshot: MarkdownSnapshot) {
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
