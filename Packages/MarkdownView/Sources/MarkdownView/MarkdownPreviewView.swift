import AppKit

/// A read-only Markdown preview: an `NSScrollView` to place in a layout, whose
/// `documentView` is the view to focus for keyboard scrolling.
///
/// Call `setSource(_:)` with the full text on every change, without a
/// debounce. Parsing and layout run on a background queue per view, one
/// update at a time: sources set while an update runs coalesce into one more
/// update with the newest, paced by `updatePolicy`. Each update re-parses the
/// whole source but rebuilds and lays out only the blocks that changed, and
/// the main thread only installs finished snapshots and draws what changed.
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
    /// Called with a link's destination, as written in the source, when a
    /// click on its text ends without a drag. The host decides what opens.
    public var onOpenLink: (@MainActor (String) -> Void)? {
        get { canvas.onOpenLink }
        set { canvas.onOpenLink = newValue }
    }
    public private(set) var lastTimings: Timings?
    /// When the next update may start after a slow one; see `UpdatePolicy`.
    public var updatePolicy = UpdatePolicy.standard
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
    private var submitted: (sourceGeneration: UInt64, width: CGFloat, complete: Bool, plan: RenderPlan)?
    /// The generation of the update in flight and when it was submitted,
    /// until its last snapshot installs.
    private var inFlight: (generation: UInt64, start: ContinuousClock.Instant)?
    /// After a slow update, newer sources wait until then.
    private var resumeAt: ContinuousClock.Instant?
    private var resumeTask: Task<Void, Never>?
    /// The source generation of the last complete snapshot installed.
    private var completedSourceGeneration: UInt64 = 0
    private var pendingScroll: ScrollTarget?
    private var timingsAwaitingDraw: Timings?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        drawsBackground = true
        // Height changes on every edit that adds or removes a line; only what
        // changed redraws, and the rest of the layer stays pinned in place.
        canvas.layerContentsRedrawPolicy = .onSetNeedsDisplay
        canvas.layerContentsPlacement = .topLeft
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
    /// While an update runs, the newest source waits for it to finish.
    public func setSource(_ text: String) {
        source = text
        sourceGeneration += 1
        scheduleUpdate()
        // Hidden or without a width: nothing older may install meanwhile.
        if !isShown || canvas.frame.width < 1 { cancelUpdates() }
    }

    private func cancelUpdates() {
        pipeline.cancel()
        inFlight = nil
        resumeTask?.cancel()
        resumeTask = nil
    }

    /// Hidden previews keep their snapshot and start no work. Sources set
    /// while hidden coalesce into one update when shown again.
    public func setVisible(_ visible: Bool) {
        guard visible != isShown else { return }
        isShown = visible
        if visible { scheduleUpdate() } else { resumeTask?.cancel(); resumeTask = nil }
    }

    /// The top of the visible area as a fraction of the document height, for
    /// carrying the position across renderers. Setting it after `setSource(_:)`
    /// and before that source's complete snapshot has installed applies it to
    /// the new content when it installs; until then, reading it returns it.
    /// Set right after `setSource(_:)`, as when showing another document, it
    /// also makes the update lay out and show the area there before the rest
    /// (approximately for a fraction, until the rest is laid out), and the
    /// update neither waits for typing updates nor pauses.
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
    /// snapshot has installed applies to that snapshot, and right after
    /// `setSource(_:)` the blocks down to it are laid out first, so the first
    /// snapshot shown is already at the exact position.
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
        } else if let submitted, submitted.sourceGeneration == sourceGeneration {
            // Set right after `setSource`, before the source is parsed: lay out
            // the area at the position first. Later, it applies on install.
            submitted.plan.set(firstStep)
        } else {
            // A position for a source still waiting: another document is
            // being shown, which neither waits for typing updates nor pauses.
            scheduleUpdate(waiting: false)
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
            // The old layout at the new width until the relayout installs.
            canvas.needsDisplay = true
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

    /// Submits an update unless one for the same source and width is out.
    /// A newer source alone (`waiting`) waits for the update in flight and
    /// for the pause after a slow one; a new width or a finished live resize
    /// supersedes it at once.
    private func scheduleUpdate(waiting: Bool = true) {
        let width = canvas.frame.width
        guard isShown, sourceGeneration > 0, width >= 1 else { return }
        let complete = !inLiveResize
        if let submitted, submitted.sourceGeneration == sourceGeneration, submitted.width == width,
           submitted.complete || !complete {
            return
        }
        if waiting, let submitted, submitted.width == width, submitted.complete == complete {
            if inFlight != nil { return }
            if let resumeAt, resumeAt > .now {
                waitForResume(until: resumeAt)
                return
            }
        }
        resumeTask?.cancel()
        resumeTask = nil
        let plan = RenderPlan(firstStep)
        submitted = (sourceGeneration, width, complete, plan)
        let generation = pipeline.submit(sourceGeneration: sourceGeneration, source: source, width: width,
                                         scrollFraction: CGFloat(scrollFraction),
                                         viewportHeight: contentView.bounds.height, visibleFirst: false,
                                         complete: complete, base: canvas.snapshot, plan: plan)
        inFlight = (generation, .now)
    }

    private func waitForResume(until instant: ContinuousClock.Instant) {
        guard resumeTask == nil else { return }
        resumeTask = Task { [weak self] in
            do { try await Task.sleep(until: instant, clock: .continuous) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.resumeTask = nil
            self.scheduleUpdate()
        }
    }

    /// What a new source lays out first: the area at a pending scroll
    /// position, with everything above it so the position is exact; the top
    /// of the first source; and while typing, everything that changed at once.
    private var firstStep: RenderPlan.FirstStep {
        switch pendingScroll {
        case .fraction(let value): value == 0 ? .offset(0) : .fraction(value)
        case .offset(let value): .offset(value)
        case nil: installedSourceGeneration == 0 ? .offset(0) : .everything
        }
    }

    private func handle(_ outcome: RenderOutcome) {
        // An update ends with its complete snapshot, or its only one during
        // live resize.
        let isLast: Bool
        switch outcome {
        case .snapshot(let snapshot, let sourceGeneration, let timings):
            isLast = snapshot.isComplete || submitted?.complete == false
            install(snapshot, sourceGeneration: sourceGeneration, timings: timings, isLast: isLast)
        case .failure(_, let message):
            isLast = true
            messageLabel.stringValue = "Preview failed: \(message)"
            messageLabel.isHidden = false
            tile()
        }
        guard isLast, inFlight?.generation == outcome.generation else { return }
        inFlight = nil
        scheduleUpdate()
    }

    private func install(_ snapshot: MarkdownSnapshot, sourceGeneration: UInt64, timings: Timings, isLast: Bool) {
        let start = ContinuousClock.now
        let interval = signposter.beginInterval("install")
        let old = canvas.snapshot
        let oldY = contentView.bounds.minY
        let sourceChanged = sourceGeneration != installedSourceGeneration
        let anchor = !sourceChanged && old.layouts.count == snapshot.layouts.count ? old.anchor(atY: oldY) : nil
        let update = sourceChanged ? snapshot.update(from: old) : nil
        let oldSelection = canvas.selection
        canvas.install(snapshot, sourceChanged: sourceChanged)
        installedSourceGeneration = sourceGeneration
        canvas.setFrameSize(NSSize(width: canvas.frame.width, height: snapshot.totalHeight))
        let isCurrent = sourceGeneration == self.sourceGeneration
        var redrawsAll = true
        if isCurrent, let target = pendingScroll {
            scroll(to: target)
            if snapshot.isComplete { pendingScroll = nil }
        } else if let anchor {
            scroll(toY: snapshot.y(for: anchor))
        } else if let update {
            scroll(toY: snapshot.anchoredY(oldY, from: old, through: update))
            redrawsAll = false
        }
        if isCurrent, snapshot.isComplete { completedSourceGeneration = sourceGeneration }
        let invalidated = redrawsAll ? nil : invalidate(from: old, oldSelection: oldSelection, update: update)
        canvas.lastInvalidation = invalidated
        if invalidated == nil { canvas.needsDisplay = true }
        messageLabel.isHidden = true
        pipeline.release(old)
        var timings = timings
        let end = ContinuousClock.now
        timings.install = end - start
        if isLast, let inFlight, inFlight.generation == snapshot.generation {
            timings.wall = end - inFlight.start
            timings.pause = updatePolicy.pause(after: timings.wall)
            resumeAt = timings.pause > .zero ? end + timings.pause : nil
        }
        signposter.endInterval("install", interval)
        timingsAwaitingDraw = timings
        // Nothing visible changed: there is no draw to wait for.
        if invalidated?.isEmpty == true { didDraw(.zero) }
        onInstall?(snapshot)
    }

    /// Marks what changed within the visible area for redrawing, after an
    /// edit diffed against `old`: changed blocks, everything below the first
    /// height change, and the selection where it moved. Nil when it all
    /// redraws.
    private func invalidate(from old: MarkdownSnapshot, oldSelection: Range<TextPosition>?,
                            update: BlockUpdate?) -> [CGRect]? {
        let new = canvas.snapshot
        let visible = canvas.visibleRect
        guard var rects = new.changedRects(from: old, in: visible) else { return nil }
        let selection = canvas.selection
        let kept = { (old: TextPosition, new: TextPosition) in
            update?.match?.newIndex(ofOld: old.block) == new.block && old.offset == new.offset
        }
        if oldSelection != nil || selection != nil {
            if let oldSelection, let selection, kept(oldSelection.lowerBound, selection.lowerBound),
               kept(oldSelection.upperBound, selection.upperBound) {
                // Unchanged blocks keep their highlight; the rest redraws anyway.
            } else {
                let bands = [oldSelection.map { old.lineBand($0.lowerBound, $0.upperBound) },
                             selection.map { new.lineBand($0.lowerBound, $0.upperBound) }]
                for case let band? in bands {
                    let rect = band.intersection(visible)
                    if !rect.isNull, !rect.isEmpty { rects.append(rect) }
                }
            }
        }
        for rect in rects { canvas.setNeedsDisplay(rect) }
        return rects
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
    var onOpenLink: (@MainActor (String) -> Void)?

    /// The rectangles the last install marked for redrawing, or nil when it
    /// redrew everything; for tests.
    var lastInvalidation: [CGRect]?
    /// Never empty; nil when nothing is selected.
    var selection: Range<TextPosition>?
    /// What the last click selected; drags and shift-clicks extend from it.
    var selectionAnchor: Range<TextPosition>?
    var granularity = SelectionGranularity.character
    /// The pointer during a drag, in window coordinates.
    var dragLocation = NSPoint.zero
    var autoscrollTimer: Timer?
    /// The link a click started on, until the pointer moves too far to open it.
    var pressedLink: (destination: String, point: CGPoint)?
    /// How far each code block wider than its box is scrolled left.
    var codeOffsets: CodeOffsets = [:]
    /// Which way the current scroll gesture goes: decided by its first
    /// movement, and kept through its momentum.
    var codeScrollGesture = CodeScrollGesture.none
    /// The code block showing its overlay scroller, until the timer hides it.
    var codeScroller: CodeBlockID?
    var codeScrollerTimer: Timer?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Replaces the snapshot. When the source changed, the selection is
    /// mapped onto the new blocks; a relayout of the same source keeps it.
    func install(_ newSnapshot: MarkdownSnapshot, sourceChanged: Bool) {
        let old = snapshot
        if sourceChanged {
            selection = selection.flatMap { newSnapshot.mapRange($0, from: old) }.flatMap { $0.isEmpty ? nil : $0 }
            selectionAnchor = selectionAnchor.flatMap { newSnapshot.mapRange($0, from: old) }
                ?? selection.map { $0.lowerBound..<$0.lowerBound }
        }
        if !codeOffsets.isEmpty {
            codeOffsets = newSnapshot.mapCodeOffsets(codeOffsets, from: old, sourceChanged: sourceChanged)
        }
        if let codeScroller, !codeOffsets.keys.contains(codeScroller) { self.codeScroller = nil }
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
        // Backgrounds, bars, and rules, then the selection over them, then
        // text, markers, and task boxes.
        let style = DrawStyle(palette, snapshot.typography)
        for index in range {
            snapshot.layouts[index].drawBackgrounds(in: context, at: origin(of: index, in: snapshot), clip: clip,
                                                    style: style)
        }
        if let selection {
            let rects = snapshot.selectionRects(for: selection, minY: dirtyRect.minY, maxY: dirtyRect.maxY,
                                                codeOffsets: codeOffsets)
            if !rects.isEmpty {
                context.setFillColor(selectionColor.cgColor)
                context.addRects(rects)
                context.fillPath()
            }
        }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let offsets = codeOffsets
        for index in range {
            snapshot.layouts[index].drawText(in: context, at: origin(of: index, in: snapshot), clip: clip, style: style) {
                offsets.isEmpty ? 0 : offsets[CodeBlockID(block: index, code: $0)] ?? 0
            }
        }
        if let codeScroller, range.contains(codeScroller.block) { drawScroller(of: codeScroller, in: context) }
    }

    private func origin(of block: Int, in snapshot: MarkdownSnapshot) -> CGPoint {
        CGPoint(x: snapshot.columnX, y: snapshot.blockTops[block])
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

/// Colors for one draw, resolved for the view's appearance, and corner radii.
struct DrawStyle {
    /// Indexed by `ColorIndex`.
    let text: [CGColor]
    let codeBackground: CGColor
    /// Quote bars, rules, and task boxes.
    let muted: CGColor
    /// The check mark in a checked task box.
    let background: CGColor
    let codeBlockCornerRadius: CGFloat
    let taskBoxCornerRadius: CGFloat

    init(_ palette: Palette, _ typography: Typography) {
        text = palette.cgColors
        codeBackground = Self.composite(palette.codeBackground, over: palette.background)
        muted = palette.mutedText.cgColor
        background = palette.background.cgColor
        codeBlockCornerRadius = typography.codeBlockCornerRadius
        taskBoxCornerRadius = typography.taskBoxCornerRadius
    }

    /// A translucent color as the opaque color it shows over an opaque
    /// background. Code backgrounds only ever cover the background, and
    /// filling large areas opaquely skips blending every pixel.
    static func composite(_ color: NSColor, over background: NSColor) -> CGColor {
        guard let top = color.usingColorSpace(.sRGB), top.alphaComponent < 1,
              let bottom = background.usingColorSpace(.sRGB), bottom.alphaComponent == 1 else { return color.cgColor }
        let alpha = top.alphaComponent
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * alpha + b * (1 - alpha) }
        return NSColor(srgbRed: mix(top.redComponent, bottom.redComponent), green: mix(top.greenComponent, bottom.greenComponent),
                       blue: mix(top.blueComponent, bottom.blueComponent), alpha: 1).cgColor
    }
}

extension BlockLayout {
    /// Fills code block backgrounds, quote bars, rules, and the inline code
    /// backgrounds on the lines that intersect `clip`.
    func drawBackgrounds(in context: CGContext, at origin: CGPoint, clip: CGRect, style: DrawStyle) {
        for box in boxes {
            let rect = box.rect.offsetBy(dx: origin.x, dy: origin.y)
            guard rect.intersects(clip) else { continue }
            switch box.kind {
            case .codeBackground:
                context.setFillColor(style.codeBackground)
                let radius = style.codeBlockCornerRadius
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            case .quoteBar, .rule:
                context.setFillColor(style.muted)
                context.fill(rect)
            }
        }
        forEachLine(intersecting: clip, at: origin) { line in
            for decoration in line.decorations where decoration.kind == .codeBackground {
                let rect = decoration.rect.offsetBy(dx: origin.x + line.x, dy: origin.y)
                context.setFillColor(style.codeBackground)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
                context.fillPath()
            }
        }
    }

    /// Draws the lines that intersect `clip`, coloring each run by its role
    /// and styles, then their underlines and strikethroughs, then list
    /// markers. Lines of a code block wider than its box move left by
    /// `codeOffset` of its index and are clipped to the box; Core Graphics
    /// skips clipped glyphs cheaply, so even a 4,842-character line costs
    /// little to draw. The context's text matrix must already flip glyphs
    /// for a flipped view.
    func drawText(in context: CGContext, at origin: CGPoint, clip: CGRect, style: DrawStyle,
                  codeOffset: (Int) -> CGFloat) {
        forEachLine(intersecting: clip, at: origin) { line in
            var x = origin.x + line.x
            let isClipped = line.codeBlock >= 0 && codeBlocks[Int(line.codeBlock)].maxOffset > 0
            if isClipped {
                x -= codeOffset(Int(line.codeBlock))
                context.saveGState()
                context.clip(to: codeBlocks[Int(line.codeBlock)].rect.offsetBy(dx: origin.x, dy: origin.y))
            }
            let position = CGPoint(x: x, y: origin.y + line.baseline)
            if let color = line.color {
                context.setFillColor(style.text[Int(color)])
                context.textPosition = position
                CTLineDraw(line.line, context)
            } else {
                for run in CTLineGetGlyphRuns(line.line) as? [CTRun] ?? [] {
                    let runStyle = styleRun(at: CTRunGetStringRange(run).location)
                    context.setFillColor(style.text[Int(ColorIndex.of(runStyle.role, runStyle.styles))])
                    context.textPosition = position
                    CTRunDraw(run, context, CFRange())
                }
            }
            for decoration in line.decorations where decoration.kind != .codeBackground {
                context.setFillColor(style.text[Int(decoration.color)])
                context.fill(decoration.rect.offsetBy(dx: x, dy: origin.y))
            }
            if isClipped { context.restoreGState() }
        }
        drawMarkers(in: context, at: origin, clip: clip, style: style)
    }

    /// Bullets, numbers, and task boxes beside the lines that intersect `clip`.
    private func drawMarkers(in context: CGContext, at origin: CGPoint, clip: CGRect, style: DrawStyle) {
        guard !markers.isEmpty else { return }
        // No marker reaches farther than a line from its baseline.
        let reach: CGFloat = 32
        var low = 0
        var high = markers.count
        while low < high {
            let mid = (low + high) / 2
            if origin.y + markers[mid].baseline + reach < clip.minY { low = mid + 1 } else { high = mid }
        }
        for marker in markers[low...] {
            guard origin.y + marker.baseline - reach < clip.maxY else { break }
            let rect = marker.rect.offsetBy(dx: origin.x, dy: origin.y)
            guard rect.intersects(clip) else { continue }
            switch marker.kind {
            case .disc:
                context.setFillColor(style.text[Int(marker.color)])
                context.fillEllipse(in: rect)
            case .circle:
                context.setStrokeColor(style.text[Int(marker.color)])
                context.setLineWidth(1)
                context.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
            case .square:
                context.setFillColor(style.text[Int(marker.color)])
                context.fill(rect)
            case .number(let line):
                context.setFillColor(style.text[Int(marker.color)])
                context.textPosition = CGPoint(x: rect.minX, y: origin.y + marker.baseline)
                CTLineDraw(line, context)
            case .task(let checked):
                drawTaskBox(in: rect, checked: checked, context: context, style: style)
            }
        }
    }

    /// A display-only checkbox: an outline, or filled with a check mark.
    private func drawTaskBox(in rect: CGRect, checked: Bool, context: CGContext, style: DrawStyle) {
        let radius = min(style.taskBoxCornerRadius, rect.width / 2)
        if checked {
            context.setFillColor(style.muted)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            context.setStrokeColor(style.background)
            context.setLineWidth(max(rect.width / 8, 1.5))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.53))
            context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.71))
            context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.31))
            context.strokePath()
        } else {
            context.setStrokeColor(style.muted)
            context.setLineWidth(1)
            let inset = rect.insetBy(dx: 0.5, dy: 0.5)
            context.addPath(CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        }
    }

    private func forEachLine(intersecting clip: CGRect, at origin: CGPoint, _ body: (LineLayout) -> Void) {
        var index = firstLine(endingBelow: clip.minY - origin.y)
        while index < lines.count, origin.y + lines[index].top < clip.maxY {
            body(lines[index])
            index += 1
        }
    }
}
