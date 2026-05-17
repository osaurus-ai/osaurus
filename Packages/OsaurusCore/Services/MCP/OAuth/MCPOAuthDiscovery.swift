//
//  MCPOAuthDiscovery.swift
//  osaurus
//
//  RFC 9728 (OAuth 2.0 Protected Resource Metadata) +
//  RFC 8414 (Authorization Server Metadata) discovery for MCP servers.
//
//  Two-step discovery flow per the MCP `2025-06-18` authorization spec:
//
//  1. Find PRM:
//     - Use `resource_metadata=` URL from a `WWW-Authenticate` header if present.
//     - Otherwise probe `<server>/.well-known/oauth-protected-resource` (path-scoped).
//  2. PRM yields one or more `authorization_servers` URLs. For each, fetch ASM:
//     - Try `<as>/.well-known/oauth-authorization-server` (RFC 8414).
//     - Fallback: `<as>/.well-known/openid-configuration` (OIDC discovery — many
//       MCP servers proxy through Cognito/Auth0/etc., which only ship this one).
//
//  All network methods are non-isolated so they can be called from background
//  contexts; only the in-memory cache is annotated.
//

import Foundation

/// RFC 9728 fields the MCP client cares about. Servers may return more; we ignore the rest.
public struct MCPProtectedResourceMetadata: Decodable, Sendable, Equatable {
    public let resource: String?
    public let authorizationServers: [String]
    public let scopesSupported: [String]?
    public let bearerMethodsSupported: [String]?

    private enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
        case bearerMethodsSupported = "bearer_methods_supported"
    }

    public init(
        resource: String?,
        authorizationServers: [String],
        scopesSupported: [String]?,
        bearerMethodsSupported: [String]?
    ) {
        self.resource = resource
        self.authorizationServers = authorizationServers
        self.scopesSupported = scopesSupported
        self.bearerMethodsSupported = bearerMethodsSupported
    }
}

/// Subset of RFC 8414 / OIDC discovery the MCP client cares about.
public struct MCPAuthorizationServerMetadata: Decodable, Sendable, Equatable {
    public let issuer: String
    public let authorizationEndpoint: String
    public let tokenEndpoint: String
    public let registrationEndpoint: String?
    public let scopesSupported: [String]?
    public let codeChallengeMethodsSupported: [String]?
    public let grantTypesSupported: [String]?
    public let tokenEndpointAuthMethodsSupported: [String]?

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case grantTypesSupported = "grant_types_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
    }

    public init(
        issuer: String,
        authorizationEndpoint: String,
        tokenEndpoint: String,
        registrationEndpoint: String?,
        scopesSupported: [String]?,
        codeChallengeMethodsSupported: [String]?,
        grantTypesSupported: [String]?,
        tokenEndpointAuthMethodsSupported: [String]?
    ) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.scopesSupported = scopesSupported
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.grantTypesSupported = grantTypesSupported
        self.tokenEndpointAuthMethodsSupported = tokenEndpointAuthMethodsSupported
    }
}

public enum MCPOAuthDiscoveryError: LocalizedError, Sendable {
    case invalidServerURL
    case prmNotFound
    case asmNotFound
    case prmDecodeFailed(String)
    case asmDecodeFailed(String)
    case noAuthorizationServers
    case httpError(Int, String?)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "MCP server URL is not a valid HTTP(S) URL"
        case .prmNotFound:
            return
                "This server doesn't advertise OAuth metadata, so automatic sign-in isn't supported. Try \"Custom Server\" with an API key or personal access token instead."
        case .asmNotFound:
            return "Authorization server does not publish OAuth metadata"
        case .prmDecodeFailed(let msg):
            return "Could not decode protected-resource metadata: \(msg)"
        case .asmDecodeFailed(let msg):
            return "Could not decode authorization-server metadata: \(msg)"
        case .noAuthorizationServers:
            return "Protected-resource metadata listed no authorization servers"
        case .httpError(let code, let body):
            if let body, !body.isEmpty {
                return "OAuth discovery HTTP \(code): \(body)"
            }
            return "OAuth discovery HTTP \(code)"
        case .transport(let msg):
            return "OAuth discovery network error: \(msg)"
        }
    }
}

/// In-memory cache + fetcher for MCP OAuth discovery. Independent of any specific provider.
public actor MCPOAuthDiscovery {
    public static let shared = MCPOAuthDiscovery()

    private var prmCache: [URL: MCPProtectedResourceMetadata] = [:]
    private var asmCache: [URL: MCPAuthorizationServerMetadata] = [:]
    /// Test seam for swapping in a fixture-driven fetcher in unit tests.
    private var fetcher: (URL) async throws -> (Data, HTTPURLResponse) = MCPOAuthDiscovery.defaultFetch

    public init() {}

    // MARK: - Test seam

    /// Replace the underlying network fetcher (call from tests only).
    public func _setFetcher(_ fetcher: @escaping (URL) async throws -> (Data, HTTPURLResponse)) {
        self.fetcher = fetcher
    }

    /// Drop all cached PRM/ASM entries. Useful from tests / manual reconfiguration.
    public func invalidateCache() {
        prmCache.removeAll()
        asmCache.removeAll()
    }

    // MARK: - Public discovery API

    /// Resolve the PRM document URL for a given MCP server, preferring the
    /// `resource_metadata` hint from a `WWW-Authenticate` challenge.
    public static func prmURL(forServer serverURL: URL, hint: URL?) -> URL? {
        if let hint { return hint }
        // RFC 9728 §3.1: place at the well-known path for the resource. We use
        // the server's host (path-scoped probing is allowed but most deployments
        // serve the doc at the root).
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        components?.path = "/.well-known/oauth-protected-resource"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    /// Fetch (and cache) the PRM document for an MCP server.
    public func fetchProtectedResourceMetadata(serverURL: URL, hint: URL?) async throws -> MCPProtectedResourceMetadata
    {
        guard let prmURL = Self.prmURL(forServer: serverURL, hint: hint) else {
            throw MCPOAuthDiscoveryError.invalidServerURL
        }
        if let cached = prmCache[prmURL] {
            return cached
        }

        let (data, response) = try await safeFetch(prmURL)
        guard response.statusCode == 200 else {
            if response.statusCode == 404 {
                throw MCPOAuthDiscoveryError.prmNotFound
            }
            throw MCPOAuthDiscoveryError.httpError(response.statusCode, String(data: data, encoding: .utf8))
        }

        do {
            let metadata = try JSONDecoder().decode(MCPProtectedResourceMetadata.self, from: data)
            guard !metadata.authorizationServers.isEmpty else {
                throw MCPOAuthDiscoveryError.noAuthorizationServers
            }
            prmCache[prmURL] = metadata
            return metadata
        } catch let error as MCPOAuthDiscoveryError {
            throw error
        } catch {
            throw MCPOAuthDiscoveryError.prmDecodeFailed(error.localizedDescription)
        }
    }

    /// Fetch (and cache) ASM for a given authorization-server URL.
    /// Tries RFC 8414 first, falls back to OIDC discovery.
    public func fetchAuthorizationServerMetadata(authServerURL: URL) async throws
        -> MCPAuthorizationServerMetadata
    {
        if let cached = asmCache[authServerURL] {
            return cached
        }

        let candidates = Self.asmCandidateURLs(authServerURL: authServerURL)
        var lastError: Error?

        for candidate in candidates {
            do {
                let (data, response) = try await safeFetch(candidate)
                guard response.statusCode == 200 else {
                    if response.statusCode == 404 {
                        lastError = MCPOAuthDiscoveryError.asmNotFound
                        continue
                    }
                    lastError = MCPOAuthDiscoveryError.httpError(
                        response.statusCode,
                        String(data: data, encoding: .utf8)
                    )
                    continue
                }
                do {
                    let metadata = try JSONDecoder().decode(MCPAuthorizationServerMetadata.self, from: data)
                    asmCache[authServerURL] = metadata
                    return metadata
                } catch {
                    lastError = MCPOAuthDiscoveryError.asmDecodeFailed(error.localizedDescription)
                    continue
                }
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? MCPOAuthDiscoveryError.asmNotFound
    }

    /// Convenience: PRM + first usable ASM in one call.
    public func discover(serverURL: URL, hint: URL?) async throws -> (
        MCPProtectedResourceMetadata, MCPAuthorizationServerMetadata
    ) {
        let prm = try await fetchProtectedResourceMetadata(serverURL: serverURL, hint: hint)
        for raw in prm.authorizationServers {
            guard let url = URL(string: raw) else { continue }
            do {
                let asm = try await fetchAuthorizationServerMetadata(authServerURL: url)
                return (prm, asm)
            } catch {
                continue
            }
        }
        throw MCPOAuthDiscoveryError.asmNotFound
    }

    // MARK: - Internal helpers

    /// Build the ordered list of ASM URLs to try for a given authorization-server URL.
    /// Per RFC 8414 the well-known path is inserted between the host and the issuer's
    /// optional path component. We probe both layouts that real servers use plus the
    /// OIDC discovery path as the final fallback.
    public static func asmCandidateURLs(authServerURL: URL) -> [URL] {
        guard var components = URLComponents(url: authServerURL, resolvingAgainstBaseURL: false) else {
            return []
        }
        components.query = nil
        components.fragment = nil

        let originalPath = components.path
        let trimmedPath = originalPath == "/" ? "" : originalPath

        var candidates: [URL] = []

        // RFC 8414 §3: `/.well-known/oauth-authorization-server` *prefixes* the path.
        components.path = "/.well-known/oauth-authorization-server" + trimmedPath
        if let url = components.url { candidates.append(url) }

        // Some deployments serve at the path-suffixed location instead.
        if !trimmedPath.isEmpty {
            components.path = trimmedPath + "/.well-known/oauth-authorization-server"
            if let url = components.url { candidates.append(url) }
        }

        // OIDC discovery (path-suffixed in OIDC §4 / Connect Discovery 1.0).
        components.path = trimmedPath + "/.well-known/openid-configuration"
        if let url = components.url { candidates.append(url) }
        // OIDC prefix variant — rarer but harmless to include.
        components.path = "/.well-known/openid-configuration" + trimmedPath
        if let url = components.url { candidates.append(url) }

        // De-dupe while preserving order.
        var seen = Set<URL>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func safeFetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await fetcher(url)
        } catch let error as MCPOAuthDiscoveryError {
            throw error
        } catch {
            throw MCPOAuthDiscoveryError.transport(error.localizedDescription)
        }
    }

    private static func defaultFetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPOAuthDiscoveryError.transport("non-HTTP response")
        }
        return (data, http)
    }
}
