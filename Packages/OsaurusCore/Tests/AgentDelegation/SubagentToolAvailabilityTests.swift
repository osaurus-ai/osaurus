//
//  SubagentToolAvailabilityTests.swift
//  osaurusTests
//
//  Pins the base-schema contract for the spawn / image delegation family. There
//  is no global master switch anymore: the family is ALWAYS present in the base
//  schema (a superset), and the per-agent narrowing happens in
//  `SystemPromptComposer.resolveTools` (covered by
//  `SubagentCapabilityRegistryTests.delegationVisibilitySemantics`). Here we pin
//  the always-present base contract and the execution-time per-agent rejection.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent delegation tool availability", .serialized)
struct SubagentToolAvailabilityTests {
    @Test
    func imageAndSpawnAreAlwaysInTheBaseSchema() async throws {
        // No master switch → the base (no-agent-context) schema always carries
        // the whole delegation family. Off-by-default is enforced per agent in
        // `resolveTools`, not by hiding the tools from the base set.
        try await withDelegationSandboxAsync(configuration: .default) {
            let names = await MainActor.run {
                Set(ToolRegistry.shared.alwaysLoadedSpecs(mode: .none).map(\.function.name))
            }
            #expect(names.contains("image"))
            #expect(names.contains("spawn_agent"))
            #expect(names.contains("spawn_model"))
        }
    }

    @Test
    func imageAndSpawnSpecsAreAlwaysLoadable() async throws {
        // The global spec/availability queries no longer apply a delegation
        // gate; they return the spec and carry no "agent delegation is disabled"
        // reason. The agent-scoped narrowing has the agent context these lack.
        try await withDelegationSandboxAsync(configuration: .default) {
            let (imageSpecs, spawnAgentSpecs, spawnModelSpecs, imageAvail, spawnAgentAvail) =
                await MainActor.run {
                    (
                        ToolRegistry.shared.specs(forTools: ["image"]).map(\.function.name),
                        ToolRegistry.shared.specs(forTools: ["spawn_agent"]).map(\.function.name),
                        ToolRegistry.shared.specs(forTools: ["spawn_model"]).map(\.function.name),
                        ToolRegistry.shared.availability(forTool: "image"),
                        ToolRegistry.shared.availability(forTool: "spawn_agent")
                    )
                }

            #expect(imageSpecs == ["image"])
            #expect(spawnAgentSpecs == ["spawn_agent"])
            #expect(spawnModelSpecs == ["spawn_model"])
            #expect(!imageAvail.detail.contains("agent delegation is disabled"))
            #expect(!spawnAgentAvail.detail.contains("agent delegation is disabled"))
        }
    }

    @Test
    func mainChatImageOffRejectsStaleToolExecution() async throws {
        // The main chat ships with image off; executing the tool anyway is
        // rejected per-agent ("not enabled for this agent"), not by a global
        // master gate.
        try await withDelegationSandboxAsync(configuration: .default) {
            let result = try await ImageTool().execute(
                argumentsJSON: #"{"prompt":"green apple"}"#
            )

            #expect(ToolEnvelope.isError(result))
            #expect(ToolEnvelope.failureMessage(result).contains("not enabled for this agent"))
        }
    }

    @Test
    func spawnAgentRejectsNonSpawnableAgentExecution() async throws {
        try await withDelegationSandboxAsync(configuration: .default) {
            let result = try await SpawnAgentTool().execute(
                argumentsJSON: #"{"agent":"Helper","input":"Summarize this small function."}"#
            )

            #expect(ToolEnvelope.isError(result))
            #expect(ToolEnvelope.failureMessage(result).contains("not spawnable"))
        }
    }

    @Test
    func spawnModelRejectsNonSpawnableModelExecution() async throws {
        // The default global config has an empty model pool, so a `spawn_model`
        // call against any id is rejected per-agent (reject-before-evict), not by
        // a global gate.
        try await withDelegationSandboxAsync(configuration: .default) {
            let result = try await SpawnModelTool().execute(
                argumentsJSON: #"{"model":"qwen3-4b-4bit","input":"Summarize this small function."}"#
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
