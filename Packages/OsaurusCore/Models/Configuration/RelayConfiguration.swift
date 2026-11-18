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
    /// Agents explicitly kept off the relay (`relay_enabled: false` from
    /// `config apply`), even before they had an address. A paired phone's
    /// turn-on for newly addressed agents skips them; turning one on clears it.
    public var keptOffAgents: [String]?

    public static let `default` = RelayConfiguration(enabledAgents: [:])

    public func isEnabled(for agentId: UUID) -> Bool {
        enabledAgents[agentId.uuidString] == true
    }

    public func isKeptOff(_ agentId: UUID) -> Bool {
        keptOffAgents?.contains(agentId.uuidString) == true
    }

    public mutating func setEnabled(_ enabled: Bool, for agentId: UUID) {
        enabledAgents[agentId.uuidString] = enabled ? true : nil
        if enabled { setKeptOff(false, for: agentId) }
    }

    public mutating func setKeptOff(_ keptOff: Bool, for agentId: UUID) {
        var ids = Set(keptOffAgents ?? [])
        if keptOff { ids.insert(agentId.uuidString) } else { ids.remove(agentId.uuidString) }
        keptOffAgents = ids.isEmpty ? nil : ids.sorted()
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
