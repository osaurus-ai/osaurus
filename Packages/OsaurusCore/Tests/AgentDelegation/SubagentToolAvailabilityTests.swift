//
//  SubagentToolAvailabilityTests.swift
//  osaurusTests
//
//  Pins delegation settings as the source of truth for chat tool exposure.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent delegation tool availability", .serialized)
struct SubagentToolAvailabilityTests {
    @Test
    func imageToolIsAbsentFromDefaultAlwaysLoadedSchema() async throws {
        try await withDelegationSandboxAsync(configuration: .default) {
            let names = await MainActor.run {
                Set(ToolRegistry.shared.alwaysLoadedSpecs(mode: .none).map(\.function.name))
            }
            #expect(!names.contains("image"))
        }
    }

    @Test
    func imageToolEntersSchemaWhenMasterAndImageDelegationAreEnabled() async throws {
        try await withDelegationSandboxAsync(
            configuration: SubagentConfiguration(
                agentDelegationEnabled: true,
                imageDelegationEnabled: true
            )
        ) {
            let names = await MainActor.run {
                Set(ToolRegistry.shared.alwaysLoadedSpecs(mode: .none).map(\.function.name))
            }
            #expect(names.contains("image"))
        }
    }

    @Test
    func disabledImageDelegationBlocksDirectSpecLoading() async throws {
        try await withDelegationSandboxAsync(
            configuration: SubagentConfiguration(
                agentDelegationEnabled: true,
                imageDelegationEnabled: false
            )
        ) {
            let (specs, availability) = await MainActor.run {
                (
                    ToolRegistry.shared.specs(forTools: ["image"]),
                    ToolRegistry.shared.availability(forTool: "image")
                )
            }

            #expect(specs.isEmpty)
            #expect(availability.reasonCodes.contains(.disabled))
            #expect(availability.detail.contains("agent delegation is disabled"))
        }
    }

    @Test
    func disabledImageDelegationRejectsStaleToolExecution() async throws {
        try await withDelegationSandboxAsync(configuration: .default) {
            let result = try await ImageTool().execute(
                argumentsJSON: #"{"prompt":"green apple"}"#
            )

            #expect(ToolEnvelope.isError(result))
            #expect(ToolEnvelope.failureMessage(result).contains("disabled in Agent Delegation settings"))
        }
    }

    @Test
    func spawnIsAbsentFromDefaultAlwaysLoadedSchema() async throws {
        try await withDelegationSandboxAsync(configuration: .default) {
            let names = await MainActor.run {
                Set(ToolRegistry.shared.alwaysLoadedSpecs(mode: .none).map(\.function.name))
            }
            #expect(!names.contains("spawn"))
        }
    }

    @Test
    func spawnEntersSchemaWhenMasterEnabledAndAnAgentIsSpawnable() async throws {
        try await withDelegationSandboxAsync(
            configuration: SubagentConfiguration(
                agentDelegationEnabled: true,
                spawnableAgentNames: ["Helper"]
            )
        ) {
            let names = await MainActor.run {
                Set(ToolRegistry.shared.alwaysLoadedSpecs(mode: .none).map(\.function.name))
            }
            #expect(names.contains("spawn"))
        }
    }

    @Test
    func spawnWithNoSpawnableAgentsBlocksDirectSpecLoading() async throws {
        try await withDelegationSandboxAsync(
            configuration: SubagentConfiguration(
                agentDelegationEnabled: true,
                spawnableAgentNames: []
            )
        ) {
            let (specs, availability) = await MainActor.run {
                (
                    ToolRegistry.shared.specs(forTools: ["spawn"]),
                    ToolRegistry.shared.availability(forTool: "spawn")
                )
            }

            #expect(specs.isEmpty)
            #expect(availability.reasonCodes.contains(.disabled))
            #expect(availability.detail.contains("agent delegation is disabled"))
        }
    }

    @Test
    func spawnRejectsNonSpawnableAgentExecution() async throws {
        try await withDelegationSandboxAsync(configuration: .default) {
            let result = try await SpawnTool().execute(
                argumentsJSON: #"{"agent":"Helper","input":"Summarize this small function."}"#
            )

            #expect(ToolEnvelope.isError(result))
            #expect(ToolEnvelope.failureMessage(result).contains("not spawnable"))
        }
    }

    private func withDelegationSandboxAsync(
        configuration: SubagentConfiguration,
        body: () async throws -> Void
    ) async throws {
        // Cross-suite lock: `SubagentConfigurationStore` mutates a
        // process-global override + snapshot cache that
        // `SubagentConfigurationStoreTests` also stamps. `.serialized`
        // only orders THIS suite; the lock keeps the global stable while
        // we read the delegation-gated schema. See SubagentStoreTestLock.
        let lease = await acquireSubagentStoreSandbox("agent-delegation-tools")
        defer { lease.release() }
        SubagentConfigurationStore.save(configuration)
        try await body()
    }
}
