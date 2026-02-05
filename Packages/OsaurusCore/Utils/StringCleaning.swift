//
//  StringCleaning.swift
//  OsaurusCore
//
//  Utility functions for cleaning and sanitizing string content.
//

import Foundation

/// Utilities for cleaning streamed content from LLM responses.
public enum StringCleaning {
    /// Strips leaked function-call JSON patterns from text content.
    ///
    /// Some models/providers may emit raw function call text (e.g., "Function: {...}")
    /// before or alongside the actual tool_calls field. This function removes such patterns.
    ///
    /// - Parameters:
    ///   - content: The text content to clean
    ///   - toolName: The name of the tool being called, used to detect leaked JSON
    /// - Returns: The cleaned content with function-call leakage removed
    public static func stripFunctionCallLeakage(_ content: String, toolName: String) -> String {
        var result = content

        // Pattern 1: Strip trailing "Function: {..." or "Assistant: Function: {..."
        // These patterns appear when models emit function calls as text
        if let range = result.range(of: "Function:", options: .caseInsensitive) {
            let suffix = String(result[range.lowerBound...])
            if suffix.contains("{") && (suffix.contains("\"name\"") || suffix.contains("\"\(toolName)\"")) {
                result = String(result[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                return result
            }
        }

        // Pattern 2: Strip trailing incomplete JSON that looks like a function call
        // e.g., {"name": "file_tree", "result": {
        if let lastBrace = result.lastIndex(of: "{") {
            let suffix = String(result[lastBrace...])
            if (suffix.contains("\"name\"") || suffix.contains("\"function\"") || suffix.contains("\"tool\""))
                && !suffix.contains("}}")
            {
                result = String(result[..<lastBrace]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return result
    }
}
