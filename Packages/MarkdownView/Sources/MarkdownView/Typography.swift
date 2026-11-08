import AppKit
import CoreText

/// Fonts, line heights, and spacing, matching the WebKit preview stylesheet:
/// 15 pt body at 1.6 line height, browser heading scale at 1.3 line height,
/// and code at 0.9 em. Immutable and safe to share across threads.
public final class Typography: @unchecked Sendable {
    public static let standard = Typography()

    public let bodyFontSize: CGFloat = 15
    /// Padding around the text column.
    public let topInset: CGFloat = 16
    public let bottomInset: CGFloat = 40
    public let horizontalInset: CGFloat = 24
    public let maximumColumnWidth: CGFloat = 900
    public let codeBlockPadding: CGFloat = 12

    let minimumColumnWidth: CGFloat = 60
    private let headingScale: [CGFloat] = [2, 1.5, 1.17, 1, 0.83, 0.67]
    private let headingBottomMargin: [CGFloat] = [0.67, 0.83, 1, 1.33, 1.67, 2.33]

    /// Indexed by `TextRole.rawValue`.
    let fonts: [CTFont]
    let lineHeights: [CGFloat]
    let attributes: [CFDictionary]

    private init() {
        var fonts: [CTFont] = []
        var lineHeights: [CGFloat] = []
        for role in TextRole.allCases {
            let font: CTFont
            let lineHeight: CGFloat
            switch role {
            case .body, .quote:
                font = CTFontCreateUIFontForLanguage(.system, bodyFontSize, nil)!
                lineHeight = bodyFontSize * 1.6
            case .code:
                font = NSFont.monospacedSystemFont(ofSize: bodyFontSize * 0.9, weight: .regular) as CTFont
                lineHeight = bodyFontSize * 0.9 * 1.6
            default:
                let size = bodyFontSize * headingScale[Int(role.rawValue - TextRole.heading1.rawValue)]
                font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)!
                lineHeight = size * 1.3
            }
            fonts.append(font)
            lineHeights.append(lineHeight)
        }
        self.fonts = fonts
        self.lineHeights = lineHeights
        attributes = fonts.map { font in
            [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: kCFBooleanTrue!] as CFDictionary
        }
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
