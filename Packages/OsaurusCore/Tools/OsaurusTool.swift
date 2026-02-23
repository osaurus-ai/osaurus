//
//  OsaurusTool.swift
//  osaurus
//
//  Defines the standardized tool protocol and helpers to expose OpenAI-compatible tool specs.
//

import Foundation

protocol OsaurusTool: Sendable {
    /// Unique tool name exposed to the model
    var name: String { get }
    /// Human description for the model and UI
    var description: String { get }
    /// JSON schema for function parameters (OpenAI-compatible minimal subset)
    var parameters: JSONValue? { get }

    /// Execute the tool with arguments provided as a JSON string
    func execute(argumentsJSON: String) async throws -> String
}

extension OsaurusTool {
    /// Build OpenAI-compatible Tool specification
    func asOpenAITool() -> Tool {
        Tool(
            type: "function",
            function: ToolFunction(name: name, description: description, parameters: parameters)
        )
    }

    /// Parse JSON arguments string into a dictionary.
    func parseArguments(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }
}
