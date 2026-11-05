import Foundation

struct WindowSession: Codable, Equatable, Sendable {
    var frame: CGRect
    var rootPath: String?
    var filePaths: [String]
    var selectedPath: String?

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
