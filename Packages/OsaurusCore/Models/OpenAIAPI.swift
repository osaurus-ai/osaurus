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
  let created: Int
  var owned_by: String = "osaurus"
  var permission: [String] = []
  let root: String
  var parent: String? = nil
  var name: String? = nil
  var model: String? = nil
  var modified_at: String? = nil
  var size: Int? = nil
  var digest: String? = nil
  var details: ModelDetails? = nil
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
}

/// Chat message in OpenAI format
struct ChatMessage: Codable, Sendable {
  let role: String
  let content: String?
  /// Present when assistant requests tool invocations
  let tool_calls: [ToolCall]?
  /// Required for role=="tool" messages to associate with a prior tool call
  let tool_call_id: String?
}

// Allow decoding OpenAI-style array-of-parts content while preserving string encoding
extension ChatMessage {
  private struct ContentPart: Codable {
    let type: String
    let text: String?
    let input_text: String?
  }

  private enum CodingKeys: String, CodingKey {
    case role
    case content
    case tool_calls
    case tool_call_id
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.role = try container.decode(String.self, forKey: .role)
    self.tool_calls = try? container.decode([ToolCall].self, forKey: .tool_calls)
    self.tool_call_id = try? container.decode(String.self, forKey: .tool_call_id)

    if let stringContent = try? container.decode(String.self, forKey: .content) {
      self.content = stringContent
    } else if let parts = try? container.decode([ContentPart].self, forKey: .content) {
      let texts = parts.compactMap { $0.text ?? $0.input_text }
      self.content = texts.isEmpty ? nil : texts.joined()
    } else {
      self.content = nil
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(role, forKey: .role)
    try container.encodeIfPresent(content, forKey: .content)
    try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
    try container.encodeIfPresent(tool_call_id, forKey: .tool_call_id)
  }
}

extension ChatMessage {
  init(role: String, content: String) {
    self.role = role
    self.content = content
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
    role: String? = nil, content: String? = nil, refusal: String? = nil,
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
enum JSONValue: Codable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  init(from decoder: Decoder) throws {
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
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  func encode(to encoder: Encoder) throws {
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
