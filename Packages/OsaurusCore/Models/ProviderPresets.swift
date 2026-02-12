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
        case .openrouter: return "https://openrouter.ai/keys"
        case .custom: return ""
        }
    }

    /// Whether this is a known provider (not custom)
    var isKnown: Bool { self != .custom }

    /// Known presets only (excludes custom)
    static var knownPresets: [ProviderPreset] {
        allCases.filter { $0.isKnown }
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
                providerType: .openai
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
                providerType: .openai
            )
        case .openrouter:
            return ProviderPresetConfiguration(
                name: "OpenRouter",
                host: "openrouter.ai",
                providerProtocol: .https,
                port: nil,
                basePath: "/api/v1",
                authType: .apiKey,
                providerType: .openai
            )
        case .custom:
            return ProviderPresetConfiguration(
                name: "",
                host: "",
                providerProtocol: .https,
                port: nil,
                basePath: "/v1",
                authType: .apiKey,
                providerType: .openai
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
