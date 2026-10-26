import Foundation
import Testing

@testable import OsaurusCore

@Suite("Input usage across HTTP protocols")
struct InputTokenUsageHTTPTests {
    @Test(arguments: ["/chat/completions", "/responses", "/messages", "/api/chat", "/api/generate"], [true, false])
    func preparedAndTerminalCountsReachTheWire(path: String, streaming: Bool) async throws {
        let service = FakeModelService(deltas: [
            StreamingInputTokenHint.encode(257), "visible answer",
            StreamingStatsHint.encode(tokenCount: 59, tokensPerSecond: 17.5,
                                      stopReason: "stop", inputTokenCount: 263),
        ])
        let server = try await startChatStreamingTestServer(with: ChatEngine(
            services: [service], installedModelsProvider: { [] }))
        defer { Task { await server.shutdown() } }
        var body: [String: Any] = ["model": "fake", "stream": streaming, "max_tokens": 128]
        switch path {
        case "/responses": body["input"] = "hi"
        case "/api/generate": body["prompt"] = "hi"
        default: body["messages"] = [["role": "user", "content": "hi"]]
        }
        if path == "/chat/completions" { body["stream_options"] = ["include_usage": true] }
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "X-Persist")
        request.authenticate()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\u{FFFE}"))
        #expect(!text.contains("input_tokens:"))
        let frames: [[String: Any]]
        if streaming {
            frames = text.components(separatedBy: CharacterSet.newlines).compactMap { line in
                let json = line.hasPrefix("data: ") ? String(line.dropFirst(6)) : line
                return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            }
        } else {
            frames = [try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])]
        }
        if path.hasPrefix("/api/") {
            let final = try #require(frames.last)
            #expect(final["done"] as? Bool == true)
            #expect(final["prompt_eval_count"] as? Int == 263)
            #expect(final["eval_count"] as? Int == 59)
            for chunk in frames.dropLast() {
                #expect(chunk["prompt_eval_count"] == nil)
                #expect(chunk["eval_count"] == nil)
            }
        } else if path == "/responses" {
            let response = streaming ? frames.last?["response"] as? [String: Any] : frames.first
            let usage = try #require(response?["usage"] as? [String: Any])
            #expect(usage["input_tokens"] as? Int == 263)
            #expect(usage["output_tokens"] as? Int == 59)
        } else {
            let usage = try #require(frames.compactMap { $0["usage"] as? [String: Any] }.last)
            #expect(usage[path == "/messages" ? "input_tokens" : "prompt_tokens"] as? Int == 263)
            #expect(usage[path == "/messages" ? "output_tokens" : "completion_tokens"] as? Int == 59)
            if path == "/messages", streaming {
                let starts = frames.filter { $0["type"] as? String == "message_start" }
                let deltas = frames.filter { $0["type"] as? String == "message_delta" }
                #expect(starts.count == 1, "a terminal count correction must not emit another message_start")
                #expect(deltas.count == 1)
                #expect(frames.first?["type"] as? String == "message_start")
                #expect(frames.last?["type"] as? String == "message_stop")
                let message = starts.first?["message"] as? [String: Any]
                let initialUsage = message?["usage"] as? [String: Any]
                #expect(initialUsage?["input_tokens"] as? Int == 257)
                let finalUsage = try #require(deltas.first?["usage"] as? [String: Any])
                #expect(finalUsage["input_tokens"] as? Int == 263)
                #expect(finalUsage["output_tokens"] as? Int == 59)
            }
        }
    }

    @Test(arguments: [true, false])
    func anthropicMissingTerminalUsageRemainsAnError(streaming: Bool) async throws {
        // The prepared input count is known, but clean EOF is not a measured
        // completion count. Do not manufacture a successful zero-output turn.
        let service = FakeModelService(deltas: [
            StreamingInputTokenHint.encode(257), "visible partial answer",
        ])
        let server = try await startChatStreamingTestServer(with: ChatEngine(
            services: [service], installedModelsProvider: { [] }))
        defer { Task { await server.shutdown() } }
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "X-Persist")
        request.authenticate()
        let body: [String: Any] = [
            "model": "fake", "stream": streaming, "max_tokens": 128,
            "messages": [["role": "user", "content": "hi"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\u{FFFE}"))
        if streaming {
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let frames = text.components(separatedBy: CharacterSet.newlines).compactMap { line -> [String: Any]? in
                guard line.hasPrefix("data: ") else { return nil }
                return (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))) as? [String: Any]
            }
            let starts = frames.filter { $0["type"] as? String == "message_start" }
            #expect(starts.count == 1)
            let message = starts.first?["message"] as? [String: Any]
            #expect((message?["usage"] as? [String: Any])?["input_tokens"] as? Int == 257)
            #expect(frames.contains { $0["type"] as? String == "error" })
            #expect(!frames.contains { $0["type"] as? String == "message_delta" })
            #expect(!frames.contains { $0["type"] as? String == "message_stop" })
            #expect(!frames.contains { $0["usage"] != nil }, "unknown terminal usage must not become a synthetic final frame")
        } else {
            // Preserve the current compatibility error-status contract. The
            // missing-usage error is mapped to the standard internal error.
            #expect((response as? HTTPURLResponse)?.statusCode == 500)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["type"] as? String == "error")
            #expect(body["error"] as? [String: Any] != nil)
            #expect(body["usage"] == nil)
            #expect(body["content"] == nil)
        }
    }
}
