//
//  SandboxPlugin.swift
//  osaurus
//
//  JSON recipe format for sandbox plugins that run inside the shared
//  Linux container. Each plugin declares dependencies, setup commands,
//  tool definitions, and optional MCP/daemon processes.
//

import CryptoKit
import Foundation

// MARK: - Sandbox Plugin

public struct SandboxPlugin: Codable, Sendable, Identifiable, Equatable {
    public var id: String { name.lowercased().replacingOccurrences(of: " ", with: "-") }

    public var name: String
    public var description: String
    public var version: String?
    public var author: String?
    public var source: String?

    /// System packages installed via `apk add` (runs as root, idempotent)
    public var dependencies: [String]?
    /// Setup command run as the agent's Linux user with cwd = plugin folder
    public var setup: String?
    /// Files seeded into the plugin folder. Keys = relative paths, values = contents.
    /// Paths must not contain ".." or start with "/".
    public var files: [String: String]?
    public var tools: [SandboxToolSpec]?
    public var mcp: SandboxMCPSpec?
    public var daemon: SandboxDaemonSpec?
    /// Secret names the plugin requires. User is prompted on install.
    public var secrets: [String]?
    public var events: SandboxEventsSpec?
    public var permissions: SandboxPermissions?

    public init(
        name: String,
        description: String,
        version: String? = nil,
        author: String? = nil,
        source: String? = nil,
        dependencies: [String]? = nil,
        setup: String? = nil,
        files: [String: String]? = nil,
        tools: [SandboxToolSpec]? = nil,
        mcp: SandboxMCPSpec? = nil,
        daemon: SandboxDaemonSpec? = nil,
        secrets: [String]? = nil,
        events: SandboxEventsSpec? = nil,
        permissions: SandboxPermissions? = nil
    ) {
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.source = source
        self.dependencies = dependencies
        self.setup = setup
        self.files = files
        self.tools = tools
        self.mcp = mcp
        self.daemon = daemon
        self.secrets = secrets
        self.events = events
        self.permissions = permissions
    }
}

// MARK: - Tool Spec

public struct SandboxToolSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public let description: String
    public var parameters: [String: SandboxParameterSpec]?
    /// Shell command to run. Parameters available as $PARAM_{NAME} env vars.
    public let run: String

    public init(
        id: String,
        description: String,
        parameters: [String: SandboxParameterSpec]? = nil,
        run: String
    ) {
        self.id = id
        self.description = description
        self.parameters = parameters
        self.run = run
    }
}

public struct SandboxParameterSpec: Codable, Sendable, Equatable {
    public var type: String
    public var description: String?
    public var `default`: String?
    public var `enum`: [String]?

    public init(
        type: String,
        description: String? = nil,
        default defaultValue: String? = nil,
        enum enumValues: [String]? = nil
    ) {
        self.type = type
        self.description = description
        self.default = defaultValue
        self.enum = enumValues
    }
}

// MARK: - MCP Server Spec

public struct SandboxMCPSpec: Codable, Sendable, Equatable {
    /// Command to start the MCP server (stdio transport)
    public let command: String
    /// Environment variables for the MCP server process
    public var env: [String: String]?

    public init(command: String, env: [String: String]? = nil) {
        self.command = command
        self.env = env
    }
}

// MARK: - Daemon Spec

public struct SandboxDaemonSpec: Codable, Sendable, Equatable {
    /// Command to run as a background daemon
    public let command: String
    public var env: [String: String]?

    public init(command: String, env: [String: String]? = nil) {
        self.command = command
        self.env = env
    }
}

// MARK: - Events Spec

public struct SandboxEventsSpec: Codable, Sendable, Equatable {
    public var subscribe: [String]?
    public var emit: [String]?

    public init(subscribe: [String]? = nil, emit: [String]? = nil) {
        self.subscribe = subscribe
        self.emit = emit
    }
}

// MARK: - Permissions

public struct SandboxPermissions: Codable, Sendable, Equatable {
    /// "outbound", "none", or specific domain allowlist
    public var network: String?
    /// Whether the plugin can call inference APIs
    public var inference: Bool?

    public init(network: String? = nil, inference: Bool? = nil) {
        self.network = network
        self.inference = inference
    }
}

// MARK: - Content Hash & Validation

extension SandboxPlugin {
    /// Deterministic SHA-256 hash of the plugin's canonical JSON representation.
    /// Used to detect meaningful content changes between library and installed copies.
    public var contentHash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Validates file paths in the `files` dictionary reject traversal attacks.
    public func validateFilePaths() -> [String] {
        SandboxPathSanitizer.validatePluginFiles(files)
    }
}

// MARK: - Installed State

/// Tracks the installation state of a sandbox plugin for a specific agent.
public struct InstalledSandboxPlugin: Codable, Sendable, Identifiable, Equatable {
    public var id: String { plugin.id }
    public let plugin: SandboxPlugin
    public let agentId: String
    public let installedAt: Date
    public var status: InstallStatus
    public let sourceContentHash: String

    public enum InstallStatus: String, Codable, Sendable, Equatable {
        case installing
        case ready
        case failed
        case uninstalling
    }

    public init(
        plugin: SandboxPlugin,
        agentId: String,
        installedAt: Date = Date(),
        status: InstallStatus = .installing,
        sourceContentHash: String? = nil
    ) {
        self.plugin = plugin
        self.agentId = agentId
        self.installedAt = installedAt
        self.status = status
        self.sourceContentHash = sourceContentHash ?? plugin.contentHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plugin = try container.decode(SandboxPlugin.self, forKey: .plugin)
        agentId = try container.decode(String.self, forKey: .agentId)
        installedAt = try container.decode(Date.self, forKey: .installedAt)
        status = try container.decode(InstallStatus.self, forKey: .status)
        sourceContentHash = try container.decodeIfPresent(String.self, forKey: .sourceContentHash) ?? ""
    }
}

// MARK: - Export / Import / Distribution

extension SandboxPlugin {
    /// Serialize to pretty-printed JSON for sharing.
    public func exportJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SandboxPluginDistributionError.encodingFailed
        }
        return json
    }

    /// Import from a JSON string.
    public static func fromJSON(_ json: String) throws -> SandboxPlugin {
        guard let data = json.data(using: .utf8) else {
            throw SandboxPluginDistributionError.invalidJSON
        }
        return try JSONDecoder().decode(SandboxPlugin.self, from: data)
    }

    /// Import from a URL (fetches JSON from a remote URL).
    public static func fromURL(_ url: URL) async throws -> SandboxPlugin {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
            (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw SandboxPluginDistributionError.fetchFailed(url.absoluteString)
        }
        return try JSONDecoder().decode(SandboxPlugin.self, from: data)
    }

    /// Import from a GitHub repo URL (looks for osaurus.json at the root).
    public static func fromGitHub(repoURL: String) async throws -> SandboxPlugin {
        // Convert github.com URL to raw.githubusercontent.com
        var raw =
            repoURL
            .replacingOccurrences(of: "github.com", with: "raw.githubusercontent.com")
        if !raw.hasSuffix("/") { raw += "/" }
        raw += "main/osaurus.json"

        guard let url = URL(string: raw) else {
            throw SandboxPluginDistributionError.invalidURL(repoURL)
        }
        return try await fromURL(url)
    }
}

public enum SandboxPluginDistributionError: Error, LocalizedError {
    case encodingFailed
    case invalidJSON
    case fetchFailed(String)
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: "Failed to encode plugin to JSON"
        case .invalidJSON: "Invalid JSON string"
        case .fetchFailed(let url): "Failed to fetch plugin from: \(url)"
        case .invalidURL(let url): "Invalid URL: \(url)"
        }
    }
}
