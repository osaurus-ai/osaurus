//
//  SpawnToolsetTests.swift
//  OsaurusCoreTests
//
//  Unit coverage for the spawn child toolset (Phase 2 context offload):
//  the `SpawnToolAccess` gate, the allowlist refusal, and the per-run
//  `maxToolCalls` cap — using the injection seams so no live ToolRegistry
//  or model is needed.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SpawnToolsetTests {
    private func spec(_ name: String) -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(name: name, description: nil, parameters: nil)
        )
    }

    private func invocation(_ name: String) -> ServiceToolInvocation {
        ServiceToolInvocation(toolName: name, jsonArguments: "{}")
    }

    @Test("access none yields no toolset (text-only run)")
    func noneYieldsNil() async {
        let toolset = await TextSubagentKind.makeToolset(
            access: SpawnToolAccess.none,
            maxToolCalls: 4,
            feed: nil,
            specs: [spec("file_read")],
            dispatch: { _ in "unreachable" }
        )
        #expect(toolset == nil)
    }

    @Test("readOnly with no registered tools yields no toolset")
    func emptySpecsYieldNil() async {
        let toolset = await TextSubagentKind.makeToolset(
            access: .readOnly,
            maxToolCalls: 4,
            feed: nil,
            specs: [],
            dispatch: { _ in "unreachable" }
        )
        #expect(toolset == nil)
    }

    @Test("allowed tool dispatches; non-allowlisted tool is refused")
    func allowlistEnforced() async throws {
        let toolset = await TextSubagentKind.makeToolset(
            access: .readOnly,
            maxToolCalls: 4,
            feed: nil,
            specs: [spec("file_read"), spec("file_search")],
            dispatch: { inv in "ran:\(inv.toolName)" }
        )
        let set = try #require(toolset)
        #expect(set.specs.count == 2)

        let ok = await set.execute(invocation("file_read"))
        #expect(ok == "ran:file_read")

        let refused = await set.execute(invocation("delete_everything"))
        #expect(ToolEnvelope.isError(refused))
        #expect(ToolEnvelope.failureMessage(refused).contains("not available inside this subagent"))
    }

    @Test("maxToolCalls cap refuses further calls with budget copy")
    func toolCallCapEnforced() async throws {
        let toolset = await TextSubagentKind.makeToolset(
            access: .readOnly,
            maxToolCalls: 2,
            feed: nil,
            specs: [spec("file_read")],
            dispatch: { _ in "ok" }
        )
        let set = try #require(toolset)

        let first = await set.execute(invocation("file_read"))
        let second = await set.execute(invocation("file_read"))
        let third = await set.execute(invocation("file_read"))
        #expect(first == "ok")
        #expect(second == "ok")
        #expect(ToolEnvelope.isError(third))
        #expect(ToolEnvelope.failureMessage(third).contains("Tool-call budget (2) exhausted"))
    }

    @Test("maxToolCalls 0 falls back to the default read-only cap")
    func zeroCapUsesDefault() async throws {
        let toolset = await TextSubagentKind.makeToolset(
            access: .readOnly,
            maxToolCalls: 0,
            feed: nil,
            specs: [spec("file_read")],
            dispatch: { _ in "ok" }
        )
        let set = try #require(toolset)

        var successes = 0
        for _ in 0 ..< (TextSubagentKind.defaultReadOnlyToolCallCap + 1) {
            let result = await set.execute(invocation("file_read"))
            if result == "ok" { successes += 1 }
        }
        #expect(successes == TextSubagentKind.defaultReadOnlyToolCallCap)
    }

    @Test("refused non-allowlisted call does not consume the cap")
    func refusalDoesNotBurnBudget() async throws {
        let toolset = await TextSubagentKind.makeToolset(
            access: .readOnly,
            maxToolCalls: 1,
            feed: nil,
            specs: [spec("file_read")],
            dispatch: { _ in "ok" }
        )
        let set = try #require(toolset)

        _ = await set.execute(invocation("not_allowed"))
        let allowed = await set.execute(invocation("file_read"))
        #expect(allowed == "ok")
    }

    @Test("cancel-reason mapping: user stop / parent cancel / deadline get distinct honest copy")
    func cancelReasonMapping() {
        // User stop → user_denied with "stopped by the user" (NOT a timeout).
        let userStop = TextSubagentKind.cancelError(
            cause: .userInterrupt,
            label: "worker",
            maxElapsedSeconds: 120
        )
        guard case .userDenied(let userMessage) = userStop else {
            Issue.record("user interrupt mapped to \(userStop), expected .userDenied")
            return
        }
        #expect(userMessage.contains("stopped by the user"))
        #expect(!userMessage.contains("time budget"))

        // Parent task cancel → execution failure tied to the parent run.
        let parent = TextSubagentKind.cancelError(
            cause: .parentTask,
            label: "worker",
            maxElapsedSeconds: 120
        )
        guard case .executionFailed(let parentMessage, let retryable) = parent else {
            Issue.record("parent cancel mapped to \(parent), expected .executionFailed")
            return
        }
        #expect(parentMessage.contains("cancelled with the parent run"))
        #expect(retryable == false)

        // Deadline (and the unknown-cause fallback) → the time-budget copy.
        for cause in [SubagentCancelCause.deadline, nil] {
            let deadline = TextSubagentKind.cancelError(
                cause: cause,
                label: "worker",
                maxElapsedSeconds: 120
            )
            guard case .timedOut(let deadlineMessage) = deadline else {
                Issue.record("\(String(describing: cause)) mapped to \(deadline), expected .timedOut")
                return
            }
            #expect(deadlineMessage.contains("120s time budget"))
        }
    }

    @Test("effectiveSpawnToolAccess: default agent uses global, custom uses settings")
    func effectiveAccessResolution() {
        var config = SubagentConfiguration()
        config.spawnToolAccess = .readOnly
        var settings = AgentSettings.defaultDisabled
        settings.spawnToolAccess = SpawnToolAccess.none

        // Default agent → global config value.
        #expect(
            SubagentToolVisibility.effectiveSpawnToolAccess(
                isDefault: true,
                config: config,
                settings: settings
            ) == .readOnly
        )
        // Custom agent → its own settings, not the global.
        #expect(
            SubagentToolVisibility.effectiveSpawnToolAccess(
                isDefault: false,
                config: config,
                settings: settings
            ) == SpawnToolAccess.none
        )
        // Missing settings → safe text-only default.
        #expect(
            SubagentToolVisibility.effectiveSpawnToolAccess(
                isDefault: false,
                config: config,
                settings: nil
            ) == SpawnToolAccess.none
        )
    }
}
