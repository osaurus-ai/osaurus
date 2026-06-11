//
//  osaurusTests.swift
//  osaurusTests
//
//  Created by Terence on 8/17/25.
//

import Foundation
import Testing

@testable import OsaurusCore

struct osaurusTests {

    @Test func example() async throws {
        // Basic test to ensure the test framework is working
        #expect(1 + 1 == 2)
    }

    @Test func openAI_decodes_arrayOfParts_content() async throws {
        let json = """
            {
              "model": "test-model",
              "messages": [
                {"role": "system", "content": "You are a test."},
                {"role": "user", "content": [
                  {"type": "text", "text": "Hel"},
                  {"type": "text", "text": "lo"}
                ]}
              ],
              "stream": false
            }
            """.data(using: .utf8)!

        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json)
        #expect(req.messages.count == 2)
        #expect(req.messages[1].role == "user")
        #expect(req.messages[1].content == "Hello")

        let internalMessages = req.toInternalMessages()
        #expect(internalMessages[1].content == "Hello")
    }

    @Test func openAI_decodes_topK_samplingOverride() async throws {
        let json = """
            {
              "model": "test-model",
              "messages": [
                {"role": "user", "content": "Hi"}
              ],
              "max_tokens": 12,
              "temperature": 0,
              "top_p": 0.9,
              "top_k": 32
            }
            """.data(using: .utf8)!

        let req = try JSONDecoder().decode(ChatCompletionRequest.self, from: json)
        #expect(req.temperature == 0)
        #expect(req.top_p == 0.9)
        #expect(req.top_k == 32)
    }

    @Test func serverConfiguration_portValidation() async throws {
        var cfg = ServerConfiguration.default
        cfg.port = 0
        #expect(cfg.isValidPort == false)

        cfg.port = 1
        #expect(cfg.isValidPort == true)

        cfg.port = 65_535
        #expect(cfg.isValidPort == true)

        cfg.port = 65_536
        #expect(cfg.isValidPort == false)
    }

    @Test func openAI_toInternalMessages_mapping() async throws {
        let request = ChatCompletionRequest(
            model: "test-model",
            messages: [
                ChatMessage(role: "system", content: "You are a test."),
                ChatMessage(role: "user", content: "Hi"),
                ChatMessage(role: "assistant", content: "Hello"),
                ChatMessage(role: "tool", content: "Ignored role maps to user"),
            ],
            temperature: nil,
            max_tokens: nil,
            stream: nil,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: nil,
            tool_choice: nil,
            session_id: nil
        )

        let internalMessages = request.toInternalMessages()
        #expect(internalMessages.count == 4)
        #expect(internalMessages[0].role.rawValue == "system")
        #expect(internalMessages[1].role.rawValue == "user")
        #expect(internalMessages[2].role.rawValue == "assistant")
        // Unknown role maps to .user per implementation
        #expect(internalMessages[3].role.rawValue == "user")
    }

    @Test func openAIModel_initFromName_setsFields() async throws {
        let name = "mlx-model"
        let model = OpenAIModel(modelName: name)
        #expect(model.id == name)
        #expect(model.root == name)
        #expect(model.object == "model")
        #expect(model.owned_by == "osaurus")
        #expect(model.created > 0)
    }

    // NOTE: The legacy `Router`-based endpoint tests were relocated to
    // handler-level integration tests in `HTTPHandlerEndpointTests.swift`
    // when the dead `Router.swift` reference dispatcher was removed. The
    // production HTTP path is owned entirely by `HTTPHandler`.

    @Test @MainActor func alwaysLoadedSpecs_includesCapabilityTools_byDefault() async throws {
        let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none)
        let names = Set(specs.map(\.function.name))
        for cap in ToolRegistry.capabilityToolNames {
            #expect(names.contains(cap), "Expected \(cap) in default always-loaded specs")
        }
    }

    @Test @MainActor func alwaysLoadedSpecs_excludesCapabilityTools_whenFlagSet() async throws {
        let specs = ToolRegistry.shared.alwaysLoadedSpecs(mode: .none, excludeCapabilityTools: true)
        let names = Set(specs.map(\.function.name))
        for cap in ToolRegistry.capabilityToolNames {
            #expect(!names.contains(cap), "\(cap) should be excluded when excludeCapabilityTools is true")
        }
    }
}
