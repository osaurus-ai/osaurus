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

// MARK: - Remote Provider Model

/// Represents a remote OpenAI-compatible API provider configuration
public struct RemoteProvider: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var host: String
    public var providerProtocol: RemoteProviderProtocol
    public var port: Int?
    public var basePath: String
    public var customHeaders: [String: String]
    public var authType: RemoteProviderAuthType
    public var enabled: Bool
    public var autoConnect: Bool
    public var timeout: TimeInterval

    // Keys for headers that should be stored in Keychain (not persisted in config)
    public var secretHeaderKeys: [String]

    private enum CodingKeys: String, CodingKey {
        case id, name, host, providerProtocol, port, basePath
        case customHeaders, authType, enabled, autoConnect, timeout
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
        self.enabled = enabled
        self.autoConnect = autoConnect
        self.timeout = timeout
        self.secretHeaderKeys = secretHeaderKeys
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

        // Add API key if configured
        if authType == .apiKey, let apiKey = getAPIKey(), !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
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
    static var overrideDirectory: URL?

    public static func load() -> RemoteProviderConfiguration {
        let url = configurationFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                return try decoder.decode(RemoteProviderConfiguration.self, from: data)
            } catch {
                print("[Osaurus] Failed to load RemoteProviderConfiguration: \(error)")
            }
        }
        // Return empty configuration if no file exists
        let defaults = RemoteProviderConfiguration()
        save(defaults)
        return defaults
    }

    public static func save(_ configuration: RemoteProviderConfiguration) {
        let url = configurationFileURL()
        do {
            try ensureDirectoryExists(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save RemoteProviderConfiguration: \(error)")
        }
    }

    // MARK: - Private

    private static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent("RemoteProviderConfiguration.json")
        }
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        return supportDir.appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("RemoteProviderConfiguration.json")
    }

    private static func ensureDirectoryExists(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
