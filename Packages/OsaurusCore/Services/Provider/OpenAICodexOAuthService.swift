//
//  OpenAICodexOAuthService.swift
//  osaurus
//
//  ChatGPT/Codex OAuth support for OpenAI providers.
//

import AppKit
import Foundation

public enum OpenAICodexOAuthError: LocalizedError, Sendable {
    case invalidAuthorizationCallback
    case invalidPKCE
    case invalidTokenResponse
    case missingAccountId
    case tokenRequestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorizationCallback:
            return "OpenAI did not return a valid authorization code"
        case .invalidPKCE:
            return "Could not create a secure login challenge"
        case .invalidTokenResponse:
            return "OpenAI returned an invalid token response"
        case .missingAccountId:
            return "Could not identify the ChatGPT account from the sign-in token"
        case .tokenRequestFailed(let message):
            return "OpenAI token request failed: \(message)"
        }
    }
}

public enum OpenAICodexOAuthService {

    // MARK: - Configuration

    public static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let redirectURI = "http://localhost:1455/auth/callback"
    public static let scope = "openid profile email offline_access"
    public static let codexBaseHost = "chatgpt.com"
    public static let codexBasePath = "/backend-api"
    public static let modelsURL = URL(string: "https://\(codexBaseHost)\(codexBasePath)/models")!

    // MARK: - Provider Factory

    public static func makeProvider(id: UUID = UUID()) -> RemoteProvider {
        RemoteProvider(
            id: id,
            name: "OpenAI ChatGPT",
            host: codexBaseHost,
            providerProtocol: .https,
            port: nil,
            basePath: codexBasePath,
            customHeaders: [:],
            authType: .openAICodexOAuth,
            providerType: .openAICodex,
            enabled: true,
            autoConnect: true,
            timeout: 300
        )
    }

    // MARK: - Sign-in / Token Refresh

    @MainActor
    public static func signIn() async throws -> RemoteProviderOAuthTokens {
        let pkce = try makePKCEPair()
        let state = makeState()
        let url = authorizationURL(codeChallenge: pkce.challenge, state: state)

        let callback = try await authorize(url: url, state: state)
        return try await exchangeAuthorizationCode(callback.code, verifier: pkce.verifier)
    }

    public static func refresh(_ tokens: RemoteProviderOAuthTokens) async throws -> RemoteProviderOAuthTokens {
        try await requestTokens(
            form: [
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
                "client_id": clientId,
            ]
        )
    }

    // MARK: - Model Catalog

    /// Offline / pre-auth fallback list. The live catalog (fetched via
    /// `fetchAvailableModels(tokens:)`) is preferred whenever OAuth tokens are
    /// available, but this list keeps the UI usable before sign-in and when the
    /// `/models` endpoint cannot be reached.
    public static let supportedModels: [String] = [
        "gpt-5.5",
        "gpt-5.5-pro",
        "gpt-5.4",
        "gpt-5.4-mini",
        "gpt-5.4-nano",
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark",
        "gpt-5.2",
        "gpt-5.2-codex",
        "gpt-5.1-codex-max",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
        "gpt-5.1",
    ]

    /// Live model catalog fetched from the ChatGPT/Codex backend, matching what
    /// `codex-rs`'s `ModelsClient.list_models` does. Filters out chat-only
    /// models so callers only see Codex-Responses-compatible slugs.
    public static func fetchAvailableModels(
        tokens: RemoteProviderOAuthTokens
    ) async throws -> [String] {
        var components = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_version", value: clientVersion())
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(tokens.accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")

        let data = try await performRequest(request)
        guard let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            throw OpenAICodexOAuthError.invalidTokenResponse
        }

        return decoded.models
            .filter(isCodexCompatible)
            .sorted { ($0.priority ?? .max) < ($1.priority ?? .max) }
            .map(\.slug)
            .uniqued()
    }

    /// True when a `/models` entry can be used through the Codex Responses
    /// backend with a ChatGPT subscription. The same endpoint also returns
    /// chat-only models (e.g. `gpt-5-4-thinking`), which fail with
    /// `HTTP 400 "model is not supported when using Codex with a ChatGPT
    /// account"` if we surface them.
    private static func isCodexCompatible(_ entry: ModelEntry) -> Bool {
        guard !entry.slug.isEmpty else { return false }

        // Must be a picker-visible model.
        guard (entry.visibility ?? "list").lowercased() == "list" else { return false }

        // Codex requires shell-tool support. Chat-only models come back with
        // `shell_type: "disabled"`. Treat a missing field as "unknown -> allow"
        // and rely on the slug check below to catch it.
        if let shellType = entry.shell_type, shellType.lowercased() == "disabled" {
            return false
        }

        // Codex slugs always use a dotted version (e.g. "gpt-5.4-codex").
        // Chat-only slugs use dashes throughout (e.g. "gpt-5-4-thinking",
        // "gpt-4o"). Match the dotted "<family>-<major>.<minor>" prefix.
        return entry.slug.range(of: #"^gpt-\d+\.\d+"#, options: .regularExpression) != nil
    }

    /// Convenience wrapper used by call sites that want a single "best
    /// available" list: prefer the live catalog when we have tokens, otherwise
    /// fall back to `supportedModels`.
    public static func availableModels(for tokens: RemoteProviderOAuthTokens?) async -> [String] {
        guard let tokens,
            let live = try? await fetchAvailableModels(tokens: tokens),
            !live.isEmpty
        else {
            return supportedModels
        }
        return live
    }

    // MARK: - OAuth Helpers

    public static func authorizationURL(codeChallenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
        ]
        return components.url!
    }

    public static func makePKCEPair() throws -> (verifier: String, challenge: String) {
        do {
            let pair = try PKCE.makePair()
            return (pair.verifier, pair.challenge)
        } catch {
            throw OpenAICodexOAuthError.invalidPKCE
        }
    }

    public static func makeState() -> String {
        PKCE.makeState()
    }

    public static func extractAccountId(from accessToken: String) -> String? {
        let parts = accessToken.split(separator: ".")
        guard parts.count == 3,
            let payload = PKCE.decodeBase64URL(String(parts[1])),
            let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let auth = json["https://api.openai.com/auth"] as? [String: Any],
            let accountId = auth["chatgpt_account_id"] as? String,
            !accountId.isEmpty
        else {
            return nil
        }
        return accountId
    }

    public static func exchangeAuthorizationCode(_ code: String, verifier: String) async throws
        -> RemoteProviderOAuthTokens
    {
        try await requestTokens(
            form: [
                "grant_type": "authorization_code",
                "client_id": clientId,
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": redirectURI,
            ]
        )
    }

    // MARK: - Internals

    /// `client_version` query parameter sent to the Codex `/models` endpoint.
    /// Mirrors what the Codex CLI does (it sends its own crate version) so the
    /// backend can gate model availability per client.
    private static func clientVersion() -> String {
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let bundleVersion, !bundleVersion.isEmpty {
            return "osaurus-\(bundleVersion)"
        }
        return "0.99.0"
    }

    // MARK: Wire types

    private struct ModelsResponse: Decodable {
        let models: [ModelEntry]
    }

    private struct ModelEntry: Decodable {
        let slug: String
        let visibility: String?
        let priority: Int?
        let shell_type: String?
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: TimeInterval
    }

    // MARK: Networking

    /// Executes `request`, returning the body on success. Throws
    /// `.invalidTokenResponse` for non-HTTP responses and `.tokenRequestFailed`
    /// for any HTTP error (body included in the message for diagnostics).
    private static func performRequest(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICodexOAuthError.invalidTokenResponse
        }
        guard http.statusCode < 400 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw OpenAICodexOAuthError.tokenRequestFailed(body)
        }
        return data
    }

    private static func requestTokens(form: [String: String]) async throws -> RemoteProviderOAuthTokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthFormEncoding.encode(form).data(using: .utf8)

        let data = try await performRequest(request)
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw OpenAICodexOAuthError.invalidTokenResponse
        }
        guard let accountId = extractAccountId(from: response.access_token) else {
            throw OpenAICodexOAuthError.missingAccountId
        }

        return RemoteProviderOAuthTokens(
            accessToken: response.access_token,
            refreshToken: response.refresh_token,
            expiresAt: Date().addingTimeInterval(response.expires_in),
            accountId: accountId
        )
    }

    @MainActor
    private static func authorize(url: URL, state: String) async throws -> OAuthCallbackResult {
        // Codex registered http://localhost:1455/auth/callback as the only redirect URI,
        // so we have to keep this port fixed even though RFC 8252 prefers ephemeral ports.
        let server: OAuthLoopbackServer
        do {
            server = try OAuthLoopbackServer(
                expectedState: state,
                port: .fixed(1455),
                callbackPath: "/auth/callback"
            )
            try await server.start()
        } catch {
            throw OpenAICodexOAuthError.invalidAuthorizationCallback
        }
        defer { server.stop() }

        guard NSWorkspace.shared.open(url) else {
            throw OpenAICodexOAuthError.invalidAuthorizationCallback
        }

        do {
            return try await server.waitForCallback()
        } catch {
            throw OpenAICodexOAuthError.invalidAuthorizationCallback
        }
    }
}

// MARK: - Helpers

extension Sequence where Element: Hashable {
    /// Returns the receiver's elements in order, dropping later duplicates.
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
