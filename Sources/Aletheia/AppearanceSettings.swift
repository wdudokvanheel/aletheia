import AppKit

/// UI and Git colors. SyntaxPalette supplies separate roles for each color scheme.
@MainActor
struct EditorPalette {
    let background: NSColor
    let foreground: NSColor
    let surface: NSColor
    let muted: NSColor
    let accent: NSColor
    let added: NSColor
    let modified: NSColor
    let deleted: NSColor
    let staged: NSColor
    let conflict: NSColor
    /// nil follows the system; bundled palettes explicitly choose light or dark controls.
    let isDark: Bool?

    static let system = EditorPalette()

    private init() {
        background = .textBackgroundColor
        foreground = .textColor
        surface = .windowBackgroundColor
        muted = .secondaryLabelColor
        accent = .controlAccentColor
        added = .systemGreen
        modified = .systemOrange
        deleted = .systemRed
        staged = .systemTeal
        conflict = .systemPurple
        isDark = nil
    }

    fileprivate init(isDark: Bool, _ background: UInt32, _ foreground: UInt32,
                     _ surface: UInt32, _ muted: UInt32, _ accent: UInt32,
                     _ added: UInt32, _ modified: UInt32, _ deleted: UInt32,
                     _ staged: UInt32, _ conflict: UInt32) {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        self.background = color(background)
        self.foreground = color(foreground)
        self.surface = color(surface)
        self.muted = color(muted)
        self.accent = color(accent)
        self.added = color(added)
        self.modified = color(modified)
        self.deleted = color(deleted)
        self.staged = color(staged)
        self.conflict = color(conflict)
        self.isDark = isDark
    }

    var appearance: NSAppearance? {
        isDark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! }
    }
}

@MainActor
struct AppColorScheme {
    let id: String
    let name: String
    let palette: EditorPalette

    // Static sRGB adaptations; exact upstream revisions, mapping and licenses:
    // docs/theme-provenance.md and docs/theme-licenses.md.
    static let all: [AppColorScheme] = [
        .init(id: "system", name: "System", palette: .system),
        .init(id: "ayu-light", name: "Ayu Light", palette: .init(isDark: false, 0xfcfcfc, 0x5c6166, 0xf8f9fa, 0x828e9f, 0xf29718, 0x6cbf43, 0x478acc, 0xff7383, 0x4cbf99, 0xa37acc)),
        .init(id: "ayu-mirage", name: "Ayu Mirage", palette: .init(isDark: true, 0x242936, 0xcccac2, 0x1f2430, 0x707a8c, 0xffcc66, 0x87d96c, 0x80bfff, 0xf27983, 0x95e6cb, 0xdfbfff)),
        .init(id: "ayu-dark", name: "Ayu Dark", palette: .init(isDark: true, 0x10141c, 0xbfbdb6, 0x0d1017, 0x5a6378, 0xe6b450, 0x70bf56, 0x73b8ff, 0xf26d78, 0x95e6cb, 0xd2a6ff)),
        .init(id: "github-light", name: "GitHub Light", palette: .init(isDark: false, 0xffffff, 0x24292e, 0xf6f8fa, 0x6a737d, 0x0366d6, 0x28a745, 0x005cc5, 0xd73a49, 0x22863a, 0xe36209)),
        .init(id: "github-dark", name: "GitHub Dark", palette: .init(isDark: true, 0x24292e, 0xe1e4e8, 0x1f2428, 0x959da5, 0x79b8ff, 0x34d058, 0x79b8ff, 0xea4a5a, 0x85e89d, 0xffab70)),
        .init(id: "github-dark-dimmed", name: "GitHub Dark Dimmed", palette: .init(isDark: true, 0x22272e, 0xadbac7, 0x1c2128, 0x768390, 0x539bf5, 0x57ab5a, 0xc69026, 0xe5534b, 0x8ddb8c, 0xcc6b2c)),
        .init(id: "night-owl", name: "Night Owl", palette: .init(isDark: true, 0x011627, 0xd6deeb, 0x011627, 0x89a4bb, 0x82aaff, 0xc5e478, 0xa2bffc, 0xef5350, 0x21c7a8, 0xffeb95)),
        .init(id: "light-owl", name: "Light Owl", palette: .init(isDark: false, 0xfbfbfb, 0x403f53, 0xf0f0f0, 0x403f53, 0x288ed7, 0x08916a, 0xe0af02, 0xde3d3b, 0x2aa298, 0xd6438a)),
        .init(id: "kanagawa-wave", name: "Kanagawa Wave", palette: .init(isDark: true, 0x1f1f28, 0xdcd7ba, 0x181820, 0xc8c093, 0x7e9cd8, 0x76946a, 0xdca561, 0xc34043, 0x6a9589, 0x957fb8)),
        .init(id: "kanagawa-dragon", name: "Kanagawa Dragon", palette: .init(isDark: true, 0x181616, 0xc5c9c5, 0x12120f, 0xc8c093, 0x8ba4b0, 0x76946a, 0xdca561, 0xc34043, 0x6a9589, 0x8992a7)),
        .init(id: "kanagawa-lotus", name: "Kanagawa Lotus", palette: .init(isDark: false, 0xf2ecbc, 0x545464, 0xdcd5ac, 0x43436c, 0x4d699b, 0x6e915f, 0xde9800, 0xd7474b, 0x5e857a, 0x624c83)),
        .init(id: "catppuccin-latte", name: "Catppuccin Latte", palette: .init(isDark: false, 0xeff1f5, 0x4c4f69, 0xe6e9ef, 0x6c6f85, 0x1e66f5, 0x40a02b, 0xdf8e1d, 0xd20f39, 0x179299, 0x8839ef)),
        .init(id: "catppuccin-frappe", name: "Catppuccin Frappé", palette: .init(isDark: true, 0x303446, 0xc6d0f5, 0x292c3c, 0xa5adce, 0x8caaee, 0xa6d189, 0xe5c890, 0xe78284, 0x81c8be, 0xca9ee6)),
        .init(id: "catppuccin-macchiato", name: "Catppuccin Macchiato", palette: .init(isDark: true, 0x24273a, 0xcad3f5, 0x1e2030, 0xa5adcb, 0x8aadf4, 0xa6da95, 0xeed49f, 0xed8796, 0x8bd5ca, 0xc6a0f6)),
        .init(id: "catppuccin-mocha", name: "Catppuccin Mocha", palette: .init(isDark: true, 0x1e1e2e, 0xcdd6f4, 0x181825, 0xa6adc8, 0x89b4fa, 0xa6e3a1, 0xf9e2af, 0xf38ba8, 0x94e2d5, 0xcba6f7)),
        .init(id: "dracula", name: "Dracula", palette: .init(isDark: true, 0x282a36, 0xf8f8f2, 0x44475a, 0x6272a4, 0xbd93f9, 0x50fa7b, 0xf1fa8c, 0xff5555, 0x8be9fd, 0xffb86c)),
        .init(id: "nord", name: "Nord", palette: .init(isDark: true, 0x2e3440, 0xd8dee9, 0x3b4252, 0x81a1c1, 0x88c0d0, 0xa3be8c, 0xebcb8b, 0xbf616a, 0x8fbcbb, 0xb48ead)),
        .init(id: "tokyo-night-night", name: "Tokyo Night", palette: .init(isDark: true, 0x1a1b26, 0xc0caf5, 0x16161e, 0xa9b1d6, 0x7aa2f7, 0x9ece6a, 0xe0af68, 0xf7768e, 0x7dcfff, 0xbb9af7)),
        .init(id: "tokyo-night-storm", name: "Tokyo Night Storm", palette: .init(isDark: true, 0x24283b, 0xc0caf5, 0x1f2335, 0xa9b1d6, 0x7aa2f7, 0x9ece6a, 0xe0af68, 0xf7768e, 0x7dcfff, 0xbb9af7)),
        .init(id: "tokyo-night-moon", name: "Tokyo Night Moon", palette: .init(isDark: true, 0x222436, 0xc8d3f5, 0x1e2030, 0x828bb8, 0x82aaff, 0xc3e88d, 0xffc777, 0xff757f, 0x86e1fc, 0xc099ff)),
        .init(id: "gruvbox-dark", name: "Gruvbox Dark", palette: .init(isDark: true, 0x282828, 0xebdbb2, 0x3c3836, 0xa89984, 0x83a598, 0xb8bb26, 0xfabd2f, 0xfb4934, 0x8ec07c, 0xd3869b)),
        .init(id: "gruvbox-dark-hard", name: "Gruvbox Dark Hard", palette: .init(isDark: true, 0x1d2021, 0xebdbb2, 0x3c3836, 0xa89984, 0x83a598, 0xb8bb26, 0xfabd2f, 0xfb4934, 0x8ec07c, 0xd3869b)),
        .init(id: "gruvbox-dark-soft", name: "Gruvbox Dark Soft", palette: .init(isDark: true, 0x32302f, 0xebdbb2, 0x3c3836, 0xa89984, 0x83a598, 0xb8bb26, 0xfabd2f, 0xfb4934, 0x8ec07c, 0xd3869b)),
        .init(id: "gruvbox-light", name: "Gruvbox Light", palette: .init(isDark: false, 0xfbf1c7, 0x3c3836, 0xebdbb2, 0x7c6f64, 0x076678, 0x79740e, 0xb57614, 0x9d0006, 0x427b58, 0x8f3f71)),
        .init(id: "gruvbox-light-hard", name: "Gruvbox Light Hard", palette: .init(isDark: false, 0xf9f5d7, 0x3c3836, 0xebdbb2, 0x7c6f64, 0x076678, 0x79740e, 0xb57614, 0x9d0006, 0x427b58, 0x8f3f71)),
        .init(id: "gruvbox-light-soft", name: "Gruvbox Light Soft", palette: .init(isDark: false, 0xf2e5bc, 0x3c3836, 0xebdbb2, 0x7c6f64, 0x076678, 0x79740e, 0xb57614, 0x9d0006, 0x427b58, 0x8f3f71)),
        .init(id: "rose-pine-main", name: "Rosé Pine", palette: .init(isDark: true, 0x191724, 0xe0def4, 0x1f1d2e, 0x908caa, 0xc4a7e7, 0x95b1ac, 0xf6c177, 0xeb6f92, 0x9ccfd8, 0xebbcba)),
        .init(id: "rose-pine-moon", name: "Rosé Pine Moon", palette: .init(isDark: true, 0x232136, 0xe0def4, 0x2a273f, 0x908caa, 0xc4a7e7, 0x95b1ac, 0xf6c177, 0xeb6f92, 0x9ccfd8, 0xea9a97)),
        .init(id: "rose-pine-dawn", name: "Rosé Pine Dawn", palette: .init(isDark: false, 0xfaf4ed, 0x464261, 0xfffaf3, 0x797593, 0x907aa9, 0x6d8f89, 0xea9d34, 0xb4637a, 0x56949f, 0xd7827e)),
        .init(id: "solarized-dark", name: "Solarized Dark", palette: .init(isDark: true, 0x002b36, 0x839496, 0x073642, 0x586e75, 0x268bd2, 0x859900, 0xb58900, 0xdc322f, 0x2aa198, 0xd33682)),
        .init(id: "solarized-light", name: "Solarized Light", palette: .init(isDark: false, 0xfdf6e3, 0x657b83, 0xeee8d5, 0x93a1a1, 0x268bd2, 0x859900, 0xb58900, 0xdc322f, 0x2aa198, 0xd33682)),
        .init(id: "one-dark", name: "One Dark", palette: .init(isDark: true, 0x282c34, 0xabb2bf, 0x31353f, 0x848b98, 0x61afef, 0x98c379, 0xe5c07b, 0xe86671, 0x56b6c2, 0xc678dd)),
        .init(id: "one-darker", name: "One Darker", palette: .init(isDark: true, 0x1f2329, 0xa0a8b7, 0x282c34, 0x7a818e, 0x4fa6ed, 0x8ebd6b, 0xe2b86b, 0xe55561, 0x48b0bd, 0xbf68d9)),
        .init(id: "one-cool", name: "One Cool", palette: .init(isDark: true, 0x242b38, 0xa5b0c5, 0x2d3343, 0x7d899f, 0x5ab0f6, 0x97ca72, 0xebc275, 0xef5f6b, 0x4dbdcb, 0xca72e4)),
        .init(id: "one-deep", name: "One Deep", palette: .init(isDark: true, 0x1a212e, 0x93a4c3, 0x21283b, 0x6c7d9c, 0x41a7fc, 0x8bcd5b, 0xefbd5d, 0xf65866, 0x34bfd0, 0xc75ae8)),
        .init(id: "one-warm", name: "One Warm", palette: .init(isDark: true, 0x2c2d30, 0xb1b4b9, 0x35373b, 0x8b8d91, 0x68aee8, 0x99bc80, 0xdfbe81, 0xe16d77, 0x5fafb9, 0xc27fd7)),
        .init(id: "one-warmer", name: "One Warmer", palette: .init(isDark: true, 0x232326, 0xa7aab0, 0x2c2d31, 0x818387, 0x57a5e5, 0x8fb573, 0xdbb671, 0xde5d68, 0x51a8b3, 0xbb70d2)),
        .init(id: "one-light", name: "One Light", palette: .init(isDark: false, 0xfafafa, 0x383a42, 0xf0f0f0, 0x818387, 0x4078f2, 0x50a14f, 0x986801, 0xe45649, 0x0184bc, 0xa626a4)),
    ]
}

@MainActor
final class AppSettings: NSObject {
    static let shared = AppSettings()
    static let didChange = Notification.Name("AletheiaAppearanceDidChange")
    static let colorSchemeKey = "colorScheme"
    static let schemes = AppColorScheme.all

    private let defaults: UserDefaults
    private(set) var selectedSchemeID: String
    var selectedScheme: AppColorScheme {
        Self.schemes.first { $0.id == selectedSchemeID } ?? Self.schemes[0]
    }
    var palette: EditorPalette { selectedScheme.palette }

    private var settingsWindow: NSWindow?
    private var schemePopup: NSPopUpButton?
    private var projectSettingsViews: [ProjectSettingsView] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.colorSchemeKey)
        selectedSchemeID = Self.schemes.first { $0.id == saved }?.id ?? "system"
        super.init()
    }

    /// Invalid or removed IDs fall back to native System colors.
    func selectScheme(id: String) {
        let validID = Self.schemes.first { $0.id == id }?.id ?? "system"
        guard selectedSchemeID != validID else { return }
        selectedSchemeID = validID
        defaults.set(validID, forKey: Self.colorSchemeKey)
        updateWindow()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func showWindow() {
        if settingsWindow == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = []
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: Self.schemes.map(\.name))
            popup.target = self
            popup.action = #selector(schemeChanged(_:))
            let appearance = NSStackView(views: [
                SettingsPage.heading("Color scheme"), popup,
                SettingsPage.note("Applies immediately to all windows, including the file tree, source editor, and Markdown preview."),
                SettingsPage.note("Choose System to follow the appearance set in macOS.")
            ])
            appearance.orientation = .vertical
            appearance.alignment = .leading
            appearance.spacing = 16
            popup.widthAnchor.constraint(equalToConstant: 300).isActive = true
            let projects = ProjectSettingsView(settings: ProjectSettings(defaults: defaults), section: .projects)
            let shortcuts = ProjectSettingsView(settings: ProjectSettings(defaults: defaults), section: .shortcuts)
            projectSettingsViews = [projects, shortcuts]
            for (title, symbol, content) in [
                ("Appearance", "paintpalette", appearance),
                ("Projects", "folder", projects),
                ("Shortcuts", "keyboard", shortcuts)
            ] {
                let controller = SettingsPage(title: title, content: content)
                let item = NSTabViewItem(viewController: controller)
                item.label = title
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.setContentSize(NSSize(width: 700, height: 590))
            window.styleMask = [.titled, .closable]
            window.title = "Settings"
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            settingsWindow = window
            schemePopup = popup
            window.center()
        }
        updateWindow()
        projectSettingsViews.forEach { $0.refresh() }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func schemeChanged(_ sender: NSPopUpButton) {
        guard Self.schemes.indices.contains(sender.indexOfSelectedItem) else { return }
        selectScheme(id: Self.schemes[sender.indexOfSelectedItem].id)
    }

    private func updateWindow() {
        settingsWindow?.appearance = palette.appearance
        schemePopup?.selectItem(at: Self.schemes.firstIndex { $0.id == selectedSchemeID } ?? 0)
    }
}
