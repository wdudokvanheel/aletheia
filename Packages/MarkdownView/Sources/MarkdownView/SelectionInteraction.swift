import AppKit

/// Mouse selection, copy, the context menu, and Services for the document
/// view. Work per event is a binary search plus the lines of the blocks the
/// selection ends in, and only the lines between the moved ends redraw.
extension MarkdownDocumentView: NSMenuItemValidation, NSUserInterfaceValidations, @preconcurrency NSServicesMenuRequestor {
    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragLocation = event.locationInWindow
        beginSelection(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount,
                       extending: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        dragLocation = event.locationInWindow
        extendSelection(to: convert(event.locationInWindow, from: nil))
        updateAutoscroll()
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Starts a selection at `point`: a click selects nothing, a double-click
    /// a word, and a triple-click a paragraph. With `extending` (shift), the
    /// end of the current selection away from the point stays put.
    func beginSelection(at point: CGPoint, clickCount: Int, extending: Bool) {
        granularity = clickCount >= 3 ? .paragraph : clickCount == 2 ? .word : .character
        guard let position = snapshot.position(at: point) else {
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
        guard let anchor = selectionAnchor, let position = snapshot.position(at: point) else { return }
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
        _ = writeSelection(to: .general, types: [.string])
    }

    @objc func lookUpSelection(_ sender: Any?) {
        guard let selection, let origin = snapshot.baselineOrigin(of: selection.lowerBound) else { return }
        let font = snapshot.typography.fonts[Int(origin.role.rawValue)] as NSFont
        let string = NSAttributedString(string: snapshot.text(in: selection),
                                        attributes: [.font: font, .foregroundColor: palette.color(for: origin.role)])
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
        if let position = snapshot.position(at: point),
           !(selection.map { $0.lowerBound <= position && position <= $0.upperBound } ?? false) {
            let word = snapshot.unitRange(at: position, granularity: .word)
            let isWord = snapshot.isOverText(point) && snapshot.text(in: word).contains { !$0.isWhitespace }
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
