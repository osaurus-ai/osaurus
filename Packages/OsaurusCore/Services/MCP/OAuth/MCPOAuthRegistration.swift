//
//  MCPOAuthRegistration.swift
//  osaurus
//
//  RFC 7591 Dynamic Client Registration for the MCP authorization spec.
//
//  We register Osaurus as a **public** native client (no client secret) using
//  loopback redirect URIs per RFC 8252. The resulting `client_id` is cached
//  in the provider's `MCPOAuthConfig` so we don't re-register on every
//  sign-in / refresh.
//
//  Production servers (Linear, Notion, Atlassian) all support DCR per the
//  MCP `2025-06-18` spec; servers that don't will fail with 404, in which
//  case the user has to provide a `client_id` manually (future feature).
//

import Foundation

public struct MCPDynamicClientRegistration: Sendable, Equatable {
    public let clientId: String
    /// Some servers (Notion does this) issue a `client_secret` even for `none` auth
    /// on public clients. We cache it but never embed it in the binary.
    public let clientSecret: String?
    /// `client_id_issued_at` if present.
    public let issuedAt: Date?
    /// Some servers issue an opaque `registration_access_token` plus
    /// `registration_client_uri` so the client can manage its own DCR record.
    /// Captured for completeness; not currently used by the manager.
    public let registrationAccessToken: String?

    public init(
        clientId: String,
        clientSecret: String? = nil,
        issuedAt: Date? = nil,
        registrationAccessToken: String? = nil
    ) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.issuedAt = issuedAt
        self.registrationAccessToken = registrationAccessToken
    }
}

public enum MCPOAuthRegistrationError: LocalizedError, Sendable {
    case missingRegistrationEndpoint
    case invalidRegistrationURL
    case httpError(Int, String?)
    case decodeFailed(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingRegistrationEndpoint:
            return "Authorization server does not support Dynamic Client Registration"
        case .invalidRegistrationURL:
            return "Authorization server returned an invalid registration_endpoint"
        case .httpError(let code, let body):
            if let body, !body.isEmpty {
                return "Dynamic client registration HTTP \(code): \(body)"
            }
            return "Dynamic client registration HTTP \(code)"
        case .decodeFailed(let msg):
            return "Could not decode DCR response: \(msg)"
        case .transport(let msg):
            return "DCR network error: \(msg)"
        }
    }
}

public enum MCPOAuthRegistration {
    /// Test seam — replace with a fixture-driven `register` for unit tests.
    nonisolated(unsafe) public static var registerOverride:
        ((URL, [String: Any]) async throws -> MCPDynamicClientRegistration)?

    /// Register a new public-native client with the authorization server.
    /// Returns the registration payload the caller should cache on the provider.
    public static func register(
        registrationEndpoint: String,
        redirectURI: String,
        clientName: String,
        scopes: [String]
    ) async throws -> MCPDynamicClientRegistration {
        guard let url = URL(string: registrationEndpoint) else {
            throw MCPOAuthRegistrationError.invalidRegistrationURL
        }

        let body: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            // Public client per RFC 6749 §2.1; PKCE is the security boundary.
            "token_endpoint_auth_method": "none",
            // Native-app metadata so the AS can render an appropriate consent UI.
            "application_type": "native",
            // Some servers honor scope hints during DCR (Atlassian does).
            "scope": scopes.joined(separator: " "),
        ]

        if let override = registerOverride {
            return try await override(url, body)
        }

        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: body, options: .osaurusCanonical)
        } catch {
            throw MCPOAuthRegistrationError.decodeFailed(error.localizedDescription)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = payload
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await MCPOAuthHTTPTransport.noRedirectSession().data(for: request)
        } catch {
            throw MCPOAuthRegistrationError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MCPOAuthRegistrationError.transport("non-HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw MCPOAuthRegistrationError.httpError(http.statusCode, String(data: data, encoding: .utf8))
        }
        return try parseRegistrationResponse(data)
    }

    /// Parse a DCR JSON response. `internal` so unit tests can drive it without HTTP.
    static func parseRegistrationResponse(_ data: Data) throws -> MCPDynamicClientRegistration {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MCPOAuthRegistrationError.decodeFailed(error.localizedDescription)
        }
        guard let dict = json as? [String: Any] else {
            throw MCPOAuthRegistrationError.decodeFailed("response was not a JSON object")
        }
        guard let clientId = dict["client_id"] as? String, !clientId.isEmpty else {
            throw MCPOAuthRegistrationError.decodeFailed("missing client_id")
        }
        let clientSecret = dict["client_secret"] as? String
        let issuedAt: Date? = (dict["client_id_issued_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let regAccessToken = dict["registration_access_token"] as? String
        return MCPDynamicClientRegistration(
            clientId: clientId,
            clientSecret: clientSecret,
            issuedAt: issuedAt,
            registrationAccessToken: regAccessToken
        )
    }
}
