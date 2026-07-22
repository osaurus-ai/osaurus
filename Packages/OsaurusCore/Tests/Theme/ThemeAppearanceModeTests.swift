//
//  ThemeAppearanceModeTests.swift
//  osaurusTests
//

import Testing

@testable import OsaurusCore

@MainActor
struct ThemeAppearanceModeTests {
    @Test
    func appearanceModeOnlyMapsCanonicalLightAndDarkBuiltIns() {
        #expect(ThemeManager.appearanceMode(forBuiltInTheme: CustomTheme.darkDefault) == .dark)
        #expect(ThemeManager.appearanceMode(forBuiltInTheme: CustomTheme.lightDefault) == .light)
        #expect(ThemeManager.appearanceMode(forBuiltInTheme: CustomTheme.neonPreset) == nil)
        #expect(ThemeManager.appearanceMode(forBuiltInTheme: CustomTheme.nordPreset) == nil)
        #expect(ThemeManager.appearanceMode(forBuiltInTheme: CustomTheme.paperPreset) == nil)
        #expect(ThemeManager.appearanceMode(forBuiltInTheme: CustomTheme.terminalPreset) == nil)
        #expect(ThemeManager.appearanceMode(forBuiltInTheme: CustomTheme.osaurusDarkPreset) == nil)
        #expect(ThemeManager.appearanceMode(forBuiltInTheme: CustomTheme.osaurusLightPreset) == nil)
    }

    @Test
    func builtInPresetIdsAreUnique() {
        let ids = CustomTheme.allBuiltInPresets.map(\.metadata.id)
        #expect(Set(ids).count == ids.count)
        #expect(CustomTheme.allBuiltInPresets.contains { $0.metadata.id == CustomTheme.osaurusDarkPreset.metadata.id })
        #expect(CustomTheme.allBuiltInPresets.contains { $0.metadata.id == CustomTheme.osaurusLightPreset.metadata.id })
    }

    @Test
    func canonicalDefaultsUseNativeMacOSPalettes() {
        let dark = CustomTheme.darkDefault
        #expect(dark.metadata.name == "Dark")
        #expect(dark.colors.primaryBackground == "#1c1c1e")
        #expect(dark.colors.accentColor == "#0a84ff")
        #expect(dark.glass.enabled)
        #expect(dark.glass.sidebarEnabled)
        #expect(dark.glass.material == .windowBackground)
        #expect(dark.isDark)

        let light = CustomTheme.lightDefault
        #expect(light.metadata.name == "Light")
        #expect(light.colors.primaryBackground == "#f5f5f7")
        #expect(light.colors.accentColor == "#007aff")
        #expect(light.glass.enabled)
        #expect(light.glass.sidebarEnabled)
        #expect(light.glass.material == .windowBackground)
        #expect(!light.isDark)
    }

    @Test
    func osaurusPresetsRetainLegacyDefaultPalettes() {
        let dark = CustomTheme.osaurusDarkPreset
        #expect(dark.metadata.name == "Osaurus Dark")
        #expect(dark.isBuiltIn)
        #expect(dark.isDark)
        #expect(dark.colors.primaryBackground == "#0e1120")
        #expect(dark.colors.accentColor == "#4a6de0")
        #expect(!dark.glass.enabled)

        let light = CustomTheme.osaurusLightPreset
        #expect(light.metadata.name == "Osaurus Light")
        #expect(light.isBuiltIn)
        #expect(!light.isDark)
        #expect(light.colors.primaryBackground == "#ffffea")
        #expect(light.colors.accentColor == "#214099")
        #expect(!light.glass.enabled)
    }

    @Test
    func startupSelectionNormalizesCanonicalBuiltInActiveThemes() {
        let lightSelection = ThemeManager.startupSelection(
            savedActiveTheme: CustomTheme.lightDefault,
            configuredAppearanceMode: .system
        )
        #expect(lightSelection.appearanceMode == .light)
        #expect(lightSelection.activeTheme == nil)
        #expect(lightSelection.shouldClearActiveTheme)

        let darkSelection = ThemeManager.startupSelection(
            savedActiveTheme: CustomTheme.darkDefault,
            configuredAppearanceMode: .light
        )
        #expect(darkSelection.appearanceMode == .dark)
        #expect(darkSelection.activeTheme == nil)
        #expect(darkSelection.shouldClearActiveTheme)
    }

    @Test
    func startupSelectionPreservesCustomAndNonCanonicalBuiltIns() {
        let neonSelection = ThemeManager.startupSelection(
            savedActiveTheme: CustomTheme.neonPreset,
            configuredAppearanceMode: .system
        )
        #expect(neonSelection.appearanceMode == .system)
        #expect(neonSelection.activeTheme?.metadata.id == CustomTheme.neonPreset.metadata.id)
        #expect(!neonSelection.shouldClearActiveTheme)

        let osaurusDarkSelection = ThemeManager.startupSelection(
            savedActiveTheme: CustomTheme.osaurusDarkPreset,
            configuredAppearanceMode: .system
        )
        #expect(osaurusDarkSelection.appearanceMode == .system)
        #expect(osaurusDarkSelection.activeTheme?.metadata.id == CustomTheme.osaurusDarkPreset.metadata.id)
        #expect(!osaurusDarkSelection.shouldClearActiveTheme)

        let emptySelection = ThemeManager.startupSelection(
            savedActiveTheme: nil,
            configuredAppearanceMode: .dark
        )
        #expect(emptySelection.appearanceMode == .dark)
        #expect(emptySelection.activeTheme == nil)
        #expect(!emptySelection.shouldClearActiveTheme)
    }
}
