import AppKit

/// Mouse selection, copy, dragging, the context menu, and Services for the
/// document view. Work per event is a binary search plus the lines of the
/// blocks the selection ends in, and only the lines between the moved ends
/// redraw.
extension MarkdownDocumentView: NSMenuItemValidation, NSUserInterfaceValidations, NSDraggingSource,
    NSViewToolTipOwner, @preconcurrency NSServicesMenuRequestor {
    // MARK: Mouse

    /// How far the pointer may move during a click on a link before the
    /// click becomes a drag that selects, or during a click on the
    /// selection before it becomes a drag of the selected text.
    static let linkDragDistance: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragLocation = event.locationInWindow
        let point = convert(event.locationInWindow, from: nil)
        let extending = event.modifierFlags.contains(.shift)
        // Only a plain single click opens; double and triple clicks select.
        pressedLink = event.clickCount == 1 && !extending
            ? snapshot.linkDestination(at: point, codeOffsets: codeOffsets).map { ($0, point) } : nil
        // On the selected text, a plain click waits to see whether it drags
        // the text or ends as a click.
        if event.clickCount == 1, !extending, isOnSelection(point) {
            pressedSelection = point
            return
        }
        beginSelection(at: point, clickCount: event.clickCount, extending: extending)
    }

    override func mouseDragged(with event: NSEvent) {
        dragLocation = event.locationInWindow
        let point = convert(event.locationInWindow, from: nil)
        if let pressed = pressedSelection {
            guard hypot(point.x - pressed.x, point.y - pressed.y) >= Self.linkDragDistance else { return }
            pressedSelection = nil
            pressedLink = nil
            dragSelection(with: event)
            return
        }
        if let pressedLink {
            guard hypot(point.x - pressedLink.point.x, point.y - pressedLink.point.y) >= Self.linkDragDistance else { return }
            self.pressedLink = nil
        }
        extendSelection(to: point)
        updateAutoscroll()
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        if let pressed = pressedSelection {
            // A click on the selection that did not drag selects nothing, as anywhere else.
            pressedSelection = nil
            beginSelection(at: pressed, clickCount: 1, extending: false)
        }
        guard let pressedLink else { return }
        self.pressedLink = nil
        onOpenLink?(pressedLink.destination)
    }

    /// Whether `point` is on the selection's highlight.
    func isOnSelection(_ point: CGPoint) -> Bool {
        guard let selection else { return false }
        return snapshot.selectionRects(for: selection, minY: point.y - 1, maxY: point.y + 1, codeOffsets: codeOffsets)
            .contains { $0.contains(point) }
    }

    // MARK: Dragging

    /// Drags the selected text out, with the flavors Copy writes. The image
    /// is the visible part of the selected lines as drawn.
    private func dragSelection(with event: NSEvent) {
        guard let selection else { return }
        let item = NSDraggingItem(pasteboardWriter: RichTextProvider.item(for: snapshot, range: selection))
        var frame = snapshot.lineBand(selection.lowerBound, selection.upperBound).intersection(visibleRect)
        if frame.isNull || frame.isEmpty {
            let point = convert(event.locationInWindow, from: nil)
            frame = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
        }
        item.setDraggingFrame(frame, contents: dragImage(of: frame))
        beginDragging(self, [item], event)
    }

    /// The view's drawing of `rect`, without reporting it as a draw.
    private func dragImage(of rect: CGRect) -> NSImage? {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        let reportsDraw = onDraw
        onDraw = nil
        cacheDisplay(in: rect, to: bitmap)
        onDraw = reportsDraw
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    // MARK: Cursor

    /// One tracking area following the visible rect: the cursor is a
    /// pointing hand over link text and an I-beam elsewhere, decided by a
    /// binary search per mouse move, which also finds the tooltip.
    func addCursorTracking() {
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    private func updateCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (snapshot.linkDestination(at: point, codeOffsets: codeOffsets) != nil ? NSCursor.pointingHand : NSCursor.iBeam).set()
        updateToolTip(at: point)
    }

    // MARK: Tooltips

    /// Link and image titles show as tooltips. While the pointer is over a
    /// title, one tooltip area covers the visible rect; it is set again
    /// whenever the title under the pointer changes, so AppKit asks anew.
    func updateToolTip(at point: CGPoint) {
        let title = snapshot.toolTip(at: point, codeOffsets: codeOffsets)
        guard title != shownToolTip else { return }
        shownToolTip = title
        removeAllToolTips()
        if title != nil { addToolTip(visibleRect, owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        snapshot.toolTip(at: point, codeOffsets: codeOffsets) ?? ""
    }

    /// Starts a selection at `point`: a click selects nothing, a double-click
    /// a word, and a triple-click a paragraph. With `extending` (shift), the
    /// end of the current selection away from the point stays put.
    func beginSelection(at point: CGPoint, clickCount: Int, extending: Bool) {
        granularity = clickCount >= 3 ? .paragraph : clickCount == 2 ? .word : .character
        guard let position = snapshot.position(at: point, codeOffsets: codeOffsets) else {
            selectionAnchor = nil
            return setSelection(nil)
        }
        if extending, let selection {
            if position < selection.lowerBound {
                selectionAnchor = selection.upperBound..<selection.upperBound
            } else if position > selection.upperBound {
                selectionAnchor = selection.lowerBound..<selection.lowerBound
            } else if selectionAnchor == nil {
                selectionAnchor = selection.lowerBound..<selection.lowerBound
            }
        } else {
            selectionAnchor = snapshot.unitRange(at: position, granularity: granularity)
        }
        extendSelection(to: point)
    }

    /// Selects from the anchor to `point`, by the granularity of the click
    /// that started the drag.
    func extendSelection(to point: CGPoint) {
        guard let anchor = selectionAnchor, let position = snapshot.position(at: point, codeOffsets: codeOffsets) else { return }
        let unit = snapshot.unitRange(at: position, granularity: granularity, forward: position >= anchor.upperBound)
        setSelection(min(anchor.lowerBound, unit.lowerBound)..<max(anchor.upperBound, unit.upperBound))
    }

    /// Changes the selection and redraws only the visible lines that changed.
    func setSelection(_ range: Range<TextPosition>?) {
        let new = range?.isEmpty == false ? range : nil
        guard new != selection else { return }
        let old = selection
        selection = new
        let visible = visibleRect
        for rect in snapshot.selectionDirtyRects(from: old, to: new) {
            let dirty = rect.intersection(visible)
            if !dirty.isNull, !dirty.isEmpty { setNeedsDisplay(dirty) }
        }
    }

    /// Redraws the visible part of the selection, for a color change.
    private func invalidateSelection() {
        guard let selection else { return }
        let dirty = snapshot.lineBand(selection.lowerBound, selection.upperBound).intersection(visibleRect)
        if !dirty.isNull, !dirty.isEmpty { setNeedsDisplay(dirty) }
    }

    // MARK: Autoscroll

    /// While a drag is above or below the visible area, a timer scrolls and
    /// extends the selection even when the pointer stops moving.
    private func updateAutoscroll() {
        let y = convert(dragLocation, from: nil).y
        let visible = visibleRect
        guard y < visible.minY || y > visible.maxY else { return stopAutoscroll() }
        guard autoscrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollStep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscrollTimer = timer
    }

    private func autoscrollStep() {
        let point = convert(dragLocation, from: nil)
        let visible = visibleRect
        let distance = point.y < visible.minY ? point.y - visible.minY : point.y > visible.maxY ? point.y - visible.maxY : 0
        guard distance != 0, window != nil else { return stopAutoscroll() }
        // Faster the farther outside the pointer is, at most half a page per step.
        let step = min(max(abs(distance) / 2, 4), visible.height / 2)
        scroll(toY: visible.minY + (distance < 0 ? -step : step))
        extendSelection(to: convert(dragLocation, from: nil))
    }

    func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    // MARK: Focus and key window

    override func becomeFirstResponder() -> Bool {
        invalidateSelection()
        return true
    }

    override func resignFirstResponder() -> Bool {
        invalidateSelection()
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        stopAutoscroll()
        guard let window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        addCursorTracking()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged(_:)), name: name, object: window)
        }
        Self.registerServicesTypes()
    }

    @objc private func keyWindowChanged(_ notification: Notification) {
        invalidateSelection()
    }

    /// Emphasized only while the window is key and this view has focus.
    var selectionColor: NSColor {
        window?.isKeyWindow == true && window?.firstResponder === self
            ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
    }

    // MARK: Commands

    override func selectAll(_ sender: Any?) {
        selectionAnchor = snapshot.fullRange.map { $0.lowerBound..<$0.lowerBound }
        setSelection(snapshot.fullRange)
    }

    @objc func copy(_ sender: Any?) {
        writeCopy(to: .general)
    }

    /// Writes the selection as Copy does: plain text at once, RTF and HTML
    /// when a receiver asks for them.
    @discardableResult
    func writeCopy(to pasteboard: NSPasteboard) -> Bool {
        guard let selection else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([RichTextProvider.item(for: snapshot, range: selection)])
    }

    @objc func lookUpSelection(_ sender: Any?) {
        guard let selection else { return }
        lookUp(selection)
    }

    /// A force click, or the trackpad's Look Up gesture, looks up the
    /// selection under the pointer or the word there, as in text views.
    override func quickLook(with event: NSEvent) {
        guard let range = lookUpRange(at: convert(event.locationInWindow, from: nil)) else {
            return super.quickLook(with: event)
        }
        lookUp(range)
    }

    /// What a force click at `point` looks up: the selection, when the point
    /// is on it, else the word under the point; nil off the text.
    func lookUpRange(at point: CGPoint) -> Range<TextPosition>? {
        if let selection, isOnSelection(point) { return selection }
        guard snapshot.isOverText(point, codeOffsets: codeOffsets),
              let position = snapshot.position(at: point, codeOffsets: codeOffsets) else { return nil }
        let word = snapshot.unitRange(at: position, granularity: .word)
        return snapshot.text(in: word).contains { !$0.isWhitespace } ? word : nil
    }

    /// Shows the system's definition of `range` over its text.
    private func lookUp(_ range: Range<TextPosition>) {
        guard let origin = snapshot.baselineOrigin(of: range.lowerBound, codeOffsets: codeOffsets) else { return }
        let font = snapshot.typography.font(origin.style.role, origin.style.styles) as NSFont
        let color = palette.color(for: origin.style.role, styles: origin.style.styles)
        let string = NSAttributedString(string: snapshot.text(in: range), attributes: [.font: font, .foregroundColor: color])
        showDefinition(for: string, at: origin.point)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateUserInterfaceItem(menuItem)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(lookUpSelection(_:)): selection != nil
        case #selector(selectAll(_:)): snapshot.fullRange != nil
        default: true
        }
    }

    // MARK: Context menu

    /// Copy, Look Up, and Services. A right-click outside the selection first
    /// selects the word under the pointer, as in text views.
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let position = snapshot.position(at: point, codeOffsets: codeOffsets),
           !(selection.map { $0.lowerBound <= position && position <= $0.upperBound } ?? false) {
            let word = snapshot.unitRange(at: position, granularity: .word)
            let isWord = snapshot.isOverText(point, codeOffsets: codeOffsets)
                && snapshot.text(in: word).contains { !$0.isWhitespace }
            selectionAnchor = isWord ? word : nil
            setSelection(isWord ? word : nil)
        }
        let menu = NSMenu()
        menu.autoenablesItems = true
        if let selection {
            var title = snapshot.text(in: selection).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            if title.count > 24 { title = title.prefix(24).trimmingCharacters(in: .whitespaces) + "…" }
            menu.addItem(withTitle: "Look Up “\(title)”", action: #selector(lookUpSelection(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
        if let services = Self.servicesItem() {
            menu.addItem(.separator())
            menu.addItem(services)
        }
        return menu
    }

    // MARK: Services

    /// The last context menu item holding the shared Services menu.
    @MainActor private static weak var servicesHost: NSMenuItem?
    @MainActor private static var registeredServicesTypes = false

    private static func registerServicesTypes() {
        guard !registeredServicesTypes, let app = NSApp else { return }
        registeredServicesTypes = true
        app.registerServicesMenuSendTypes([.string], returnTypes: [])
    }

    /// A Services item whose submenu is the application's Services menu,
    /// which AppKit fills and validates against this view. Created when the
    /// host has none; left out when the host shows it in its own menus.
    private static func servicesItem() -> NSMenuItem? {
        guard let app = NSApp else { return nil }
        servicesHost?.submenu = nil
        let services = app.servicesMenu ?? NSMenu(title: "Services")
        app.servicesMenu = services
        guard services.supermenu == nil else { return nil }
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        item.submenu = services
        servicesHost = item
        return item
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == .string, returnType == nil, selection != nil { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Writes the selection as plain text, for Copy and Services.
    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string), let selection else { return false }
        pboard.clearContents()
        return pboard.setString(snapshot.text(in: selection), forType: .string)
    }
}
