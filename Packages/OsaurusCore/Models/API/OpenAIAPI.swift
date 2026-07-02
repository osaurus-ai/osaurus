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
        // Some OpenAI-compatible servers expose provider-local metadata in
        // `size` as a fractional value. That field is informational for
        // Osaurus model discovery, so preserve the model row instead of
        // rejecting the whole `/models` response.
        size = try? container.decodeIfPresent(Int.self, forKey: .size)
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

extension ModelDetails {
    /// Ollama-compatible details for local MLX models.
    ///
    /// Prefer resolved bundle metadata when the model id maps to a downloaded
    /// directory. Fall back to strict family-name helpers for local aliases
    /// such as `_dsv4_band_pe2`, because `/api/tags` is often used by clients
    /// before the user loads the model and those aliases still need honest
    /// family metadata instead of `unknown`.
    static func localMLXModelDetails(for modelId: String) -> ModelDetails {
        let modelInfo = ModelInfo.load(modelId: modelId)
        let family = localMLXFamily(for: modelId, architecture: modelInfo?.model.architecture)

        return ModelDetails(
            parent_model: "",
            format: "safetensors",
            family: family,
            families: [family],
            parameter_size: modelInfo?.model.parameters ?? ModelMetadataParser.parameterCount(from: modelId) ?? "",
            quantization_level: modelInfo?.model.quantization ?? ModelMetadataParser.quantizationOllama(from: modelId)
                ?? ""
        )
    }

    private static func localMLXFamily(for modelId: String, architecture: String?) -> String {
        if let architecture,
            !architecture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            architecture.lowercased() != "unknown"
        {
            return architecture
        }

        if ModelFamilyNames.isDSV4Family(modelId) { return "deepseek_v4" }
        if ModelFamilyNames.isQwenFamily(modelId) { return "qwen" }
        if ModelFamilyNames.isGemmaFamily(modelId) { return "gemma" }
        if ModelFamilyNames.isMiniMaxFamily(modelId) { return "minimax" }
        if ModelFamilyNames.isLingFamily(modelId) { return "ling" }
        if ModelFamilyNames.isZayaVLFamily(modelId) { return "zaya_vl" }
        if ModelFamilyNames.isZayaFamily(modelId) { return "zaya" }
        if ModelFamilyNames.isNemotronOmniFamily(modelId) { return "nemotron_omni" }

        return "unknown"
    }
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

struct LocalAudioSamples: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Int
    let preencodedAttachmentId: UUID?

    init(
        samples: [Float],
        sampleRate: Int,
        preencodedAttachmentId: UUID? = nil
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.preencodedAttachmentId = preencodedAttachmentId
    }
}

// MARK: - Multimodal Content Parts

/// OpenAI-compatible content part for multimodal messages.
///
/// Supports four shapes:
///   - `text` / `input_text` — plain text
///   - `image_url` — `{url, detail?}`. URL may be `data:image/...;base64,...` or `https://...`
///   - `input_audio` — `{data: <base64>, format: "wav"|"mp3"|"flac"|...}`. Mirrors the
///     OpenAI Realtime / GPT-4o audio shape; valid WAV bytes decode directly to
///     `UserInput.Audio.samples(...)` for local MLX, while other containers fall
///     back to a temp file handed to vmlx as `UserInput.Audio.url(...)` so
///     `nemotronOmniLoadAudioFile` can use AVAudioConverter.
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
    /// In-process live voice samples aligned to audio input parts. This is
    /// deliberately not Codable: OpenAI-compatible JSON keeps the portable
    /// `input_audio` payload, while local MLX requests can bypass the
    /// WAV/base64/temp-file round trip.
    let localAudioSamples: [LocalAudioSamples?]
    /// Present when assistant requests tool invocations
    let tool_calls: [ToolCall]?
    /// Required for role=="tool" messages to associate with a prior tool call
    let tool_call_id: String?
    /// Reasoning/thinking text from thinking-capable OpenAI-compat providers
    /// (DeepSeek thinking mode, Qwen, vLLM, …). Echoed back on follow-ups
    /// for providers that require it (issue #959); `RemoteProviderService`
    /// strips it on the wire for everyone else.
    let reasoning_content: String?
    /// Opaque OpenAI Responses reasoning-item identifier (`rs_…`) captured from
    /// the prior turn. In-memory only — NOT part of the OpenAI chat-completions
    /// JSON. `toOpenResponsesRequest` re-emits it as a `reasoning` input item.
    let reasoning_item_id: String?
    /// Server-encrypted reasoning blob paired with `reasoning_item_id`. In-memory
    /// only; re-sent verbatim on the Responses path for chain continuity.
    let reasoning_encrypted: String?

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
    /// `format` is whatever the client sent (e.g. `"wav"`, `"mp3"`); valid
    /// WAV data can bypass temp-file materialization, and fallback containers
    /// pass the format through to the temp-file extension for AVAudioConverter.
    var audioInputs: [(data: String, format: String)] {
        audioInputsWithLocalSamples.map { (data: $0.data, format: $0.format) }
    }

    var audioInputsWithLocalSamples: [(data: String, format: String, localSamples: LocalAudioSamples?)] {
        guard let parts = contentParts else { return [] }
        var audioIndex = 0
        return parts.compactMap { part in
            if case .audioInput(let data, let format) = part {
                let local = audioIndex < localAudioSamples.count ? localAudioSamples[audioIndex] : nil
                audioIndex += 1
                return (data, format, local)
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
        // Responses-only carriers; never present in OpenAI chat-completions JSON.
        self.reasoning_item_id = nil
        self.reasoning_encrypted = nil
        self.localAudioSamples = []

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
        self.localAudioSamples = []
        self.tool_calls = nil
        self.tool_call_id = nil
        self.reasoning_content = nil
        self.reasoning_item_id = nil
        self.reasoning_encrypted = nil
    }

    /// Initialize with optional tool calls, tool call id, and reasoning content.
    /// `reasoning_content` is echoed back to thinking-capable providers
    /// (e.g. DeepSeek) on multi-turn follow-ups. `reasoning_item_id` /
    /// `reasoning_encrypted` carry the OpenAI Responses reasoning item for
    /// round-trip continuity (re-emitted by `toOpenResponsesRequest`).
    init(
        role: String,
        content: String?,
        tool_calls: [ToolCall]?,
        tool_call_id: String?,
        reasoning_content: String? = nil,
        reasoning_item_id: String? = nil,
        reasoning_encrypted: String? = nil
    ) {
        self.role = role
        self.content = content
        self.contentParts = nil
        self.localAudioSamples = []
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.reasoning_content = reasoning_content
        self.reasoning_item_id = reasoning_item_id
        self.reasoning_encrypted = reasoning_encrypted
    }

    /// Initialize from a route adapter that already normalized OpenAI-style
    /// multimodal content parts. Keeps media available to `imageUrls`,
    /// `videoUrls`, and `audioInputs` instead of flattening the message to text.
    init(role: String, content: String?, contentParts: [MessageContentPart]?) {
        self.role = role
        self.content = content
        self.contentParts = contentParts
        self.localAudioSamples = []
        self.tool_calls = nil
        self.tool_call_id = nil
        self.reasoning_content = nil
        self.reasoning_item_id = nil
        self.reasoning_encrypted = nil
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
        self.localAudioSamples = []
        self.tool_calls = nil
        self.tool_call_id = nil
        self.reasoning_content = nil
        self.reasoning_item_id = nil
        self.reasoning_encrypted = nil
    }

    /// Multimodal init covering image + audio + video. Used by the
    /// chat composer when the loaded model's capabilities advertise the
    /// modality. Audio bytes encode as `input_audio` with explicit
    /// format hint; video bytes encode as `video_url` with
    /// `data:video/<container>` URL. All three flow into the
    /// OpenAI-compatible JSON shape that `mapOpenAIChatToMLX` lowers through
    /// `extractAudioSources` / `extractVideoSources`.
    init(
        role: String,
        text: String,
        imageData: [Data],
        audios: [(data: Data, format: String)],
        localAudioSamples: [LocalAudioSamples?] = [],
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
        self.localAudioSamples = localAudioSamples
        self.tool_calls = nil
        self.tool_call_id = nil
        self.reasoning_content = nil
        self.reasoning_item_id = nil
        self.reasoning_encrypted = nil
    }
}

/// Chat completion request
/// OpenAI-legacy `/v1/completions` request. Unlike chat, `prompt` is a raw
/// string fed to the model verbatim (no chat template) — what FIM autocomplete
/// tools (Continue, etc.) rely on for `<|fim_*|>` prompts.
struct CompletionRequest: Decodable, Sendable {
    let model: String
    /// Raw prompt sent to the generation path. For OpenAI insertion/FIM
    /// clients that send `prefix` instead of `prompt`, this falls back to the
    /// prefix because the local raw completion contract accepts one string.
    let prompt: String
    /// OpenAI-compatible FIM/insertion request fields. `suffix` and `middle`
    /// are decoded so callers get a precise compatibility error instead of the
    /// field being silently ignored by the raw left-to-right completion path.
    let prefix: String?
    let suffix: String?
    let middle: String?
    let maxTokens: Int?
    let temperature: Float?
    let topP: Float?
    let topK: Int?
    let stop: [String]
    let stream: Bool?

    private enum CodingKeys: String, CodingKey {
        case model, prompt, prefix, suffix, middle, temperature, stop, stream
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        let decodedPrefix = Self.decodeStringOrFirstArray(from: c, forKey: .prefix)
        prefix = decodedPrefix
        suffix = Self.decodeStringOrFirstArray(from: c, forKey: .suffix)
        middle = Self.decodeStringOrFirstArray(from: c, forKey: .middle)
        // `prompt` may be a string or an array of strings. FIM clients send a
        // single string; for an array we take the first entry. Some OpenAI-
        // compatible insertion clients use `prefix` instead of `prompt`; treat
        // that as the raw prompt only when `prompt` is absent.
        prompt = Self.decodeStringOrFirstArray(from: c, forKey: .prompt) ?? decodedPrefix ?? ""
        maxTokens = try? c.decodeIfPresent(Int.self, forKey: .maxTokens)
        temperature = try? c.decodeIfPresent(Float.self, forKey: .temperature)
        topP = try? c.decodeIfPresent(Float.self, forKey: .topP)
        topK = try? c.decodeIfPresent(Int.self, forKey: .topK)
        // `stop` may be a string or an array of strings.
        if let s = try? c.decode(String.self, forKey: .stop) {
            stop = [s]
        } else if let arr = try? c.decode([String].self, forKey: .stop) {
            stop = arr
        } else {
            stop = []
        }
        stream = try? c.decodeIfPresent(Bool.self, forKey: .stream)
    }

    private static func decodeStringOrFirstArray(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        if let s = try? container.decode(String.self, forKey: key) {
            return s
        }
        if let arr = try? container.decode([String].self, forKey: key) {
            return arr.first
        }
        return nil
    }

    /// FIM completions are short; default generously when the client omits
    /// `max_tokens` (OpenAI's legacy default of 16 is too small for most
    /// autocomplete use).
    var resolvedMaxTokens: Int { maxTokens ?? 256 }

    /// The current local raw-completion generation contract accepts one prompt
    /// string. A prompt that already contains model-native FIM tokens is routed
    /// verbatim; separate `suffix` / `middle` fields cannot be honored without
    /// a runtime-level suffix channel, so reject them explicitly instead of
    /// ignoring suffix context and generating a misleading left-to-right
    /// continuation.
    var unsupportedFIMReason: String? {
        var unsupportedFields: [String] = []
        if let suffix, !suffix.isEmpty {
            unsupportedFields.append("suffix")
        }
        if let middle, !middle.isEmpty {
            unsupportedFields.append("middle")
        }
        guard !unsupportedFields.isEmpty else { return nil }
        let fields = unsupportedFields.map { "'\($0)'" }.joined(separator: ", ")
        return "FIM fields \(fields) are not supported by the local /v1/completions runtime. "
            + "Send a single raw prompt containing the model's native FIM tokens, or omit "
            + "separate suffix/middle fields."
    }
}

struct ChatCompletionRequest: Codable, Sendable {
    let model: String
    var messages: [ChatMessage]
    let temperature: Float?
    let max_tokens: Int?
    /// OpenAI newer alias for max_tokens; accepted on inbound requests alongside max_tokens.
    var max_completion_tokens: Int? = nil
    let stream: Bool?
    let top_p: Float?
    var top_k: Int? = nil
    /// Extension sampling knob (mlx/llama.cpp ecosystems): minimum
    /// probability cutoff relative to the top token. Mapped to
    /// `GenerationParameters.minPOverride`.
    var min_p: Float? = nil
    let frequency_penalty: Float?
    let presence_penalty: Float?
    let stop: [String]?
    let n: Int?
    /// OpenAI tools/function-calling definitions
    let tools: [Tool]?
    /// OpenAI tool_choice ("none" | "auto" | {"type":"function","function":{"name":...}})
    let tool_choice: ToolChoiceOption?
    /// Optional session identifier for chat/history grouping. Not a KV cache key —
    /// vmlx-swift's `CacheCoordinator` is content-addressed and discovers
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
    /// Local-only correlation id tying this request to the chat assistant
    /// turn that produced it, so the Insights tab can be opened focused on a
    /// specific response. Not decoded from OpenAI JSON, not forwarded to
    /// remote providers.
    var turnId: UUID? = nil
    /// Per-request thinking toggle. Translated to `modelOptions["disableThinking"]`
    /// at request entry; absent preserves server defaults.
    var enable_thinking: Bool? = nil
    /// OpenAI-compatible reasoning effort. Local Hy3 uses this as the native
    /// `reasoning_effort` chat-template kwarg; remote providers forward it
    /// natively where supported.
    var reasoning_effort: String? = nil
    /// Local-only marker for app/UI requests whose sampling values came from
    /// profile defaults. Not decoded from OpenAI JSON and not forwarded to
    /// remote providers.
    var samplingParametersAreImplicit: Bool = false
    /// Local-only marker set by agent-driven surfaces (the `/agents/{id}/run`
    /// endpoint, dispatch, and agent-bound Chat sessions) so `message_sent`
    /// telemetry can label the turn `is_agent`. Not decoded from OpenAI JSON
    /// and not forwarded to remote providers.
    var isAgentRequest: Bool = false
    /// Stable per-logical-step idempotency token. Set by the chat surface and
    /// reused across connect-phase and transient agent-loop retries so the
    /// Osaurus Router can dedupe billing on a re-POST. Not decoded from inbound
    /// OpenAI JSON; forwarded ONLY to the router (in the signed request body).
    var idempotencyKey: String? = nil
    /// Local-only marker set by a chat session that targets a paired/discovered
    /// remote Osaurus *agent* (Mode 2). When true the request is routed to the
    /// remote `/agents/{address}/run` endpoint so the agent runs fully
    /// server-side (its own model + context + tools) and only text deltas
    /// stream back. When false an `.osaurus` provider is used as a plain
    /// OpenAI-compatible inference backend (`/chat/completions`, Mode 1). Not
    /// decoded from OpenAI JSON and not forwarded to remote providers.
    var runAsRemoteAgent: Bool = false
    /// Local-only: the remote agent's live effective model (the model the peer
    /// will actually run), carried purely so the Insights log records *that*
    /// instead of the local prefixed fallback (e.g. `coco/foundation`) the
    /// picker pinned when the agent's real model isn't in the device catalog.
    /// Only meaningful for Mode 2 (`runAsRemoteAgent`); over the wire Mode 2
    /// omits `model` entirely (the peer resolves its own effective model).
    /// Not decoded from OpenAI JSON and not forwarded to remote providers.
    var remoteAgentLogModel: String? = nil
    /// Local-only: the `RemoteProvider` id of the remote agent this Mode 2 run
    /// targets. With `runAsRemoteAgent`, `ChatEngine` routes directly to this
    /// provider's service instead of by model string, so a stale `selectedModel`
    /// (e.g. a leftover prefix like `fugu/...`) can't redirect an agent run to a
    /// different provider. Not decoded from OpenAI JSON, not sent to providers.
    var remoteAgentProviderId: UUID? = nil

    /// Resolved max tokens, preferring max_tokens then max_completion_tokens.
    var resolvedMaxTokens: Int? { max_tokens ?? max_completion_tokens }

    private enum CodingKeys: String, CodingKey {
        case model, messages, temperature, max_tokens, max_completion_tokens, stream, top_p, top_k
        case min_p
        case frequency_penalty, presence_penalty, stop, n
        case tools, tool_choice, session_id
        case seed, response_format, stream_options
        case enable_thinking, reasoning_effort
    }

    func withModel(_ newModel: String) -> ChatCompletionRequest {
        var copy = ChatCompletionRequest(
            model: newModel,
            messages: messages,
            temperature: temperature,
            max_tokens: max_tokens,
            stream: stream,
            top_p: top_p,
            top_k: top_k,
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
        copy.max_completion_tokens = max_completion_tokens
        copy.min_p = min_p
        copy.modelOptions = modelOptions
        copy.ttftTrace = ttftTrace
        copy.turnId = turnId
        copy.enable_thinking = enable_thinking
        copy.reasoning_effort = reasoning_effort
        copy.samplingParametersAreImplicit = samplingParametersAreImplicit
        copy.isAgentRequest = isAgentRequest
        copy.idempotencyKey = idempotencyKey
        copy.runAsRemoteAgent = runAsRemoteAgent
        copy.remoteAgentLogModel = remoteAgentLogModel
        copy.remoteAgentProviderId = remoteAgentProviderId
        return copy
    }

    func withContext(
        messages newMessages: [ChatMessage],
        tools newTools: [Tool]?,
        toolChoice newToolChoice: ToolChoiceOption?
    ) -> ChatCompletionRequest {
        var copy = ChatCompletionRequest(
            model: model,
            messages: newMessages,
            temperature: temperature,
            max_tokens: max_tokens,
            stream: stream,
            top_p: top_p,
            top_k: top_k,
            frequency_penalty: frequency_penalty,
            presence_penalty: presence_penalty,
            stop: stop,
            n: n,
            tools: newTools,
            tool_choice: newToolChoice,
            session_id: session_id,
            seed: seed,
            response_format: response_format,
            stream_options: stream_options
        )
        copy.max_completion_tokens = max_completion_tokens
        copy.min_p = min_p
        copy.modelOptions = modelOptions
        copy.ttftTrace = ttftTrace
        copy.turnId = turnId
        copy.enable_thinking = enable_thinking
        copy.reasoning_effort = reasoning_effort
        copy.samplingParametersAreImplicit = samplingParametersAreImplicit
        copy.isAgentRequest = isAgentRequest
        copy.idempotencyKey = idempotencyKey
        copy.runAsRemoteAgent = runAsRemoteAgent
        copy.remoteAgentLogModel = remoteAgentLogModel
        copy.remoteAgentProviderId = remoteAgentProviderId
        return copy
    }
}

extension ChatCompletionRequest {
    /// Custom decode so `stop` accepts the OpenAI-legal single string as
    /// well as an array of strings — a bare string used to fail the whole
    /// request decode and surface as a generic 400 "Invalid request
    /// format". Declared in an extension so the synthesized memberwise
    /// initializer (used by HTTPHandler/ChatEngine sub-request builders)
    /// survives. Decodes exactly the `CodingKeys` set; local-only fields
    /// keep their defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        temperature = try container.decodeIfPresent(Float.self, forKey: .temperature)
        max_tokens = try container.decodeIfPresent(Int.self, forKey: .max_tokens)
        max_completion_tokens = try container.decodeIfPresent(
            Int.self, forKey: .max_completion_tokens)
        stream = try container.decodeIfPresent(Bool.self, forKey: .stream)
        top_p = try container.decodeIfPresent(Float.self, forKey: .top_p)
        top_k = try container.decodeIfPresent(Int.self, forKey: .top_k)
        min_p = try container.decodeIfPresent(Float.self, forKey: .min_p)
        frequency_penalty = try container.decodeIfPresent(Float.self, forKey: .frequency_penalty)
        presence_penalty = try container.decodeIfPresent(Float.self, forKey: .presence_penalty)
        if let singleStop = try? container.decode(String.self, forKey: .stop) {
            stop = [singleStop]
        } else {
            stop = try container.decodeIfPresent([String].self, forKey: .stop)
        }
        n = try container.decodeIfPresent(Int.self, forKey: .n)
        tools = try container.decodeIfPresent([Tool].self, forKey: .tools)
        tool_choice = try container.decodeIfPresent(ToolChoiceOption.self, forKey: .tool_choice)
        session_id = try container.decodeIfPresent(String.self, forKey: .session_id)
        seed = try container.decodeIfPresent(Int.self, forKey: .seed)
        response_format = try container.decodeIfPresent(ResponseFormat.self, forKey: .response_format)
        stream_options = try container.decodeIfPresent(StreamOptions.self, forKey: .stream_options)
        enable_thinking = try container.decodeIfPresent(Bool.self, forKey: .enable_thinking)
        reasoning_effort = try container.decodeIfPresent(String.self, forKey: .reasoning_effort)
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
    let tokens_per_second: Double?

    init(
        prompt_tokens: Int,
        completion_tokens: Int,
        total_tokens: Int,
        tokens_per_second: Double? = nil
    ) {
        self.prompt_tokens = prompt_tokens
        self.completion_tokens = completion_tokens
        self.total_tokens = total_tokens
        self.tokens_per_second = tokens_per_second
    }
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
    /// Content hash of the system prompt + canonical tool schemas used for this request.
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

    private enum CodingKeys: String, CodingKey {
        case role, content, refusal, tool_calls, reasoning_content
    }

    /// One entry of Mistral's structured `content` array. Mistral streams
    /// reasoning models as `content: [{type:"thinking", thinking:[{type:"text",
    /// text:…}]}, {type:"text", text:…}]` rather than the OpenAI-standard plain
    /// `content` string plus separate `reasoning_content`. Decoded here so
    /// thinking chunks route to `reasoning_content` and text chunks to `content`,
    /// letting the rest of the streaming pipeline handle Mistral like every other
    /// separate-channel reasoning provider.
    private struct MistralContentChunk: Decodable {
        let type: String?
        let text: String?
        let thinking: [InnerText]?

        struct InnerText: Decodable {
            let type: String?
            let text: String?
        }
    }

    init(from decoder: Decoder) throws {
        // Preserve the synthesized decoder's throwing `decodeIfPresent`
        // semantics for every field: a present-but-malformed value must throw so
        // the stream parser's split-JSON recovery path can retry, rather than
        // being silently dropped. Only `content` adds a string-or-array fallback.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decodeIfPresent(String.self, forKey: .role)
        self.refusal = try container.decodeIfPresent(String.self, forKey: .refusal)
        self.tool_calls = try container.decodeIfPresent([DeltaToolCall].self, forKey: .tool_calls)
        let explicitReasoning = try container.decodeIfPresent(String.self, forKey: .reasoning_content)

        do {
            // Standard OpenAI-compatible shape: `content` is a string (or absent).
            self.content = try container.decodeIfPresent(String.self, forKey: .content)
            self.reasoning_content = explicitReasoning
        } catch DecodingError.typeMismatch(_, _) {
            // Mistral reasoning models stream `content` as a structured array of
            // thinking/text chunks. Route thinking to `reasoning_content` and
            // text to `content`. A genuine structural error (not a type mismatch)
            // propagates from here so recovery can retry.
            let chunks = try container.decode([MistralContentChunk].self, forKey: .content)
            var visible = ""
            var thinking = ""
            for chunk in chunks {
                if chunk.type == "thinking" {
                    for part in chunk.thinking ?? [] { thinking += part.text ?? "" }
                } else {
                    visible += chunk.text ?? ""
                }
            }
            self.content = visible.isEmpty ? nil : visible
            let mergedReasoning = (explicitReasoning ?? "") + thinking
            self.reasoning_content = mergedReasoning.isEmpty ? nil : mergedReasoning
        }
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
    /// Osaurus extension chunk for determinate local prefill progress. Emitted
    /// with empty choices before the first token when the runtime reports it.
    var osaurus_prefill: PrefillProgressState? = nil
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
    case required
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
            case "required": self = .required
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription:
                        "Unsupported tool_choice string '\(str)'. Expected 'auto', 'none', 'required', or a typed function selector."
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
        case .required:
            try container.encode("required")
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
    /// Convert JSON Schema into the shape expected by local chat templates.
    ///
    /// Some local templates, notably Gemma-4's native tool template, treat
    /// schema `type` fields as scalars and run string filters over them.
    /// OpenAI/MCP schemas commonly spell nullable fields as
    /// `type: ["string", "null"]`. That is valid JSON Schema, but it is not
    /// renderable by those templates. The transformation below rewrites only
    /// schema-position dictionaries into template-renderable shapes while
    /// preserving property maps whose keys may legitimately include "type".
    var chatTemplateSchemaValue: JSONValue {
        normalizedChatTemplateSchemaValue(inSchemaPosition: true)
    }

    private func normalizedChatTemplateSchemaValue(inSchemaPosition: Bool) -> JSONValue {
        switch self {
        case .object(let obj):
            var normalized: [String: JSONValue] = [:]
            for (key, value) in obj {
                switch key {
                case "properties":
                    if case .object(let properties) = value {
                        normalized[key] = .object(
                            properties.mapValues {
                                $0.normalizedChatTemplateSchemaValue(inSchemaPosition: true)
                            }
                        )
                    } else {
                        normalized[key] = value.normalizedChatTemplateSchemaValue(
                            inSchemaPosition: false
                        )
                    }
                case "items", "additionalProperties", "response":
                    // Gemma-4's native template pipes a schema's boolean
                    // `additionalProperties` through `| upper`, throwing "upper
                    // filter requires string". Drop only that boolean form; the
                    // schema-object form renders fine, and the original schema
                    // still drives argument validation, so this is lossless.
                    if key == "additionalProperties", case .bool = value { continue }
                    normalized[key] = value.normalizedChatTemplateSchemaValue(
                        inSchemaPosition: true
                    )
                case "oneOf", "anyOf", "allOf":
                    if case .array(let branches) = value {
                        normalized[key] = .array(
                            branches.map {
                                $0.normalizedChatTemplateSchemaValue(inSchemaPosition: true)
                            }
                        )
                    } else {
                        normalized[key] = value.normalizedChatTemplateSchemaValue(
                            inSchemaPosition: false
                        )
                    }
                default:
                    normalized[key] = value.normalizedChatTemplateSchemaValue(
                        inSchemaPosition: false
                    )
                }
            }
            if inSchemaPosition {
                Self.normalizeTemplateRenderableSchemaType(&normalized)
            }
            return .object(normalized)
        case .array(let arr):
            return .array(
                arr.map { $0.normalizedChatTemplateSchemaValue(inSchemaPosition: inSchemaPosition) }
            )
        case .null, .bool, .number, .string:
            return self
        }
    }

    private static func normalizeTemplateRenderableSchemaType(_ object: inout [String: JSONValue]) {
        switch object["type"] {
        case .some(.string):
            return
        case .some(.array(let entries)):
            normalizeTypeUnion(entries, in: &object)
        case .some(.null), .some(.bool), .some(.number), .some(.object):
            object["type"] = inferredFallbackType(for: object)
        case nil:
            object["type"] = inferredFallbackType(for: object)
        }
    }

    private static func normalizeTypeUnion(_ entries: [JSONValue], in object: inout [String: JSONValue]) {
        var hasNull = false
        var scalars: [String] = []
        for entry in entries {
            guard case .string(let typeName) = entry else {
                object["type"] = inferredFallbackType(for: object)
                return
            }
            if typeName == "null" {
                hasNull = true
            } else {
                scalars.append(typeName)
            }
        }

        guard let scalar = scalars.first else { return }
        object["type"] = .string(scalar)
        if hasNull {
            object["nullable"] = .bool(true)
        }
        if scalars.count > 1 {
            object["x-osaurus-original-type"] = .array(scalars.map { .string($0) })
        }
    }

    private static func inferredFallbackType(for object: [String: JSONValue]) -> JSONValue {
        if object["properties"] != nil { return .string("object") }
        if object["items"] != nil { return .string("array") }
        return .string("string")
    }

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
            fn["parameters"] = parameters.chatTemplateSchemaValue.sendableValue
        }
        return fn
    }
}

extension Tool {
    /// Convert to Tokenizers.ToolSpec (`[String: any Sendable]`) for MLX chat templates.
    ///
    /// The dictionary is normalised via `canonicalize` so every leaf is
    /// JSON-encodable and the values bridge cleanly through Foundation.
    /// Byte-stability of the resulting `<tools>` block in the rendered
    /// prompt is enforced at *encode time* by `JSONEncoder.osaurusCanonical()`
    /// / `.osaurusCanonical` writing options (see
    /// `docs/JSON_DETERMINISM.md`). Without those, key iteration order
    /// from a fresh dictionary literal silently invalidates the MLX paged
    /// KV cache prefix.
    func toTokenizerToolSpec() -> [String: any Sendable] {
        let raw: [String: any Sendable] = [
            "type": type,
            "function": function.toFunctionSpec(),
        ]
        return Self.canonicalize(raw) ?? raw
    }

    /// Canonical JSON bytes for hash/evidence paths that need to distinguish
    /// compact bootstrap schemas from full tool schemas. This mirrors the
    /// tokenizer-tool shape so prefix evidence tracks the bytes handed to the
    /// chat template, not just the callable names.
    func canonicalHashPayload() -> Data {
        let spec = toTokenizerToolSpec()
        if JSONSerialization.isValidJSONObject(spec),
            let data = try? JSONSerialization.data(withJSONObject: spec, options: .osaurusCanonical)
        {
            return data
        }

        let encoder = JSONEncoder.osaurusCanonical()
        return (try? encoder.encode(self)) ?? Data("\(type)\0\(function.name)".utf8)
    }

    /// Normalise a `Sendable` JSON value into a Foundation-bridged dict.
    /// Round-trips through `JSONSerialization` so every leaf comes back as
    /// `NSNumber` / `NSString` / `NSArray` / `NSDictionary`, which avoids
    /// surprises in downstream chat-template renderers. Falls back to
    /// `JSONCanonicalization.normalizeObject` on the extremely unlikely
    /// serialisation failure so callers never see the raw unsorted input
    /// — preserving the determinism guarantee documented in
    /// `docs/JSON_DETERMINISM.md`.
    fileprivate static func canonicalize(_ value: [String: any Sendable]) -> [String: any Sendable]? {
        if JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: .osaurusCanonical),
            let reparsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: any Sendable]
        {
            return reparsed
        }
        return JSONCanonicalization.normalizeObject(value)
    }
}
