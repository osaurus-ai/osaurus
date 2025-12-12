//
//  AnthropicAPITests.swift
//  osaurusTests
//
//  Tests for Anthropic Messages API compatibility.
//

import Foundation
import Testing

@testable import OsaurusCore

struct AnthropicAPITests {

    // MARK: - Request Parsing Tests

    @Test func parseSimpleAnthropicRequest() throws {
        let json = """
            {
                "model": "claude-3-5-sonnet-20241022",
                "max_tokens": 1024,
                "messages": [
                    {"role": "user", "content": "Hello, Claude!"}
                ]
            }
            """
        let data = Data(json.utf8)
        let request = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: data)

        #expect(request.model == "claude-3-5-sonnet-20241022")
        #expect(request.max_tokens == 1024)
        #expect(request.messages.count == 1)
        #expect(request.messages[0].role == "user")
        #expect(request.messages[0].content.plainText == "Hello, Claude!")
    }

    @Test func parseAnthropicRequestWithSystem() throws {
        let json = """
            {
                "model": "claude-3-5-sonnet-20241022",
                "max_tokens": 1024,
                "system": "You are a helpful assistant.",
                "messages": [
                    {"role": "user", "content": "Hello!"}
                ]
            }
            """
        let data = Data(json.utf8)
        let request = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: data)

        #expect(request.system?.plainText == "You are a helpful assistant.")
    }

    @Test func parseAnthropicRequestWithContentBlocks() throws {
        let json = """
            {
                "model": "claude-3-5-sonnet-20241022",
                "max_tokens": 1024,
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": "What is in this image?"}
                        ]
                    }
                ]
            }
            """
        let data = Data(json.utf8)
        let request = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: data)

        #expect(request.messages[0].content.plainText == "What is in this image?")
    }

    @Test func parseAnthropicRequestWithTools() throws {
        let json = """
            {
                "model": "claude-3-5-sonnet-20241022",
                "max_tokens": 1024,
                "messages": [
                    {"role": "user", "content": "Get the weather in San Francisco"}
                ],
                "tools": [
                    {
                        "name": "get_weather",
                        "description": "Get the current weather in a location",
                        "input_schema": {
                            "type": "object",
                            "properties": {
                                "location": {"type": "string"}
                            },
                            "required": ["location"]
                        }
                    }
                ]
            }
            """
        let data = Data(json.utf8)
        let request = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: data)

        #expect(request.tools?.count == 1)
        #expect(request.tools?[0].name == "get_weather")
        #expect(request.tools?[0].description == "Get the current weather in a location")
    }

    @Test func parseAnthropicRequestWithToolResult() throws {
        let json = """
            {
                "model": "claude-3-5-sonnet-20241022",
                "max_tokens": 1024,
                "messages": [
                    {"role": "user", "content": "Get the weather"},
                    {
                        "role": "assistant",
                        "content": [
                            {
                                "type": "tool_use",
                                "id": "toolu_123",
                                "name": "get_weather",
                                "input": {"location": "San Francisco"}
                            }
                        ]
                    },
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": "toolu_123",
                                "content": "72°F and sunny"
                            }
                        ]
                    }
                ]
            }
            """
        let data = Data(json.utf8)
        let request = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: data)

        #expect(request.messages.count == 3)

        // Check tool_use block in assistant message
        let assistantBlocks = request.messages[1].content.blocks
        #expect(assistantBlocks.count == 1)
        if case .toolUse(let toolUse) = assistantBlocks[0] {
            #expect(toolUse.id == "toolu_123")
            #expect(toolUse.name == "get_weather")
        } else {
            #expect(Bool(false), "Expected tool_use block")
        }

        // Check tool_result block in user message
        let userBlocks = request.messages[2].content.blocks
        #expect(userBlocks.count == 1)
        if case .toolResult(let toolResult) = userBlocks[0] {
            #expect(toolResult.tool_use_id == "toolu_123")
            #expect(toolResult.content?.plainText == "72°F and sunny")
        } else {
            #expect(Bool(false), "Expected tool_result block")
        }
    }

    // MARK: - Response Encoding Tests

    @Test func encodeAnthropicMessagesResponse() throws {
        let response = AnthropicMessagesResponse(
            id: "msg_123",
            model: "claude-3-5-sonnet-20241022",
            content: [.textBlock("Hello! How can I help you?")],
            stopReason: "end_turn",
            usage: AnthropicUsage(inputTokens: 10, outputTokens: 8)
        )

        let json = try JSONEncoder().encode(response)
        let decoded = try JSONSerialization.jsonObject(with: json) as! [String: Any]

        #expect(decoded["id"] as? String == "msg_123")
        #expect(decoded["type"] as? String == "message")
        #expect(decoded["role"] as? String == "assistant")
        #expect(decoded["model"] as? String == "claude-3-5-sonnet-20241022")
        #expect(decoded["stop_reason"] as? String == "end_turn")

        let content = decoded["content"] as! [[String: Any]]
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "Hello! How can I help you?")

        let usage = decoded["usage"] as! [String: Int]
        #expect(usage["input_tokens"] == 10)
        #expect(usage["output_tokens"] == 8)
    }

    @Test func encodeAnthropicResponseWithToolUse() throws {
        let response = AnthropicMessagesResponse(
            id: "msg_456",
            model: "claude-3-5-sonnet-20241022",
            content: [
                .toolUseBlock(
                    id: "toolu_789",
                    name: "get_weather",
                    input: ["location": AnyCodableValue("San Francisco")]
                )
            ],
            stopReason: "tool_use",
            usage: AnthropicUsage(inputTokens: 15, outputTokens: 12)
        )

        let json = try JSONEncoder().encode(response)
        let decoded = try JSONSerialization.jsonObject(with: json) as! [String: Any]

        #expect(decoded["stop_reason"] as? String == "tool_use")

        let content = decoded["content"] as! [[String: Any]]
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "tool_use")
        #expect(content[0]["id"] as? String == "toolu_789")
        #expect(content[0]["name"] as? String == "get_weather")
    }

    // MARK: - Streaming Event Tests

    @Test func encodeMessageStartEvent() throws {
        let event = MessageStartEvent(id: "msg_001", model: "claude-3-5-sonnet-20241022", inputTokens: 25)

        let json = try JSONEncoder().encode(event)
        let decoded = try JSONSerialization.jsonObject(with: json) as! [String: Any]

        #expect(decoded["type"] as? String == "message_start")

        let message = decoded["message"] as! [String: Any]
        #expect(message["id"] as? String == "msg_001")
        #expect(message["type"] as? String == "message")
        #expect(message["role"] as? String == "assistant")
        #expect(message["model"] as? String == "claude-3-5-sonnet-20241022")
    }

    @Test func encodeContentBlockDeltaEvent() throws {
        let event = ContentBlockDeltaEvent(index: 0, text: "Hello")

        let json = try JSONEncoder().encode(event)
        let decoded = try JSONSerialization.jsonObject(with: json) as! [String: Any]

        #expect(decoded["type"] as? String == "content_block_delta")
        #expect(decoded["index"] as? Int == 0)

        let delta = decoded["delta"] as! [String: Any]
        #expect(delta["type"] as? String == "text_delta")
        #expect(delta["text"] as? String == "Hello")
    }

    @Test func encodeMessageDeltaEvent() throws {
        let event = MessageDeltaEvent(stopReason: "end_turn", outputTokens: 50)

        let json = try JSONEncoder().encode(event)
        let decoded = try JSONSerialization.jsonObject(with: json) as! [String: Any]

        #expect(decoded["type"] as? String == "message_delta")

        let delta = decoded["delta"] as! [String: Any]
        #expect(delta["stop_reason"] as? String == "end_turn")

        let usage = decoded["usage"] as! [String: Int]
        #expect(usage["output_tokens"] == 50)
    }

    // MARK: - Conversion Tests

    @Test func convertAnthropicRequestToOpenAI() throws {
        let json = """
            {
                "model": "claude-3-5-sonnet-20241022",
                "max_tokens": 1024,
                "system": "You are helpful.",
                "messages": [
                    {"role": "user", "content": "Hello!"},
                    {"role": "assistant", "content": "Hi there!"},
                    {"role": "user", "content": "How are you?"}
                ],
                "temperature": 0.7
            }
            """
        let data = Data(json.utf8)
        let anthropicReq = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: data)

        let openAIReq = anthropicReq.toChatCompletionRequest()

        #expect(openAIReq.model == "claude-3-5-sonnet-20241022")
        #expect(openAIReq.max_tokens == 1024)
        #expect(openAIReq.temperature == 0.7)

        // System message should be first
        #expect(openAIReq.messages.count == 4)
        #expect(openAIReq.messages[0].role == "system")
        #expect(openAIReq.messages[0].content == "You are helpful.")
        #expect(openAIReq.messages[1].role == "user")
        #expect(openAIReq.messages[1].content == "Hello!")
        #expect(openAIReq.messages[2].role == "assistant")
        #expect(openAIReq.messages[2].content == "Hi there!")
        #expect(openAIReq.messages[3].role == "user")
        #expect(openAIReq.messages[3].content == "How are you?")
    }

    @Test func convertAnthropicToolsToOpenAI() throws {
        let json = """
            {
                "model": "claude-3-5-sonnet-20241022",
                "max_tokens": 1024,
                "messages": [{"role": "user", "content": "Get weather"}],
                "tools": [
                    {
                        "name": "get_weather",
                        "description": "Get weather for a location",
                        "input_schema": {
                            "type": "object",
                            "properties": {
                                "location": {"type": "string"}
                            }
                        }
                    }
                ],
                "tool_choice": {"type": "auto"}
            }
            """
        let data = Data(json.utf8)
        let anthropicReq = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: data)

        let openAIReq = anthropicReq.toChatCompletionRequest()

        #expect(openAIReq.tools?.count == 1)
        #expect(openAIReq.tools?[0].type == "function")
        #expect(openAIReq.tools?[0].function.name == "get_weather")
        #expect(openAIReq.tools?[0].function.description == "Get weather for a location")
    }
}
