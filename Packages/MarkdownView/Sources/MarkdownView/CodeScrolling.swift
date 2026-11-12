import AppKit

/// A code block in a snapshot: its block's index and its index in that
/// block's `codeBlocks`.
struct CodeBlockID: Hashable, Sendable {
    var block: Int
    var code: Int
}

/// How far code blocks wider than their box are scrolled left, in points.
/// Blocks not listed are not scrolled. It is view state: layouts stay
/// immutable and are drawn shifted.
typealias CodeOffsets = [CodeBlockID: CGFloat]

/// Which way a trackpad scroll gesture goes, decided by its first movement.
enum CodeScrollGesture: Equatable {
    case none
    case undecided
    case document
    case code(CodeBlockID)
}

extension MarkdownSnapshot {
    /// The code block whose box holds `point`, in view coordinates.
    func codeBlock(at point: CGPoint) -> CodeBlockID? {
        let index = firstBlock(endingBelow: point.y)
        guard index < layouts.count, blockTops[index] <= point.y else { return nil }
        let codeBlocks = layouts[index].codeBlocks
        let local = CGPoint(x: point.x - columnX, y: point.y - blockTops[index])
        var low = 0
        var high = codeBlocks.count
        while low < high {
            let mid = (low + high) / 2
            if codeBlocks[mid].rect.maxY <= local.y { low = mid + 1 } else { high = mid }
        }
        guard low < codeBlocks.count, codeBlocks[low].rect.contains(local) else { return nil }
        return CodeBlockID(block: index, code: low)
    }

    func codeBlockLayout(_ id: CodeBlockID) -> CodeBlockLayout? {
        guard id.block < layouts.count, id.code < layouts[id.block].codeBlocks.count else { return nil }
        return layouts[id.block].codeBlocks[id.code]
    }

    /// A code block's box in view coordinates.
    func codeBlockRect(_ id: CodeBlockID) -> CGRect? {
        codeBlockLayout(id)?.rect.offsetBy(dx: columnX, dy: blockTops[id.block])
    }

    /// Carries code block and table offsets from `old` into this snapshot:
    /// the same blocks after a relayout of the same source, and blocks the
    /// diff kept after an edit. A table also keeps its offset when its own
    /// block was edited, as when typing in one of its cells. Offsets are
    /// clamped to the new widths; code blocks that changed, or a snapshot of
    /// another document, start unscrolled.
    func mapCodeOffsets(_ offsets: CodeOffsets, from old: MarkdownSnapshot, sourceChanged: Bool) -> CodeOffsets {
        let match = sourceChanged ? update(from: old)?.match : nil
        guard !sourceChanged || match != nil else { return [:] }
        var mapped: CodeOffsets = [:]
        for (id, offset) in offsets {
            var block = sourceChanged ? match?.newIndex(ofOld: id.block) : id.block
            if block == nil, let match, old.codeBlockLayout(id)?.isTable == true,
               let paired = match.pairedNewIndex(ofOld: id.block), paired < layouts.count,
               layouts[paired].isEstimate || codeBlockLayout(CodeBlockID(block: paired, code: id.code))?.isTable == true {
                block = paired
            }
            guard let block, block < layouts.count else { continue }
            let target = CodeBlockID(block: block, code: id.code)
            if layouts[block].isEstimate {
                // Not laid out yet: keep the offset until it is.
                mapped[target] = offset
            } else if let code = codeBlockLayout(target), code.maxOffset > 0 {
                mapped[target] = min(offset, code.maxOffset)
            }
        }
        return mapped
    }
}

/// Horizontal scrolling of code blocks wider than their box, each on its own,
/// with an overlay scroller while it moves. A mostly horizontal trackpad
/// gesture that starts over such a block scrolls it, momentum included; any
/// other gesture scrolls the document. A mouse wheel scrolls a block
/// horizontally with Shift held, as AppKit turns those deltas horizontal.
extension MarkdownDocumentView {
    /// How long the overlay scroller stays after the last movement.
    static let codeScrollerDuration: TimeInterval = 0.8

    override func scrollWheel(with event: NSEvent) {
        if scrollCodeBlock(with: event) { return }
        super.scrollWheel(with: event)
    }

    /// Scrolls a code block with `event` if it belongs to it, and returns
    /// whether it did. A gesture's start and end still reach the scroll
    /// view, which tracks gestures.
    private func scrollCodeBlock(with event: NSEvent) -> Bool {
        let phase = event.phase
        let momentum = event.momentumPhase
        let delta = event.scrollingDeltaX
        let isHorizontal = abs(delta) > abs(event.scrollingDeltaY)
        let lineScroll = enclosingScrollView?.horizontalLineScroll ?? 10
        guard !phase.isEmpty || !momentum.isEmpty else {
            // A mouse wheel: each event goes on its own.
            guard isHorizontal, let id = scrollableCodeBlock(at: event) else { return false }
            scrollCode(id, by: event.hasPreciseScrollingDeltas ? delta : delta * lineScroll)
            return true
        }
        if phase.contains(.mayBegin) || phase.contains(.began) {
            codeScrollGesture = .undecided
            return false
        }
        if codeScrollGesture == .undecided, phase.contains(.changed), delta != 0 || event.scrollingDeltaY != 0 {
            codeScrollGesture = isHorizontal ? scrollableCodeBlock(at: event).map { .code($0) } ?? .document : .document
        }
        guard case .code(let id) = codeScrollGesture else { return false }
        if phase.contains(.ended) || phase.contains(.cancelled) { return false }
        if momentum.contains(.ended) || momentum.contains(.cancelled) {
            codeScrollGesture = .none
            return true
        }
        scrollCode(id, by: event.hasPreciseScrollingDeltas ? delta : delta * lineScroll)
        return true
    }

    private func scrollableCodeBlock(at event: NSEvent) -> CodeBlockID? {
        let point = convert(event.locationInWindow, from: nil)
        guard let id = snapshot.codeBlock(at: point), let code = snapshot.codeBlockLayout(id), code.maxOffset > 0
        else { return nil }
        return id
    }

    /// Moves a code block's lines by `delta` (positive moves them right),
    /// clamped to its width, and redraws only its box.
    func scrollCode(_ id: CodeBlockID, by delta: CGFloat) {
        guard let code = snapshot.codeBlockLayout(id), let box = snapshot.codeBlockRect(id) else { return }
        let old = codeOffsets[id] ?? 0
        let new = min(max(old - delta, 0), code.maxOffset)
        showCodeScroller(id)
        guard new != old else { return }
        codeOffsets[id] = new > 0 ? new : nil
        let dirty = box.intersection(drawnRect)
        if !dirty.isNull, !dirty.isEmpty { setNeedsDisplay(dirty) }
    }

    private func showCodeScroller(_ id: CodeBlockID) {
        if let shown = codeScroller, shown != id { invalidateScroller(of: shown) }
        codeScroller = id
        invalidateScroller(of: id)
        codeScrollerTimer?.invalidate()
        let timer = Timer(timeInterval: Self.codeScrollerDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let shown = self.codeScroller else { return }
                self.codeScroller = nil
                self.codeScrollerTimer = nil
                self.invalidateScroller(of: shown)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        codeScrollerTimer = timer
    }

    private func invalidateScroller(of id: CodeBlockID) {
        guard let rect = scrollerRect(of: id)?.insetBy(dx: -1, dy: -1).intersection(drawnRect),
              !rect.isNull, !rect.isEmpty else { return }
        setNeedsDisplay(rect)
    }

    /// The overlay knob along the bottom of a code block, inside its padding.
    func scrollerRect(of id: CodeBlockID) -> CGRect? {
        guard let code = snapshot.codeBlockLayout(id), code.maxOffset > 0,
              let box = snapshot.codeBlockRect(id) else { return nil }
        let inset: CGFloat = 2
        let thickness: CGFloat = 5
        let track = box.width - 2 * inset
        let width = max(track * box.width / code.contentWidth, min(24, track))
        let fraction = (codeOffsets[id] ?? 0) / code.maxOffset
        return CGRect(x: box.minX + inset + (track - width) * fraction, y: box.maxY - inset - thickness,
                      width: width, height: thickness)
    }

    func drawScroller(of id: CodeBlockID, in context: CGContext) {
        guard let rect = scrollerRect(of: id) else { return }
        context.setFillColor(palette.text.cgColor.copy(alpha: 0.35) ?? palette.mutedText.cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2,
                               transform: nil))
        context.fillPath()
    }
}
