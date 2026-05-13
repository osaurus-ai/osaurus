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
    public static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let redirectURI = "http://localhost:1455/auth/callback"
    public static let scope = "openid profile email offline_access"
    public static let codexBaseHost = "chatgpt.com"
    public static let codexBasePath = "/backend-api"

    public static let supportedModels: [String] = [
        "gpt-5.2",
        "gpt-5.2-codex",
        "gpt-5.1-codex-max",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
        "gpt-5.1",
    ]

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

    private static func requestTokens(form: [String: String]) async throws -> RemoteProviderOAuthTokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthFormEncoding.encode(form).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICodexOAuthError.invalidTokenResponse
        }
        guard http.statusCode < 400 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw OpenAICodexOAuthError.tokenRequestFailed(body)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: TimeInterval
        }

        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw OpenAICodexOAuthError.invalidTokenResponse
        }
        guard let accountId = extractAccountId(from: tokenResponse.access_token) else {
            throw OpenAICodexOAuthError.missingAccountId
        }

        return RemoteProviderOAuthTokens(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            expiresAt: Date().addingTimeInterval(tokenResponse.expires_in),
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
