//
//  ToolRegistry.swift
//  osaurus
//
//  Central registry for chat tools. Provides OpenAI tool specs and execution by name.
//

import Foundation

@MainActor
final class ToolRegistry {
  static let shared = ToolRegistry()

  private var toolsByName: [String: ChatTool] = [:]

  private init() {
    // Register built-in tools here
    register(WeatherTool())
  }

  func register(_ tool: ChatTool) {
    toolsByName[tool.name] = tool
  }

  /// OpenAI-compatible tool specifications for the current registry
  func specs() -> [Tool] {
    return toolsByName.values.map { $0.asOpenAITool() }
  }

  /// Execute a tool by name with raw JSON arguments
  func execute(name: String, argumentsJSON: String) async throws -> String {
    guard let tool = toolsByName[name] else {
      throw NSError(
        domain: "ToolRegistry", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"])
    }
    return try await tool.execute(argumentsJSON: argumentsJSON)
  }
}
