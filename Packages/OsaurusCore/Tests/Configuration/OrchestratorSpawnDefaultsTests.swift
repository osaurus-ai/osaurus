//
//  OrchestratorSpawnDefaultsTests.swift
//  OsaurusCoreTests
//
//  Pins the orchestrator-first spawn defaults:
//
//  1. Every custom agent joins the DEFAULT / main-chat spawn pool on
//     creation (`AgentManager.registerInDefaultSpawnPool`, reached from
//     add/create, config apply, duplicate, bundle import, and backup
//     restore), and deleting the agent prunes the pool.
//  2. A config apply that grows the live chat conversation's spawn pool
//     stages constrained `spawn_agent` / `spawn_batch` specs into
//     `CapabilityLoadBuffer` — `osaurus_config` is an activation trigger, so
//     the loop offers the tools in the SAME turn and the orchestrator can
//     run a just-created agent without waiting for the next user message.
//  3. Existing installs are seeded once (`spawnPoolSeeded`): every current
//     custom agent joins the pool exactly one time, so a user's later
//     removal persists across restarts and refreshes.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Spawn pool auto-add / prune

@Suite(.serialized)
@MainActor
struct SpawnPoolAutoAddTests {

    @Test("agents apply adds the new agent to the Default spawn pool; delete prunes it")
    func agentsApply_addsToSpawnPool_deleteRemoves() async throws {
        // Cross-suite lock: delegation suites sandbox the same store via
        // `SubagentConfigurationStore.setOverrideDirectory`; mutating the
        // live store while a sandbox lease is active races both sides.
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }

        let name = "Spawn Pool Probe \(UUID().uuidString.prefix(6))"
        var document = OsaurusConfigDocument()
        document.agents = [AgentEntry(name: name)]
        let results = await ConfigApplier.apply(document: document, prune: false)
        #expect(results.allSatisfy { $0.status != .failed }, "\(results)")

        guard let created = AgentManager.shared.agents.first(where: { $0.name == name }) else {
            Issue.record("agent `\(name)` was not created")
            return
        }
        #expect(
            SubagentConfigurationStore.snapshot().spawnableAgentIDs.contains(created.id),
            "a newly created agent must join the Default agent's spawn pool")
        // The create result must tell the orchestrator it can act NOW.
        let createResult = results.first { $0.section == "agents" && $0.target == name }
        #expect(
            createResult?.message?.contains("spawn_agent") == true,
            "create result must point at spawn_agent: \(String(describing: createResult))")

        // Re-applying the same document updates (not re-creates) the agent
        // and must not duplicate the pool entry.
        _ = await ConfigApplier.apply(document: document, prune: false)
        let occurrences = SubagentConfigurationStore.snapshot().spawnableAgentIDs
            .filter { $0 == created.id }.count
        #expect(occurrences == 1, "pool must not accumulate duplicates")

        _ = await AgentManager.shared.delete(id: created.id)
        #expect(
            !SubagentConfigurationStore.snapshot().spawnableAgentIDs.contains(created.id),
            "deleting an agent must prune it from the Default spawn pool")
    }

    @Test("AgentManager.create auto-adds; built-ins are excluded; the append is idempotent")
    func managerCreate_addsToPool_builtInsExcluded() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }

        let agent = AgentManager.shared.create(
            name: "Pool Create Probe \(UUID().uuidString.prefix(6))",
            description: "", systemPrompt: "")
        #expect(
            SubagentConfigurationStore.snapshot().spawnableAgentIDs.contains(agent.id),
            "AgentManager.create must auto-add the agent to the Default spawn pool")

        // Duplicate / import / restore reach the same hook — it must be
        // idempotent so no path can double-append.
        AgentManager.shared.registerInDefaultSpawnPool(agent)
        let occurrences = SubagentConfigurationStore.snapshot().spawnableAgentIDs
            .filter { $0 == agent.id }.count
        #expect(occurrences == 1, "repeat registration must not duplicate the pool entry")

        // A built-in agent never joins the pool (it would let the Default
        // agent spawn itself).
        let builtIn = Agent(name: "Built-in Probe", isBuiltIn: true)
        AgentManager.shared.registerInDefaultSpawnPool(builtIn)
        #expect(
            !SubagentConfigurationStore.snapshot().spawnableAgentIDs.contains(builtIn.id),
            "built-in agents must not join the spawn pool")

        _ = await AgentManager.shared.delete(id: agent.id)
        #expect(
            !SubagentConfigurationStore.snapshot().spawnableAgentIDs.contains(agent.id))
    }

    @Test("duplicate, bundle import, and backup restore are wired to the pool hook")
    func creationBypassPaths_callTheSpawnPoolHook() throws {
        // These creation paths save via `AgentStore.save` directly (never
        // `AgentManager.add`), so each callsite must invoke the hook itself.
        // Source pin, matching the repo's wiring-guard style — a hook nobody
        // calls is how default-on silently regresses.
        func source(_ relativePath: String) throws -> String {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // Configuration/
                .deletingLastPathComponent()  // Tests/
                .deletingLastPathComponent()  // OsaurusCore/
            return try String(
                contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
        }
        let agentsView = try source("Views/Agent/AgentsView.swift")
        #expect(
            agentsView.contains("registerInDefaultSpawnPool(duplicated)"),
            "duplicateAgent must register the copy in the Default spawn pool")
        let bundleService = try source("Services/AgentBridge/AgentBundleService.swift")
        #expect(
            bundleService.contains("registerInDefaultSpawnPool(agent)"),
            "bundle-import activate must register the imported agent")
        let manager = try source("Managers/AgentManager.swift")
        #expect(
            manager.contains("registerInDefaultSpawnPool(restored)"),
            "restoreRecoverableAgentBackup must register the restored agent")
    }
}

// MARK: - Same-turn spawn activation

@Suite(.serialized)
@MainActor
struct SameTurnSpawnStagingTests {

    private static func agentEnum(of tool: Tool) -> [String] {
        guard case .object(let root)? = tool.function.parameters,
            case .object(let properties)? = root["properties"],
            case .object(let agent)? = properties["agent"],
            case .array(let values)? = agent["enum"]
        else { return [] }
        return values.compactMap {
            if case .string(let value) = $0 { return value }
            return nil
        }
    }

    @Test("osaurus_config is an activation trigger for the buffer-drain growth path")
    func osaurusConfigTriggersActivation() {
        #expect(CapabilityLoadBuffer.shouldActivate(after: "osaurus_config"))
    }

    @Test("a chat-turn apply that creates an agent stages constrained spawn specs")
    func chatApply_stagesSpawnSpecs_sameTurn() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }

        try await ChatHistoryTestStorage.run {
            let buffer = CapabilityLoadBuffer()
            let name = "Same Turn Spawn \(UUID().uuidString.prefix(6))"
            var document = OsaurusConfigDocument()
            document.agents = [AgentEntry(name: name)]

            let session = ChatSession()
            session.agentId = Agent.defaultId

            // Bind the task locals exactly like a live orchestrator turn:
            // the session box identifies the conversation, the buffer
            // override isolates this suite from the process-global buffer.
            let results = await CapabilityLoadBuffer.$overrideForTests.withValue(buffer) {
                await ChatExecutionContext.$currentChatSessionBox.withValue(
                    WeakChatSessionBox(session)
                ) {
                    await ConfigApplier.apply(document: document, prune: false)
                }
            }
            #expect(results.allSatisfy { $0.status != .failed }, "\(results)")

            guard let created = AgentManager.shared.agents.first(where: { $0.name == name })
            else {
                Issue.record("agent `\(name)` was not created")
                return
            }
            defer { Task { _ = await AgentManager.shared.delete(id: created.id) } }

            let staged = await buffer.drain()
            let names = staged.map { $0.function.name }
            #expect(
                names.contains(SubagentCapabilityRegistry.spawnAgentToolName),
                "spawn_agent must be staged for the same turn, got \(names)")
            #expect(
                names.contains(SubagentCapabilityRegistry.spawnBatchToolName),
                "spawn_batch must be staged alongside spawn_agent, got \(names)")

            // The staged schema must already advertise the just-created
            // agent (UUID + display name) — execution validates against the
            // live pool, but a strict enum-enforcing provider needs the
            // identity in the schema.
            if let spawnAgent = staged.first(
                where: { $0.function.name == SubagentCapabilityRegistry.spawnAgentToolName })
            {
                let enumValues = Self.agentEnum(of: spawnAgent)
                #expect(enumValues.contains(created.id.uuidString), "\(enumValues)")
                #expect(enumValues.contains(name), "\(enumValues)")
            }

            // Mirror of the loop's growth path (`toolScope.activate(newTools)`
            // after an activation-trigger tool): the staged specs both
            // authorize and publish for the next iteration.
            let scope = ToolExecutionScope(exposed: [])
            #expect(!scope.permits(SubagentCapabilityRegistry.spawnAgentToolName))
            scope.activate(staged)
            #expect(scope.permits(SubagentCapabilityRegistry.spawnAgentToolName))
            #expect(
                scope.modelVisibleSpecs.map { $0.function.name }
                    .contains(SubagentCapabilityRegistry.spawnAgentToolName))
        }
    }

    @Test("non-chat applies stage nothing")
    func nonChatApply_stagesNothing() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }

        try await ChatHistoryTestStorage.run {
            let buffer = CapabilityLoadBuffer()
            let name = "Headless Spawn \(UUID().uuidString.prefix(6))"
            var document = OsaurusConfigDocument()
            document.agents = [AgentEntry(name: name)]

            // HTTP-sourced session bound: still not a live interactive chat
            // turn, so nothing is staged (CLI/HTTP/delegation surfaces
            // compose fresh anyway).
            let session = ChatSession()
            session.agentId = Agent.defaultId
            session.source = .http

            let results = await CapabilityLoadBuffer.$overrideForTests.withValue(buffer) {
                await ChatExecutionContext.$currentChatSessionBox.withValue(
                    WeakChatSessionBox(session)
                ) {
                    await ConfigApplier.apply(document: document, prune: false)
                }
            }
            #expect(results.allSatisfy { $0.status != .failed }, "\(results)")
            if let created = AgentManager.shared.agents.first(where: { $0.name == name }) {
                _ = await AgentManager.shared.delete(id: created.id)
            }

            let staged = await buffer.drain()
            #expect(staged.isEmpty, "non-chat applies must not stage spawn specs: \(staged)")
        }
    }

    @Test("a chat-turn apply that does not grow the pool stages nothing")
    func chatApply_withoutPoolGrowth_stagesNothing() async throws {
        await SubagentStoreTestLock.shared.acquire()
        defer { SubagentStoreTestLock.shared.release() }

        try await ChatHistoryTestStorage.run {
            let buffer = CapabilityLoadBuffer()
            // A memory-only change: no agents section, pool untouched.
            var document = OsaurusConfigDocument()
            var memory = MemorySection()
            memory.enabled = MemoryConfigurationStore.load().enabled
            document.memory = memory

            let session = ChatSession()
            session.agentId = Agent.defaultId

            let results = await CapabilityLoadBuffer.$overrideForTests.withValue(buffer) {
                await ChatExecutionContext.$currentChatSessionBox.withValue(
                    WeakChatSessionBox(session)
                ) {
                    await ConfigApplier.apply(document: document, prune: false)
                }
            }
            #expect(results.allSatisfy { $0.status != .failed }, "\(results)")

            let staged = await buffer.drain()
            #expect(staged.isEmpty, "a no-growth apply must not stage spawn specs: \(staged)")
        }
    }
}

// MARK: - One-time seed migration

@Suite(.serialized)
@MainActor
struct SpawnPoolSeedMigrationTests {

    @Test("existing custom agents are seeded exactly once; removals persist")
    func seedRunsOnce_andRemovalsPersist() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-pool-seed")
        defer { lease.release() }

        // A pre-sentinel install: default config, unseeded.
        SubagentConfigurationStore.save(SubagentConfiguration())
        #expect(!SubagentConfigurationStore.snapshot().spawnPoolSeeded)

        let custom1 = Agent(name: "Seed A")
        let custom2 = Agent(name: "Seed B")
        let builtIn = Agent(name: "Seed Built-in", isBuiltIn: true)

        _ = SubagentConfigurationStore.seedSpawnPoolIfNeeded(
            with: [custom1, builtIn, custom2])
        var snapshot = SubagentConfigurationStore.snapshot()
        #expect(snapshot.spawnPoolSeeded)
        #expect(snapshot.spawnableAgentIDs == [custom1.id, custom2.id])

        // The user removes one agent from the pool (the Settings chips).
        _ = SubagentConfigurationStore.mutate { config in
            config.spawnableAgentIDs.removeAll { $0 == custom1.id }
        }

        // Later refreshes re-run the seed hook with the same agents — the
        // sentinel must keep it inert so the removal persists. An empty pool
        // is likewise NOT an "unseeded" signal.
        _ = SubagentConfigurationStore.seedSpawnPoolIfNeeded(
            with: [custom1, builtIn, custom2])
        snapshot = SubagentConfigurationStore.snapshot()
        #expect(
            !snapshot.spawnableAgentIDs.contains(custom1.id),
            "seeding must never re-add an agent the user removed")
        #expect(snapshot.spawnableAgentIDs == [custom2.id])
    }

    @Test("the sentinel survives persistence, normalization, and delegation applies")
    func sentinelSurvivesRoundTrips() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-pool-seed-roundtrip")
        defer { lease.release() }

        // Pre-sentinel JSON decodes as unseeded (that IS the migration
        // trigger)…
        let legacy = try JSONDecoder().decode(
            SubagentConfiguration.self,
            from: Data("{}".utf8))
        #expect(!legacy.spawnPoolSeeded)

        // …and a seeded config keeps the flag through encode/decode and
        // `normalized`.
        var seeded = SubagentConfiguration()
        seeded.spawnPoolSeeded = true
        #expect(seeded.normalized.spawnPoolSeeded)
        let decoded = try JSONDecoder().decode(
            SubagentConfiguration.self,
            from: JSONEncoder().encode(seeded))
        #expect(decoded.spawnPoolSeeded)

        // A delegation-section apply (the export/apply round-trip path)
        // mutates named fields only — it must not reset the sentinel or
        // touch the pool when the document doesn't name it.
        SubagentConfigurationStore.save(seeded)
        var document = OsaurusConfigDocument()
        var delegation = DelegationSection()
        delegation.budgetMaxTurns = 3
        document.delegation = delegation
        let results = await ConfigApplier.apply(document: document, prune: false)
        #expect(results.allSatisfy { $0.status != .failed }, "\(results)")
        let snapshot = SubagentConfigurationStore.snapshot()
        #expect(snapshot.spawnPoolSeeded, "a delegation apply must not reset the seed sentinel")
        #expect(snapshot.budgets.maxDelegateTurns == 3)

        // A stale settings editor (loaded before seeding) saving an
        // unrelated change must not revert the sentinel either.
        var staleBaseline = SubagentConfiguration()
        staleBaseline.spawnPoolSeeded = false
        var editor = staleBaseline
        editor.imageDelegationEnabled = true
        let merged = SubagentConfigurationStore.saveEditorSnapshot(
            editor, loadedBaseline: staleBaseline)
        #expect(merged.spawnPoolSeeded, "an editor save must not revert the seed sentinel")
        #expect(merged.imageDelegationEnabled)
    }

    @Test("delegation export/apply round-trip is a no-op after seeding")
    func exportApplyRoundTrip_isNoOp() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-pool-export-roundtrip")
        defer { lease.release() }

        // A seeded install with one custom agent in the pool (create
        // auto-adds it; the sentinel is what a real seeded install carries).
        let agent = AgentManager.shared.create(
            name: "Export Roundtrip \(UUID().uuidString.prefix(6))",
            description: "", systemPrompt: "")
        _ = SubagentConfigurationStore.mutate { $0.spawnPoolSeeded = true }
        let before = SubagentConfigurationStore.snapshot()
        #expect(before.spawnableAgentIDs.contains(agent.id))

        // Export names the pool by agent display name; re-applying the
        // exported document must resolve back to the identical pool and
        // leave the sentinel intact — otherwise backup/restore flows would
        // re-trigger seeding and resurrect user removals.
        let exported = ConfigExporter.export(sections: [.delegation])
        let results = await ConfigApplier.apply(document: exported, prune: false)
        #expect(results.allSatisfy { $0.status != .failed }, "\(results)")

        let after = SubagentConfigurationStore.snapshot()
        #expect(after.spawnableAgentIDs == before.spawnableAgentIDs)
        #expect(after.spawnPoolSeeded, "round-trip must not reset the seed sentinel")

        _ = await AgentManager.shared.delete(id: agent.id)
    }
}
