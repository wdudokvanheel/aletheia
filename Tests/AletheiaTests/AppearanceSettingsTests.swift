import AppKit
import XCTest
@testable import Aletheia

final class AppearanceSettingsTests: XCTestCase {
    @MainActor func testSelectionPersistsAndUnknownValueFallsBackToSystem() throws {
        let suite = "AletheiaAppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.selectedSchemeID, "system")
        XCTAssertNil(settings.palette.isDark)
        let changed = expectation(forNotification: AppSettings.didChange, object: settings)
        settings.selectScheme(id: "catppuccin-mocha")
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(AppSettings(defaults: defaults).selectedSchemeID, "catppuccin-mocha")
        XCTAssertEqual(settings.palette.isDark, true)
        defaults.set("removed-theme", forKey: AppSettings.colorSchemeKey)
        XCTAssertEqual(AppSettings(defaults: defaults).selectedSchemeID, "system")
        settings.selectScheme(id: "removed-theme")
        XCTAssertNil(settings.palette.isDark)
        XCTAssertEqual(defaults.string(forKey: AppSettings.colorSchemeKey), "system")
    }

    @MainActor func testCatalogUsesUniqueIDsAndCorrectLightDarkForegrounds() throws {
        XCTAssertEqual(AppSettings.schemes.count, 31)
        XCTAssertEqual(Set(AppSettings.schemes.map(\.id)).count, AppSettings.schemes.count)
        for scheme in AppSettings.schemes where scheme.id != "system" {
            let palette = scheme.palette
            let background = try XCTUnwrap(palette.background.usingColorSpace(.sRGB))
            let foreground = try XCTUnwrap(palette.foreground.usingColorSpace(.sRGB))
            func brightness(_ color: NSColor) -> CGFloat {
                0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            }
            XCTAssertEqual(brightness(background) < brightness(foreground), palette.isDark, scheme.id)
            for color in [palette.background, palette.foreground, palette.surface, palette.muted,
                          palette.accent, palette.added, palette.modified, palette.deleted,
                          palette.staged, palette.conflict] {
                XCTAssertNotNil(color.usingColorSpace(.sRGB), scheme.id)
                XCTAssertEqual(color.alphaComponent, 1, scheme.id)
            }
        }
        let dracula = try XCTUnwrap(AppSettings.schemes.first { $0.id == "dracula" })
        let background = try XCTUnwrap(dracula.palette.background.usingColorSpace(.sRGB))
        XCTAssertEqual(background.redComponent, 40.0 / 255, accuracy: 0.00001)
        XCTAssertEqual(background.greenComponent, 42.0 / 255, accuracy: 0.00001)
        XCTAssertEqual(background.blueComponent, 54.0 / 255, accuracy: 0.00001)
    }
}
