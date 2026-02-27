//
//  GeminiAPI.swift
//  osaurus
//
//  Google Gemini API compatible request/response models.
//

import Foundation

// MARK: - Request Models

/// Gemini GenerateContent API request
struct GeminiGenerateContentRequest: Codable, Sendable {
    let contents: [GeminiContent]
    let tools: [GeminiTool]?
    let toolConfig: GeminiToolConfig?
    let systemInstruction: GeminiContent?
    let generationConfig: GeminiGenerationConfig?
    let safetySettings: [GeminiSafetySetting]?
}

/// Gemini content object (used for messages and system instructions)
struct GeminiContent: Codable, Sendable {
    let role: String?
    let parts: [GeminiPart]

    init(role: String? = nil, parts: [GeminiPart]) {
        self.role = role
        self.parts = parts
    }
}

/// Gemini content part (polymorphic: text, functionCall, functionResponse, inlineData)
///
/// `thought` and `thoughtSignature` are part-level metadata fields per the Gemini API spec.
/// `thought` marks intermediate thinking/reasoning parts that should not be shown to the user.
/// `thoughtSignature` is an opaque token that must be echoed back in multi-turn requests.
struct GeminiPart: Codable, Sendable {
    /// The polymorphic content payload of this part.
    enum Content: Sendable {
        case text(String)
        case functionCall(GeminiFunctionCall)
        case functionResponse(GeminiFunctionResponse)
        case inlineData(GeminiInlineData)
    }

    let content: Content
    /// When `true`, this part is an intermediate thinking artifact (e.g. draft image).
    let thought: Bool?
    /// Opaque token for Gemini thinking-mode models. Must be echoed back in subsequent
    /// requests so the model can maintain continuity of its reasoning chain.
    let thoughtSignature: String?

    // MARK: - Convenience factories (match the old enum-case API)

    static func text(_ text: String) -> GeminiPart {
        GeminiPart(content: .text(text), thought: nil, thoughtSignature: nil)
    }

    static func functionCall(_ call: GeminiFunctionCall) -> GeminiPart {
        GeminiPart(content: .functionCall(call), thought: nil, thoughtSignature: call.thoughtSignature)
    }

    static func functionResponse(_ resp: GeminiFunctionResponse) -> GeminiPart {
        GeminiPart(content: .functionResponse(resp), thought: nil, thoughtSignature: nil)
    }

    static func inlineData(_ data: GeminiInlineData) -> GeminiPart {
        GeminiPart(content: .inlineData(data), thought: nil, thoughtSignature: nil)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case text, functionCall, functionResponse, thoughtSignature, thought, inlineData
    }

    init(content: Content, thought: Bool? = nil, thoughtSignature: String? = nil) {
        self.content = content
        self.thought = thought
        self.thoughtSignature = thoughtSignature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Decode part-level metadata
        let thought = try container.decodeIfPresent(Bool.self, forKey: .thought)
        let thoughtSig = try container.decodeIfPresent(String.self, forKey: .thoughtSignature)

        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self.content = .text(text)
        } else if let funcCall = try container.decodeIfPresent(GeminiFunctionCall.self, forKey: .functionCall) {
            // Inject thoughtSignature into the model object for convenience
            let enriched = GeminiFunctionCall(name: funcCall.name, args: funcCall.args, thoughtSignature: thoughtSig)
            self.content = .functionCall(enriched)
        } else if let funcResponse = try container.decodeIfPresent(
            GeminiFunctionResponse.self,
            forKey: .functionResponse
        ) {
            self.content = .functionResponse(funcResponse)
        } else if let data = try container.decodeIfPresent(GeminiInlineData.self, forKey: .inlineData) {
            self.content = .inlineData(data)
        } else {
            // Default to empty text for unknown part types
            self.content = .text("")
        }

        self.thought = thought
        self.thoughtSignature = thoughtSig
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        // Encode part-level metadata
        try container.encodeIfPresent(thought, forKey: .thought)

        switch content {
        case .text(let text):
            try container.encode(text, forKey: .text)
            // thoughtSignature is a sibling of text per Gemini API spec
            try container.encodeIfPresent(thoughtSignature, forKey: .thoughtSignature)
        case .functionCall(let funcCall):
            try container.encode(funcCall, forKey: .functionCall)
            // thoughtSignature is a sibling of functionCall per Gemini API spec
            try container.encodeIfPresent(funcCall.thoughtSignature ?? thoughtSignature, forKey: .thoughtSignature)
        case .functionResponse(let funcResponse):
            try container.encode(funcResponse, forKey: .functionResponse)
        case .inlineData(let data):
            try container.encode(data, forKey: .inlineData)
            // thoughtSignature is a sibling of inlineData per Gemini API spec
            try container.encodeIfPresent(thoughtSignature, forKey: .thoughtSignature)
        }
    }
}

/// Gemini function call (model requesting tool invocation)
struct GeminiFunctionCall: Codable, Sendable {
    let name: String
    let args: [String: AnyCodableValue]?
    /// Opaque token for Gemini thinking-mode models. Must be echoed back in subsequent
    /// requests so the model can maintain continuity of its reasoning chain across tool calls.
    /// Note: This field is serialized at the `GeminiPart` level (not inside `functionCall`).
    let thoughtSignature: String?

    private enum CodingKeys: String, CodingKey {
        case name, args
        // thoughtSignature is intentionally excluded — it is encoded/decoded
        // at the GeminiPart level as a sibling of functionCall per the Gemini API spec.
    }

    init(name: String, args: [String: AnyCodableValue]? = nil, thoughtSignature: String? = nil) {
        self.name = name
        self.args = args
        self.thoughtSignature = thoughtSignature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        args = try container.decodeIfPresent([String: AnyCodableValue].self, forKey: .args)
        // thoughtSignature is injected by GeminiPart after decoding
        thoughtSignature = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(args, forKey: .args)
        // thoughtSignature is encoded by GeminiPart at the part level
    }
}

/// Gemini function response (user providing tool output)
struct GeminiFunctionResponse: Codable, Sendable {
    let name: String
    let response: [String: AnyCodableValue]
}

/// Gemini inline data (images, audio, etc.)
struct GeminiInlineData: Codable, Sendable {
    let mimeType: String
    let data: String  // base64-encoded
}

// MARK: - Tool Definitions

/// Gemini tool definition
struct GeminiTool: Codable, Sendable {
    let functionDeclarations: [GeminiFunctionDeclaration]?
}

/// Gemini function declaration
struct GeminiFunctionDeclaration: Codable, Sendable {
    let name: String
    let description: String?
    let parameters: JSONValue?
}

/// Gemini tool configuration
struct GeminiToolConfig: Codable, Sendable {
    let functionCallingConfig: GeminiFunctionCallingConfig?
}

/// Gemini function calling configuration
struct GeminiFunctionCallingConfig: Codable, Sendable {
    let mode: String  // "AUTO", "NONE", "ANY"
}

// MARK: - Safety Settings

/// Gemini safety setting
struct GeminiSafetySetting: Codable, Sendable {
    let category: String
    let threshold: String
}

// MARK: - Generation Config

/// Gemini image generation configuration (aspect ratio, resolution)
struct GeminiImageConfig: Codable, Sendable {
    let aspectRatio: String?  // "1:1","1:4","1:8","2:3","3:2","3:4","4:1","4:3","4:5","5:4","8:1","9:16","16:9","21:9"
    let imageSize: String?  // "512px", "1K", "2K", "4K"
}

/// Gemini generation configuration
struct GeminiGenerationConfig: Codable, Sendable {
    let temperature: Double?
    let maxOutputTokens: Int?
    let topP: Double?
    let topK: Int?
    let stopSequences: [String]?
    let responseModalities: [String]?
    let imageConfig: GeminiImageConfig?
}

// MARK: - Response Models

/// Gemini GenerateContent API response
struct GeminiGenerateContentResponse: Codable, Sendable {
    let candidates: [GeminiCandidate]?
    let usageMetadata: GeminiUsageMetadata?
}

/// Gemini response candidate
struct GeminiCandidate: Codable, Sendable {
    let content: GeminiContent?
    let finishReason: String?
    let index: Int?
}

/// Gemini token usage metadata
struct GeminiUsageMetadata: Codable, Sendable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let totalTokenCount: Int?
}

// MARK: - Error Response

/// Gemini error response
struct GeminiErrorResponse: Codable, Sendable {
    let error: GeminiError

    struct GeminiError: Codable, Sendable {
        let code: Int
        let message: String
        let status: String?
    }
}

// MARK: - Models List Response

/// Gemini models list response (GET /models)
struct GeminiModelsResponse: Codable, Sendable {
    let models: [GeminiModelInfo]?
    let nextPageToken: String?
}

/// Gemini model info from list endpoint
struct GeminiModelInfo: Codable, Sendable {
    let name: String  // e.g. "models/gemini-2.0-flash"
    let displayName: String?
    let description: String?
    let supportedGenerationMethods: [String]?

    /// Extract the short model ID (strips "models/" prefix)
    var modelId: String {
        if name.hasPrefix("models/") {
            return String(name.dropFirst("models/".count))
        }
        return name
    }
}
