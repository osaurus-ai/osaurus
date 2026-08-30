//
//  ConfigProviderPresets.swift
//  osaurus
//
//  Chat/document-friendly cloud-provider preset ids and their resolution
//  onto `ProviderPreset` / the special OAuth + peer-agent paths. Moved
//  here from the old `osaurus_provider` tool when the per-domain tools
//  were replaced by the declarative `osaurus_config` surface.
//

import Foundation

/// Resolution outcome for a document `provider` value. `.preset` is the
/// canonical path; the other two carry the special storage paths that have
/// no `ProviderPreset` case (`.codexOAuth` uses the OpenAI brand but a
/// distinct OAuth flow, `.osaurusAgent` is a peer agent).
enum ProviderToolResolution {
    case preset(ProviderPreset)
    case codexOAuth
    case osaurusAgent

    /// `RemoteProviderType` the manager should persist with.
    var providerType: RemoteProviderType {
        switch self {
        case .preset(let preset): return preset.configuration.providerType
        case .codexOAuth: return .openAICodex
        case .osaurusAgent: return .osaurus
        }
    }
}

enum ConfigProviderPresets {
    /// Document-friendly provider ids. New ids should be added here first.
    static let providerAliases: [String: ProviderToolResolution] = [
        "anthropic": .preset(.anthropic),
        "openai": .preset(.openai),
        "azure_openai": .preset(.azureOpenAI),
        "google": .preset(.google),
        "gemini": .preset(.google),
        "xai": .preset(.xai),
        "deepseek": .preset(.deepseek),
        "venice": .preset(.venice),
        "openrouter": .preset(.openrouter),
        "ollama": .preset(.ollama),
        "custom": .preset(.custom),
        "openai_compatible": .preset(.custom),
        "codex_oauth": .codexOAuth,
        "osaurus_agent": .osaurusAgent,
    ]

    /// Canonical list surfaced in schema docs and error messages.
    static let canonicalIds: [String] = [
        "anthropic", "openai", "codex_oauth", "azure_openai", "google",
        "xai", "deepseek", "venice", "openrouter", "ollama",
        "custom", "osaurus_agent",
    ]

    static func resolve(_ value: String?) -> ProviderToolResolution? {
        guard let value else { return nil }
        return providerAliases[value.lowercased()]
    }

    static var canonicalIdsList: String {
        canonicalIds.joined(separator: ", ")
    }

    /// The provider slice the declarative document manages. Ephemeral
    /// providers (Bonjour-discovered peer agents and the eval harness's
    /// in-memory run/judge providers) are memory-only runtime state, not
    /// user configuration: they must never be exported, matched for
    /// update, or pruned by a declarative apply.
    @MainActor
    static func manageableProviders() -> [RemoteProvider] {
        let manager = RemoteProviderManager.shared
        return manager.configuration.providers.filter { !manager.isEphemeral(id: $0.id) }
    }

    /// Best-effort reverse mapping for export: identify the preset by its
    /// default host, falling back to the API-family raw value. Only
    /// informational on export — matching during plan/apply is by `name`.
    static func exportId(for provider: RemoteProvider) -> String {
        switch provider.providerType {
        case .openAICodex: return "codex_oauth"
        case .osaurus: return "osaurus_agent"
        case .osaurusRouter: return "osaurus_agent"
        case .anthropic: return "anthropic"
        case .azureOpenAI: return "azure_openai"
        case .gemini: return "google"
        case .openResponses, .openaiLegacy:
            for id in canonicalIds {
                guard case .preset(let preset)? = providerAliases[id] else { continue }
                if preset.configuration.host == provider.host { return id }
            }
            return "custom"
        }
    }
}
