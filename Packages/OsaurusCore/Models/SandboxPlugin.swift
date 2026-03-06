//
//  SandboxPlugin.swift
//  osaurus
//
//  JSON recipe format for sandbox plugins that run inside an agent's Linux VM.
//  Plugins declare dependencies, setup commands, tools, MCP servers, and secrets.
//

import Foundation

public struct SandboxPlugin: Codable, Identifiable, Sendable, Equatable {
    public var id: String { normalizedName }
    public let name: String
    public let description: String
    public var version: String?
    public var author: String?
    public var source: String?

    public var dependencies: [String]?
    public var setup: String?
    public var files: [String: String]?
    public var tools: [SandboxToolSpec]?
    public var mcp: MCPSpec?
    public var daemon: String?
    public var secrets: [String]?
    public var permissions: PermissionsSpec?

    /// Lowercased, hyphenated name used as the project folder name.
    public var normalizedName: String {
        let filtered = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return filtered.isEmpty ? "unnamed-plugin" : filtered
    }
}

// MARK: - Tool Spec

public struct SandboxToolSpec: Codable, Sendable, Equatable {
    public let id: String
    public let description: String
    public var parameters: [String: SandboxParameterSpec]?
    public let run: String
    public var timeout: Int?
}

public struct SandboxParameterSpec: Codable, Sendable, Equatable {
    public let type: String
    public var description: String?
    public var `default`: String?
    public var `enum`: [String]?
}

// MARK: - MCP Spec

public struct MCPSpec: Codable, Sendable, Equatable {
    public let transport: String
    public let command: String
}

// MARK: - Permissions

public struct PermissionsSpec: Codable, Sendable, Equatable {
    public var network: String?
    public var network_domains: [String]?
    public var inference: Bool?
}

// MARK: - Discovered MCP Tool (persisted for restore)

public struct DiscoveredMCPTool: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public var inputSchemaJSON: String?
}

// MARK: - Install State

public enum SandboxPluginStatus: String, Codable, Sendable {
    case pending
    case installing
    case ready
    case failed
}

/// Per-agent record of an installed sandbox plugin and its status.
public struct InstalledSandboxPlugin: Codable, Sendable, Identifiable {
    public var id: String { plugin.normalizedName }
    public let plugin: SandboxPlugin
    public var status: SandboxPluginStatus
    public var errorMessage: String?
    public let installedAt: Date
    /// Tools discovered from MCP tools/list, persisted so they can be restored without booting the VM.
    public var discoveredMCPTools: [DiscoveredMCPTool]?

    public init(plugin: SandboxPlugin, status: SandboxPluginStatus = .pending, errorMessage: String? = nil) {
        self.plugin = plugin
        self.status = status
        self.errorMessage = errorMessage
        self.installedAt = Date()
    }
}

/// Persisted list of sandbox plugins for an agent.
public struct SandboxPluginStore: Codable, Sendable {
    public var plugins: [InstalledSandboxPlugin]

    public init(plugins: [InstalledSandboxPlugin] = []) {
        self.plugins = plugins
    }

    public static func load(for agentId: UUID) -> SandboxPluginStore {
        let url = OsaurusPaths.agentSandboxPluginsFile(agentId)
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(SandboxPluginStore.self, from: data)
        else { return SandboxPluginStore() }
        return store
    }

    public func save(for agentId: UUID) {
        let url = OsaurusPaths.agentSandboxPluginsFile(agentId)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
