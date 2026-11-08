import CoreGraphics
import CoreText
import Foundation

/// A decoded image from the host's `MarkdownImageProvider`, ready to draw.
public final class MarkdownImage: Sendable {
    /// The first frame, at most the requested display size times the scale
    /// in pixels.
    public let image: CGImage
    /// The natural size in points, as a browser lays the image out. The view
    /// shows it at this size, scaled down to fit the text it is in.
    public let size: CGSize
    /// Per-frame delays of an animated image; empty for a still one.
    public let frameDelays: [TimeInterval]
    /// What keeping the image costs, in bytes, counted against the view's
    /// retention cap.
    public let byteCount: Int
    private let frames: (@Sendable (Int) -> CGImage?)?

    /// `frame` returns frame `index` of an animated image (with
    /// `frameDelays`), at the size of `image`. The view calls it off the main
    /// thread, one frame at a time, only while the image is visible.
    /// `byteCount` defaults to the size of `image`'s pixels.
    public init(image: CGImage, size: CGSize, frameDelays: [TimeInterval] = [], byteCount: Int? = nil,
                frame: (@Sendable (Int) -> CGImage?)? = nil) {
        self.image = image
        self.size = size
        self.frameDelays = frame == nil ? [] : frameDelays
        self.byteCount = byteCount ?? image.bytesPerRow * image.height
        frames = frame
    }

    public var frameCount: Int { max(1, frameDelays.count) }

    /// Whether it has more than one frame to play.
    public var isAnimated: Bool { frameDelays.count > 1 }

    /// Frame `index`: the first is `image`, and the others are decoded by the
    /// provider's frame function on the calling thread.
    public func frame(at index: Int) -> CGImage? {
        index == 0 ? image : frameDelays.indices.contains(index) ? frames?(index) : nil
    }
}

/// An image load in progress, which the view cancels when it no longer needs
/// the image: when it scrolls far away, the view is hidden, or another
/// document is shown.
public final class MarkdownImageRequest: Sendable {
    private let onCancel: @Sendable () -> Void

    public init(cancel: @escaping @Sendable () -> Void) {
        onCancel = cancel
    }

    public func cancel() { onCancel() }
}

/// Where a `MarkdownPreviewView` gets its images. The view never reads files
/// or opens connections itself: it asks for each image by its source as
/// written in the Markdown, only for images in or near the visible area and
/// only while it is shown, and draws what comes back.
///
/// The provider decides what loads. It must resolve relative sources against
/// the document's folder and apply the host's policies: for local files, no
/// traversal out of that folder, no escaping symlinks, and raster types only;
/// for remote images, HTTPS only, with no cookies or credentials and capped
/// sizes. Anything it refuses or cannot load is a failure, and the view
/// shows the alt text for the rest of the document's time in it.
@MainActor
public protocol MarkdownImageProvider: AnyObject {
    /// Starts loading the image `source` names and calls `completion` once on
    /// the main thread, unless the request is cancelled first; a completion
    /// after a cancel is ignored. `displaySize` is the box in points the view
    /// fits the image into, scaled down with its aspect ratio kept and never
    /// enlarged: the width the image has where it is in the text, and an
    /// infinite height unless the natural size is known. Decode at most
    /// `displaySize` times `scale` pixels. A provider that has the image at
    /// hand may call `completion` before returning, and then returns nil.
    func requestImage(source: String, displaySize: CGSize?, scale: CGFloat,
                      completion: @escaping @MainActor (Result<MarkdownImage, any Error>) -> Void)
        -> MarkdownImageRequest?
}

/// The natural sizes in points of the images loaded so far, by source as
/// written: an input of layout, like the column width. Images missing here
/// show their alt text. Immutable and shared between snapshots; a new
/// instance means something changed.
final class ImageSizes: Sendable {
    static let none = ImageSizes([:])

    let sizes: [String: CGSize]

    init(_ sizes: [String: CGSize]) {
        self.sizes = sizes
    }

    subscript(source: String) -> CGSize? { sizes[source] }

    /// The size an image of natural size `size` is shown at in text `width`
    /// wide: its natural size, scaled down with its aspect ratio kept to fit
    /// the width, as `img { max-width: 100% }` does in the WebKit stylesheet.
    /// Inline images and images alone in a paragraph follow the same rule.
    static func displaySize(_ size: CGSize, fitting width: CGFloat) -> CGSize {
        guard size.width > width, size.width > 0 else { return size }
        return CGSize(width: width, height: size.height * width / size.width)
    }

    /// Whether a size can be laid out: positive and finite.
    static func isValid(_ size: CGSize) -> Bool {
        size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite
    }
}

/// The images of a string about to be typeset, in order: their ranges in the
/// string, their index in the block's images, and the size a loaded one is
/// shown at.
///
/// A loaded image's text is typeset as U+FFFC carrying a `CTRunDelegate` of
/// the image's size, followed by U+2060 word joiners for the rest of its alt
/// text: the string keeps its length, so line ranges stay display offsets,
/// and the joiners have no width and allow no line break, so the image never
/// splits. Its bottom sits on the baseline, as CSS places images.
struct ImageText {
    struct Item {
        var range: Range<Int>
        var index: Int32
        /// Nil while the image is not loaded and its alt text shows.
        var size: CGSize?
    }

    private(set) var items: [Item]
    let hasLoaded: Bool

    /// The block's images, those of `sizes` fitted to `width`.
    init(block: MarkdownBlock, sizes: [CGSize?], width: CGFloat) {
        items = block.images.indices.map { index in
            Item(range: block.images[index].range, index: Int32(index),
                 size: sizes[index].map { ImageSizes.displaySize($0, fitting: max(width, 1)) })
        }
        hasLoaded = items.contains { $0.size != nil }
    }

    private init(items: [Item]) {
        self.items = items
        hasLoaded = items.contains { $0.size != nil }
    }

    /// The items inside `range`, relative to its start, for a substring.
    func slice(_ range: Range<Int>) -> ImageText {
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].range.upperBound <= range.lowerBound { low = mid + 1 } else { high = mid }
        }
        var sliced: [Item] = []
        while low < items.count, items[low].range.lowerBound < range.upperBound {
            var item = items[low]
            if item.range.lowerBound >= range.lowerBound, item.range.upperBound <= range.upperBound {
                item.range = (item.range.lowerBound - range.lowerBound)..<(item.range.upperBound - range.lowerBound)
                sliced.append(item)
            }
            low += 1
        }
        return ImageText(items: sliced)
    }

    /// The same with the loaded images inside `range` that are wider than
    /// `width` fitted to it, or nil when none is.
    func fitting(_ range: Range<Int>, to width: CGFloat) -> ImageText? {
        guard hasLoaded, items.contains(where: { item in
            item.range.lowerBound >= range.lowerBound && item.range.upperBound <= range.upperBound
                && (item.size?.width ?? 0) > width
        }) else { return nil }
        var fitted = self
        for index in fitted.items.indices {
            let item = fitted.items[index]
            guard item.range.lowerBound >= range.lowerBound, item.range.upperBound <= range.upperBound,
                  let size = item.size else { continue }
            fitted.items[index].size = ImageSizes.displaySize(size, fitting: max(width, 1))
        }
        return fitted
    }

    /// A line end moved past the joiners of a loaded image it falls inside,
    /// which a line too narrow for the image would otherwise split off.
    func lineEnd(_ end: Int) -> Int {
        guard hasLoaded else { return end }
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if items[mid].range.upperBound <= end { low = mid + 1 } else { high = mid }
        }
        guard low < items.count, items[low].size != nil, items[low].range.lowerBound < end else { return end }
        return items[low].range.upperBound
    }

    /// Replaces each loaded image's text as described above, and gives the
    /// U+FFFC of an image without alt text a delegate of no size until it
    /// loads, so it takes no space and draws nothing.
    func apply(to string: CFMutableAttributedString) {
        let text = CFAttributedStringGetString(string)
        for item in items where !item.range.isEmpty {
            let location = CFRange(location: item.range.lowerBound, length: 1)
            if let size = item.size {
                let replacement = "\u{FFFC}" + String(repeating: "\u{2060}", count: item.range.count - 1)
                CFAttributedStringReplaceString(string, CFRange(location: item.range.lowerBound, length: item.range.count),
                                                replacement as CFString)
                CFAttributedStringSetAttribute(string, location, kCTRunDelegateAttributeName,
                                               Self.delegate(ImageBox(size: size, index: item.index)))
            } else if item.range.count == 1, CFStringGetCharacterAtIndex(text, item.range.lowerBound) == 0xFFFC {
                CFAttributedStringSetAttribute(string, location, kCTRunDelegateAttributeName,
                                               Self.delegate(ImageBox(size: .zero, index: item.index)))
            }
        }
    }

    /// What a run delegate stands for.
    final class ImageBox {
        let size: CGSize
        let index: Int32

        init(size: CGSize, index: Int32) {
            self.size = size
            self.index = index
        }
    }

    private static func delegate(_ box: ImageBox) -> CTRunDelegate {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { Unmanaged<ImageBox>.fromOpaque($0).release() },
            getAscent: { Unmanaged<ImageBox>.fromOpaque($0).takeUnretainedValue().size.height },
            getDescent: { _ in 0 },
            getWidth: { Unmanaged<ImageBox>.fromOpaque($0).takeUnretainedValue().size.width })
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(box).toOpaque())!
    }

    /// The box of a glyph run made by one of these delegates, or nil.
    static func box(of run: CTRun) -> ImageBox? {
        let key = Unmanaged.passUnretained(kCTRunDelegateAttributeName).toOpaque()
        guard let value = CFDictionaryGetValue(CTRunGetAttributes(run), key) else { return nil }
        let delegate = Unmanaged<CTRunDelegate>.fromOpaque(value).takeUnretainedValue()
        return Unmanaged<ImageBox>.fromOpaque(CTRunDelegateGetRefCon(delegate)).takeUnretainedValue()
    }
}
