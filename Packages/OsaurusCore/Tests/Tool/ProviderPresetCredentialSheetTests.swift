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
    func ollamaPreset_keyFormatHintAdvertisesOptionalKey() {
        // The sheet's `canSave` / `runTestConnection` / `save` paths all
        // gate on `storageAuthType == .none` to allow an empty key. The
        // catalog must keep `.none` (and a hint that says it's optional)
        // so that contract stays honest.
        let entry = ProviderCredentialInstructionsCatalog.entry(for: .ollama)
        #expect(entry.storageAuthType == .none)
        #expect(entry.keyFormatHint?.contains("blank") == true)
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
        // Explicitly qualify the enum — both `ProviderPreset` and
        // `RemoteProviderType` carry these cases, and `supportsOAuth` has
        // overloads for both, so `.anthropic` / `.openrouter` are ambiguous
        // on their own.
        #expect(OAuthSignInCoordinator.supportsOAuth(ProviderPreset.openrouter) == true)
        #expect(OAuthSignInCoordinator.supportsOAuth(ProviderPreset.deepseek) == false)
        #expect(OAuthSignInCoordinator.supportsOAuth(ProviderPreset.anthropic) == false)
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

    // MARK: - Tool schema contract

    @Test
    func providerAddTool_marksProviderAsRequiredAlongsideName() {
        // The schema must match the runtime behavior: `execute` errors when
        // neither `provider` nor `provider_type` is supplied, so the schema
        // had been lying to the model. Lock the contract here so it can't
        // silently drift back to `name`-only.
        let tool = OsaurusProviderAddTool()
        guard case .object(let schema) = tool.parameters else {
            Issue.record("provider_add schema must be an object")
            return
        }
        guard case .array(let required) = schema["required"] else {
            Issue.record("provider_add schema must declare a `required` array")
            return
        }
        let names: [String] = required.compactMap { value in
            if case .string(let s) = value { return s }
            return nil
        }
        #expect(names.contains("name"))
        #expect(names.contains("provider"))
        // `provider_type` is the deprecated alias — it must NOT be required.
        #expect(names.contains("provider_type") == false)
    }

    // MARK: - Azure deployments → manualModelIds

    @Test
    func parseManualModelIds_singleEntryYieldsOneId() {
        #expect(OsaurusProviderAddTool.parseManualModelIds("gpt-4o") == ["gpt-4o"])
    }

    @Test
    func parseManualModelIds_commaAndNewlineSeparated() {
        let parsed = OsaurusProviderAddTool.parseManualModelIds(
            "gpt-4o, gpt-4o-mini\nprod-chat"
        )
        #expect(parsed == ["gpt-4o", "gpt-4o-mini", "prod-chat"])
    }

    @Test
    func parseManualModelIds_dedupesCaseInsensitivelyKeepingFirstSpelling() {
        // Matches `RemoteProviderEditSheet.parseManualModelIds` — the first
        // spelling wins so chat-driven Azure providers persist identically
        // to those configured via Settings.
        let parsed = OsaurusProviderAddTool.parseManualModelIds(
            "GPT-4o, gpt-4o,  gpt-4o "
        )
        #expect(parsed == ["GPT-4o"])
    }

    @Test
    func parseManualModelIds_emptyAndWhitespaceCollapseToEmptyArray() {
        #expect(OsaurusProviderAddTool.parseManualModelIds("") == [])
        #expect(OsaurusProviderAddTool.parseManualModelIds(" , \n , ") == [])
    }

    @Test
    func azureCatalogEntry_advertisesMultiDeploymentInPlaceholderAndHelpText() {
        // The Settings UI lets users register many Azure deployments at
        // once via comma/newline-separated text. The chat flow now mirrors
        // that — guard the user-facing hints so they don't regress to
        // "single deployment" wording.
        let entry = ProviderCredentialInstructionsCatalog.entry(for: .azureOpenAI)
        guard let deployment = entry.extraFields.first(where: { $0.key == "deployment" }) else {
            Issue.record("Azure catalog entry must include a deployment field")
            return
        }
        #expect(deployment.placeholder.contains(","))
        #expect(deployment.helpText?.isEmpty == false)
    }

    @Test
    func reservedExtraKeys_blockHostAndDeploymentFromCustomHeaders() {
        // `.openaiLegacy` providers pass through unknown extra fields as
        // custom headers, so the reserved keys must stay opaque or Azure
        // would leak its endpoint into the headers map.
        #expect(OsaurusProviderAddTool.reservedExtraKeys.contains("host"))
        #expect(OsaurusProviderAddTool.reservedExtraKeys.contains("deployment"))
    }
}
