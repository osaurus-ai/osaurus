//
//  ThemeAppearanceModeTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ThemeAppearanceModeTests {
    @Test
    func canonicalDefaultsUseHandoffSemanticPalettes() {
        let dark = CustomTheme.darkDefault
        #expect(dark.metadata.name == "Dark")
        #expect(dark.schemaVersion == CustomTheme.currentSchemaVersion)
        #expect(dark.colors.surface.canvas.lowercased() == "#1c1c1e")
        // Handoff primary action is monochrome: white on dark, black on light.
        #expect(dark.colors.action.primary.default.background.lowercased() == "#ffffff")
        #expect(dark.colors.action.primary.default.foreground.lowercased() == "#000000")
        #expect(dark.colors.text.link.lowercased() == "#ffffff")
        #expect(dark.windowMaterial.nativeMaterial == .underWindowBackground)
        #expect(dark.windowMaterial.blending == .behindWindow)
        #expect(dark.windowMaterial.tintOpacity == 0.75)
        #expect(dark.isDark)

        let light = CustomTheme.lightDefault
        #expect(light.metadata.name == "Light")
        #expect(light.schemaVersion == CustomTheme.currentSchemaVersion)
        #expect(light.colors.surface.canvas.lowercased() == "#f5f5f7")
        #expect(light.colors.action.primary.default.background.lowercased() == "#000000")
        #expect(light.colors.action.primary.default.foreground.lowercased() == "#ffffff")
        #expect(light.colors.text.link.lowercased() == "#000000")
        #expect(light.windowMaterial.nativeMaterial == .underWindowBackground)
        #expect(light.windowMaterial.blending == .behindWindow)
        #expect(light.windowMaterial.tintOpacity == 0.75)
        #expect(!light.isDark)
    }

    @Test
    func retiredBuiltInIdsMapToTheirAppearance() {
        let neverRead: (UUID) -> Data? = { _ in
            Issue.record("built-in ids must not read a theme file")
            return nil
        }
        #expect(
            ThemeManager.retiredThemeAppearance(
                activeThemeId: CustomTheme.builtInDarkID.uuidString, readThemeFile: neverRead, configured: .light
            ) == .dark)
        #expect(
            ThemeManager.retiredThemeAppearance(
                activeThemeId: CustomTheme.builtInLightID.uuidString, readThemeFile: neverRead, configured: .system
            ) == .light)
    }

    @Test
    func retiredCustomThemeKeepsItsLightOrDarkLook() {
        let darkFile = Data(#"{"schemaVersion": 7, "isDark": true, "metadata": {}}"#.utf8)
        let lightLegacyFile = Data(#"{"isDark": false, "palette": {}}"#.utf8)
        let id = UUID().uuidString
        #expect(
            ThemeManager.retiredThemeAppearance(activeThemeId: id, readThemeFile: { _ in darkFile }, configured: .system)
                == .dark)
        #expect(
            ThemeManager.retiredThemeAppearance(
                activeThemeId: id, readThemeFile: { _ in lightLegacyFile }, configured: .dark) == .light)
    }

    @Test
    func unreadableRetiredThemeKeepsTheConfiguredMode() {
        let id = UUID().uuidString
        #expect(
            ThemeManager.retiredThemeAppearance(activeThemeId: id, readThemeFile: { _ in nil }, configured: .system)
                == .system)
        #expect(
            ThemeManager.retiredThemeAppearance(
                activeThemeId: id, readThemeFile: { _ in Data("not json".utf8) }, configured: .dark) == .dark)
        #expect(
            ThemeManager.retiredThemeAppearance(
                activeThemeId: "not-a-uuid", readThemeFile: { _ in nil }, configured: .light) == .light)
    }
}
