//
//  MCPOAuthService.swift
//  osaurus
//
//  Sign-in / refresh orchestration for remote MCP providers.
//
//  This is the single entrypoint the UI and `MCPProviderManager` use:
//
//    let result = try await MCPOAuthService.signIn(provider:, hint:)
//      // result includes refreshed MCPOAuthConfig + MCPOAuthTokens
//      // (already saved to Keychain by this service)
//
//    let refreshed = try await MCPOAuthService.refresh(provider:, tokens:)
//      // returns refreshed tokens; saves to Keychain
//
//  All steps follow the MCP `2025-06-18` authorization spec:
//    - PRM (RFC 9728) → ASM (RFC 8414, with OIDC fallback)
//    - DCR (RFC 7591) for `client_id`, with a fallback path for confidential-
//      client vendors (e.g. HubSpot's MCP Auth Apps) that don't publish a
//      `registration_endpoint` and instead require the user to register an
//      OAuth app by hand and supply both `client_id` and `client_secret`.
//    - PKCE S256 + state for the authorize step.
//    - RFC 8707 `resource=` parameter on every authorize / token request.
//    - Loopback `http://127.0.0.1:<port>/callback` redirect URI. The port is
//      kernel-assigned by default; vendors that require an exact-match
//      registered redirect URI can pin it via
//      `MCPOAuthConfig.loopbackPort`.
//

import AppKit
import Foundation

public enum MCPOAuthError: LocalizedError, Sendable {
    case invalidServerURL
    case missingClientId
    case missingTokenEndpoint
    case missingAuthorizationEndpoint
    case missingRefreshToken
    case canonicalResourceFailed
    case invalidTokenResponse
    case tokenRequestFailed(Int, String?)
    case discovery(MCPOAuthDiscoveryError)
    case registration(MCPOAuthRegistrationError)
    case loopback(OAuthLoopbackError)
    case pkce
    case browserOpenFailed
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "MCP server URL is not a valid HTTP(S) URL"
        case .missingClientId:
            return
                "OAuth client_id is missing — register an app with the authorization server or paste a client_id manually"
        case .missingTokenEndpoint: return "Authorization server metadata is missing token_endpoint"
        case .missingAuthorizationEndpoint:
            return "Authorization server metadata is missing authorization_endpoint"
        case .missingRefreshToken:
            return "No refresh_token available — the user must sign in again"
        case .canonicalResourceFailed:
            return "Could not derive canonical resource URL for OAuth resource indicator"
        case .invalidTokenResponse: return "OAuth token response was not valid JSON"
        case .tokenRequestFailed(let code, let body):
            if let body, !body.isEmpty {
                return "OAuth token request failed with HTTP \(code): \(body)"
            }
            return "OAuth token request failed with HTTP \(code)"
        case .discovery(let inner): return inner.errorDescription
        case .registration(let inner): return inner.errorDescription
        case .loopback(let inner): return inner.errorDescription
        case .pkce: return "Could not create a secure login challenge"
        case .browserOpenFailed: return "Could not open the browser to complete sign-in"
        case .transport(let msg): return "OAuth network error: \(msg)"
        }
    }
}

/// Result of a successful sign-in: tokens persisted to Keychain + the cached config to
/// stash on the `MCPProvider` so we don't re-discover or re-register on every refresh.
public struct MCPOAuthSignInResult: Sendable, Equatable {
    public let config: MCPOAuthConfig
    public let tokens: MCPOAuthTokens
}

public enum MCPOAuthService {
    /// Conservative default scopes when neither PRM nor `WWW-Authenticate scope=`
    /// gives a hint. `offline_access` is requested so the AS issues a refresh token.
    public static let defaultScopes: [String] = ["offline_access"]

    /// Run the full OAuth sign-in flow for `provider`.
    ///
    /// - Parameters:
    ///   - provider: Provider record. Its `oauth.clientId` is reused if already DCR-registered.
    ///   - hint: Optional `WWW-Authenticate` challenge from a 401 response, used to skip
    ///     `.well-known` probing and to pull a `scope=` hint.
    ///   - persist: When true (default), tokens are saved to the Keychain under `provider.id`.
    ///     Tests pass `false` to keep the keychain clean.
    @MainActor
    public static func signIn(
        provider: MCPProvider,
        hint: MCPBearerChallenge? = nil,
        persist: Bool = true
    ) async throws -> MCPOAuthSignInResult {
        guard let serverURL = URL(string: provider.url) else {
            throw MCPOAuthError.invalidServerURL
        }
        guard let canonical = MCPOAuthCanonicalURL.canonicalize(serverURL) else {
            throw MCPOAuthError.canonicalResourceFailed
        }

        // 1. Discovery — PRM then ASM. Skipped when the provider record already
        //    carries a complete manual override (both `authorizationEndpoint` and
        //    `tokenEndpoint`); this lets users wire up MCP servers that don't
        //    implement RFC 9728 PRM (e.g. plugins that ship explicit endpoints
        //    in their `.mcp.json` oauth block).
        let (prm, asm): (MCPProtectedResourceMetadata, MCPAuthorizationServerMetadata)
        if let manualPair = manualMetadata(from: provider.oauth, serverURL: serverURL) {
            (prm, asm) = manualPair
        } else {
            do {
                (prm, asm) = try await MCPOAuthDiscovery.shared.discover(
                    serverURL: serverURL,
                    hint: hint?.resourceMetadataURL
                )
            } catch let error as MCPOAuthDiscoveryError {
                throw MCPOAuthError.discovery(error)
            }
        }

        // 2. Resolve scopes.
        let scopes = resolveScopes(provider: provider, prm: prm, asm: asm, hint: hint)

        // 3. Loopback server on an ephemeral port — or a provider-specified
        // fixed port when the vendor requires an exact-match redirect URI
        // (HubSpot's MCP Auth Apps register a single redirect URI with the
        // exact port baked in).
        let pkce: PKCEPair
        do {
            pkce = try PKCE.makePair()
        } catch {
            throw MCPOAuthError.pkce
        }
        let state = PKCE.makeState()

        let loopbackPort: LoopbackPort = {
            if let pinned = provider.oauth?.loopbackPort, pinned != 0 {
                return .fixed(pinned)
            }
            return .ephemeral
        }()

        let server: OAuthLoopbackServer
        do {
            server = try OAuthLoopbackServer(
                expectedState: state,
                port: loopbackPort,
                callbackPath: "/callback"
            )
            try await server.start()
        } catch let error as OAuthLoopbackError {
            throw MCPOAuthError.loopback(error)
        } catch {
            throw MCPOAuthError.transport(error.localizedDescription)
        }
        defer { server.stop() }

        guard let port = server.boundPort, port != 0 else {
            throw MCPOAuthError.loopback(.bindFailed("listener never reported a port"))
        }
        let redirectURI = "http://127.0.0.1:\(port)/callback"

        // 4. Ensure we have a `client_id`. Order of preference:
        //    a. Cached on the provider record (manual entry for vendors without
        //       DCR — HubSpot's MCP Auth Apps — or a previous DCR result).
        //    b. RFC 7591 Dynamic Client Registration when the AS publishes a
        //       `registration_endpoint`.
        //    Skipping DCR when (a) is set lets us support confidential-client
        //    OAuth providers whose AS metadata advertises no DCR.
        let clientId: String
        if let cached = provider.oauth?.clientId, !cached.isEmpty {
            clientId = cached
        } else {
            guard let registrationEndpoint = asm.registrationEndpoint, !registrationEndpoint.isEmpty else {
                throw MCPOAuthError.registration(.missingRegistrationEndpoint)
            }
            do {
                let registration = try await MCPOAuthRegistration.register(
                    registrationEndpoint: registrationEndpoint,
                    redirectURI: redirectURI,
                    clientName: "Osaurus",
                    scopes: scopes
                )
                clientId = registration.clientId
            } catch let error as MCPOAuthRegistrationError {
                throw MCPOAuthError.registration(error)
            }
        }

        // Confidential-client `client_secret`, when stored in Keychain. Vendors
        // whose ASM advertises `client_secret_post` (HubSpot) need this in
        // every token POST; public-native clients leave it empty and rely on
        // PKCE alone.
        let clientSecret = resolveClientSecret(for: provider.id)

        // 5. Build the authorization URL and open the browser.
        guard let authorizeURL = URL(string: asm.authorizationEndpoint) else {
            throw MCPOAuthError.missingAuthorizationEndpoint
        }
        let url = authorizationURL(
            authorizationEndpoint: authorizeURL,
            clientId: clientId,
            redirectURI: redirectURI,
            codeChallenge: pkce.challenge,
            state: state,
            scopes: scopes,
            resource: canonical
        )

        guard await NSWorkspace.shared.openAsync(url) else {
            throw MCPOAuthError.browserOpenFailed
        }

        // 6. Wait for callback.
        let callback: OAuthCallbackResult
        do {
            callback = try await server.waitForCallback()
        } catch let error as OAuthLoopbackError {
            throw MCPOAuthError.loopback(error)
        }

        // 7. Exchange code for tokens.
        guard let tokenURL = URL(string: asm.tokenEndpoint) else {
            throw MCPOAuthError.missingTokenEndpoint
        }
        let tokens = try await exchangeAuthorizationCode(
            tokenURL: tokenURL,
            clientId: clientId,
            clientSecret: clientSecret,
            code: callback.code,
            verifier: pkce.verifier,
            redirectURI: redirectURI,
            resource: canonical
        )

        // 8. Build the cached config and persist tokens. Preserve the
        // `loopbackPort` from the input so the next refresh / re-sign-in
        // keeps using the same port the vendor expects.
        let config = MCPOAuthConfig(
            clientId: clientId,
            redirectURI: redirectURI,
            scopes: scopes,
            resource: canonical,
            issuer: asm.issuer,
            authorizationEndpoint: asm.authorizationEndpoint,
            tokenEndpoint: asm.tokenEndpoint,
            registrationEndpoint: asm.registrationEndpoint,
            serverMetadataCachedAt: Date(),
            loopbackPort: provider.oauth?.loopbackPort
        )
        if persist {
            MCPProviderKeychain.saveOAuthTokens(tokens, for: provider.id)
        }
        return MCPOAuthSignInResult(config: config, tokens: tokens)
    }

    /// Refresh OAuth tokens using the cached configuration. Saves the result to Keychain
    /// when `persist` is true. Throws if the provider has no refresh_token.
    public static func refresh(
        provider: MCPProvider,
        tokens: MCPOAuthTokens,
        persist: Bool = true
    ) async throws -> MCPOAuthTokens {
        guard let oauth = provider.oauth else {
            throw MCPOAuthError.missingClientId
        }
        guard let clientId = oauth.clientId else {
            throw MCPOAuthError.missingClientId
        }
        guard let tokenEndpoint = oauth.tokenEndpoint, let tokenURL = URL(string: tokenEndpoint) else {
            throw MCPOAuthError.missingTokenEndpoint
        }
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw MCPOAuthError.missingRefreshToken
        }

        var form: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ]
        // Confidential-client OAuth (HubSpot) advertises `client_secret_post`
        // and rejects refresh requests without `client_secret`. Public clients
        // never store one, so this branch is a no-op for the DCR path.
        if let secret = resolveClientSecret(for: provider.id), !secret.isEmpty {
            form["client_secret"] = secret
        }
        if let resource = oauth.resource, !resource.isEmpty {
            form["resource"] = resource
        }
        if !oauth.scopes.isEmpty {
            form["scope"] = oauth.scopes.joined(separator: " ")
        }

        let raw = try await postTokenRequest(url: tokenURL, form: form)
        // Refresh-token rotation: some servers (Notion) return a new RT, some don't.
        // Fall back to the existing one when omitted.
        let newRefresh = raw.refreshToken ?? refreshToken
        let refreshed = MCPOAuthTokens(
            accessToken: raw.accessToken,
            refreshToken: newRefresh,
            expiresAt: raw.expiresAt,
            scope: raw.scope ?? tokens.scope
        )
        if persist {
            MCPProviderKeychain.saveOAuthTokens(refreshed, for: provider.id)
        }
        return refreshed
    }

    // MARK: - Internal helpers (also used by tests)

    /// Build the authorize URL with the full required parameter set.
    public static func authorizationURL(
        authorizationEndpoint: URL,
        clientId: String,
        redirectURI: String,
        codeChallenge: String,
        state: String,
        scopes: [String],
        resource: String?
    ) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if !scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        if let resource, !resource.isEmpty {
            items.append(URLQueryItem(name: "resource", value: resource))
        }
        components.queryItems = items
        return components.url!
    }

    /// Build synthetic PRM/ASM from a provider's manually-supplied OAuth config.
    /// Returns `nil` unless **both** `authorizationEndpoint` and `tokenEndpoint`
    /// are populated — those are the two pieces discovery cannot work around.
    /// Used to support MCP servers that don't implement RFC 9728 PRM but still
    /// expect a standard authorization-code/PKCE flow.
    static func manualMetadata(
        from oauth: MCPOAuthConfig?,
        serverURL: URL
    ) -> (MCPProtectedResourceMetadata, MCPAuthorizationServerMetadata)? {
        guard let oauth,
            let authEndpoint = oauth.authorizationEndpoint, !authEndpoint.isEmpty,
            let tokenEndpoint = oauth.tokenEndpoint, !tokenEndpoint.isEmpty
        else { return nil }

        let issuer =
            oauth.issuer
            ?? authEndpoint.components(separatedBy: "/").prefix(3)
            .joined(separator: "/")
        let prm = MCPProtectedResourceMetadata(
            resource: serverURL.absoluteString,
            authorizationServers: [issuer],
            scopesSupported: oauth.scopes.isEmpty ? nil : oauth.scopes,
            bearerMethodsSupported: ["header"]
        )
        let asm = MCPAuthorizationServerMetadata(
            issuer: issuer,
            authorizationEndpoint: authEndpoint,
            tokenEndpoint: tokenEndpoint,
            registrationEndpoint: oauth.registrationEndpoint,
            scopesSupported: oauth.scopes.isEmpty ? nil : oauth.scopes,
            codeChallengeMethodsSupported: ["S256"],
            grantTypesSupported: ["authorization_code", "refresh_token"],
            tokenEndpointAuthMethodsSupported: ["none"]
        )
        return (prm, asm)
    }

    /// Resolve the scope list for the authorize/token request.
    /// Precedence: explicit hint scope > saved provider scopes > PRM `scopes_supported` > default.
    static func resolveScopes(
        provider: MCPProvider,
        prm: MCPProtectedResourceMetadata,
        asm: MCPAuthorizationServerMetadata,
        hint: MCPBearerChallenge?
    ) -> [String] {
        if let hintScope = hint?.scope, !hintScope.isEmpty {
            return hintScope.split(separator: " ").map(String.init)
        }
        if let saved = provider.oauth?.scopes, !saved.isEmpty {
            return saved
        }
        if let supported = prm.scopesSupported, !supported.isEmpty {
            return supported
        }
        if let asmScopes = asm.scopesSupported, !asmScopes.isEmpty {
            return asmScopes
        }
        return defaultScopes
    }

    /// Exchange an authorization code for tokens. Always sends `resource=`.
    /// `clientSecret` is included in the form body when non-nil — required for
    /// confidential-client OAuth providers whose ASM advertises
    /// `client_secret_post` (e.g. HubSpot).
    public static func exchangeAuthorizationCode(
        tokenURL: URL,
        clientId: String,
        clientSecret: String? = nil,
        code: String,
        verifier: String,
        redirectURI: String,
        resource: String?
    ) async throws -> MCPOAuthTokens {
        var form: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
        ]
        if let clientSecret, !clientSecret.isEmpty {
            form["client_secret"] = clientSecret
        }
        if let resource, !resource.isEmpty {
            form["resource"] = resource
        }
        let parsed = try await postTokenRequest(url: tokenURL, form: form)
        return MCPOAuthTokens(
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken,
            expiresAt: parsed.expiresAt,
            scope: parsed.scope
        )
    }

    /// Test seam: replace with a fixture-driven token POST in unit tests.
    nonisolated(unsafe) public static var tokenRequestOverride:
        ((URL, [String: String]) async throws -> ParsedTokenResponse)?

    /// Test seam: replace the Keychain lookup for `client_secret` in unit
    /// tests. Production code should leave this nil so the real Keychain
    /// wrapper is used.
    nonisolated(unsafe) public static var clientSecretAccessorOverride: ((UUID) -> String?)?

    /// Resolve the `client_secret` for `providerId`. Tests stub this via
    /// `clientSecretAccessorOverride`; production reads from Keychain.
    static func resolveClientSecret(for providerId: UUID) -> String? {
        if let override = clientSecretAccessorOverride {
            return override(providerId)
        }
        return MCPProviderKeychain.getOAuthClientSecret(for: providerId)
    }

    public struct ParsedTokenResponse: Sendable, Equatable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresAt: Date
        public let scope: String?
    }

    static func postTokenRequest(url: URL, form: [String: String]) async throws -> ParsedTokenResponse {
        if let override = tokenRequestOverride {
            return try await override(url, form)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OAuthFormEncoding.encode(form).data(using: .utf8)
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await MCPOAuthHTTPTransport.noRedirectSession().data(for: request)
        } catch {
            throw MCPOAuthError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MCPOAuthError.transport("non-HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw MCPOAuthError.tokenRequestFailed(http.statusCode, String(data: data, encoding: .utf8))
        }
        return try parseTokenResponse(data)
    }

    /// Parse a token endpoint response. Internal so tests can drive it without HTTP.
    static func parseTokenResponse(_ data: Data) throws -> ParsedTokenResponse {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MCPOAuthError.invalidTokenResponse
        }
        guard let dict = json as? [String: Any] else {
            throw MCPOAuthError.invalidTokenResponse
        }
        guard let accessToken = dict["access_token"] as? String, !accessToken.isEmpty else {
            throw MCPOAuthError.invalidTokenResponse
        }
        // `expires_in` is RECOMMENDED but not REQUIRED by RFC 6749. Default to 1h
        // when absent so we still refresh proactively rather than waiting for 401.
        let expiresIn: TimeInterval = (dict["expires_in"] as? TimeInterval) ?? 3600
        let refreshToken = dict["refresh_token"] as? String
        let scope = dict["scope"] as? String
        return ParsedTokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            scope: scope
        )
    }
}
