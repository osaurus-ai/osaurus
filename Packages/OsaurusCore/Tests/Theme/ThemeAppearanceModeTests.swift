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

        let emptySelection = ThemeManager.startupSelection(
            savedActiveTheme: nil,
            configuredAppearanceMode: .dark
        )
        #expect(emptySelection.appearanceMode == .dark)
        #expect(emptySelection.activeTheme == nil)
        #expect(!emptySelection.shouldClearActiveTheme)
    }
}
