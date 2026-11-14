//
//  MCPOAuthClientMetadata.swift
//  osaurus
//
//  Client registration strategy for MCP OAuth, including Client ID Metadata
//  Documents (CIMD, MCP 2025-11-25 authorization; the preferred mechanism in
//  2026-07-28, which deprecates Dynamic Client Registration).
//
//  With CIMD the `client_id` is an HTTPS URL the authorization server fetches
//  to learn the client's name and redirect URIs, so no per-server
//  registration round trip is needed. The document is published on the
//  osaurus.ai website (source of truth: `docs/oauth/mcp-client-metadata.json`).
//  Before it is used, the published copy is fetched and validated once per
//  launch; until it is live, sign-in falls back to DCR.
//
//  Registration order:
//    1. A cached `client_id` bound to the same issuer (manual credentials or a
//       previous registration). Credentials are never reused across issuers.
//    2. CIMD, when the AS advertises `client_id_metadata_document_supported`.
//    3. RFC 7591 DCR, when the AS publishes a `registration_endpoint`.
//

import Foundation
import os

enum MCPOAuthClientRegistrationStrategy: Equatable, Sendable {
    case cached(clientId: String)
    case metadataDocument(clientId: String)
    case dynamicRegistration(endpoint: String)
    case unavailable
}

enum MCPOAuthClientMetadata {
    static let documentURL = URL(string: "https://osaurus.ai/oauth/mcp-client-metadata.json")!

    static let clientName = "Osaurus"

    /// Loopback redirect URIs. Per RFC 8252 §7.3 the AS matches loopback
    /// redirects without the port, which is kernel-assigned per sign-in.
    static let redirectURIs = ["http://127.0.0.1/callback", "http://localhost/callback"]

    /// The document as it must be published at `documentURL`.
    static var document: [String: Any] {
        [
            "client_id": documentURL.absoluteString,
            "client_name": clientName,
            "client_uri": "https://osaurus.ai",
            "tos_uri": OsaurusWebLinks.terms.absoluteString,
            "policy_uri": OsaurusWebLinks.privacy.absoluteString,
            "redirect_uris": redirectURIs,
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
        ]
    }

    /// A published document is usable only when its `client_id` is exactly
    /// the URL it was served from and it lists the loopback redirect we use.
    static func isValidPublishedDocument(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["client_id"] as? String == documentURL.absoluteString,
            let redirects = object["redirect_uris"] as? [String]
        else { return false }
        return redirects.contains("http://127.0.0.1/callback")
            && (object["token_endpoint_auth_method"] as? String ?? "none") == "none"
    }

    static func strategy(
        cachedClientId: String?,
        cachedIssuer: String?,
        asm: MCPAuthorizationServerMetadata,
        metadataDocumentPublished: Bool
    ) -> MCPOAuthClientRegistrationStrategy {
        if let cachedClientId, !cachedClientId.isEmpty,
            cachedIssuer == nil || cachedIssuer == asm.issuer
        {
            return .cached(clientId: cachedClientId)
        }
        if asm.clientIdMetadataDocumentSupported == true, metadataDocumentPublished {
            return .metadataDocument(clientId: documentURL.absoluteString)
        }
        if let endpoint = asm.registrationEndpoint, !endpoint.isEmpty {
            return .dynamicRegistration(endpoint: endpoint)
        }
        return .unavailable
    }

    // MARK: - Published-document check

    private struct PublishedCheck {
        var published: Bool
        var checkedAt: Date
    }

    private static let publishedCheck = OSAllocatedUnfairLock<PublishedCheck?>(initialState: nil)

    /// A failed check is retried after this interval so a newly published
    /// document is picked up without a relaunch.
    static let negativeCheckTTL: TimeInterval = 600

    /// Test seam.
    nonisolated(unsafe) static var publishedOverride: Bool?

    static func isDocumentPublished() async -> Bool {
        if let publishedOverride { return publishedOverride }
        if let cached = publishedCheck.withLock({ $0 }),
            cached.published || Date().timeIntervalSince(cached.checkedAt) < negativeCheckTTL
        {
            return cached.published
        }
        var request = URLRequest(url: documentURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        var published = false
        if let (data, response) = try? await MCPOAuthHTTPTransport.noRedirectSession().data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        {
            published = isValidPublishedDocument(data)
        }
        let check = PublishedCheck(published: published, checkedAt: Date())
        publishedCheck.withLock { $0 = check }
        return check.published
    }

    // MARK: - Issuer validation (RFC 9207)

    /// Validate the `iss` authorization-response parameter against the
    /// issuer discovery returned. A present but different `iss` is a mix-up
    /// attack signal; a missing one is only an error when the AS promised it.
    static func validateIssuer(
        callbackURL: URL,
        asm: MCPAuthorizationServerMetadata
    ) -> MCPOAuthIssuerValidation {
        let iss = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "iss" }?.value
        guard let iss, !iss.isEmpty else {
            return asm.authorizationResponseIssParameterSupported == true ? .missing : .valid
        }
        return normalizedIssuer(iss) == normalizedIssuer(asm.issuer) ? .valid : .mismatch(received: iss)
    }

    private static func normalizedIssuer(_ issuer: String) -> String {
        issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer
    }
}

enum MCPOAuthIssuerValidation: Equatable, Sendable {
    case valid
    case missing
    case mismatch(received: String)
}
