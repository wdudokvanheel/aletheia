import AppKit

/// Colors by role, supplied by the host. Layouts carry roles only, so changing
/// the palette is a redraw. Dynamic system colors resolve for the view's
/// appearance at draw time.
public struct Palette: Sendable, Equatable {
    public var background: NSColor
    public var text: NSColor
    public var headingText: NSColor
    public var codeText: NSColor
    public var codeBackground: NSColor
    /// Block quote text and status messages.
    public var mutedText: NSColor

    public init(background: NSColor, text: NSColor, headingText: NSColor, codeText: NSColor,
                codeBackground: NSColor, mutedText: NSColor) {
        self.background = background
        self.text = text
        self.headingText = headingText
        self.codeText = codeText
        self.codeBackground = codeBackground
        self.mutedText = mutedText
    }

    /// System colors that follow light and dark mode.
    public static let standard = Palette(
        background: .textBackgroundColor,
        text: .textColor,
        headingText: .textColor,
        codeText: .textColor,
        codeBackground: .textColor.withAlphaComponent(0.07),
        mutedText: .secondaryLabelColor
    )

    func color(for role: TextRole) -> NSColor {
        switch role {
        case .body: text
        case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6: headingText
        case .code: codeText
        case .quote: mutedText
        }
    }
}
