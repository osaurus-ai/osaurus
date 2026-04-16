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
    /// Internal metadata for budgeted prompt guidance and future scheduling.
    var promptMetadata: ToolMetadata? { get }

    /// Execute the tool with arguments provided as a JSON string
    func execute(argumentsJSON: String) async throws -> String
}

extension OsaurusTool {
    var promptMetadata: ToolMetadata? {
        ToolMetadataCatalog.metadata(for: name)
    }

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

    // MARK: - Argument Coercion

    func coerceStringArray(_ value: Any?) -> [String]? { ArgumentCoercion.stringArray(value) }
    func coerceInt(_ value: Any?) -> Int? { ArgumentCoercion.int(value) }
    func coerceBool(_ value: Any?) -> Bool? { ArgumentCoercion.bool(value) }
}

// MARK: - Argument Coercion

/// Shared coercion helpers for tool arguments. Local/quantized models frequently
/// serialize values with wrong JSON types (arrays as strings, numbers as strings, etc.).
/// These helpers normalize common mistakes so tool execution succeeds.
enum ArgumentCoercion {
    /// Coerce to `[String]`: actual array, JSON-encoded string (`"[\"a\"]"`),
    /// or bare string wrapped into a single-element array.
    static func stringArray(_ value: Any?) -> [String]? {
        if let arr = value as? [String] { return arr }
        if let str = value as? String {
            if let data = str.data(using: .utf8),
                let parsed = try? JSONSerialization.jsonObject(with: data) as? [String]
            {
                return parsed
            }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return [trimmed] }
        }
        return nil
    }

    /// Coerce to `Int`: native int, `NSNumber`, or string-encoded integer (`"30"`).
    static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = (value as? NSNumber)?.intValue { return n }
        if let s = value as? String, let n = Int(s) { return n }
        return nil
    }

    /// Coerce to `Bool`: native bool, string variants (`"true"`, `"1"`, `"yes"`), or `NSNumber`.
    static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let s = value as? String {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }
}
