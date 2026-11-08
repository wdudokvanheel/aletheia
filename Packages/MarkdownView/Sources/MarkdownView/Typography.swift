import AppKit
import CoreText

/// Fonts, line heights, and spacing, matching the WebKit preview stylesheet:
/// 15 pt body at 1.6 line height, browser heading scale at 1.3 line height,
/// and code at 0.9 em with 4 pt of padding beside inline code. Immutable and
/// safe to share across threads.
public final class Typography: @unchecked Sendable {
    public static let standard = Typography()

    public let bodyFontSize: CGFloat = 15
    /// Padding around the text column.
    public let topInset: CGFloat = 16
    public let bottomInset: CGFloat = 40
    public let horizontalInset: CGFloat = 24
    public let maximumColumnWidth: CGFloat = 900
    public let codeBlockPadding: CGFloat = 12
    /// Horizontal padding inside an inline code background.
    public let inlineCodePadding: CGFloat = 4

    let minimumColumnWidth: CGFloat = 60
    private let headingScale: [CGFloat] = [2, 1.5, 1.17, 1, 0.83, 0.67]
    private let headingBottomMargin: [CGFloat] = [0.67, 0.83, 1, 1.33, 1.67, 2.33]

    /// Each role's own font, indexed by `TextRole.rawValue`.
    let fonts: [CTFont]
    let lineHeights: [CGFloat]
    /// Indexed by `Self.index(role, styles)`.
    private let styledFonts: [CTFont]
    private let styledAttributes: [CFDictionary]

    private init() {
        var fonts: [CTFont] = []
        var lineHeights: [CGFloat] = []
        var styledFonts: [CTFont] = []
        var styledAttributes: [CFDictionary] = []
        // Keeps runs with the same font but different inline styles apart, so
        // each can be colored and decorated.
        let styleAttribute = "MarkdownViewInlineStyle" as CFString
        for role in TextRole.allCases {
            let size: CGFloat
            let lineHeight: CGFloat
            switch role {
            case .body, .quote:
                size = bodyFontSize
                lineHeight = size * 1.6
            case .code:
                size = bodyFontSize * 0.9
                lineHeight = size * 1.6
            default:
                size = bodyFontSize * headingScale[Int(role.rawValue - TextRole.heading1.rawValue)]
                lineHeight = size * 1.3
            }
            let isHeading = TextRole.heading1.rawValue...TextRole.heading6.rawValue ~= role.rawValue
            // Bold, italic, and monospaced variants, indexed by those bits.
            let variants = (0..<8).map { traits in
                let monospaced = role == .code || traits & 4 != 0
                return Self.makeFont(size: monospaced && role != .code ? size * 0.9 : size,
                                     bold: isHeading || traits & 1 != 0, italic: traits & 2 != 0,
                                     monospaced: monospaced)
            }
            fonts.append(variants[0])
            lineHeights.append(lineHeight)
            for raw in 0..<InlineStyle.combinations {
                let styles = InlineStyle(rawValue: UInt8(raw))
                let font = variants[(styles.contains(.strong) ? 1 : 0) | (styles.contains(.emphasis) ? 2 : 0)
                                    | (styles.contains(.code) ? 4 : 0)]
                styledFonts.append(font)
                var attributes: [CFString: Any] = [kCTFontAttributeName: font,
                                                   kCTForegroundColorFromContextAttributeName: kCFBooleanTrue!]
                if !styles.isEmpty { attributes[styleAttribute] = NSNumber(value: styles.rawValue) }
                styledAttributes.append(attributes as CFDictionary)
            }
        }
        self.fonts = fonts
        self.lineHeights = lineHeights
        self.styledFonts = styledFonts
        self.styledAttributes = styledAttributes
    }

    private static func makeFont(size: CGFloat, bold: Bool, italic: Bool, monospaced: Bool) -> CTFont {
        var font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular) as CTFont
            : CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
        if italic, let italicFont = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic) {
            font = italicFont
        }
        return font
    }

    private static func index(_ role: TextRole, _ styles: InlineStyle) -> Int {
        Int(role.rawValue) * InlineStyle.combinations + Int(styles.rawValue) % InlineStyle.combinations
    }

    /// The font for a role with inline styles: bold for strong, italic for
    /// emphasis, and monospaced at 0.9 em for code.
    func font(_ role: TextRole, _ styles: InlineStyle) -> CTFont { styledFonts[Self.index(role, styles)] }

    /// Core Text attributes for a role with inline styles. Glyphs take their
    /// color from the context, which the view sets per run at draw time.
    func attributes(_ role: TextRole, _ styles: InlineStyle) -> CFDictionary {
        styledAttributes[Self.index(role, styles)]
    }

    func lineHeight(_ role: TextRole) -> CGFloat { lineHeights[Int(role.rawValue)] }

    /// Vertical margins around a block, collapsed with its neighbor's as in CSS.
    func margins(for kind: MarkdownBlock.Kind) -> (top: CGFloat, bottom: CGFloat) {
        switch kind {
        case .heading(let level):
            let index = min(max(level, 1), 6) - 1
            let size = bodyFontSize * headingScale[index]
            return (size * 1.4, size * headingBottomMargin[index])
        case .codeBlock:
            return (bodyFontSize * 0.9, bodyFontSize * 0.9)
        case .thematicBreak:
            return (bodyFontSize * 0.5, bodyFontSize * 0.5)
        case .table, .htmlBlock:
            return (0, 0)
        case .paragraph, .blockQuote, .list, .other:
            return (bodyFontSize, bodyFontSize)
        }
    }

    /// The text column for a view width: inset, capped, and centered.
    public func column(forWidth width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let columnWidth = min(max(width - 2 * horizontalInset, minimumColumnWidth), maximumColumnWidth)
        return (max(horizontalInset, ((width - columnWidth) / 2).rounded(.down)), columnWidth)
    }
}
