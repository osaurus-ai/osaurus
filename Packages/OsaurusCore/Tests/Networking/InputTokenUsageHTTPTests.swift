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
        let server = try await startTestServer(with: ChatEngine(
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
                #expect(frames.first?["type"] as? String == "message_start")
                let message = frames.first?["message"] as? [String: Any]
                let initialUsage = message?["usage"] as? [String: Any]
                #expect(initialUsage?["input_tokens"] as? Int == 257)
            }
        }
    }
}
