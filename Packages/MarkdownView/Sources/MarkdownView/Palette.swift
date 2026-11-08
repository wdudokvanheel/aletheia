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
    /// Link text and its underline.
    public var link: NSColor

    public init(background: NSColor, text: NSColor, headingText: NSColor, codeText: NSColor,
                codeBackground: NSColor, mutedText: NSColor, link: NSColor = .linkColor) {
        self.background = background
        self.text = text
        self.headingText = headingText
        self.codeText = codeText
        self.codeBackground = codeBackground
        self.mutedText = mutedText
        self.link = link
    }

    /// System colors that follow light and dark mode.
    public static let standard = Palette(
        background: .textBackgroundColor,
        text: .textColor,
        headingText: .textColor,
        codeText: .textColor,
        // `withAlphaComponent` would resolve `textColor` once, for whatever
        // appearance is current at creation, so build a dynamic color instead.
        codeBackground: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? 1 : 0, alpha: 0.07)
        },
        mutedText: .secondaryLabelColor,
        link: .linkColor
    )

    func color(for role: TextRole) -> NSColor {
        switch role {
        case .body: text
        case .heading1, .heading2, .heading3, .heading4, .heading5, .heading6: headingText
        case .code: codeText
        case .quote: mutedText
        }
    }

    /// The color of text in `role` with `styles`. Inline code keeps the color
    /// around it, and headings and code in a block quote take its color, as
    /// in the WebKit stylesheet.
    func color(for role: TextRole, styles: InlineStyle) -> NSColor {
        styles.contains(.link) ? link : color(for: styles.contains(.quoted) ? .quote : role)
    }

    /// Draw-time colors indexed by `ColorIndex`: one per role, then links.
    var cgColors: [CGColor] {
        TextRole.allCases.map { color(for: $0).cgColor } + [link.cgColor]
    }
}

/// An index into `Palette.cgColors`.
enum ColorIndex {
    static let link = UInt8(TextRole.allCases.count)

    static func of(_ role: TextRole, _ styles: InlineStyle) -> UInt8 {
        styles.contains(.link) ? link : styles.contains(.quoted) ? TextRole.quote.rawValue : role.rawValue
    }
}
