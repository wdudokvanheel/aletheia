import CoreGraphics
import CoreText
import Foundation

/// Lays out one block's segments top to bottom, inside the indents of their
/// lists and quotes, with the margins that meet between two segments
/// collapsed to the largest, as CSS collapses them through containers
/// without borders or padding above and below.
struct BlockLayoutBuilder {
    let block: MarkdownBlock
    let textLength: Int
    let columnWidth: CGFloat
    let typography: Typography
    /// Estimates measure heights from text lengths and build no lines.
    let isEstimate: Bool
    /// Raw HTML and empty front matter take no space.
    let isDropped: Bool
    /// An earlier layout whose tables lend rows and natural widths.
    var hint: BlockLayout?
    /// How much of a table block's table to lay out.
    var tableRows = TableRows.all
    /// The natural sizes of the images loaded so far.
    var images = ImageSizes.none
    private(set) var isCancelled = false
    private(set) var lines: [LineLayout] = []
    private(set) var boxes: [BlockBox] = []
    private(set) var markers: [MarkerLayout] = []
    private(set) var codeBlocks: [CodeBlockLayout] = []
    private(set) var tables: [TableLayout] = []
    /// See `BlockLayout`.
    private(set) var imageSizes: [CGSize?] = []
    private(set) var imageWidths: [CGFloat] = []
    private(set) var drawsImages = false
    /// The display text, then its attributed string and typesetter, made
    /// when a segment first needs them: tables lay out cell by cell, so a
    /// table block never shapes its whole text at once.
    private var text: CFString?
    private var string: CFAttributedString?
    private var typesetter: CTTypesetter?
    /// The images of the typesetter's string, fitted to `imageWidth`. A
    /// block with loaded images gets a typesetter per text width.
    private var imageText: ImageText?
    private var imageWidth: CGFloat = 0
    /// The style run the next line starts in.
    private var runIndex = 0
    /// UTF-16 offsets of the display text's newlines, for estimates.
    private var newlines: [Int]?

    init(block: MarkdownBlock, textLength: Int, columnWidth: CGFloat, typography: Typography, isEstimate: Bool) {
        self.block = block
        self.textLength = textLength
        self.columnWidth = columnWidth
        self.typography = typography
        self.isEstimate = isEstimate
        isDropped = block.kind == .htmlBlock || (block.isFrontMatter && textLength == 0)
    }

    /// A list or quote that contains the segment being laid out.
    private struct OpenContainer {
        let index: Int
        /// One past its last segment.
        let end: Int
        /// The left and right edges of its content, relative to the column.
        let left: CGFloat
        let right: CGFloat
        /// Where a quote's bar goes: the left edge of the content around it.
        let barX: CGFloat
        let top: CGFloat
        let isQuoted: Bool
    }

    /// The block's height and its top and bottom margins. Stops early, with
    /// `isCancelled` set, when `isCancelled` reports true during a table.
    mutating func build(isCancelled: () -> Bool) -> (height: CGFloat, top: CGFloat, bottom: CGFloat) {
        guard !isDropped else { return (0, 0, 0) }
        let segments = block.segments.isEmpty ? Self.segments(of: block, textLength: textLength) : block.segments
        let containers = block.containers
        if !isEstimate, textLength > 0 { text = BlockLayout.makeText(block.text, length: textLength) }
        if !isEstimate, !block.images.isEmpty {
            imageSizes = block.images.map { BlockLayout.size($0.source, in: images) }
            imageWidths = [CGFloat](repeating: 0, count: block.images.count)
        }
        // A segment's lines run to where the next text starts, so the newline
        // separating them ends its last line.
        var lineEnds = [Int](repeating: textLength, count: segments.count)
        var next = textLength
        for index in segments.indices.reversed() {
            lineEnds[index] = next
            if !segments[index].range.isEmpty { next = segments[index].range.lowerBound }
        }
        var open: [OpenContainer] = []
        var opening: [Int] = []
        var pendingMarkers: [(marker: ListMarker, textLeft: CGFloat, isQuoted: Bool)] = []
        var nextContainer = 0
        var y: CGFloat = 0
        var marginTop: CGFloat = 0
        var pendingMargin: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            // Margins above: the segment's and those of the containers it opens.
            var margin = typography.margins(for: segment).top
            opening.removeAll(keepingCapacity: true)
            while nextContainer < containers.count, containers[nextContainer].segments.lowerBound <= index {
                margin = max(margin, typography.margin(for: containers[nextContainer].kind))
                if !containers[nextContainer].segments.isEmpty { opening.append(nextContainer) }
                nextContainer += 1
            }
            if index == 0 { marginTop = margin } else { y += max(pendingMargin, margin) }
            for containerIndex in opening {
                let container = containers[containerIndex]
                let parent = open.last
                let parentLeft = parent?.left ?? 0
                var left = parentLeft
                var right = parent?.right ?? 0
                switch container.kind {
                case .quote:
                    left += typography.quoteBarWidth + typography.quotePadding
                    right += typography.quoteRightMargin
                case .list, .nestedList:
                    left += typography.listIndent
                case .item:
                    if container.marker != .none {
                        pendingMarkers.append((container.marker, parentLeft, parent?.isQuoted == true))
                    }
                }
                (left, right) = clamped(left, right)
                open.append(OpenContainer(index: containerIndex, end: container.segments.upperBound, left: left,
                                          right: right, barX: parentLeft, top: y,
                                          isQuoted: container.kind == .quote || parent?.isQuoted == true))
            }

            let left = open.last?.left ?? 0
            let width = max(columnWidth - left - (open.last?.right ?? 0), 1)
            let range = segment.range.isEmpty ? segment.range : segment.range.lowerBound..<lineEnds[index]
            let firstLine = lines.count
            let height: CGFloat
            switch segment.kind {
            case .paragraph, .heading:
                height = layOutText(range, x: left, width: width, top: y)
            case .table:
                height = layOutTable(range, x: left, width: width, top: y, isCancelled: isCancelled)
                if self.isCancelled { return (0, 0, 0) }
            case .code:
                height = layOutCode(range, x: left, width: width, top: y)
            case .rule:
                height = typography.ruleThickness
                if !isEstimate { boxes.append(BlockBox(kind: .rule, rect: CGRect(x: left, y: y, width: width, height: height))) }
            case .emptyItem:
                height = typography.lineHeight(.body)
            }
            if !pendingMarkers.isEmpty {
                // Markers sit on the first line of their item, wherever it is.
                let baseline = firstLine < lines.count ? lines[firstLine].baseline : y + bodyBaselineOffset
                for pending in pendingMarkers where !isEstimate {
                    addMarker(pending.marker, textLeft: pending.textLeft, baseline: baseline, isQuoted: pending.isQuoted)
                }
                pendingMarkers.removeAll(keepingCapacity: true)
            }
            y += height

            // Margins below: the segment's and those of the containers it closes.
            pendingMargin = typography.margins(for: segment).bottom
            while let last = open.last, last.end <= index + 1 {
                open.removeLast()
                let container = containers[last.index]
                pendingMargin = max(pendingMargin, typography.margin(for: container.kind))
                if container.kind == .quote, !isEstimate {
                    boxes.append(BlockBox(kind: .quoteBar, rect: CGRect(x: last.barX, y: last.top,
                                                                        width: typography.quoteBarWidth,
                                                                        height: y - last.top)))
                }
            }
        }
        // Empty containers at the end only add their margins.
        for container in containers[min(nextContainer, containers.count)...] {
            let margin = typography.margin(for: container.kind)
            if segments.isEmpty { marginTop = max(marginTop, margin) }
            pendingMargin = max(pendingMargin, margin)
        }
        return (y, marginTop, pendingMargin)
    }

    /// The one segment of a block without containers, by its kind.
    static func segments(of block: MarkdownBlock, textLength: Int) -> [BlockSegment] {
        let end = Int32(clamping: textLength)
        switch block.kind {
        case .heading(let level): return [BlockSegment(kind: .heading, level: UInt8(min(max(level, 1), 6)), start: 0, end: end)]
        case .codeBlock: return [BlockSegment(kind: .code, start: 0, end: end)]
        case .table: return [BlockSegment(kind: .table, start: 0, end: end)]
        case .thematicBreak: return [BlockSegment(kind: .rule, start: 0, end: 0)]
        case .htmlBlock: return []
        case .paragraph, .blockQuote, .list, .other: return [BlockSegment(kind: .paragraph, start: 0, end: end)]
        }
    }

    /// Edges that leave deeply nested content at least the minimum width:
    /// right margins give way first, then the indent stops growing.
    private func clamped(_ left: CGFloat, _ right: CGFloat) -> (CGFloat, CGFloat) {
        let minimum = min(typography.minimumColumnWidth, columnWidth)
        var left = left
        var right = right
        if columnWidth - left - right < minimum { right = max(columnWidth - left - minimum, 0) }
        if columnWidth - left - right < minimum { left = max(columnWidth - minimum, 0) }
        return (left, right)
    }

    /// From the top of a body line box to its baseline.
    private var bodyBaselineOffset: CGFloat {
        let font = typography.fonts[Int(TextRole.body.rawValue)]
        let ascent = CTFontGetAscent(font)
        return (typography.lineHeight(.body) - ascent - CTFontGetDescent(font)) / 2 + ascent
    }

    // MARK: Lines

    /// Makes the attributed display text and its typesetter, once, with
    /// images fitted to `width`; again for another width when images are
    /// loaded.
    private mutating func prepareTypesetter(width: CGFloat) {
        if typesetter != nil, imageText?.hasLoaded != true || imageWidth == width { return }
        guard let text else { return }
        let images = imageSizes.isEmpty ? nil : ImageText(block: block, sizes: imageSizes, width: width)
        guard let string = BlockLayout.makeString(text, runs: block.styleRuns, typography: typography,
                                                  images: images) else { return }
        self.string = string
        imageText = images
        imageWidth = width
        typesetter = CTTypesetterCreateWithAttributedString(string)
    }

    /// Wraps text with `CTTypesetter` at `width`, one line box per line.
    private mutating func layOutText(_ range: Range<Int>, x: CGFloat, width: CGFloat, top: CGFloat) -> CGFloat {
        guard !range.isEmpty else { return 0 }
        prepareTypesetter(width: width)
        guard let typesetter else { return estimatedHeight(of: range, width: width) }
        var y = top
        var start = range.lowerBound
        while start < range.upperBound {
            let count = max(CTTypesetterSuggestLineBreak(typesetter, start, Double(width)), 1)
            var end = min(start + count, range.upperBound)
            if let imageText { end = min(imageText.lineEnd(end), range.upperBound) }
            y += appendLine(start..<end, x: x, maxX: x + width, top: y, codeBlock: -1).height
            start = end
        }
        recordImageWidths(in: range, width)
        return y - top
    }

    /// Notes `width` as the widest the images in `range` may be.
    private mutating func recordImageWidths(in range: Range<Int>, _ width: CGFloat) {
        guard !imageWidths.isEmpty else { return }
        let images = block.images
        var low = 0
        var high = images.count
        while low < high {
            let mid = (low + high) / 2
            if images[mid].range.lowerBound < range.lowerBound { low = mid + 1 } else { high = mid }
        }
        while low < images.count, images[low].range.upperBound <= range.upperBound {
            imageWidths[low] = width
            low += 1
        }
    }

    /// A code block: its padded background box and one line per source
    /// line, never wrapped, however wide.
    private mutating func layOutCode(_ range: Range<Int>, x: CGFloat, width: CGFloat, top: CGFloat) -> CGFloat {
        let padding = typography.codeBlockPadding
        var y = top + padding
        var widest: CGFloat = 0
        // Code has no images, so any typesetter will do.
        if !range.isEmpty { prepareTypesetter(width: typesetter == nil ? width : imageWidth) }
        if !range.isEmpty, let string {
            var characters = [UniChar](repeating: 0, count: range.count)
            CFStringGetCharacters(CFAttributedStringGetString(string), CFRange(location: range.lowerBound, length: range.count),
                                  &characters)
            let code = Int32(codeBlocks.count)
            var start = 0
            while start < characters.count {
                let end = characters[start...].firstIndex(of: 0x0A).map { $0 + 1 } ?? characters.count
                let line = appendLine((range.lowerBound + start)..<(range.lowerBound + end), x: x + padding,
                                      maxX: x + width - padding, top: y, codeBlock: code)
                widest = max(widest, line.width)
                y += line.height
                start = end
            }
        } else if !range.isEmpty {
            y += CGFloat(newlineCount(inside: range) + 1) * typography.lineHeight(.code)
        }
        y += padding
        if !isEstimate {
            let rect = CGRect(x: x, y: top, width: width, height: y - top)
            boxes.append(BlockBox(kind: .codeBackground, rect: rect))
            codeBlocks.append(CodeBlockLayout(rect: rect, contentWidth: widest + 2 * padding))
        }
        return y - top
    }

    /// Adds the line for `range` with its line box. Returns its height and,
    /// for code lines, the width of its text without trailing whitespace.
    private mutating func appendLine(_ range: Range<Int>, x: CGFloat, maxX: CGFloat, top: CGFloat,
                                     codeBlock: Int32) -> (height: CGFloat, width: CGFloat) {
        guard let typesetter, let string else { return (0, 0) }
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: range.lowerBound, length: range.count))
        // Lines of blocks with images may hold run delegates, of loaded images
        // or of placeholders.
        let hasImages = imageText != nil
        let (layout, width) = BlockLayout.lineLayout(line, range: range, string: CFAttributedStringGetString(string),
                                                     runs: block.styleRuns, runIndex: &runIndex, links: block.links[...],
                                                     linkOffset: 0, x: x, maxX: maxX, top: top, codeBlock: codeBlock,
                                                     typography: typography, hasImages: hasImages)
        if hasImages, !drawsImages { drawsImages = layout.decorations.contains { $0.kind == .image } }
        lines.append(layout)
        return (layout.height, codeBlock >= 0 ? width : 0)
    }

    // MARK: Tables

    /// A table laid out per cell, in a box as wide as the content around
    /// it, which scrolls horizontally when the table is wider. Without its
    /// grid (never expected) it falls back to plain text.
    private mutating func layOutTable(_ range: Range<Int>, x: CGFloat, width: CGFloat, top: CGFloat,
                                      isCancelled: () -> Bool) -> CGFloat {
        let index = tables.count
        guard index < block.tables.count else { return layOutText(range, x: x, width: width, top: top) }
        let structure = block.tables[index]
        if isEstimate { return TableLayout.estimatedHeight(of: structure, typography: typography) }
        guard let text else { return 0 }
        let hintTable = hint.flatMap { index < $0.tables.count ? $0.tables[index] : nil }
        // Images in cells may take the widest text a cell gets: the table's
        // whole width less its borders and padding.
        let border = typography.tableBorderWidth
        let cellWidth = max(width - CGFloat(structure.columnCount) * (border + 2 * typography.tableCellHorizontalPadding)
                            - border, 1)
        let images = imageSizes.isEmpty ? nil : ImageText(block: block, sizes: imageSizes, width: cellWidth)
        recordImageWidths(in: structure.displayRange, cellWidth)
        guard let table = TableLayout.build(structure, block: block, text: text, x: x, top: top, width: width,
                                            scrollIndex: codeBlocks.count, typography: typography, hint: hintTable,
                                            rows: tableRows, images: images, isCancelled: isCancelled) else {
            self.isCancelled = true
            return 0
        }
        tables.append(table)
        codeBlocks.append(CodeBlockLayout(rect: table.rect, contentWidth: table.width, isTable: true))
        return table.rect.height
    }

    // MARK: Markers

    /// A bullet, number, or task box ending `listMarkerSpacing` left of the
    /// item's text, centered on the x-height of the first line.
    private mutating func addMarker(_ marker: ListMarker, textLeft: CGFloat, baseline: CGFloat, isQuoted: Bool) {
        let right = textLeft - typography.listMarkerSpacing
        let body = typography.fonts[Int(TextRole.body.rawValue)]
        let middle = baseline - CTFontGetXHeight(body) / 2
        let color = isQuoted ? TextRole.quote.rawValue : TextRole.body.rawValue
        func square(_ size: CGFloat) -> CGRect {
            CGRect(x: (right - size).rounded(), y: (middle - size / 2).rounded(), width: size, height: size)
        }
        switch marker {
        case .none:
            return
        case .bullet(let level):
            markers.append(MarkerLayout(kind: level == 0 ? .disc : level == 1 ? .circle : .square,
                                        rect: square(typography.bulletSize), baseline: baseline, color: color))
        case .number(let number):
            guard let text = CFAttributedStringCreate(nil, "\(number)." as CFString, typography.attributes(.body, []))
            else { return }
            let line = CTLineCreateWithAttributedString(text)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            markers.append(MarkerLayout(kind: .number(line), rect: CGRect(x: right - width, y: baseline - ascent,
                                                                         width: width, height: ascent + descent),
                                        baseline: baseline, color: color))
        case .task(let checked):
            markers.append(MarkerLayout(kind: .task(checked: checked), rect: square(typography.taskBoxSize),
                                        baseline: baseline, color: color))
        }
    }

    // MARK: Estimates

    private mutating func estimatedHeight(of range: Range<Int>, width: CGFloat) -> CGFloat {
        let runs = block.styleRuns
        let runIndex = BlockLayout.styleRunIndex(in: runs, at: range.lowerBound)
        let role = runIndex < runs.count ? runs[runIndex].role : .body
        let averageCharacterWidth = CTFontGetSize(typography.fonts[Int(role.rawValue)]) * (role == .code ? 0.6 : 0.5)
        let wrapped = CGFloat(range.count) * averageCharacterWidth / width
        return CGFloat(newlineCount(inside: range) + 1 + Int(wrapped)) * typography.lineHeight(role)
    }

    /// The newlines in `range` before its last character, which is the
    /// separator after a segment.
    private mutating func newlineCount(inside range: Range<Int>) -> Int {
        if newlines == nil {
            var offsets: [Int] = []
            var offset = 0
            for unit in block.text.utf16 {
                if unit == 0x0A { offsets.append(offset) }
                offset += 1
            }
            newlines = offsets
        }
        let offsets = newlines ?? []
        func firstIndex(atOrAfter target: Int) -> Int {
            var low = 0
            var high = offsets.count
            while low < high {
                let mid = (low + high) / 2
                if offsets[mid] < target { low = mid + 1 } else { high = mid }
            }
            return low
        }
        return max(firstIndex(atOrAfter: range.upperBound - 1) - firstIndex(atOrAfter: range.lowerBound), 0)
    }
}
