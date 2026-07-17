//
//  AgentStore.swift
//  osaurus
//
//  Persistence for Agents
//

import Foundation

@MainActor
public enum AgentStore {
    public struct RecoverableAgentBackup: Equatable, Sendable {
        public let url: URL
        public let agent: Agent
        public let conflictsWithExistingAgent: Bool
    }

    public enum RecoveryError: Error, Equatable, LocalizedError {
        case unreadableBackup(String)
        case builtInAgent(String)
        case restoreSaveFailed(String)
        case backupConsumedFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableBackup(let name):
                return "Could not read agent backup \(name)."
            case .builtInAgent(let name):
                return "Built-in agent backups cannot be restored: \(name)."
            case .restoreSaveFailed(let name):
                return "Could not save recovered agent \(name)."
            case .backupConsumedFailed(let name):
                return "Recovered agent backup could not be marked restored: \(name)."
            }
        }
    }

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

    /// Preserved legacy migration conflict copies (`<uuid>.json.bak`,
    /// `<uuid>.json.1.bak`, ...). These are intentionally ignored by
    /// `loadAll()` so a conflict never overwrites the canonical agent, but the
    /// user still needs a recovery surface for the saved legacy copy.
    public static func recoverableBackups() -> [RecoverableAgentBackup] {
        OsaurusPaths.migrateLegacyPersonasIfNeeded()
        let directory = OsaurusPaths.agents()
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else { return [] }

        return files
            .filter(isRecoverableBackupURL)
            .compactMap { url -> RecoverableAgentBackup? in
                guard let agent = try? decodeAgentBackup(at: url), !agent.isBuiltIn else {
                    return nil
                }
                return RecoverableAgentBackup(
                    url: url,
                    agent: agent,
                    conflictsWithExistingAgent: exists(id: agent.id)
                        || identityConflicts(with: agent)
                )
            }
            .sorted { lhs, rhs in
                lhs.url.lastPathComponent.localizedCaseInsensitiveCompare(rhs.url.lastPathComponent)
                    == .orderedAscending
            }
    }

    /// Restore a preserved agent backup into the canonical `agents/` store.
    ///
    /// If the backup's original UUID is free, the agent is restored as-is. If a
    /// current agent already owns that UUID, the recovered copy is imported as a
    /// new agent with a fresh UUID and cleared crypto identity so existing
    /// agent-scoped tokens / addresses are never duplicated.
    @discardableResult
    public static func restoreRecoverableBackup(
        at url: URL,
        recoveredId: UUID = UUID(),
        recoveredAt: Date = Date()
    ) throws -> Agent {
        let backup = try decodeAgentBackup(at: url)
        guard !backup.isBuiltIn else {
            throw RecoveryError.builtInAgent(backup.name)
        }

        let restored: Agent
        if exists(id: backup.id) {
            let safeRecoveredId = uniqueRecoveredId(preferred: recoveredId)
            restored = backup.recoveredConflictCopy(id: safeRecoveredId, recoveredAt: recoveredAt)
        } else if identityConflicts(with: backup) {
            restored = backup.clearingRecoveredIdentity(recoveredAt: recoveredAt)
        } else {
            restored = backup
        }
        let createdRestoredAgent = !exists(id: restored.id)
        save(restored)
        guard exists(id: restored.id) else {
            throw RecoveryError.restoreSaveFailed(restored.name)
        }
        do {
            try consumeRecoveredBackup(at: url)
        } catch {
            if createdRestoredAgent {
                removeAgentRecord(id: restored.id)
            }
            throw error
        }
        return restored
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

    private static func isRecoverableBackupURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "bak"
            && url.lastPathComponent.localizedCaseInsensitiveContains(".json")
    }

    private static func decodeAgentBackup(at url: URL) throws -> Agent {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Agent.self, from: data)
        } catch {
            throw RecoveryError.unreadableBackup(url.lastPathComponent)
        }
    }

    private static func identityConflicts(with agent: Agent) -> Bool {
        let candidateAddress = agent.agentAddress?.lowercased()
        return loadAll().contains { existing in
            guard !existing.isBuiltIn else { return false }
            if let index = agent.agentIndex, existing.agentIndex == index {
                return true
            }
            if let candidateAddress,
                existing.agentAddress?.lowercased() == candidateAddress
            {
                return true
            }
            return false
        }
    }

    private static func consumeRecoveredBackup(at url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let consumedURL = uniqueConsumedBackupURL(for: url, fileManager: fm)
        do {
            try fm.moveItem(at: url, to: consumedURL)
        } catch {
            throw RecoveryError.backupConsumedFailed(url.lastPathComponent)
        }
    }

    private static func uniqueRecoveredId(preferred: UUID) -> UUID {
        var candidate = preferred
        while exists(id: candidate) {
            candidate = UUID()
        }
        return candidate
    }

    private static func removeAgentRecord(id: UUID) {
        let url = agentFileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("[Osaurus] Failed to roll back recovered agent record \(id): \(error)")
        }
    }

    private static func uniqueConsumedBackupURL(for url: URL, fileManager fm: FileManager) -> URL {
        var candidate = url.appendingPathExtension("restored")
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = url.appendingPathExtension("restored.\(counter)")
            counter += 1
        }
        return candidate
    }
}

private extension Agent {
    func clearingRecoveredIdentity(recoveredAt: Date) -> Agent {
        Agent(
            id: id,
            name: name,
            description: description,
            systemPrompt: systemPrompt,
            themeId: themeId,
            defaultModel: defaultModel,
            temperature: temperature,
            maxTokens: maxTokens,
            chatQuickActions: chatQuickActions,
            chatGreeting: chatGreeting,
            chatSubtitle: chatSubtitle,
            isBuiltIn: false,
            createdAt: createdAt,
            updatedAt: recoveredAt,
            agentIndex: nil,
            agentAddress: nil,
            autonomousExec: autonomousExec,
            pluginInstructions: pluginInstructions,
            bonjourEnabled: bonjourEnabled,
            toolSelectionMode: toolSelectionMode,
            manualToolNames: manualToolNames,
            toolsEnabled: toolsEnabled,
            memoryEnabled: memoryEnabled,
            avatar: avatar,
            customAvatarFilename: customAvatarFilename,
            autoSpeak: autoSpeak,
            ttsVoice: ttsVoice,
            settings: settings,
            order: order,
            hostWorkspaceBookmark: hostWorkspaceBookmark,
            hostWorkspacePath: hostWorkspacePath
        )
    }

    func recoveredConflictCopy(id: UUID, recoveredAt: Date) -> Agent {
        Agent(
            id: id,
            name: "\(name) (Recovered)",
            description: description,
            systemPrompt: systemPrompt,
            themeId: themeId,
            defaultModel: defaultModel,
            temperature: temperature,
            maxTokens: maxTokens,
            chatQuickActions: chatQuickActions,
            chatGreeting: chatGreeting,
            chatSubtitle: chatSubtitle,
            isBuiltIn: false,
            createdAt: createdAt,
            updatedAt: recoveredAt,
            agentIndex: nil,
            agentAddress: nil,
            autonomousExec: autonomousExec,
            pluginInstructions: pluginInstructions,
            bonjourEnabled: bonjourEnabled,
            toolSelectionMode: toolSelectionMode,
            manualToolNames: manualToolNames,
            toolsEnabled: toolsEnabled,
            memoryEnabled: memoryEnabled,
            avatar: avatar,
            customAvatarFilename: nil,
            autoSpeak: autoSpeak,
            ttsVoice: ttsVoice,
            settings: settings,
            order: nil,
            hostWorkspaceBookmark: hostWorkspaceBookmark,
            hostWorkspacePath: hostWorkspacePath
        )
    }
}
