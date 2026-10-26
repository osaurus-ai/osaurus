import Foundation
import Testing
import os

@testable import OsaurusCore

@Suite("Plugin production Responses loops", .serialized, .timeLimit(.minutes(1)))
struct ResponsesPluginLoopTests {
    private actor Executions {
        var slots: [Int] = []
        func record(_ slot: Int) { slots.append(slot) }
    }
    private struct ProbeTool: OsaurusTool {
        let name: String
        let executions: Executions
        let description = "Fixture echo with no file, process or network access"
        var parameters: JSONValue? { .object([
            "type": .string("object"), "additionalProperties": .bool(false),
            "properties": .object(["slot": .object(["type": .string("integer")])]),
            "required": .array([.string("slot")]),
        ]) }
        func execute(argumentsJSON: String) async throws -> String {
            let body = try JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Int]
            let slot = body?["slot"] ?? -1
            await executions.record(slot)
            return ToolEnvelope.success(tool: name, text: "fixture-result-\(slot)")
        }
    }
    private actor Engine: ResponsesEngineProtocol {
        let rows: [[ResponsesGenerationEvent]]
        private(set) var requests: [ResponsesInferenceRequest] = []
        init(_ rows: [[ResponsesGenerationEvent]]) { self.rows = rows }
        func streamResponses(request: ResponsesInferenceRequest) async throws
            -> AsyncThrowingStream<ResponsesGenerationEvent, Error>
        {
            let index = requests.count
            requests.append(request)
            guard index < rows.count else { throw NSError(domain: "unexpected-replay", code: 999) }
            let events = rows[index]
            return AsyncThrowingStream { c in
                for event in events { c.yield(event) }
                // Deliberately no EOF: production plugin steps must dispatch
                // at logical completion, not wait for the producer's tail.
            }
        }
    }
    private final class Chunks: @unchecked Sendable {
        let values = OSAllocatedUnfairLock(initialState: [String]())
        weak var context: PluginHostContext?
        let cancelOnStop: Bool
        let streamID: String
        init(context: PluginHostContext, streamID: String, cancelOnStop: Bool = false) {
            self.context = context; self.streamID = streamID; self.cancelOnStop = cancelOnStop
        }
        func record(_ text: String) {
            values.withLock { $0.append(text) }
            guard cancelOnStop,
                let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                choices.first?["finish_reason"] as? String == "stop"
            else { return }
            context?.completeCancel(streamId: streamID)
        }
    }
    private let raw: JSONValue = .object([
        "type": .string("message"), "id": .string("msg_plugin"), "phase": .string("commentary"),
        "future": .object(["retained": .bool(true)]),
    ])
    private func row(
        _ text: String, calls: [ResponsesFunctionCall] = [],
        status: ResponsesGenerationCompletion.Status = .completed, measured: Bool = true
    ) -> [ResponsesGenerationEvent] {
        [
            .inputTokenCount(111), .outputTextDelta(text), .reasoningDelta("fixture reasoning"),
            .providerOutputItem(raw), .reasoningItem(.init(id: "rs_plugin", encryptedContent: "opaque")),
            .responseCompleted(.init(
                responseID: "resp_plugin", status: status, functionCalls: calls,
                tokenCount: measured ? 20 : nil, tokensPerSecond: measured ? 33.123456789 : nil,
                unclosedReasoning: false, stopReason: status == .incomplete ? "length" : "stop",
                promptTokensPerSecond: nil, mtp: nil
            )),
        ]
    }
    private func body(tool: ProbeTool? = nil, streamID: String = UUID().uuidString) throws -> String {
        var value: [String: Any] = [
            "model": "plugin-fixture-model", "messages": [["role": "user", "content": "fixture task"]],
            "session_id": UUID().uuidString, "stream_id": streamID, "max_iterations": 3,
        ]
        if let tool {
            let spec = Tool(type: "function", function: ToolFunction(name: tool.name, description: nil, parameters: tool.parameters))
            value["tools"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([spec]))
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    private func invoke(_ context: PluginHostContext, body: String, streaming: Bool, chunks: Chunks) async -> String {
        await Task.detached {
            if streaming {
                return context.completeStream(requestJSON: body, onChunk: { text, userData in
                    guard let text, let userData else { return }
                    Unmanaged<Chunks>.fromOpaque(userData).takeUnretainedValue().record(String(cString: text))
                }, userData: Unmanaged.passUnretained(chunks).toOpaque())
            }
            return context.complete(requestJSON: body)
        }.value
    }

    @Test(arguments: [false, true])
    @MainActor
    func bothPublicEntryPointsKeepOneWholeBatchAndExactResultIDs(_ streaming: Bool) async throws {
        let executions = Executions()
        let tool = ProbeTool(name: "responses_fixture_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), executions: executions)
        ToolRegistry.shared.register(tool)
        ToolRegistry.shared.setEnabled(true, for: tool.name)
        defer {
            ToolRegistry.shared.setEnabled(false, for: tool.name)
            ToolRegistry.shared.unregister(names: [tool.name])
        }
        let calls = [1, 2].map { n in ResponsesFunctionCall(
            id: "fc_\(n)", callID: "call_\(n)", name: tool.name, arguments: "{\"slot\":\(n)}",
            geminiThoughtSignature: "signature-\(n)"
        ) }
        let engine = Engine([row("Checking both.", calls: calls), row("Both results received.")])
        let context = try PluginHostContext(pluginId: "test.responses.\(UUID())", inferenceEngineFactory: { engine })
        let chunks = Chunks(context: context, streamID: "fixture")
        let answer = await invoke(context, body: try body(tool: tool), streaming: streaming, chunks: chunks)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        #expect(json["error"] == nil)
        #expect(await executions.slots.sorted() == [1, 2])
        let requests = await engine.requests
        #expect(requests.count == 2)
        let assistants = requests[1].input.filter { $0.role == "assistant" }
        #expect(assistants.count == 1)
        let assistant = try #require(assistants.first)
        #expect(assistant.content == "Checking both.")
        #expect(assistant.tool_calls?.map(\.id) == ["call_1", "call_2"])
        #expect(assistant.tool_calls?.map(\.geminiThoughtSignature) == ["signature-1", "signature-2"])
        #expect(assistant.responses_output_items == [raw])
        #expect(assistant.reasoning_item_id == "rs_plugin" && assistant.reasoning_encrypted == "opaque")
        // The shared composer adds transient tool-role environment feedback
        // to preserve Qwen's last-user reasoning/cache anchor. Those notices
        // are not additional executions or persisted tool results.
        let outputs = requests[1].input.filter {
            $0.role == "tool" && !($0.content ?? "").hasPrefix("[System Notice]")
        }
        #expect(outputs.map(\.tool_call_id) == ["call_1", "call_2"])
        #expect(outputs[0].content?.contains("fixture-result-1") == true)
        #expect(outputs[1].content?.contains("fixture-result-2") == true)
        #expect((json["usage"] as? [String: Any])?["tokens_per_second"] as? Double == 33.123456789)
    }

    @Test(arguments: [false, true])
    func lengthCannotExecuteOtherwiseCompleteToolArguments(_ streaming: Bool) async throws {
        let executions = Executions()
        let tool = ProbeTool(name: "responses_length_fixture", executions: executions)
        let call = ResponsesFunctionCall(id: "fc_1", callID: "call_1", name: tool.name, arguments: #"{"slot":1}"#)
        let engine = Engine([row("partial", calls: [call], status: .incomplete)])
        let context = try PluginHostContext(pluginId: "test.responses.length.\(UUID())", inferenceEngineFactory: { engine })
        let answer = await invoke(context, body: try body(tool: tool), streaming: streaming,
            chunks: Chunks(context: context, streamID: "fixture"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        #expect(json["error"] as? String == "output_token_limit")
        #expect(await executions.slots.isEmpty)
        #expect(await engine.requests.count == 1)
    }

    @Test func missingMeteringStaysAbsentAtCompatibilityBoundary() async throws {
        let engine = Engine([row("answer", measured: false)])
        let context = try PluginHostContext(pluginId: "test.responses.metering.\(UUID())", inferenceEngineFactory: { engine })
        let answer = await invoke(context, body: try body(), streaming: false,
            chunks: Chunks(context: context, streamID: "fixture"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        #expect(json["error"] == nil && json["usage"] == nil)
        let metrics = try #require(json["generation_metrics"] as? [String: Any])
        #expect(metrics["completion_tokens"] == nil && metrics["tokens_per_second"] == nil)
    }

    @Test(arguments: [false, true])
    func upstreamCancellationIsNotAttributedToThePluginOrReplayed(_ streaming: Bool) async throws {
        let engine = Engine([row("partial", status: .cancelled)])
        let context = try PluginHostContext(pluginId: "test.responses.upstream.\(UUID())", inferenceEngineFactory: { engine })
        let chunks = Chunks(context: context, streamID: "fixture")
        let answer = await invoke(context, body: try body(), streaming: streaming, chunks: chunks)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        #expect(json["error"] as? String == "inference_error")
        #expect((json["message"] as? String)?.contains("upstream") == true)
        #expect(await engine.requests.count == 1)
        if streaming {
            #expect(chunks.values.withLock { $0.filter { $0.contains(#""finish_reason":"error""#) }.count } == 1)
        }
    }

    @Test func cancelFromFinalChunkCallbackCannotRelabelOrEmitAnotherTerminal() async throws {
        let streamID = UUID().uuidString
        let engine = Engine([row("answer")])
        let context = try PluginHostContext(pluginId: "test.responses.latecancel.\(UUID())", inferenceEngineFactory: { engine })
        let chunks = Chunks(context: context, streamID: streamID, cancelOnStop: true)
        let answer = await invoke(context, body: try body(streamID: streamID), streaming: true, chunks: chunks)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        #expect(json["error"] == nil)
        let reasons = chunks.values.withLock { values in values.compactMap { text -> String? in
            guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                let choices = value["choices"] as? [[String: Any]] else { return nil }
            return choices.first?["finish_reason"] as? String
        } }
        #expect(reasons == ["stop"])
    }
}
