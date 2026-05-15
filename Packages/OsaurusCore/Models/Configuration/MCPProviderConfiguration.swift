//
//  MCPProviderConfiguration.swift
//  osaurus
//
//  Configuration model for remote MCP providers.
//

import Foundation

// MARK: - MCP Provider Auth

/// Authentication strategy for a remote MCP provider.
public enum MCPProviderAuthType: String, Codable, Sendable, CaseIterable {
    /// No authentication (public/internal server).
    case none
    /// Static bearer token stored in Keychain.
    case bearerToken
    /// OAuth 2.1 with discovery + DCR + PKCE (per MCP authorization spec).
    case oauth
}

/// Per-provider OAuth configuration cached after Dynamic Client Registration / discovery.
///
/// Secrets (access/refresh tokens, registration access token) are stored in Keychain;
/// this struct only carries the metadata the client needs to construct authorize/token
/// requests without re-discovering on every call.
public struct MCPOAuthConfig: Codable, Sendable, Equatable {
    /// `client_id` returned from RFC 7591 Dynamic Client Registration.
    public var clientId: String?
    /// Redirect URI registered with the auth server (loopback `http://127.0.0.1:<port>/callback`).
    public var redirectURI: String?
    /// Scopes resolved from PRM `scopes_supported` / `WWW-Authenticate scope=` hint.
    public var scopes: [String]
    /// Canonical resource URL (RFC 8707) for `resource=` parameter.
    public var resource: String?
    /// Cached authorization-server `issuer` URL.
    public var issuer: String?
    /// Cached authorization endpoint URL.
    public var authorizationEndpoint: String?
    /// Cached token endpoint URL.
    public var tokenEndpoint: String?
    /// Cached registration endpoint URL (for re-registration on `client_id` invalidation).
    public var registrationEndpoint: String?
    /// When the cached metadata was last refreshed.
    public var serverMetadataCachedAt: Date?

    public init(
        clientId: String? = nil,
        redirectURI: String? = nil,
        scopes: [String] = [],
        resource: String? = nil,
        issuer: String? = nil,
        authorizationEndpoint: String? = nil,
        tokenEndpoint: String? = nil,
        registrationEndpoint: String? = nil,
        serverMetadataCachedAt: Date? = nil
    ) {
        self.clientId = clientId
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.resource = resource
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.serverMetadataCachedAt = serverMetadataCachedAt
    }
}

// MARK: - MCP Provider Model

/// Represents a remote MCP server provider configuration
public struct MCPProvider: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var url: String
    public var enabled: Bool
    public var customHeaders: [String: String]

    // Advanced settings
    public var streamingEnabled: Bool
    public var discoveryTimeout: TimeInterval
    public var toolCallTimeout: TimeInterval
    public var autoConnect: Bool

    // Keys for headers that should be stored in Keychain (not persisted in config)
    public var secretHeaderKeys: [String]

    /// Auth strategy. Defaults to `.bearerToken` for backward compatibility with existing
    /// `mcp.json` files that pre-date the auth-type field.
    public var authType: MCPProviderAuthType

    /// OAuth client/server metadata, populated when `authType == .oauth`.
    public var oauth: MCPOAuthConfig?

    /// Optional plugin grouping key. Set when this provider was installed as
    /// part of a plugin import (e.g. a Claude plugin's `.mcp.json` entry).
    /// Used for bulk uninstall.
    public var pluginId: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, url, enabled, customHeaders
        case streamingEnabled, discoveryTimeout, toolCallTimeout, autoConnect
        case secretHeaderKeys
        case authType, oauth
        case pluginId
    }

    public init(
        id: UUID = UUID(),
        name: String,
        url: String,
        enabled: Bool = true,
        customHeaders: [String: String] = [:],
        streamingEnabled: Bool = false,
        discoveryTimeout: TimeInterval = 20,
        toolCallTimeout: TimeInterval = 45,
        autoConnect: Bool = true,
        secretHeaderKeys: [String] = [],
        authType: MCPProviderAuthType = .bearerToken,
        oauth: MCPOAuthConfig? = nil,
        pluginId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
        self.customHeaders = customHeaders
        self.streamingEnabled = streamingEnabled
        self.discoveryTimeout = discoveryTimeout
        self.toolCallTimeout = toolCallTimeout
        self.autoConnect = autoConnect
        self.secretHeaderKeys = secretHeaderKeys
        self.authType = authType
        self.oauth = oauth
        self.pluginId = pluginId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.url = try container.decode(String.self, forKey: .url)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.customHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        self.streamingEnabled = try container.decodeIfPresent(Bool.self, forKey: .streamingEnabled) ?? false
        self.discoveryTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .discoveryTimeout) ?? 20
        self.toolCallTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .toolCallTimeout) ?? 45
        self.autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        self.secretHeaderKeys = try container.decodeIfPresent([String].self, forKey: .secretHeaderKeys) ?? []
        // Migration: legacy configs default to .bearerToken so the existing token-from-Keychain path works.
        self.authType = try container.decodeIfPresent(MCPProviderAuthType.self, forKey: .authType) ?? .bearerToken
        self.oauth = try container.decodeIfPresent(MCPOAuthConfig.self, forKey: .oauth)
        self.pluginId = try container.decodeIfPresent(String.self, forKey: .pluginId)
    }

    /// Get all headers including secret headers from Keychain
    public func resolvedHeaders() -> [String: String] {
        var headers = customHeaders

        // Add secret headers from Keychain
        for key in secretHeaderKeys {
            if let value = MCPProviderKeychain.getHeaderSecret(key: key, for: id) {
                headers[key] = value
            }
        }

        return headers
    }

    /// Check if provider has a token stored in Keychain
    public var hasToken: Bool {
        MCPProviderKeychain.hasToken(for: id)
    }

    /// Get token from Keychain
    public func getToken() -> String? {
        MCPProviderKeychain.getToken(for: id)
    }

    /// True if OAuth is configured AND tokens are present in Keychain.
    public var hasOAuthTokens: Bool {
        authType == .oauth && MCPProviderKeychain.hasOAuthTokens(for: id)
    }

    /// Read OAuth tokens from Keychain (or nil).
    public func getOAuthTokens() -> MCPOAuthTokens? {
        guard authType == .oauth else { return nil }
        return MCPProviderKeychain.getOAuthTokens(for: id)
    }
}

// MARK: - MCP Provider Runtime State

/// Runtime state for a connected provider (not persisted)
public struct MCPProviderState: Sendable {
    public let providerId: UUID
    public var isConnected: Bool
    public var isConnecting: Bool
    public var lastError: String?
    public var discoveredToolCount: Int
    public var discoveredToolNames: [String]
    public var lastConnectedAt: Date?
    /// Set when a connection attempt yielded `401 Unauthorized` and the server advertised
    /// OAuth via `WWW-Authenticate`. UI uses this to surface a "Sign in" CTA.
    public var requiresAuth: Bool
    /// Optional `resource_metadata` URL parsed out of `WWW-Authenticate`. When present
    /// the OAuth service can skip path-scoped `.well-known` discovery.
    public var resourceMetadataURL: URL?

    public init(providerId: UUID) {
        self.providerId = providerId
        self.isConnected = false
        self.isConnecting = false
        self.lastError = nil
        self.discoveredToolCount = 0
        self.discoveredToolNames = []
        self.lastConnectedAt = nil
        self.requiresAuth = false
        self.resourceMetadataURL = nil
    }
}

// MARK: - MCP Provider Configuration

/// Collection of MCP providers configuration
public struct MCPProviderConfiguration: Codable, Sendable {
    public var providers: [MCPProvider]

    public init(providers: [MCPProvider] = []) {
        self.providers = providers
    }

    /// Get provider by ID
    public func provider(id: UUID) -> MCPProvider? {
        providers.first { $0.id == id }
    }

    /// Get enabled providers
    public var enabledProviders: [MCPProvider] {
        providers.filter { $0.enabled }
    }

    /// Get providers that should auto-connect
    public var autoConnectProviders: [MCPProvider] {
        providers.filter { $0.enabled && $0.autoConnect }
    }

    /// Add a provider
    public mutating func add(_ provider: MCPProvider) {
        providers.append(provider)
    }

    /// Update a provider
    public mutating func update(_ provider: MCPProvider) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        }
    }

    /// Remove a provider by ID
    public mutating func remove(id: UUID) {
        // Clean up Keychain secrets
        MCPProviderKeychain.deleteAllSecrets(for: id)
        providers.removeAll { $0.id == id }
    }

    /// Set enabled state for a provider
    public mutating func setEnabled(_ enabled: Bool, for id: UUID) {
        if let index = providers.firstIndex(where: { $0.id == id }) {
            providers[index].enabled = enabled
        }
    }
}

// MARK: - MCP Provider Configuration Store

/// Persistence for MCPProviderConfiguration
@MainActor
public enum MCPProviderConfigurationStore {
    public static func load() -> MCPProviderConfiguration {
        let url = configurationFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                return try JSONDecoder().decode(MCPProviderConfiguration.self, from: Data(contentsOf: url))
            } catch {
                print("[Osaurus] Failed to load MCPProviderConfiguration: \(error)")
            }
        }
        // CRITICAL: see RemoteProviderConfigurationStore.load — never
        // auto-save an empty default. Doing so used to race the
        // v1→v2 storage migrator and silently destroyed the user's
        // real provider list when the .osec twin was discarded.
        return MCPProviderConfiguration()
    }

    public static func save(_ configuration: MCPProviderConfiguration) {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save MCPProviderConfiguration: \(error)")
        }
    }

    private static func configurationFileURL() -> URL {
        OsaurusPaths.resolvePath(new: OsaurusPaths.mcpProviderConfigFile(), legacy: "MCPProviderConfiguration.json")
    }
}
