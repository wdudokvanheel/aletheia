import CoreFoundation

/// The base writing direction of a paragraph of a string about to be
/// typeset: a UTF-16 range of it, which includes the separator after it.
struct ParagraphDirection: Sendable, Equatable {
    var range: Range<Int>
    var isRightToLeft: Bool
}

/// Paragraph directions as `dir="auto"` decides them, the way GitHub shows
/// Markdown: by the first strong character of each paragraph, heading,
/// list item paragraph, and table cell (rules P2 and P3 of the Unicode
/// bidirectional algorithm, skipping isolates). Code is always left to right.
enum TextDirection {
    /// Whether `range` of `string` reads right to left, and whether it
    /// holds any right-to-left character at all. Core Text finds the same
    /// direction by itself, but per line between hard breaks; a paragraph
    /// with right-to-left text in it gets its direction set explicitly.
    static func scan(_ string: CFString, _ range: Range<Int>) -> (isRightToLeft: Bool, hasRightToLeft: Bool) {
        var direction: Bool?
        var hasRightToLeft = false
        var isolates = 0
        var high: UInt16 = 0
        var buffer = [UniChar](repeating: 0, count: 512)
        var location = range.lowerBound
        while location < range.upperBound {
            let count = min(buffer.count, range.upperBound - location)
            CFStringGetCharacters(string, CFRange(location: location, length: count), &buffer)
            for unit in buffer[0..<count] {
                let scalar: UInt32
                if UTF16.isLeadSurrogate(unit) {
                    high = unit
                    continue
                } else if UTF16.isTrailSurrogate(unit), high != 0 {
                    scalar = 0x10000 + (UInt32(high - 0xD800) << 10) + UInt32(unit - 0xDC00)
                    high = 0
                } else {
                    scalar = UInt32(unit)
                    high = 0
                }
                let isRightToLeftBlock = isInRightToLeftBlock(scalar)
                if isRightToLeftBlock { hasRightToLeft = true }
                if direction == nil {
                    switch scalar {
                    case 0x2066, 0x2067, 0x2068: isolates += 1
                    case 0x2069: isolates = max(isolates - 1, 0)
                    default:
                        if isolates == 0 { direction = strongDirection(scalar, isRightToLeftBlock) }
                    }
                }
                if hasRightToLeft, direction != nil { return (direction == true, true) }
            }
            location += count
        }
        return (direction == true, hasRightToLeft)
    }

    /// True for a strong right-to-left character, false for a strong
    /// left-to-right one, nil for the rest: letters decide, by their block.
    private static func strongDirection(_ scalar: UInt32, _ isRightToLeftBlock: Bool) -> Bool? {
        if scalar < 0x80 {
            return (0x41...0x5A).contains(scalar) || (0x61...0x7A).contains(scalar) ? false : nil
        }
        switch scalar {
        case 0x200E: return false
        case 0x200F, 0x061C: return true
        default: break
        }
        guard let character = Unicode.Scalar(scalar) else { return nil }
        switch character.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return isRightToLeftBlock
        case .spacingMark, .letterNumber:
            return isRightToLeftBlock ? nil : false
        default:
            return nil
        }
    }

    /// The blocks whose letters are right to left: Hebrew, Arabic, Syriac,
    /// Thaana, N'Ko and the others up to U+08FF, their presentation forms,
    /// and the right-to-left ranges of the supplementary planes.
    private static func isInRightToLeftBlock(_ scalar: UInt32) -> Bool {
        (0x0590...0x08FF).contains(scalar) || (0xFB1D...0xFDFF).contains(scalar) || (0xFE70...0xFEFE).contains(scalar)
            || (0x10800...0x10FFF).contains(scalar) || (0x1E800...0x1EFFF).contains(scalar)
            || scalar == 0x200F || scalar == 0x061C
    }
}
