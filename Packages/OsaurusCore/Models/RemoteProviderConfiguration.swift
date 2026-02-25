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
    case http = "http"
    case https = "https"

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
    case none = "none"
    case apiKey = "apiKey"
}

// MARK: - Provider Type

/// Type of remote provider (determines API format)
public enum RemoteProviderType: String, Codable, Sendable, CaseIterable {
    case openai = "openai"  // OpenAI-compatible API (default)
    case anthropic = "anthropic"  // Anthropic Messages API
    case openResponses = "openResponses"  // Open Responses API
    case gemini = "gemini"  // Google Gemini API

    public var displayName: String {
        switch self {
        case .openai: return "OpenAI Compatible"
        case .anthropic: return "Anthropic"
        case .openResponses: return "Open Responses"
        case .gemini: return "Google Gemini"
        }
    }

    public var chatEndpoint: String {
        switch self {
        case .openai: return "/chat/completions"
        case .anthropic: return "/messages"
        case .openResponses: return "/responses"
        case .gemini: return "/models"  // Actual URL is built dynamically: /models/{model}:generateContent
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

    // Keys for headers that should be stored in Keychain (not persisted in config)
    public var secretHeaderKeys: [String]

    private enum CodingKeys: String, CodingKey {
        case id, name, host, providerProtocol, port, basePath
        case customHeaders, authType, providerType, enabled, autoConnect, timeout
        case secretHeaderKeys
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
        providerType: RemoteProviderType = .openai,
        enabled: Bool = true,
        autoConnect: Bool = true,
        timeout: TimeInterval = 60,
        secretHeaderKeys: [String] = []
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
        self.secretHeaderKeys = secretHeaderKeys
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
        providerType = try container.decodeIfPresent(RemoteProviderType.self, forKey: .providerType) ?? .openai
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        autoConnect = try container.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 60
        secretHeaderKeys = try container.decodeIfPresent([String].self, forKey: .secretHeaderKeys) ?? []
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
                headers["x-api-key"] = apiKey
                // Add required Anthropic version header if not already set
                if headers["anthropic-version"] == nil {
                    headers["anthropic-version"] = "2023-06-01"
                }
            case .gemini:
                headers["x-goog-api-key"] = apiKey
            case .openai, .openResponses:
                headers["Authorization"] = "Bearer \(apiKey)"
            }
        }

        return headers
    }

    /// Check if provider has an API key stored in Keychain
    public var hasAPIKey: Bool {
        RemoteProviderKeychain.hasAPIKey(for: id)
    }

    /// Get API key from Keychain
    public func getAPIKey() -> String? {
        RemoteProviderKeychain.getAPIKey(for: id)
    }
}

// MARK: - Remote Provider Runtime State

/// Runtime state for a connected remote provider (not persisted)
public struct RemoteProviderState: Sendable {
    public let providerId: UUID
    public var isConnected: Bool
    public var isConnecting: Bool
    public var lastError: String?
    public var discoveredModels: [String]
    public var lastConnectedAt: Date?

    public init(providerId: UUID) {
        self.providerId = providerId
        self.isConnected = false
        self.isConnecting = false
        self.lastError = nil
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
}

// MARK: - Remote Provider Configuration Store

/// Persistence for RemoteProviderConfiguration
@MainActor
public enum RemoteProviderConfigurationStore {
    public static func load() -> RemoteProviderConfiguration {
        let url = configurationFileURL()

        guard FileManager.default.fileExists(atPath: url.path) else {
            // File doesn't exist yet – create an empty default.
            let defaults = RemoteProviderConfiguration()
            save(defaults)
            return defaults
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
