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

    // MARK: - Prompt caching (top-level cache_control)

    @Test func outboundAnthropicRequestCarriesTopLevelCacheControl() throws {
        let request = RemoteChatRequest(
            model: "claude-opus-4-8",
            messages: [ChatMessage(role: "user", content: "Hello")],
            temperature: nil,
            max_completion_tokens: 512,
            stream: true,
            top_p: nil,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            tools: nil,
            tool_choice: nil,
            reasoning_effort: nil,
            reasoning: nil,
            thinking: nil,
            modelOptions: [:],
            veniceParameters: nil
        ).toAnthropicRequest()

        #expect(request.cache_control?.type == "ephemeral")

        // And it reaches the wire as a top-level key.
        let encoded = try JSONEncoder.osaurusCanonical().encode(request)
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let cacheControl = json?["cache_control"] as? [String: Any]
        #expect(cacheControl?["type"] as? String == "ephemeral")
    }

    @Test func inboundAnthropicRequestWithoutCacheControlStillDecodes() throws {
        // Server-side compat path: SDK clients that don't send cache_control
        // must keep decoding exactly as before.
        let json = """
            {
                "model": "claude-3-5-sonnet-20241022",
                "max_tokens": 1024,
                "messages": [
                    {"role": "user", "content": "Hello"}
                ]
            }
            """
        let request = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: Data(json.utf8))
        #expect(request.cache_control == nil)
    }

    @Test func anthropicUsageDecodesCacheFields() throws {
        let json = """
            {
                "input_tokens": 12,
                "output_tokens": 34,
                "cache_creation_input_tokens": 2048,
                "cache_read_input_tokens": 4096
            }
            """
        let usage = try JSONDecoder().decode(AnthropicUsage.self, from: Data(json.utf8))
        #expect(usage.input_tokens == 12)
        #expect(usage.output_tokens == 34)
        #expect(usage.cache_creation_input_tokens == 2048)
        #expect(usage.cache_read_input_tokens == 4096)

        // Absent fields stay nil (server-side writer / non-caching providers).
        let bare = try JSONDecoder().decode(
            AnthropicUsage.self,
            from: Data(#"{"input_tokens": 1, "output_tokens": 2}"#.utf8)
        )
        #expect(bare.cache_creation_input_tokens == nil)
        #expect(bare.cache_read_input_tokens == nil)
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

    @Test func convertAnthropicImageBlocksToOpenAIPartsForVLRuntime() throws {
        let json = """
            {
                "model": "claude-3-5-sonnet-20241022",
                "max_tokens": 1024,
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {"type": "text", "text": "What is in this image?"},
                            {
                                "type": "image",
                                "source": {
                                    "type": "base64",
                                    "media_type": "image/png",
                                    "data": "QUJD"
                                }
                            }
                        ]
                    }
                ]
            }
            """
        let data = Data(json.utf8)
        let anthropicReq = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: data)

        let openAIReq = anthropicReq.toChatCompletionRequest()

        #expect(openAIReq.messages.count == 1)
        #expect(openAIReq.messages[0].role == "user")
        #expect(openAIReq.messages[0].content == "What is in this image?")
        #expect(openAIReq.messages[0].imageUrls == ["data:image/png;base64,QUJD"])
        #expect(openAIReq.messages[0].imageDataFromParts == [Data("ABC".utf8)])

        guard let parts = openAIReq.messages[0].contentParts else {
            Issue.record("Anthropic image blocks must survive conversion as ChatMessage.contentParts")
            return
        }
        #expect(parts.count == 2)
        if case .imageUrl(let url, let detail) = parts[1] {
            #expect(url == "data:image/png;base64,QUJD")
            #expect(detail == nil)
        } else {
            Issue.record("Second converted part should be image_url")
        }
    }

    @Test func convertAnthropicToolResultKeepsSiblingUserBlocksForRuntime() throws {
        let json = """
            {
                "model": "claude-3-5-sonnet-20241022",
                "max_tokens": 1024,
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": "toolu_123",
                                "content": "72F and sunny"
                            },
                            {"type": "text", "text": "Use that result with this image."},
                            {
                                "type": "image",
                                "source": {
                                    "type": "base64",
                                    "media_type": "image/png",
                                    "data": "QUJD"
                                }
                            }
                        ]
                    }
                ]
            }
            """
        let data = Data(json.utf8)
        let anthropicReq = try JSONDecoder().decode(AnthropicMessagesRequest.self, from: data)

        let openAIReq = anthropicReq.toChatCompletionRequest()

        #expect(openAIReq.messages.count == 2)
        guard openAIReq.messages.count == 2 else {
            Issue.record("tool_result conversion dropped sibling user-visible blocks")
            return
        }
        #expect(openAIReq.messages[0].role == "tool")
        #expect(openAIReq.messages[0].tool_call_id == "toolu_123")
        #expect(openAIReq.messages[0].content == "72F and sunny")
        #expect(openAIReq.messages[1].role == "user")
        #expect(openAIReq.messages[1].content == "Use that result with this image.")
        #expect(openAIReq.messages[1].imageUrls == ["data:image/png;base64,QUJD"])

        guard let parts = openAIReq.messages[1].contentParts else {
            Issue.record("Sibling text/image blocks must remain visible after tool_result conversion")
            return
        }
        #expect(parts.count == 2)
    }
}
