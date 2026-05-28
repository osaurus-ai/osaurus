//
//  ProviderPresetCredentialSheetTests.swift
//  OsaurusCoreTests
//
//  Pins down the preset-as-single-source-of-truth contract that the
//  chat-driven `osaurus_provider_add` tool relies on:
//
//   * `ProviderCredentialRequest(preset:)` derives the right
//     `providerType` and `instructions` from each preset, so OpenRouter
//     gets the OAuth catalog entry instead of the generic
//     OpenAI-compatible one.
//   * `OAuthSignInCoordinator.supportsOAuth(_:)` opts OpenRouter in via
//     the new preset-keyed overload (and still recognizes Codex via the
//     legacy provider-type overload).
//   * Vendor presets that share `RemoteProviderType.openaiLegacy`
//     (DeepSeek, OpenRouter, xAI, Venice, Ollama) carry their own host
//     in `preset.configuration`, not the generic `api.openai.com`.
//   * `ProviderToolShared.resolve(_:)` accepts the canonical `provider`
//     ids *and* the deprecated `provider_type` aliases ("openrouter",
//     "openai_compatible", etc.).
//   * The legacy `ProviderCredentialRequest(providerType:)` init still
//     produces correct instructions for callers that only have a
//     `RemoteProviderType` (rotate-credentials path on existing
//     providers, older tests).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ProviderPresetCredentialSheetTests {

    // MARK: - Preset-keyed request

    @Test
    func openrouterPreset_requestsOAuthFlow() {
        let request = ProviderCredentialRequest(
            preset: .openrouter,
            providerName: "OpenRouter",
            mode: .addNew
        )
        #expect(request.preset == .openrouter)
        #expect(request.providerType == .openaiLegacy)
        #expect(request.instructions.authMethod == .oauth)
        #expect(request.instructions.presetId == "openrouter")
    }

    @Test
    func deepseekPreset_usesApiKeyAndVendorHost() {
        let request = ProviderCredentialRequest(
            preset: .deepseek,
            providerName: "DeepSeek",
            mode: .addNew
        )
        #expect(request.preset == .deepseek)
        #expect(request.providerType == .openaiLegacy)
        #expect(request.instructions.authMethod == .apiKey)
        #expect(ProviderPreset.deepseek.configuration.host == "api.deepseek.com")
    }

    @Test
    func customPreset_requiresHostExtraField() {
        let request = ProviderCredentialRequest(
            preset: .custom,
            providerName: "My Server",
            mode: .addNew
        )
        let hostField = request.instructions.extraFields.first(where: { $0.key == "host" })
        #expect(hostField != nil)
        #expect(hostField?.isRequired == true)
    }

    @Test
    func ollamaPreset_usesLocalhostAndNoneStorageAuth() {
        let request = ProviderCredentialRequest(
            preset: .ollama,
            providerName: "Ollama",
            mode: .addNew
        )
        #expect(request.preset == .ollama)
        #expect(request.instructions.storageAuthType == .none)
        let cfg = ProviderPreset.ollama.configuration
        #expect(cfg.host == "localhost")
        #expect(cfg.port == 11434)
    }

    @Test
    func everyKnownPresetHasCatalogEntry() {
        // Sanity guard so adding a new preset case forces a catalog
        // entry — otherwise the chat sheet would render an empty form.
        for preset in ProviderPreset.allCases {
            let entry = ProviderCredentialInstructionsCatalog.entry(for: preset)
            #expect(entry.presetId == preset.rawValue)
            #expect(entry.displayName.isEmpty == false)
        }
    }

    // MARK: - Legacy back-compat init

    @Test
    func legacyInit_anthropic_keepsAnthropicInstructions() {
        let request = ProviderCredentialRequest(
            providerType: .anthropic,
            providerName: "Anthropic",
            mode: .addNew
        )
        #expect(request.preset == .anthropic)
        #expect(request.instructions.providerType == .anthropic)
    }

    @Test
    func legacyInit_codex_keepsOAuthEntry() {
        let request = ProviderCredentialRequest(
            providerType: .openAICodex,
            providerName: "Codex",
            mode: .addNew
        )
        #expect(request.preset == .openai)
        #expect(request.providerType == .openAICodex)
        #expect(request.instructions.authMethod == .oauth)
    }

    @Test
    func legacyInit_osaurusAgent_carriesNilPreset() {
        let request = ProviderCredentialRequest(
            providerType: .osaurus,
            providerName: "Peer",
            mode: .addNew
        )
        #expect(request.preset == nil)
        #expect(request.providerType == .osaurus)
        #expect(request.instructions.storageAuthType == .apiKey)
    }

    @Test
    func legacyInit_openaiLegacy_fallsBackToCustom() {
        // The legacy init can't disambiguate `.openaiLegacy` (shared by
        // five vendor presets), so it has to fall back to `.custom`.
        // New callers must use the preset-keyed init instead.
        let request = ProviderCredentialRequest(
            providerType: .openaiLegacy,
            providerName: "Mystery",
            mode: .addNew
        )
        #expect(request.preset == .custom)
        let hostField = request.instructions.extraFields.first(where: { $0.key == "host" })
        #expect(hostField != nil)
    }

    // MARK: - OAuth coordinator dispatch

    @Test
    func coordinator_supportsOAuth_recognizesOpenrouterPreset() {
        #expect(OAuthSignInCoordinator.supportsOAuth(.openrouter) == true)
        #expect(OAuthSignInCoordinator.supportsOAuth(.deepseek) == false)
        #expect(OAuthSignInCoordinator.supportsOAuth(.anthropic) == false)
    }

    @Test
    func coordinator_legacySupportsOAuth_recognizesCodex() {
        #expect(OAuthSignInCoordinator.supportsOAuth(RemoteProviderType.openAICodex) == true)
        #expect(OAuthSignInCoordinator.supportsOAuth(RemoteProviderType.openaiLegacy) == false)
    }

    // MARK: - Tool argument resolver

    @Test
    func resolver_acceptsCanonicalProviderIds() {
        // Every id surfaced in the tool schema description must resolve;
        // a typo here would render the corresponding vendor unreachable
        // from chat even though the catalog has its entry.
        for id in ProviderToolShared.canonicalIds {
            #expect(ProviderToolShared.resolve(id) != nil, "unresolved id: \(id)")
        }
    }

    @Test
    func resolver_resolvesOpenrouterToOpenrouterPreset() {
        guard case .preset(let preset) = ProviderToolShared.resolve("openrouter") else {
            Issue.record("openrouter must resolve to a preset")
            return
        }
        #expect(preset == .openrouter)
    }

    @Test
    func resolver_legacyOpenaiCompatibleAliasResolvesToCustom() {
        // The chat tool used to expose `openai_compatible` as a sibling
        // of `openrouter`. Keep it accepted but route it to `.custom`
        // so the sheet asks for a host instead of inheriting OpenAI
        // branding by accident.
        guard case .preset(let preset) = ProviderToolShared.resolve("openai_compatible") else {
            Issue.record("openai_compatible must resolve to a preset")
            return
        }
        #expect(preset == .custom)
    }

    @Test
    func resolver_codexOauthAliasIsSpecialCase() {
        if case .codexOAuth = ProviderToolShared.resolve("codex_oauth") {
            return
        }
        Issue.record("codex_oauth must resolve to the codexOAuth special case")
    }

    @Test
    func resolver_osaurusAgentAliasIsSpecialCase() {
        if case .osaurusAgent = ProviderToolShared.resolve("osaurus_agent") {
            return
        }
        Issue.record("osaurus_agent must resolve to the osaurusAgent special case")
    }

    @Test
    func resolver_unknownIdReturnsNil() {
        #expect(ProviderToolShared.resolve("nonexistent_vendor") == nil)
    }

    @Test
    func resolver_isCaseInsensitive() {
        #expect(ProviderToolShared.resolve("OpenRouter") != nil)
        #expect(ProviderToolShared.resolve("DEEPSEEK") != nil)
    }
}
