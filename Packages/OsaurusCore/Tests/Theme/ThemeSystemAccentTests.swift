//
//  ThemeSystemAccentTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("System accent following")
struct ThemeSystemAccentTests {
    @Test("only the canonical Dark/Light defaults follow the system accent")
    func canonicalPresetsOptIn() {
        #expect(CustomTheme.darkDefault.followsSystemAccent)
        #expect(CustomTheme.lightDefault.followsSystemAccent)
        #expect(!CustomTheme.neonPreset.followsSystemAccent)
        #expect(!CustomTheme.nordPreset.followsSystemAccent)
        #expect(!CustomTheme.paperPreset.followsSystemAccent)
        #expect(!CustomTheme.terminalPreset.followsSystemAccent)
        #expect(!CustomTheme.osaurusDarkPreset.followsSystemAccent)
        #expect(!CustomTheme.osaurusLightPreset.followsSystemAccent)
    }

    @Test("decoding JSON without the flag defaults to false; round-trip preserves true")
    func decodingDefaultsAndRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Round-trip preserves the flag.
        let encoded = try encoder.encode(CustomTheme.darkDefault)
        let roundTripped = try decoder.decode(CustomTheme.self, from: encoded)
        #expect(roundTripped.followsSystemAccent)

        // A legacy payload without the key decodes to false.
        var json = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        json.removeValue(forKey: "followsSystemAccent")
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let legacy = try decoder.decode(CustomTheme.self, from: legacyData)
        #expect(!legacy.followsSystemAccent)
    }

    @Test("applying the stored accent is an identity")
    func identityWhenAccentMatchesStoredValue() {
        let dark = CustomTheme.darkDefault.colors
        #expect(dark.applyingAccent("#0a84ff", isDark: true) == dark)
        // Case and prefix insensitive.
        #expect(dark.applyingAccent("0A84FF", isDark: true) == dark)

        let light = CustomTheme.lightDefault.colors
        #expect(light.applyingAccent("#007aff", isDark: false) == light)
    }

    @Test("invalid accent input leaves colors unchanged")
    func invalidAccentIsIgnored() {
        let colors = CustomTheme.darkDefault.colors
        #expect(colors.applyingAccent("not-a-color", isDark: true) == colors)
        #expect(colors.applyingAccent("#fff", isDark: true) == colors)
    }

    @Test("a new accent rewrites only the accent-adjacent fields")
    func derivationRewritesAccentAdjacentFieldsOnly() {
        let purple = "#a550a7"
        let base = CustomTheme.darkDefault.colors
        let derived = base.applyingAccent(purple, isDark: true)

        #expect(derived.accentColor == purple)
        #expect(derived.focusBorder == purple)
        #expect(derived.cursorColor == purple)
        #expect(derived.selectionColor == purple + "45")
        #expect(derived.accentColorLight != base.accentColorLight)
        #expect(derived.sidebarSelectedBackground != base.sidebarSelectedBackground)
        #expect(derived.infoColor == derived.accentColorLight)

        // Everything else stays authored.
        #expect(derived.primaryText == base.primaryText)
        #expect(derived.secondaryText == base.secondaryText)
        #expect(derived.primaryBackground == base.primaryBackground)
        #expect(derived.secondaryBackground == base.secondaryBackground)
        #expect(derived.sidebarBackground == base.sidebarBackground)
        #expect(derived.successColor == base.successColor)
        #expect(derived.warningColor == base.warningColor)
        #expect(derived.errorColor == base.errorColor)
        #expect(derived.cardBackground == base.cardBackground)
        #expect(derived.buttonBackground == base.buttonBackground)
        #expect(derived.inputBackground == base.inputBackground)
        #expect(derived.shadowColor == base.shadowColor)
        #expect(derived.placeholderText == base.placeholderText)
    }

    @Test("light derivation uses the light selection alpha and accent info color")
    func lightDerivationUsesLightRules() {
        let purple = "#a550a7"
        let base = CustomTheme.lightDefault.colors
        let derived = base.applyingAccent(purple, isDark: false)

        #expect(derived.selectionColor == purple + "26")
        #expect(derived.infoColor == purple)
        // Light selected-row color blends toward white, so it should be
        // much lighter than the accent itself.
        #expect(derived.sidebarSelectedBackground != base.sidebarSelectedBackground)
        #expect(derived.sidebarSelectedBackground.hasPrefix("#"))
    }
}
