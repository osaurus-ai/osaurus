//
//  MCPProviderConfiguration.swift
//  osaurus
//
//  Configuration model for remote MCP providers.
//

import Foundation

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

    private enum CodingKeys: String, CodingKey {
        case id, name, url, enabled, customHeaders
        case streamingEnabled, discoveryTimeout, toolCallTimeout, autoConnect
        case secretHeaderKeys
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
        secretHeaderKeys: [String] = []
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

    public init(providerId: UUID) {
        self.providerId = providerId
        self.isConnected = false
        self.isConnecting = false
        self.lastError = nil
        self.discoveredToolCount = 0
        self.discoveredToolNames = []
        self.lastConnectedAt = nil
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
    static var overrideDirectory: URL?

    public static func load() -> MCPProviderConfiguration {
        let url = configurationFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                return try decoder.decode(MCPProviderConfiguration.self, from: data)
            } catch {
                print("[Osaurus] Failed to load MCPProviderConfiguration: \(error)")
            }
        }
        // Return empty configuration if no file exists
        let defaults = MCPProviderConfiguration()
        save(defaults)
        return defaults
    }

    public static func save(_ configuration: MCPProviderConfiguration) {
        let url = configurationFileURL()
        do {
            try ensureDirectoryExists(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save MCPProviderConfiguration: \(error)")
        }
    }

    // MARK: - Private

    private static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent("MCPProviderConfiguration.json")
        }
        let fm = FileManager.default
        let supportDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "osaurus"
        return supportDir.appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("MCPProviderConfiguration.json")
    }

    private static func ensureDirectoryExists(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
