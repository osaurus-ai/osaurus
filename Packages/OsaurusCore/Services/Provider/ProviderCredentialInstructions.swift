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
    /// Optional one-liner shown beneath the field. Use for value-format hints
    /// (e.g. "Comma or newline-separated") that wouldn't fit in the placeholder.
    public let helpText: String?
    public let isRequired: Bool
    public init(
        key: String,
        label: String,
        placeholder: String,
        helpText: String? = nil,
        isRequired: Bool
    ) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.helpText = helpText
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

/// Static catalog of credential instructions keyed by `ProviderPreset`.
/// `ProviderPreset` is the single source of truth across the chat
/// credential prompt and the Settings sheet, so vendors that share a
/// `RemoteProviderType` (OpenRouter, DeepSeek, xAI, Venice, Ollama all
/// use `.openaiLegacy`) each get their own entry with vendor-specific
/// branding, OAuth path, and key-format hints.
public enum ProviderCredentialInstructionsCatalog {
    /// Returns curated instructions for `preset`. Every preset has an
    /// entry, so the sheet always has fields to render.
    public static func entry(for preset: ProviderPreset) -> ProviderCredentialInstructions {
        let providerType = preset.configuration.providerType
        let getKeyURL = preset.consoleURL.isEmpty ? nil : URL(string: preset.consoleURL)
        switch preset {
        case .anthropic:
            return ProviderCredentialInstructions(
                providerType: providerType,
                displayName: L("Anthropic"),
                authMethod: .apiKey,
                getKeyURL: getKeyURL,
                keyFormatHint: L("Keys start with sk-ant-."),
                storageAuthType: .apiKey,
                presetId: preset.rawValue
            )
        case .openai:
            return ProviderCredentialInstructions(
                providerType: providerType,
                displayName: L("OpenAI"),
                authMethod: .apiKey,
                getKeyURL: getKeyURL,
                keyFormatHint: L("Keys start with sk-."),
                storageAuthType: .apiKey,
                presetId: preset.rawValue
            )
        case .azureOpenAI:
            return ProviderCredentialInstructions(
                providerType: providerType,
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
                        label: L("Deployments"),
                        placeholder: L("gpt-4o, gpt-4o-mini"),
                        helpText: L(
                            "One or more Azure deployment names — comma or newline-separated. Stored as the provider's model list."
                        ),
                        isRequired: true
                    ),
                ],
                storageAuthType: .apiKey,
                presetId: preset.rawValue
            )
        case .atlasCloud:
            return ProviderCredentialInstructions(
                providerType: providerType,
                displayName: L("AtlasCloud"),
                authMethod: .apiKey,
                getKeyURL: getKeyURL,
                keyFormatHint: L("Use an AtlasCloud API key from the AtlasCloud console."),
                storageAuthType: .apiKey,
                presetId: preset.rawValue
            )
        case .google:
            return ProviderCredentialInstructions(
                providerType: providerType,
                displayName: L("Google Gemini"),
                authMethod: .apiKey,
                getKeyURL: getKeyURL,
                keyFormatHint: L("Get a free key from Google AI Studio."),
                storageAuthType: .apiKey,
                presetId: preset.rawValue
            )
        case .openrouter:
            return ProviderCredentialInstructions(
                providerType: providerType,
                displayName: L("OpenRouter"),
                authMethod: .oauth,
                getKeyURL: getKeyURL,
                keyFormatHint: L("Sign in with OpenRouter or paste a key from openrouter.ai/keys."),
                storageAuthType: .apiKey,
                presetId: preset.rawValue
            )
        case .deepseek:
            return ProviderCredentialInstructions(
                providerType: providerType,
                displayName: L("DeepSeek"),
                authMethod: .apiKey,
                getKeyURL: getKeyURL,
                keyFormatHint: L("Get a key from platform.deepseek.com."),
                storageAuthType: .apiKey,
                presetId: preset.rawValue
            )
        case .mistral:
            return ProviderCredentialInstructions(
                providerType: providerType,
                displayName: L("Mistral"),
                authMethod: .apiKey,
                getKeyURL: getKeyURL,
                keyFormatHint: L("Get a key from console.mistral.ai."),
                storageAuthType: .apiKey,
                presetId: preset.rawValue
            )
        case .minimax:
            return ProviderCredentialInstructions(
                providerType: providerType,
                displayName: L("MiniMax"),
                authMethod: .apiKey,
                getKeyURL: getKeyURL,
                keyFormatHint: L("Get a key from platform.minimax.io."),
                storageAuthType: .apiKey,
                presetId: preset.rawValue
            )
        case .xai:
            return ProviderCredentialInstructions(
                providerType: providerType,
                displayName: L("Grok"),
                authMethod: .oauth,
                getKeyURL: getKeyURL,
                keyFormatHint: L(
                    "Sign in with Grok using a SuperGrok or X Premium+ subscription, or paste a key from console.x.ai."
                ),
                storageAuthType: .xaiOAuth,
                presetId: preset.rawValue
            )
        case .venice:
            return ProviderCredentialInstructions(
                providerType: providerType,
                displayName: L("Venice AI"),
                authMethod: .apiKey,
                getKeyURL: getKeyURL,
                keyFormatHint: L("Generate a key from venice.ai/settings/api."),
                storageAuthType: .apiKey,
                presetId: preset.rawValue
            )
        case .ollama:
            return ProviderCredentialInstructions(
                providerType: providerType,
                displayName: L("Ollama"),
                authMethod: .apiKey,
                getKeyURL: getKeyURL,
                keyFormatHint: L("Leave the key blank if your local Ollama doesn't require one."),
                storageAuthType: .none,
                presetId: preset.rawValue
            )
        case .custom:
            return ProviderCredentialInstructions(
                providerType: providerType,
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
                presetId: preset.rawValue
            )
        }
    }

    /// Special entry for the Osaurus-Agent peer path. `.osaurus` has no
    /// `ProviderPreset` because it isn't a third-party vendor — it's
    /// another Osaurus instance reachable over the local network. The
    /// sheet still needs an entry so the user can paste a pairing key.
    public static func osaurusAgentEntry() -> ProviderCredentialInstructions {
        ProviderCredentialInstructions(
            providerType: .osaurus,
            displayName: L("Osaurus Agent"),
            authMethod: .apiKey,
            getKeyURL: nil,
            keyFormatHint: L("Paste the pairing API key from the remote Osaurus."),
            storageAuthType: .apiKey,
            presetId: ""
        )
    }

    /// Codex OAuth uses the same brand as the OpenAI preset but is a
    /// distinct `RemoteProviderType`. Kept as a separate entry the
    /// chat tool can request explicitly via `provider: "codex_oauth"`.
    public static func openAICodexEntry() -> ProviderCredentialInstructions {
        ProviderCredentialInstructions(
            providerType: .openAICodex,
            displayName: L("OpenAI Codex"),
            authMethod: .oauth,
            getKeyURL: URL(string: "https://chatgpt.com/codex"),
            keyFormatHint: L("Sign in with your ChatGPT account."),
            storageAuthType: .openAICodexOAuth,
            presetId: ProviderPreset.openai.rawValue
        )
    }
}
