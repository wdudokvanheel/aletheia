import AppKit
import CoreText

/// Static file-icons/atom artwork and filename rules. Never reads file contents.
@MainActor
final class FileIcons {
    static let shared = FileIcons()

    struct Artwork: Decodable { let font: String; let glyph: String }
    struct Rule: Decodable {
        let icon: String
        let colors: [String?]
        let pattern: String
        let insensitive: Bool
        let path: Bool
    }
    struct Catalog: Decodable {
        let icons: [String: Artwork]
        let rules: [Rule]
    }
    let catalog: Catalog
    let rules: [(Rule, NSRegularExpression)]
    private let fonts: [String: CTFont]
    private var images: [String: NSImage] = [:]
    private let matches = NSCache<NSString, NSNumber>()

    init() {
        let directory = Bundle.module.resourceURL!.appendingPathComponent("FileIcons")
        // Invalid bundled data is a packaging error, not an unknown file type.
        catalog = try! JSONDecoder().decode(Catalog.self, from: Data(contentsOf: directory.appendingPathComponent("catalog.json")))
        rules = catalog.rules.map { rule in
            (rule, try! NSRegularExpression(pattern: rule.pattern, options: rule.insensitive ? [.caseInsensitive] : []))
        }
        fonts = Dictionary(uniqueKeysWithValues: Set(catalog.icons.values.map(\.font)).compactMap { name in
            guard let provider = CGDataProvider(url: directory.appendingPathComponent(name + ".ttf") as CFURL),
                  let font = CGFont(provider) else { return nil }
            return (name, CTFontCreateWithGraphicsFont(font, 16, nil, nil))
        })
        matches.countLimit = 4096
    }

    func rule(for url: URL) -> Rule? {
        let path = url.path
        let key = path as NSString
        if let cached = matches.object(forKey: key) {
            return cached.intValue < 0 ? nil : rules[cached.intValue].0
        }
        let name = url.lastPathComponent
        let nameRange = NSRange(name.startIndex..., in: name)
        let pathRange = NSRange(path.startIndex..., in: path)
        for (index, pair) in rules.enumerated() {
            let subject = pair.0.path ? path : name
            if pair.1.firstMatch(in: subject, range: pair.0.path ? pathRange : nameRange) != nil {
                matches.setObject(NSNumber(value: index), forKey: key)
                return pair.0
            }
        }
        matches.setObject(-1, forKey: key)
        return nil
    }

    func image(for icon: String) -> NSImage? {
        if let image = images[icon] { return image }
        guard let artwork = catalog.icons[icon], let font = fonts[artwork.font] else { return nil }
        guard artwork.glyph.unicodeScalars.allSatisfy({ CFCharacterSetIsLongCharacterMember(CTFontCopyCharacterSet(font), $0.value) }) else { return nil }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: artwork.glyph, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            for index in 0..<CTRunGetGlyphCount(run) {
                var glyph: CGGlyph = 0
                var position = CGPoint.zero
                CTRunGetGlyphs(run, CFRange(location: index, length: 1), &glyph)
                CTRunGetPositions(run, CFRange(location: index, length: 1), &position)
                guard glyph != 0, let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
                path.addPath(outline, transform: CGAffineTransform(translationX: position.x, y: position.y))
            }
        }
        let bounds = path.boundingBoxOfPath
        guard !bounds.isEmpty, !bounds.isInfinite else { return nil }
        let scale = min(16 / bounds.width, 16 / bounds.height)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: (18 - bounds.width * scale) / 2, y: (18 - bounds.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        images[icon] = image
        return image
    }

    func color(for rule: Rule, dark: Bool) -> NSColor? {
        guard let name = rule.colors[dark ? 0 : 1] else { return nil }
        let colors: [String: UInt32] = ["red": 0xac4142, "green": 0x90a959, "yellow": 0xf4bf75,
            "blue": 0x6a9fb5, "maroon": 0x8f5536, "purple": 0xaa759f, "orange": 0xd28445,
            "cyan": 0x75b5aa, "pink": 0xff00cc, "grey": 0x7f7f7f]
        guard let rgb = colors[String(name.split(separator: "-").last ?? "")] else { return nil }
        let color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                            green: CGFloat((rgb >> 8) & 255) / 255,
                            blue: CGFloat(rgb & 255) / 255, alpha: 1)
        return dark ? color.blended(withFraction: 0.15, of: .white) : color.blended(withFraction: 0.15, of: .black)
    }
}
