//
//  ProviderPresetsTests.swift
//  osaurusTests
//
//  Pins the built-in provider preset catalog — catches accidental renames
//  or host changes that would silently break preset matching for users
//  upgrading from a previous version.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ProviderPreset")
struct ProviderPresetsTests {

    @Test func atlasCloudPreset_configurationMatchesOfficialAPI() throws {
        let config = ProviderPreset.atlasCloud.configuration

        #expect(config.name == "AtlasCloud")
        #expect(config.host == "api.atlascloud.ai")
        #expect(config.providerProtocol == .https)
        #expect(config.port == nil)
        #expect(config.basePath == "/v1")
        #expect(config.authType == .apiKey)
        #expect(config.providerType == .openaiLegacy)
    }

    @Test func atlasCloudPreset_includesSeedManualModels() throws {
        let config = ProviderPreset.atlasCloud.configuration

        #expect(config.defaultManualModelIds.contains("deepseek-ai/DeepSeek-V3-0324"))
        #expect(config.defaultManualModelIds.contains("qwen/qwen3-coder-next"))
        #expect(config.defaultManualModelIds.contains("moonshotai/kimi-k2.5"))
        #expect(config.defaultManualModelIds.contains("zai-org/glm-5"))
        #expect(config.defaultManualModelIds.contains("minimaxai/minimax-m2.7"))
    }

    @Test func atlasCloudPreset_isListedAsKnownPreset() throws {
        #expect(ProviderPreset.knownPresets.contains(.atlasCloud))
    }

    @Test func matching_providerWithAtlasCloudHost_resolvesToAtlasCloudPreset() throws {
        let provider = RemoteProvider(
            name: "My AtlasCloud",
            host: "api.atlascloud.ai",
            basePath: "/v1",
            authType: .apiKey,
            providerType: .openaiLegacy
        )

        #expect(ProviderPreset.matching(provider: provider) == .atlasCloud)
    }

    @Test func atlasCloudPreset_chatEndpointResolvesToChatCompletions() throws {
        let provider = RemoteProvider(
            name: "AtlasCloud",
            host: ProviderPreset.atlasCloud.configuration.host,
            basePath: ProviderPreset.atlasCloud.configuration.basePath,
            authType: .apiKey,
            providerType: ProviderPreset.atlasCloud.configuration.providerType
        )

        #expect(
            provider.url(for: provider.providerType.chatEndpoint)?.absoluteString
                == "https://api.atlascloud.ai/v1/chat/completions"
        )
    }

    @Test func deepseekPreset_configurationMatchesOfficialAPI() throws {
        let config = ProviderPreset.deepseek.configuration

        #expect(config.name == "DeepSeek")
        #expect(config.host == "api.deepseek.com")
        #expect(config.providerProtocol == .https)
        #expect(config.port == nil)
        #expect(config.basePath == "/v1")
        #expect(config.authType == .apiKey)
        #expect(config.providerType == .openaiLegacy)
    }

    @Test func deepseekPreset_isListedAsKnownPreset() throws {
        #expect(ProviderPreset.knownPresets.contains(.deepseek))
    }

    @Test func matching_providerWithDeepSeekHost_resolvesToDeepSeekPreset() throws {
        let provider = RemoteProvider(
            name: "My DeepSeek",
            host: "api.deepseek.com",
            basePath: "/v1",
            authType: .apiKey,
            providerType: .openaiLegacy
        )

        #expect(ProviderPreset.matching(provider: provider) == .deepseek)
    }

    @Test func deepseekPreset_chatEndpointResolvesToChatCompletions() throws {
        let provider = RemoteProvider(
            name: "DeepSeek",
            host: ProviderPreset.deepseek.configuration.host,
            basePath: ProviderPreset.deepseek.configuration.basePath,
            authType: .apiKey,
            providerType: ProviderPreset.deepseek.configuration.providerType
        )

        #expect(
            provider.url(for: provider.providerType.chatEndpoint)?.absoluteString
                == "https://api.deepseek.com/v1/chat/completions"
        )
    }

    @Test func minimaxPreset_configurationMatchesOfficialAPI() throws {
        let config = ProviderPreset.minimax.configuration

        #expect(config.name == "MiniMax")
        #expect(config.host == "api.minimax.io")
        #expect(config.providerProtocol == .https)
        #expect(config.port == nil)
        #expect(config.basePath == "/v1")
        #expect(config.authType == .apiKey)
        #expect(config.providerType == .openaiLegacy)
    }

    @Test func minimaxPreset_includesSeedManualModels() throws {
        let config = ProviderPreset.minimax.configuration

        #expect(config.defaultManualModelIds.contains("MiniMax-M3"))
        #expect(config.defaultManualModelIds.contains("MiniMax-M2.7"))
        #expect(config.defaultManualModelIds.contains("MiniMax-M2"))
    }

    @Test func minimaxPreset_isListedAsKnownPreset() throws {
        #expect(ProviderPreset.knownPresets.contains(.minimax))
    }

    @Test func matching_providerWithMiniMaxHost_resolvesToMiniMaxPreset() throws {
        let provider = RemoteProvider(
            name: "My MiniMax",
            host: "api.minimax.io",
            basePath: "/v1",
            authType: .apiKey,
            providerType: .openaiLegacy
        )

        #expect(ProviderPreset.matching(provider: provider) == .minimax)
    }

    @Test func minimaxPreset_chatEndpointResolvesToChatCompletions() throws {
        let provider = RemoteProvider(
            name: "MiniMax",
            host: ProviderPreset.minimax.configuration.host,
            basePath: ProviderPreset.minimax.configuration.basePath,
            authType: .apiKey,
            providerType: ProviderPreset.minimax.configuration.providerType
        )

        #expect(
            provider.url(for: provider.providerType.chatEndpoint)?.absoluteString
                == "https://api.minimax.io/v1/chat/completions"
        )
    }

    // MARK: - OAuth-first picker grouping

    @Test func oauthProviders_areTheThreeOneClickProviders() throws {
        #expect(ProviderPreset.oauthProviders == [.openai, .xai, .openrouter])
    }

    @Test func apiKeyProviders_includeDualModeProvidersButNotLocalOrCustom() throws {
        let keyVendors = ProviderPreset.apiKeyProviders
        // The OAuth-first presets each also expose a paste-a-key path, so they
        // appear in the API-key list too (no in-form fork).
        #expect(keyVendors.contains(.openai))
        #expect(keyVendors.contains(.xai))
        #expect(keyVendors.contains(.openrouter))
        #expect(keyVendors.contains(.anthropic))
        #expect(keyVendors.contains(.azureOpenAI))
        // Ollama (local, no key) and Custom (its own section) stay out.
        #expect(!keyVendors.contains(.ollama))
        #expect(!keyVendors.contains(.custom))
    }

    @Test func apiKeyPickerGroups_omitAzureWhenRequested() throws {
        let onboarding = ProviderPreset.apiKeyPickerGroups(includeAzure: false)
        let onboardingPresets = onboarding.flatMap { $0.presets }
        #expect(!onboardingPresets.contains(.azureOpenAI))

        let settings = ProviderPreset.apiKeyPickerGroups(includeAzure: true)
        let settingsPresets = settings.flatMap { $0.presets }
        #expect(settingsPresets.contains(.azureOpenAI))
    }

    @Test func apiKeyPickerGroups_includeLocalAndCustomSections() throws {
        let groups = ProviderPreset.apiKeyPickerGroups(includeAzure: true)
        #expect(groups.contains { $0.presets == [.ollama] })
        #expect(groups.contains { $0.presets == [.custom] })
    }

    /// The OAuth top level plus the "Use an API key" sub-list (settings variant)
    /// must collectively cover every known preset plus custom — nothing dropped.
    @Test func oauthAndAPIKeyPicker_coverAllKnownPresetsPlusCustom() throws {
        let topLevel = Set(ProviderPreset.oauthProviders)
        let subList = Set(
            ProviderPreset.apiKeyPickerGroups(includeAzure: true).flatMap { $0.presets }
        )
        let covered = topLevel.union(subList)
        let expected = Set(ProviderPreset.knownPresets).union([.custom])
        #expect(covered == expected)
    }
}
