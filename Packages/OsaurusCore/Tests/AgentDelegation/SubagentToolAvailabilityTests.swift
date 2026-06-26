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
    func imageBlockedFromSpecLoadingWhenMasterOff() async throws {
        // The base schema + global spec/availability queries apply only the
        // MASTER gate (no agent context). With the master off, image is blocked
        // for everyone.
        try await withDelegationSandboxAsync(configuration: .default) {
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
    func imageStaysLoadableAtGlobalLevelWhenMasterOnEvenIfMainChatImageOff() async throws {
        // With the master on, image is loadable at the GLOBAL level even when the
        // main-chat image switch is off — a custom agent may have enabled it. The
        // per-agent narrowing (Default → off here) happens in `resolveTools`,
        // which has the agent context the global query lacks.
        try await withDelegationSandboxAsync(
            configuration: SubagentConfiguration(
                agentDelegationEnabled: true,
                imageDelegationEnabled: false
            )
        ) {
            let names = await MainActor.run {
                Set(ToolRegistry.shared.specs(forTools: ["image"]).map(\.function.name))
            }
            #expect(names.contains("image"))
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
    func spawnBlockedFromSpecLoadingWhenMasterOff() async throws {
        // Master off → spawn blocked at the global level for everyone.
        try await withDelegationSandboxAsync(configuration: .default) {
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
    func spawnStaysLoadableAtGlobalLevelWhenMasterOnEvenIfMainChatPoolEmpty() async throws {
        // With the master on, spawn is loadable at the GLOBAL level even when the
        // main-chat pool is empty — a custom agent may have its own spawnable
        // list. The per-agent narrowing (Default → empty pool here) happens in
        // `resolveTools`.
        try await withDelegationSandboxAsync(
            configuration: SubagentConfiguration(
                agentDelegationEnabled: true,
                spawnableAgentNames: []
            )
        ) {
            let names = await MainActor.run {
                Set(ToolRegistry.shared.specs(forTools: ["spawn"]).map(\.function.name))
            }
            #expect(names.contains("spawn"))
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
