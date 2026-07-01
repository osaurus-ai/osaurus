//
//  ProviderPresets.swift
//  osaurus
//
//  Shared provider preset definitions used by both onboarding and provider management.
//

import SwiftUI

// MARK: - Provider Preset

/// Unified provider presets shared across onboarding and provider management.
public enum ProviderPreset: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case azureOpenAI
    case atlasCloud
    case openai
    case google
    case xai
    case deepseek
    case mistral
    case minimax
    case venice
    case openrouter
    case ollama
    case custom

    public var id: String { rawValue }

    /// Display name
    var name: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .azureOpenAI: return "Azure OpenAI Foundry"
        case .atlasCloud: return "AtlasCloud"
        case .openai: return "OpenAI"
        case .google: return "Google"
        case .xai: return "xAI"
        case .deepseek: return "DeepSeek"
        case .mistral: return "Mistral"
        case .minimax: return "MiniMax"
        case .venice: return "Venice AI"
        case .openrouter: return "OpenRouter"
        case .ollama: return "Ollama"
        case .custom: return "Custom"
        }
    }

    /// Short description shown below the name
    var description: String {
        switch self {
        case .anthropic: return L("Claude models")
        case .azureOpenAI: return L("Azure deployments")
        case .atlasCloud: return "DeepSeek, Qwen, GLM, Kimi, MiniMax"
        case .openai: return L("ChatGPT/Codex or Platform API")
        case .google: return L("Gemini models")
        case .xai: return L("Grok models")
        case .deepseek: return "deepseek-v4-pro / v4-flash"
        case .mistral: return L("Mistral Small/Medium models")
        case .minimax: return L("MiniMax M-series models")
        case .venice: return L("Privacy-first AI")
        case .openrouter: return L("Multi-provider")
        case .ollama: return L("Run models locally via Ollama")
        case .custom: return L("Custom endpoint")
        }
    }

    /// SF Symbol name
    var icon: String {
        switch self {
        case .anthropic: return "brain.head.profile"
        case .azureOpenAI: return "cloud.fill"
        case .atlasCloud: return "square.stack.3d.up.fill"
        case .openai: return "sparkles"
        case .google: return "globe"
        case .xai: return "bolt.fill"
        case .deepseek: return "cpu"
        case .mistral: return "wind"
        case .minimax: return "m.square.fill"
        case .venice: return "lock.shield.fill"
        case .openrouter: return "arrow.triangle.branch"
        case .ollama: return "shippingbox.fill"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// Gradient colors for visual accents
    var gradient: [Color] {
        switch self {
        case .anthropic: return [Color(red: 0.85, green: 0.55, blue: 0.35), Color(red: 0.75, green: 0.4, blue: 0.25)]
        case .azureOpenAI: return [Color(red: 0.0, green: 0.47, blue: 0.84), Color(red: 0.0, green: 0.62, blue: 0.72)]
        case .atlasCloud: return [Color(red: 0.03, green: 0.23, blue: 0.21), Color(red: 0.07, green: 0.39, blue: 0.34)]
        case .openai: return [Color(red: 0.0, green: 0.65, blue: 0.52), Color(red: 0.0, green: 0.5, blue: 0.4)]
        case .google: return [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.18, green: 0.38, blue: 0.85)]
        case .xai: return [Color(red: 0.1, green: 0.1, blue: 0.1), Color(red: 0.2, green: 0.2, blue: 0.2)]
        case .deepseek: return [Color(red: 0.18, green: 0.36, blue: 0.95), Color(red: 0.34, green: 0.52, blue: 0.98)]
        case .mistral: return [Color(red: 0.98, green: 0.42, blue: 0.11), Color(red: 0.87, green: 0.24, blue: 0.09)]
        case .minimax: return [Color(red: 0.93, green: 0.27, blue: 0.23), Color(red: 0.83, green: 0.15, blue: 0.18)]
        case .venice: return [Color(red: 0.83, green: 0.66, blue: 0.33), Color(red: 0.72, green: 0.53, blue: 0.17)]
        case .openrouter: return [Color(red: 0.95, green: 0.55, blue: 0.25), Color(red: 0.85, green: 0.4, blue: 0.2)]
        case .ollama: return [Color(red: 0.36, green: 0.36, blue: 0.4), Color(red: 0.22, green: 0.22, blue: 0.26)]
        case .custom: return [Color(red: 0.55, green: 0.55, blue: 0.6), Color(red: 0.4, green: 0.4, blue: 0.45)]
        }
    }

    /// URL to the provider's API key console page (empty for custom)
    var consoleURL: String {
        switch self {
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .azureOpenAI: return "https://ai.azure.com"
        case .atlasCloud: return "https://www.atlascloud.ai/console/api-keys"
        case .openai: return "https://platform.openai.com/api-keys"
        case .google: return "https://aistudio.google.com/apikey"
        case .xai: return "https://console.x.ai/"
        case .deepseek: return "https://platform.deepseek.com/api_keys"
        case .mistral: return "https://console.mistral.ai/api-keys"
        case .minimax: return "https://platform.minimax.io/user-center/basic-information/interface-key"
        case .venice: return "https://venice.ai/settings/api"
        case .openrouter: return "https://openrouter.ai/keys"
        case .ollama: return "https://ollama.com/download"
        case .custom: return ""
        }
    }

    /// Optional badge label (e.g. "Privacy") shown as a highlight pill on provider cards
    var badge: String? {
        switch self {
        case .azureOpenAI: return "Azure"
        case .venice: return L("Privacy")
        case .ollama: return L("Local")
        default: return nil
        }
    }

    /// Optional documentation URL for the provider (shown in help sections)
    var documentationURL: String? {
        switch self {
        case .azureOpenAI: return "https://learn.microsoft.com/azure/ai-foundry/openai/"
        case .atlasCloud: return "https://www.atlascloud.ai/docs/en/models/get-start"
        case .deepseek: return "https://api-docs.deepseek.com/"
        case .mistral: return "https://docs.mistral.ai/api"
        case .minimax: return "https://platform.minimax.io/docs/api-reference/api-overview"
        case .venice: return "https://docs.venice.ai"
        case .ollama: return "https://github.com/ollama/ollama"
        default: return nil
        }
    }

    /// Optional custom image asset name (from the app's asset catalog).
    /// When non-nil, `ProviderIcon` renders this instead of the SF Symbol.
    var imageAssetName: String? {
        switch self {
        case .venice: return "venice-keys"
        default: return nil
        }
    }

    /// Help steps shown when guiding the user to create an API key
    var helpSteps: [String] {
        switch self {
        case .azureOpenAI:
            return [
                L("Open your Azure OpenAI resource in Azure AI Foundry"),
                L("Copy the resource endpoint host and an API key"),
                L("Add deployment names if they do not appear automatically"),
                L("Paste the key here"),
            ]
        case .atlasCloud:
            return [
                L("Go to the AtlasCloud API keys page"),
                L("Create or copy an API key"),
                L("Use the OpenAI-compatible base URL https://api.atlascloud.ai/v1"),
                L("Paste the key here"),
            ]
        case .openai:
            return [
                L("Go to the OpenAI Platform API keys page"),
                L("Sign in to your developer account"),
                L("Create a new API key"),
                L("Copy and paste it here"),
            ]
        case .venice:
            return [
                L("Go to Venice AI settings page"),
                L("Sign in or create an account"),
                L("Generate a new API key"),
                L("Copy and paste it here"),
            ]
        case .deepseek:
            return [
                L("Go to the DeepSeek Platform API keys page"),
                L("Sign in or create an account"),
                L("Create a new API key"),
                L("Copy and paste it here"),
            ]
        case .minimax:
            return [
                L("Go to the MiniMax platform API keys page"),
                L("Sign in or create an account"),
                L("Create a new secret key"),
                L("Copy and paste it here"),
            ]
        case .mistral:
            return [
                L("Go to the Mistral console API keys page"),
                L("Sign in or create an account"),
                L("Create a new API key"),
                L("Copy and paste it here"),
            ]
        case .ollama:
            return [
                L("Install Ollama from ollama.com"),
                L("Run `ollama serve` (or launch the app)"),
                L("Pull a model — e.g. `ollama pull llama3.2`"),
                L("Click Connect — no API key required"),
            ]
        default:
            return [
                L("Go to \(name) console"),
                L("Sign in or create an account"),
                L("Click \"API Keys\" → \"Create Key\""),
                L("Copy and paste it here"),
            ]
        }
    }

    /// Whether this is a known provider (not custom)
    var isKnown: Bool { self != .custom }

    /// OAuth-capable presets, surfaced first in provider lists because a
    /// browser sign-in is the lowest-friction path (no API-key paste). Order
    /// within the group is curated.
    static let oauthFirstPresets: [ProviderPreset] = [.openai, .xai, .openrouter]

    /// Known presets (excludes custom). OAuth-capable providers lead (see
    /// `oauthFirstPresets`), then the remaining providers alphabetically by
    /// display name.
    static var knownPresets: [ProviderPreset] {
        let oauthFirst = oauthFirstPresets.filter { $0.isKnown }
        let rest =
            allCases
            .filter { $0.isKnown && !oauthFirst.contains($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return oauthFirst + rest
    }

    // MARK: - OAuth-first picker grouping

    /// Preset-keyed views of `ProviderCatalog`, kept so existing call sites and
    /// tests that think in `ProviderPreset` terms don't have to. The catalog is
    /// the source of truth; these just project its entries down to presets.

    /// OAuth-capable presets surfaced as first-class rows at the top of the
    /// provider picker.
    static var oauthProviders: [ProviderPreset] { ProviderCatalog.topLevel.map(\.preset) }

    /// API-key vendors shown inside the "Use an API key" drill-in, alphabetical
    /// by display name. Includes the OAuth-first presets because each also
    /// offers a paste-a-key path; excludes Ollama (local) and Custom.
    static var apiKeyProviders: [ProviderPreset] {
        ProviderCatalog.apiKeyGroups(includeAzure: true)
            .first { $0.id == "apiKey" }?
            .entries.map(\.preset) ?? []
    }

    /// A labeled section in the "Use an API key" drill-in sub-list. `title` is a
    /// localization key the view localizes via `.module` bundle.
    struct PickerSection: Identifiable {
        let id: String
        let title: String
        let presets: [ProviderPreset]
    }

    /// Sections for the "Use an API key" drill-in, projected from
    /// `ProviderCatalog.apiKeyGroups`. Onboarding omits Azure OpenAI via
    /// `includeAzure`.
    static func apiKeyPickerGroups(includeAzure: Bool) -> [PickerSection] {
        ProviderCatalog.apiKeyGroups(includeAzure: includeAzure).map {
            PickerSection(id: $0.id, title: $0.title, presets: $0.entries.map(\.preset))
        }
    }

    // MARK: - Configuration

    /// Connection configuration for this preset
    var configuration: ProviderPresetConfiguration {
        switch self {
        case .anthropic:
            return ProviderPresetConfiguration(
                name: "Anthropic",
                host: "api.anthropic.com",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .apiKey,
                providerType: .anthropic
            )
        case .azureOpenAI:
            return ProviderPresetConfiguration(
                name: "Azure OpenAI Foundry",
                host: "",
                providerProtocol: .https,
                port: nil,
                basePath: "/openai/v1",
                authType: .apiKey,
                providerType: .azureOpenAI
            )
        case .atlasCloud:
            return ProviderPresetConfiguration(
                name: "AtlasCloud",
                host: "api.atlascloud.ai",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .apiKey,
                providerType: .openaiLegacy,
                defaultManualModelIds: [
                    "deepseek-ai/DeepSeek-V3-0324",
                    "deepseek-ai/deepseek-v4-flash",
                    "qwen/qwen3.5-122b-a10b",
                    "qwen/qwen3-coder-next",
                    "moonshotai/kimi-k2.5",
                    "zai-org/glm-5",
                    "zai-org/glm-5-turbo",
                    "minimaxai/minimax-m2.7",
                ]
            )
        case .openai:
            return ProviderPresetConfiguration(
                name: "OpenAI",
                host: "api.openai.com",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .apiKey,
                providerType: .openResponses
            )
        case .google:
            return ProviderPresetConfiguration(
                name: "Google",
                host: "generativelanguage.googleapis.com",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1beta",
                authType: .apiKey,
                providerType: .gemini
            )
        case .xai:
            return ProviderPresetConfiguration(
                name: "xAI",
                host: "api.x.ai",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .apiKey,
                providerType: .openaiLegacy
            )
        case .deepseek:
            return ProviderPresetConfiguration(
                name: "DeepSeek",
                host: "api.deepseek.com",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .apiKey,
                providerType: .openaiLegacy
            )
        case .mistral:
            return ProviderPresetConfiguration(
                name: "Mistral",
                host: "api.mistral.ai",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .apiKey,
                providerType: .openaiLegacy,
                defaultManualModelIds: [
                    "mistral-medium-3.5",
                    "mistral-small-latest",
                ]
            )
        case .minimax:
            return ProviderPresetConfiguration(
                name: "MiniMax",
                host: "api.minimax.io",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .apiKey,
                providerType: .openaiLegacy,
                defaultManualModelIds: [
                    "MiniMax-M3",
                    "MiniMax-M2.7",
                    "MiniMax-M2.7-highspeed",
                    "MiniMax-M2.5",
                    "MiniMax-M2.1",
                    "MiniMax-M2",
                ]
            )
        case .venice:
            return ProviderPresetConfiguration(
                name: "Venice AI",
                host: "api.venice.ai",
                providerProtocol: .https,
                port: nil,
                basePath: "/api/v1",
                authType: .apiKey,
                providerType: .openaiLegacy
            )
        case .openrouter:
            return ProviderPresetConfiguration(
                name: "OpenRouter",
                host: "openrouter.ai",
                providerProtocol: .https,
                port: nil,
                basePath: "/api/v1",
                authType: .apiKey,
                providerType: .openaiLegacy
            )
        case .ollama:
            return ProviderPresetConfiguration(
                name: "Ollama",
                host: "localhost",
                providerProtocol: .http,
                port: 11434,
                basePath: "/v1",
                authType: .none,
                providerType: .openaiLegacy
            )
        case .custom:
            return ProviderPresetConfiguration(
                name: "",
                host: "",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .apiKey,
                providerType: .openaiLegacy
            )
        }
    }

    // MARK: - Matching

    /// Best-effort lookup keyed by `RemoteProviderType` (used by the credential
    /// prompt service to pick a preset for an existing provider) — picks the
    /// unambiguous preset for distinctive types and `nil` for `.openaiLegacy`
    /// (shared by xAI, DeepSeek, Venice, OpenRouter, Ollama, and custom) so the
    /// caller can fall back to `.custom`.
    static func preferred(for providerType: RemoteProviderType) -> ProviderPreset? {
        switch providerType {
        case .anthropic: return .anthropic
        case .openResponses: return .openai
        case .gemini: return .google
        case .azureOpenAI: return .azureOpenAI
        case .openAICodex: return .openai
        case .openaiLegacy, .osaurus, .osaurusRouter: return nil
        }
    }

    /// Attempts to match an existing RemoteProvider to a known preset by host.
    static func matching(provider: RemoteProvider) -> ProviderPreset? {
        if provider.providerType == .azureOpenAI {
            return .azureOpenAI
        }

        let host = provider.host.lowercased().trimmingCharacters(in: .whitespaces)
        if let byHost = knownPresets.first(where: { preset in
            guard !preset.configuration.host.isEmpty else { return false }
            return preset.configuration.host.lowercased() == host
        }) {
            return byHost
        }

        // Host didn't match a stock endpoint which is likely a custom base URL like a
        // self-hosted proxy. Fall back to the distinctive provider types so a
        // custom-host Anthropic/OpenAI/Gemini provider keeps its branded card and
        // native editor instead of looking like a generic custom provider.
        // `openaiLegacy` is intentionally excluded as it's shared by many presets
        // (xAI, DeepSeek, Venice, OpenRouter, Ollama) so it can't identify one.
        switch provider.providerType {
        case .anthropic: return .anthropic
        case .gemini: return .google
        case .openResponses, .openAICodex: return .openai
        case .openaiLegacy, .azureOpenAI, .osaurus, .osaurusRouter: return nil
        }
    }
}

// MARK: - Preset Configuration

/// Connection configuration for a provider preset.
struct ProviderPresetConfiguration {
    let name: String
    let host: String
    let providerProtocol: RemoteProviderProtocol
    let port: Int?
    let basePath: String
    let authType: RemoteProviderAuthType
    let providerType: RemoteProviderType
    let defaultManualModelIds: [String]

    init(
        name: String,
        host: String,
        providerProtocol: RemoteProviderProtocol,
        port: Int?,
        basePath: String,
        authType: RemoteProviderAuthType,
        providerType: RemoteProviderType,
        defaultManualModelIds: [String] = []
    ) {
        self.name = name
        self.host = host
        self.providerProtocol = providerProtocol
        self.port = port
        self.basePath = basePath
        self.authType = authType
        self.providerType = providerType
        self.defaultManualModelIds = defaultManualModelIds
    }
}

// MARK: - Provider Badge View

/// Reusable badge pill shown next to a provider name (e.g. "Privacy" for Venice AI).
struct ProviderBadge: View {
    let text: String
    let gradient: [Color]
    let fontSize: CGFloat

    init(_ text: String, gradient: [Color], fontSize: CGFloat = 9) {
        self.text = text
        self.gradient = gradient
        self.fontSize = fontSize
    }

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, fontSize < 10 ? 5 : 7)
            .padding(.vertical, fontSize < 10 ? 1.5 : 2)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: gradient,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
    }
}

// MARK: - Provider Icon View

/// Renders a provider's icon, using a custom image asset when available or an SF Symbol as fallback.
struct ProviderIcon: View {
    let preset: ProviderPreset
    let size: CGFloat
    let color: Color

    var body: some View {
        if let assetName = preset.imageAssetName {
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundColor(color)
        } else {
            Image(systemName: preset.icon)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(color)
        }
    }
}

// MARK: - Provider Help Links View

/// Reusable console + documentation link buttons for provider help sections.
struct ProviderHelpLinks: View {
    let preset: ProviderPreset
    let accentColor: Color
    let secondaryTextColor: Color

    var body: some View {
        HStack(spacing: 16) {
            Button {
                if let url = URL(string: preset.consoleURL) {
                    // Async open: the synchronous `open(_:)` blocks the main
                    // thread on a LaunchServices XPC round-trip that can stall
                    // long enough to trip the hang watchdog.
                    NSWorkspace.shared.open(
                        url,
                        configuration: NSWorkspace.OpenConfiguration(),
                        completionHandler: nil
                    )
                }
            } label: {
                HStack(spacing: 6) {
                    Text(
                        preset.configuration.authType == .none
                            ? "Install \(preset.name)"
                            : "Open \(preset.name) Console",
                        bundle: .module
                    )
                    .font(.system(size: 13, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(accentColor)
            }
            .buttonStyle(.plain)

            if let docURL = preset.documentationURL {
                Button {
                    if let url = URL(string: docURL) {
                        // Async open to avoid blocking the main thread on the
                        // synchronous LaunchServices XPC round-trip.
                        NSWorkspace.shared.open(
                            url,
                            configuration: NSWorkspace.OpenConfiguration(),
                            completionHandler: nil
                        )
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("View Docs", bundle: .module)
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "book")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(secondaryTextColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
