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
    // Resources/ThemeLicenses.md (bundled), theme-authors.md.
    static let all: [AppColorScheme] = [
        .init(id: "system", name: "System", palette: .system),
        .init(id: "material-oceanic", name: "Material Oceanic", palette: .init(isDark: true, 0x263238, 0xeeffff, 0x263238, 0x6c8692, 0x80cbc4, 0xc3e88d, 0x82aaff, 0xf07178, 0x89ddff, 0xffcb6b)),
        .init(id: "material-deep-ocean", name: "Material Deep Ocean", palette: .init(isDark: true, 0x0f111a, 0xbabed8, 0x292d3e, 0x525975, 0x80cbc4, 0xc3e88d, 0x82aaff, 0xf07178, 0x89ddff, 0xffcb6b)),
        .init(id: "material-palenight", name: "Material Palenight", palette: .init(isDark: true, 0x292d3e, 0xbabed8, 0x292d3e, 0x676e95, 0x80cbc4, 0xc3e88d, 0x82aaff, 0xf07178, 0x89ddff, 0xffcb6b)),
        .init(id: "material-lighter", name: "Material Lighter", palette: .init(isDark: false, 0xfafafa, 0x90a4ae, 0xfafafa, 0x758a95, 0x80cbc4, 0x91b859, 0x6182b8, 0xe53935, 0x39adb5, 0xe2931d)),
        .init(id: "material-darker", name: "Material Darker", palette: .init(isDark: true, 0x212121, 0xeeffff, 0x212121, 0x676767, 0x80cbc4, 0xc3e88d, 0x82aaff, 0xf07178, 0x89ddff, 0xffcb6b)),
        .init(id: "vscode-dark-modern", name: "VS Code Dark Modern", palette: .init(isDark: true, 0x1f1f1f, 0xcccccc, 0x181818, 0x9d9d9d, 0x0078d4, 0x81b88b, 0xe2c08d, 0xc74e39, 0xe2c08d, 0xe4676b)),
        .init(id: "vscode-light-modern", name: "VS Code Light Modern", palette: .init(isDark: false, 0xffffff, 0x3b3b3b, 0xf8f8f8, 0x3b3b3b, 0x005fb8, 0x587c0c, 0x895503, 0xad0707, 0x895503, 0xad0707)),
        .init(id: "vscode-quiet-light", name: "VS Code Quiet Light", palette: .init(isDark: false, 0xf5f5f5, 0x333333, 0xf2f2f2, 0x6d705b, 0x9769dc, 0x587c0c, 0x895503, 0xad0707, 0x895503, 0xad0707)),
        .init(id: "vscode-abyss", name: "VS Code Abyss", palette: .init(isDark: true, 0x000c18, 0x6688cc, 0x060621, 0x406385, 0x596f99, 0x81b88b, 0xe2c08d, 0xc74e39, 0xe2c08d, 0xe4676b)),
        .init(id: "vscode-kimbie-dark", name: "VS Code Kimbie Dark", palette: .init(isDark: true, 0x221a0f, 0xd3af86, 0x362712, 0xa57a4c, 0xa57a4c, 0x81b88b, 0xe2c08d, 0xc74e39, 0xe2c08d, 0xe4676b)),
        .init(id: "vscode-monokai", name: "VS Code Monokai", palette: .init(isDark: true, 0x272822, 0xf8f8f2, 0x1e1f1c, 0x90908a, 0x99947c, 0x81b88b, 0xe2c08d, 0xc74e39, 0xe2c08d, 0xe4676b)),
        .init(id: "vscode-monokai-dimmed", name: "VS Code Monokai Dimmed", palette: .init(isDark: true, 0x1e1e1e, 0xc5c8c6, 0x272727, 0x9a9b99, 0x3655b5, 0x81b88b, 0xe2c08d, 0xc74e39, 0xe2c08d, 0xe4676b)),
        .init(id: "jetbrains-darcula", name: "JetBrains Darcula", palette: .init(isDark: true, 0x2b2b2b, 0xa9b7c6, 0x3c3f41, 0x777777, 0x6897bb, 0x629755, 0x6897bb, 0x6c6c6c, 0x3a8484, 0xd5756c)),
        .init(id: "intellij-light", name: "IntelliJ Light", palette: .init(isDark: false, 0xffffff, 0x000000, 0xf2f2f2, 0x8c8c8c, 0x2470b3, 0x0a7700, 0x0032a0, 0x616161, 0x007c7c, 0xff0000)),
        .init(id: "nordic", name: "Nordic", palette: .init(isDark: true, 0x242933, 0xc0c8d8, 0x191d24, 0x81a1c1, 0x88c0d0, 0xa3be8c, 0x81a1c1, 0xbf616a, 0x8fbcbb, 0xb48ead)),
        .init(id: "melange-dark", name: "Mélange Dark", palette: .init(isDark: true, 0x292522, 0xece1d7, 0x34302c, 0x867462, 0xa3a9ce, 0x85b695, 0xebc06d, 0xd47766, 0x89b3b6, 0xcf9bc2)),
        .init(id: "melange-light", name: "Mélange Light", palette: .init(isDark: false, 0xf1f1f1, 0x54433a, 0xe9e1db, 0xa98a78, 0x465aa4, 0x3a684a, 0xa06d00, 0xbf0021, 0x3d6568, 0x904180)),
        .init(id: "everforest-dark-hard", name: "Everforest Dark Hard", palette: .init(isDark: true, 0x272e33, 0xd3c6aa, 0x1e2326, 0x859289, 0x7fbbb3, 0xa7c080, 0xdbbc7f, 0xe67e80, 0x83c092, 0xd699b6)),
        .init(id: "everforest-light-hard", name: "Everforest Light Hard", palette: .init(isDark: false, 0xfffbef, 0x5c6a72, 0xf2efdf, 0x939f91, 0x3a94c5, 0x8da101, 0xdfa000, 0xf85552, 0x35a77c, 0xdf69ba)),
        .init(id: "everforest-dark-medium", name: "Everforest Dark Medium", palette: .init(isDark: true, 0x2d353b, 0xd3c6aa, 0x232a2e, 0x859289, 0x7fbbb3, 0xa7c080, 0xdbbc7f, 0xe67e80, 0x83c092, 0xd699b6)),
        .init(id: "everforest-light-medium", name: "Everforest Light Medium", palette: .init(isDark: false, 0xfdf6e3, 0x5c6a72, 0xefebd4, 0x939f91, 0x3a94c5, 0x8da101, 0xdfa000, 0xf85552, 0x35a77c, 0xdf69ba)),
        .init(id: "everforest-dark-soft", name: "Everforest Dark Soft", palette: .init(isDark: true, 0x333c43, 0xd3c6aa, 0x293136, 0x859289, 0x7fbbb3, 0xa7c080, 0xdbbc7f, 0xe67e80, 0x83c092, 0xd699b6)),
        .init(id: "everforest-light-soft", name: "Everforest Light Soft", palette: .init(isDark: false, 0xf3ead3, 0x5c6a72, 0xe5dfc5, 0x939f91, 0x3a94c5, 0x8da101, 0xdfa000, 0xf85552, 0x35a77c, 0xdf69ba)),
        .init(id: "sonokai-default", name: "Sonokai Default", palette: .init(isDark: true, 0x2c2e34, 0xe2e2e3, 0x222327, 0x7f8490, 0x76cce0, 0x9ed072, 0xe7c664, 0xfc5d7c, 0x76cce0, 0xb39df3)),
        .init(id: "sonokai-shusia", name: "Sonokai Shusia", palette: .init(isDark: true, 0x2d2a2e, 0xe3e1e4, 0x211f21, 0x848089, 0x7accd7, 0x9ecd6f, 0xe5c463, 0xf85e84, 0x7accd7, 0xab9df2)),
        .init(id: "sonokai-andromeda", name: "Sonokai Andromeda", palette: .init(isDark: true, 0x2b2d3a, 0xe1e3e4, 0x252630, 0x7e8294, 0x6dcae8, 0x9ed06c, 0xedc763, 0xfb617e, 0x6dcae8, 0xbb97ee)),
        .init(id: "sonokai-atlantis", name: "Sonokai Atlantis", palette: .init(isDark: true, 0x2a2f38, 0xe1e3e4, 0x24272e, 0x828a9a, 0x72cce8, 0x9dd274, 0xeacb64, 0xff6578, 0x72cce8, 0xba9cf3)),
        .init(id: "sonokai-maia", name: "Sonokai Maia", palette: .init(isDark: true, 0x273136, 0xe1e2e3, 0x21282c, 0x82878b, 0x78cee9, 0x9cd57b, 0xe3d367, 0xf76c7c, 0x78cee9, 0xbaa0f8)),
        .init(id: "sonokai-espresso", name: "Sonokai Espresso", palette: .init(isDark: true, 0x312c2b, 0xe4e3e1, 0x242120, 0x90817b, 0x81d0c9, 0xa6cd77, 0xf0c66f, 0xf86882, 0x81d0c9, 0x9fa0e1)),
        .init(id: "nightfox", name: "Nightfox", palette: .init(isDark: true, 0x192330, 0xcdcecf, 0x131a24, 0x71839b, 0x719cd6, 0x81b29a, 0xdbc074, 0xc94f6d, 0x63cdcf, 0xf4a261)),
        .init(id: "dayfox", name: "Dayfox", palette: .init(isDark: false, 0xf6f2ee, 0x3d2b5a, 0xe4dcd4, 0x824d5b, 0x2848a9, 0x396847, 0xac5402, 0xa5222f, 0x287980, 0x955f61)),
        .init(id: "dawnfox", name: "Dawnfox", palette: .init(isDark: false, 0xfaf4ed, 0x575279, 0xebe5df, 0xa8a3b3, 0x286983, 0x618774, 0xea9d34, 0xb4637a, 0x56949f, 0xd7827e)),
        .init(id: "duskfox", name: "Duskfox", palette: .init(isDark: true, 0x232136, 0xe0def4, 0x191726, 0x6e6a86, 0x569fba, 0xa3be8c, 0xf6c177, 0xeb6f92, 0x9ccfd8, 0xea9a97)),
        .init(id: "nordfox", name: "Nordfox", palette: .init(isDark: true, 0x2e3440, 0xcdcecf, 0x232831, 0x7e8188, 0x81a1c1, 0xa3be8c, 0xebcb8b, 0xbf616a, 0x88c0d0, 0xc9826b)),
        .init(id: "terafox", name: "Terafox", palette: .init(isDark: true, 0x152528, 0xe6eaea, 0x0f1c1e, 0x587b7b, 0x5a93aa, 0x7aa4a1, 0xfda47f, 0xe85c51, 0xa1cdd8, 0xff8349)),
        .init(id: "carbonfox", name: "Carbonfox", palette: .init(isDark: true, 0x161616, 0xf2f4f8, 0x0c0c0c, 0x7b7c7e, 0x78a9ff, 0x25be6a, 0x08bdba, 0xee5396, 0x33b1ff, 0x3ddbd9)),
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

/// The app-wide Markdown preview renderer. WebKit stays the default while Custom is experimental.
enum MarkdownRenderer: String, CaseIterable {
    case webkit, custom

    var title: String { self == .webkit ? "WebKit" : "Custom (Experimental)" }
}

@MainActor
final class AppSettings: NSObject {
    static let shared = AppSettings()
    static let didChange = Notification.Name("AletheiaAppearanceDidChange")
    static let colorSchemeKey = "colorScheme"
    static let revealActiveFileKey = "revealActiveFileInTree"
    static let revealActiveFileDidChange = Notification.Name("AletheiaRevealActiveFileDidChange")
    static let markdownRendererKey = "markdownRenderer"
    static let markdownRendererDidChange = Notification.Name("AletheiaMarkdownRendererDidChange")
    static let previewTimingsKey = "showPreviewTimings"
    static let previewTimingsDidChange = Notification.Name("AletheiaPreviewTimingsDidChange")
    static let schemes = AppColorScheme.all

    private let defaults: UserDefaults
    private(set) var selectedSchemeID: String
    var selectedScheme: AppColorScheme {
        Self.schemes.first { $0.id == selectedSchemeID } ?? Self.schemes[0]
    }
    var palette: EditorPalette { selectedScheme.palette }
    var revealActiveFileInTree: Bool {
        defaults.object(forKey: Self.revealActiveFileKey) == nil
            || defaults.bool(forKey: Self.revealActiveFileKey)
    }

    func setRevealActiveFileInTree(_ enabled: Bool) {
        guard revealActiveFileInTree != enabled else { return }
        defaults.set(enabled, forKey: Self.revealActiveFileKey)
        NotificationCenter.default.post(name: Self.revealActiveFileDidChange, object: self)
    }

    /// Unknown stored values fall back to WebKit.
    var markdownRenderer: MarkdownRenderer {
        defaults.string(forKey: Self.markdownRendererKey).flatMap(MarkdownRenderer.init(rawValue:)) ?? .webkit
    }

    func setMarkdownRenderer(_ renderer: MarkdownRenderer) {
        guard markdownRenderer != renderer else { return }
        defaults.set(renderer.rawValue, forKey: Self.markdownRendererKey)
        NotificationCenter.default.post(name: Self.markdownRendererDidChange, object: self)
    }

    /// The Custom renderer's diagnostics overlay.
    var showsPreviewTimings: Bool { defaults.bool(forKey: Self.previewTimingsKey) }

    func setShowsPreviewTimings(_ enabled: Bool) {
        guard showsPreviewTimings != enabled else { return }
        defaults.set(enabled, forKey: Self.previewTimingsKey)
        NotificationCenter.default.post(name: Self.previewTimingsDidChange, object: self)
    }

    private var settingsWindow: NSWindow?
    private var schemePopup: NSPopUpButton?
    private var revealCheckbox: NSButton?
    private var rendererPopup: NSPopUpButton?
    private var timingsCheckbox: NSButton?
    private var projectSettingsView: ProjectSettingsView?
    private let shortcuts: Shortcuts

    init(defaults: UserDefaults = .standard, shortcuts: Shortcuts = .shared) {
        self.defaults = defaults
        self.shortcuts = shortcuts
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
            let reveal = NSButton(checkboxWithTitle: "Reveal active file in tree", target: self,
                                  action: #selector(revealChanged(_:)))
            let renderer = NSPopUpButton(frame: .zero, pullsDown: false)
            renderer.addItems(withTitles: MarkdownRenderer.allCases.map(\.title))
            renderer.target = self
            renderer.action = #selector(rendererChanged(_:))
            renderer.widthAnchor.constraint(equalToConstant: 300).isActive = true
            let timings = NSButton(checkboxWithTitle: "Show preview timings", target: self,
                                   action: #selector(timingsChanged(_:)))
            let revealNote = SettingsPage.note("Opening or selecting a tab expands its folders and selects the file in the tree.")
            let general = NSStackView(views: [
                SettingsPage.heading("File tree"), reveal, revealNote,
                SettingsPage.heading("Markdown renderer"), renderer, timings,
                SettingsPage.note("Applies immediately to all windows. Preview timings are shown only by the Custom renderer.")
            ])
            general.orientation = .vertical
            general.alignment = .leading
            general.spacing = 12
            general.setCustomSpacing(28, after: revealNote)
            let projects = ProjectSettingsView(settings: ProjectSettings(defaults: defaults), shortcuts: shortcuts)
            projectSettingsView = projects
            let shortcutList = ShortcutSettingsView(shortcuts: shortcuts)
            for (title, symbol, content) in [
                ("General", "gearshape", general),
                ("Appearance", "paintpalette", appearance),
                ("Projects", "folder", projects),
                ("Shortcuts", "keyboard", shortcutList)
            ] as [(String, String, NSView)] {
                let controller = SettingsPage(title: title, content: content, fills: content === shortcutList)
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
            revealCheckbox = reveal
            rendererPopup = renderer
            timingsCheckbox = timings
            window.center()
        }
        updateWindow()
        projectSettingsView?.refresh()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func schemeChanged(_ sender: NSPopUpButton) {
        guard Self.schemes.indices.contains(sender.indexOfSelectedItem) else { return }
        selectScheme(id: Self.schemes[sender.indexOfSelectedItem].id)
    }

    @objc private func revealChanged(_ sender: NSButton) {
        setRevealActiveFileInTree(sender.state == .on)
    }

    @objc private func rendererChanged(_ sender: NSPopUpButton) {
        guard MarkdownRenderer.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        setMarkdownRenderer(MarkdownRenderer.allCases[sender.indexOfSelectedItem])
        updateWindow()
    }

    @objc private func timingsChanged(_ sender: NSButton) {
        setShowsPreviewTimings(sender.state == .on)
    }

    private func updateWindow() {
        settingsWindow?.appearance = palette.appearance
        schemePopup?.selectItem(at: Self.schemes.firstIndex { $0.id == selectedSchemeID } ?? 0)
        revealCheckbox?.state = revealActiveFileInTree ? .on : .off
        rendererPopup?.selectItem(at: MarkdownRenderer.allCases.firstIndex(of: markdownRenderer) ?? 0)
        timingsCheckbox?.state = showsPreviewTimings ? .on : .off
        timingsCheckbox?.isEnabled = markdownRenderer == .custom
    }
}
