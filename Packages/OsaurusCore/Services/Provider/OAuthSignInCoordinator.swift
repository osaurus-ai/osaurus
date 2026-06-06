//
//  OAuthSignInCoordinator.swift
//  osaurus
//
//  Thin reusable facade for completing OAuth flows for remote providers.
//
//  Historically the OAuth sign-in code lived inline inside
//  `RemoteProviderEditSheet` and `OnboardingConfigureAIView`. The Phase-C
//  default-agent configure tools (and the credential prompt sheet) need
//  the same flow without dragging in a giant settings view, so this
//  coordinator wraps the two per-vendor services (`OpenAICodexOAuthService`
//  and `OpenRouterOAuthService`) behind a single `signIn(...)` entry point
//  that returns a normalized result.
//
//  Like the rest of the credential prompt path, this file deliberately
//  contains no LLM-visible logging — all secrets are passed back as
//  `ProviderCredentialResult` and stored via Keychain by the manager.
//

import Foundation

/// Outcome of a vendor OAuth flow, normalized across providers. The
/// caller turns this into a `RemoteProvider` + Keychain write through
/// `RemoteProviderManager.addProvider(_:apiKey:oauthTokens:)`.
public enum OAuthSignInOutcome: Sendable {
    /// ChatGPT / Codex-style flow that returns access + refresh tokens.
    case tokens(RemoteProviderOAuthTokens)
    /// OpenRouter-style flow that exchanges PKCE for a long-lived API key.
    case apiKey(String)
}

/// Coordinator that fronts every OAuth provider. `ProviderPreset` is the
/// canonical dispatch key — five `.openaiLegacy` vendor presets (OpenRouter
/// being the OAuth one) collapse into the same `RemoteProviderType`, so
/// using preset here lets us route OpenRouter to its dedicated service
/// without growing per-call branches.
public enum OAuthSignInCoordinator {
    /// True when `preset` supports OAuth sign-in via this coordinator.
    /// Used by `ProviderCredentialPromptSheet` to decide between
    /// rendering an "API key" field and a "Sign in with …" button.
    public static func supportsOAuth(_ preset: ProviderPreset) -> Bool {
        switch preset {
        case .openrouter, .xai: return true
        default: return false
        }
    }

    /// Legacy back-compat shim. Some call sites only have a
    /// `RemoteProviderType` (rotate-credentials on an existing provider,
    /// older tests). Only `.openAICodex` is supported through this path
    /// because OpenRouter requires the preset to disambiguate.
    public static func supportsOAuth(_ providerType: RemoteProviderType) -> Bool {
        providerType == .openAICodex
    }

    /// Run the vendor OAuth flow for `preset` and return a normalized
    /// outcome. Must be called on the main actor because each service
    /// drives an `NSWorkspace` browser open + a local callback listener.
    @MainActor
    public static func signIn(preset: ProviderPreset) async throws -> OAuthSignInOutcome {
        switch preset {
        case .openrouter:
            let key = try await OpenRouterOAuthService.signIn()
            return .apiKey(key)
        case .xai:
            let tokens = try await XAIOAuthService.signIn()
            return .tokens(tokens)
        default:
            throw OAuthSignInCoordinatorError.unsupportedPreset(preset: preset)
        }
    }

    /// Codex OAuth keeps a `RemoteProviderType` entry point because it
    /// lives behind the `.openAICodex` type rather than a preset case
    /// (the `.openai` preset is API-key only).
    @MainActor
    public static func signIn(providerType: RemoteProviderType) async throws -> OAuthSignInOutcome {
        switch providerType {
        case .openAICodex:
            let tokens = try await OpenAICodexOAuthService.signIn()
            return .tokens(tokens)
        default:
            throw OAuthSignInCoordinatorError.unsupportedProvider(providerType: providerType)
        }
    }

    /// OpenRouter-specific entry point kept for back-compat with Settings
    /// (which calls it directly, predating the preset coordinator).
    @MainActor
    public static func openRouterSignIn() async throws -> OAuthSignInOutcome {
        try await signIn(preset: .openrouter)
    }
}

public enum OAuthSignInCoordinatorError: LocalizedError, Sendable, Equatable {
    case unsupportedProvider(providerType: RemoteProviderType)
    case unsupportedPreset(preset: ProviderPreset)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let providerType):
            return String(
                format: L("OAuth sign-in is not supported for provider type '%@'."),
                providerType.rawValue
            )
        case .unsupportedPreset(let preset):
            return String(
                format: L("OAuth sign-in is not supported for provider '%@'."),
                preset.rawValue
            )
        }
    }
}
