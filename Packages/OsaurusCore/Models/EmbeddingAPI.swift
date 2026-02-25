//
//  EmbeddingAPI.swift
//  osaurus
//
//  Request/response models for embedding endpoints.
//  Supports both OpenAI (/v1/embeddings) and Ollama (/api/embed) formats.
//

import Foundation

// MARK: - Shared Input Type

/// Decodes both `"single string"` and `["array", "of", "strings"]` from JSON.
enum EmbeddingInput: Codable, Sendable {
    case single(String)
    case multiple([String])

    var texts: [String] {
        switch self {
        case .single(let s): [s]
        case .multiple(let a): a
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .single(str)
        } else if let arr = try? container.decode([String].self) {
            self = .multiple(arr)
        } else {
            throw DecodingError.typeMismatch(
                EmbeddingInput.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a string or array of strings")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let s): try container.encode(s)
        case .multiple(let a): try container.encode(a)
        }
    }
}

// MARK: - Shared Request

/// Both OpenAI and Ollama endpoints accept the same request shape.
struct EmbeddingRequest: Codable, Sendable {
    let model: String
    let input: EmbeddingInput
    let encoding_format: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        input = try c.decode(EmbeddingInput.self, forKey: .input)
        encoding_format = try c.decodeIfPresent(String.self, forKey: .encoding_format)
    }
}

// MARK: - OpenAI Response (/v1/embeddings)

struct OpenAIEmbeddingResponse: Codable, Sendable {
    let object: String
    let data: [OpenAIEmbeddingObject]
    let model: String
    let usage: OpenAIEmbeddingUsage

    init(data: [OpenAIEmbeddingObject], model: String, usage: OpenAIEmbeddingUsage) {
        self.object = "list"
        self.data = data
        self.model = model
        self.usage = usage
    }
}

struct OpenAIEmbeddingObject: Codable, Sendable {
    let object: String
    let embedding: [Float]
    let index: Int

    init(embedding: [Float], index: Int) {
        self.object = "embedding"
        self.embedding = embedding
        self.index = index
    }
}

struct OpenAIEmbeddingUsage: Codable, Sendable {
    let prompt_tokens: Int
    let total_tokens: Int
}

// MARK: - Ollama Response (/api/embed)

struct OllamaEmbedResponse: Codable, Sendable {
    let model: String
    let embeddings: [[Float]]
}
