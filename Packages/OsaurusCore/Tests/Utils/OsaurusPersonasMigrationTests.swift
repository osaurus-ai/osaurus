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
            try seedAgentJSON(at: agents.appendingPathComponent("\(id).json"), id: id, name: "Canonical")

            let legacy = root.appendingPathComponent("Personas", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            try seedAgentJSON(at: legacy.appendingPathComponent("\(id).json"), id: id, name: "Legacy")

            let result = OsaurusPaths.migrateLegacyPersonasIfNeeded()
            #expect(result == .migrated(moved: 0, conflicts: 1))

            // Canonical copy is untouched.
            let canonical = try JSONDecoder().decode(
                Agent.self,
                from: Data(contentsOf: agents.appendingPathComponent("\(id).json"))
            )
            #expect(canonical.name == "Canonical")

            // Legacy copy preserved as a `.bak` sibling (ignored by loadAll).
            let backup = agents.appendingPathComponent("\(id).json.bak")
            #expect(fm.fileExists(atPath: backup.path))
            let backed = try JSONDecoder().decode(Agent.self, from: Data(contentsOf: backup))
            #expect(backed.name == "Legacy")

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
}
