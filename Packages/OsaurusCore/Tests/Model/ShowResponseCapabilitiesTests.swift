//
//  ShowResponseCapabilitiesTests.swift
//  osaurusTests
//
//  The Ollama-compatible /show response must carry the model's capabilities
//  so clients can gate features (vision, tools) without sniffing model_info.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ShowResponseCapabilitiesTests {

    private func makeInfo(capabilities: [String]) -> ModelInfo {
        ModelInfo(
            name: "test/model-4bit",
            model: .init(
                architecture: "qwen2",
                parameters: "7B",
                contextLength: 32768,
                embeddingLength: 3584,
                quantization: "Q4_0"
            ),
            capabilities: capabilities,
            parameters: .init(
                temperature: nil, topP: nil, topK: nil, stop: nil, repeatPenalty: nil
            )
        )
    }

    @Test func showResponseCarriesCapabilities() throws {
        let response = makeInfo(capabilities: ["completion", "vision"]).toShowResponse()
        #expect(response.capabilities == ["completion", "vision"])
    }

    @Test func capabilitiesAreSerializedAtTopLevel() throws {
        let response = makeInfo(capabilities: ["completion"]).toShowResponse()
        let data = try JSONEncoder().encode(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["capabilities"] as? [String] == ["completion"])
    }
}
