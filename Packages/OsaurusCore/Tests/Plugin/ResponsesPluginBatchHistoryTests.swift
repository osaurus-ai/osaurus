import Foundation
import Testing

@testable import OsaurusCore

@Suite("Plugin authoritative tool batch history")
struct ResponsesPluginBatchHistoryTests {
    private func assistant(ids: [String] = ["first", "guarded", "later"]) -> ChatMessage {
        ChatMessage(
            role: "assistant", content: "Checking.",
            tool_calls: ids.map { ToolCall(id: $0, type: "function", function: .init(name: "fixture", arguments: "{}")) },
            tool_call_id: nil, reasoning_content: "Native earlier reasoning",
            reasoning_item_id: "rs_batch", reasoning_encrypted: "opaque",
            responses_output_items: [.object(["id": .string("msg_batch"), "phase": .string("commentary"), "future": .bool(true)])]
        )
    }

    @Test func completeBatchCommitsGuardedResultsInOriginalOrderOnce() throws {
        var history = ResponsesToolBatchHistory()
        try history.begin(assistant())
        history.record(callID: "later", result: "actual-later")
        history.record(callID: "first", result: "actual-first")
        let guarded = AgentLoopToolOutcome(
            invocation: .init(toolName: "fixture", jsonArguments: "{}", toolCallId: "guarded"),
            callId: "guarded", result: "guard-refusal", wasDeduped: false, wasError: true
        )
        let completed = history.complete([guarded])
        let commit = try #require(completed)
        #expect(commit.results.map(\.tool_call_id) == ["first", "guarded", "later"])
        #expect(commit.results.map(\.content) == ["actual-first", "guard-refusal", "actual-later"])
        #expect(commit.assistant.responses_output_items == assistant().responses_output_items)
        #expect(commit.assistant.reasoning_content == "Native earlier reasoning")
        #expect(commit.assistant.reasoning_item_id == "rs_batch" && commit.assistant.reasoning_encrypted == "opaque")
        #expect(history.complete([]) == nil)
        #expect(history.finish(runExit: "cancelled") == nil)
    }

    @Test func cancellationPreservesCompletedResultAndMarksRemainingCallsUnstarted() throws {
        var history = ResponsesToolBatchHistory()
        try history.begin(assistant())
        history.record(callID: "first", result: "actual-first")
        #expect(history.complete([]) == nil)
        let finished = history.finish(runExit: "cancelled")
        let commit = try #require(finished)
        #expect(commit.messages.count == 4)
        #expect(commit.results.first?.content == "actual-first")
        for row in commit.results.dropFirst() {
            let body = try #require(try JSONSerialization.jsonObject(with: Data((row.content ?? "").utf8)) as? [String: Any])
            #expect(body["execution_state"] as? String == "not_started")
            #expect(body["run_exit"] as? String == "cancelled")
            #expect(body["retryable"] as? Bool == false)
            #expect(body["ok"] as? Bool == false)
        }
        #expect(history.finish(runExit: "cancelled") == nil)
    }

    @Test func invalidOrOverlappingModelBatchesCannotLoseCallIdentity() throws {
        for ids in [["same", "same"], [""], [" \t "]] {
            var history = ResponsesToolBatchHistory()
            #expect(throws: ResponsesToolBatchHistory.Failure.self) { try history.begin(assistant(ids: ids)) }
        }
        var history = ResponsesToolBatchHistory()
        try history.begin(assistant(ids: ["original"]))
        #expect(throws: ResponsesToolBatchHistory.Failure.self) { try history.begin(assistant(ids: ["replacement"])) }
        let finished = history.finish(runExit: "endedBySurface")
        let commit = try #require(finished)
        #expect(commit.results.map(\.tool_call_id) == ["original"])
    }
}
