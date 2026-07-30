//
//  ToolRegistryAutoApproveTests.swift
//  osaurus
//
//  Pins the security contract of `ChatExecutionContext.autoApproveToolPrompts`,
//  the headless eval harness's approval bypass:
//    * defaults to false — production surfaces never inherit it,
//    * skips ONLY the `.ask` user prompt,
//    * `.deny` policies still throw even while it is bound.
//
//  Also pins the user-facing `ToolApprovalSettings.autoAllowAll` chat
//  setting: default off, approves only `.ask` prompts, and is outranked by
//  both `.deny` policies and headless surface denials.
//
//  The complementary "without the binding, `.ask` prompts" path is
//  deliberately NOT executed here: it would present a real NSPanel and
//  hang the test run — exactly the failure mode the TaskLocal exists to
//  prevent in headless contexts.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Fixtures

/// Minimal permissioned tool with a configurable default policy and no
/// requirements, so the test exercises the ask/deny policy switch in
/// `runPermissionGate` without touching system permissions.
private final class PolicyProbeTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name: String
    let description = "Test-only permission policy probe."
    let parameters: JSONValue? = nil

    let requirements: [String] = []
    let defaultPermissionPolicy: ToolPermissionPolicy

    private(set) var executions = 0

    init(name: String, policy: ToolPermissionPolicy) {
        self.name = name
        self.defaultPermissionPolicy = policy
    }

    func execute(argumentsJSON: String) async throws -> String {
        executions += 1
        return ToolEnvelope.success(tool: name, text: "ran")
    }
}

// MARK: - Tests

@MainActor
struct ToolRegistryAutoApproveTests {

    @Test func taskLocalDefaultsToFalse() {
        #expect(ChatExecutionContext.autoApproveToolPrompts == false)
    }

    @Test func askGatedToolExecutesWithoutPromptWhenBound() async throws {
        let tool = PolicyProbeTool(name: "test_auto_approve_ask_probe", policy: .ask)
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        let result = try await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
            try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
        }

        #expect(tool.executions == 1)
        #expect(!ToolEnvelope.isError(result))
    }

    @Test func denyPolicyStillThrowsWhileBound() async {
        let tool = PolicyProbeTool(name: "test_auto_approve_deny_probe", policy: .deny)
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        await #expect(throws: (any Error).self) {
            _ = try await ChatExecutionContext.$autoApproveToolPrompts.withValue(true) {
                try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
            }
        }
        #expect(tool.executions == 0)
    }

    @Test func parserInvalidArgumentsEnvelopeNeverExecutesToolBody() async throws {
        let tool = PolicyProbeTool(name: "test_parser_invalid_args_probe", policy: .auto)
        ToolRegistry.shared.register(tool)
        defer { ToolRegistry.shared.unregister(names: [tool.name]) }

        let arguments =
            #"{"_error":"invalid_tool_arguments","_tool":"test_parser_invalid_args_probe","_message":"duplicate argument: columns","_field":"columns","_expected":"one value per declared parameter"}"#
        let result = try await ToolRegistry.shared.execute(
            name: tool.name,
            argumentsJSON: arguments)

        #expect(tool.executions == 0)
        #expect(ToolEnvelope.isError(result))
        let data = try #require(result.data(using: .utf8))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "invalid_args")
        #expect(object["field"] as? String == "columns")
        #expect(object["expected"] as? String == "one value per declared parameter")
        #expect(object["retryable"] as? Bool == true)
    }

    // MARK: Global auto-allow chat setting

    @Test func globalAutoAllowDefaultsToOff() {
        UserDefaults.standard.removeObject(
            forKey: ToolApprovalSettings.autoAllowAllDefaultsKey
        )
        #expect(ToolApprovalSettings.autoAllowAll == false)
    }

    @Test func askGatedToolExecutesWhenGlobalAutoAllowIsOn() async throws {
        let tool = PolicyProbeTool(name: "test_global_auto_allow_ask_probe", policy: .ask)
        ToolRegistry.shared.register(tool)
        UserDefaults.standard.set(true, forKey: ToolApprovalSettings.autoAllowAllDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(
                forKey: ToolApprovalSettings.autoAllowAllDefaultsKey
            )
            ToolRegistry.shared.unregister(names: [tool.name])
        }

        let result = try await ToolRegistry.shared.execute(
            name: tool.name,
            argumentsJSON: "{}"
        )

        #expect(tool.executions == 1)
        #expect(!ToolEnvelope.isError(result))
    }

    @Test func denyPolicyOutranksGlobalAutoAllow() async {
        let tool = PolicyProbeTool(name: "test_global_auto_allow_deny_probe", policy: .deny)
        ToolRegistry.shared.register(tool)
        UserDefaults.standard.set(true, forKey: ToolApprovalSettings.autoAllowAllDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(
                forKey: ToolApprovalSettings.autoAllowAllDefaultsKey
            )
            ToolRegistry.shared.unregister(names: [tool.name])
        }

        await #expect(throws: (any Error).self) {
            _ = try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
        }
        #expect(tool.executions == 0)
    }

    /// Headless surfaces that bind `denyUnapprovedToolPrompts` must stay
    /// denial-shaped even when the user's global auto-allow setting is on:
    /// the setting replaces the interactive card, it never overrides a
    /// surface-level denial.
    @Test func headlessDenyOutranksGlobalAutoAllow() async {
        let tool = PolicyProbeTool(name: "test_global_auto_allow_headless_probe", policy: .ask)
        ToolRegistry.shared.register(tool)
        UserDefaults.standard.set(true, forKey: ToolApprovalSettings.autoAllowAllDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(
                forKey: ToolApprovalSettings.autoAllowAllDefaultsKey
            )
            ToolRegistry.shared.unregister(names: [tool.name])
        }

        await #expect(throws: (any Error).self) {
            _ = try await ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
                try await ToolRegistry.shared.execute(name: tool.name, argumentsJSON: "{}")
            }
        }
        #expect(tool.executions == 0)
    }

    // MARK: Two-phase batch (serial approvals → parallel execution)

    /// The canonical headless batch (`runBatchInParallel(sessionId:agentId:)`)
    /// must resolve approvals serially in model order BEFORE any execution:
    /// a denial skips every later call with a paired rejection envelope —
    /// never executing it — exactly like the chat surface's batch executor.
    @Test func batchDenialSkipsLaterCallsWithoutExecuting() async {
        let okTool = PolicyProbeTool(name: "test_batch_ok_probe", policy: .auto)
        let denyTool = PolicyProbeTool(name: "test_batch_deny_probe", policy: .deny)
        let skippedTool = PolicyProbeTool(name: "test_batch_skipped_probe", policy: .auto)
        ToolRegistry.shared.register(okTool)
        ToolRegistry.shared.register(denyTool)
        ToolRegistry.shared.register(skippedTool)
        defer {
            ToolRegistry.shared.unregister(names: [okTool.name, denyTool.name, skippedTool.name])
        }

        let calls: [(invocation: ServiceToolInvocation, callId: String)] = [
            (ServiceToolInvocation(toolName: okTool.name, jsonArguments: "{}", toolCallId: nil), "c1"),
            (ServiceToolInvocation(toolName: denyTool.name, jsonArguments: "{}", toolCallId: nil), "c2"),
            (ServiceToolInvocation(toolName: skippedTool.name, jsonArguments: "{}", toolCallId: nil), "c3"),
        ]
        let executions = await AgentToolLoop.runBatchInParallel(
            calls,
            sessionId: "test-session",
            agentId: UUID()
        )

        #expect(executions.count == 3)
        // Slot 0 approved + executed.
        #expect(okTool.executions == 1)
        #expect(!ToolEnvelope.isError(executions[0].result))
        // Slot 1 denied at the approval phase — never executed.
        #expect(denyTool.executions == 0)
        #expect(executions[1].isError)
        #expect(ToolEnvelope.isError(executions[1].result))
        // Slot 2 skipped because of the earlier denial — never executed,
        // but paired with an envelope so the tool_use doesn't dangle.
        #expect(skippedTool.executions == 0)
        #expect(executions[2].result.contains("Skipped"))
    }

    @Test func batchWithAllAutoToolsExecutesEverySlot() async {
        let a = PolicyProbeTool(name: "test_batch_auto_a", policy: .auto)
        let b = PolicyProbeTool(name: "test_batch_auto_b", policy: .auto)
        ToolRegistry.shared.register(a)
        ToolRegistry.shared.register(b)
        defer { ToolRegistry.shared.unregister(names: [a.name, b.name]) }

        let calls: [(invocation: ServiceToolInvocation, callId: String)] = [
            (ServiceToolInvocation(toolName: a.name, jsonArguments: "{}", toolCallId: nil), "c1"),
            (ServiceToolInvocation(toolName: b.name, jsonArguments: "{}", toolCallId: nil), "c2"),
        ]
        let executions = await AgentToolLoop.runBatchInParallel(
            calls,
            sessionId: "test-session",
            agentId: UUID()
        )

        #expect(executions.count == 2)
        #expect(a.executions == 1)
        #expect(b.executions == 1)
        #expect(executions.allSatisfy { !$0.isError })
    }
}
