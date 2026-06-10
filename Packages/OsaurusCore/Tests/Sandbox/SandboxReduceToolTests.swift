//
//  SandboxReduceToolTests.swift
//  osaurusTests
//
//  Guardrail tests for the `sandbox_reduce` reduction subagent: recursion
//  refusal, argument validation, allowlist composition, and iteration caps.
//  The full nested loop is exercised by the AgentLoop eval suite (it needs
//  a live model); these tests pin everything that must hold without one.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SandboxReduceToolTests {

    private var tool: SandboxReduceTool {
        SandboxReduceTool(
            agentId: UUID().uuidString,
            agentName: "test-agent",
            home: "/home/test-agent"
        )
    }

    @Test func refusesRecursion() async throws {
        let result = try await SandboxReduceContext.$isActive.withValue(true) {
            try await tool.execute(argumentsJSON: #"{"task":"summarize logs"}"#)
        }
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("cannot be called from inside"))
    }

    @Test func rejectsMissingTask() async throws {
        let result = try await tool.execute(argumentsJSON: "{}")
        #expect(ToolEnvelope.isError(result))
        #expect(result.contains("task"))
    }

    @Test func rejectsMalformedArguments() async throws {
        let result = try await tool.execute(argumentsJSON: "not json")
        #expect(ToolEnvelope.isError(result))
    }

    @Test func allowlistIsReadSearchExecOnly() {
        let allowlist = Set(SandboxReduceTool.childToolAllowlist)
        #expect(allowlist == ["sandbox_read_file", "sandbox_search_files", "sandbox_exec"])
        // Explicitly excluded: loop tools, dispatch, writes, and itself.
        for banned in [
            "sandbox_reduce", "complete", "clarify", "todo", "dispatch", "sandbox_write_file", "share_artifact",
        ] {
            #expect(!allowlist.contains(banned))
        }
    }

    @Test func iterationBudgetIsCapped() {
        #expect(SandboxReduceTool.defaultIterations <= SandboxReduceTool.maxIterations)
        #expect(SandboxReduceTool.maxIterations <= 12)
    }

    @Test func bypassesRegistryTimeoutWithOwnDeadline() {
        // The nested loop outlives the registry's per-tool wall clock; the
        // tool must opt out and carry its own deadline.
        #expect(tool.bypassRegistryTimeout)
        #expect(SandboxReduceTool.wallClockSeconds > 0)
    }
}
