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
        // Consolidate any records stranded in the legacy `Personas/` directory
        // before resolving where to read from — enabling a per-agent Database
        // or writing a custom avatar creates `agents/`, which flips path
        // resolution away from `Personas/`. Idempotent + conflict-safe.
        OsaurusPaths.migrateLegacyPersonasIfNeeded()
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
            // Ordered agents first; unordered fall through to alphabetical.
            switch (a.order, b.order) {
            case let (lhs?, rhs?) where lhs != rhs:
                return lhs < rhs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
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

        // Best-effort cleanup of any custom avatar file before removing the JSON.
        if let agent = load(id: id), let url = agent.customAvatarURL {
            try? FileManager.default.removeItem(at: url)
        }

        // Agent DB feature: drop scheduler rows + the per-agent DB
        // directory. Each cleanup is best-effort so a missing
        // scheduler.sqlite (feature not yet initialised) doesn't
        // block agent deletion.
        try? SchedulerDatabase.shared.deleteAllForAgent(id)
        try? AgentDatabaseStore.shared.deleteOnDisk(for: id)
        // The serial queue + open DB handle inside LocalAgentBridge
        // outlives `deleteOnDisk` (those live in a separate registry
        // keyed by agentId). Drop them here so a later create-with-
        // the-same-id can't re-attach to a stale handle.
        LocalAgentBridge.shared.forget(agentId: id)

        do {
            try FileManager.default.removeItem(at: agentFileURL(for: id))
            return true
        } catch {
            print("[Osaurus] Failed to delete agent \(id): \(error)")
            return false
        }
    }

    // MARK: - Custom Avatar Storage

    /// Persist `data` as the custom avatar image for `agent` and return the
    /// resulting filename (relative to the avatars directory). The caller is
    /// responsible for writing the updated `Agent` (with `customAvatarFilename`
    /// set) via `save(_:)`.
    @discardableResult
    public static func writeCustomAvatar(_ data: Data, ext: String, for agentId: UUID) -> String? {
        let dir = avatarsDirectory()
        OsaurusPaths.ensureExistsSilent(dir)
        let safeExt = ext.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let filename = "\(agentId.uuidString).\(safeExt.isEmpty ? "png" : safeExt)"
        let url = dir.appendingPathComponent(filename)
        do {
            // Remove any prior file with a different extension for the same agent.
            if let existing = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for f in existing
                where f.deletingPathExtension().lastPathComponent == agentId.uuidString
                    && f.lastPathComponent != filename
                {
                    try? FileManager.default.removeItem(at: f)
                }
            }
            try data.write(to: url, options: [.atomic])
            return filename
        } catch {
            print("[Osaurus] Failed to write custom avatar for \(agentId): \(error)")
            return nil
        }
    }

    /// Remove the custom avatar file for `agentId` if present. The caller is
    /// responsible for clearing `customAvatarFilename` on the Agent record.
    public static func removeCustomAvatar(for agentId: UUID) {
        let dir = avatarsDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for f in entries where f.deletingPathExtension().lastPathComponent == agentId.uuidString {
            try? FileManager.default.removeItem(at: f)
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

    private static func avatarsDirectory() -> URL {
        OsaurusPaths.agents().appendingPathComponent("avatars", isDirectory: true)
    }
}
