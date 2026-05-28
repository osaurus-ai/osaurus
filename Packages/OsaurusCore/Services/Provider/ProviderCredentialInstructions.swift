//
//  ProviderCredentialInstructions.swift
//  osaurus
//
//  Curated per-provider instructions for the credential prompt sheet.
//  Tells the user where to get their API key / how to sign in, and
//  what extra non-secret fields (host, deployment name, etc.) we need
//  alongside the secret for that provider type.
//
//  Only non-secret guidance lives here — actual keys and OAuth tokens
//  are never represented in this table. They flow exclusively through
//  the SwiftUI sheet's `@State` and on to Keychain via
//  `RemoteProviderKeychain`. The LLM never sees them.
//

import Foundation

/// How the user authenticates to a given provider. Drives which fields
/// the credential prompt sheet renders.
public enum ProviderAuthMethod: Sendable, Equatable {
    /// API key + optional secret HTTP headers.
    case apiKey
    /// OAuth flow handled by `OAuthSignInCoordinator` (Codex, OpenRouter, …).
    case oauth
}

/// One extra field the user has to fill in alongside the secret.
/// Used for Azure (endpoint + deployment), custom OpenAI-compatible
/// hosts (base URL), etc.
public struct ProviderCredentialField: Sendable, Equatable {
    public let key: String
    public let label: String
    public let placeholder: String
    public let isRequired: Bool
    public init(key: String, label: String, placeholder: String, isRequired: Bool) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.isRequired = isRequired
    }
}

/// Per-provider, non-secret guidance for the credential prompt sheet.
public struct ProviderCredentialInstructions: Sendable, Equatable {
    public let providerType: RemoteProviderType
    public let displayName: String
    public let authMethod: ProviderAuthMethod
    /// Marketing-grade URL the user can open to obtain credentials.
    public let getKeyURL: URL?
    /// One-line hint about the key's expected shape, e.g. "Keys start with `sk-ant-`."
    public let keyFormatHint: String?
    /// Optional extra fields (Azure endpoint, OpenAI-compatible host, etc.).
    public let extraFields: [ProviderCredentialField]
    /// Default `RemoteProviderAuthType` to assign to the persisted record
    /// once the user finishes the sheet. Distinct from `authMethod`
    /// because the manager-side enum has historical case names that
    /// don't map 1:1 to UI labels.
    public let storageAuthType: RemoteProviderAuthType
    /// Stable `ProviderPreset.rawValue` used by UI to resolve branding
    /// (gradient, icon asset, help steps). Lives here as a string so this
    /// module can stay free of UI imports. Empty means "no preset" — the
    /// sheet falls back to a generic key glyph.
    public let presetId: String

    public init(
        providerType: RemoteProviderType,
        displayName: String,
        authMethod: ProviderAuthMethod,
        getKeyURL: URL? = nil,
        keyFormatHint: String? = nil,
        extraFields: [ProviderCredentialField] = [],
        storageAuthType: RemoteProviderAuthType,
        presetId: String = ""
    ) {
        self.providerType = providerType
        self.displayName = displayName
        self.authMethod = authMethod
        self.getKeyURL = getKeyURL
        self.keyFormatHint = keyFormatHint
        self.extraFields = extraFields
        self.storageAuthType = storageAuthType
        self.presetId = presetId
    }
}

/// Static catalog of credential instructions keyed by `RemoteProviderType`.
/// Tools like `osaurus_provider_add` resolve their per-provider guidance
/// through `ProviderCredentialInstructionsCatalog.entry(for:)` so a new
/// provider only needs one entry added here.
public enum ProviderCredentialInstructionsCatalog {
    /// Returns curated instructions for `type`, or a permissive fallback
    /// (API-key-only) when the type has no curated entry. Callers should
    /// always get *some* envelope so the sheet has fields to render.
    public static func entry(for type: RemoteProviderType) -> ProviderCredentialInstructions {
        switch type {
        case .anthropic:
            return ProviderCredentialInstructions(
                providerType: .anthropic,
                displayName: L("Anthropic"),
                authMethod: .apiKey,
                getKeyURL: URL(string: "https://console.anthropic.com/settings/keys"),
                keyFormatHint: L("Keys start with sk-ant-."),
                storageAuthType: .apiKey,
                presetId: "anthropic"
            )
        case .openResponses:
            return ProviderCredentialInstructions(
                providerType: .openResponses,
                displayName: L("OpenAI"),
                authMethod: .apiKey,
                getKeyURL: URL(string: "https://platform.openai.com/api-keys"),
                keyFormatHint: L("Keys start with sk-."),
                storageAuthType: .apiKey,
                presetId: "openai"
            )
        case .openaiLegacy:
            return ProviderCredentialInstructions(
                providerType: .openaiLegacy,
                displayName: L("OpenAI-Compatible Server"),
                authMethod: .apiKey,
                getKeyURL: nil,
                keyFormatHint: L("Any key your server accepts. Set the host below."),
                extraFields: [
                    ProviderCredentialField(
                        key: "host",
                        label: L("Host"),
                        placeholder: L("api.example.com"),
                        isRequired: true
                    )
                ],
                storageAuthType: .apiKey,
                presetId: "custom"
            )
        case .azureOpenAI:
            return ProviderCredentialInstructions(
                providerType: .azureOpenAI,
                displayName: L("Azure OpenAI"),
                authMethod: .apiKey,
                getKeyURL: URL(string: "https://portal.azure.com/"),
                keyFormatHint: L("Use the resource key from Azure Portal."),
                extraFields: [
                    ProviderCredentialField(
                        key: "host",
                        label: L("Endpoint"),
                        placeholder: L("<resource>.openai.azure.com"),
                        isRequired: true
                    ),
                    ProviderCredentialField(
                        key: "deployment",
                        label: L("Deployment"),
                        placeholder: L("gpt-4o"),
                        isRequired: true
                    ),
                ],
                storageAuthType: .apiKey,
                presetId: "azureOpenAI"
            )
        case .gemini:
            return ProviderCredentialInstructions(
                providerType: .gemini,
                displayName: L("Google Gemini"),
                authMethod: .apiKey,
                getKeyURL: URL(string: "https://aistudio.google.com/apikey"),
                keyFormatHint: L("Get a free key from Google AI Studio."),
                storageAuthType: .apiKey,
                presetId: "google"
            )
        case .openAICodex:
            return ProviderCredentialInstructions(
                providerType: .openAICodex,
                displayName: L("OpenAI Codex"),
                authMethod: .oauth,
                getKeyURL: URL(string: "https://chatgpt.com/codex"),
                keyFormatHint: L("Sign in with your ChatGPT account."),
                storageAuthType: .openAICodexOAuth,
                presetId: "openai"
            )
        case .osaurus:
            return ProviderCredentialInstructions(
                providerType: .osaurus,
                displayName: L("Osaurus Agent"),
                authMethod: .apiKey,
                getKeyURL: nil,
                keyFormatHint: L("Paste the pairing API key from the remote Osaurus."),
                storageAuthType: .apiKey,
                presetId: ""
            )
        }
    }
}
