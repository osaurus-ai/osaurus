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

    // MARK: - Write serialization

    /// Serial queue for agent JSON writes. `save` runs on the main actor
    /// (every settings edit and autosave lands here) and an atomic write to a
    /// slow or pressured disk has shown up as a multi-second app hang, so the
    /// disk write happens here instead of the calling thread. The queue is
    /// serial so writes land in call order, and readers flush it first so a
    /// save immediately followed by `refresh()`/`loadAll()` observes its own
    /// write.
    private nonisolated static let writeQueue = DispatchQueue(
        label: "com.dinoki.osaurus.agent-store-writes", qos: .utility)

    /// Barrier for read paths: waits for queued writes only, which are single
    /// small JSON files — bounded, unlike the read scan they unblock.
    private nonisolated static func flushPendingWrites() {
        writeQueue.sync {}
    }

    // MARK: - Public API

    // Decoded custom agents by id, populated by the first `loadAll` disk
    // scan and maintained in place by `save`/`delete`. Every debounced
    // settings save runs `AgentManager.refresh()` → `loadAll()`, and
    // re-reading + decoding every agent file there was a measured
    // multi-second main-thread hang on contended disks. In-process record
    // mutations all go through this type (main-actor); files written
    // out-of-band (tests, manual edits) are caught by revalidating the memo
    // against the directory listing — one enumeration instead of N file
    // reads + JSON decodes.
    private static var loadedCustomAgents: [UUID: Agent]?

    /// Load all agents sorted by name, including built-ins
    public static func loadAll() -> [Agent] {
        // Cheap when the queue is idle; guarantees the listing check below
        // sees writes queued by `save` in program order.
        flushPendingWrites()
        if let cached = loadedCustomAgents, cachedListingMatchesDisk(cached) {
            return sortedForDisplay(Agent.builtInAgents + Array(cached.values))
        }
        loadedCustomAgents = nil

        // Consolidate any records stranded in the legacy `Personas/` directory
        // before resolving where to read from — enabling a per-agent Database
        // or writing a custom avatar creates `agents/`, which flips path
        // resolution away from `Personas/`. Idempotent + conflict-safe.
        OsaurusPaths.migrateLegacyPersonasIfNeeded()
        var custom: [UUID: Agent] = [:]
        let directory = agentsDirectory()
        OsaurusPaths.ensureExistsSilent(directory)

        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else {
            return sortedForDisplay(Agent.builtInAgents)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let agent = try decoder.decode(Agent.self, from: data)
                if !Agent.builtInAgents.contains(where: { $0.id == agent.id }) {
                    custom[agent.id] = agent
                }
            } catch {
                print("[Osaurus] Failed to load agent from \(file.lastPathComponent): \(error)")
            }
        }

        loadedCustomAgents = custom
        return sortedForDisplay(Agent.builtInAgents + Array(custom.values))
    }

    /// Whether the memoized agent set still matches the `.json` records on
    /// disk (by filename). Catches out-of-band file adds/removes; an
    /// out-of-band content edit of an existing record is only picked up on
    /// the next cold launch, as before the memo existed.
    private static func cachedListingMatchesDisk(_ cached: [UUID: Agent]) -> Bool {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: agentsDirectory(), includingPropertiesForKeys: nil)
        else { return cached.isEmpty }
        let builtInNames = Set(Agent.builtInAgents.map { "\($0.id.uuidString).json" })
        var onDisk = Set<String>()
        for file in files where file.pathExtension == "json" {
            let name = file.lastPathComponent
            if !builtInNames.contains(name) { onDisk.insert(name) }
        }
        let expected = Set(cached.keys.map { "\($0.uuidString).json" })
        return onDisk == expected
    }

    private static func sortedForDisplay(_ agents: [Agent]) -> [Agent] {
        agents.sorted { a, b in
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
        if let cached = loadedCustomAgents?[id] {
            return cached
        }
        // Cache miss falls through to disk: the record may have been written
        // out-of-band (tests, manual edits) since the memo was built.
        flushPendingWrites()
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
        loadedCustomAgents?[agent.id] = agent

        do {
            // Encode on the caller (cheap, and `Agent` needn't be Sendable);
            // only the disk write moves to the background queue.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(agent)
            let agentId = agent.id
            writeQueue.async {
                OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
                do {
                    try data.write(to: url, options: [.atomic])
                } catch {
                    print("[Osaurus] Failed to save agent \(agentId): \(error)")
                }
            }
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

        // Serialize against queued saves so a pending write can't recreate
        // the file after removal.
        flushPendingWrites()

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
            loadedCustomAgents?.removeValue(forKey: id)
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

    /// Check if an agent exists. `nonisolated`: pure filesystem + static
    /// data, callable from any thread — background validators must not have
    /// to `DispatchQueue.main.sync` into the MainActor just to run a
    /// `fileExists` (that hop can deadlock when the main thread is itself
    /// waiting on the background queue, and stalls behind a busy run loop).
    public nonisolated static func exists(id: UUID) -> Bool {
        if Agent.builtInAgents.contains(where: { $0.id == id }) { return true }
        // A just-saved agent may still be in the write queue; wait for it so
        // existence matches program order (`nonisolated`, so callable here).
        flushPendingWrites()
        return FileManager.default.fileExists(atPath: agentFileURL(for: id).path)
    }

    // MARK: - Private

    private nonisolated static func agentsDirectory() -> URL {
        OsaurusPaths.resolvePath(new: OsaurusPaths.agents(), legacy: "Personas")
    }

    private nonisolated static func agentFileURL(for id: UUID) -> URL {
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
        // The record may still be a queued write; serialize before removal.
        flushPendingWrites()
        loadedCustomAgents?.removeValue(forKey: id)
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
