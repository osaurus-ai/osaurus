//
//  AnthropicAPI.swift
//  osaurus
//
//  Anthropic Messages API compatible request/response models for Claude Code compatibility.
//

import Foundation

// MARK: - Request Models

/// Anthropic Messages API request
struct AnthropicMessagesRequest: Codable, Sendable {
    let model: String
    let max_tokens: Int
    let system: AnthropicSystemContent?
    let messages: [AnthropicMessage]
    let stream: Bool?
    let temperature: Double?
    let top_p: Double?
    let top_k: Int?
    let stop_sequences: [String]?
    let tools: [AnthropicTool]?
    let tool_choice: AnthropicToolChoice?
    let metadata: AnthropicMetadata?
}

/// System content can be a string or array of content blocks
enum AnthropicSystemContent: Codable, Sendable {
    case text(String)
    case blocks([AnthropicContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let blocks = try? container.decode([AnthropicContentBlock].self) {
            self = .blocks(blocks)
        } else {
            throw DecodingError.typeMismatch(
                AnthropicSystemContent.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected String or [AnthropicContentBlock]"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }

    /// Extract plain text from system content
    var plainText: String {
        switch self {
        case .text(let text):
            return text
        case .blocks(let blocks):
            return blocks.compactMap { block in
                if case .text(let textBlock) = block {
                    return textBlock.text
                }
                return nil
            }.joined(separator: "\n")
        }
    }
}

/// Anthropic message in conversation
struct AnthropicMessage: Codable, Sendable {
    let role: String  // "user" or "assistant"
    let content: AnthropicMessageContent
}

/// Message content can be a string or array of content blocks
enum AnthropicMessageContent: Codable, Sendable {
    case text(String)
    case blocks([AnthropicContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let blocks = try? container.decode([AnthropicContentBlock].self) {
            self = .blocks(blocks)
        } else {
            throw DecodingError.typeMismatch(
                AnthropicMessageContent.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected String or [AnthropicContentBlock]"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }

    /// Extract plain text from message content
    var plainText: String {
        switch self {
        case .text(let text):
            return text
        case .blocks(let blocks):
            return blocks.compactMap { block in
                if case .text(let textBlock) = block {
                    return textBlock.text
                }
                return nil
            }.joined(separator: "\n")
        }
    }

    /// Get all content blocks
    var blocks: [AnthropicContentBlock] {
        switch self {
        case .text(let text):
            return [.text(AnthropicTextBlock(text: text))]
        case .blocks(let blocks):
            return blocks
        }
    }
}

/// Content block types
enum AnthropicContentBlock: Codable, Sendable {
    case text(AnthropicTextBlock)
    case image(AnthropicImageBlock)
    case toolUse(AnthropicToolUseBlock)
    case toolResult(AnthropicToolResultBlock)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try AnthropicTextBlock(from: decoder))
        case "image":
            self = .image(try AnthropicImageBlock(from: decoder))
        case "tool_use":
            self = .toolUse(try AnthropicToolUseBlock(from: decoder))
        case "tool_result":
            self = .toolResult(try AnthropicToolResultBlock(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content block type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let block):
            try block.encode(to: encoder)
        case .image(let block):
            try block.encode(to: encoder)
        case .toolUse(let block):
            try block.encode(to: encoder)
        case .toolResult(let block):
            try block.encode(to: encoder)
        }
    }
}

/// Text content block
struct AnthropicTextBlock: Codable, Sendable {
    let type: String
    let text: String

    init(text: String) {
        self.type = "text"
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case type, text
    }
}

/// Image content block
struct AnthropicImageBlock: Codable, Sendable {
    let type: String
    let source: AnthropicImageSource

    struct AnthropicImageSource: Codable, Sendable {
        let type: String  // "base64" or "url"
        let media_type: String?  // e.g., "image/png"
        let data: String?  // base64 data
        let url: String?  // URL if type is "url"
    }
}

/// Tool use content block (assistant requesting tool invocation)
struct AnthropicToolUseBlock: Codable, Sendable {
    let type: String
    let id: String
    let name: String
    let input: [String: AnyCodableValue]

    init(id: String, name: String, input: [String: AnyCodableValue]) {
        self.type = "tool_use"
        self.id = id
        self.name = name
        self.input = input
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, name, input
    }
}

/// Tool result content block (user providing tool output)
struct AnthropicToolResultBlock: Codable, Sendable {
    let type: String
    let tool_use_id: String
    let content: AnthropicToolResultContent?
    let is_error: Bool?
}

/// Tool result content can be a string or array of content blocks
enum AnthropicToolResultContent: Codable, Sendable {
    case text(String)
    case blocks([AnthropicContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let blocks = try? container.decode([AnthropicContentBlock].self) {
            self = .blocks(blocks)
        } else {
            throw DecodingError.typeMismatch(
                AnthropicToolResultContent.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected String or [AnthropicContentBlock]"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }

    var plainText: String {
        switch self {
        case .text(let text):
            return text
        case .blocks(let blocks):
            return blocks.compactMap { block in
                if case .text(let textBlock) = block {
                    return textBlock.text
                }
                return nil
            }.joined(separator: "\n")
        }
    }
}

/// Tool definition
struct AnthropicTool: Codable, Sendable {
    let name: String
    let description: String?
    let input_schema: JSONValue?
}

/// Tool choice specification
enum AnthropicToolChoice: Codable, Sendable {
    case auto
    case any
    case none
    case tool(name: String)

    private enum CodingKeys: String, CodingKey {
        case type, name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "auto":
            self = .auto
        case "any":
            self = .any
        case "none":
            self = .none
        case "tool":
            let name = try container.decode(String.self, forKey: .name)
            self = .tool(name: name)
        default:
            self = .auto
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try container.encode("auto", forKey: .type)
        case .any:
            try container.encode("any", forKey: .type)
        case .none:
            try container.encode("none", forKey: .type)
        case .tool(let name):
            try container.encode("tool", forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}

/// Request metadata
struct AnthropicMetadata: Codable, Sendable {
    let user_id: String?
}

// MARK: - Response Models

/// Anthropic Messages API response (non-streaming)
struct AnthropicMessagesResponse: Codable, Sendable {
    let id: String
    let type: String
    let role: String
    let content: [AnthropicResponseContentBlock]
    let model: String
    let stop_reason: String?
    let stop_sequence: String?
    let usage: AnthropicUsage

    init(
        id: String,
        model: String,
        content: [AnthropicResponseContentBlock],
        stopReason: String?,
        usage: AnthropicUsage
    ) {
        self.id = id
        self.type = "message"
        self.role = "assistant"
        self.content = content
        self.model = model
        self.stop_reason = stopReason
        self.stop_sequence = nil
        self.usage = usage
    }
}

/// Response content block (simplified for encoding)
enum AnthropicResponseContentBlock: Codable, Sendable {
    case text(type: String, text: String)
    case toolUse(type: String, id: String, name: String, input: [String: AnyCodableValue])

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(type: type, text: text)
        case "tool_use":
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let input = try container.decode([String: AnyCodableValue].self, forKey: .input)
            self = .toolUse(type: type, id: id, name: name, input: input)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown response content block type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let type, let text):
            try container.encode(type, forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolUse(let type, let id, let name, let input):
            try container.encode(type, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        }
    }

    static func textBlock(_ text: String) -> AnthropicResponseContentBlock {
        .text(type: "text", text: text)
    }

    static func toolUseBlock(id: String, name: String, input: [String: AnyCodableValue])
        -> AnthropicResponseContentBlock
    {
        .toolUse(type: "tool_use", id: id, name: name, input: input)
    }
}

/// Token usage information
struct AnthropicUsage: Codable, Sendable {
    let input_tokens: Int
    let output_tokens: Int

    init(inputTokens: Int, outputTokens: Int) {
        self.input_tokens = inputTokens
        self.output_tokens = outputTokens
    }
}

/// Anthropic error response
struct AnthropicError: Codable, Sendable {
    let type: String
    let error: AnthropicErrorDetail

    init(type: String = "error", message: String, errorType: String = "invalid_request_error") {
        self.type = type
        self.error = AnthropicErrorDetail(type: errorType, message: message)
    }

    struct AnthropicErrorDetail: Codable, Sendable {
        let type: String
        let message: String
    }
}

// MARK: - Streaming Event Models

/// Base streaming event
protocol AnthropicStreamEvent: Codable, Sendable {
    var type: String { get }
}

/// message_start event
struct MessageStartEvent: Codable, Sendable {
    let type: String
    let message: MessageStartPayload

    struct MessageStartPayload: Codable, Sendable {
        let id: String
        let type: String
        let role: String
        let content: [AnthropicResponseContentBlock]
        let model: String
        let stop_reason: String?
        let stop_sequence: String?
        let usage: AnthropicUsage
    }

    init(id: String, model: String, inputTokens: Int) {
        self.type = "message_start"
        self.message = MessageStartPayload(
            id: id,
            type: "message",
            role: "assistant",
            content: [],
            model: model,
            stop_reason: nil,
            stop_sequence: nil,
            usage: AnthropicUsage(inputTokens: inputTokens, outputTokens: 0)
        )
    }
}

/// content_block_start event
struct ContentBlockStartEvent: Codable, Sendable {
    let type: String
    let index: Int
    let content_block: ContentBlockStart

    enum ContentBlockStart: Codable, Sendable {
        case text(TextBlockStart)
        case toolUse(ToolUseBlockStart)

        struct TextBlockStart: Codable, Sendable {
            let type: String
            let text: String

            init() {
                self.type = "text"
                self.text = ""
            }
        }

        struct ToolUseBlockStart: Codable, Sendable {
            let type: String
            let id: String
            let name: String
            let input: [String: AnyCodableValue]

            init(id: String, name: String) {
                self.type = "tool_use"
                self.id = id
                self.name = name
                self.input = [:]
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type, text, id, name, input
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = .text(TextBlockStart())
            case "tool_use":
                let id = try container.decode(String.self, forKey: .id)
                let name = try container.decode(String.self, forKey: .name)
                self = .toolUse(ToolUseBlockStart(id: id, name: name))
            default:
                self = .text(TextBlockStart())
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let block):
                try container.encode(block.type, forKey: .type)
                try container.encode(block.text, forKey: .text)
            case .toolUse(let block):
                try container.encode(block.type, forKey: .type)
                try container.encode(block.id, forKey: .id)
                try container.encode(block.name, forKey: .name)
                try container.encode(block.input, forKey: .input)
            }
        }
    }

    init(index: Int, textBlock: Bool = true) {
        self.type = "content_block_start"
        self.index = index
        self.content_block = .text(ContentBlockStart.TextBlockStart())
    }

    init(index: Int, toolId: String, toolName: String) {
        self.type = "content_block_start"
        self.index = index
        self.content_block = .toolUse(ContentBlockStart.ToolUseBlockStart(id: toolId, name: toolName))
    }
}

/// content_block_delta event
struct ContentBlockDeltaEvent: Codable, Sendable {
    let type: String
    let index: Int
    let delta: ContentBlockDelta

    enum ContentBlockDelta: Codable, Sendable {
        case textDelta(TextDelta)
        case inputJsonDelta(InputJsonDelta)

        struct TextDelta: Codable, Sendable {
            let type: String
            let text: String

            init(text: String) {
                self.type = "text_delta"
                self.text = text
            }
        }

        struct InputJsonDelta: Codable, Sendable {
            let type: String
            let partial_json: String

            init(partialJson: String) {
                self.type = "input_json_delta"
                self.partial_json = partialJson
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type, text, partial_json
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text_delta":
                let text = try container.decode(String.self, forKey: .text)
                self = .textDelta(TextDelta(text: text))
            case "input_json_delta":
                let json = try container.decode(String.self, forKey: .partial_json)
                self = .inputJsonDelta(InputJsonDelta(partialJson: json))
            default:
                self = .textDelta(TextDelta(text: ""))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .textDelta(let delta):
                try container.encode(delta.type, forKey: .type)
                try container.encode(delta.text, forKey: .text)
            case .inputJsonDelta(let delta):
                try container.encode(delta.type, forKey: .type)
                try container.encode(delta.partial_json, forKey: .partial_json)
            }
        }
    }

    init(index: Int, text: String) {
        self.type = "content_block_delta"
        self.index = index
        self.delta = .textDelta(ContentBlockDelta.TextDelta(text: text))
    }

    init(index: Int, partialJson: String) {
        self.type = "content_block_delta"
        self.index = index
        self.delta = .inputJsonDelta(ContentBlockDelta.InputJsonDelta(partialJson: partialJson))
    }
}

/// content_block_stop event
struct ContentBlockStopEvent: Codable, Sendable {
    let type: String
    let index: Int

    init(index: Int) {
        self.type = "content_block_stop"
        self.index = index
    }
}

/// message_delta event
struct MessageDeltaEvent: Codable, Sendable {
    let type: String
    let delta: MessageDelta
    let usage: MessageDeltaUsage

    struct MessageDelta: Codable, Sendable {
        let stop_reason: String?
        let stop_sequence: String?
    }

    struct MessageDeltaUsage: Codable, Sendable {
        let output_tokens: Int
    }

    init(stopReason: String?, outputTokens: Int) {
        self.type = "message_delta"
        self.delta = MessageDelta(stop_reason: stopReason, stop_sequence: nil)
        self.usage = MessageDeltaUsage(output_tokens: outputTokens)
    }
}

/// message_stop event
struct MessageStopEvent: Codable, Sendable {
    let type: String

    init() {
        self.type = "message_stop"
    }
}

/// ping event (for keep-alive)
struct PingEvent: Codable, Sendable {
    let type: String

    init() {
        self.type = "ping"
    }
}

// MARK: - Helper: Generic Codable Value

/// A type-erased codable value for handling arbitrary JSON
struct AnyCodableValue: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodableValue].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unable to decode value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodableValue($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodableValue($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - Conversion Helpers

extension AnthropicMessagesRequest {
    /// Convert Anthropic request to OpenAI-compatible ChatCompletionRequest
    func toChatCompletionRequest() -> ChatCompletionRequest {
        var openAIMessages: [ChatMessage] = []

        // Add system message if present
        if let system = system {
            openAIMessages.append(ChatMessage(role: "system", content: system.plainText))
        }

        // Convert messages
        for msg in messages {
            switch msg.role {
            case "user":
                // Check for tool_result blocks
                let blocks = msg.content.blocks
                var hasToolResult = false
                for block in blocks {
                    if case .toolResult(let result) = block {
                        hasToolResult = true
                        let content = result.content?.plainText ?? ""
                        openAIMessages.append(
                            ChatMessage(
                                role: "tool",
                                content: content,
                                tool_calls: nil,
                                tool_call_id: result.tool_use_id
                            )
                        )
                    }
                }
                if !hasToolResult {
                    openAIMessages.append(ChatMessage(role: "user", content: msg.content.plainText))
                }
            case "assistant":
                // Check for tool_use blocks
                let blocks = msg.content.blocks
                var toolCalls: [ToolCall] = []
                var textContent = ""

                for block in blocks {
                    switch block {
                    case .text(let textBlock):
                        textContent += textBlock.text
                    case .toolUse(let toolUse):
                        let argsData =
                            try? JSONSerialization.data(
                                withJSONObject: toolUse.input.mapValues { $0.value }
                            )
                        let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        toolCalls.append(
                            ToolCall(
                                id: toolUse.id,
                                type: "function",
                                function: ToolCallFunction(name: toolUse.name, arguments: argsString)
                            )
                        )
                    default:
                        break
                    }
                }

                if !toolCalls.isEmpty {
                    openAIMessages.append(
                        ChatMessage(
                            role: "assistant",
                            content: textContent.isEmpty ? nil : textContent,
                            tool_calls: toolCalls,
                            tool_call_id: nil
                        )
                    )
                } else {
                    openAIMessages.append(ChatMessage(role: "assistant", content: textContent))
                }
            default:
                openAIMessages.append(ChatMessage(role: msg.role, content: msg.content.plainText))
            }
        }

        // Convert tools
        var openAITools: [Tool]? = nil
        if let tools = tools {
            openAITools = tools.map { tool in
                Tool(
                    type: "function",
                    function: ToolFunction(
                        name: tool.name,
                        description: tool.description,
                        parameters: tool.input_schema
                    )
                )
            }
        }

        // Convert tool_choice
        var openAIToolChoice: ToolChoiceOption? = nil
        if let choice = tool_choice {
            switch choice {
            case .auto:
                openAIToolChoice = .auto
            case .none:
                openAIToolChoice = ToolChoiceOption.none
            case .any:
                // "any" means the model must call a tool - map to auto as closest equivalent
                openAIToolChoice = .auto
            case .tool(let name):
                openAIToolChoice = .function(
                    ToolChoiceOption.FunctionName(
                        type: "function",
                        function: ToolChoiceOption.Name(name: name)
                    )
                )
            }
        }

        return ChatCompletionRequest(
            model: model,
            messages: openAIMessages,
            temperature: temperature.map { Float($0) },
            max_tokens: max_tokens,
            stream: stream,
            top_p: top_p.map { Float($0) },
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: stop_sequences,
            n: nil,
            tools: openAITools,
            tool_choice: openAIToolChoice,
            session_id: nil
        )
    }
}
