import MarkdownView

/// A deterministic stand-in for the app's tokenizer, so custom mode measures what highlighting
/// costs the library itself: splitting style runs, and drawing code token by token. In a
/// block with an info string, two of every three words (text between spaces, tabs and line
/// breaks) are a token, of each kind in turn; blocks without one stay plain, as the app leaves
/// them. Pure and cheap, so it is safe to call concurrently and adds little time of its own.
struct FakeCodeHighlighter: MarkdownCodeHighlighter {
    func tokens(for code: String, info: String) -> [CodeToken]? {
        guard !info.isEmpty else { return nil }
        var tokens: [CodeToken] = []
        var words = 0
        var start: Int?
        var offset = 0
        func endWord() {
            guard let wordStart = start else { return }
            if words % 3 != 2 {
                let kind = CodeTokenKind.allCases[tokens.count % CodeTokenKind.allCases.count]
                tokens.append(CodeToken(range: wordStart..<offset, kind: kind))
            }
            words += 1
            start = nil
        }
        for unit in code.utf16 {
            if unit == 0x20 || unit == 0x09 || unit == 0x0A {
                endWord()
            } else if start == nil {
                start = offset
            }
            offset += 1
        }
        endWord()
        return tokens
    }
}
