//
//  SubagentConfigurationStoreTests.swift
//  osaurusTests
//
//  Persistence coverage for the local delegate/image-job settings store.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent delegation configuration store", .serialized)
struct SubagentConfigurationStoreTests {
    @Test("missing file snapshots to defaults")
    func missingFileSnapshotsToDefaults() async throws {
        let lease = await acquireSubagentStoreSandbox("agent-delegation-store")
        defer { lease.release() }

        #expect(SubagentConfigurationStore.load() == nil)
        #expect(SubagentConfigurationStore.snapshot() == .default)
    }

    @Test("save persists and invalidated snapshot reloads")
    func saveWritesAndReloads() async throws {
        let lease = await acquireSubagentStoreSandbox("agent-delegation-store")
        defer { lease.release() }
        let sandbox = lease.sandbox

        let config = SubagentConfiguration(
            localTextDelegationEnabled: true,
            imageDelegationEnabled: true,
            defaultImageGenerationModelId: "  flux  ",
            defaultImageEditModelId: "qwen-edit",
            imageJobLoadPolicy: .unloadImageAfterAgentJob,
            permissionDefaults: SubagentPermissionDefaults(
                policies: ["spawn": .alwaysAllow, "image": .deny]
            ),
            budgets: SubagentBudgets(
                maxDelegateTokens: 100_000,
                maxDelegateTurns: 99,
                maxToolCalls: 99,
                maxElapsedSeconds: 99_999
            )
        )

        SubagentConfigurationStore.save(config)
        SubagentConfigurationStore.flushPendingWrites()

        let file = sandbox.appendingPathComponent("agent-delegation.json")
        #expect(FileManager.default.fileExists(atPath: file.path))

        SubagentConfigurationStore.invalidateSnapshot()
        let reloaded = SubagentConfigurationStore.snapshot()
        #expect(reloaded.localTextDelegationEnabled == true)
        #expect(reloaded.imageDelegationEnabled == true)
        #expect(reloaded.localOrchestratorTextHandoffActive == true)
        #expect(reloaded.imageDelegationActive == true)
        #expect(reloaded.defaultImageGenerationModelId == "flux")
        #expect(reloaded.imageJobLoadPolicy == .unloadImageAfterAgentJob)
        #expect(reloaded.permissionDefaults.policy(for: "spawn") == .alwaysAllow)
        #expect(reloaded.permissionDefaults.policy(for: "image") == .deny)
        #expect(reloaded.budgets.maxDelegateTokens == 32_768)
        #expect(reloaded.budgets.maxDelegateTurns == 8)
        #expect(reloaded.budgets.maxToolCalls == 32)
        #expect(reloaded.budgets.maxElapsedSeconds == 1_800)
    }

    @Test("parallel cold readers materialize one atomic snapshot revision")
    func parallelColdReadersShareOneMaterialization() async throws {
        let lease = await acquireSubagentStoreSandbox(
            "agent-delegation-parallel-cold-read"
        )
        defer { lease.release() }

        let expected = SubagentConfiguration(
            localTextDelegationEnabled: true,
            budgets: SubagentBudgets(maxParallelSpawns: 4),
            spawnableModelNames: ["local/worker"]
        ).normalized
        let file = lease.sandbox.appendingPathComponent(
            "agent-delegation.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(expected).write(to: file, options: .atomic)
        SubagentConfigurationStore.invalidateSnapshot()
        let revisionBeforeRead = SubagentConfigurationStore.revision()

        let readers = 32
        let gate = ColdSnapshotStartGate(expectedArrivals: readers)
        let snapshots = await withTaskGroup(
            of: (SubagentConfiguration, UInt64).self,
            returning: [(SubagentConfiguration, UInt64)].self
        ) { group in
            for _ in 0 ..< readers {
                group.addTask {
                    await gate.arriveAndWait()
                    let snapshot =
                        SubagentConfigurationStore.snapshotWithRevision()
                    return (
                        snapshot.configuration,
                        snapshot.revision
                    )
                }
            }
            var values: [(SubagentConfiguration, UInt64)] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        #expect(snapshots.count == readers)
        #expect(snapshots.allSatisfy { $0.0 == expected })
        #expect(
            snapshots.allSatisfy {
                $0.1 == revisionBeforeRead &+ 1
            }
        )
        #expect(
            SubagentConfigurationStore.revision()
                == revisionBeforeRead &+ 1
        )
    }

    @Test("main-chat spawn policy survives a store reload")
    func mainChatSpawnPolicySurvivesReload() async throws {
        let lease = await acquireSubagentStoreSandbox("main-chat-spawn-policy")
        defer { lease.release() }
        let researcherID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        let coderID = UUID(uuidString: "30000000-0000-4000-8000-000000000002")!

        let config = SubagentConfiguration(
            spawnableAgentIDs: [researcherID, coderID],
            permissionDefaults: SubagentPermissionDefaults(
                policies: [SubagentCapabilityRegistry.spawn.id: .alwaysAllow]
            ),
            budgets: SubagentBudgets(
                maxDelegateTokens: 4096,
                maxDelegateTurns: 4,
                maxToolCalls: 6,
                maxElapsedSeconds: 300,
                maxParallelSpawns: 5
            ),
            subagentModelOverrides: [
                SubagentCapabilityRegistry.spawn.id: "local/orchestrator-helper"
            ],
            spawnableModelNames: [
                "local/fast-helper",
                "openai/frontier-helper",
            ],
            spawnableModelNotes: [
                "local/fast-helper": "Fast local file batches",
                "openai/frontier-helper": "Hard research",
            ],
            spawnToolAccess: .readOnly
        )

        SubagentConfigurationStore.save(config)
        SubagentConfigurationStore.flushPendingWrites()
        SubagentConfigurationStore.invalidateSnapshot()

        let reloaded = SubagentConfigurationStore.snapshot()
        #expect(reloaded.spawnableAgentIDs == [researcherID, coderID])
        #expect(
            reloaded.spawnableModelNames
                == ["local/fast-helper", "openai/frontier-helper"]
        )
        #expect(reloaded.spawnableModelNotes["local/fast-helper"] == "Fast local file batches")
        #expect(reloaded.spawnableModelNotes["openai/frontier-helper"] == "Hard research")
        #expect(
            reloaded.permissionDefaults.policy(for: SubagentCapabilityRegistry.spawn.id)
                == .alwaysAllow
        )
        #expect(reloaded.budgets.maxDelegateTokens == 4096)
        #expect(reloaded.budgets.maxDelegateTurns == 4)
        #expect(reloaded.budgets.maxToolCalls == 6)
        #expect(reloaded.budgets.maxElapsedSeconds == 300)
        #expect(reloaded.budgets.maxParallelSpawns == 5)
        #expect(reloaded.spawnToolAccess == .readOnly)
        #expect(
            reloaded.subagentModelOverrides[SubagentCapabilityRegistry.spawn.id]
                == "local/orchestrator-helper"
        )
    }

    @Test("shared fan-out changes invalidate every launcher authority")
    func sharedFanOutAdvancesSharedAuthority() async {
        let lease = await acquireSubagentStoreSandbox("shared-spawn-fan-out-authority")
        defer { lease.release() }

        SubagentConfigurationStore.save(.default)
        let before = SubagentConfigurationStore.snapshotWithSpawnAuthorityRevisions()
        SubagentConfigurationStore.mutate { configuration in
            configuration.budgets.maxParallelSpawns =
                before.configuration.budgets.maxParallelSpawns + 1
        }
        let after = SubagentConfigurationStore.snapshotWithSpawnAuthorityRevisions()

        #expect(after.spawnSharedRevision == before.spawnSharedRevision &+ 1)
        #expect(after.spawnDefaultRevision == before.spawnDefaultRevision &+ 1)
    }

    @Test("legacy names migrate once, persist UUIDs, and collisions fail closed")
    func legacyNameMigrationPersistsStableIDs() async throws {
        let lease = await acquireSubagentStoreSandbox("legacy-agent-name-migration")
        defer { lease.release() }
        let coderID = UUID(uuidString: "30000000-0000-4000-8000-000000000003")!
        let upperID = UUID(uuidString: "30000000-0000-4000-8000-000000000004")!
        let lowerID = UUID(uuidString: "30000000-0000-4000-8000-000000000005")!
        let file = lease.sandbox.appendingPathComponent("agent-delegation.json")
        try FileManager.default.createDirectory(
            at: lease.sandbox,
            withIntermediateDirectories: true
        )
        try Data(
            #"{"localTextDelegationEnabled":true,"spawnableAgentNames":["Coder","Helper","missing"]}"#
                .utf8
        ).write(to: file, options: .atomic)

        SubagentConfigurationStore.invalidateSnapshot()
        let legacy = SubagentConfigurationStore.snapshot()
        #expect(legacy.spawnableAgentIDs.isEmpty)
        #expect(legacy.legacySpawnableAgentNames == ["Coder", "Helper", "missing"])

        let migrated = SubagentConfigurationStore.migrateLegacyAgentNames(
            using: [
                Agent(id: coderID, name: "Coder"),
                Agent(id: upperID, name: "Helper"),
                Agent(id: lowerID, name: "helper"),
            ]
        )
        #expect(migrated.spawnableAgentIDs == [coderID])
        #expect(migrated.legacySpawnableAgentNames.isEmpty)

        SubagentConfigurationStore.flushPendingWrites()
        SubagentConfigurationStore.invalidateSnapshot()
        let reloaded = SubagentConfigurationStore.snapshot()
        #expect(reloaded.spawnableAgentIDs == [coderID])
        #expect(reloaded.legacySpawnableAgentNames.isEmpty)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        #expect(object["spawnableAgentNames"] == nil)
        #expect((object["spawnableAgentIDs"] as? [String]) == [coderID.uuidString])
    }

    @Test("legacy files decode with safe delegation defaults")
    func legacyFilesDecodeWithSafeDefaults() throws {
        let data = Data(
            """
            {
              "localTextDelegationEnabled": true,
              "defaultImageGenerationModelId": "flux"
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(SubagentConfiguration.self, from: data)

        #expect(decoded.localTextDelegationEnabled == true)
        #expect(decoded.imageDelegationEnabled == false)
        // No master switch: the handoff is active whenever its own toggle is on.
        #expect(decoded.localOrchestratorTextHandoffActive == true)
        // The main chat's image switch is off here, so image stays inactive.
        #expect(decoded.imageDelegationActive == false)
        #expect(decoded.defaultImageGenerationModelId == "flux")
    }

    @Test("external notification hydration is a no-op store commit")
    func externalHydrationDoesNotEchoSave() async {
        let lease = await acquireSubagentStoreSandbox(
            "agent-delegation-editor-hydration"
        )
        defer { lease.release() }

        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(
            .ask,
            for: SubagentCapabilityRegistry.spawn.id
        )
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                permissionDefaults: permissions,
                budgets: SubagentBudgets(maxParallelSpawns: 2)
            )
        )
        let loadedBaseline = SubagentConfigurationStore.snapshot()

        let latest = SubagentConfigurationStore.mutate { live in
            live.permissionDefaults.setPolicy(
                .alwaysAllow,
                for: SubagentCapabilityRegistry.spawn.id
            )
        }
        let reconciled = SubagentConfiguration.mergingEditorSnapshot(
            loadedBaseline,
            loadedBaseline: loadedBaseline,
            live: latest
        )
        #expect(reconciled == latest)

        // SwiftUI's notification assignment triggers its onChange handler.
        // Saving that already-hydrated value against the new baseline must not
        // publish another revision/notification/write.
        let revisionBeforeHydrationSave = SubagentConfigurationStore.revision()
        let canonical = SubagentConfigurationStore.saveEditorSnapshot(
            reconciled,
            loadedBaseline: latest
        )
        #expect(canonical == latest)
        #expect(
            SubagentConfigurationStore.revision()
                == revisionBeforeHydrationSave
        )
    }

    @Test("stale global editor cannot erase concurrent Always Allow")
    func staleEditorPreservesConcurrentAlwaysAllow() async {
        let lease = await acquireSubagentStoreSandbox(
            "agent-delegation-editor-always-allow"
        )
        defer { lease.release() }

        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(
            .ask,
            for: SubagentCapabilityRegistry.spawn.id
        )
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                permissionDefaults: permissions,
                budgets: SubagentBudgets(maxParallelSpawns: 2)
            )
        )
        let loadedBaseline = SubagentConfigurationStore.snapshot()
        var staleEditor = loadedBaseline
        staleEditor.budgets = SubagentBudgets(maxParallelSpawns: 5)

        SubagentConfigurationStore.mutate { live in
            live.permissionDefaults.setPolicy(
                .alwaysAllow,
                for: SubagentCapabilityRegistry.spawn.id
            )
        }
        let saved = SubagentConfigurationStore.saveEditorSnapshot(
            staleEditor,
            loadedBaseline: loadedBaseline
        )
        #expect(saved.budgets.maxParallelSpawns == 5)
        #expect(
            saved.permissionDefaults.policy(
                for: SubagentCapabilityRegistry.spawn.id
            ) == .alwaysAllow
        )

        SubagentConfigurationStore.flushPendingWrites()
        SubagentConfigurationStore.invalidateSnapshot()
        let reloaded = SubagentConfigurationStore.snapshot()
        #expect(reloaded.budgets.maxParallelSpawns == 5)
        #expect(
            reloaded.permissionDefaults.policy(
                for: SubagentCapabilityRegistry.spawn.id
            ) == .alwaysAllow
        )
    }

    @Test("override directory swaps between sandboxes")
    func overrideDirectorySwapsBetweenSandboxes() async throws {
        // `lease.sandbox` is the first override; `lease.release()` resets
        // the global override to nil and removes it. The second dir is
        // managed locally.
        let lease = await acquireSubagentStoreSandbox("agent-delegation-store-first")
        let first = lease.sandbox
        let second = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: second)
            lease.release()
        }

        SubagentConfigurationStore.save(
            SubagentConfiguration(defaultImageGenerationModelId: "first")
        )
        SubagentConfigurationStore.flushPendingWrites()

        SubagentConfigurationStore.setOverrideDirectory(second)
        SubagentConfigurationStore.save(
            SubagentConfiguration(defaultImageGenerationModelId: "second")
        )
        SubagentConfigurationStore.flushPendingWrites()

        let firstData = try Data(contentsOf: first.appendingPathComponent("agent-delegation.json"))
        let secondData = try Data(contentsOf: second.appendingPathComponent("agent-delegation.json"))
        let firstDecoded = try JSONDecoder().decode(SubagentConfiguration.self, from: firstData)
        let secondDecoded = try JSONDecoder().decode(SubagentConfiguration.self, from: secondData)

        #expect(firstDecoded.defaultImageGenerationModelId == "first")
        #expect(secondDecoded.defaultImageGenerationModelId == "second")
    }

    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-agent-delegation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor ColdSnapshotStartGate {
    private let expectedArrivals: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expectedArrivals: Int) {
        self.expectedArrivals = expectedArrivals
    }

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == expectedArrivals {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
