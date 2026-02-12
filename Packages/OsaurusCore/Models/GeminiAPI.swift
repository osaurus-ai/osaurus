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

    private enum CodingKeys: String, CodingKey {
        case contents, tools, toolConfig, systemInstruction, generationConfig, safetySettings
    }
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

/// Gemini content part (polymorphic: text, functionCall, functionResponse)
///
/// `thoughtSignature` is encoded/decoded at this level (as a sibling of `functionCall`)
/// per the Gemini API spec, then stored on `GeminiFunctionCall` for convenience.
enum GeminiPart: Codable, Sendable {
    case text(String)
    case functionCall(GeminiFunctionCall)
    case functionResponse(GeminiFunctionResponse)

    private enum CodingKeys: String, CodingKey {
        case text, functionCall, functionResponse, thoughtSignature
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self = .text(text)
        } else if let funcCall = try container.decodeIfPresent(GeminiFunctionCall.self, forKey: .functionCall) {
            // thoughtSignature lives at part level in JSON, inject it into the model object
            let thoughtSig = try container.decodeIfPresent(String.self, forKey: .thoughtSignature)
            let enriched = GeminiFunctionCall(name: funcCall.name, args: funcCall.args, thoughtSignature: thoughtSig)
            self = .functionCall(enriched)
        } else if let funcResponse = try container.decodeIfPresent(
            GeminiFunctionResponse.self,
            forKey: .functionResponse
        ) {
            self = .functionResponse(funcResponse)
        } else {
            // Default to empty text for unknown part types
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(text, forKey: .text)
        case .functionCall(let funcCall):
            try container.encode(funcCall, forKey: .functionCall)
            // thoughtSignature must be a sibling of functionCall per Gemini API spec
            try container.encodeIfPresent(funcCall.thoughtSignature, forKey: .thoughtSignature)
        case .functionResponse(let funcResponse):
            try container.encode(funcResponse, forKey: .functionResponse)
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

// MARK: - Tool Definitions

/// Gemini tool definition
struct GeminiTool: Codable, Sendable {
    let functionDeclarations: [GeminiFunctionDeclaration]?

    private enum CodingKeys: String, CodingKey {
        case functionDeclarations
    }
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

    private enum CodingKeys: String, CodingKey {
        case functionCallingConfig
    }
}

/// Gemini function calling configuration
struct GeminiFunctionCallingConfig: Codable, Sendable {
    let mode: String  // "AUTO", "NONE", "ANY"

    private enum CodingKeys: String, CodingKey {
        case mode
    }
}

// MARK: - Safety Settings

/// Gemini safety setting
struct GeminiSafetySetting: Codable, Sendable {
    let category: String
    let threshold: String
}

// MARK: - Generation Config

/// Gemini generation configuration
struct GeminiGenerationConfig: Codable, Sendable {
    let temperature: Double?
    let maxOutputTokens: Int?
    let topP: Double?
    let topK: Int?
    let stopSequences: [String]?

    private enum CodingKeys: String, CodingKey {
        case temperature, maxOutputTokens, topP, topK, stopSequences
    }
}

// MARK: - Response Models

/// Gemini GenerateContent API response
struct GeminiGenerateContentResponse: Codable, Sendable {
    let candidates: [GeminiCandidate]?
    let usageMetadata: GeminiUsageMetadata?

    private enum CodingKeys: String, CodingKey {
        case candidates, usageMetadata
    }
}

/// Gemini response candidate
struct GeminiCandidate: Codable, Sendable {
    let content: GeminiContent?
    let finishReason: String?
    let index: Int?

    private enum CodingKeys: String, CodingKey {
        case content, finishReason, index
    }
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

    /// Support for nextPageToken if paginated
    let nextPageToken: String?

    private enum CodingKeys: String, CodingKey {
        case models, nextPageToken
    }
}

/// Gemini model info from list endpoint
struct GeminiModelInfo: Codable, Sendable {
    let name: String  // e.g. "models/gemini-2.0-flash"
    let displayName: String?
    let description: String?
    let supportedGenerationMethods: [String]?

    private enum CodingKeys: String, CodingKey {
        case name, displayName, description, supportedGenerationMethods
    }

    /// Extract the short model ID (strips "models/" prefix)
    var modelId: String {
        if name.hasPrefix("models/") {
            return String(name.dropFirst("models/".count))
        }
        return name
    }
}
