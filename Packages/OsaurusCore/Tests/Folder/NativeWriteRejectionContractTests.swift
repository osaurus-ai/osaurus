import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct NativeWriteRejectionContractTests {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("real-write-rejection-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func exactEvalWriteIsARealNonretryableRejectionBeforeMutation() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await FileWriteTool(rootPath: root).execute(
            argumentsJSON: #"{"path":"report.pptm","content":"hello"}"#)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(payload["ok"] as? Bool == false)
        #expect(payload["kind"] as? String == "rejected")
        #expect(payload["retryable"] as? Bool == false)
        #expect(payload["extension"] as? String == "pptm")
        #expect(payload["tool"] as? String == "file_write")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("report.pptm").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("report.pptx").path))
    }

    private actor Model: ResponsesEngineProtocol {
        private(set) var modelSteps = 0
        func streamResponses(request: ResponsesInferenceRequest) async throws -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
            modelSteps += 1
            guard modelSteps == 1 else { throw NSError(domain: "unexpected-model-continuation", code: 1) }
            let calls: [ResponsesFunctionCall] = [
                .init(id: "fc_rejected", callID: "call_rejected", name: "file_write", arguments: #"{"path":"report.pptm","content":"hello"}"#),
                .init(id: "fc_later", callID: "call_later", name: "file_write", arguments: #"{"path":"must-not-exist.txt","content":"later side effect"}"#),
            ]
            return AsyncThrowingStream { continuation in
                continuation.yield(.responseCompleted(.init(responseID: "resp_real_rejection", status: .completed,
                    functionCalls: calls, tokenCount: 7, tokensPerSecond: 20,
                    unclosedReasoning: false, stopReason: "tool_calls", promptTokensPerSecond: nil, mtp: nil)))
                continuation.finish()
            }
        }
    }

    @Test func realRejectedWriteStopsTypedLoopBeforeSiblingOrAnotherModelStep() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Model()
        var pending = ResponsesToolBatchHistory()
        var executed: [String] = []
        var recorded: [AgentLoopToolOutcome] = []
        let hooks = AgentLoopHooks(
            buildMessages: { _ in .init(messages: [.init(role: "user", content: "Write the requested file.")]) },
            modelStep: { messages, _ in
                let response = try await ResponsesEvaluationStep.collect(engine: model,
                    request: .init(model: "scripted-real-write", input: messages))
                try pending.begin(response.completedAssistantInput())
                return try ResponsesEvaluationStep.classify(response, toolsWereOffered: true)
            },
            executeTool: { invocation, callID in
                executed.append(callID)
                do {
                    let envelope = try await FileWriteTool(rootPath: root).execute(argumentsJSON: invocation.jsonArguments)
                    return .init(result: envelope, isError: ToolEnvelope.isError(envelope))
                } catch {
                    Issue.record("Real FileWriteTool unexpectedly threw: \(error)")
                    return .init(result: ToolEnvelope.failure(kind: .executionError, message: error.localizedDescription), isError: true)
                }
            },
            onBatchComplete: { outcomes in
                recorded.append(contentsOf: outcomes)
                for outcome in outcomes { pending.record(callID: outcome.callId, result: outcome.result) }
            }
        )
        let result = try await AgentToolLoop.run(policy: .init(maxIterations: 4,
            stopOnToolRejection: true, dedupeNoticeEnabled: false), state: AgentTaskState(), hooks: hooks)
        #expect(result.exit == .toolRejected)
        #expect(result.iterations == 1)
        #expect(await model.modelSteps == 1)
        #expect(executed == ["call_rejected"])
        #expect(recorded.map(\.callId) == ["call_rejected"])
        let rejection = try #require(recorded.first)
        #expect(rejection.wasError && !rejection.wasDeduped)
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(rejection.result.utf8)) as? [String: Any])
        #expect(envelope["kind"] as? String == "rejected")
        let finished = pending.finish(runExit: "toolRejected")
        let history = try #require(finished)
        #expect(history.assistant.tool_calls?.map(\.id) == ["call_rejected", "call_later"])
        try #require(history.results.count == 2)
        let skipped = try #require(JSONSerialization.jsonObject(with: Data((history.results[1].content ?? "").utf8)) as? [String: Any])
        #expect(skipped["execution_state"] as? String == "not_started")
        #expect(skipped["run_exit"] as? String == "toolRejected")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("report.pptm").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-exist.txt").path))
    }
}
