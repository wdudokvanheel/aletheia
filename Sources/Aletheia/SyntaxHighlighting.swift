import AppKit
import MarkdownView
import SwiftHighlight

/// Tokens are display attributes only: never rewrite the document's text storage.
struct SyntaxRun: Sendable {
    let range: NSRange
    let style: SyntaxStyle
}

enum SyntaxStyle: Sendable, CaseIterable {
    case comment, string, keyword, number, name, property, markup, invalid

    init?(_ scope: Scope) {
        if scope.isWithin(.comment) { self = .comment }
        else if scope.isWithin(.string) || scope.isWithin(.inlineCode) { self = .string }
        else if scope.isWithin(.keyword) || scope.isWithin("storage") { self = .keyword }
        else if scope.isWithin("constant") { self = .number }
        else if scope.isWithin(.key) || scope.isWithin(.variable) || scope.isWithin(.tagAttribute) { self = .property }
        else if scope.isWithin("entity") || scope.isWithin("support") { self = .name }
        else if scope.isWithin("markup") || scope.isWithin(.listMarker) { self = .markup }
        else if scope.isWithin(.invalid) { self = .invalid }
        else { return nil }
    }

    /// The Markdown preview's name for the same style.
    var tokenKind: CodeTokenKind {
        switch self {
        case .comment: .comment
        case .string: .string
        case .keyword: .keyword
        case .number: .number
        case .name: .name
        case .property: .property
        case .markup: .markup
        case .invalid: .invalid
        }
    }

    @MainActor func color(_ palette: SyntaxPalette) -> NSColor {
        switch self {
        case .comment: palette.comment
        case .string: palette.string
        case .keyword: palette.keyword
        case .number: palette.number
        case .name: palette.name
        case .markup: palette.markup
        case .property: palette.property
        case .invalid: palette.invalid
        }
    }
}

enum SyntaxHighlighting {
    // Huge logs are outside the editor's ordinary-source workload. Keep them editable.
    static let maximumBytes = 2 * 1024 * 1024

    static func languageID(for url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        if name == ".env" || name.hasPrefix(".env.") { return "shell" }
        return LanguageRegistry.shared.language(forPath: url.path)?.id
    }

    static func runs(in text: String, languageID: String) -> [SyntaxRun] {
        guard text.utf8.count <= maximumBytes, !Task.isCancelled else { return [] }
        return runs(in: text, language: Language.named(languageID))
    }

    /// `text` tokenized in `language`, as styled UTF-16 ranges: the one mapping
    /// the editor and the Custom preview's code blocks share, so the same text
    /// takes the same colors in both. Callable from any thread.
    static func runs(in text: String, language: Language) -> [SyntaxRun] {
        let tokens = language.tokenize(text)
        guard !Task.isCancelled else { return [] }
        // Walk scalar boundaries once. NSTextView uses UTF-16; the lexer uses UTF-8.
        var scalars = text.unicodeScalars.makeIterator()
        var byteOffset = 0
        var utf16Offset = 0
        func advance(to target: Int) -> Int {
            while byteOffset < target, let scalar = scalars.next() {
                let value = scalar.value
                byteOffset += value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x10000 ? 3 : 4
                utf16Offset += value < 0x10000 ? 1 : 2
            }
            return utf16Offset
        }
        // Few scopes recur across many tokens. Resolve each once: `isWithin`
        // takes the scope registry's lock per step and interns string literals.
        var styles: [Scope: SyntaxStyle?] = [:]
        var result: [SyntaxRun] = []
        for token in tokens {
            let style: SyntaxStyle?
            if let known = styles[token.scope] {
                style = known
            } else {
                style = SyntaxStyle(token.scope)
                styles.updateValue(style, forKey: token.scope)
            }
            guard let style else { continue }
            let start = advance(to: token.range.lowerBound)
            let end = advance(to: token.range.upperBound)
            result.append(SyntaxRun(range: NSRange(location: start, length: end - start), style: style))
        }
        return result
    }
}

/// Colors fenced code in the Custom preview as the editor colors a file in the
/// fence's language: the info string names the language (`java`, `ts`,
/// `{python}`), and any grammar SwiftHighlight ships applies. Unknown or
/// empty info stays plain.
///
/// The preview calls it on its render queue, possibly from several threads
/// and while the editor tokenizes. SwiftHighlight 1.0.0 tokenizes with
/// per-call state, and its language and scope registries take locks, so the
/// calls need no queue of their own.
struct PreviewCodeHighlighter: MarkdownCodeHighlighter {
    func tokens(for code: String, info: String) -> [CodeToken]? {
        guard !info.isEmpty, let language = LanguageRegistry.shared.language(named: info) else { return nil }
        return SyntaxHighlighting.runs(in: code, language: language).map {
            CodeToken(range: $0.range.location..<NSMaxRange($0.range), kind: $0.style.tokenKind)
        }
    }
}
