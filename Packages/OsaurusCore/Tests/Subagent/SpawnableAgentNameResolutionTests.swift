//
//  SpawnableAgentNameResolutionTests.swift
//  OsaurusCoreTests
//
//  A custom agent's launcher can address a spawnable agent by its display
//  NAME, not just its UUID (issue #2408): small local models reliably echo a
//  name but not an opaque UUID. Resolution stays scoped to the launcher's own
//  allow-list, so it never widens authorization.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SpawnableAgentNameResolutionTests {
    /// Isolate the agent store under a throwaway root for one closure, then
    /// restore. Mirrors `SpawnPermissionGateTests`' storage isolation.
    @MainActor
    private static func withIsolatedStore(
        _ body: @MainActor @Sendable () async throws -> Void
    ) async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "osaurus-spawn-name-resolution-\(UUID().uuidString)",
                    isDirectory: true
                )
            try? FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }
            try await body()
        }
    }

    /// Persist a launcher whose spawnable allow-list is `targetIDs` and return
    /// its scope.
    @MainActor
    private static func makeLauncher(targetIDs: [UUID]) -> SubagentScope {
        var launcher = Agent(
            name: "Article Writer", description: "launcher", systemPrompt: "stable",
            autonomousExec: AutonomousExecConfig(enabled: false))
        launcher.settings.spawnDelegationEnabled = true
        launcher.settings.spawnableAgentIDs = targetIDs
        AgentStore.save(launcher)
        AgentManager.shared.refresh()
        return SubagentScope(sessionId: "s", toolCallId: "t", agentId: launcher.id)
    }

    @MainActor
    @Test("a display name resolves to its allow-listed spawnable agent id")
    func nameResolvesToAllowListedId() async throws {
        try await Self.withIsolatedStore {
            let cleaner = Agent(
                name: "Transcript Cleaner", description: "cleans", systemPrompt: "x",
                autonomousExec: AutonomousExecConfig(enabled: false))
            AgentStore.save(cleaner)
            AgentManager.shared.refresh()
            let scope = Self.makeLauncher(targetIDs: [cleaner.id])

            // Exact and case-insensitive names both resolve to the UUID.
            let exact = await SubagentToolVisibility.resolveSpawnableAgentName(
                "Transcript Cleaner", scope: scope)
            #expect(exact.id == cleaner.id)
            let cased = await SubagentToolVisibility.resolveSpawnableAgentName(
                "transcript cleaner", scope: scope)
            #expect(cased.id == cleaner.id)
        }
    }

    @MainActor
    @Test("an unknown name resolves to nil and surfaces the valid names")
    func unknownNameSurfacesValidNames() async throws {
        try await Self.withIsolatedStore {
            let cleaner = Agent(
                name: "Transcript Cleaner", description: "cleans", systemPrompt: "x",
                autonomousExec: AutonomousExecConfig(enabled: false))
            AgentStore.save(cleaner)
            AgentManager.shared.refresh()
            let scope = Self.makeLauncher(targetIDs: [cleaner.id])

            let miss = await SubagentToolVisibility.resolveSpawnableAgentName(
                "Researcher", scope: scope)
            #expect(miss.id == nil)
            #expect(miss.allowedNames.contains("Transcript Cleaner"))
        }
    }

    @MainActor
    @Test("a name outside the launcher's allow-list never resolves")
    func nameOutsideAllowListStaysUnauthorized() async throws {
        try await Self.withIsolatedStore {
            // `cleaner` exists in the catalog but is NOT in the launcher's list.
            let cleaner = Agent(
                name: "Transcript Cleaner", description: "cleans", systemPrompt: "x",
                autonomousExec: AutonomousExecConfig(enabled: false))
            AgentStore.save(cleaner)
            AgentManager.shared.refresh()
            let scope = Self.makeLauncher(targetIDs: [])

            let miss = await SubagentToolVisibility.resolveSpawnableAgentName(
                "Transcript Cleaner", scope: scope)
            #expect(miss.id == nil)
            #expect(miss.allowedNames.isEmpty)
        }
    }
}
