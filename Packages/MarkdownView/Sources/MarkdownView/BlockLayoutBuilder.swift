import CoreGraphics
import CoreText
import Foundation
import os

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
    /// Whether the lines are about to be drawn, rather than laid out ahead;
    /// see `LineSet.seal(isWarm:)`.
    var linesWarm = true
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
    /// The display text, and the window of it being typeset, made when a
    /// segment first needs it: tables lay out cell by cell, so a table
    /// block never shapes its whole text at once.
    private var text: CFString?
    private var window: TextWindow?
    /// Paragraphs whose direction is set rather than left to Core Text.
    private var directions: [ParagraphDirection] = []
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
        // Every direction first: a window holds the paragraphs after the
        // one it opens for.
        var isRightToLeft = [Bool](repeating: false, count: segments.count)
        if let text, TextDirection.hasRightToLeft(text, 0..<textLength) {
            for (index, segment) in segments.enumerated() where segment.kind == .paragraph || segment.kind == .heading {
                isRightToLeft[index] = direction(of: segment.range)
            }
        }
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
                height = layOutText(range, x: left, width: width, top: y, isRightToLeft: isRightToLeft[index])
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

    /// Whether the paragraph in `range` reads right to left, by its first
    /// strong character. One with any right-to-left text gets its
    /// direction set, so lines after a hard break keep it.
    private mutating func direction(of range: Range<Int>) -> Bool {
        guard let text, !range.isEmpty else { return false }
        let found = TextDirection.scan(text, range)
        if found.hasRightToLeft {
            directions.append(ParagraphDirection(range: range.lowerBound..<min(range.upperBound + 1, textLength),
                                                 isRightToLeft: found.isRightToLeft))
        }
        return found.isRightToLeft
    }

    /// The window to typeset a line starting at `start` with, at text
    /// `width`, when the line's paragraph (up to Core Text, text between
    /// newlines) starts at `paragraphStart`: the current one while it
    /// reaches far enough past `start`, fits its images to `width`, and
    /// holds less than `advance` of the paragraph before `start`; or else a
    /// new one starting there.
    private mutating func window(at start: Int, width: CGFloat, paragraphStart: Int) -> TextWindow? {
        let advance = advance
        if let window, window.range.lowerBound <= start,
           window.range.upperBound == textLength || window.range.upperBound - start >= window.reach,
           window.images?.hasLoaded != true || window.imageWidth == width,
           start - max(window.range.lowerBound, paragraphStart) < advance {
            return window
        }
        // Deep in a long paragraph, a window holds two advances of it.
        return openWindow(at: start, width: width,
                          length: start - paragraphStart >= advance ? 2 * advance : TextWindow.length)
    }

    /// How much of a paragraph a window holds before a line it breaks:
    /// Core Text looks back that far for each break. Short lines (narrow
    /// columns, emoji) make each break cost as much as a long one, so
    /// windows move on sooner.
    private var advance: Int {
        let lineLength = lines.isEmpty ? TextWindow.advance : lines.last!.range.upperBound / lines.count
        return min(max(16 * lineLength, TextWindow.advance / 16), TextWindow.advance)
    }

    private mutating func openWindow(at start: Int, width: CGFloat, reaching end: Int = 0,
                                     length windowLength: Int = TextWindow.length) -> TextWindow? {
        guard let text else { return nil }
        let images = imageSizes.isEmpty ? nil : ImageText(block: block, sizes: imageSizes, width: width)
        guard let window = TextWindow(text: text, block: block, start: start, reaching: end, length: textLength,
                                      windowLength: windowLength, typography: typography,
                                      images: images, imageWidth: width, directions: directions,
                                      isWarm: linesWarm) else { return nil }
        self.window = window
        return window
    }

    /// Wraps text with `CTTypesetter` at `width`, one line box per line.
    /// Long text is typeset in windows: Core Text's line breaking looks back
    /// to the start of the paragraph, so one typesetter over a paragraph of
    /// a million characters takes minutes, and past about 10,000 it also
    /// stops kerning.
    private mutating func layOutText(_ range: Range<Int>, x: CGFloat, width: CGFloat, top: CGFloat,
                                     isRightToLeft: Bool = false) -> CGFloat {
        guard !range.isEmpty else { return 0 }
        guard text != nil,
              var window = window(at: range.lowerBound, width: width, paragraphStart: range.lowerBound) else {
            return estimatedHeight(of: range, width: width)
        }
        var y = top
        var start = range.lowerBound
        var paragraphStart = start
        while start < range.upperBound {
            if let current = self.window(at: start, width: width, paragraphStart: paragraphStart) { window = current }
            var count = max(CTTypesetterSuggestLineBreak(window.typesetter, start - window.range.lowerBound,
                                                         Double(width)), 1)
            if start + count >= window.range.upperBound, window.range.upperBound < textLength,
               window.range.lowerBound < start, let fresh = openWindow(at: start, width: width,
                                                                       length: max(2 * advance, 4 * count)) {
                // The line may go on past the window: break it again from here.
                window = fresh
                count = max(CTTypesetterSuggestLineBreak(window.typesetter, 0, Double(width)), 1)
            }
            var end = min(start + count, range.upperBound)
            if let images = window.images {
                end = min(images.lineEnd(end - window.range.lowerBound) + window.range.lowerBound, range.upperBound)
            }
            y += appendLine(start..<end, in: window, x: x, maxX: x + width, top: y, codeBlock: -1,
                            isRightToLeft: isRightToLeft).height
            if lines.last?.endsWithNewline == true { paragraphStart = end }
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
        if !range.isEmpty, let text {
            var characters = [UniChar](repeating: 0, count: range.count)
            CFStringGetCharacters(text, CFRange(location: range.lowerBound, length: range.count), &characters)
            let code = Int32(codeBlocks.count)
            var start = 0
            while start < characters.count {
                let end = characters[start...].firstIndex(of: 0x0A).map { $0 + 1 } ?? characters.count
                let lineRange = (range.lowerBound + start)..<(range.lowerBound + end)
                // Code has no images, so any window that holds the line will do.
                var current = window
                if let window, window.range.lowerBound <= lineRange.lowerBound,
                   lineRange.upperBound <= window.range.upperBound {
                    current = window
                } else {
                    current = openWindow(at: lineRange.lowerBound, width: width, reaching: lineRange.upperBound)
                }
                guard let window = current else { break }
                let line = appendLine(lineRange, in: window, x: x + padding, maxX: x + width - padding, top: y,
                                      codeBlock: code)
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
    private mutating func appendLine(_ range: Range<Int>, in window: TextWindow, x: CGFloat, maxX: CGFloat, top: CGFloat,
                                     codeBlock: Int32, isRightToLeft: Bool = false) -> (height: CGFloat, width: CGFloat) {
        let base = window.range.lowerBound
        let location = CFRange(location: range.lowerBound - base, length: range.count)
        let line = CTTypesetterCreateLine(window.typesetter, location)
        // Lines of blocks with images may hold run delegates, of loaded images
        // or of placeholders.
        let hasImages = window.images != nil
        let index = window.set.append(window.set.isKept ? line : nil, range: location)
        let (layout, width) = BlockLayout.lineLayout(line, in: window.set, index: index,
                                                     range: range, base: base, string: window.string,
                                                     runs: block.styleRuns, runIndex: &runIndex, links: block.links[...],
                                                     linkOffset: 0, x: x, maxX: maxX, top: top, codeBlock: codeBlock,
                                                     typography: typography, hasImages: hasImages,
                                                     isRightToLeft: isRightToLeft)
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
                                            rows: tableRows, images: images, linesWarm: linesWarm,
                                            isCancelled: isCancelled) else {
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
            let line = MarkerNumbers.line(number, typography: typography)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            markers.append(MarkerLayout(kind: .number(number), rect: CGRect(x: right - width, y: baseline - ascent,
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

/// A window of a block's display text with its own typesetter, starting at
/// a line start, and the set its lines go into.
struct TextWindow {
    /// How much text a window holds: under the 10,000 characters past which
    /// Core Text stops kerning, and short enough to typeset again quickly.
    static let length = 8_192
    /// A line starts at most this far into a paragraph in its window, so
    /// breaking it never looks back further; less for short lines.
    static let advance = 4_096
    /// A line starts at least this far before its window's end, unless the
    /// window ends the text, or half the window for a shorter one; a line
    /// longer than that gets a new window.
    static let reach = 1_024
    let reach: Int

    /// Display offsets of the window's text.
    let range: Range<Int>
    let typesetter: CTTypesetter
    /// The string as typeset, with loaded images replaced.
    let string: CFString
    /// The images in the window, relative to its start.
    let images: ImageText?
    let imageWidth: CGFloat
    let set: LineSet

    /// The window from `start`, through `reaching` at least and about
    /// `windowLength` long, of `text`, the display text of `block` (`length`
    /// units), with the block's `images` fitted to `imageWidth` and the
    /// paragraph `directions` of the block.
    init?(text: CFString, block: MarkdownBlock, start: Int, reaching: Int, length: Int,
          windowLength: Int = TextWindow.length, typography: Typography, images: ImageText?, imageWidth: CGFloat,
          directions: [ParagraphDirection], isWarm: Bool) {
        // The rest of the text, when it is short enough: one window for a
        // block of up to `length`.
        var end = length - start <= Self.length ? length : min(max(start + min(windowLength, Self.length), reaching), length)
        if end < length {
            // Never inside a character or an image.
            let composed = CFStringGetRangeOfComposedCharactersAtIndex(text, end)
            if composed.location < end { end = min(composed.location + composed.length, length) }
            if let image = images?.items.first(where: { $0.range.lowerBound < end && end < $0.range.upperBound }) {
                end = image.range.upperBound
            }
        }
        let range = start..<end
        reach = min(Self.reach, range.count / 2)
        // A window of the whole text shares the block's runs.
        let runs = range == 0..<length ? block.styleRuns : Self.slice(block.styleRuns, to: range)
        let windowImages = images?.slice(range)
        let windowDirections = directions.compactMap { direction -> ParagraphDirection? in
            let lower = max(direction.range.lowerBound, start)
            let upper = min(direction.range.upperBound, end)
            return lower < upper ? ParagraphDirection(range: (lower - start)..<(upper - start),
                                                      isRightToLeft: direction.isRightToLeft) : nil
        }
        guard let substring = range == 0..<length ? text
                : CFStringCreateWithSubstring(nil, text, CFRange(location: start, length: end - start)),
              let string = BlockLayout.makeString(substring, runs: runs, typography: typography, images: windowImages,
                                                  directions: windowDirections) else { return nil }
        self.range = range
        typesetter = CTTypesetterCreateWithAttributedString(string)
        self.string = CFAttributedStringGetString(string)
        self.images = windowImages
        self.imageWidth = imageWidth
        let source = block.text
        set = LineSet(length: end - start, isWarm: isWarm) {
            guard let substring = BlockLayout.substring(of: source, range, length: length),
                  let string = BlockLayout.makeString(substring, runs: runs, typography: typography,
                                                      images: windowImages, directions: windowDirections)
            else { return nil }
            return CTTypesetterCreateWithAttributedString(string)
        }
    }

    /// The style runs in `range`, relative to its start.
    static func slice(_ runs: [StyleRun], to range: Range<Int>) -> [StyleRun] {
        var sliced: [StyleRun] = []
        var index = BlockLayout.styleRunIndex(in: runs, at: range.lowerBound)
        while index < runs.count, runs[index].range.lowerBound < range.upperBound {
            let run = runs[index]
            let lower = max(run.range.lowerBound, range.lowerBound)
            let upper = min(run.range.upperBound, range.upperBound)
            if lower < upper {
                var piece = run
                piece.range = (lower - range.lowerBound)..<(upper - range.lowerBound)
                sliced.append(piece)
            }
            index += 1
        }
        return sliced
    }
}

/// The typeset numbers of ordered list items, kept once for all lists: most
/// count from one, so a few hundred lines serve every document, where a
/// line per item would cost about 1.6 KB each.
enum MarkerNumbers {
    /// Numbers up to this are kept; larger ones are typeset when drawn.
    static let keptLimit = 1_000
    nonisolated(unsafe) private static let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        return lock
    }()
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var lines: [Int: CTLine] = [:]

    /// `number` and a period in the body font.
    static func line(_ number: Int, typography: Typography) -> CTLine {
        let isKept = number >= 0 && number <= keptLimit && typography === Typography.standard
        if isKept {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            if let line = lines[number] { return line }
            let line = make(number, typography)
            lines[number] = line
            return line
        }
        return make(number, typography)
    }

    private static func make(_ number: Int, _ typography: Typography) -> CTLine {
        let text = CFAttributedStringCreate(nil, "\(number)." as CFString, typography.attributes(.body, []))
        return CTLineCreateWithAttributedString(text ?? CFAttributedStringCreate(nil, "" as CFString, nil))
    }
}
