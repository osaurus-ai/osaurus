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
        // spawn may resolve a DIFFERENT local model → the host runs the
        // residency handoff (unlike same-model image/computer_use/sandbox).
        #expect(kind.needsHandoff)
        #expect(kind.feedTitle.contains("helper"))
    }
}
