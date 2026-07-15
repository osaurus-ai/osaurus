//
//  OsaurusPersonasMigrationTests.swift
//  OsaurusCoreTests
//
//  Pins the legacy `Personas/` -> `agents/` consolidation that fixes the
//  disappearing-agents bug: once any feature creates `agents/` (a per-agent
//  Database directory, a custom avatar), `resolvePath(new: agents(),
//  legacy: "Personas")` flips away from the legacy directory and every record
//  still under `Personas/` vanishes from the list. The migration moves them
//  so the flip can never strand data again.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct OsaurusPersonasMigrationTests {

    private func seedAgentJSON(at url: URL, id: UUID, name: String) throws {
        // A minimal but real `Agent` record so the migrated file is a valid
        // decode target, not just opaque bytes.
        let agent = Agent(id: id, name: name)
        let data = try JSONEncoder().encode(agent)
        try data.write(to: url, options: .atomic)
    }

    private func seedLoadableAgentJSON(at url: URL, agent: Agent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(agent)
        try data.write(to: url, options: .atomic)
    }

    private func loadableAgentDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func withTemporaryOsaurusRoot<T: Sendable>(
        name: String,
        _ body: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let previousRoot = OsaurusPaths.overrideRoot
        OsaurusPaths.overrideRoot = root
        defer {
            OsaurusPaths.overrideRoot = previousRoot
            try? fm.removeItem(at: root)
        }
        return try await body(root)
    }

    @Test("Stranded records move into agents/ after the agents dir already exists")
    func movesStrandedRecordsAfterAgentsDirCreated() async throws {
        try await StoragePathsTestLock.shared.run {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent(
                "osaurus-personas-migrate-\(UUID().uuidString)",
                isDirectory: true
            )
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? fm.removeItem(at: root)
            }

            let legacy = root.appendingPathComponent("Personas", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            let idA = UUID()
            let idB = UUID()
            try seedAgentJSON(at: legacy.appendingPathComponent("\(idA).json"), id: idA, name: "Alpha")
            try seedAgentJSON(at: legacy.appendingPathComponent("\(idB).json"), id: idB, name: "Beta")

            // Simulate the flip trigger: enabling per-agent Database creates
            // `agents/<uuid>/db.sqlite`, which makes `agents/` exist.
            let agents = OsaurusPaths.agents()
            let dbDir = agents.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: dbDir, withIntermediateDirectories: true)
            try Data("db".utf8).write(to: dbDir.appendingPathComponent("db.sqlite"))

            let result = OsaurusPaths.migrateLegacyPersonasIfNeeded()
            #expect(result == .migrated(moved: 2, conflicts: 0))

            #expect(fm.fileExists(atPath: agents.appendingPathComponent("\(idA).json").path))
            #expect(fm.fileExists(atPath: agents.appendingPathComponent("\(idB).json").path))
            // Legacy dir had only JSON, so it is now empty and removed.
            #expect(!fm.fileExists(atPath: legacy.path))

            // The moved records still decode as valid Agent values.
            let movedA = try JSONDecoder().decode(
                Agent.self,
                from: Data(contentsOf: agents.appendingPathComponent("\(idA).json"))
            )
            #expect(movedA.id == idA && movedA.name == "Alpha")
        }
    }

    @Test("A name clash keeps the canonical copy and backs up the legacy one")
    func conflictKeepsCanonicalCopyAndBacksUpLegacy() async throws {
        try await StoragePathsTestLock.shared.run {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent(
                "osaurus-personas-conflict-\(UUID().uuidString)",
                isDirectory: true
            )
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? fm.removeItem(at: root)
            }

            let id = UUID()
            let agents = OsaurusPaths.agents()
            try fm.createDirectory(at: agents, withIntermediateDirectories: true)
            try seedLoadableAgentJSON(
                at: agents.appendingPathComponent("\(id).json"),
                agent: Agent(id: id, name: "Canonical")
            )

            let legacy = root.appendingPathComponent("Personas", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            try seedLoadableAgentJSON(
                at: legacy.appendingPathComponent("\(id).json"),
                agent: Agent(id: id, name: "Legacy")
            )

            let result = OsaurusPaths.migrateLegacyPersonasIfNeeded()
            #expect(result == .migrated(moved: 0, conflicts: 1))

            // Canonical copy is untouched.
            let canonical = try loadableAgentDecoder().decode(
                Agent.self,
                from: Data(contentsOf: agents.appendingPathComponent("\(id).json"))
            )
            #expect(canonical.name == "Canonical")

            // Legacy copy preserved as a `.bak` sibling (ignored by loadAll).
            let backup = agents.appendingPathComponent("\(id).json.bak")
            #expect(fm.fileExists(atPath: backup.path))
            let backed = try loadableAgentDecoder().decode(Agent.self, from: Data(contentsOf: backup))
            #expect(backed.name == "Legacy")

            let recoverableBackups = await MainActor.run { AgentStore.recoverableBackups() }
            let recoverableBackup = try #require(recoverableBackups.first)
            #expect(recoverableBackups.count == 1)
            #expect(recoverableBackup.url.lastPathComponent == backup.lastPathComponent)
            #expect(recoverableBackup.agent.name == "Legacy")
            #expect(recoverableBackup.conflictsWithExistingAgent)

            #expect(!fm.fileExists(atPath: legacy.path))
        }
    }

    @Test("Non-JSON entries are preserved and the legacy directory is kept")
    func preservesNonJSONEntriesAndKeepsLegacyDir() async throws {
        try await StoragePathsTestLock.shared.run {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent(
                "osaurus-personas-nonjson-\(UUID().uuidString)",
                isDirectory: true
            )
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? fm.removeItem(at: root)
            }

            let legacy = root.appendingPathComponent("Personas", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            let id = UUID()
            try seedAgentJSON(at: legacy.appendingPathComponent("\(id).json"), id: id, name: "Gamma")
            let note = legacy.appendingPathComponent("notes.txt")
            try Data("keep me".utf8).write(to: note)

            let result = OsaurusPaths.migrateLegacyPersonasIfNeeded()
            #expect(result == .migrated(moved: 1, conflicts: 0))

            let agents = OsaurusPaths.agents()
            #expect(fm.fileExists(atPath: agents.appendingPathComponent("\(id).json").path))
            // The non-JSON file is left in place, so the directory is retained.
            #expect(fm.fileExists(atPath: legacy.path))
            #expect(fm.fileExists(atPath: note.path))
        }
    }

    @Test("Absent legacy directory is a no-op and the migration is idempotent")
    func absentLegacyDirIsNoOpAndIdempotent() async throws {
        try await StoragePathsTestLock.shared.run {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent(
                "osaurus-personas-absent-\(UUID().uuidString)",
                isDirectory: true
            )
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? fm.removeItem(at: root)
            }

            #expect(OsaurusPaths.migrateLegacyPersonasIfNeeded() == .legacyDirectoryAbsent)

            // Seed, migrate once, then confirm a second run is a clean no-op.
            let legacy = root.appendingPathComponent("Personas", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            let id = UUID()
            try seedAgentJSON(at: legacy.appendingPathComponent("\(id).json"), id: id, name: "Delta")

            #expect(OsaurusPaths.migrateLegacyPersonasIfNeeded() == .migrated(moved: 1, conflicts: 0))
            #expect(OsaurusPaths.migrateLegacyPersonasIfNeeded() == .legacyDirectoryAbsent)
        }
    }

    @Test("Migration conflict backups are discoverable and restore as safe new agents")
    func conflictBackupRestoresAsNewAgentWithoutOverwritingCanonical() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withTemporaryOsaurusRoot(name: "osaurus-personas-recover-conflict") { _ in
                let fm = FileManager.default
                let agents = OsaurusPaths.agents()
                try fm.createDirectory(at: agents, withIntermediateDirectories: true)

                let originalId = UUID()
                let recoveredId = UUID()
                let recoveredAt = Date(timeIntervalSince1970: 1_800_000_000)

                let canonical = Agent(
                    id: originalId,
                    name: "Canonical",
                    systemPrompt: "canonical prompt"
                )
                try seedLoadableAgentJSON(
                    at: agents.appendingPathComponent("\(originalId.uuidString).json"),
                    agent: canonical
                )

                let legacy = Agent(
                    id: originalId,
                    name: "Legacy",
                    systemPrompt: "legacy prompt",
                    agentIndex: 42,
                    agentAddress: "0xlegacy",
                    customAvatarFilename: "\(originalId.uuidString).png",
                    order: 7
                )
                let backupURL = agents.appendingPathComponent("\(originalId.uuidString).json.bak")
                try seedLoadableAgentJSON(at: backupURL, agent: legacy)

                let backups = await MainActor.run { AgentStore.recoverableBackups() }
                let backup = try #require(backups.first)
                #expect(backups.count == 1)
                #expect(backup.url.lastPathComponent == backupURL.lastPathComponent)
                #expect(backup.agent.name == "Legacy")
                #expect(backup.conflictsWithExistingAgent)

                let restored = try await MainActor.run {
                    try AgentStore.restoreRecoverableBackup(
                        at: backup.url,
                        recoveredId: recoveredId,
                        recoveredAt: recoveredAt
                    )
                }

                #expect(restored.id == recoveredId)
                #expect(restored.name == "Legacy (Recovered)")
                #expect(restored.systemPrompt == "legacy prompt")
                #expect(restored.updatedAt == recoveredAt)
                #expect(restored.agentIndex == nil)
                #expect(restored.agentAddress == nil)
                #expect(restored.customAvatarFilename == nil)
                #expect(restored.order == nil)

                let stillCanonical = await MainActor.run { AgentStore.load(id: originalId) }
                #expect(stillCanonical?.name == "Canonical")
                #expect(stillCanonical?.systemPrompt == "canonical prompt")

                let loadedRecovered = await MainActor.run { AgentStore.load(id: recoveredId) }
                #expect(loadedRecovered?.name == "Legacy (Recovered)")

                #expect(!fm.fileExists(atPath: backupURL.path))
                #expect(fm.fileExists(atPath: backupURL.appendingPathExtension("restored").path))
                let remainingBackups = await MainActor.run { AgentStore.recoverableBackups() }
                #expect(remainingBackups.isEmpty)
            }
        }
    }

    @Test("Numbered non-conflicting backups restore under their original agent id")
    func nonConflictingBackupRestoresOriginalId() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withTemporaryOsaurusRoot(name: "osaurus-personas-recover-orphan") { _ in
                let fm = FileManager.default
                let agents = OsaurusPaths.agents()
                try fm.createDirectory(at: agents, withIntermediateDirectories: true)

                let originalId = UUID()
                let orphan = Agent(
                    id: originalId,
                    name: "Orphan",
                    systemPrompt: "orphan prompt",
                    agentIndex: 11,
                    agentAddress: "0xorphan",
                    order: 3
                )
                let backupURL = agents.appendingPathComponent("\(originalId.uuidString).json.1.bak")
                try seedLoadableAgentJSON(at: backupURL, agent: orphan)

                let backups = await MainActor.run { AgentStore.recoverableBackups() }
                let backup = try #require(backups.first)
                #expect(backups.count == 1)
                #expect(!backup.conflictsWithExistingAgent)

                let restored = try await MainActor.run {
                    try AgentStore.restoreRecoverableBackup(at: backup.url)
                }

                #expect(restored.id == originalId)
                #expect(restored.name == "Orphan")
                #expect(restored.systemPrompt == "orphan prompt")
                #expect(restored.agentIndex == 11)
                #expect(restored.agentAddress == "0xorphan")
                #expect(restored.order == 3)

                let loaded = await MainActor.run { AgentStore.load(id: originalId) }
                #expect(loaded?.name == "Orphan")
                #expect(loaded?.systemPrompt == "orphan prompt")

                #expect(!fm.fileExists(atPath: backupURL.path))
                #expect(fm.fileExists(atPath: backupURL.appendingPathExtension("restored").path))
                let remainingBackups = await MainActor.run { AgentStore.recoverableBackups() }
                #expect(remainingBackups.isEmpty)
            }
        }
    }

    @Test("Conflict restores avoid explicit recovered id collisions")
    func conflictBackupAvoidsRecoveredIdCollision() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withTemporaryOsaurusRoot(name: "osaurus-personas-recover-id-collision") { _ in
                let fm = FileManager.default
                let agents = OsaurusPaths.agents()
                try fm.createDirectory(at: agents, withIntermediateDirectories: true)

                let originalId = UUID()
                let occupiedRecoveredId = UUID()
                try seedLoadableAgentJSON(
                    at: agents.appendingPathComponent("\(originalId.uuidString).json"),
                    agent: Agent(id: originalId, name: "Canonical")
                )
                try seedLoadableAgentJSON(
                    at: agents.appendingPathComponent("\(occupiedRecoveredId.uuidString).json"),
                    agent: Agent(id: occupiedRecoveredId, name: "Occupied")
                )

                let legacy = Agent(
                    id: originalId,
                    name: "Legacy",
                    systemPrompt: "legacy prompt"
                )
                let backupURL = agents.appendingPathComponent("\(originalId.uuidString).json.bak")
                try seedLoadableAgentJSON(at: backupURL, agent: legacy)

                let restored = try await MainActor.run {
                    try AgentStore.restoreRecoverableBackup(
                        at: backupURL,
                        recoveredId: occupiedRecoveredId
                    )
                }

                #expect(restored.id != originalId)
                #expect(restored.id != occupiedRecoveredId)
                #expect(restored.name == "Legacy (Recovered)")
                let occupied = await MainActor.run { AgentStore.load(id: occupiedRecoveredId) }
                #expect(occupied?.name == "Occupied")
                let loadedRecovered = await MainActor.run { AgentStore.load(id: restored.id) }
                #expect(loadedRecovered?.name == "Legacy (Recovered)")
                #expect(!fm.fileExists(atPath: backupURL.path))
                #expect(fm.fileExists(atPath: backupURL.appendingPathExtension("restored").path))
            }
        }
    }

    @Test("Built-in backups are rejected and left untouched")
    func builtInBackupRestoreIsRejected() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withTemporaryOsaurusRoot(name: "osaurus-personas-built-in-backup") { _ in
                let fm = FileManager.default
                let agents = OsaurusPaths.agents()
                try fm.createDirectory(at: agents, withIntermediateDirectories: true)

                let builtIn = Agent(
                    id: Agent.defaultId,
                    name: "Osaurus",
                    isBuiltIn: true,
                    createdAt: Date(timeIntervalSince1970: 0),
                    updatedAt: Date(timeIntervalSince1970: 0)
                )
                let backupURL = agents.appendingPathComponent("\(Agent.defaultId.uuidString).json.bak")
                try seedLoadableAgentJSON(at: backupURL, agent: builtIn)

                do {
                    _ = try await MainActor.run {
                        try AgentStore.restoreRecoverableBackup(at: backupURL)
                    }
                    Issue.record("expected built-in backup restore to fail")
                } catch let error as AgentStore.RecoveryError {
                    #expect(error == .builtInAgent("Osaurus"))
                } catch {
                    Issue.record("unexpected restore error: \(error)")
                }

                #expect(fm.fileExists(atPath: backupURL.path))
                #expect(!fm.fileExists(atPath: backupURL.appendingPathExtension("restored").path))
            }
        }
    }

    @Test("Orphan backups with reused identity keep their id and clear address/index")
    func orphanBackupWithReusedIdentityClearsAddressAndIndex() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withTemporaryOsaurusRoot(name: "osaurus-personas-recover-identity") { _ in
                let fm = FileManager.default
                let agents = OsaurusPaths.agents()
                try fm.createDirectory(at: agents, withIntermediateDirectories: true)

                let existingId = UUID()
                let originalId = UUID()
                let reusedAddress = "0xreused"
                let existing = Agent(
                    id: existingId,
                    name: "Current",
                    agentIndex: 5,
                    agentAddress: reusedAddress
                )
                try seedLoadableAgentJSON(
                    at: agents.appendingPathComponent("\(existingId.uuidString).json"),
                    agent: existing
                )

                let orphan = Agent(
                    id: originalId,
                    name: "Orphan",
                    systemPrompt: "orphan prompt",
                    agentIndex: 5,
                    agentAddress: reusedAddress,
                    customAvatarFilename: "\(originalId.uuidString).png",
                    order: 4
                )
                let backupURL = agents.appendingPathComponent("\(originalId.uuidString).json.bak")
                try seedLoadableAgentJSON(at: backupURL, agent: orphan)

                let backups = await MainActor.run { AgentStore.recoverableBackups() }
                let backup = try #require(backups.first)
                #expect(backups.count == 1)
                #expect(backup.conflictsWithExistingAgent)

                let restored = try await MainActor.run {
                    try AgentStore.restoreRecoverableBackup(
                        at: backup.url,
                        recoveredAt: Date(timeIntervalSince1970: 1_800_000_100)
                    )
                }

                #expect(restored.id == originalId)
                #expect(restored.name == "Orphan")
                #expect(restored.agentIndex == nil)
                #expect(restored.agentAddress == nil)
                #expect(restored.customAvatarFilename == "\(originalId.uuidString).png")
                #expect(restored.order == 4)

                let loaded = await MainActor.run { AgentStore.load(id: originalId) }
                #expect(loaded?.agentIndex == nil)
                #expect(loaded?.agentAddress == nil)

                let stillExisting = await MainActor.run { AgentStore.load(id: existingId) }
                #expect(stillExisting?.agentIndex == 5)
                #expect(stillExisting?.agentAddress == reusedAddress)

                #expect(!fm.fileExists(atPath: backupURL.path))
                #expect(fm.fileExists(atPath: backupURL.appendingPathExtension("restored").path))
            }
        }
    }

    @Test("Failed backup consumption rolls back only the restored agent JSON")
    func restoreConsumeFailureKeepsExistingAgentData() async throws {
        try await StoragePathsTestLock.shared.run {
            try await withTemporaryOsaurusRoot(name: "osaurus-personas-recover-consume-failure") { root in
                let fm = FileManager.default
                let agents = OsaurusPaths.agents()
                try fm.createDirectory(at: agents, withIntermediateDirectories: true)

                let originalId = UUID()
                let agentDirectory = OsaurusPaths.agentDirectory(for: originalId)
                let databaseURL = OsaurusPaths.agentDatabaseFile(for: originalId)
                try fm.createDirectory(
                    at: agentDirectory,
                    withIntermediateDirectories: true
                )
                try Data("existing db".utf8).write(to: databaseURL, options: .atomic)

                let backupDirectory = root.appendingPathComponent(
                    "locked-backups",
                    isDirectory: true
                )
                try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                let backupURL = backupDirectory.appendingPathComponent(
                    "\(originalId.uuidString).json.bak"
                )
                let orphan = Agent(
                    id: originalId,
                    name: "Orphan",
                    systemPrompt: "restore should roll back JSON only"
                )
                try seedLoadableAgentJSON(at: backupURL, agent: orphan)
                try fm.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o555)],
                    ofItemAtPath: backupDirectory.path
                )
                defer {
                    try? fm.setAttributes(
                        [.posixPermissions: NSNumber(value: 0o755)],
                        ofItemAtPath: backupDirectory.path
                    )
                }

                do {
                    _ = try await MainActor.run {
                        try AgentStore.restoreRecoverableBackup(at: backupURL)
                    }
                    Issue.record("expected backup consumption to fail")
                } catch let error as AgentStore.RecoveryError {
                    #expect(error == .backupConsumedFailed(backupURL.lastPathComponent))
                } catch {
                    Issue.record("unexpected restore error: \(error)")
                }

                #expect(fm.fileExists(atPath: backupURL.path))
                #expect(!fm.fileExists(
                    atPath: agents.appendingPathComponent("\(originalId.uuidString).json").path
                ))
                #expect(fm.fileExists(atPath: databaseURL.path))
            }
        }
    }
}
