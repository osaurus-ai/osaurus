//
//  SpawnToolTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Model-free guardrail tests for the `spawn` text sub-agent tool, mirroring
//  `SandboxReduceToolTests`. The full nested loop needs a live model (covered by
//  the AgentLoop eval suite); these pin everything that must hold without one:
//  the unified recursion guard, argument validation, and the registry-timeout
//  opt-out.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SpawnToolTests {

    @Test func refusesRecursion() async throws {
        // The recursion guard is the unified host guard
        // (`SubagentSession.activeKindId`), shared across the whole sub-agent
        // family — a running sub-agent of ANY kind blocks a nested spawn.
        let result = try await SubagentSession.$activeKindId.withValue("image") {
            try await SpawnTool().execute(
                argumentsJSON: #"{"agent":"helper","input":"summarize"}"#
            )
        }
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("cannot be called from inside"))
    }

    @Test func rejectsMissingAgent() async throws {
        let result = try await SpawnTool().execute(argumentsJSON: #"{"input":"do a thing"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("agent"))
    }

    @Test func rejectsMissingInput() async throws {
        let result = try await SpawnTool().execute(argumentsJSON: #"{"agent":"helper"}"#)
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("input"))
    }

    @Test func rejectsMalformedArguments() async throws {
        let result = try await SpawnTool().execute(argumentsJSON: "not json")
        #expect(ToolEnvelope.isError(result))
    }

    @Test func bypassesRegistryTimeout() {
        // The nested loop outlives the registry's per-tool wall clock; spawn
        // must opt out so the host owns the deadline.
        #expect(SpawnTool().bypassRegistryTimeout)
    }

    @Test func kindShape() {
        let kind = TextSubagentKind(agentName: "helper", input: "x")
        #expect(kind.capability.id == "spawn")
        #expect(kind.capability.toolNames == ["spawn"])
        // spawn runs the chosen persona's model → it may resolve a DIFFERENT
        // local model and run the residency handoff (unlike the same-model
        // image / computer_use / sandbox kinds).
        #expect(kind.capability.modelSource == .persona)
        #expect(kind.feedTitle.contains("helper"))
    }

    /// Per-agent spawnable enforcement: a CUSTOM launching agent may only spawn
    /// personas in its OWN `spawnableAgentNames` list — the global pool does NOT
    /// apply to it. Here the main chat's pool lists
    /// "Helper", but the launching agent is a custom agent with an empty list, so
    /// `resolveModel` must reject BEFORE any model/residency work (the
    /// reject-before-evict contract). Binding `ChatExecutionContext.currentAgentId`
    /// to a non-default id that AgentManager doesn't know about resolves the
    /// per-agent target list to empty.
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
                // The custom-agent message points at the agent's own Sub-agents
                // tab, not the global Main Chat pool.
                #expect(message.contains("not spawnable from this agent"))
            } catch {
                Issue.record("expected SubagentError.denied, got \(error)")
            }
        }
    }

    /// Per-agent permission enforcement for the main chat: the Default agent
    /// reads its spawn permission from the GLOBAL config (not `AgentSettings`).
    /// With the target in the global pool but the spawn permission set to
    /// `.deny`, `resolveModel` must reject with the per-agent permission message
    /// before any model / persona work (reject-before-evict).
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
