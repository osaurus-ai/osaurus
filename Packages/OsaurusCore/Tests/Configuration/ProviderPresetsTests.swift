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
}
