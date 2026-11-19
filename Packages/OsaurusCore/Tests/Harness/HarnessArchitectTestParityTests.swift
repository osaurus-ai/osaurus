//
//  HarnessArchitectTestParityTests.swift
//  osaurusTests
//
//  A `workflow_test` the Architect starts from a harness (its token on
//  `/mcp/call`) runs its steps exactly as one started by Osaurus's own
//  loop: the bridge call's external surface, prompt denial, and harness
//  bindings never reach a step.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct HarnessArchitectTestParityTests {

    private static func definition() -> WorkflowDefinition {
        WorkflowDefinition(
            inputSchema: WF.object([:]),
            outputSchema: WF.object(["ok": WF.bool]),
            nodes: [
                WorkflowNode(
                    id: "probe", name: "Probe",
                    kind: .tool(ToolNodeSpec(tool: ToolRef(name: StepScopeProbeTool.toolName))),
                    input: .object([:]), outputSchema: .object([:]))
            ],
            output: .object(["ok": "{{nodes.probe.output.ok}}"]))
    }

    /// Tests `definition()` as a fresh draft in chat `chatId` and returns
    /// what its step saw.
    private func stepScope(chatId: UUID, _ run: () async throws -> String) async throws -> [String: String] {
        let draft = WorkflowDraftStore.shared.create(sessionID: chatId.uuidString)
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        defer { WorkflowRunStore.shared.deleteRuns(workflowID: draft.id) }
        WorkflowDraftStore.shared.applyUserEdit(draft.id) { $0.definition = Self.definition() }
        StepScopeProbeTool.seen = nil
        let envelope = try await run()
        let result = try #require(JSONValue.parse(envelope)?.objectValue, "\(envelope.prefix(400))")
        #expect(result["ok"]?.boolValue == true, "\(envelope.prefix(400))")
        return try #require(StepScopeProbeTool.seen, "the step ran: \(envelope.prefix(400))")
    }

    @Test func aBridgeTestRunsItsStepsLikeTheBuiltInLoop() async throws {
        try await DynamicCatalogTestLock.shared.run {
            ToolRegistry.shared.register(StepScopeProbeTool())
            ToolRegistry.shared.setEnabled(true, for: StepScopeProbeTool.toolName)
            defer { ToolRegistry.shared.unregister(names: [StepScopeProbeTool.toolName]) }

            let builtInChat = UUID()
            let builtIn = try await stepScope(chatId: builtInChat) {
                try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
                    try await ChatExecutionContext.$currentSessionId.withValue(builtInChat.uuidString) {
                        try await WorkflowTestTool().execute(argumentsJSON: #"{"input": {}}"#)
                    }
                }
            }

            let harnessChat = UUID()
            let grant = HarnessGrant(
                agentId: Agent.architectId, chatId: harnessChat, allowsConfigWrites: false,
                allowedToolNames: HarnessGrantStore.architectToolNames, expiresAt: nil)
            let bridged = try await stepScope(chatId: harnessChat) {
                try await HTTPHandler.executeBridgeCall(
                    toolName: WorkflowTestTool.toolName, argumentsJSON: #"{"input": {}}"#, grant: grant,
                    attended: nil, toolCallId: "toolu_test")
            }

            #expect(bridged["session"] == harnessChat.uuidString)
            #expect(builtIn["session"] == builtInChat.uuidString)
            var normalized = bridged
            normalized["session"] = builtIn["session"]
            #expect(normalized == builtIn)
            #expect(bridged["external"] == "false")
            #expect(bridged["deny"] == "false")
            #expect(bridged["harness_agent"] == "nil")
            #expect(bridged["harness_chat"] == "nil")
            #expect(bridged["tool_call_id"] == "nil")
        }
    }
}

private struct StepScopeProbeTool: OsaurusTool {
    static let toolName = "harness_step_scope_probe"
    @MainActor static var seen: [String: String]?

    let name = StepScopeProbeTool.toolName
    let description = "Reports the execution scope of a workflow step"
    let parameters: JSONValue? = nil

    func execute(argumentsJSON: String) async throws -> String {
        func show(_ value: Any?) -> String { value.map { String(describing: $0) } ?? "nil" }
        let scope: [String: String] = [
            "external": show(ChatExecutionContext.isExternalSurface),
            "deny": show(ChatExecutionContext.denyUnapprovedToolPrompts),
            "auto_approve": show(ChatExecutionContext.autoApproveToolPrompts),
            "harness_agent": show(ChatExecutionContext.harnessTokenAgentId),
            "harness_chat": show(ChatExecutionContext.harnessChatId),
            "agent": show(ChatExecutionContext.currentAgentId),
            "session": show(ChatExecutionContext.currentSessionId),
            "session_source": show(ChatExecutionContext.currentSessionSource),
            "request_source": show(ChatExecutionContext.currentRequestSource),
            "inference_source": show(ChatExecutionContext.inferenceSourceOverride),
            "unattended": show(ChatExecutionContext.isUnattendedDispatch),
            "remote_reviewer": show(ChatExecutionContext.hasRemoteReviewer),
            "tool_call_id": show(ChatExecutionContext.currentToolCallId),
            "granted": show(ChatExecutionContext.workflowGrantedToolNames?.sorted()),
            "chat_box": show(ChatExecutionContext.currentChatSessionBox.map { _ in "bound" }),
        ]
        await MainActor.run { StepScopeProbeTool.seen = scope }
        return ToolEnvelope.success(tool: StepScopeProbeTool.toolName, result: ["ok": true])
    }
}
