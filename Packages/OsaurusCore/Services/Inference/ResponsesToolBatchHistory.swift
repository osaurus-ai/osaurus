import Foundation

/// Commits a model's completed assistant batch with one ordered result for
/// every call. Executed, deduped and driver-guarded results share this path.
/// A terminal run explicitly records remaining calls as not executed.
struct ResponsesToolBatchHistory {
    struct Commit {
        let assistant: ChatMessage
        let results: [ChatMessage]
        var messages: [ChatMessage] { [assistant] + results }
    }
    enum Failure: Error, LocalizedError {
        case unfinishedBatch
        case invalidCallIdentity
        var errorDescription: String? {
            switch self {
            case .unfinishedBatch: return "A previous tool batch has not finished."
            case .invalidCallIdentity: return "The model returned empty or duplicate tool call IDs. The batch was not executed."
            }
        }
    }
    private var assistant: ChatMessage?
    private var results: [String: String] = [:]

    mutating func begin(_ message: ChatMessage) throws {
        guard assistant == nil else { throw Failure.unfinishedBatch }
        let calls = message.tool_calls ?? []
        let ids = calls.map(\.id)
        guard !ids.isEmpty, ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
            Set(ids).count == ids.count
        else { throw Failure.invalidCallIdentity }
        assistant = message
        results.removeAll(keepingCapacity: true)
    }

    mutating func record(callID: String, result: String) {
        results[callID] = result
    }

    mutating func complete(_ outcomes: [AgentLoopToolOutcome]) -> Commit? {
        for outcome in outcomes { record(callID: outcome.callId, result: outcome.result) }
        guard let assistant,
            (assistant.tool_calls ?? []).allSatisfy({ results[$0.id] != nil })
        else { return nil }
        return takeCommit()
    }

    mutating func finish(runExit: String) -> Commit? {
        guard let assistant else { return nil }
        for call in assistant.tool_calls ?? [] where results[call.id] == nil {
            results[call.id] = ToolEnvelope.failure(
                kind: .executionError,
                message: "Tool call was not executed because the run ended (\(runExit)).",
                tool: call.function.name,
                retryable: false,
                metadata: ["execution_state": "not_started", "run_exit": runExit]
            )
        }
        return takeCommit()
    }

    private mutating func takeCommit() -> Commit? {
        guard let assistant else { return nil }
        let rows = (assistant.tool_calls ?? []).map { call in
            ChatMessage(role: "tool", content: results[call.id], tool_calls: nil, tool_call_id: call.id)
        }
        self.assistant = nil
        results.removeAll(keepingCapacity: true)
        return Commit(assistant: assistant, results: rows)
    }
}
