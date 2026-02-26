//
//  AgentStore.swift
//  osaurus
//
//  Persistence for Agents
//

import Foundation

@MainActor
public enum AgentStore {
    // MARK: - Public API

    /// Load all agents sorted by name, including built-ins
    public static func loadAll() -> [Agent] {
        var agents = Agent.builtInAgents
        let directory = agentsDirectory()
        OsaurusPaths.ensureExistsSilent(directory)

        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else {
            return agents
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let agent = try decoder.decode(Agent.self, from: data)
                if !Agent.builtInAgents.contains(where: { $0.id == agent.id }) {
                    agents.append(agent)
                }
            } catch {
                print("[Osaurus] Failed to load agent from \(file.lastPathComponent): \(error)")
            }
        }

        return agents.sorted { a, b in
            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
            if a.isBuiltIn && b.isBuiltIn {
                if a.id == Agent.defaultId { return true }
                if b.id == Agent.defaultId { return false }
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Load a specific agent by ID
    public static func load(id: UUID) -> Agent? {
        if let builtIn = Agent.builtInAgents.first(where: { $0.id == id }) {
            return builtIn
        }

        let url = agentFileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Agent.self, from: data)
        } catch {
            print("[Osaurus] Failed to load agent \(id): \(error)")
            return nil
        }
    }

    /// Save an agent (creates or updates). Cannot save built-in agents.
    public static func save(_ agent: Agent) {
        guard !agent.isBuiltIn else {
            print("[Osaurus] Cannot save built-in agent: \(agent.name)")
            return
        }

        let url = agentFileURL(for: agent.id)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(agent)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save agent \(agent.id): \(error)")
        }
    }

    /// Delete an agent by ID. Cannot delete built-in agents.
    @discardableResult
    public static func delete(id: UUID) -> Bool {
        if Agent.builtInAgents.contains(where: { $0.id == id }) {
            print("[Osaurus] Cannot delete built-in agent")
            return false
        }

        do {
            try FileManager.default.removeItem(at: agentFileURL(for: id))
            return true
        } catch {
            print("[Osaurus] Failed to delete agent \(id): \(error)")
            return false
        }
    }

    /// Check if an agent exists
    public static func exists(id: UUID) -> Bool {
        Agent.builtInAgents.contains(where: { $0.id == id })
            || FileManager.default.fileExists(atPath: agentFileURL(for: id).path)
    }

    // MARK: - Private

    private static func agentsDirectory() -> URL {
        OsaurusPaths.resolvePath(new: OsaurusPaths.agents(), legacy: "Personas")
    }

    private static func agentFileURL(for id: UUID) -> URL {
        agentsDirectory().appendingPathComponent("\(id.uuidString).json")
    }
}
