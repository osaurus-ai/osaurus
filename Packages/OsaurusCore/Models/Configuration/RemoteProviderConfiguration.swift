//
//  RemoteProviderConfiguration.swift
//  osaurus
//
//  Configuration model for remote OpenAI-compatible API providers.
//

import Foundation

// MARK: - Protocol Enum

/// Protocol type for remote provider connections
public enum RemoteProviderProtocol: String, Codable, Sendable, CaseIterable {
    case http
    case https

    public var defaultPort: Int {
        switch self {
        case .http: return 80
        case .https: return 443
        }
    }
}

// MARK: - Authentication Type

/// Authentication type for remote providers
public enum RemoteProviderAuthType: String, Codable, Sendable, CaseIterable {
    case none
    case apiKey
    case openAICodexOAuth
    case xaiOAuth
}

enum RemoteProviderHeaderRedactor {
    static let redactedValue = "***"

    private static let exactSensitiveHeaderNames: Set<String> = [
        "authorization",
        "api-key",
        "cookie",
        "proxy-authorization",
        "set-cookie",
        "x-api-key",
        "x-goog-api-key",
    ]

    private static let likelySensitiveNameFragments = [
        "token",
        "secret",
        "password",
        "passwd",
        "key",
    ]

    /// Custom provider headers are user-defined, so log redaction treats likely credential names as sensitive.
    static func isSensitiveHeader(_ name: String, configuredSecretHeaderKeys: [String] = []) -> Bool {
        let normalizedName = normalize(name)
        guard !normalizedName.isEmpty else { return false }

        if exactSensitiveHeaderNames.contains(normalizedName) {
            return true
        }

        if configuredSecretHeaderKeys.contains(where: { normalize($0) == normalizedName }) {
            return true
        }

        return likelySensitiveNameFragments.contains { normalizedName.contains($0) }
    }

    static func valueForLogging(
        headerName: String,
        value: String,
        configuredSecretHeaderKeys: [String] = []
    ) -> String {
        isSensitiveHeader(headerName, configuredSecretHeaderKeys: configuredSecretHeaderKeys)
            ? redactedValue
            : value
    }

    static func redactedHeaders(
        _ headers: [String: String],
        configuredSecretHeaderKeys: [String] = []
    ) -> [String: String] {
        var redacted = headers
        for (name, value) in headers {
            redacted[name] = valueForLogging(
                headerName: name,
                value: value,
                configuredSecretHeaderKeys: configuredSecretHeaderKeys
            )
        }
        return redacted
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Provider Type

/// Type of remote provider (determines API format)
public enum RemoteProviderType: String, Codable, Sendable, CaseIterable {
    case openaiLegacy = "openai"  // OpenAI-compatible /chat/completions (third-party servers, backward compat)
    case azureOpenAI = "azureOpenAI"  // Azure OpenAI Foundry /openai/v1 OpenAI-compatible chat completions
    case anthropic = "anthropic"  // Anthropic Messages API
    case openResponses = "openResponses"  // Open Responses API — used for official OpenAI and any compatible provider
    case openAICodex = "openAICodex"  // ChatGPT/Codex OAuth backend
    case gemini = "gemini"  // Google Gemini API
    case osaurus = "osaurus"  // Native Osaurus agent — full server-side execution via /agents/{id}/run
    case osaurusRouter = "osaurusRouter"  // Hosted Osaurus Router — identity-signed billed inference

    public var displayName: String {
        switch self {
        case .openaiLegacy: return L("OpenAI Compatible")
        case .azureOpenAI: return L("Azure OpenAI Foundry")
        case .anthropic: return L("Anthropic")
        case .openResponses: return L("Open Responses")
        case .openAICodex: return L("OpenAI Codex")
        case .gemini: return L("Google Gemini")
        case .osaurus: return L("Osaurus Agent")
        case .osaurusRouter: return L("Osaurus")
        }
    }

    public var chatEndpoint: String {
        switch self {
        case .openaiLegacy, .azureOpenAI: return "/chat/completions"
        case .anthropic: return "/messages"
        case .openResponses: return "/responses"
        case .openAICodex: return "/codex/responses"
        case .gemini: return "/models"  // Actual URL is built dynamically: /models/{model}:generateContent
        case .osaurus: return "/run"  // Unused — full URL built by RemoteProviderService.buildURLRequest
        case .osaurusRouter: return "/v1/chat/completions"
        }
    }

    public var modelsEndpoint: String {
        // Both use /models but response format differs
        return "/models"
    }
}

// MARK: - Remote Provider Model

/// Represents a remote API provider configuration
public struct RemoteProvider: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var host: String
    public var providerProtocol: RemoteProviderProtocol
    public var port: Int?
    public var basePath: String
    public var customHeaders: [String: String]
    public var authType: RemoteProviderAuthType
    public var providerType: RemoteProviderType
    public var enabled: Bool
    public var autoConnect: Bool
    public var timeout: TimeInterval
    /// When true, requests run effectively unbounded — the request, resource, and
    /// stream inactivity limits are all lifted. Intended for trusted long-running
    /// workloads  where time doesn't matter.
    /// Discovery/probe timeouts are deliberately unaffected and stay short.
    public var disableTimeout: Bool
    public var manualModelIds: [String]

    /// Sentinel applied at runtime when `disableTimeout` is set. Finite by design:
    /// `.infinity` / `.greatestFiniteMagnitude` would crash the streaming path
    /// (`UInt64(timeout * 1e9)` overflows) and can't be JSON encoded. One year is
    /// no limit for any real request while staying safely within those bounds.
    public static let unboundedTimeout: TimeInterval = 60 * 60 * 24 * 365

    // Keys for headers that should be stored in Keychain (not persisted in config)
    public var secretHeaderKeys: [String]

    /// The UUID of the agent on the remote Osaurus server. Only used when providerType == .osaurus.
    public var remoteAgentId: UUID?

    /// The crypto address (e.g. "0x...") of the remote agent, used to build relay tunnel URLs.
    /// Only used when providerType == .osaurus.
    public var remoteAgentAddress: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, host, providerProtocol, port, basePath
        case customHeaders, authType, providerType, enabled, autoConnect, timeout, disableTimeout
        case manualModelIds
        case secretHeaderKeys, remoteAgentId, remoteAgentAddress
    }

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        providerProtocol: RemoteProviderProtocol = .https,
        port: Int? = nil,
        basePath: String = "/v1",
        customHeaders: [String: String] = [:],
        authType: RemoteProviderAuthType = .none,
        providerType: RemoteProviderType = .openaiLegacy,
        enabled: Bool = true,
        autoConnect: Bool = true,
        timeout: TimeInterval = 60,
        disableTimeout: Bool = false,
        manualModelIds: [String] = [],
        secretHeaderKeys: [String] = [],
        remoteAgentId: UUID? = nil,
        remoteAgentAddress: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.providerProtocol = providerProtocol
        self.port = port
        self.basePath = basePath
        self.customHeaders = customHeaders
        self.authType = authType
        self.providerType = providerType
        self.enabled = enabled
        self.autoConnect = autoConnect
        self.timeout = timeout
        self.disableTimeout = disableTimeout
        self.manualModelIds = manualModelIds
        self.secretHeaderKeys = secretHeaderKeys
        self.remoteAgentId = remoteAgentId
        self.remoteAgentAddress = remoteAgentAddress
    }

    /// Custom decoder – uses `decodeIfPresent` for backward compatibility with older config files.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        providerProtocol =
            try container.decodeIfPresent(RemoteProviderProtocol.self, forKey: .providerProtocol) ?? .https
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        basePath = try container.decodeIfPresent(String.self, forKey: .basePath) ?? "/v1"
        customHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        authType = try container.decodeIfPresent(RemoteProviderAuthType.self, forKey: .authType) ?? .none
        providerType =
            try container.decodeIfPresent(RemoteProviderType.self, forKey: .providerType) ?? .openaiLegacy
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 60
        disableTimeout = try container.decodeIfPresent(Bool.self, forKey: .disableTimeout) ?? false
        manualModelIds = try container.decodeIfPresent([String].self, forKey: .manualModelIds) ?? []
        secretHeaderKeys = try container.decodeIfPresent([String].self, forKey: .secretHeaderKeys) ?? []
        remoteAgentId = try container.decodeIfPresent(UUID.self, forKey: .remoteAgentId)
        remoteAgentAddress = try container.decodeIfPresent(String.self, forKey: .remoteAgentAddress)
    }

    /// Get the effective port (uses protocol default if not specified)
    public var effectivePort: Int {
        port ?? providerProtocol.defaultPort
    }

    /// Build the base URL for this provider
    public var baseURL: URL? {
        var components = URLComponents()
        components.scheme = providerProtocol.rawValue

        // Parse host - it might contain a path component (e.g., "host/api")
        var actualHost = host.trimmingCharacters(in: .whitespaces)
        var hostPath = ""

        // Check if host contains a path (indicated by a slash after the hostname)
        if let slashIndex = actualHost.firstIndex(of: "/") {
            hostPath = String(actualHost[slashIndex...])  // e.g., "/api"
            actualHost = String(actualHost[..<slashIndex])  // e.g., "host"
        }

        // Check if host contains a port (e.g., "localhost:8080")
        if let colonIndex = actualHost.lastIndex(of: ":"),
            let portValue = Int(String(actualHost[actualHost.index(after: colonIndex)...]))
        {
            // Extract port from host if not already set
            if port == nil {
                components.port = portValue
            }
            actualHost = String(actualHost[..<colonIndex])
        }

        components.host = actualHost

        // Only include port if it differs from the protocol default
        if let port = port, port != providerProtocol.defaultPort {
            components.port = port
        }

        // Combine any path from host with basePath
        var normalizedPath = hostPath + basePath.trimmingCharacters(in: .whitespaces)
        if !normalizedPath.hasPrefix("/") {
            normalizedPath = "/" + normalizedPath
        }
        if normalizedPath.hasSuffix("/") {
            normalizedPath = String(normalizedPath.dropLast())
        }
        // Normalize double slashes (e.g., "/api//v1" -> "/api/v1")
        while normalizedPath.contains("//") {
            normalizedPath = normalizedPath.replacingOccurrences(of: "//", with: "/")
        }
        components.path = normalizedPath

        return components.url
    }

    /// Build URL for a specific endpoint
    public func url(for endpoint: String) -> URL? {
        guard let base = baseURL else { return nil }
        let normalizedEndpoint = endpoint.hasPrefix("/") ? endpoint : "/" + endpoint
        return URL(string: base.absoluteString + normalizedEndpoint)
    }

    /// Display string for the endpoint
    public var displayEndpoint: String {
        // Use the baseURL to get the properly constructed endpoint
        if let url = baseURL {
            return url.absoluteString
        }
        // Fallback to manual construction
        var result = "\(providerProtocol.rawValue)://\(host)"
        if let port = port, port != providerProtocol.defaultPort {
            result += ":\(port)"
        }
        result += basePath
        return result
    }

    /// Get all headers including secret headers from Keychain
    public func resolvedHeaders() -> [String: String] {
        var headers = customHeaders

        // Add secret headers from Keychain
        for key in secretHeaderKeys {
            if let value = RemoteProviderKeychain.getHeaderSecret(key: key, for: id) {
                headers[key] = value
            }
        }

        // Add API key if configured (format differs by provider type)
        if authType == .apiKey, let apiKey = getAPIKey(), !apiKey.isEmpty {
            switch providerType {
            case .anthropic:
                if headers["x-api-key"] == nil {
                    headers["x-api-key"] = apiKey
                }
                // Add required Anthropic version header if not already set
                if headers["anthropic-version"] == nil {
                    headers["anthropic-version"] = "2023-06-01"
                }
            case .gemini:
                if headers["x-goog-api-key"] == nil {
                    headers["x-goog-api-key"] = apiKey
                }
            case .azureOpenAI:
                if headers["api-key"] == nil {
                    headers["api-key"] = apiKey
                }
            case .openaiLegacy, .openResponses, .openAICodex, .osaurus, .osaurusRouter:
                if headers["Authorization"] == nil {
                    headers["Authorization"] = "Bearer \(apiKey)"
                }
            }
        }

        // xAI (Grok) OAuth: inject the access token as a Bearer credential so
        // the generic OpenAI-compatible path (model discovery, etc.) authorizes
        // correctly. Per-request refresh happens in `RemoteProviderService`;
        // the connect path refreshes before headers are resolved here.
        if authType == .xaiOAuth, headers["Authorization"] == nil,
            let tokens = getOAuthTokens(), !tokens.accessToken.isEmpty
        {
            headers["Authorization"] = "Bearer \(tokens.accessToken)"
        }

        // OpenRouter app attribution: surfaces Osaurus on openrouter.ai/rankings.
        // Constants live on `OpenRouterOAuthService.Attribution` so the OAuth
        // app row and these per-request headers can't drift. nil-checks let
        // user-supplied customHeaders win.
        if host.lowercased().trimmingCharacters(in: .whitespaces)
            == OpenRouterOAuthService.Attribution.host
        {
            let attribution = OpenRouterOAuthService.Attribution.self
            if headers[attribution.refererHeader] == nil {
                headers[attribution.refererHeader] = attribution.referrerURL
            }
            if headers[attribution.titleHeader] == nil {
                headers[attribution.titleHeader] = attribution.appTitle
            }
        }

        return headers
    }

    /// Resolve Keychain-backed headers away from the main actor.
    public func resolvedHeadersOffMainActor() async -> [String: String] {
        await RemoteProviderKeychain.runOffCooperativeExecutor {
            self.resolvedHeaders()
        }
    }

    /// Check if provider has an API key stored in Keychain
    public var hasAPIKey: Bool {
        RemoteProviderKeychain.hasAPIKey(for: id)
    }

    public var hasOAuthTokens: Bool {
        RemoteProviderKeychain.hasOAuthTokens(for: id)
    }

    /// Get API key from Keychain
    public func getAPIKey() -> String? {
        RemoteProviderKeychain.getAPIKey(for: id)
    }

    public func getOAuthTokens() -> RemoteProviderOAuthTokens? {
        RemoteProviderKeychain.getOAuthTokens(for: id)
    }

    /// Resolve OAuth tokens away from the main actor.
    public func getOAuthTokensOffMainActor() async -> RemoteProviderOAuthTokens? {
        await RemoteProviderKeychain.runOffCooperativeExecutor {
            self.getOAuthTokens()
        }
    }

    public func mergedModelIds(discovered: [String]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        let sourceModels = providerType == .azureOpenAI ? manualModelIds : discovered + manualModelIds

        for rawValue in sourceModels {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            let key = value.lowercased()
            guard !seen.contains(key) else { continue }

            seen.insert(key)
            merged.append(value)
        }

        return merged
    }
}

// MARK: - Remote Provider Runtime State

/// Runtime state for a connected remote provider (not persisted)
public struct RemoteProviderState: Sendable {
    public let providerId: UUID
    public var isConnected: Bool
    public var isConnecting: Bool
    public var lastError: String?
    public var lastReplayDiagnostics: ProviderReplayDiagnosticBundle?
    public var discoveredModels: [String]
    public var lastConnectedAt: Date?

    public init(providerId: UUID) {
        self.providerId = providerId
        self.isConnected = false
        self.isConnecting = false
        self.lastError = nil
        self.lastReplayDiagnostics = nil
        self.discoveredModels = []
        self.lastConnectedAt = nil
    }

    public var modelCount: Int {
        discoveredModels.count
    }
}

// MARK: - Remote Provider Configuration

/// Collection of remote provider configurations
public struct RemoteProviderConfiguration: Codable, Sendable {
    public var providers: [RemoteProvider]

    public init(providers: [RemoteProvider] = []) {
        self.providers = providers
    }

    /// Get provider by ID
    public func provider(id: UUID) -> RemoteProvider? {
        providers.first { $0.id == id }
    }

    /// Get enabled providers
    public var enabledProviders: [RemoteProvider] {
        providers.filter { $0.enabled }
    }

    /// Get providers that should auto-connect
    public var autoConnectProviders: [RemoteProvider] {
        providers.filter { $0.enabled && $0.autoConnect }
    }

    /// Add a provider
    public mutating func add(_ provider: RemoteProvider) {
        providers.append(provider)
    }

    /// Update a provider
    public mutating func update(_ provider: RemoteProvider) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        }
    }

    /// Remove a provider by ID
    public mutating func remove(id: UUID) {
        // Clean up Keychain secrets
        RemoteProviderKeychain.deleteAllSecrets(for: id)
        providers.removeAll { $0.id == id }
    }

    /// Set enabled state for a provider
    public mutating func setEnabled(_ enabled: Bool, for id: UUID) {
        if let index = providers.firstIndex(where: { $0.id == id }) {
            providers[index].enabled = enabled
        }
    }

    /// Reorder `providers` to match the sequence of `orderedIds`. Unknown and
    /// duplicate IDs are ignored; any providers omitted from `orderedIds` keep
    /// their current relative position after the requested ones, so a partial
    /// list never drops providers.
    public mutating func reorder(orderedIds: [UUID]) {
        var byId: [UUID: RemoteProvider] = [:]
        for provider in providers where byId[provider.id] == nil {
            byId[provider.id] = provider
        }
        var seen = Set<UUID>()
        var reordered: [RemoteProvider] = []
        for id in orderedIds {
            guard let provider = byId[id], seen.insert(id).inserted else { continue }
            reordered.append(provider)
        }
        for provider in providers where seen.insert(provider.id).inserted {
            reordered.append(provider)
        }
        providers = reordered
    }
}

// MARK: - Remote Provider Configuration Store

/// Persistence for RemoteProviderConfiguration
@MainActor
public enum RemoteProviderConfigurationStore {
    public static func load() -> RemoteProviderConfiguration {
        let url = configurationFileURL()

        // CRITICAL: do NOT auto-save an empty default when the file
        // is missing. The 2026-04 storage-migration race showed this
        // pattern silently destroys provider data: the migrator's
        // v1→v2 recovery would later see an empty plaintext file
        // already on disk, treat it as authoritative, and discard
        // the encrypted twin holding the real configuration. By
        // returning defaults in-memory only, the file stays absent
        // until something explicitly saves it (a real user edit).
        guard FileManager.default.fileExists(atPath: url.path) else {
            return RemoteProviderConfiguration()
        }

        do {
            return try JSONDecoder().decode(RemoteProviderConfiguration.self, from: Data(contentsOf: url))
        } catch {
            // Return empty in-memory config but never overwrite the existing file;
            // that would permanently destroy the user's providers.
            print("[Osaurus] Failed to load RemoteProviderConfiguration: \(error)")
            return RemoteProviderConfiguration()
        }
    }

    public static func save(_ configuration: RemoteProviderConfiguration) {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save RemoteProviderConfiguration: \(error)")
        }
    }

    private static func configurationFileURL() -> URL {
        OsaurusPaths.resolvePath(
            new: OsaurusPaths.remoteProviderConfigFile(),
            legacy: "RemoteProviderConfiguration.json"
        )
    }
}
