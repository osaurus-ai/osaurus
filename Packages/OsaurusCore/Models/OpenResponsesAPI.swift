//
//  OpenResponsesAPI.swift
//  osaurus
//
//  Open Responses API compatible request/response models.
//  Based on the Open Responses specification: https://www.openresponses.org
//

import Foundation

// MARK: - Request Models

/// Reasoning configuration for reasoning models.
public struct OpenResponsesReasoningConfig: Codable, Sendable {
    public let effort: String
}

/// Open Responses API create request
public struct OpenResponsesRequest: Codable, Sendable {
    /// Model identifier
    public let model: String
    /// Input content - can be a string or array of input items
    public let input: OpenResponsesInput
    /// Whether to stream the response
    public let stream: Bool?
    /// Available tools for the model to use
    public let tools: [OpenResponsesTool]?
    /// Tool choice configuration
    public let tool_choice: OpenResponsesToolChoice?
    /// Temperature for sampling
    public let temperature: Float?
    /// Maximum tokens to generate
    public let max_output_tokens: Int?
    /// Top-p sampling parameter
    public let top_p: Float?
    /// Instructions/system prompt
    public let instructions: String?
    /// Previous response ID for multi-turn conversations
    public let previous_response_id: String?
    /// Optional metadata
    public let metadata: [String: String]?
    /// Reasoning configuration for reasoning models
    public let reasoning: OpenResponsesReasoningConfig?
}

/// Input can be a string or array of input items
public enum OpenResponsesInput: Codable, Sendable {
    case text(String)
    case items([OpenResponsesInputItem])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let items = try? container.decode([OpenResponsesInputItem].self) {
            self = .items(items)
        } else {
            throw DecodingError.typeMismatch(
                OpenResponsesInput.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected String or [OpenResponsesInputItem]"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .items(let items):
            try container.encode(items)
        }
    }
}

/// Input item types
public enum OpenResponsesInputItem: Codable, Sendable {
    case message(OpenResponsesMessageItem)
    case functionCallOutput(OpenResponsesFunctionCallOutputItem)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "message":
            self = .message(try OpenResponsesMessageItem(from: decoder))
        case "function_call_output":
            self = .functionCallOutput(try OpenResponsesFunctionCallOutputItem(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown input item type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .message(let item):
            try item.encode(to: encoder)
        case .functionCallOutput(let item):
            try item.encode(to: encoder)
        }
    }
}

/// Message input item
public struct OpenResponsesMessageItem: Codable, Sendable {
    public let type: String
    public let role: String
    public let content: OpenResponsesMessageContent

    public init(role: String, content: OpenResponsesMessageContent) {
        self.type = "message"
        self.role = role
        self.content = content
    }
}

/// Message content can be string or array of content parts
public enum OpenResponsesMessageContent: Codable, Sendable {
    case text(String)
    case parts([OpenResponsesContentPart])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let parts = try? container.decode([OpenResponsesContentPart].self) {
            self = .parts(parts)
        } else {
            throw DecodingError.typeMismatch(
                OpenResponsesMessageContent.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected String or [OpenResponsesContentPart]"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }

    /// Extract plain text from content
    public var plainText: String {
        switch self {
        case .text(let text):
            return text
        case .parts(let parts):
            return parts.compactMap { part in
                if case .inputText(let textPart) = part {
                    return textPart.text
                }
                return nil
            }.joined(separator: "\n")
        }
    }
}

/// Content part types
public enum OpenResponsesContentPart: Codable, Sendable {
    case inputText(OpenResponsesInputTextPart)
    case inputImage(OpenResponsesInputImagePart)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "input_text":
            self = .inputText(try OpenResponsesInputTextPart(from: decoder))
        case "input_image":
            self = .inputImage(try OpenResponsesInputImagePart(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content part type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .inputText(let part):
            try part.encode(to: encoder)
        case .inputImage(let part):
            try part.encode(to: encoder)
        }
    }
}

/// Text content part
public struct OpenResponsesInputTextPart: Codable, Sendable {
    public let type: String
    public let text: String

    public init(text: String) {
        self.type = "input_text"
        self.text = text
    }
}

/// Image content part
public struct OpenResponsesInputImagePart: Codable, Sendable {
    public let type: String
    public let image_url: String?
    public let detail: String?

    public init(imageUrl: String, detail: String? = nil) {
        self.type = "input_image"
        self.image_url = imageUrl
        self.detail = detail
    }
}

/// Function call output item (tool result)
public struct OpenResponsesFunctionCallOutputItem: Codable, Sendable {
    public let type: String
    public let call_id: String
    public let output: String

    public init(callId: String, output: String) {
        self.type = "function_call_output"
        self.call_id = callId
        self.output = output
    }
}

// MARK: - Tool Definitions

/// Tool definition
public struct OpenResponsesTool: Codable, Sendable {
    public let type: String
    public let name: String
    public let description: String?
    public let parameters: JSONValue?

    public init(name: String, description: String?, parameters: JSONValue?) {
        self.type = "function"
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Tool choice configuration
public enum OpenResponsesToolChoice: Codable, Sendable {
    case auto
    case none
    case required
    case function(name: String)

    private enum CodingKeys: String, CodingKey {
        case type, name
    }

    public init(from decoder: Decoder) throws {
        // Try decoding as string first
        if let container = try? decoder.singleValueContainer(),
            let str = try? container.decode(String.self)
        {
            switch str {
            case "auto": self = .auto
            case "none": self = .none
            case "required": self = .required
            default: self = .auto
            }
            return
        }

        // Try decoding as object
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "auto": self = .auto
        case "none": self = .none
        case "required": self = .required
        case "function":
            let name = try container.decode(String.self, forKey: .name)
            self = .function(name: name)
        default:
            self = .auto
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .auto:
            var container = encoder.singleValueContainer()
            try container.encode("auto")
        case .none:
            var container = encoder.singleValueContainer()
            try container.encode("none")
        case .required:
            var container = encoder.singleValueContainer()
            try container.encode("required")
        case .function(let name):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("function", forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}

// MARK: - Response Models

/// Open Responses API response
public struct OpenResponsesResponse: Codable, Sendable {
    public let id: String
    public let object: String
    public let created_at: Int
    public let status: OpenResponsesStatus
    public let model: String
    public let output: [OpenResponsesOutputItem]
    public let usage: OpenResponsesUsage?
    public let metadata: [String: String]?

    public init(
        id: String,
        createdAt: Int,
        status: OpenResponsesStatus,
        model: String,
        output: [OpenResponsesOutputItem],
        usage: OpenResponsesUsage?
    ) {
        self.id = id
        self.object = "response"
        self.created_at = createdAt
        self.status = status
        self.model = model
        self.output = output
        self.usage = usage
        self.metadata = nil
    }
}

/// Response status
public enum OpenResponsesStatus: String, Codable, Sendable {
    case inProgress = "in_progress"
    case completed = "completed"
    case failed = "failed"
    case cancelled = "cancelled"
    case incomplete = "incomplete"
}

/// Output item types
public enum OpenResponsesOutputItem: Codable, Sendable {
    case message(OpenResponsesOutputMessage)
    case functionCall(OpenResponsesFunctionCall)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "message":
            self = .message(try OpenResponsesOutputMessage(from: decoder))
        case "function_call":
            self = .functionCall(try OpenResponsesFunctionCall(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown output item type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .message(let item):
            try item.encode(to: encoder)
        case .functionCall(let item):
            try item.encode(to: encoder)
        }
    }
}

/// Output message item
public struct OpenResponsesOutputMessage: Codable, Sendable {
    public let type: String
    public let id: String
    public let status: OpenResponsesItemStatus
    public let role: String
    public let content: [OpenResponsesOutputContent]

    public init(id: String, status: OpenResponsesItemStatus, content: [OpenResponsesOutputContent]) {
        self.type = "message"
        self.id = id
        self.status = status
        self.role = "assistant"
        self.content = content
    }
}

/// Item status
public enum OpenResponsesItemStatus: String, Codable, Sendable {
    case inProgress = "in_progress"
    case completed = "completed"
}

/// Output content types
public enum OpenResponsesOutputContent: Codable, Sendable {
    case outputText(OpenResponsesOutputText)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "output_text":
            self = .outputText(try OpenResponsesOutputText(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown output content type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .outputText(let content):
            try content.encode(to: encoder)
        }
    }
}

/// Output text content
public struct OpenResponsesOutputText: Codable, Sendable {
    public let type: String
    public let text: String

    public init(text: String) {
        self.type = "output_text"
        self.text = text
    }
}

/// Function call output item
public struct OpenResponsesFunctionCall: Codable, Sendable {
    public let type: String
    public let id: String
    public let status: OpenResponsesItemStatus
    public let call_id: String
    public let name: String
    public let arguments: String

    public init(id: String, status: OpenResponsesItemStatus, callId: String, name: String, arguments: String) {
        self.type = "function_call"
        self.id = id
        self.status = status
        self.call_id = callId
        self.name = name
        self.arguments = arguments
    }
}

/// Token usage information
public struct OpenResponsesUsage: Codable, Sendable {
    public let input_tokens: Int
    public let output_tokens: Int
    public let total_tokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.input_tokens = inputTokens
        self.output_tokens = outputTokens
        self.total_tokens = inputTokens + outputTokens
    }
}

// MARK: - Streaming Event Models

/// response.created event
public struct ResponseCreatedEvent: Codable, Sendable {
    public let type: String
    public let sequence_number: Int
    public let response: OpenResponsesResponse

    public init(sequenceNumber: Int, response: OpenResponsesResponse) {
        self.type = "response.created"
        self.sequence_number = sequenceNumber
        self.response = response
    }
}

/// response.in_progress event
public struct ResponseInProgressEvent: Codable, Sendable {
    public let type: String
    public let sequence_number: Int
    public let response: OpenResponsesResponse

    public init(sequenceNumber: Int, response: OpenResponsesResponse) {
        self.type = "response.in_progress"
        self.sequence_number = sequenceNumber
        self.response = response
    }
}

/// response.output_item.added event
public struct OutputItemAddedEvent: Codable, Sendable {
    public let type: String
    public let sequence_number: Int
    public let output_index: Int
    public let item: OpenResponsesOutputItem

    public init(sequenceNumber: Int, outputIndex: Int, item: OpenResponsesOutputItem) {
        self.type = "response.output_item.added"
        self.sequence_number = sequenceNumber
        self.output_index = outputIndex
        self.item = item
    }
}

/// response.content_part.added event
public struct ContentPartAddedEvent: Codable, Sendable {
    public let type: String
    public let sequence_number: Int
    public let item_id: String
    public let output_index: Int
    public let content_index: Int
    public let part: OpenResponsesOutputContent

    public init(
        sequenceNumber: Int,
        itemId: String,
        outputIndex: Int,
        contentIndex: Int,
        part: OpenResponsesOutputContent
    ) {
        self.type = "response.content_part.added"
        self.sequence_number = sequenceNumber
        self.item_id = itemId
        self.output_index = outputIndex
        self.content_index = contentIndex
        self.part = part
    }
}

/// response.output_text.delta event
public struct OutputTextDeltaEvent: Codable, Sendable {
    public let type: String
    public let sequence_number: Int
    public let item_id: String
    public let output_index: Int
    public let content_index: Int
    public let delta: String

    public init(sequenceNumber: Int, itemId: String, outputIndex: Int, contentIndex: Int, delta: String) {
        self.type = "response.output_text.delta"
        self.sequence_number = sequenceNumber
        self.item_id = itemId
        self.output_index = outputIndex
        self.content_index = contentIndex
        self.delta = delta
    }
}

/// response.output_text.done event
public struct OutputTextDoneEvent: Codable, Sendable {
    public let type: String
    public let sequence_number: Int
    public let item_id: String
    public let output_index: Int
    public let content_index: Int
    public let text: String

    public init(sequenceNumber: Int, itemId: String, outputIndex: Int, contentIndex: Int, text: String) {
        self.type = "response.output_text.done"
        self.sequence_number = sequenceNumber
        self.item_id = itemId
        self.output_index = outputIndex
        self.content_index = contentIndex
        self.text = text
    }
}

/// response.output_item.done event
public struct OutputItemDoneEvent: Codable, Sendable {
    public let type: String
    public let sequence_number: Int
    public let output_index: Int
    public let item: OpenResponsesOutputItem

    public init(sequenceNumber: Int, outputIndex: Int, item: OpenResponsesOutputItem) {
        self.type = "response.output_item.done"
        self.sequence_number = sequenceNumber
        self.output_index = outputIndex
        self.item = item
    }
}

/// response.function_call_arguments.delta event
public struct FunctionCallArgumentsDeltaEvent: Codable, Sendable {
    public let type: String
    public let sequence_number: Int
    public let item_id: String
    public let output_index: Int
    public let call_id: String
    public let delta: String

    public init(sequenceNumber: Int, itemId: String, outputIndex: Int, callId: String, delta: String) {
        self.type = "response.function_call_arguments.delta"
        self.sequence_number = sequenceNumber
        self.item_id = itemId
        self.output_index = outputIndex
        self.call_id = callId
        self.delta = delta
    }
}

/// response.function_call_arguments.done event
public struct FunctionCallArgumentsDoneEvent: Codable, Sendable {
    public let type: String
    public let sequence_number: Int
    public let item_id: String
    public let output_index: Int
    public let call_id: String
    public let arguments: String

    public init(sequenceNumber: Int, itemId: String, outputIndex: Int, callId: String, arguments: String) {
        self.type = "response.function_call_arguments.done"
        self.sequence_number = sequenceNumber
        self.item_id = itemId
        self.output_index = outputIndex
        self.call_id = callId
        self.arguments = arguments
    }
}

/// response.completed event
public struct ResponseCompletedEvent: Codable, Sendable {
    public let type: String
    public let sequence_number: Int
    public let response: OpenResponsesResponse

    public init(sequenceNumber: Int, response: OpenResponsesResponse) {
        self.type = "response.completed"
        self.sequence_number = sequenceNumber
        self.response = response
    }
}

/// response.failed event
public struct ResponseFailedEvent: Codable, Sendable {
    public let type: String
    public let sequence_number: Int
    public let response: OpenResponsesResponse
    public let error: OpenResponsesError?

    public init(sequenceNumber: Int, response: OpenResponsesResponse, error: OpenResponsesError?) {
        self.type = "response.failed"
        self.sequence_number = sequenceNumber
        self.response = response
        self.error = error
    }
}

// MARK: - Error Models

/// Open Responses error
public struct OpenResponsesError: Codable, Sendable {
    public let type: String
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.type = "error"
        self.code = code
        self.message = message
    }
}

/// Error response wrapper
public struct OpenResponsesErrorResponse: Codable, Sendable {
    public let error: OpenResponsesError

    public init(code: String, message: String) {
        self.error = OpenResponsesError(code: code, message: message)
    }
}

// MARK: - Conversion Helpers

extension OpenResponsesRequest {
    /// Convert Open Responses request to internal ChatCompletionRequest
    func toChatCompletionRequest() -> ChatCompletionRequest {
        var messages: [ChatMessage] = []

        // Add instructions as system message if present
        if let instructions = instructions, !instructions.isEmpty {
            messages.append(ChatMessage(role: "system", content: instructions))
        }

        // Convert input to messages
        switch input {
        case .text(let text):
            messages.append(ChatMessage(role: "user", content: text))
        case .items(let items):
            for item in items {
                switch item {
                case .message(let messageItem):
                    messages.append(ChatMessage(role: messageItem.role, content: messageItem.content.plainText))
                case .functionCallOutput(let outputItem):
                    messages.append(
                        ChatMessage(
                            role: "tool",
                            content: outputItem.output,
                            tool_calls: nil,
                            tool_call_id: outputItem.call_id
                        )
                    )
                }
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
                        parameters: tool.parameters
                    )
                )
            }
        }

        // Convert tool choice
        var openAIToolChoice: ToolChoiceOption? = nil
        if let choice = tool_choice {
            switch choice {
            case .auto:
                openAIToolChoice = .auto
            case .none:
                openAIToolChoice = ToolChoiceOption.none
            case .required:
                openAIToolChoice = .auto
            case .function(let name):
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
            messages: messages,
            temperature: temperature,
            max_tokens: max_output_tokens,
            stream: stream,
            top_p: top_p,
            frequency_penalty: nil,
            presence_penalty: nil,
            stop: nil,
            n: nil,
            tools: openAITools,
            tool_choice: openAIToolChoice,
            session_id: nil
        )
    }
}

extension ChatCompletionResponse {
    /// Convert internal ChatCompletionResponse to Open Responses format
    func toOpenResponsesResponse(responseId: String) -> OpenResponsesResponse {
        var outputItems: [OpenResponsesOutputItem] = []

        for choice in choices {
            let itemId = "item_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))"

            // Check for tool calls
            if let toolCalls = choice.message.tool_calls, !toolCalls.isEmpty {
                for toolCall in toolCalls {
                    let funcCall = OpenResponsesFunctionCall(
                        id: itemId,
                        status: .completed,
                        callId: toolCall.id,
                        name: toolCall.function.name,
                        arguments: toolCall.function.arguments
                    )
                    outputItems.append(.functionCall(funcCall))
                }
            } else if let content = choice.message.content {
                // Regular text message
                let outputMessage = OpenResponsesOutputMessage(
                    id: itemId,
                    status: .completed,
                    content: [.outputText(OpenResponsesOutputText(text: content))]
                )
                outputItems.append(.message(outputMessage))
            }
        }

        return OpenResponsesResponse(
            id: responseId,
            createdAt: created,
            status: .completed,
            model: model,
            output: outputItems,
            usage: OpenResponsesUsage(
                inputTokens: usage.prompt_tokens,
                outputTokens: usage.completion_tokens
            )
        )
    }
}
