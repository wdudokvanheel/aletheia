import cmark_gfm
import cmark_gfm_extensions

/// Bridge to cmark-gfm with exactly the extensions the renderer supports.
enum MarkdownParser {
    static let extensionNames = ["table", "strikethrough", "tasklist", "autolink"]

    /// Parses `markdown` with source positions and returns the cmark type name
    /// of each top-level block, in document order.
    static func topLevelBlockKinds(of markdown: String) -> [String] {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_SOURCEPOS) else { return [] }
        defer { cmark_parser_free(parser) }
        for name in extensionNames {
            guard let syntaxExtension = cmark_find_syntax_extension(name) else {
                preconditionFailure("cmark-gfm extension \(name) is not registered")
            }
            cmark_parser_attach_syntax_extension(parser, syntaxExtension)
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return [] }
        defer { cmark_node_free(document) }
        var kinds: [String] = []
        var node = cmark_node_first_child(document)
        while let block = node {
            kinds.append(String(cString: cmark_node_get_type_string(block)))
            node = cmark_node_next(block)
        }
        return kinds
    }
}
