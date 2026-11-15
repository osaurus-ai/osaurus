//
//  ToolApprovalAuditMarkerTests.swift
//  osaurus
//
//  The "Ran without asking" marker: a skip reason the gate recorded lands on
//  the chat turn with the call's result, persists and syncs with the turn,
//  reaches the tool row, and rides on Insights tool rows without changing
//  how older rows encode.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct ToolApprovalAuditMarkerTests {

    private func callId() -> String { "call-marker-\(UUID().uuidString)" }

    @Test @MainActor
    func setToolResultCollectsTheRecordedReason() {
        let skipped = callId()
        let asked = callId()
        ToolApprovalAudit.record(.agentNeverAsk, callId: skipped)
        let turn = ChatTurn(role: .assistant, content: "")
        turn.setToolResult("ok", for: skipped)
        turn.setToolResult("ok", for: asked)
        #expect(turn.toolCallApprovalSkips == [skipped: .agentNeverAsk])
        #expect(ToolApprovalAudit.take(callId: skipped) == nil, "collected once")
    }

    @Test
    func peekLeavesTheReasonForTheTurn() {
        let id = callId()
        ToolApprovalAudit.record(.globalAutoAllow, callId: id)
        #expect(ToolApprovalAudit.peek(callId: id) == .globalAutoAllow)
        #expect(ToolApprovalAudit.take(callId: id) == .globalAutoAllow)
    }

    @Test @MainActor
    func turnDataRoundTripsAndOmitsAnEmptyMap() throws {
        let id = callId()
        let turn = ChatTurn(role: .assistant, content: "")
        turn.toolCallApprovalSkips = [id: .agentToolPolicy]
        let data = try JSONEncoder().encode(ChatTurnData(from: turn))
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: data)
        #expect(decoded.toolCallApprovalSkips == [id: .agentToolPolicy])
        #expect(ChatTurn(from: decoded).toolCallApprovalSkips == [id: .agentToolPolicy])

        let plain = try JSONEncoder().encode(ChatTurnData(role: .assistant, content: ""))
        let object = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(object["toolCallApprovalSkips"] == nil)
    }

    @Test
    func unknownReasonsAreDroppedOnDecode() throws {
        let json = #"{"id":"\#(UUID().uuidString)","role":"assistant","content":"","toolCallApprovalSkips":{"a":"agent_never_ask","b":"from_the_future"}}"#
        let decoded = try JSONDecoder().decode(ChatTurnData.self, from: Data(json.utf8))
        #expect(decoded.toolCallApprovalSkips == ["a": .agentNeverAsk])
    }

    @Test
    func syncAppDataCarriesTheMap() throws {
        let turn = ChatTurnData(role: .assistant, content: "", toolCallApprovalSkips: ["call_1": .agentNeverAsk])
        let encoded = try SyncConversationMapper.encode(turn: turn, toolName: nil)
        let object = try #require(SyncConversationMapper.parseObject(encoded.appData))
        #expect(object["toolCallApprovalSkips"] as? [String: String] == ["call_1": "agent_never_ask"])
        #expect(SyncConversationMapper.turnOwnedKeys.contains("toolCallApprovalSkips"))
    }

    @Test
    func toolRowItemCarriesTheReason() {
        let call = ToolCall(id: "call_1", type: "function", function: ToolCallFunction(name: "probe", arguments: "{}"))
        let plain = ToolCallItem(call: call, result: "ok")
        var marked = plain
        marked.approvalSkip = .agentNeverAsk
        #expect(plain != marked, "a new marker redraws the row")
    }

    // MARK: Insights

    @Test
    func insightsRowOmitsTheKeyWhenUnset() throws {
        let log = ToolCallLog(name: "probe", arguments: "{}")
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(log)) as? [String: Any])
        #expect(object["approvalSkip"] == nil)
        #expect(log.approvalSkip == nil)
    }

    @Test
    func insightsRowReencodesExactlyEvenWithAnUnknownReason() throws {
        let marked = ToolCallLog(name: "probe", arguments: "{}", approvalSkip: .globalAutoAllow)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(marked)
        let decoded = try JSONDecoder().decode(ToolCallLog.self, from: data)
        #expect(decoded.approvalSkip == .globalAutoAllow)
        #expect(try encoder.encode(decoded) == data)

        let future = Data(
            #"{"approvalSkip":"from_the_future","arguments":"{}","id":"\#(UUID().uuidString)","isError":false,"name":"probe"}"#
                .utf8)
        let decodedFuture = try JSONDecoder().decode(ToolCallLog.self, from: future)
        #expect(decodedFuture.approvalSkip == nil)
        #expect(try encoder.encode(decodedFuture) == future)
        #expect(decodedFuture.withoutContent().approvalSkip == nil)
    }
}
