import AppKit
import CoreText

/// Fonts, line heights, and spacing, starting from the WebKit preview
/// stylesheet (`Resources/Preview/preview.css`) and WebKit's default styles
/// for what it leaves out. CSS pixels are points. Immutable and safe to share
/// across threads; every value below is here to be reviewed and tuned. The
/// table gives `standard`'s values; `init(scale:)` multiplies every size in
/// points.
///
/// | Metric | Value | Source |
/// | --- | --- | --- |
/// | Body text | 15 pt, line height 1.6 (24 pt) | stylesheet `:root` |
/// | Headings h1–h6 | 2, 1.5, 1.17, 1, 0.83, 0.67 em, bold, line height 1.3 | default `h1`–`h6`, stylesheet |
/// | Heading margins | 1.4 em above; 0.67, 0.83, 1, 1.33, 1.67, 2.33 em below, of the heading size | stylesheet, default |
/// | Paragraph, list, and quote margins | 15 pt (1 em) above and below; nested lists none | default `p`, `ul`, `ol`, `blockquote` |
/// | Tight list paragraphs | no margins | cmark's tight lists, no `<p>` |
/// | Column | 900 pt at most, insets 16 top, 24 sides, 40 bottom | stylesheet `main` |
/// | List indent | 40 pt per level | default `padding-inline-start` |
/// | List markers | 6 pt from the text; bullets 5 pt (disc, circle, then square by depth); numbers in the body font | markers drawn outside, like `list-style-position: outside` |
/// | Task boxes | 13 pt, in place of the marker | stylesheet keeps the bullet too; see the plan |
/// | Block quotes | 3 pt bar, text 16 pt past it, 40 pt right margin, muted text | stylesheet `blockquote`, default right margin |
/// | Code blocks | monospaced 0.9 em of 0.9 em (12.15 pt) in 21.6 pt lines (1.6 of 0.9 em), 12 pt padding, 4 pt radius, 13.5 pt margins (1 em of 0.9 em), tabs every 8 spaces, no wrapping | stylesheet `pre`, `pre code`, default `pre` margins and `tab-size` |
/// | Inline code | 0.9 em, 4 pt beside it | stylesheet `code` |
/// | Thematic breaks | 1 pt rule, 7.5 pt (0.5 em) margins | stylesheet `hr`, default margins |
/// | Tables | 1 pt borders in the muted color, cells padded 6 pt above and below and 12 pt beside, text vertically centered, no margins or backgrounds | stylesheet `table`, `th, td`; default `vertical-align: middle` |
/// | Table header cells | bold, centered unless the column is aligned | default `th` |
/// | Table cells | not kerned: kerning costs about ten times the rest of shaping, which tables with thousands of cells cannot afford, and Core Text already drops it for any text over about 10,000 characters | — |
/// | Table columns | as wide as their widest cell; when the table is wider than the column, the space is shared in proportion to those widths, columns no wider than an equal share keep their width, none gets under 60 pt, and cells wrap; when even that does not fit, it scrolls on its own, with columns at their natural width up to half the space | stylesheet `overflow-x: auto` |
///
/// The stylesheet sets code block text to 0.9 em twice (`pre` and `pre code`),
/// so it is 12.15 pt, while the `pre`'s own 13.5 pt font sets its 21.6 pt
/// lines, as in WebKit.
public final class Typography: @unchecked Sendable {
    public static let standard = Typography(scale: 1)
    /// Marks alt text, whose attributes are otherwise those of the text
    /// around it, so Core Text keeps it in runs of its own to color.
    nonisolated(unsafe) static let imageAttribute = "MarkdownViewImage" as CFString

    /// The factor every size in points is multiplied by.
    public let scale: CGFloat
    public let bodyFontSize: CGFloat
    /// Line height as a multiple of the font size: body, quote, and code text.
    public let lineHeightMultiple: CGFloat = 1.6
    public let headingLineHeightMultiple: CGFloat = 1.3
    /// Heading sizes as multiples of the body size, h1 to h6.
    public let headingScale: [CGFloat] = [2, 1.5, 1.17, 1, 0.83, 0.67]
    /// Margins above headings, as a multiple of the heading's size.
    public let headingTopMargin: CGFloat = 1.4
    /// Margins below headings, as multiples of the heading's size, h1 to h6.
    public let headingBottomMargins: [CGFloat] = [0.67, 0.83, 1, 1.33, 1.67, 2.33]
    /// Code font size as a multiple of the size around it; code block text
    /// gets it twice.
    public let codeScale: CGFloat = 0.9

    /// Padding around the text column.
    public let topInset: CGFloat
    public let bottomInset: CGFloat
    public let horizontalInset: CGFloat
    public let maximumColumnWidth: CGFloat

    /// Margins above and below paragraphs, top-level lists, and block quotes.
    public let blockSpacing: CGFloat
    /// Margins above and below code blocks: 1 em of their font.
    public let codeBlockMargin: CGFloat
    public let codeBlockPadding: CGFloat
    public let codeBlockCornerRadius: CGFloat
    /// Tab stops in code blocks, in spaces of the code font.
    public let codeTabWidth = 8
    /// Horizontal padding inside an inline code background.
    public let inlineCodePadding: CGFloat
    public let ruleThickness: CGFloat
    public let ruleMargin: CGFloat

    /// Table borders, collapsed between cells.
    public let tableBorderWidth: CGFloat
    public let tableCellVerticalPadding: CGFloat
    public let tableCellHorizontalPadding: CGFloat
    /// The narrowest a column's text gets when its table is wider than the
    /// space it has; a column that is narrower by nature keeps its width.
    public let tableMinimumColumnWidth: CGFloat

    /// How far each list level indents its items' text.
    public let listIndent: CGFloat
    /// The gap between a list marker or task box and the item's text.
    public let listMarkerSpacing: CGFloat
    /// The diameter of a disc or circle bullet and the side of a square one.
    public let bulletSize: CGFloat
    public let taskBoxSize: CGFloat
    public let taskBoxCornerRadius: CGFloat

    public let quoteBarWidth: CGFloat
    /// The space between a quote's bar and its text.
    public let quotePadding: CGFloat
    /// The space a quote leaves on its right, like WebKit's default margin.
    public let quoteRightMargin: CGFloat

    /// The narrowest column, and the narrowest text in deeply nested blocks.
    let minimumColumnWidth: CGFloat

    /// Each role's own font, indexed by `TextRole.rawValue`.
    let fonts: [CTFont]
    let lineHeights: [CGFloat]
    /// Indexed by `Self.index(role, styles)`.
    private let styledFonts: [CTFont]
    private let styledAttributes: [CFDictionary]
    /// The same without kerning, for table cells.
    private let unkernedAttributes: [CFDictionary]
    /// Left-to-right and right-to-left paragraphs.
    private let directionStyles: [CTParagraphStyle]

    /// Every size above in points, multiplied by `scale`: 2 doubles the
    /// fonts, line heights, spacing, and column width, while the multiples
    /// and ratios stay. `standard` is scale 1. A scale that is not positive
    /// and finite is 1.
    public init(scale: CGFloat) {
        let scale = scale.isFinite && scale > 0 ? scale : 1
        self.scale = scale
        bodyFontSize = 15 * scale
        topInset = 16 * scale
        bottomInset = 40 * scale
        horizontalInset = 24 * scale
        maximumColumnWidth = 900 * scale
        blockSpacing = 15 * scale
        codeBlockMargin = 13.5 * scale
        codeBlockPadding = 12 * scale
        codeBlockCornerRadius = 4 * scale
        inlineCodePadding = 4 * scale
        ruleThickness = 1 * scale
        ruleMargin = 7.5 * scale
        tableBorderWidth = 1 * scale
        tableCellVerticalPadding = 6 * scale
        tableCellHorizontalPadding = 12 * scale
        tableMinimumColumnWidth = 60 * scale
        listIndent = 40 * scale
        listMarkerSpacing = 6 * scale
        bulletSize = 5 * scale
        taskBoxSize = 13 * scale
        taskBoxCornerRadius = 3 * scale
        quoteBarWidth = 3 * scale
        quotePadding = 16 * scale
        quoteRightMargin = 40 * scale
        minimumColumnWidth = 60 * scale
        var fonts: [CTFont] = []
        var lineHeights: [CGFloat] = []
        var styledFonts: [CTFont] = []
        var styledAttributes: [CFDictionary] = []
        var unkernedAttributes: [CFDictionary] = []
        // Keeps runs with the same font but different inline styles apart, so
        // each can be colored and decorated.
        let styleAttribute = "MarkdownViewInlineStyle" as CFString
        for role in TextRole.allCases {
            let size: CGFloat
            let lineHeight: CGFloat
            switch role {
            case .body, .quote:
                size = bodyFontSize
                lineHeight = size * lineHeightMultiple
            case .code:
                // `pre code` inside `pre`: the text is 0.9 em of the pre's 0.9 em.
                size = bodyFontSize * codeScale * codeScale
                lineHeight = bodyFontSize * codeScale * lineHeightMultiple
            default:
                size = bodyFontSize * headingScale[Int(role.rawValue - TextRole.heading1.rawValue)]
                lineHeight = size * headingLineHeightMultiple
            }
            let isHeading = TextRole.heading1.rawValue...TextRole.heading6.rawValue ~= role.rawValue
            // Bold, italic, and monospaced variants, indexed by those bits.
            let codeScale = codeScale
            let variants = (0..<8).map { traits in
                let monospaced = role == .code || traits & 4 != 0
                return Self.makeFont(size: monospaced && role != .code ? size * codeScale : size, scale: scale,
                                     bold: isHeading || traits & 1 != 0, italic: traits & 2 != 0,
                                     monospaced: monospaced)
            }
            fonts.append(variants[0])
            lineHeights.append(lineHeight)
            // Code block lines are whole paragraphs, so they can carry their own tab stops.
            let tabs = role == .code ? Self.tabStops(every: codeTabWidth, of: variants[0]) : nil
            for raw in 0..<InlineStyle.combinations {
                let styles = InlineStyle(rawValue: UInt8(raw))
                let font = variants[(styles.contains(.strong) ? 1 : 0) | (styles.contains(.emphasis) ? 2 : 0)
                                    | (styles.contains(.code) ? 4 : 0)]
                styledFonts.append(font)
                var attributes: [CFString: Any] = [kCTFontAttributeName: font,
                                                   kCTForegroundColorFromContextAttributeName: kCFBooleanTrue!]
                if !styles.isEmpty { attributes[styleAttribute] = NSNumber(value: styles.rawValue) }
                if let tabs { attributes[kCTParagraphStyleAttributeName] = tabs }
                styledAttributes.append(attributes as CFDictionary)
                attributes[kCTKernAttributeName] = 0 as NSNumber
                unkernedAttributes.append(attributes as CFDictionary)
            }
        }
        self.fonts = fonts
        self.lineHeights = lineHeights
        self.styledFonts = styledFonts
        self.styledAttributes = styledAttributes
        self.unkernedAttributes = unkernedAttributes
        directionStyles = [CTWritingDirection.leftToRight, .rightToLeft].map { direction in
            var direction = direction
            return withUnsafeBytes(of: &direction) { bytes in
                CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .baseWritingDirection,
                                                                valueSize: MemoryLayout<CTWritingDirection>.size,
                                                                value: bytes.baseAddress!)], 1)
            }
        }
    }

    /// A paragraph style that sets the base writing direction.
    func paragraphStyle(_ isRightToLeft: Bool) -> CTParagraphStyle { directionStyles[isRightToLeft ? 1 : 0] }

    /// A system font. Scaled, it keeps the optical size of its unscaled
    /// size: the system font is narrower at larger sizes, which would break
    /// lines elsewhere than at scale 1.
    private static func makeFont(size: CGFloat, scale: CGFloat, bold: Bool, italic: Bool, monospaced: Bool) -> CTFont {
        var font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular) as CTFont
            : CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
        if scale != 1 {
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(font), [kCTFontOpticalSizeAttribute: size / scale as NSNumber] as CFDictionary)
            font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        if italic, let italicFont = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic) {
            font = italicFont
        }
        return font
    }

    /// A paragraph style with tab stops every `spaces` spaces of `font`, as
    /// CSS `tab-size` sets them, left to right as code always is.
    private static func tabStops(every spaces: Int, of font: CTFont) -> CTParagraphStyle {
        var glyph = CGGlyph(0)
        var space = UniChar(0x20)
        CTFontGetGlyphsForCharacters(font, &space, &glyph, 1)
        var interval = CGFloat(spaces) * CGFloat(CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1))
        var stops = [CTTextTab]() as CFArray
        var direction = CTWritingDirection.leftToRight
        return withUnsafeBytes(of: &interval) { intervalBytes in
            withUnsafeBytes(of: &stops) { stopsBytes in
                withUnsafeBytes(of: &direction) { directionBytes in
                    let settings = [
                        CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size,
                                                value: intervalBytes.baseAddress!),
                        CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size,
                                                value: stopsBytes.baseAddress!),
                        CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size,
                                                value: directionBytes.baseAddress!)
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
    }

    private static func index(_ role: TextRole, _ styles: InlineStyle) -> Int {
        Int(role.rawValue) * InlineStyle.combinations + Int(styles.rawValue) % InlineStyle.combinations
    }

    /// The font for a role with inline styles: bold for strong, italic for
    /// emphasis, and monospaced at 0.9 em for code.
    func font(_ role: TextRole, _ styles: InlineStyle) -> CTFont { styledFonts[Self.index(role, styles)] }

    /// Core Text attributes for a role with inline styles. Glyphs take their
    /// color from the context, which the view sets per run at draw time.
    func attributes(_ role: TextRole, _ styles: InlineStyle, kerned: Bool = true) -> CFDictionary {
        (kerned ? styledAttributes : unkernedAttributes)[Self.index(role, styles)]
    }

    func lineHeight(_ role: TextRole) -> CGFloat { lineHeights[Int(role.rawValue)] }

    /// Vertical margins around a leaf block, collapsed with every margin
    /// next to it as in CSS.
    func margins(for segment: BlockSegment) -> (top: CGFloat, bottom: CGFloat) {
        switch segment.kind {
        case .heading:
            let index = min(max(Int(segment.level), 1), 6) - 1
            let size = bodyFontSize * headingScale[index]
            return (size * headingTopMargin, size * headingBottomMargins[index])
        case .paragraph: return segment.isTight ? (0, 0) : (blockSpacing, blockSpacing)
        case .code: return (codeBlockMargin, codeBlockMargin)
        case .rule: return (ruleMargin, ruleMargin)
        case .table, .emptyItem: return (0, 0)
        }
    }

    /// The margin above and below a container, collapsed like a leaf's.
    func margin(for container: BlockContainer.Kind) -> CGFloat {
        switch container {
        case .quote, .list: blockSpacing
        case .nestedList, .item: 0
        }
    }

    /// The text column for a view width: inset, capped, and centered.
    public func column(forWidth width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let columnWidth = min(max(width - 2 * horizontalInset, minimumColumnWidth), maximumColumnWidth)
        return (max(horizontalInset, ((width - columnWidth) / 2).rounded(.down)), columnWidth)
    }
}
