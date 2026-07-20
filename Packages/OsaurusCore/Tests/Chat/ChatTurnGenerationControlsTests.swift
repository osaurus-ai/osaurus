//
//  ChatTurnGenerationControlsTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Chat turn generation controls")
struct ChatTurnGenerationControlsTests {
    private func request() -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: "JANGQ-AI/Ornith-1.0-9B-JANG_4M",
            messages: [ChatMessage(role: "user", content: "Use three tools")],
            temperature: nil,
            max_tokens: 64,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )
    }

    @Test("explicit Thinking off reaches every reconstructed tool-loop request")
    func explicitOffPropagatesAcrossIterations() throws {
        let controls = ChatTurnGenerationControls.capture(
            activeModelOptions: ["disableThinking": .bool(true)]
        )

        var requests = [request(), request(), request(), request()]
        for index in requests.indices {
            controls.apply(to: &requests[index])
        }

        #expect(controls.enableThinking == false)
        #expect(requests.allSatisfy { $0.enable_thinking == false })
        #expect(
            requests.allSatisfy {
                $0.modelOptions?["disableThinking"]?.boolValue == true
            }
        )

        let encoded = try JSONEncoder().encode(requests[0])
        let json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(json["enable_thinking"] as? Bool == false)
    }

    @Test("explicit Thinking on reaches every reconstructed tool-loop request")
    func explicitOnPropagatesAcrossIterations() {
        let controls = ChatTurnGenerationControls.capture(
            activeModelOptions: ["disableThinking": .bool(false)]
        )

        var requests = [request(), request(), request()]
        for index in requests.indices {
            controls.apply(to: &requests[index])
        }

        #expect(controls.enableThinking == true)
        #expect(requests.allSatisfy { $0.enable_thinking == true })
        #expect(
            requests.allSatisfy {
                $0.modelOptions?["disableThinking"]?.boolValue == false
            }
        )
    }

    @Test("unset Thinking preserves the bundle default")
    func unsetPreservesBundleDefault() {
        let controls = ChatTurnGenerationControls.capture(
            activeModelOptions: [:]
        )
        var request = request()
        controls.apply(to: &request)

        #expect(controls.enableThinking == nil)
        #expect(request.enable_thinking == nil)
        #expect(request.modelOptions == nil)
    }

    @Test("non-thinking model options do not synthesize a Thinking override")
    func unrelatedOptionsDoNotSynthesizeThinking() {
        let controls = ChatTurnGenerationControls.capture(
            activeModelOptions: ["customFlag": .string("kept")]
        )
        var request = request()
        controls.apply(to: &request)

        #expect(request.enable_thinking == nil)
        #expect(request.modelOptions?["customFlag"]?.stringValue == "kept")
    }
}
