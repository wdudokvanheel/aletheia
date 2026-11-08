import AppKit
import MarkdownView

/// The experimental Core Text renderer from the MarkdownView package. Unlike
/// WebKit it stays alive in hidden windows: it keeps its snapshot and pauses.
@MainActor
final class CustomMarkdownPreview: NSObject, MarkdownPreviewing {
    let preview = MarkdownPreviewView(frame: .zero)
    var view: NSView { preview }
    var focusView: NSView { preview.documentView ?? preview }
    /// Links arrive in Phase 3.
    var onOpen: ((URL) -> Void)?
    private weak var document: EditorDocument?
    private var pending: Task<Void, Never>?
    /// The buffer changed since it was last pushed.
    private var stale = false
    private var visible = true
    private var nextFraction: Double?
    /// The installed snapshot's generation when the document was shown. Until
    /// another snapshot installs, scroll positions belong to the old content.
    private var awaitingGeneration: UInt64?
    /// The stored offset to apply once the shown document has installed.
    private var restoreY: CGFloat?
    /// The diagnostics overlay: the last update's phase times.
    let timingsLabel = NSTextField(labelWithString: "")

    override init() {
        super.init()
        preview.contentView.postsBoundsChangedNotifications = true
        preview.documentView?.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: preview.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged),
            name: NSView.frameDidChangeNotification, object: preview.documentView)
        NotificationCenter.default.addObserver(self, selector: #selector(updateTimingsOverlay),
            name: AppSettings.previewTimingsDidChange, object: nil)
        preview.onTimings = { [weak self] _ in
            guard let self else { return }
            _ = self.settle()
            self.updateTimingsOverlay()
        }
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
        pending?.cancel()
        pending = nil
        guard let document else {
            nextFraction = nil
            awaitingGeneration = nil
            restoreY = nil
            stale = false
            preview.setSource("")
            return
        }
        guard changed || stale else { return }
        stale = false
        let installed = preview.snapshot.generation
        preview.setSource(document.editor.string)
        guard changed else { return }
        awaitingGeneration = installed
        restoreY = nil
        // Set after the source, so it waits for that source's snapshot.
        if let fraction = nextFraction {
            nextFraction = nil
            preview.scrollFraction = fraction
        } else {
            let y = document.previewPosition.y
            let height = preview.documentView?.frame.height ?? 0
            restoreY = y > 0 ? y : nil
            // The library takes fractions only. This is exact when the new height
            // matches the old one; otherwise `settle` corrects it on install.
            preview.scrollFraction = y <= 0 ? 0 : height > 0 ? Double(y / height) : 1
        }
    }

    /// Mirrors WebKit: copy the buffer only after the 200 ms editing debounce.
    func contentChanged() {
        guard document != nil else { return }
        stale = true
        pending?.cancel()
        pending = nil
        guard visible else { return }
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.pushIfStale()
        }
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
            codeText: palette.foreground, codeBackground: palette.surface, mutedText: palette.muted)
    }

    /// Find in the preview arrives in Phase 8.
    func setSearch(query: String, sourceRange: NSRange?) {}

    func setVisible(_ visible: Bool) {
        self.visible = visible
        preview.setVisible(visible)
        if pending == nil { pushIfStale() }
    }

    func prepareForRelease() {
        pending?.cancel()
        pending = nil
        document = nil
        preview.setSource("")
    }

    func scrollFraction() async -> Double? {
        guard document != nil, restoreY == nil else { return nil }
        return preview.scrollFraction
    }

    func setScrollFraction(_ fraction: Double) { nextFraction = fraction }

    /// Returns whether the shown document has installed, applying its stored
    /// offset the first time. Install changes the document frame and clip
    /// bounds before it draws, so this runs before the first frame is shown.
    private func settle() -> Bool {
        guard let awaiting = awaitingGeneration else { return true }
        guard preview.snapshot.generation != awaiting else { return false }
        awaitingGeneration = nil
        let y = restoreY
        restoreY = nil
        if let y, let height = preview.documentView?.frame.height, height > 0 {
            preview.scrollFraction = Double(y / height)
        }
        return true
    }

    @objc private func frameChanged() { _ = settle() }

    @objc private func boundsChanged() {
        guard settle(), let document else { return }
        document.previewPosition = EditorDocument.validPosition(preview.contentView.bounds.origin)
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
            + "  draw \(ms(last.draw)) ms  \(last.blockCount) blocks\(last.isComplete ? "" : " (partial)") "
    }
}
