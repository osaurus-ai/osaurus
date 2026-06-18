//
//  XAIOAuthService.swift
//  osaurus
//
//  xAI (Grok) OAuth 2.1 PKCE sign-in.
//
//  Modeled on OpenClaw's `xai-oauth.ts` and the ChatGPT/Codex flow. Unlike
//  OpenRouter (which mints a long-lived API key), xAI returns short-lived
//  `access_token` + `refresh_token` pairs, so this follows the Codex token
//  pattern: tokens are persisted via `RemoteProviderKeychain.saveOAuthTokens`
//  and refreshed on connect / before each request. The persisted provider uses
//  `authType: .xaiOAuth`, `providerType: .openaiLegacy` (xAI's API stays
//  OpenAI-compatible at `api.x.ai/v1`).
//
//  Requires a SuperGrok or X Premium+ subscription on the xAI account.
//

import AppKit
import Foundation

public enum XAIOAuthError: LocalizedError, Sendable {
    case invalidAuthorizationCallback
    case invalidPKCE
    case invalidTokenResponse
    case missingSignInTokens
    case discoveryFailed(String)
    case untrustedEndpoint(String)
    case tokenRequestFailed(String)
    case loopbackBindFailed(String)
    case browserOpenFailed
    case authorizationCallbackFailed(String)
    case authorizationCallbackRejected(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorizationCallback:
            return
                L(
                    "Grok sign-in did not return a valid authorization code. Try the sign-in again from the same browser window."
                )
        case .invalidPKCE:
            return L("Could not create a secure login challenge")
        case .invalidTokenResponse:
            return L("xAI returned an invalid token response during Grok sign-in")
        case .missingSignInTokens:
            return L("Missing Grok sign-in tokens. Sign in with Grok again, then retry the provider.")
        case .discoveryFailed(let message):
            return L("Could not load xAI OAuth configuration: \(XAIOAuthService.safeDiagnosticFragment(message))")
        case .untrustedEndpoint(let label):
            return L("xAI OAuth discovery returned an untrusted \(label)")
        case .tokenRequestFailed(let message):
            return L("xAI token request failed: \(XAIOAuthService.safeDiagnosticFragment(message))")
        case .loopbackBindFailed(let message):
            return
                L(
                    "Could not start the Grok sign-in callback server on 127.0.0.1:\(XAIOAuthService.callbackPort). Close any other in-progress sign-in or app using that port, then retry. Details: \(XAIOAuthService.safeDiagnosticFragment(message))"
                )
        case .browserOpenFailed:
            return
                L("Could not open the browser for Grok sign-in. Check the macOS default browser setting, then retry.")
        case .authorizationCallbackFailed(let message):
            return L("Grok sign-in callback failed: \(XAIOAuthService.safeDiagnosticFragment(message))")
        case .authorizationCallbackRejected(let message):
            return L("xAI rejected the sign-in callback: \(XAIOAuthService.safeDiagnosticFragment(message))")
        }
    }
}

public enum XAIOAuthService {

    // MARK: - Configuration

    /// xAI's shared OAuth client. Its loopback redirect (`127.0.0.1:56121
    /// /callback`) is pre-registered against this client, so the host/port/path
    /// below must match exactly. xAI may label the consent app using its shared
    /// app name because this client is not Osaurus-specific.
    public static let clientId = "b1a00492-073a-47ea-816f-4c329264a828"
    public static let scope = "openid profile email offline_access grok-cli:access api:access"
    public static let issuer = "https://auth.x.ai"
    public static let discoveryURL = URL(string: "\(issuer)/.well-known/openid-configuration")!

    public static let callbackHost = "127.0.0.1"
    public static let callbackPort: UInt16 = 56121
    public static let callbackPath = "/callback"
    public static let redirectURI = "http://\(callbackHost):\(callbackPort)\(callbackPath)"

    /// xAI's auth page delivers the authorization code to the loopback server via
    /// a browser `fetch()` from these origins (not a top-level redirect), so the
    /// callback server must echo `Access-Control-Allow-Origin` for them. Without
    /// this the fetch is CORS-blocked and the page shows "Could not establish
    /// connection" with a manual code-paste fallback.
    public static let corsOriginAllowlist = ["auth.x.ai", "accounts.x.ai"]

    private static let fetchTimeout: TimeInterval = 30

    /// Models reachable through the xAI OAuth ("Grok Build" / SuperGrok / X
    /// Premium+) entitlement. The OAuth access token is denied access to the
    /// `/models` endpoint (HTTP 403), so — like Codex — model discovery uses
    /// this built-in catalog rather than a live query. Mirrors OpenClaw's
    /// selectable xAI model set; `grok-4.3` is the default.
    public static let supportedModels: [String] = [
        "grok-4.3",
        "grok-build-0.1",
        "grok-4.20-beta-latest-reasoning",
        "grok-4.20-beta-latest-non-reasoning",
    ]

    // MARK: - Provider Factory

    public static func makeProvider(id: UUID = UUID()) -> RemoteProvider {
        RemoteProvider(
            id: id,
            name: "xAI",
            host: "api.x.ai",
            providerProtocol: .https,
            port: nil,
            basePath: "/v1",
            customHeaders: [:],
            authType: .xaiOAuth,
            providerType: .openaiLegacy,
            enabled: true,
            autoConnect: true,
            timeout: 300
        )
    }

    // MARK: - Sign-in / Token Refresh

    @MainActor
    public static func signIn() async throws -> RemoteProviderOAuthTokens {
        let discovery = try await fetchDiscovery()
        let pkce = try makePKCEPair()
        let state = PKCE.makeState()
        let nonce = PKCE.makeState()
        let url = authorizationURL(
            authorizationEndpoint: discovery.authorizationEndpoint,
            codeChallenge: pkce.challenge,
            state: state,
            nonce: nonce
        )

        let callback = try await authorize(url: url, state: state)
        return try await exchangeAuthorizationCode(
            callback.code,
            verifier: pkce.verifier,
            challenge: pkce.challenge,
            tokenEndpoint: discovery.tokenEndpoint
        )
    }

    public static func refresh(_ tokens: RemoteProviderOAuthTokens) async throws -> RemoteProviderOAuthTokens {
        let discovery = try await fetchDiscovery()
        return try await requestTokens(
            form: [
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
                "client_id": clientId,
            ],
            tokenEndpoint: discovery.tokenEndpoint,
            existingRefreshToken: tokens.refreshToken
        )
    }

    // MARK: - OAuth Helpers

    public static func authorizationURL(
        authorizationEndpoint: URL,
        codeChallenge: String,
        state: String,
        nonce: String
    ) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "plan", value: "generic"),
            URLQueryItem(name: "referrer", value: "osaurus"),
        ]
        return components.url!
    }

    public static func makePKCEPair() throws -> (verifier: String, challenge: String) {
        do {
            let pair = try PKCE.makePair()
            return (pair.verifier, pair.challenge)
        } catch {
            throw XAIOAuthError.invalidPKCE
        }
    }

    /// Extract the account identifier (`sub`) from the id/access token JWT.
    /// Returns an empty string when it can't be parsed — xAI's API does not
    /// require an account id header (unlike Codex), so this is purely
    /// informational for the persisted credential.
    public static func extractAccountId(idToken: String?, accessToken: String) -> String {
        for token in [idToken, accessToken].compactMap({ $0 }) {
            if let sub = decodeJWTClaim(token, claim: "sub"), !sub.isEmpty {
                return sub
            }
        }
        return ""
    }

    public static func exchangeAuthorizationCode(
        _ code: String,
        verifier: String,
        challenge: String,
        tokenEndpoint: URL
    ) async throws -> RemoteProviderOAuthTokens {
        try await requestTokens(
            form: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectURI,
                "client_id": clientId,
                "code_verifier": verifier,
                // xAI re-validates these PKCE fields at token exchange for
                // this client, so they must be resent here.
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            ],
            tokenEndpoint: tokenEndpoint,
            existingRefreshToken: nil
        )
    }

    // MARK: - Discovery

    struct Discovery: Sendable, Equatable {
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
    }

    /// True when `endpoint` is an HTTPS URL whose host is `x.ai` or a subdomain.
    public static func isTrustedEndpoint(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint),
            url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased()
        else {
            return false
        }
        return host == "x.ai" || host.hasSuffix(".x.ai")
    }

    static func fetchDiscovery() async throws -> Discovery {
        var request = URLRequest(url: discoveryURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = fetchTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await GlobalProxySettings.sharedSession().data(for: request)
        } catch {
            throw XAIOAuthError.discoveryFailed("Network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw XAIOAuthError.discoveryFailed("HTTP \(status)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let authorization = json["authorization_endpoint"] as? String,
            let token = json["token_endpoint"] as? String
        else {
            throw XAIOAuthError.discoveryFailed("missing endpoints")
        }
        guard isTrustedEndpoint(authorization), let authorizationURL = URL(string: authorization) else {
            throw XAIOAuthError.untrustedEndpoint("authorization endpoint")
        }
        guard isTrustedEndpoint(token), let tokenURL = URL(string: token) else {
            throw XAIOAuthError.untrustedEndpoint("token endpoint")
        }
        return Discovery(authorizationEndpoint: authorizationURL, tokenEndpoint: tokenURL)
    }

    // MARK: - Diagnostics

    public static func diagnosticMessage(for error: Error) -> String {
        if let xaiError = error as? XAIOAuthError {
            return xaiError.errorDescription ?? "Grok sign-in failed"
        }
        if let loopbackError = error as? OAuthLoopbackError {
            return mapLoopbackError(loopbackError).errorDescription ?? "Grok sign-in failed"
        }
        return "Grok sign-in failed: \(safeDiagnosticFragment(error.localizedDescription))"
    }

    /// Redact OAuth credentials from provider diagnostics while preserving
    /// enough status/body detail for maintainers to understand what failed.
    public static func safeDiagnosticFragment(_ raw: String, maxLength: Int = 240) -> String {
        var value = raw
        let replacements: [(pattern: String, template: String)] = [
            (#"(?i)authorization\s*[:=]\s*(?:bearer\s+)?[^\s,;}]+\"?"#, "credential=***"),
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "credential=***"),
            (#"(?i)\"(access_token|refresh_token|code_verifier|code|verifier)\"\s*:\s*\"[^\"]*\""#, #""$1":"***""#),
            (#"(?i)\b(access_token|refresh_token|code_verifier|code|verifier)=([^&\s,;}]+)"#, "$1=***"),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "jwt=***"),
        ]
        for replacement in replacements {
            value = value.xaiReplacingMatches(of: replacement.pattern, with: replacement.template)
        }

        value = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }

        guard !value.isEmpty else { return "No details returned" }
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength)) + "..."
    }

    // MARK: - Internals

    static func decodeJWTClaim(_ token: String, claim: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
            let payload = PKCE.decodeBase64URL(String(parts[1])),
            let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let value = json[claim] as? String
        else {
            return nil
        }
        return value
    }

    // MARK: Wire types

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: TimeInterval?
        let id_token: String?
    }

    // MARK: Networking

    private static func requestTokens(
        form: [String: String],
        tokenEndpoint: URL,
        existingRefreshToken: String?
    ) async throws -> RemoteProviderOAuthTokens {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OAuthFormEncoding.encode(form).data(using: .utf8)
        request.timeoutInterval = fetchTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await GlobalProxySettings.sharedSession().data(for: request)
        } catch {
            throw XAIOAuthError.tokenRequestFailed("Network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw XAIOAuthError.invalidTokenResponse
        }
        guard http.statusCode < 400 else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw XAIOAuthError.tokenRequestFailed("HTTP \(http.statusCode): \(body)")
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data),
            !decoded.access_token.isEmpty
        else {
            throw XAIOAuthError.invalidTokenResponse
        }
        guard let refreshToken = decoded.refresh_token ?? existingRefreshToken, !refreshToken.isEmpty else {
            throw XAIOAuthError.invalidTokenResponse
        }

        let expiresAt =
            decoded.expires_in.map { Date().addingTimeInterval($0) }
            ?? Date().addingTimeInterval(3600)
        let accountId = extractAccountId(idToken: decoded.id_token, accessToken: decoded.access_token)

        return RemoteProviderOAuthTokens(
            accessToken: decoded.access_token,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            accountId: accountId
        )
    }

    @MainActor
    private static func authorize(url: URL, state: String) async throws -> OAuthCallbackResult {
        // xAI registered http://127.0.0.1:56121/callback as the redirect URI
        // for this client, so the port must stay fixed.
        let server: OAuthLoopbackServer
        do {
            server = try OAuthLoopbackServer(
                expectedState: state,
                port: .fixed(callbackPort),
                callbackPath: callbackPath,
                corsOriginAllowlist: corsOriginAllowlist
            )
            try await server.start()
        } catch let error as OAuthLoopbackError {
            throw mapLoopbackError(error)
        } catch {
            throw XAIOAuthError.loopbackBindFailed(error.localizedDescription)
        }
        defer { server.stop() }

        guard await NSWorkspace.shared.openAsync(url) else {
            throw XAIOAuthError.browserOpenFailed
        }

        do {
            return try await server.waitForCallback()
        } catch let error as OAuthLoopbackError {
            throw mapLoopbackError(error)
        } catch {
            throw XAIOAuthError.authorizationCallbackFailed(error.localizedDescription)
        }
    }

    private static func mapLoopbackError(_ error: OAuthLoopbackError) -> XAIOAuthError {
        switch error {
        case .bindFailed(let message):
            return .loopbackBindFailed(message)
        case .stateMismatch:
            return .authorizationCallbackRejected("state mismatch from browser callback")
        case .missingCode:
            return .authorizationCallbackRejected("missing authorization code")
        case .oauthError(let error, let description):
            let detail = [error, description].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            return .authorizationCallbackRejected(detail.isEmpty ? "OAuth provider returned an error" : detail)
        case .invalidCallback:
            return .authorizationCallbackFailed("invalid callback path or request")
        }
    }
}

// MARK: - Helpers

extension String {
    fileprivate func xaiReplacingMatches(of pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let range = NSRange(startIndex ..< endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, range: range, withTemplate: template)
    }
}
