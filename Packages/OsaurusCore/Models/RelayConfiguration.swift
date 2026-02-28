//
//  RelayConfiguration.swift
//  osaurus
//
//  Persistent configuration for relay tunneling per agent.
//

import Foundation

/// Which agents have relay tunneling enabled.
public struct RelayConfiguration: Codable, Equatable, Sendable {
    /// Maps agent UUID string -> tunnel enabled. Only agents with `true` are tunneled.
    public var enabledAgents: [String: Bool]

    public static let `default` = RelayConfiguration(enabledAgents: [:])

    public func isEnabled(for agentId: UUID) -> Bool {
        enabledAgents[agentId.uuidString] == true
    }

    public mutating func setEnabled(_ enabled: Bool, for agentId: UUID) {
        enabledAgents[agentId.uuidString] = enabled ? true : nil
    }

    /// All agent UUIDs that have tunneling enabled.
    public var enabledAgentIds: [UUID] {
        enabledAgents.compactMap { key, value in
            value ? UUID(uuidString: key) : nil
        }
    }
}

// MARK: - Persistence

@MainActor
enum RelayConfigurationStore {
    static func load() -> RelayConfiguration {
        let url = OsaurusPaths.relayConfigFile()
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        do {
            return try JSONDecoder().decode(RelayConfiguration.self, from: Data(contentsOf: url))
        } catch {
            print("[Osaurus] Failed to load RelayConfiguration: \(error)")
            return .default
        }
    }

    static func save(_ configuration: RelayConfiguration) {
        let url = OsaurusPaths.relayConfigFile()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save RelayConfiguration: \(error)")
        }
    }
}
