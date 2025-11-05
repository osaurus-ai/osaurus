//
//  ChatTool.swift
//  osaurus
//
//  Defines a minimal tool protocol and helpers to expose OpenAI-compatible tool specs.
//

import Foundation

protocol ChatTool: Sendable {
  /// Unique tool name exposed to the model
  var name: String { get }
  /// Human description for the model and UI
  var toolDescription: String { get }
  /// JSON schema for function parameters (OpenAI-compatible minimal subset)
  var parameters: JSONValue? { get }

  /// Execute the tool with arguments provided as a JSON string
  func execute(argumentsJSON: String) async throws -> String
}

extension ChatTool {
  /// Build OpenAI-compatible Tool specification
  func asOpenAITool() -> Tool {
    return Tool(
      type: "function",
      function: ToolFunction(name: name, description: toolDescription, parameters: parameters))
  }
}
