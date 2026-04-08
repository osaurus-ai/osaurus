//
//  ProviderPresets.swift
//  osaurus
//
//  Shared provider preset definitions used by both onboarding and provider management.
//

import SwiftUI

// MARK: - Provider Preset

/// Unified provider presets shared across onboarding and provider management.
enum ProviderPreset: String, CaseIterable, Identifiable {
    case anthropic
    case openai
    case google
    case xai
    case venice
    case openrouter
    case custom

    var id: String { rawValue }

    /// Display name
    var name: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .google: return "Google"
        case .xai: return "xAI"
        case .venice: return "Venice AI"
        case .openrouter: return "OpenRouter"
        case .custom: return "Custom"
        }
    }

    /// Short description shown below the name
    var description: String {
        switch self {
        case .anthropic: return "Claude models"
        case .openai: return "ChatGPT models"
        case .google: return "Gemini models"
        case .xai: return "Grok models"
        case .venice: return "Privacy-first AI"
        case .openrouter: return "Multi-provider"
        case .custom: return "Custom endpoint"
        }
    }

    /// SF Symbol name
    var icon: String {
        switch self {
        case .anthropic: return "brain.head.profile"
        case .openai: return "sparkles"
        case .google: return "globe"
        case .xai: return "bolt.fill"
        case .venice: return "lock.shield.fill"
        case .openrouter: return "arrow.triangle.branch"
        case .custom: return "slider.horizontal.3"
        }
    }

    /// Gradient colors for visual accents
    var gradient: [Color] {
        switch self {
        case .anthropic: return [Color(red: 0.85, green: 0.55, blue: 0.35), Color(red: 0.75, green: 0.4, blue: 0.25)]
        case .openai: return [Color(red: 0.0, green: 0.65, blue: 0.52), Color(red: 0.0, green: 0.5, blue: 0.4)]
        case .google: return [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.18, green: 0.38, blue: 0.85)]
        case .xai: return [Color(red: 0.1, green: 0.1, blue: 0.1), Color(red: 0.2, green: 0.2, blue: 0.2)]
        case .venice: return [Color(red: 0.83, green: 0.66, blue: 0.33), Color(red: 0.72, green: 0.53, blue: 0.17)]
        case .openrouter: return [Color(red: 0.95, green: 0.55, blue: 0.25), Color(red: 0.85, green: 0.4, blue: 0.2)]
        case .custom: return [Color(red: 0.55, green: 0.55, blue: 0.6), Color(red: 0.4, green: 0.4, blue: 0.45)]
        }
    }

    /// URL to the provider's API key console page (empty for custom)
    var consoleURL: String {
        switch self {
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .openai: return "https://platform.openai.com/api-keys"
        case .google: return "https://aistudio.google.com/apikey"
        case .xai: return "https://console.x.ai/"
        case .venice: return "https://venice.ai/settings/api"
        case .openrouter: return "https://openrouter.ai/keys"
        case .custom: return ""
        }
    }

    /// Optional badge label (e.g. "Privacy") shown as a highlight pill on provider cards
    var badge: String? {
        switch self {
        case .venice: return "Privacy"
        default: return nil
        }
    }

    /// Optional documentation URL for the provider (shown in help sections)
    var documentationURL: String? {
        switch self {
        case .venice: return "https://docs.venice.ai"
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
        case .venice:
            return [
                "Go to Venice AI settings page",
                "Sign in or create an account",
                "Generate a new API key",
                "Copy and paste it here",
            ]
        default:
            return [
                "Go to \(name) console",
                "Sign in or create an account",
                "Click \"API Keys\" \u{2192} \"Create Key\"",
                "Copy and paste it here",
            ]
        }
    }

    /// Whether this is a known provider (not custom)
    var isKnown: Bool { self != .custom }

    /// Known presets sorted alphabetically by display name (excludes custom)
    static var knownPresets: [ProviderPreset] {
        allCases.filter { $0.isKnown }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

    /// Attempts to match an existing RemoteProvider to a known preset by host.
    static func matching(provider: RemoteProvider) -> ProviderPreset? {
        let host = provider.host.lowercased().trimmingCharacters(in: .whitespaces)
        return knownPresets.first { preset in
            preset.configuration.host.lowercased() == host
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
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Open \(preset.name) Console")
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
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("View Docs")
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
