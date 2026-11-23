//
//  HarnessBridgeCallTests.swift
//  osaurusTests
//
//  How a harness's `/mcp/call` is bound: which calls run as the open chat's
//  own, the harness's tool-call id, and the calls a finished turn cancels.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct HarnessBridgeCallTests {
    private let chatId = UUID()

    private func grant(chatId: UUID?) -> HarnessGrant {
        HarnessGrant(
            agentId: UUID(), chatId: chatId, allowsConfigWrites: false, allowedToolNames: nil,
            expiresAt: nil)
    }

    private func withOpenChat<T>(_ chatId: UUID, folder: URL?, _ body: () async throws -> T) async rethrows -> T {
        let previous = HarnessBridgeCall.openChat
        HarnessBridgeCall.openChat = { $0 == chatId ? .init(folderRoot: folder) : nil }
        defer { HarnessBridgeCall.openChat = previous }
        return try await body()
    }

    @Test func runWorkflowIsAttendedOnlyWhileItsChatIsOpen() async {
        let folder = URL(fileURLWithPath: "/tmp/harness-bridge")
        #expect(HarnessBridgeCall.attendedScope(grant: grant(chatId: chatId), toolName: "run_workflow") == nil)
        await withOpenChat(chatId, folder: folder) {
            #expect(
                HarnessBridgeCall.attendedScope(grant: grant(chatId: chatId), toolName: "run_workflow")
                    == .init(folderRoot: folder))
            #expect(HarnessBridgeCall.attendedScope(grant: grant(chatId: chatId), toolName: "status") == nil)
            #expect(HarnessBridgeCall.attendedScope(grant: grant(chatId: nil), toolName: "run_workflow") == nil)
            #expect(HarnessBridgeCall.attendedScope(grant: nil, toolName: "run_workflow") == nil)
        }
    }

    @Test func toolCallIdsAreBoundedToolUseIds() {
        #expect(HarnessBridgeCall.toolCallId(fromHeader: "toolu_01ABCdef-9") == "toolu_01ABCdef-9")
        #expect(HarnessBridgeCall.toolCallId(fromHeader: nil) == nil)
        #expect(HarnessBridgeCall.toolCallId(fromHeader: "  ") == nil)
        #expect(HarnessBridgeCall.toolCallId(fromHeader: "toolu_1\"><script>") == nil)
        #expect(HarnessBridgeCall.toolCallId(fromHeader: String(repeating: "a", count: 129)) == nil)
        #expect(HarnessBridgeCall.toolCallId(fromHeader: "tööl") == nil)
    }

    @Test func externalCallsKeepTheExternalSurfaceAndAttendedOnesRunAsTheChat() async throws {
        try await DynamicCatalogTestLock.shared.run {
            ToolRegistry.shared.register(BridgeScopeProbeTool())
            ToolRegistry.shared.setEnabled(true, for: BridgeScopeProbeTool.toolName)
            defer { ToolRegistry.shared.unregister(names: [BridgeScopeProbeTool.toolName]) }
            let folder = URL(fileURLWithPath: "/tmp/harness-bridge-folder")

            let external = try await HTTPHandler.executeBridgeCall(
                toolName: BridgeScopeProbeTool.toolName, argumentsJSON: "{}", grant: grant(chatId: chatId),
                attended: nil, toolCallId: "toolu_ext")
            let attended = try await HTTPHandler.executeBridgeCall(
                toolName: BridgeScopeProbeTool.toolName, argumentsJSON: "{}", grant: grant(chatId: chatId),
                attended: .init(folderRoot: folder), toolCallId: "toolu_att")

            func scope(_ envelope: String) throws -> [String: JSONValue] {
                let text = try #require(
                    JSONValue.parse(envelope)?.objectValue?["result"]?.objectValue?["text"]?.stringValue, "\(envelope)")
                return try #require(JSONValue.parse(text)?.objectValue)
            }
            let ext = try scope(external)
            #expect(ext["external"]?.boolValue == true)
            #expect(ext["deny"]?.boolValue == true)
            #expect(ext["source"] == nil)
            #expect(ext["tool_call_id"]?.stringValue == "toolu_ext")
            #expect(ext["session"]?.stringValue == chatId.uuidString)
            #expect(ext["harness_chat"]?.stringValue == chatId.uuidString)

            let att = try scope(attended)
            #expect(att["external"]?.boolValue == false)
            #expect(att["deny"]?.boolValue == false)
            #expect(att["source"]?.stringValue == SessionSource.chat.rawValue)
            #expect(att["folder"]?.stringValue == folder.path)
            #expect(att["tool_call_id"]?.stringValue == "toolu_att")
            #expect(att["harness_chat"]?.stringValue == chatId.uuidString)
        }
    }

    @Test func endingTheTurnCancelsItsInFlightCalls() async throws {
        let calls = HarnessBridgeCalls()
        let started = AsyncStream<Void>.makeStream()
        let call = Task {
            try await calls.run(chatId: chatId) {
                started.continuation.yield()
                try await Task.sleep(for: .seconds(30))
                return "finished"
            }
        }
        for await _ in started.stream { break }
        #expect(await calls.inFlightCount(chatId: chatId) == 1)
        await calls.cancelAll(chatId: chatId)
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(await calls.inFlightCount(chatId: chatId) == 0)
    }

    @Test func cancellingTheRequestCancelsTheCall() async throws {
        let calls = HarnessBridgeCalls()
        let started = AsyncStream<Void>.makeStream()
        let call = Task {
            try await calls.run(chatId: chatId) {
                started.continuation.yield()
                try await Task.sleep(for: .seconds(30))
                return "finished"
            }
        }
        for await _ in started.stream { break }
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
    }

    @Test func servedCallsAreKeptPerChatAndBounded() async {
        let calls = HarnessBridgeCalls()
        func served(_ id: String, result: String = "{}") -> HarnessBridgeCalls.Record {
            .init(toolCallId: id, name: "workflow_draft", arguments: "{}", result: result, isError: false, durationMs: 1)
        }
        for index in 0 ..< HarnessBridgeCalls.recordLimit + 5 { await calls.record(served("toolu_\(index)"), chatId: chatId) }
        await calls.record(served("toolu_big", result: String(repeating: "x", count: HarnessBridgeCalls.fieldLimit * 2)), chatId: chatId)
        let kept = await calls.records(chatId: chatId)
        #expect(kept.count == HarnessBridgeCalls.recordLimit)
        #expect(kept.first?.toolCallId == "toolu_6")
        #expect(await calls.record(chatId: chatId, toolCallId: "toolu_big")?.result.count == HarnessBridgeCalls.fieldLimit)
        #expect(await calls.records(chatId: UUID()).isEmpty)
        await calls.clearRecords(chatId: chatId)
        #expect(await calls.records(chatId: chatId).isEmpty)
    }

    /// The harness's stream reports only that an Osaurus tool ran; the card
    /// shows what Osaurus itself received and returned.
    @Test func aServedCallsDetailLandsOnItsToolRow() {
        let turn = ChatTurn(role: .assistant, content: "")
        turn.noteRemoteToolStarted(callId: "toolu_1", name: "workflow_draft")
        turn.noteRemoteToolFinished(callId: "toolu_1", name: "workflow_draft", isError: false)
        let result = #"{"ok":true,"result":{"applied":1}}"#
        turn.noteRemoteToolDetail(callId: "toolu_1", arguments: #"{"action":"patch"}"#, result: result)
        turn.noteRemoteToolDetail(callId: "toolu_unseen", arguments: "{}", result: "{}")
        #expect(turn.remoteToolActivity.map(\.id) == ["toolu_1"])
        #expect(turn.remoteToolActivity.first?.function.name == "workflow_draft")
        #expect(turn.remoteToolActivity.first?.function.arguments == #"{"action":"patch"}"#)
        #expect(turn.remoteToolResults["toolu_1"] == result)
    }

    /// A step of a run a bridge call started binds its prompts from the
    /// run's caller, never from the call's task.
    @Test func callersCarryTheirPromptDenial() async {
        let denied = await ChatExecutionContext.$denyUnapprovedToolPrompts.withValue(true) {
            await WorkflowToolCall.caller(kind: .orchestrator)
        }
        let open = await WorkflowToolCall.caller(kind: .orchestrator)
        #expect(denied.deniesUnapprovedPrompts)
        #expect(!open.deniesUnapprovedPrompts)

        let decoded = try? JSONDecoder().decode(WorkflowCaller.self, from: JSONEncoder().encode(denied))
        #expect(decoded?.deniesUnapprovedPrompts == true)
    }
}

private struct BridgeScopeProbeTool: OsaurusTool {
    static let toolName = "harness_bridge_scope_probe"
    let name = BridgeScopeProbeTool.toolName
    let description = "Reports the execution scope of a bridge call"
    let parameters: JSONValue? = nil

    func execute(argumentsJSON: String) async throws -> String {
        var out: [String: JSONValue] = [
            "external": .bool(ChatExecutionContext.isExternalSurface),
            "deny": .bool(ChatExecutionContext.denyUnapprovedToolPrompts),
        ]
        if let source = ChatExecutionContext.currentSessionSource { out["source"] = .string(source.rawValue) }
        if let folder = ChatExecutionContext.currentFolderRoot { out["folder"] = .string(folder.path) }
        if let id = ChatExecutionContext.currentToolCallId { out["tool_call_id"] = .string(id) }
        if let session = ChatExecutionContext.currentSessionId { out["session"] = .string(session) }
        if let chat = ChatExecutionContext.harnessChatId { out["harness_chat"] = .string(chat.uuidString) }
        let data = try JSONEncoder().encode(JSONValue.object(out))
        return String(decoding: data, as: UTF8.self)
    }
}
