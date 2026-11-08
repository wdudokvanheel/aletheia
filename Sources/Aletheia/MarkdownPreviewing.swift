import AppKit

/// What `EditorWindow` needs from a Markdown preview renderer.
@MainActor
protocol MarkdownPreviewing: AnyObject {
    /// The view placed in the editor layout.
    var view: NSView { get }
    /// The view made first responder in preview-only mode.
    var focusView: NSView { get }
    var onOpen: ((URL) -> Void)? { get set }
    func show(_ document: EditorDocument?)
    func contentChanged()
    func applyTheme()
    func setSearch(query: String, sourceRange: NSRange?)
    /// Called when the window becomes visible or fully hidden.
    func setVisible(_ visible: Bool)
    /// Stops in-flight work before the window drops this preview.
    func prepareForRelease()
}
