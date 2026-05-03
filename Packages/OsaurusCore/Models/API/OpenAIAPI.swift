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

/// OpenAI-compatible content part for multimodal messages.
///
/// Supports four shapes:
///   - `text` / `input_text` — plain text
///   - `image_url` — `{url, detail?}`. URL may be `data:image/...;base64,...` or `https://...`
///   - `input_audio` — `{data: <base64>, format: "wav"|"mp3"|"flac"|...}`. Mirrors the
///     OpenAI Realtime / GPT-4o audio shape; the audio bytes are written to a temp
///     file and handed to vmlx as `UserInput.Audio.url(...)` so vmlx's
///     `nemotronOmniLoadAudioFile` (AVAudioConverter → 16 kHz mono Float32) handles
///     all decoding. Format strings are passed through to vmlx unchanged — vmlx
///     uses the file extension, so the format hint becomes the file extension.
///   - `video_url` — `{url}`. Mirrors the convention adopted by LM Studio / Ollama
///     for video inputs since OpenAI hasn't published a canonical chat-completions
///     video shape. URL may be `data:video/...;base64,...` or `https://...`.
enum MessageContentPart: Codable, Sendable {
    case text(String)
    case imageUrl(url: String, detail: String?)
    case audioInput(data: String, format: String)
    case videoUrl(url: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case input_text
        case image_url
        case input_audio
        case video_url
    }

    private struct ImageUrlContent: Codable {
        let url: String
        let detail: String?
    }

    private struct InputAudioContent: Codable {
        let data: String
        let format: String
    }

    private struct VideoUrlContent: Codable {
        let url: String
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
        case "input_audio":
            let audio = try container.decode(InputAudioContent.self, forKey: .input_audio)
            self = .audioInput(data: audio.data, format: audio.format)
        case "video_url":
            let video = try container.decode(VideoUrlContent.self, forKey: .video_url)
            self = .videoUrl(url: video.url)
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
        case .audioInput(let data, let format):
            try container.encode("input_audio", forKey: .type)
            try container.encode(InputAudioContent(data: data, format: format), forKey: .input_audio)
        case .videoUrl(let url):
            try container.encode("video_url", forKey: .type)
            try container.encode(VideoUrlContent(url: url), forKey: .video_url)
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
    /// Reasoning/thinking text from thinking-capable OpenAI-compat providers
    /// (DeepSeek thinking mode, Qwen, vLLM, …). Echoed back on follow-ups
    /// for providers that require it (issue #959); `RemoteProviderService`
    /// strips it on the wire for everyone else.
    let reasoning_content: String?

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

    /// Extract `(base64, format)` pairs from `input_audio` content parts.
    /// `format` is whatever the client sent (e.g. `"wav"`, `"mp3"`); we pass
    /// it through to the file extension when materializing the temp file
    /// because vmlx's `nemotronOmniLoadAudioFile` keys decoder selection on
    /// the URL extension via AVAudioConverter.
    var audioInputs: [(data: String, format: String)] {
        guard let parts = contentParts else { return [] }
        return parts.compactMap { part in
            if case .audioInput(let data, let format) = part {
                return (data, format)
            }
            return nil
        }
    }

    /// Extract video URLs (data: or http(s):) from `video_url` content parts.
    var videoUrls: [String] {
        guard let parts = contentParts else { return [] }
        return parts.compactMap { part in
            if case .videoUrl(let url) = part {
                return url
            }
            return nil
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
        case reasoning_content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(String.self, forKey: .role)
        self.tool_calls = try? container.decode([ToolCall].self, forKey: .tool_calls)
        self.tool_call_id = try? container.decode(String.self, forKey: .tool_call_id)
        self.reasoning_content = try? container.decode(String.self, forKey: .reasoning_content)

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
        // If we have content parts with any non-text media, encode as array;
        // otherwise as string. Round-trip preserves audio/video/image parts
        // so a request that came in with `input_audio` or `video_url` is
        // re-serialized in the same shape.
        if let parts = contentParts,
            parts.contains(where: {
                switch $0 {
                case .imageUrl, .audioInput, .videoUrl: return true
                case .text: return false
                }
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
        // Stripped at the transport layer for providers that don't need it.
        try container.encodeIfPresent(reasoning_content, forKey: .reasoning_content)
    }
}

extension ChatMessage {
    init(role: String, content: String) {
        self.role = role
        self.content = content
        self.contentParts = nil
        self.tool_calls = nil
        self.tool_call_id = nil
        self.reasoning_content = nil
    }

    /// Initialize with optional tool calls, tool call id, and reasoning content.
    /// `reasoning_content` is echoed back to thinking-capable providers
    /// (e.g. DeepSeek) on multi-turn follow-ups.
    init(
        role: String,
        content: String?,
        tool_calls: [ToolCall]?,
        tool_call_id: String?,
        reasoning_content: String? = nil
    ) {
        self.role = role
        self.content = content
        self.contentParts = nil
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.reasoning_content = reasoning_content
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
        self.reasoning_content = nil
    }

    /// Multimodal init covering image + audio + video. Used by the
    /// chat composer when the loaded model's capabilities advertise the
    /// modality. Audio bytes encode as `input_audio` with explicit
    /// format hint; video bytes encode as `video_url` with
    /// `data:video/<container>` URL. All three flow into the
    /// OpenAI-compatible JSON shape that vmlx's
    /// `mapOpenAIChatToMLX` materializes through
    /// `extractAudioSources` / `extractVideoSources`.
    init(
        role: String,
        text: String,
        imageData: [Data],
        audios: [(data: Data, format: String)],
        videos: [(data: Data, mimeSubtype: String)]
    ) {
        self.role = role
        var parts: [MessageContentPart] = []

        if !text.isEmpty {
            parts.append(.text(text))
        }

        for data in imageData {
            let base64 = data.base64EncodedString()
            parts.append(.imageUrl(url: "data:image/png;base64,\(base64)", detail: nil))
        }

        for (data, format) in audios {
            // OpenAI audio shape: bare base64 string + format hint.
            // The format string round-trips to vmlx's
            // `materializeMediaDataUrl` audio canonicalization (mp4 → m4a
            // for audio mime, NOT for video — audit fix locked in
            // `MaterializeMediaDataUrlMCDCTests`).
            parts.append(.audioInput(data: data.base64EncodedString(), format: format))
        }

        for (data, mimeSubtype) in videos {
            // Video data URL with the container subtype (`mp4` / `mov` /
            // `webm` / `quicktime`) so the materializer keeps the right
            // file extension (NOT downgraded to .m4a — see audit fix).
            let base64 = data.base64EncodedString()
            parts.append(
                .videoUrl(url: "data:video/\(mimeSubtype);base64,\(base64)")
            )
        }

        self.contentParts = parts.isEmpty ? nil : parts
        self.content = text.isEmpty ? nil : text
        self.tool_calls = nil
        self.tool_call_id = nil
        self.reasoning_content = nil
    }
}

/// Chat completion request
struct ChatCompletionRequest: Codable, Sendable {
    let model: String
    var messages: [ChatMessage]
    let temperature: Float?
    let max_tokens: Int?
    /// OpenAI newer alias for max_tokens; accepted on inbound requests alongside max_tokens.
    var max_completion_tokens: Int? = nil
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
    /// Optional session identifier for chat/history grouping. Not a KV cache key —
    /// vmlx-swift-lm's `CacheCoordinator` is content-addressed and discovers
    /// reusable prefixes autonomously.
    var session_id: String? = nil
    /// Deterministic-sampling seed (OpenAI v1.x). When set, identical
    /// requests should yield identical completions on the same backend.
    var seed: Int? = nil
    /// `{"type":"json_object"}` for OpenAI JSON mode. Other shapes
    /// (`text`, `json_schema`) are rejected at request validation.
    var response_format: ResponseFormat? = nil
    /// `{"include_usage": true}` instructs the SSE producer to emit a
    /// final chunk carrying `usage` (prompt/completion/total tokens).
    var stream_options: StreamOptions? = nil
    /// Model-specific options from the active ModelProfile (not serialized to JSON).
    var modelOptions: [String: ModelOptionValue]? = nil
    /// Optional TTFT trace for diagnostic timing (not serialized to JSON).
    var ttftTrace: TTFTTrace? = nil

    /// Resolved max tokens, preferring max_tokens then max_completion_tokens.
    var resolvedMaxTokens: Int? { max_tokens ?? max_completion_tokens }

    private enum CodingKeys: String, CodingKey {
        case model, messages, temperature, max_tokens, max_completion_tokens, stream, top_p
        case frequency_penalty, presence_penalty, stop, n
        case tools, tool_choice, session_id
        case seed, response_format, stream_options
    }

    func withModel(_ newModel: String) -> ChatCompletionRequest {
        var copy = ChatCompletionRequest(
            model: newModel,
            messages: messages,
            temperature: temperature,
            max_tokens: max_tokens,
            stream: stream,
            top_p: top_p,
            frequency_penalty: frequency_penalty,
            presence_penalty: presence_penalty,
            stop: stop,
            n: n,
            tools: tools,
            tool_choice: tool_choice,
            session_id: session_id,
            seed: seed,
            response_format: response_format,
            stream_options: stream_options
        )
        copy.modelOptions = modelOptions
        return copy
    }
}

/// OpenAI `response_format`. We only act on `json_object`; other kinds
/// (`text`, `json_schema`) flow through unchanged so the request
/// validator can accept or reject them with a clear, specific error.
struct ResponseFormat: Codable, Sendable, Equatable {
    let type: String
}

/// OpenAI `stream_options` shape. Today we only honor `include_usage`.
struct StreamOptions: Codable, Sendable, Equatable {
    let include_usage: Bool?
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
    var system_fingerprint: String? = nil
    /// Content hash of the system prompt + tool names used for this request.
    /// Informational only — clients can use it to detect when the system
    /// prefix changed across requests. KV reuse itself is handled
    /// autonomously by vmlx's `CacheCoordinator` (content-addressed).
    var prefix_hash: String? = nil
}

// MARK: - Streaming Response Structures

/// Delta content for streaming
struct DeltaContent: Codable, Sendable {
    let role: String?
    let content: String?
    let refusal: String?
    /// Incremental tool_calls information (OpenAI-compatible)
    let tool_calls: [DeltaToolCall]?
    /// Reasoning/thinking text streamed in a separate channel by OpenAI-compatible
    /// providers (DeepSeek, Qwen, Together, vLLM). Absent on providers that only
    /// emit content. The stream parser wraps these chunks with synthetic `<think>`
    /// tags so the rest of the pipeline can route them as reasoning.
    let reasoning_content: String?

    init(
        role: String? = nil,
        content: String? = nil,
        refusal: String? = nil,
        tool_calls: [DeltaToolCall]? = nil,
        reasoning_content: String? = nil
    ) {
        self.role = role
        self.content = content
        self.refusal = refusal
        self.tool_calls = tool_calls
        self.reasoning_content = reasoning_content
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
    var system_fingerprint: String? = nil
    /// Included only in the first chunk; see `ChatCompletionResponse.prefix_hash`.
    var prefix_hash: String? = nil
    /// Final usage chunk (OpenAI `stream_options.include_usage`). Populated
    /// only on the dedicated penultimate SSE chunk; nil on every other.
    var usage: Usage? = nil
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        let params = parameters ?? .object(["type": .string("object"), "properties": .object([:])])
        try container.encode(params, forKey: .parameters)
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, parameters
    }
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
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription:
                        "Unsupported tool_choice string '\(str)'. Expected 'auto', 'none', or a typed function selector."
                )
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
public struct ToolCall: Codable, Sendable {
    public let id: String
    public let type: String  // "function"
    public let function: ToolCallFunction
    /// Optional thought signature for Gemini thinking-mode models (e.g. Gemini 2.5)
    public let geminiThoughtSignature: String?

    public init(id: String, type: String, function: ToolCallFunction, geminiThoughtSignature: String? = nil) {
        self.id = id
        self.type = type
        self.function = function
        self.geminiThoughtSignature = geminiThoughtSignature
    }
}

public struct ToolCallFunction: Codable, Sendable {
    public let name: String
    /// Arguments serialized as JSON string per OpenAI spec
    public let arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
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
public enum JSONValue: Codable, Sendable, Equatable {
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

// MARK: - JSONValue Conversions

extension JSONValue {
    /// Convert JSONValue to Sendable-compatible value for Jinja chat templates.
    /// Null values are dropped from dictionaries because Jinja's `Value(any:)` cannot
    /// handle `NSNull` and throws a runtime error. JSON Schema treats a missing key
    /// the same as `null`, so this is semantically lossless for tool specs.
    var sendableValue: any Sendable {
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
            return arr.map { $0.sendableValue }
        case .object(let obj):
            var dict: [String: any Sendable] = [:]
            for (k, v) in obj {
                if case .null = v { continue }
                dict[k] = v.sendableValue
            }
            return dict
        }
    }

    /// Convert JSONValue to Foundation JSON-compatible Any (for JSONSerialization).
    /// Unlike `sendableValue`, this preserves null as `NSNull` in dictionaries
    /// since `JSONSerialization` handles it correctly.
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
    /// Convert to MLXLMCommon.ToolSpec-compatible function dictionary
    fileprivate func toFunctionSpec() -> [String: any Sendable] {
        var fn: [String: any Sendable] = [
            "name": name
        ]
        if let description {
            fn["description"] = description
        }
        if let parameters {
            fn["parameters"] = parameters.sendableValue
        }
        return fn
    }
}

extension Tool {
    /// Convert to Tokenizers.ToolSpec (`[String: any Sendable]`) for MLX chat templates.
    ///
    /// The dictionary is round-tripped through canonical JSON
    /// (`JSONSerialization.WritingOptions.sortedKeys`) so the structure handed
    /// to the chat template — and the resulting `<tools>` block in the
    /// rendered prompt — is byte-stable across calls. Without this, key
    /// iteration order from a fresh dictionary literal can shift between
    /// requests and silently invalidate the MLX paged KV cache prefix.
    func toTokenizerToolSpec() -> [String: any Sendable] {
        let raw: [String: any Sendable] = [
            "type": type,
            "function": function.toFunctionSpec(),
        ]
        return Self.canonicalize(raw) ?? raw
    }

    /// Round-trip a Sendable JSON value through `JSONSerialization` with
    /// `.sortedKeys` to canonicalise nested key ordering. Returns `nil` on
    /// the (extremely unlikely) serialisation failure so callers fall back
    /// to the raw dict rather than emit nothing.
    fileprivate static func canonicalize(_ value: [String: any Sendable]) -> [String: any Sendable]? {
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            let reparsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: any Sendable]
        else { return nil }
        return reparsed
    }
}
