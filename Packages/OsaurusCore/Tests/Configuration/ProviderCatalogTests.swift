//
//  ProviderCatalogTests.swift
//  osaurusTests
//
//  Pins the data-driven provider picker catalog: placement grouping, the
//  dual-mode (OAuth + API key) providers appearing at both levels, the derived
//  API-key sub-list, and full coverage of the known presets. The picker in
//  onboarding, the settings add-sheet, and the empty state all render from this,
//  so a regression here silently breaks every surface.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ProviderCatalog")
struct ProviderCatalogTests {

    // MARK: - Top level

    @Test func topLevel_isTheThreeOAuthProvidersInOrder() throws {
        #expect(ProviderCatalog.topLevel.map(\.preset) == [.openai, .xai, .openrouter])
    }

    @Test func topLevel_entriesLeadWithOAuth() throws {
        for entry in ProviderCatalog.topLevel {
            #expect(entry.placement == .oauthTopLevel)
            #expect(entry.authMethods.first?.isOAuth == true)
            #expect(entry.primaryOAuthKind != nil)
        }
    }

    // MARK: - Dual-mode entries appear at both levels

    @Test func dualModeProviders_appearAtTopLevelAndInAPIKeyList() throws {
        let apiKeySection = try #require(
            ProviderCatalog.apiKeyGroups(includeAzure: true).first { $0.id == "apiKey" }
        )
        let apiKeyPresets = Set(apiKeySection.entries.map(\.preset))
        for preset in [ProviderPreset.openai, .xai, .openrouter] {
            let entry = try #require(ProviderCatalog.entry(for: preset))
            #expect(entry.placement == .oauthTopLevel)
            #expect(entry.supportsAPIKey)
            #expect(apiKeyPresets.contains(preset))
        }
    }

    // MARK: - API-key sub-list derivation

    @Test func apiKeyGroups_apiKeySectionIsAlphabeticalAndExcludesLocalCustom() throws {
        let section = try #require(
            ProviderCatalog.apiKeyGroups(includeAzure: true).first { $0.id == "apiKey" }
        )
        let presets = section.entries.map(\.preset)
        #expect(!presets.contains(.ollama))
        #expect(!presets.contains(.custom))

        let names = section.entries.map { $0.preset.name }
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test func apiKeyGroups_omitAzureWhenRequested() throws {
        let onboarding = ProviderCatalog.apiKeyGroups(includeAzure: false).flatMap { $0.entries.map(\.preset) }
        #expect(!onboarding.contains(.azureOpenAI))

        let settings = ProviderCatalog.apiKeyGroups(includeAzure: true).flatMap { $0.entries.map(\.preset) }
        #expect(settings.contains(.azureOpenAI))
    }

    @Test func apiKeyGroups_haveLocalAndCustomSections() throws {
        let groups = ProviderCatalog.apiKeyGroups(includeAzure: true)
        let local = try #require(groups.first { $0.id == "local" })
        let custom = try #require(groups.first { $0.id == "custom" })
        #expect(local.entries.map(\.preset) == [.ollama])
        #expect(custom.entries.map(\.preset) == [.custom])
    }

    // MARK: - Coverage

    @Test func catalog_coversAllKnownPresetsPlusCustom() throws {
        let covered = Set(ProviderCatalog.entries.map(\.preset))
        let expected = Set(ProviderPreset.knownPresets).union([.custom])
        #expect(covered == expected)
    }

    @Test func entry_lookupResolvesEveryEntry() throws {
        for entry in ProviderCatalog.entries {
            #expect(ProviderCatalog.entry(for: entry.preset)?.preset == entry.preset)
        }
    }

    // MARK: - Subtitles / copy

    @Test func pickerSubtitle_dualModeReflectsEntryPoint() throws {
        let openai = try #require(ProviderCatalog.entry(for: .openai))
        // OAuth-first row describes sign-in; api-key row describes the pasted key.
        #expect(openai.pickerSubtitle(preferAPIKey: false) == ProviderOAuthKind.openAICodex.subtitle)
        #expect(openai.pickerSubtitle(preferAPIKey: true).contains("platform.openai.com"))
    }

    @Test func pickerSubtitle_customIsAlwaysExamples() throws {
        let custom = try #require(ProviderCatalog.entry(for: .custom))
        #expect(custom.pickerSubtitle(preferAPIKey: false) == "Together AI, LM Studio, and more")
        #expect(custom.pickerSubtitle(preferAPIKey: true) == "Together AI, LM Studio, and more")
    }

    @Test func primaryOAuthKind_isNilForKeyOnlyProviders() throws {
        #expect(ProviderCatalog.entry(for: .anthropic)?.primaryOAuthKind == nil)
        #expect(ProviderCatalog.entry(for: .ollama)?.primaryOAuthKind == nil)
        #expect(ProviderCatalog.entry(for: .openai)?.primaryOAuthKind == .openAICodex)
        #expect(ProviderCatalog.entry(for: .xai)?.primaryOAuthKind == .xai)
        #expect(ProviderCatalog.entry(for: .openrouter)?.primaryOAuthKind == .openRouter)
    }

    @Test func oauthKind_copyIsNonEmptyAndDistinct() throws {
        let kinds: [ProviderOAuthKind] = [.openAICodex, .openRouter, .xai]
        let ctas = kinds.map(\.ctaTitle)
        let subtitles = kinds.map(\.subtitle)
        #expect(ctas.allSatisfy { !$0.isEmpty })
        #expect(subtitles.allSatisfy { !$0.isEmpty })
        #expect(Set(ctas).count == kinds.count)
        #expect(Set(subtitles).count == kinds.count)
    }

    // MARK: - Bridge parity

    @Test func presetBridge_matchesCatalog() throws {
        #expect(ProviderPreset.oauthProviders == ProviderCatalog.topLevel.map(\.preset))

        let bridgeGroups = ProviderPreset.apiKeyPickerGroups(includeAzure: true)
        let catalogGroups = ProviderCatalog.apiKeyGroups(includeAzure: true)
        #expect(bridgeGroups.map(\.id) == catalogGroups.map(\.id))
        for (bridge, catalog) in zip(bridgeGroups, catalogGroups) {
            #expect(bridge.presets == catalog.entries.map(\.preset))
        }
    }
}
