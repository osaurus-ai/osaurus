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

/// Coordinator that fronts every OAuth provider. The `providerType`
/// argument selects the underlying service; new vendors should be added
/// here so callers (sheet, configure tools, onboarding) don't grow
/// per-vendor branches.
public enum OAuthSignInCoordinator {
    /// True when `providerType` supports OAuth sign-in via this
    /// coordinator. Used by `ProviderCredentialPromptSheet` to decide
    /// between rendering an "API key" field and a "Sign in with …" button.
    public static func supportsOAuth(_ providerType: RemoteProviderType) -> Bool {
        switch providerType {
        case .openAICodex: return true
        default: return false
        }
    }

    /// True when `providerType` *also* supports an OAuth-derived API key
    /// (currently only OpenRouter through the legacy OpenAI shape).
    public static func supportsApiKeyOAuth(_ providerType: RemoteProviderType) -> Bool {
        // OpenRouter is served through `.openaiLegacy` today, but we don't
        // want every legacy provider to render an OpenRouter button — the
        // sheet has to opt in by setting `wantsOpenRouterOAuth: true`.
        false
    }

    /// Run the vendor OAuth flow for `providerType` and return a normalized
    /// outcome. Must be called on the main actor because each service
    /// drives an `NSWorkspace` browser open + a local callback listener.
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

    /// OpenRouter-specific entry point. Kept separate because OpenRouter
    /// stores its credential as an OpenAI-compatible API key rather than
    /// vendor tokens, and the calling UI is what knows to opt into this
    /// branch.
    @MainActor
    public static func openRouterSignIn() async throws -> OAuthSignInOutcome {
        let key = try await OpenRouterOAuthService.signIn()
        return .apiKey(key)
    }
}

public enum OAuthSignInCoordinatorError: LocalizedError, Sendable, Equatable {
    case unsupportedProvider(providerType: RemoteProviderType)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let providerType):
            return "OAuth sign-in is not supported for provider type '\(providerType.rawValue)'."
        }
    }
}
