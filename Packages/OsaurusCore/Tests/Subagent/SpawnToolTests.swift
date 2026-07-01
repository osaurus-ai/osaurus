//
//  SpawnToolTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Model-free guardrail tests for the spawn family — `spawn_agent` (agent
//  context) and `spawn_model` (bare model). The full nested loop needs a live
//  model (covered by the AgentLoop eval suite); these pin everything that must
//  hold without one: the unified recursion guard, argument validation, the
//  registry-timeout opt-out, and the per-agent / per-pool reject-before-evict
//  gates for BOTH tools.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SpawnToolTests {

    @Test func refusesRecursion() async throws {
        // The recursion guard is the unified host guard
        // (`SubagentSession.activeKindId`), shared across the whole subagent
        // family — a running subagent of ANY kind blocks a nested spawn.
        let agentResult = try await SubagentSession.$activeKindId.withValue("image") {
            try await SpawnAgentTool().execute(
                argumentsJSON: #"{"agent":"helper","input":"summarize"}"#
            )
        }
        #expect(ToolEnvelope.isError(agentResult))
        #expect(agentResult.contains("cannot be called from inside"))

        let modelResult = try await SubagentSession.$activeKindId.withValue("image") {
            try await SpawnModelTool().execute(
                argumentsJSON: #"{"model":"qwen3-4b-4bit","input":"summarize"}"#
            )
        }
        #expect(ToolEnvelope.isError(modelResult))
        #expect(modelResult.contains("cannot be called from inside"))
    }

    @Test func spawnAgentRejectsMissingArguments() async throws {
        let missingAgent = try await SpawnAgentTool().execute(argumentsJSON: #"{"input":"do a thing"}"#)
        #expect(ToolEnvelope.isError(missingAgent))
        #expect(missingAgent.contains("agent"))

        let missingInput = try await SpawnAgentTool().execute(argumentsJSON: #"{"agent":"helper"}"#)
        #expect(ToolEnvelope.isError(missingInput))
        #expect(missingInput.contains("input"))

        let malformed = try await SpawnAgentTool().execute(argumentsJSON: "not json")
        #expect(ToolEnvelope.isError(malformed))
    }

    @Test func spawnModelRejectsMissingArguments() async throws {
        let missingModel = try await SpawnModelTool().execute(argumentsJSON: #"{"input":"do a thing"}"#)
        #expect(ToolEnvelope.isError(missingModel))
        #expect(missingModel.contains("model"))

        let missingInput = try await SpawnModelTool().execute(argumentsJSON: #"{"model":"qwen3-4b-4bit"}"#)
        #expect(ToolEnvelope.isError(missingInput))
        #expect(missingInput.contains("input"))

        let malformed = try await SpawnModelTool().execute(argumentsJSON: "not json")
        #expect(ToolEnvelope.isError(malformed))
    }

    @Test func bypassesRegistryTimeout() {
        // The nested loop outlives the registry's per-tool wall clock; both spawn
        // tools must opt out so the host owns the deadline.
        #expect(SpawnAgentTool().bypassRegistryTimeout)
        #expect(SpawnModelTool().bypassRegistryTimeout)
    }

    @Test func toolNamesMatchTheRegistry() {
        // The two tools are the SSOT names from the shared `spawn` capability.
        #expect(SpawnAgentTool().name == "spawn_agent")
        #expect(SpawnModelTool().name == "spawn_model")
        #expect(
            SubagentCapabilityRegistry.spawn.toolNames == ["spawn_agent", "spawn_model"]
        )
    }

    @Test func agentKindShape() {
        let kind = TextSubagentKind(agentName: "helper", input: "x")
        #expect(kind.capability.id == "spawn")
        #expect(kind.capability.toolNames == ["spawn_agent", "spawn_model"])
        // spawn runs the chosen agent's model → it may resolve a DIFFERENT
        // local model and run the residency handoff (unlike the same-model
        // image / computer_use / sandbox kinds).
        #expect(kind.capability.modelSource == .agent)
        #expect(kind.feedTitle.contains("helper"))
    }

    @Test func modelKindShape() {
        // The model-mode kind shares the same capability but titles itself with
        // the bare model id (no agent).
        let kind = TextSubagentKind(model: "qwen3-4b-4bit", input: "x")
        #expect(kind.capability.id == "spawn")
        #expect(kind.feedTitle.contains("qwen3-4b-4bit"))
    }

    /// Per-agent spawnable enforcement (agents): a CUSTOM launching agent may
    /// only spawn agents in its OWN `spawnableAgentNames` list — the global
    /// pool does NOT apply to it. Here the main chat's pool lists "Helper", but
    /// the launching agent is a custom agent with an empty list, so `resolveModel`
    /// must reject BEFORE any model/residency work (reject-before-evict). Binding
    /// `ChatExecutionContext.currentAgentId` to a non-default id that
    /// AgentManager doesn't know about resolves the per-agent list to empty.
    @Test func customAgentSpawnRejectsTargetOutsideItsOwnList() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-per-agent-enforcement")
        defer { lease.release() }
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                spawnableAgentNames: ["Helper"]
            )
        )

        let customAgentId = UUID()
        await ChatExecutionContext.$currentAgentId.withValue(customAgentId) {
            do {
                _ = try await TextSubagentKind(agentName: "Helper", input: "x")
                    .resolveModel(SubagentScope.current())
                Issue.record("custom agent spawn of an unlisted target should be denied")
            } catch let SubagentError.denied(message) {
                // The custom-agent message points at the agent's own Subagents
                // tab, not the global Main Chat pool.
                #expect(message.contains("not spawnable from this agent"))
            } catch {
                Issue.record("expected SubagentError.denied, got \(error)")
            }
        }
    }

    /// Per-pool enforcement (models): the main chat's `spawn_model` pool is
    /// authoritative for the Default agent. With an empty model pool, a
    /// `spawn_model` against any id must reject before model/residency work.
    @Test func mainChatSpawnModelRejectsModelOutsideItsPool() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-model-pool-enforcement")
        defer { lease.release() }
        SubagentConfigurationStore.save(
            SubagentConfiguration(spawnableModelNames: ["allowed-model"])
        )

        await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            do {
                _ = try await TextSubagentKind(model: "not-in-pool", input: "x")
                    .resolveModel(SubagentScope.current())
                Issue.record("spawn_model of a model outside the pool should be denied")
            } catch let SubagentError.denied(message) {
                #expect(message.contains("not spawnable"))
            } catch {
                Issue.record("expected SubagentError.denied, got \(error)")
            }
        }
    }

    /// Per-agent permission enforcement for the main chat: the Default agent
    /// reads its spawn permission from the GLOBAL config (not `AgentSettings`).
    /// With the target in the global pool but the spawn permission set to
    /// `.deny`, `resolveModel` must reject with the per-agent permission message
    /// before any model / agent work (reject-before-evict).
    @Test func mainChatSpawnRespectsGlobalPermissionDeny() async throws {
        let lease = await acquireSubagentStoreSandbox("spawn-main-chat-permission-deny")
        defer { lease.release() }
        var perms = SubagentPermissionDefaults()
        perms.setPolicy(.deny, for: SubagentCapabilityRegistry.spawn.id)
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                spawnableAgentNames: ["Helper"],
                permissionDefaults: perms
            )
        )

        await ChatExecutionContext.$currentAgentId.withValue(Agent.defaultId) {
            do {
                _ = try await TextSubagentKind(agentName: "Helper", input: "x")
                    .resolveModel(SubagentScope.current())
                Issue.record("a denied spawn permission should reject resolveModel")
            } catch let SubagentError.denied(message) {
                #expect(message.contains("denied by this agent's permission settings"))
            } catch {
                Issue.record("expected SubagentError.denied, got \(error)")
            }
        }
    }
}
