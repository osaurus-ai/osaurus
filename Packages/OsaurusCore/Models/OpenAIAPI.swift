//
//  OpenAIAPI.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation

// MARK: - OpenAI API Compatible Structures

/// OpenAI-compatible model object
struct OpenAIModel: Codable, Sendable {
    let id: String
    var object: String = "model"
    var created: Int = 0
    var owned_by: String = "osaurus"
    var permission: [ModelPermission]? = nil
    var root: String? = nil
    var parent: String? = nil
    var name: String? = nil
    var model: String? = nil
    var modified_at: String? = nil
    var size: Int? = nil
    var digest: String? = nil
    var details: ModelDetails? = nil

    /// Initialize from a model name (for local models)
    init(modelName: String) {
        self.id = modelName
        self.object = "model"
        self.created = Int(Date().timeIntervalSince1970)
        self.owned_by = "osaurus"
        self.root = modelName
    }

    /// Full initializer
    init(
        id: String,
        object: String = "model",
        created: Int = 0,
        owned_by: String = "osaurus",
        permission: [ModelPermission]? = nil,
        root: String? = nil,
        parent: String? = nil,
        name: String? = nil,
        model: String? = nil,
        modified_at: String? = nil,
        size: Int? = nil,
        digest: String? = nil,
        details: ModelDetails? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.owned_by = owned_by
        self.permission = permission
        self.root = root
        self.parent = parent
        self.name = name
        self.model = model
        self.modified_at = modified_at
        self.size = size
        self.digest = digest
        self.details = details
    }

    // Explicit Codable implementation to avoid ambiguity
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        object = try container.decodeIfPresent(String.self, forKey: .object) ?? "model"
        created = try container.decodeIfPresent(Int.self, forKey: .created) ?? 0
        owned_by = try container.decodeIfPresent(String.self, forKey: .owned_by) ?? "unknown"
        permission = try container.decodeIfPresent([ModelPermission].self, forKey: .permission)
        root = try container.decodeIfPresent(String.self, forKey: .root)
        parent = try container.decodeIfPresent(String.self, forKey: .parent)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        modified_at = try container.decodeIfPresent(String.self, forKey: .modified_at)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        digest = try container.decodeIfPresent(String.self, forKey: .digest)
        details = try container.decodeIfPresent(ModelDetails.self, forKey: .details)
    }

    private enum CodingKeys: String, CodingKey {
        case id, object, created, owned_by, permission, root, parent
        case name, model, modified_at, size, digest, details
    }
}

/// Model permission object (OpenAI format)
struct ModelPermission: Codable, Sendable {
    var id: String?
    var object: String?
    var created: Int?
    var allow_create_engine: Bool?
    var allow_sampling: Bool?
    var allow_logprobs: Bool?
    var allow_search_indices: Bool?
    var allow_view: Bool?
    var allow_fine_tuning: Bool?
    var organization: String?
    var group: String?
    var is_blocking: Bool?
}

struct ModelDetails: Codable, Sendable {
    let parent_model: String?
    let format: String?
    let family: String?
    let families: [String]?
    let parameter_size: String?
    let quantization_level: String?
}

/// Response for /models endpoint
struct ModelsResponse: Codable, Sendable {
    var object: String = "list"
    let data: [OpenAIModel]

    private enum CodingKeys: String, CodingKey {
        case object, data
    }

    /// Memberwise initializer
    init(object: String = "list", data: [OpenAIModel]) {
        self.object = object
        self.data = data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Make object optional for providers like OpenRouter that don't include it
        self.object = try container.decodeIfPresent(String.self, forKey: .object) ?? "list"
        self.data = try container.decode([OpenAIModel].self, forKey: .data)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(object, forKey: .object)
        try container.encode(data, forKey: .data)
    }
}

// MARK: - Multimodal Content Parts

/// OpenAI-compatible content part for multimodal messages
enum MessageContentPart: Codable, Sendable {
    case text(String)
    case imageUrl(url: String, detail: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case input_text
        case image_url
    }

    private struct ImageUrlContent: Codable {
        let url: String
        let detail: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            if let text = try? container.decode(String.self, forKey: .text) {
                self = .text(text)
            } else if let inputText = try? container.decode(String.self, forKey: .input_text) {
                self = .text(inputText)
            } else {
                self = .text("")
            }
        case "image_url":
            let imageUrl = try container.decode(ImageUrlContent.self, forKey: .image_url)
            self = .imageUrl(url: imageUrl.url, detail: imageUrl.detail)
        default:
            // Fallback to text for unknown types
            if let text = try? container.decode(String.self, forKey: .text) {
                self = .text(text)
            } else {
                self = .text("")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageUrl(let url, let detail):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageUrlContent(url: url, detail: detail), forKey: .image_url)
        }
    }
}

/// Chat message in OpenAI format
struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String?
    /// Multimodal content parts (images, text) - populated when content is an array
    let contentParts: [MessageContentPart]?
    /// Present when assistant requests tool invocations
    let tool_calls: [ToolCall]?
    /// Required for role=="tool" messages to associate with a prior tool call
    let tool_call_id: String?

    /// Extract image URLs from content parts (supports both data URLs and http URLs)
    var imageUrls: [String] {
        guard let parts = contentParts else { return [] }
        return parts.compactMap { part in
            if case .imageUrl(let url, _) = part {
                return url
            }
            return nil
        }
    }

    /// Extract base64 image data from data URLs in content parts
    var imageDataFromParts: [Data] {
        imageUrls.compactMap { url in
            // Parse data URL: data:image/png;base64,<base64data>
            guard url.hasPrefix("data:image/") else { return nil }
            guard let commaIndex = url.firstIndex(of: ",") else { return nil }
            let base64String = String(url[url.index(after: commaIndex)...])
            return Data(base64Encoded: base64String)
        }
    }
}

// Allow decoding OpenAI-style array-of-parts content while preserving string encoding
extension ChatMessage {
    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case tool_calls
        case tool_call_id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(String.self, forKey: .role)
        self.tool_calls = try? container.decode([ToolCall].self, forKey: .tool_calls)
        self.tool_call_id = try? container.decode(String.self, forKey: .tool_call_id)

        if let stringContent = try? container.decode(String.self, forKey: .content) {
            self.content = stringContent
            self.contentParts = nil
        } else if let parts = try? container.decode([MessageContentPart].self, forKey: .content) {
            // Store the parts for multimodal access
            self.contentParts = parts
            // Also extract text for backward compatibility
            let texts = parts.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
            // OpenAI-style array-of-parts text should be concatenated verbatim. Newlines should be
            // represented explicitly in the text segments themselves, not inserted by the decoder.
            self.content = texts.isEmpty ? nil : texts.joined()
        } else {
            self.content = nil
            self.contentParts = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        // If we have content parts with images, encode as array; otherwise as string
        if let parts = contentParts,
            parts.contains(where: {
                if case .imageUrl = $0 { return true }
                return false
            })
        {
            try container.encode(parts, forKey: .content)
        } else if let content = content {
            // Only encode content if it's not nil (OpenAI rejects null content)
            try container.encode(content, forKey: .content)
        }
        // Note: content is intentionally omitted when nil (e.g., assistant messages with tool_calls)
        try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
        try container.encodeIfPresent(tool_call_id, forKey: .tool_call_id)
    }
}

extension ChatMessage {
    init(role: String, content: String) {
        self.role = role
        self.content = content
        self.contentParts = nil
        self.tool_calls = nil
        self.tool_call_id = nil
    }

    /// Initialize with optional tool calls and tool call id
    init(role: String, content: String?, tool_calls: [ToolCall]?, tool_call_id: String?) {
        self.role = role
        self.content = content
        self.contentParts = nil
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
    }

    /// Initialize with multimodal content (text and images)
    init(role: String, text: String, imageData: [Data]) {
        self.role = role
        var parts: [MessageContentPart] = []

        // Add text part
        if !text.isEmpty {
            parts.append(.text(text))
        }

        // Add image parts as base64 data URLs
        for data in imageData {
            let base64 = data.base64EncodedString()
            let dataUrl = "data:image/png;base64,\(base64)"
            parts.append(.imageUrl(url: dataUrl, detail: nil))
        }

        self.contentParts = parts.isEmpty ? nil : parts
        self.content = text.isEmpty ? nil : text
        self.tool_calls = nil
        self.tool_call_id = nil
    }
}

/// Chat completion request
struct ChatCompletionRequest: Codable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Float?
    let max_tokens: Int?
    let stream: Bool?
    let top_p: Float?
    let frequency_penalty: Float?
    let presence_penalty: Float?
    let stop: [String]?
    let n: Int?
    /// OpenAI tools/function-calling definitions
    let tools: [Tool]?
    /// OpenAI tool_choice ("none" | "auto" | {"type":"function","function":{"name":...}})
    let tool_choice: ToolChoiceOption?
    /// Optional session identifier for KV cache reuse across turns
    let session_id: String?
}

/// Chat completion choice
struct ChatChoice: Codable, Sendable {
    let index: Int
    let message: ChatMessage
    let finish_reason: String
}

/// Token usage information
struct Usage: Codable, Sendable {
    let prompt_tokens: Int
    let completion_tokens: Int
    let total_tokens: Int
}

/// Chat completion response
struct ChatCompletionResponse: Codable, Sendable {
    let id: String
    var object: String = "chat.completion"
    let created: Int
    let model: String
    let choices: [ChatChoice]
    let usage: Usage
    let system_fingerprint: String?
}

// MARK: - Streaming Response Structures

/// Delta content for streaming
struct DeltaContent: Codable, Sendable {
    let role: String?
    let content: String?
    let refusal: String?
    /// Incremental tool_calls information (OpenAI-compatible)
    let tool_calls: [DeltaToolCall]?

    init(
        role: String? = nil,
        content: String? = nil,
        refusal: String? = nil,
        tool_calls: [DeltaToolCall]? = nil
    ) {
        self.role = role
        self.content = content
        self.refusal = refusal
        self.tool_calls = tool_calls
    }
}

/// Streaming choice
struct StreamChoice: Codable, Sendable {
    let index: Int
    let delta: DeltaContent
    let finish_reason: String?
}

/// Chat completion chunk for streaming
struct ChatCompletionChunk: Codable, Sendable {
    let id: String
    var object: String = "chat.completion.chunk"
    let created: Int
    let model: String
    let choices: [StreamChoice]
    let system_fingerprint: String?
}

// MARK: - Error Response

/// OpenAI-compatible error response
struct OpenAIError: Codable, Error, Sendable {
    let error: ErrorDetail

    struct ErrorDetail: Codable, Sendable {
        let message: String
        let type: String
        let param: String?
        let code: String?
    }
}

// MARK: - Helper Extensions

extension ChatCompletionRequest {
    /// Convert OpenAI format messages to internal Message format
    func toInternalMessages() -> [Message] {
        return messages.map { chatMessage in
            let role: MessageRole =
                switch chatMessage.role {
                case "system": .system
                case "user": .user
                case "assistant": .assistant
                default: .user
                }
            return Message(role: role, content: chatMessage.content ?? "")
        }
    }
}

extension OpenAIModel {
    /// Create an OpenAI model from an internal model name
    init(from modelName: String) {
        self.id = modelName
        self.created = Int(Date().timeIntervalSince1970)
        self.root = modelName
    }
}

// MARK: - Tools: Request/Response Models

/// Tool definition (currently only type=="function")
struct Tool: Codable, Sendable {
    let type: String  // "function"
    let function: ToolFunction
}

struct ToolFunction: Codable, Sendable {
    let name: String
    let description: String?
    let parameters: JSONValue?
}

/// tool_choice option
enum ToolChoiceOption: Codable, Sendable {
    case auto
    case none
    case function(FunctionName)

    struct FunctionName: Codable, Sendable {
        let type: String
        let function: Name
    }
    struct Name: Codable, Sendable { let name: String }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            switch str {
            case "auto": self = .auto
            case "none": self = .none
            default: self = .auto
            }
            return
        }
        let obj = try container.decode(FunctionName.self)
        self = .function(obj)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto:
            try container.encode("auto")
        case .none:
            try container.encode("none")
        case .function(let obj):
            try container.encode(obj)
        }
    }
}

/// Assistant tool call in responses
struct ToolCall: Codable, Sendable {
    let id: String
    let type: String  // "function"
    let function: ToolCallFunction
}

struct ToolCallFunction: Codable, Sendable {
    let name: String
    /// Arguments serialized as JSON string per OpenAI spec
    let arguments: String
}

// Streaming deltas for tool calls
struct DeltaToolCall: Codable, Sendable {
    let index: Int?
    let id: String?
    let type: String?
    let function: DeltaToolCallFunction?
}

struct DeltaToolCallFunction: Codable, Sendable {
    let name: String?
    let arguments: String?
}

// MARK: - Generic JSON value for tool parameters

/// Simple JSON value representation to carry arbitrary JSON schema/arguments
public enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: JSONValue].self) {
            self = .object(dict)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .number(let n):
            try container.encode(n)
        case .string(let s):
            try container.encode(s)
        case .array(let arr):
            try container.encode(arr)
        case .object(let obj):
            try container.encode(obj)
        }
    }
}

// MARK: - Conversions for Tool Specs (OpenAI -> Tokenizers.ToolSpec)

extension JSONValue {
    /// Convert JSONValue to Foundation JSON-compatible Any (for Tokenizers.ToolSpec)
    var anyValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let b):
            return b
        case .number(let n):
            return n
        case .string(let s):
            return s
        case .array(let arr):
            return arr.map { $0.anyValue }
        case .object(let obj):
            var dict: [String: Any] = [:]
            for (k, v) in obj { dict[k] = v.anyValue }
            return dict
        }
    }
}

extension ToolFunction {
    /// Convert to Tokenizers.ToolSpec-compatible function dictionary
    fileprivate func toFunctionSpec() -> [String: Any] {
        var fn: [String: Any] = [
            "name": name
        ]
        if let description {
            fn["description"] = description
        }
        if let parameters {
            fn["parameters"] = parameters.anyValue
        }
        return fn
    }
}

extension Tool {
    /// Convert to Tokenizers.ToolSpec (`[String: Any]`) for MLX chat templates
    func toTokenizerToolSpec() -> [String: Any] {
        return [
            "type": type,
            "function": function.toFunctionSpec(),
        ]
    }
}
