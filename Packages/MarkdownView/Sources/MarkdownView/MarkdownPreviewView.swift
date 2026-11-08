import AppKit

/// A read-only Markdown preview: an `NSScrollView` to place in a layout, whose
/// `documentView` is the view to focus for keyboard scrolling.
///
/// Call `setSource(_:)` with the full text on every change. Parsing and layout
/// run on a background queue per view; the newest source always wins, and the
/// main thread only installs finished snapshots and draws visible blocks.
@MainActor
public final class MarkdownPreviewView: NSScrollView {
    /// Colors by role. Changing it only redraws.
    public var palette = Palette.standard {
        didSet { applyPalette() }
    }

    /// Called on the main thread after the first draw of each installed update.
    public var onTimings: (@MainActor (Timings) -> Void)?
    /// Called on the main thread right after each snapshot installs, before it
    /// draws. A pending scroll position has been applied by then.
    public var onInstall: (@MainActor (MarkdownSnapshot) -> Void)?
    public private(set) var lastTimings: Timings?
    /// Whether updates run. Hidden previews keep their content.
    public private(set) var isShown = true
    /// The installed snapshot.
    public var snapshot: MarkdownSnapshot { canvas.snapshot }
    /// The selected text as positions in the installed snapshot, or nil.
    public var selection: Range<TextPosition>? { canvas.selection }
    /// The selection as the plain text Copy writes.
    public var selectedText: String { canvas.selection.map { canvas.snapshot.text(in: $0) } ?? "" }

    let pipeline = RenderPipeline(typography: .standard)
    private let canvas = MarkdownDocumentView(frame: .zero)
    private let messageLabel = NSTextField(labelWithString: "")
    private var source = ""
    private var sourceGeneration: UInt64 = 0
    private var installedSourceGeneration: UInt64 = 0
    private var submitted: (sourceGeneration: UInt64, width: CGFloat, complete: Bool, visibleFirst: Bool)?
    /// The source generation of the last complete snapshot installed.
    private var completedSourceGeneration: UInt64 = 0
    private var pendingScroll: ScrollTarget?
    private var timingsAwaitingDraw: Timings?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        drawsBackground = true
        documentView = canvas
        messageLabel.isHidden = true
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 1
        messageLabel.drawsBackground = true
        addSubview(messageLabel)
        applyPalette()
        pipeline.onOutcome = { [weak self] outcome in self?.handle(outcome) }
        canvas.onDraw = { [weak self] duration in self?.didDraw(duration) }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    /// Replaces the Markdown source. Cheap on the main thread: the text is
    /// handed to the background queue, and while hidden it is only stored.
    public func setSource(_ text: String) {
        source = text
        sourceGeneration += 1
        scheduleUpdate()
        // Hidden or without a width: nothing older may install meanwhile.
        if submitted?.sourceGeneration != sourceGeneration { pipeline.cancel() }
    }

    /// Hidden previews keep their snapshot and start no work. Sources set
    /// while hidden coalesce into one update when shown again.
    public func setVisible(_ visible: Bool) {
        guard visible != isShown else { return }
        isShown = visible
        if visible { scheduleUpdate() }
    }

    /// The top of the visible area as a fraction of the document height, for
    /// carrying the position across renderers. Setting it after `setSource(_:)`
    /// and before that source's complete snapshot has installed applies it to
    /// the new content when it installs; until then, reading it returns it.
    public var scrollFraction: Double {
        get {
            let height = canvas.frame.height
            switch pendingScroll {
            case .fraction(let fraction): return Double(fraction)
            case .offset(let y): return height > 0 ? Double(min(y / height, 1)) : 0
            case nil: return height > 0 ? Double(contentView.bounds.minY / height) : 0
            }
        }
        set {
            requestScroll(.fraction(newValue.isFinite ? CGFloat(min(max(newValue, 0), 1)) : 0))
        }
    }

    /// The top of the visible area in points, or a pending position as
    /// described for `scrollFraction`.
    public var scrollOffset: CGFloat {
        switch pendingScroll {
        case .fraction(let fraction): fraction * canvas.frame.height
        case .offset(let y): y
        case nil: contentView.bounds.minY
        }
    }

    /// Scrolls so `y` is at the top, clamped to the content. Like
    /// `scrollFraction`, a position set before the current source's complete
    /// snapshot has installed applies to that snapshot.
    public func setScrollOffset(_ y: CGFloat) {
        requestScroll(.offset(y.isFinite ? max(y, 0) : 0))
    }

    /// Deselects all text.
    public func clearSelection() {
        canvas.selectionAnchor = nil
        canvas.setSelection(nil)
    }

    private func requestScroll(_ target: ScrollTarget) {
        if sourceGeneration > 0, completedSourceGeneration == sourceGeneration {
            pendingScroll = nil
            scroll(to: target)
            return
        }
        pendingScroll = target
        if installedSourceGeneration == sourceGeneration {
            // Only the visible part is laid out: show about the right place now
            // and settle on the complete snapshot.
            scroll(to: target)
        } else if let submitted, submitted.sourceGeneration == sourceGeneration,
                  submitted.visibleFirst != wantsVisibleFirst {
            // The position decides whether laying out the visible part first pays off.
            self.submitted = nil
            scheduleUpdate()
        }
    }

    private func scroll(to target: ScrollTarget) {
        switch target {
        case .fraction(let fraction): scroll(toY: fraction * canvas.frame.height)
        case .offset(let y): scroll(toY: y)
        }
    }

    public override func tile() {
        super.tile()
        let width = contentView.bounds.width
        if canvas.frame.width != width {
            canvas.setFrameSize(NSSize(width: width, height: canvas.frame.height))
            scheduleUpdate()
        }
        if !messageLabel.isHidden {
            let height = messageLabel.fittingSize.height
            messageLabel.frame = NSRect(x: 12, y: isFlipped ? 8 : bounds.height - 8 - height,
                                        width: max(bounds.width - 24, 0), height: height)
        }
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleUpdate()
    }

    // MARK: Updates

    private func scheduleUpdate() {
        let width = canvas.frame.width
        guard isShown, sourceGeneration > 0, width >= 1 else { return }
        let complete = !inLiveResize
        if let submitted, submitted.sourceGeneration == sourceGeneration, submitted.width == width,
           submitted.complete || !complete {
            return
        }
        let visibleFirst = wantsVisibleFirst
        submitted = (sourceGeneration, width, complete, visibleFirst)
        let fraction = visibleFirst ? 0 : CGFloat(scrollFraction)
        pipeline.submit(sourceGeneration: sourceGeneration, source: source, width: width, scrollFraction: fraction,
                        viewportHeight: contentView.bounds.height, visibleFirst: visibleFirst, complete: complete)
    }

    /// Visible-first only pays off when the position in the new document is
    /// known without laying out what is above it: the top.
    private var wantsVisibleFirst: Bool {
        guard installedSourceGeneration != sourceGeneration else { return false }
        switch pendingScroll {
        case .fraction(let value), .offset(let value): return value == 0
        case nil: return installedSourceGeneration == 0
        }
    }

    private func handle(_ outcome: RenderOutcome) {
        switch outcome {
        case .snapshot(let snapshot, let sourceGeneration, let timings):
            install(snapshot, sourceGeneration: sourceGeneration, timings: timings)
        case .failure(_, let message):
            messageLabel.stringValue = "Preview failed: \(message)"
            messageLabel.isHidden = false
            tile()
        }
    }

    private func install(_ snapshot: MarkdownSnapshot, sourceGeneration: UInt64, timings: Timings) {
        let start = ContinuousClock.now
        let interval = signposter.beginInterval("install")
        let old = canvas.snapshot
        let anchor = sourceGeneration == installedSourceGeneration && old.layouts.count == snapshot.layouts.count
            ? old.anchor(atY: contentView.bounds.minY) : nil
        canvas.install(snapshot, sourceChanged: sourceGeneration != installedSourceGeneration)
        installedSourceGeneration = sourceGeneration
        canvas.setFrameSize(NSSize(width: canvas.frame.width, height: snapshot.totalHeight))
        let isCurrent = sourceGeneration == self.sourceGeneration
        if isCurrent, let target = pendingScroll {
            scroll(to: target)
            if snapshot.isComplete { pendingScroll = nil }
        } else if let anchor {
            scroll(toY: snapshot.y(for: anchor))
        }
        if isCurrent, snapshot.isComplete { completedSourceGeneration = sourceGeneration }
        canvas.needsDisplay = true
        messageLabel.isHidden = true
        pipeline.release(old)
        var timings = timings
        timings.install = ContinuousClock.now - start
        signposter.endInterval("install", interval)
        timingsAwaitingDraw = timings
        onInstall?(snapshot)
    }

    private func didDraw(_ duration: Duration) {
        guard var timings = timingsAwaitingDraw else { return }
        timingsAwaitingDraw = nil
        timings.draw = duration
        lastTimings = timings
        // Report after the display pass rather than from inside it.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onTimings?(timings) }
        }
    }

    private func scroll(toY y: CGFloat) {
        canvas.scroll(toY: y)
    }

    private enum ScrollTarget {
        case fraction(CGFloat)
        case offset(CGFloat)
    }

    private func applyPalette() {
        canvas.palette = palette
        backgroundColor = palette.background
        messageLabel.textColor = palette.mutedText
        messageLabel.backgroundColor = palette.background
    }
}

/// The flipped document view: draws visible blocks and the selection, and
/// handles selection, copy, and keyboard scrolling.
final class MarkdownDocumentView: NSView {
    private(set) var snapshot = MarkdownSnapshot.empty
    var palette = Palette.standard {
        didSet { needsDisplay = true }
    }
    var onDraw: (@MainActor (Duration) -> Void)?

    /// Never empty; nil when nothing is selected.
    var selection: Range<TextPosition>?
    /// What the last click selected; drags and shift-clicks extend from it.
    var selectionAnchor: Range<TextPosition>?
    var granularity = SelectionGranularity.character
    /// The pointer during a drag, in window coordinates.
    var dragLocation = NSPoint.zero
    var autoscrollTimer: Timer?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Replaces the snapshot. When the source changed, the selection is
    /// mapped onto the new blocks; a relayout of the same source keeps it.
    func install(_ newSnapshot: MarkdownSnapshot, sourceChanged: Bool) {
        if sourceChanged {
            let old = snapshot
            selection = selection.flatMap { newSnapshot.mapRange($0, from: old) }.flatMap { $0.isEmpty ? nil : $0 }
            selectionAnchor = selectionAnchor.flatMap { newSnapshot.mapRange($0, from: old) }
                ?? selection.map { $0.lowerBound..<$0.lowerBound }
        }
        snapshot = newSnapshot
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let start = ContinuousClock.now
        let interval = signposter.beginInterval("draw")
        defer {
            signposter.endInterval("draw", interval)
            onDraw?(ContinuousClock.now - start)
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(palette.background.cgColor)
        context.fill(dirtyRect)
        let snapshot = snapshot
        // Lines just outside the dirty area are drawn too, so glyphs that
        // overhang their line box are not cut off.
        let clip = dirtyRect.insetBy(dx: 0, dy: -8)
        let range = snapshot.blockRange(intersecting: clip.minY, clip.maxY)
        guard !range.isEmpty else { return }
        if let selection {
            let rects = snapshot.selectionRects(for: selection, minY: dirtyRect.minY, maxY: dirtyRect.maxY)
            if !rects.isEmpty {
                context.setFillColor(selectionColor.cgColor)
                context.addRects(rects)
                context.fillPath()
            }
        }
        let colors = TextRole.allCases.map { palette.color(for: $0).cgColor }
        let codeBackground = palette.codeBackground.cgColor
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for index in range {
            snapshot.layouts[index].draw(in: context, at: CGPoint(x: snapshot.columnX, y: snapshot.blockTops[index]),
                                         clip: clip, colors: colors, codeBackground: codeBackground)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) else {
            return super.keyDown(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let top = visibleRect.minY
        let line = Typography.standard.lineHeight(.body)
        let page = max(visibleRect.height - line, line)
        let end = CGFloat.greatestFiniteMagnitude
        switch key {
        case NSUpArrowFunctionKey:
            scroll(toY: flags.contains(.command) ? 0 : top - (flags.contains(.option) ? page : line))
        case NSDownArrowFunctionKey:
            scroll(toY: flags.contains(.command) ? end : top + (flags.contains(.option) ? page : line))
        case NSPageUpFunctionKey:
            scroll(toY: top - page)
        case NSPageDownFunctionKey:
            scroll(toY: top + page)
        case NSHomeFunctionKey:
            scroll(toY: 0)
        case NSEndFunctionKey:
            scroll(toY: end)
        case 0x20 where flags.isDisjoint(with: [.command, .control, .option]):
            scroll(toY: top + (flags.contains(.shift) ? -page : page))
        default:
            super.keyDown(with: event)
        }
    }

    /// Scrolls the enclosing clip view so `y` is at the top, clamped.
    func scroll(toY y: CGFloat) {
        let maximum = max(bounds.height - visibleRect.height, 0)
        scroll(NSPoint(x: 0, y: min(max(y, 0), maximum)))
    }
}

extension BlockLayout {
    /// Draws the lines that intersect `clip`, coloring each run by role. The
    /// context's text matrix must already flip glyphs for a flipped view.
    func draw(in context: CGContext, at origin: CGPoint, clip: CGRect, colors: [CGColor], codeBackground: CGColor) {
        if drawsCodeBackground {
            let rect = CGRect(x: origin.x, y: origin.y, width: columnWidth, height: height)
            context.setFillColor(codeBackground)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()
        }
        var index = firstLine(endingBelow: clip.minY - origin.y)
        while index < lines.count, origin.y + lines[index].top < clip.maxY {
            let line = lines[index]
            let position = CGPoint(x: origin.x + textInset, y: origin.y + line.baseline)
            if let role = line.role {
                context.setFillColor(colors[Int(role.rawValue)])
                context.textPosition = position
                CTLineDraw(line.line, context)
            } else {
                for run in CTLineGetGlyphRuns(line.line) as? [CTRun] ?? [] {
                    context.setFillColor(colors[Int(role(at: CTRunGetStringRange(run).location).rawValue)])
                    context.textPosition = position
                    CTRunDraw(run, context, CFRange())
                }
            }
            index += 1
        }
    }
}
