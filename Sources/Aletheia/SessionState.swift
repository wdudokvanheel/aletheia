import Foundation

enum MarkdownMode: String, Codable, Sendable, CaseIterable {
    case editor, split, preview
}

struct FileScrollPosition: Codable, Equatable, Sendable {
    var source: CGPoint = .zero
    var preview: CGPoint = .zero
}

struct FolderTreeState: Codable, Equatable, Sendable {
    var expandedPaths: [String] = []
    var selectedPath: String? = nil
    var scrollOrigin: CGPoint = .zero
}

struct WindowSession: Codable, Equatable, Sendable {
    var frame: CGRect
    var rootPath: String?
    var filePaths: [String]
    var selectedPath: String?
    var markdownModes: [String: MarkdownMode]? = nil

    var treeState: FolderTreeState? = nil
    var scrollPositions: [String: FileScrollPosition]? = nil

    var treeWidth: CGFloat? = nil
    var editorFraction: CGFloat? = nil

    func visibleFrame(on screens: [CGRect]) -> CGRect {
        let fallback = CGRect(x: 0, y: 0, width: 1080, height: 720)
        let proposed = [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0 ? frame : fallback
        guard let screen = screens.max(by: { lhs, rhs in
            let left = lhs.intersection(proposed)
            let right = rhs.intersection(proposed)
            return (left.isNull ? 0 : left.width * left.height) < (right.isNull ? 0 : right.width * right.height)
        }) else { return proposed }
        let width = min(max(proposed.width, 620), screen.width)
        let height = min(max(proposed.height, 360), screen.height)
        return CGRect(x: min(max(proposed.minX, screen.minX), screen.maxX - width),
                      y: min(max(proposed.minY, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }
}

struct SessionState: Codable, Equatable, Sendable {
    var version = 1
    var windows: [WindowSession]
    var activeWindowIndex: Int?

    private static let key = "lastSession"

    static func load(from defaults: UserDefaults = .standard) -> SessionState? {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(Self.self, from: data), state.version == 1 else { return nil }
        return state
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Stored in the application preferences, never in a project directory.
struct ProjectSessions: Codable, Equatable {
    var projects: [String: WindowSession] = [:]
    var mostRecent: WindowSession?
    private static let key = "projectSessions"

    static func identity(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func sameProject(_ lhs: URL, _ rhs: URL) -> Bool {
        if identity(lhs) == identity(rhs) { return true }
        // Also recognize alternate casing on case-insensitive volumes.
        let a = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let b = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        return (a as? NSObject).map { $0.isEqual(b) } ?? false
    }

    func session(for url: URL) -> WindowSession? {
        projects[Self.identity(url)] ?? projects.values.first {
            $0.rootPath.map { Self.sameProject(URL(fileURLWithPath: $0), url) } ?? false
        }
    }

    mutating func remember(_ session: WindowSession, active: Bool = false) {
        if let root = session.rootPath {
            let key = Self.identity(URL(fileURLWithPath: root))
            projects[key] = session
        }
        if active, session.rootPath != nil || projects.isEmpty { mostRecent = session }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: key),
           let value = try? JSONDecoder().decode(Self.self, from: data) { return value }
        var value = Self()
        if let legacy = SessionState.load(from: defaults) {
            for session in legacy.windows { value.remember(session) }
            let index = legacy.activeWindowIndex ?? 0
            value.mostRecent = legacy.windows.indices.contains(index)
                ? legacy.windows[index] : legacy.windows.first
        }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
