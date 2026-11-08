import AppKit
import XCTest
@testable import Aletheia

final class AppearanceSettingsTests: XCTestCase {
    @MainActor func testRevealActiveFileDefaultsOnAndPersists() throws {
        let suite = "AletheiaRevealTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.revealActiveFileInTree)
        let changed = expectation(forNotification: AppSettings.revealActiveFileDidChange, object: settings)
        settings.setRevealActiveFileInTree(false)
        wait(for: [changed], timeout: 1)
        XCTAssertFalse(AppSettings(defaults: defaults).revealActiveFileInTree)
        settings.setRevealActiveFileInTree(true)
        XCTAssertTrue(AppSettings(defaults: defaults).revealActiveFileInTree)
    }

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
        XCTAssertEqual(AppSettings.schemes.count, 75)
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

    @MainActor func testForestFamiliesRetainEveryVariantAndDerivedColors() throws {
        let expected: [String: UInt32] = [
            "everforest-dark-hard": 0x272e33, "everforest-dark-medium": 0x2d353b,
            "everforest-dark-soft": 0x333c43, "everforest-light-hard": 0xfffbef,
            "everforest-light-medium": 0xfdf6e3, "everforest-light-soft": 0xf3ead3,
            "sonokai-default": 0x2c2e34, "sonokai-shusia": 0x2d2a2e,
            "sonokai-andromeda": 0x2b2d3a, "sonokai-atlantis": 0x2a2f38,
            "sonokai-maia": 0x273136, "sonokai-espresso": 0x312c2b,
            "nightfox": 0x192330, "dayfox": 0xf6f2ee, "dawnfox": 0xfaf4ed,
            "duskfox": 0x232136, "nordfox": 0x2e3440,
            "terafox": 0x152528, "carbonfox": 0x161616
        ]
        func hex(_ color: NSColor) throws -> UInt32 {
            let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
            return UInt32((rgb.redComponent * 255).rounded()) << 16
                | UInt32((rgb.greenComponent * 255).rounded()) << 8
                | UInt32((rgb.blueComponent * 255).rounded())
        }
        let suite = "AletheiaForestTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for (id, background) in expected {
            let scheme = try XCTUnwrap(AppSettings.schemes.first { $0.id == id })
            XCTAssertEqual(try hex(scheme.palette.background), background, id)
            XCTAssertNotNil(SyntaxPalette.bundled[id], id)
            settings.selectScheme(id: id)
            XCTAssertEqual(AppSettings(defaults: defaults).selectedSchemeID, id)
        }
        // Derived upstream shades must not silently become the base blue.
        let carbon = try XCTUnwrap(AppSettings.schemes.first { $0.id == "carbonfox" })
        XCTAssertEqual(try hex(carbon.palette.surface), 0x0c0c0c)
        XCTAssertEqual(try hex(carbon.syntaxPalette.comment), 0x6e6f70)
        XCTAssertEqual(try hex(carbon.syntaxPalette.name), 0x8cb6ff)
        let day = try XCTUnwrap(SyntaxPalette.bundled["dayfox"])
        XCTAssertEqual(try hex(day.name), 0x223d90)
    }

}
