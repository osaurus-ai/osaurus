import Foundation
import Testing
import os

@testable import OsaurusCore

@Suite("HTTP canonical tool-choice failures", .serialized, .timeLimit(.minutes(2)))
struct HTTPToolChoiceContractTests {
    private enum NativeIdentity: Sendable { case snapshot, early, absent }
    private final class Capture: Sendable {
        let calls = OSAllocatedUnfairLock(initialState: 0)
    }

    /// The real ChatEngine owns preflight and whole-response validation.
    /// This fixture replaces only the inference service, never those gates.
    private struct Service: ResponsesGenerationService {
        let capture: Capture
        let nativeEvents: Bool
        var nativeIdentity: NativeIdentity = .snapshot
        var failBeforeCompletion = false
        var id: String { "http-choice-fixture" }
        func isAvailable() -> Bool { true }
        func handles(requestedModel: String?) -> Bool { requestedModel == id }
        func generateOneShot(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?) async throws -> String {
            throw NSError(domain: "unexpected-legacy", code: 1)
        }
        func streamDeltas(messages: [ChatMessage], parameters: GenerationParameters,
            requestedModel: String?, stopSequences: [String]) async throws
            -> AsyncThrowingStream<String, Error> {
            throw NSError(domain: "unexpected-legacy", code: 2)
        }
        func streamResponses(messages: [ChatMessage], parameters: GenerationParameters,
            stopSequences: [String], tools: [Tool], toolChoice: ToolChoiceOption?,
            requestedModel: String?) async throws -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
            capture.calls.withLock { $0 += 1 }
            return AsyncThrowingStream { c in
                if nativeEvents {
                    let first: JSONValue
                    switch nativeIdentity {
                    case .snapshot:
                        first = .object(["type": .string("response.created"), "sequence_number": .number(1),
                            "response": .object(["id": .string("resp_provider_choice"), "status": .string("in_progress"),
                                "model": .string("http-choice-fixture"), "created_at": .number(123)])])
                    case .early:
                        first = .object(["type": .string("response.in_progress"), "sequence_number": .number(9),
                            "response_id": .string("resp_provider_choice")])
                    case .absent:
                        first = .object(["type": .string("response.in_progress"), "sequence_number": .number(9)])
                    }
                    c.yield(.providerEvent(first))
                    if failBeforeCompletion {
                        c.finish(throwing: NSError(domain: "NativeFixtureTransport", code: 502,
                            userInfo: [NSLocalizedDescriptionKey: "upstream failed before response identity was complete"]))
                        return
                    }
                    // A provider's success cannot escape the common contract
                    // before its complete named batch has validated.
                    c.yield(.providerEvent(.object(["type": .string("response.completed"),
                        "sequence_number": .number(2),
                        "response": .object(["id": .string("resp_provider_choice"), "status": .string("completed")])])))
                }
                c.yield(.responseCompleted(.init(responseID: "resp_provider_choice", status: .completed,
                    functionCalls: [
                        .init(id: "fc_target", callID: "call_target", name: "target", arguments: #"{"count":"7"}"#),
                        .init(id: "fc_other", callID: "call_other", name: "other", arguments: "{}"),
                    ], tokenCount: 7, tokensPerSecond: 41, unclosedReasoning: false, stopReason: "tool_calls",
                    promptTokensPerSecond: nil, mtp: nil, inputTokenCount: 19)))
                c.finish()
            }
        }
    }

    @Test(arguments: [true, false], [true, false])
    func nativeEarlyFailureDoesNotInventResponseSnapshot(
        hasEarlyID: Bool, terminalContractFailure: Bool
    ) async throws {
        let capture = Capture()
        let service = Service(capture: capture, nativeEvents: true,
            nativeIdentity: hasEarlyID ? .early : .absent, failBeforeCompletion: !terminalContractFailure)
        let engine = ChatEngine(services: [service], installedModelsProvider: { [] }, remoteServicesProvider: { [] })
        let server = try await startChatStreamingTestServer(with: engine)
        defer { Task { await server.shutdown() } }
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "X-Persist")
        request.authenticate()
        request.httpBody = Data(#"{"model":"http-choice-fixture","input":"go","stream":true,"tools":[{"type":"function","name":"target"}],"tool_choice":{"type":"function","name":"target"}}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let body = String(decoding: data, as: UTF8.self)
        let frames = try body.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("data: ") && $0 != "data: [DONE]" }
            .map { try #require(JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as? [String: Any]) }
        let errors = frames.filter { $0["type"] as? String == "error" }
        #expect(errors.count == 1)
        let error = try #require(errors.first)
        #expect(error["sequence_number"] as? Int == 10)
        #expect(error["code"] as? String == (terminalContractFailure ? "invalid_request_error" : "api_error"))
        #expect(error["response"] == nil)
        #expect(error["response_id"] as? String == (hasEarlyID || terminalContractFailure ? "resp_provider_choice" : nil))
        #expect(!body.contains("response.completed") && !body.contains("response.failed"))
        #expect(capture.calls.withLock { $0 } == 1)
    }

    @Test(arguments: [true, false], ["/chat/completions", "/api/chat", "/messages", "/responses"].flatMap { path in
        [true, false].map { preflight in (path: path, preflight: preflight) }
    })
    func namedContractErrorsUseEachWireWithoutSuccessfulTerminal(
        streaming: Bool, row: (path: String, preflight: Bool)
    ) async throws {
        let capture = Capture()
        let engine = ChatEngine(services: [Service(capture: capture, nativeEvents: row.path == "/responses")],
            installedModelsProvider: { [] }, remoteServicesProvider: { [] })
        let server = try await startChatStreamingTestServer(with: engine)
        defer { Task { await server.shutdown() } }
        let names = row.preflight ? ["other"] : ["target", "other"]
        var payload: [String: Any] = ["model": "http-choice-fixture", "stream": streaming, "max_tokens": 16]
        let schema: [String: Any] = ["type": "object", "properties": ["count": ["type": "string"]]]
        switch row.path {
        case "/responses":
            payload["max_output_tokens"] = payload.removeValue(forKey: "max_tokens")
            payload["input"] = "perform target"
            payload["tools"] = names.map { ["type": "function", "name": $0, "parameters": schema] as [String: Any] }
            payload["tool_choice"] = ["type": "function", "name": "target"]
        case "/messages":
            payload["messages"] = [["role": "user", "content": "perform target"]]
            payload["tools"] = names.map { ["name": $0, "input_schema": schema] as [String: Any] }
            payload["tool_choice"] = ["type": "tool", "name": "target"]
        default:
            payload["messages"] = [["role": "user", "content": "perform target"]]
            payload["tools"] = names.map {
                ["type": "function", "function": ["name": $0, "parameters": schema]] as [String: Any]
            }
            payload["tool_choice"] = ["type": "function", "function": ["name": "target"]]
        }
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(row.path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "X-Persist")
        request.authenticate()
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        let body = String(decoding: data, as: UTF8.self)
        #expect((response as? HTTPURLResponse)?.statusCode == (streaming && !row.preflight ? 200 : 422))
        #expect(capture.calls.withLock { $0 } == (row.preflight ? 0 : 1))
        #expect(!body.contains("unexpected-legacy"))
        #expect(!body.contains("\"finish_reason\":\"stop\"") && !body.contains("\"finish_reason\":\"tool_calls\""))
        #expect(!body.contains("\"done_reason\":\"stop\"") && !body.contains("\"type\":\"message_stop\""))
        #expect(!body.contains("response.completed") && !body.contains("call_target") && !body.contains("call_other"))
        let frames: [[String: Any]]
        if streaming && !row.preflight && row.path != "/api/chat" {
            frames = try body.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("data: ") && $0 != "data: [DONE]" }
                .map { try #require(JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as? [String: Any]) }
        } else if streaming && !row.preflight {
            frames = try body.components(separatedBy: .newlines).filter { !$0.isEmpty }
                .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        } else {
            frames = [try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])]
        }
        let errors = frames.compactMap { $0["error"] as? [String: Any] }
        #expect(errors.count == 1)
        let error = try #require(errors.first)
        #expect(error[row.path == "/responses" ? "code" : "type"] as? String == "invalid_request_error")
        #expect((error["message"] as? String)?.contains(row.preflight ? "not declared" : "whole response") == true)
        if streaming && !row.preflight && row.path == "/responses" {
            let failures = frames.filter { $0["type"] as? String == "response.failed" }
            #expect(failures.count == 1)
            #expect((failures.first?["response"] as? [String: Any])?["id"] as? String == "resp_provider_choice")
            #expect(failures.first?["sequence_number"] as? Int == 2)
        }
    }
}
