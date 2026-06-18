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
    case unsafeDiscoveredURL(String)
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
        case .unsafeDiscoveredURL(let url):
            return "OAuth metadata pointed at an unsafe URL: \(url)"
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
    private var fetcher: @Sendable (URL) async throws -> (Data, HTTPURLResponse) = MCPOAuthDiscovery.defaultFetch

    public init() {}

    // MARK: - Test seam

    /// Replace the underlying network fetcher (call from tests only).
    public func _setFetcher(_ fetcher: @escaping @Sendable (URL) async throws -> (Data, HTTPURLResponse)) {
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
    ///
    /// Returns the first candidate from `prmCandidateURLs` — primarily a
    /// convenience for callers that just need a single URL (and for tests).
    /// Real fetching uses the full candidate list.
    public static func prmURL(forServer serverURL: URL, hint: URL?) -> URL? {
        prmCandidateURLs(forServer: serverURL, hint: hint).first
    }

    /// Ordered list of PRM URLs to probe for a given MCP server.
    ///
    /// - If `hint` (the `resource_metadata=` URL from a `WWW-Authenticate`
    ///   challenge) is present and passes the discovery URL policy, it is the
    ///   sole candidate — RFC 9728 §5.1 makes that the canonical pointer.
    /// - Otherwise we probe both well-known layouts described by RFC 9728 §3.1:
    ///     1. Path-scoped: `<host>/.well-known/oauth-protected-resource<path>`
    ///        (the spec-canonical form for resources with a path).
    ///     2. Root: `<host>/.well-known/oauth-protected-resource`
    ///        (what most single-tenant deployments serve).
    ///   For a path-less server URL the two collapse to a single entry after
    ///   de-dup.
    public static func prmCandidateURLs(forServer serverURL: URL, hint: URL?) -> [URL] {
        if let hint {
            return MCPOAuthURLPolicy.allowsDiscoveredURL(hint, from: serverURL) ? [hint] : []
        }
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return []
        }
        components.query = nil
        components.fragment = nil

        let originalPath = components.path
        let trimmedPath = originalPath == "/" ? "" : originalPath

        var candidates: [URL] = []

        // RFC 9728 §3.1 canonical form: well-known prefixes the resource path.
        components.path = "/.well-known/oauth-protected-resource" + trimmedPath
        if let url = components.url { candidates.append(url) }

        // Common deployment shortcut: root-scoped well-known.
        if !trimmedPath.isEmpty {
            components.path = "/.well-known/oauth-protected-resource"
            if let url = components.url { candidates.append(url) }
        }

        var seen = Set<URL>()
        let uniqueCandidates = candidates.filter { seen.insert($0).inserted }
        return uniqueCandidates.filter {
            MCPOAuthURLPolicy.allowsDiscoveredURL($0, from: serverURL)
        }
    }

    /// Fetch (and cache) the PRM document for an MCP server.
    public func fetchProtectedResourceMetadata(
        serverURL: URL,
        hint: URL?
    ) async throws -> MCPProtectedResourceMetadata {
        let candidates = Self.prmCandidateURLs(forServer: serverURL, hint: hint)
        guard !candidates.isEmpty else {
            throw MCPOAuthDiscoveryError.invalidServerURL
        }
        for candidate in candidates {
            if let cached = prmCache[candidate] {
                return cached
            }
        }

        var lastError: MCPOAuthDiscoveryError?
        for candidate in candidates {
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await safeFetch(candidate)
            } catch let error as MCPOAuthDiscoveryError {
                lastError = error
                continue
            }

            guard response.statusCode == 200 else {
                if response.statusCode == 404 {
                    lastError = .prmNotFound
                    continue
                }
                lastError = .httpError(response.statusCode, String(data: data, encoding: .utf8))
                continue
            }

            do {
                let metadata = try JSONDecoder().decode(MCPProtectedResourceMetadata.self, from: data)
                guard !metadata.authorizationServers.isEmpty else {
                    throw MCPOAuthDiscoveryError.noAuthorizationServers
                }
                prmCache[candidate] = metadata
                return metadata
            } catch let error as MCPOAuthDiscoveryError {
                lastError = error
                continue
            } catch {
                lastError = .prmDecodeFailed(error.localizedDescription)
                continue
            }
        }

        throw lastError ?? .prmNotFound
    }

    /// Fetch (and cache) ASM for a given authorization-server URL.
    /// Tries RFC 8414 first, falls back to OIDC discovery.
    public func fetchAuthorizationServerMetadata(
        authServerURL: URL,
        resourceServerURL: URL? = nil
    ) async throws -> MCPAuthorizationServerMetadata {
        guard MCPOAuthURLPolicy.allowsDiscoveredURL(authServerURL, from: resourceServerURL ?? authServerURL) else {
            throw MCPOAuthDiscoveryError.unsafeDiscoveredURL(authServerURL.absoluteString)
        }
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
                    try Self.validateAuthorizationServerMetadata(
                        metadata,
                        origin: resourceServerURL ?? authServerURL
                    )
                    asmCache[authServerURL] = metadata
                    return metadata
                } catch {
                    if let discoveryError = error as? MCPOAuthDiscoveryError {
                        lastError = discoveryError
                    } else {
                        lastError = MCPOAuthDiscoveryError.asmDecodeFailed(error.localizedDescription)
                    }
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
            guard MCPOAuthURLPolicy.allowsDiscoveredURL(url, from: serverURL) else { continue }
            do {
                let asm = try await fetchAuthorizationServerMetadata(authServerURL: url, resourceServerURL: serverURL)
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

    static func validateAuthorizationServerMetadata(
        _ metadata: MCPAuthorizationServerMetadata,
        origin: URL
    ) throws {
        let required = [metadata.issuer, metadata.authorizationEndpoint, metadata.tokenEndpoint]
        for raw in required {
            guard
                let url = URL(string: raw),
                MCPOAuthURLPolicy.allowsDiscoveredURL(url, from: origin)
            else {
                throw MCPOAuthDiscoveryError.unsafeDiscoveredURL(raw)
            }
        }
        if let raw = metadata.registrationEndpoint {
            guard
                let url = URL(string: raw),
                MCPOAuthURLPolicy.allowsDiscoveredURL(url, from: origin)
            else {
                throw MCPOAuthDiscoveryError.unsafeDiscoveredURL(raw)
            }
        }
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
        let (data, response) = try await MCPOAuthHTTPTransport.noRedirectSession().data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPOAuthDiscoveryError.transport("non-HTTP response")
        }
        return (data, http)
    }
}
