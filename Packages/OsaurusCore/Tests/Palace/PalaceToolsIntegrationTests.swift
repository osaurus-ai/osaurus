//
//  PalaceToolsIntegrationTests.swift
//  osaurusTests
//
//  End-to-end tool round-trip against a temp OsaurusPaths root:
//  enable palace.json → palace_add_drawer → palace_search → palace_get_drawer,
//  plus the disabled-flag envelope and the composer strip set.
//  Uses embeddingBackend "none" so no model download is needed in CI —
//  the search path exercised here is FTS5.
//

import Foundation
import Testing
import os

@testable import OsaurusCore

@Suite(.serialized)
struct PalaceToolsIntegrationTests {

    /// Runs `body` against an isolated OsaurusPaths root with palace
    /// enabled (embeddingBackend "none") and a fresh PalaceDatabase.shared
    /// state. `overrideRoot` is process-global — take the cross-suite lock.
    private func withEnabledPalace(_ body: @Sendable () async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "palace-integration-\(UUID().uuidString)",
                    isDirectory: true
                )
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            PalaceConfigurationStore.invalidateCache()
            var config = PalaceConfiguration()
            config.enabled = true
            config.embeddingBackend = "none"
            PalaceConfigurationStore.save(config)
            defer {
                PalaceDatabase.shared.close()
                OsaurusPaths.overrideRoot = previousRoot
                PalaceConfigurationStore.invalidateCache()
                try? FileManager.default.removeItem(at: root)
            }
            try await body()
        }
    }

    private func decodeEnvelope(_ json: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return (obj as? [String: Any]) ?? [:]
    }

    @Test func disabled_flag_returns_unavailable_and_creates_nothing() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("palace-disabled-\(UUID().uuidString)", isDirectory: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            PalaceConfigurationStore.invalidateCache()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                PalaceConfigurationStore.invalidateCache()
                try? FileManager.default.removeItem(at: root)
            }

            let result = try await PalaceAddDrawerTool().execute(
                argumentsJSON: #"{"content": "should not land"}"#
            )
            let envelope = try decodeEnvelope(result)
            #expect(envelope["ok"] as? Bool == false)
            // Nothing was created on disk — a disabled palace does zero work.
            #expect(
                !FileManager.default.fileExists(atPath: OsaurusPaths.palaceDatabaseFile().path)
            )
        }
    }

    @Test func add_search_get_roundTrip() async throws {
        try await withEnabledPalace {
            let addResult = try await PalaceAddDrawerTool().execute(
                argumentsJSON:
                    #"{"content": "The verbatim GraphQL federation decision from March.", "wing": "test_project", "room": "decisions"}"#
            )
            let addEnvelope = try decodeEnvelope(addResult)
            #expect(addEnvelope["ok"] as? Bool == true)
            let drawerId =
                ((addEnvelope["result"] as? [String: Any])?["drawer_id"] as? String) ?? ""
            #expect(!drawerId.isEmpty)

            // Search finds it (FTS path), scoped and unscoped.
            for argsJSON in [
                #"{"query": "graphql federation"}"#,
                #"{"query": "graphql federation", "wing": "test_project", "room": "decisions"}"#,
            ] {
                let searchResult = try await PalaceSearchTool().execute(argumentsJSON: argsJSON)
                let searchEnvelope = try decodeEnvelope(searchResult)
                #expect(searchEnvelope["ok"] as? Bool == true)
                let hits =
                    ((searchEnvelope["result"] as? [String: Any])?["hits"] as? [[String: Any]])
                    ?? []
                #expect(hits.count == 1)
                #expect(hits.first?["drawer_id"] as? String == drawerId)
            }

            // Get returns the full verbatim content.
            let getResult = try await PalaceGetDrawerTool().execute(
                argumentsJSON: #"{"drawer_id": "\#(drawerId)"}"#
            )
            let getEnvelope = try decodeEnvelope(getResult)
            #expect(getEnvelope["ok"] as? Bool == true)
            let content = ((getEnvelope["result"] as? [String: Any])?["content"] as? String) ?? ""
            #expect(content == "The verbatim GraphQL federation decision from March.")

            // Dedup: identical re-add returns the same drawer, deduped=true.
            let dupResult = try await PalaceAddDrawerTool().execute(
                argumentsJSON:
                    #"{"content": "The verbatim GraphQL federation decision from March.", "wing": "test_project", "room": "decisions"}"#
            )
            let dupEnvelope = try decodeEnvelope(dupResult)
            let dup = (dupEnvelope["result"] as? [String: Any]) ?? [:]
            #expect(dup["deduped"] as? Bool == true)
            #expect(dup["drawer_id"] as? String == drawerId)

            // Status reflects one drawer.
            let statusResult = try await PalaceStatusTool().execute(argumentsJSON: "{}")
            let statusEnvelope = try decodeEnvelope(statusResult)
            let status = (statusEnvelope["result"] as? [String: Any]) ?? [:]
            #expect(status["drawers"] as? Int == 1)
            #expect(status["wings"] as? Int == 1)
        }
    }

    @Test func update_delete_roundTrip() async throws {
        try await withEnabledPalace {
            let addResult = try await PalaceAddDrawerTool().execute(
                argumentsJSON: #"{"content": "original wording"}"#
            )
            let drawerId =
                (((try decodeEnvelope(addResult))["result"] as? [String: Any])?["drawer_id"]
                    as? String) ?? ""
            #expect(!drawerId.isEmpty)

            let updateResult = try await PalaceUpdateDrawerTool().execute(
                argumentsJSON: #"{"drawer_id": "\#(drawerId)", "content": "revised wording"}"#
            )
            #expect((try decodeEnvelope(updateResult))["ok"] as? Bool == true)

            let getResult = try await PalaceGetDrawerTool().execute(
                argumentsJSON: #"{"drawer_id": "\#(drawerId)"}"#
            )
            let content =
                (((try decodeEnvelope(getResult))["result"] as? [String: Any])?["content"]
                    as? String) ?? ""
            #expect(content == "revised wording")

            let deleteResult = try await PalaceDeleteDrawerTool().execute(
                argumentsJSON: #"{"drawer_id": "\#(drawerId)"}"#
            )
            #expect((try decodeEnvelope(deleteResult))["ok"] as? Bool == true)

            // Second delete → not_found envelope.
            let secondDelete = try await PalaceDeleteDrawerTool().execute(
                argumentsJSON: #"{"drawer_id": "\#(drawerId)"}"#
            )
            #expect((try decodeEnvelope(secondDelete))["ok"] as? Bool == false)
        }
    }

    @Test func composer_strip_set_matches_registered_tool_names() {
        // The strip set and the registered tool names must stay in lockstep;
        // a palace tool missing from `palaceToolNames` would leak into the
        // schema while the flag is off.
        let registered: Set<String> = [
            PalaceStatusTool().name, PalaceSearchTool().name, PalaceAddDrawerTool().name,
            PalaceGetDrawerTool().name, PalaceUpdateDrawerTool().name,
            PalaceDeleteDrawerTool().name, PalaceListWingsTool().name,
            PalaceListRoomsTool().name, PalaceListDrawersTool().name,
        ]
        #expect(registered == SystemPromptComposer.palaceToolNames)
    }

    /// No-Memory-v2-regression guard: with palace enabled and used, the
    /// memory database file is untouched (Palace never opens or writes it).
    @Test func palace_usage_does_not_touch_memory_database() async throws {
        try await withEnabledPalace {
            _ = try await PalaceAddDrawerTool().execute(
                argumentsJSON: #"{"content": "palace-only write"}"#
            )
            #expect(FileManager.default.fileExists(atPath: OsaurusPaths.palaceDatabaseFile().path))
            #expect(
                !FileManager.default.fileExists(atPath: OsaurusPaths.memoryDatabaseFile().path)
            )
        }
    }

    /// The storage catalog must list palace.sqlite only when it exists:
    /// `StorageExportService.rekeyDatabase` has no missing-file guard, so an
    /// unconditional entry would abort key rotation for every default
    /// (palace-disabled) install with at-rest encryption enabled.
    @Test func catalog_lists_palace_only_when_file_exists() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("palace-catalog-\(UUID().uuidString)", isDirectory: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                try? FileManager.default.removeItem(at: root)
            }

            let before = StorageDatabaseCatalog.databaseTargets()
            #expect(!before.contains { $0.label == "palace" })

            let dbURL = OsaurusPaths.palaceDatabaseFile()
            try OsaurusPaths.ensureExists(dbURL.deletingLastPathComponent())
            try Data().write(to: dbURL)
            let after = StorageDatabaseCatalog.databaseTargets()
            #expect(after.contains { $0.label == "palace" })
        }
    }

    /// Updating a drawer whose re-embed fails must DROP the old vector —
    /// a stale embedding would keep answering semantic queries with the
    /// drawer's previous meaning.
    @Test func update_dropsStaleEmbedding_whenReembedFails() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("palace-stale-embed-\(UUID().uuidString)", isDirectory: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            PalaceConfigurationStore.invalidateCache()
            var config = PalaceConfiguration()
            config.enabled = true
            config.embeddingBackend = "mlx"  // embedder IS invoked
            PalaceConfigurationStore.save(config)
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                PalaceConfigurationStore.invalidateCache()
                try? FileManager.default.removeItem(at: root)
            }

            struct FakeEmbedderFailure: Error {}
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let db = PalaceDatabase()
            try db.openInMemory()
            let service = PalaceService(
                db: db,
                embedder: { texts in
                    let call = calls.withLock { count -> Int in
                        count += 1
                        return count
                    }
                    guard call == 1 else { throw FakeEmbedderFailure() }
                    return texts.map { _ in [0.1, 0.2] }
                }
            )

            let added = try await service.addDrawer(
                content: "cats purr when content",
                wing: nil,
                room: nil
            )
            #expect(added.embedded)
            #expect(try db.loadEmbeddings(wingId: nil, roomId: nil).count == 1)

            // Second embed call throws → the OLD vector must be gone.
            _ = try await service.updateDrawer(id: added.drawer.id, content: "2026 tax notes")
            #expect(try db.loadEmbeddings(wingId: nil, roomId: nil).isEmpty)
        }
    }

    /// Concurrent identical adds collapse to exactly one drawer, and every
    /// caller gets that same drawer id — the actor serializes the check +
    /// insert, and the DB UNIQUE constraint is the authority behind it.
    @Test func concurrent_identical_adds_collapse_to_one_drawer() async throws {
        try await StoragePathsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("palace-race-\(UUID().uuidString)", isDirectory: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            PalaceConfigurationStore.invalidateCache()
            var config = PalaceConfiguration()
            config.enabled = true
            config.embeddingBackend = "none"  // FTS-only; no model needed
            PalaceConfigurationStore.save(config)
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                PalaceConfigurationStore.invalidateCache()
                try? FileManager.default.removeItem(at: root)
            }

            let db = PalaceDatabase()
            try db.openInMemory()
            let service = PalaceService(db: db, embedder: nil)

            let results = try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0 ..< 24 {
                    group.addTask {
                        let r = try await service.addDrawer(
                            content: "the exact same verbatim line",
                            wing: "race",
                            room: "general"
                        )
                        return r.drawer.id
                    }
                }
                var ids: [String] = []
                for try await id in group { ids.append(id) }
                return ids
            }

            #expect(results.count == 24)
            #expect(Set(results).count == 1)  // all callers saw the same winner
            #expect(try db.countDrawers() == 1)
        }
    }
}
