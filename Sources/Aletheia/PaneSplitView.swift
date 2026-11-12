import AppKit

/// Keeps the preferred divider position independent of temporary window constraints.
@MainActor
final class PaneSplitView: NSSplitView, NSSplitViewDelegate {
    let proportional: Bool
    var preferredSize: CGFloat
    /// Pins the first pane to this width and disables the divider, keeping `preferredSize`.
    var collapsedSize: CGFloat? {
        didSet { applyPreferredSize() }
    }

    init(proportional: Bool, preferredSize: CGFloat) {
        self.proportional = proportional
        self.preferredSize = preferredSize
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyPreferredSize() {
        guard arrangedSubviews.count == 2 else { return }
        let available = max(0, bounds.width - dividerThickness)
        let desired = proportional ? available * preferredSize : preferredSize
        let position = collapsedSize.map { min($0, available) }
            ?? min(max(desired, minimumPosition), maximumPosition)
        arrangedSubviews[0].frame = NSRect(x: 0, y: 0, width: position, height: bounds.height)
        arrangedSubviews[1].frame = NSRect(x: position + dividerThickness, y: 0,
                                          width: available - position, height: bounds.height)
        // Frames set directly do not invalidate the divider, which would stay painted at its old position.
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        rememberDividerPosition()
    }

    private var minimumPosition: CGFloat {
        min(proportional ? 120 : 140, max(0, bounds.width - dividerThickness) / 2)
    }

    private var maximumPosition: CGFloat {
        let available = max(0, bounds.width - dividerThickness)
        return max(minimumPosition, available - (proportional ? 120 : 280))
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        applyPreferredSize()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { collapsedSize ?? minimumPosition }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { collapsedSize ?? maximumPosition }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                   forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        collapsedSize == nil ? proposedEffectiveRect : .zero
    }

    // Called after native divider tracking, never after automatic window layout.
    func rememberDividerPosition() {
        guard arrangedSubviews.count == 2, collapsedSize == nil else { return }
        let available = bounds.width - dividerThickness
        guard available > 0 else { return }
        preferredSize = proportional ? arrangedSubviews[0].frame.width / available : arrangedSubviews[0].frame.width
    }
}
