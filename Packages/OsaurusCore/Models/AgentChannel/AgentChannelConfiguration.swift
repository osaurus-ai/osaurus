//
//  AgentChannelConfiguration.swift
//  osaurus
//
//  JSON-backed connection definitions for agent communication channels.
//

import Foundation

enum AgentChannelKind: String, Codable, CaseIterable, Sendable {
    case discord
    case slack
    case telegram
    case customHTTP = "custom_http"
}

enum AgentChannelAction: String, Codable, CaseIterable, Sendable {
    case diagnostics
    case listSpaces = "list_spaces"
    case listRooms = "list_rooms"
    case readMessages = "read_messages"
    case searchMessages = "search_messages"
    case draftMessage = "draft_message"
    case sendMessage = "send_message"
    case replyThread = "reply_thread"
}

struct AgentChannelSecretReference: Codable, Equatable, Sendable {
    var name: String
    var keychainId: String

    var normalized: AgentChannelSecretReference {
        AgentChannelSecretReference(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            keychainId: keychainId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct AgentChannelCustomHTTPAction: Codable, Equatable, Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var bodyTemplate: String?

    init(
        method: String = "GET",
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        bodyTemplate: String? = nil
    ) {
        self.method = method.uppercased()
        self.path = path
        self.query = query
        self.headers = headers
        self.bodyTemplate = bodyTemplate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decodeIfPresent(String.self, forKey: .method)?.uppercased() ?? "GET"
        path = try container.decode(String.self, forKey: .path)
        query = try container.decodeIfPresent([String: String].self, forKey: .query) ?? [:]
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        bodyTemplate = try container.decodeIfPresent(String.self, forKey: .bodyTemplate)
    }
}

struct AgentChannelCustomHTTPConfiguration: Codable, Equatable, Sendable {
    var baseURL: String
    var actions: [String: AgentChannelCustomHTTPAction]

    init(baseURL: String, actions: [String: AgentChannelCustomHTTPAction] = [:]) {
        self.baseURL = baseURL
        self.actions = actions
    }

    init(baseURL: String, actions: [AgentChannelAction: AgentChannelCustomHTTPAction]) {
        self.baseURL = baseURL
        self.actions = Dictionary(uniqueKeysWithValues: actions.map { ($0.rawValue, $1) })
    }
}

struct AgentChannelConnection: Codable, Equatable, Identifiable, Sendable {
    static let nativeDiscordConnectionId = "discord"

    var id: String
    var name: String
    var kind: AgentChannelKind
    var enabled: Bool
    var supportedActions: [AgentChannelAction]
    var spaceAllowlist: [String]
    var readRoomAllowlist: [String]
    var writeRoomAllowlist: [String]
    var writeEnabled: Bool
    var defaultReadLimit: Int
    var secrets: [AgentChannelSecretReference]
    var customHTTP: AgentChannelCustomHTTPConfiguration?

    init(
        id: String,
        name: String,
        kind: AgentChannelKind,
        enabled: Bool = true,
        supportedActions: [AgentChannelAction] = AgentChannelAction.allCases,
        spaceAllowlist: [String] = [],
        readRoomAllowlist: [String] = [],
        writeRoomAllowlist: [String] = [],
        writeEnabled: Bool = false,
        defaultReadLimit: Int = 50,
        secrets: [AgentChannelSecretReference] = [],
        customHTTP: AgentChannelCustomHTTPConfiguration? = nil
    ) {
        self.id = Self.normalizedId(id)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.enabled = enabled
        self.supportedActions = Self.normalizedActions(supportedActions)
        self.spaceAllowlist = Self.normalizedIds(spaceAllowlist)
        self.readRoomAllowlist = Self.normalizedIds(readRoomAllowlist)
        self.writeRoomAllowlist = Self.normalizedIds(writeRoomAllowlist)
        self.writeEnabled = writeEnabled
        self.defaultReadLimit = Self.clampReadLimit(defaultReadLimit)
        self.secrets = secrets.map(\.normalized)
        self.customHTTP = customHTTP
    }

    var normalized: AgentChannelConnection {
        AgentChannelConnection(
            id: id,
            name: name,
            kind: kind,
            enabled: enabled,
            supportedActions: supportedActions,
            spaceAllowlist: spaceAllowlist,
            readRoomAllowlist: readRoomAllowlist,
            writeRoomAllowlist: writeRoomAllowlist,
            writeEnabled: writeEnabled,
            defaultReadLimit: defaultReadLimit,
            secrets: secrets,
            customHTTP: customHTTP
        )
    }

    static func normalizedId(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedIds(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return
            ids
            .map(normalizedId)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func normalizedActions(_ actions: [AgentChannelAction]) -> [AgentChannelAction] {
        var seen = Set<AgentChannelAction>()
        return actions.filter { seen.insert($0).inserted }
    }

    static func clampReadLimit(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }
}

struct AgentChannelConfiguration: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var connections: [AgentChannelConnection]

    init(schemaVersion: Int = 1, connections: [AgentChannelConnection] = []) {
        self.schemaVersion = schemaVersion
        self.connections = Self.normalizedConnections(connections)
    }

    var normalized: AgentChannelConfiguration {
        AgentChannelConfiguration(schemaVersion: max(schemaVersion, 1), connections: connections)
    }

    func connection(id: String) -> AgentChannelConnection? {
        let normalized = AgentChannelConnection.normalizedId(id)
        return connections.first { $0.id == normalized }
    }

    private static func normalizedConnections(
        _ connections: [AgentChannelConnection]
    ) -> [AgentChannelConnection] {
        var seen = Set<String>()
        return
            connections
            .map(\.normalized)
            .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }
}

enum AgentChannelConfigurationStore {
    nonisolated(unsafe) static var overrideDirectory: URL?

    private static let fileName = "agent-channels.json"

    static func load() -> AgentChannelConfiguration {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AgentChannelConfiguration()
        }
        do {
            return try JSONDecoder()
                .decode(AgentChannelConfiguration.self, from: Data(contentsOf: url))
                .normalized
        } catch {
            NSLog("[AgentChannels] Failed to load channel configuration: \(error.localizedDescription)")
            return AgentChannelConfiguration()
        }
    }

    static func save(_ configuration: AgentChannelConfiguration) throws {
        let url = configurationFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration.normalized).write(to: url, options: [.atomic])
    }

    static func configurationFileURL() -> URL {
        if let overrideDirectory {
            return overrideDirectory.appendingPathComponent(fileName)
        }
        return OsaurusPaths.config().appendingPathComponent(fileName)
    }
}
