//
//  OpenRouterOAuthService.swift
//  osaurus
//
//  OpenRouter OAuth 2.1 PKCE sign-in.
//
//  Unlike the ChatGPT/Codex flow, OpenRouter's `/auth/keys` endpoint returns a
//  long-lived user API key (`sk-or-v1-...`) — not access/refresh tokens — so
//  there is nothing to refresh. The returned key is stored via the standard
//  `RemoteProviderKeychain.saveAPIKey` path and the persisted provider remains
//  `authType: .apiKey`, `providerType: .openaiLegacy`.
//

import AppKit
import Foundation

public enum OpenRouterOAuthError: LocalizedError, Sendable {
    case invalidAuthorizationCallback
    case invalidPKCE
    case invalidKeyResponse
    case keyRequestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorizationCallback:
            return "OpenRouter did not return a valid authorization code"
        case .invalidPKCE:
            return "Could not create a secure login challenge"
        case .invalidKeyResponse:
            return "OpenRouter returned an invalid key response"
        case .keyRequestFailed(let message):
            return "OpenRouter key exchange failed: \(message)"
        }
    }
}

public enum OpenRouterOAuthService {

    // MARK: - Configuration

    public static let authorizeURL = URL(string: "https://openrouter.ai/auth")!
    public static let keyExchangeURL = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
    public static let callbackPath = "/callback"

    /// OpenRouter keys per-user "app" registration on the `callback_url` query
    /// parameter. An ephemeral / custom port produces a new URL every run and
    /// trips a server-side `409 "Failed to create or update app while creating
    /// auth code"`. Their docs and their Discord support both recommend
    /// `http://localhost:3000` as the canonical desktop callback — they only
    /// guarantee the dedup fast-path for that exact URL. We keep the
    /// `/callback` suffix so the loopback server can still reject incidental
    /// browser probes like favicon requests.
    public static let callbackPort: UInt16 = 3000
    public static let callbackURL = "http://localhost:\(callbackPort)\(callbackPath)"

    // MARK: - Attribution

    /// Single source of truth for Osaurus's identity to OpenRouter. The same
    /// values are used both when minting the OAuth app row (in
    /// `exchangeCodeForKey`) and on every downstream chat-completion request
    /// (auto-injected in `RemoteProvider.resolvedHeaders()`), so the OAuth
    /// row and the per-request `HTTP-Referer` always agree.
    public enum Attribution {
        public static let host = "openrouter.ai"
        public static let referrerURL = "https://osaurus.ai"
        public static let appTitle = "Osaurus"
        public static let refererHeader = "HTTP-Referer"
        public static let titleHeader = "X-OpenRouter-Title"
    }

    // MARK: - Sign-in

    /// Runs the full PKCE flow and returns the freshly minted OpenRouter API key.
    /// The caller is responsible for persisting the key via the existing
    /// `RemoteProviderManager.addProvider(_:apiKey:)` path.
    @MainActor
    public static func signIn() async throws -> String {
        let pkce = try makePKCEPair()
        let state = PKCE.makeState()
        let callback = try await runAuthorizationFlow(state: state, codeChallenge: pkce.challenge)
        return try await exchangeCodeForKey(callback.code, verifier: pkce.verifier)
    }

    /// Spins up the loopback server, opens the browser, and resolves with the
    /// callback payload. Any underlying loopback / browser error is collapsed
    /// to `.invalidAuthorizationCallback` since the user can't act on the
    /// specifics; the only useful UI signal is "we didn't get a valid code".
    @MainActor
    private static func runAuthorizationFlow(
        state: String,
        codeChallenge: String
    ) async throws -> OAuthCallbackResult {
        let server: OAuthLoopbackServer
        do {
            server = try OAuthLoopbackServer(
                expectedState: state,
                port: .fixed(callbackPort),
                callbackPath: callbackPath
            )
            try await server.start()
        } catch {
            throw OpenRouterOAuthError.invalidAuthorizationCallback
        }
        defer { server.stop() }

        let authURL = authorizationURL(
            callbackURL: callbackURL,
            codeChallenge: codeChallenge,
            state: state
        )

        guard await NSWorkspace.shared.openAsync(authURL) else {
            throw OpenRouterOAuthError.invalidAuthorizationCallback
        }

        do {
            return try await server.waitForCallback()
        } catch {
            throw OpenRouterOAuthError.invalidAuthorizationCallback
        }
    }

    // MARK: - OAuth Helpers

    /// Builds the `/auth` URL the browser is opened to.
    /// Per the OpenRouter PKCE docs, the only required parameter is `callback_url`;
    /// we always include `code_challenge` + S256 (recommended) and `state` (CSRF).
    public static func authorizationURL(
        callbackURL: String,
        codeChallenge: String,
        state: String
    ) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackURL),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    public static func makePKCEPair() throws -> (verifier: String, challenge: String) {
        do {
            let pair = try PKCE.makePair()
            return (pair.verifier, pair.challenge)
        } catch {
            throw OpenRouterOAuthError.invalidPKCE
        }
    }

    /// Exchanges an authorization code for an OpenRouter user API key.
    /// OpenRouter's endpoint expects a **JSON** body (not form-encoded) and
    /// returns `{ "key": "sk-or-v1-..." }` on success.
    public static func exchangeCodeForKey(_ code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: keyExchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Per OpenRouter Discord support: the "referrer URL" should match the
        // app identity. Sending it here keeps the OAuth app row pinned to the
        // same Osaurus identity that future chat-completion requests present.
        request.setValue(Attribution.referrerURL, forHTTPHeaderField: Attribution.refererHeader)
        request.setValue(Attribution.appTitle, forHTTPHeaderField: Attribution.titleHeader)

        let body: [String: String] = [
            "code": code,
            "code_verifier": verifier,
            "code_challenge_method": "S256",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .osaurusCanonical)

        let (data, response) = try await GlobalProxySettings.sharedSession().data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterOAuthError.invalidKeyResponse
        }
        guard http.statusCode < 400 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw OpenRouterOAuthError.keyRequestFailed(message)
        }

        guard let decoded = try? JSONDecoder().decode(KeyResponse.self, from: data),
            !decoded.key.isEmpty
        else {
            throw OpenRouterOAuthError.invalidKeyResponse
        }
        return decoded.key
    }

    // MARK: Wire types

    private struct KeyResponse: Decodable {
        let key: String
    }
}
