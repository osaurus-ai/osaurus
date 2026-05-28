//
//  RemoteToolDetection.swift
//  osaurus
//
//  Best-effort detection of inline tool-call JSON in generated text for the
//  remote (non-MLX) provider path.  The MLX path delegates to the upstream
//  ToolCallProcessor from vmlx-swift instead.
//

import Foundation

/// Best-effort inline tool-call detector for remote/proxy provider responses.
///
/// Remote API providers (OpenAI-compatible, Gemini, Anthropic, etc.) sometimes
/// stream tool calls inline in the text content rather than in the structured
/// `tool_calls` field.  This helper parses those out as a fallback.
///
/// The MLX local-inference path does NOT use this — it delegates entirely to
/// `ToolCallProcessor` from `MLXLMCommon` (vmlx-swift).
enum RemoteToolDetection {
    /// Best-effort detector for inline tool-call JSON in generated text. Returns (toolName, argsJSON).
    ///
    /// Supports:
    /// - Plain JSON: `{"name": "fn", "arguments": {...}}`
    /// - Qwen XML-wrapped: `<tool_call>{"name": "fn", "arguments": {...}}</tool_call>`
    static func detectInlineToolCall(
        in text: String,
        tools: [Tool]
    ) -> (String, String)? {
        guard !tools.isEmpty, !text.isEmpty else { return nil }
        let window = String(text.suffix(5000))
        let toolNames = Set(tools.map { $0.function.name })

        // Fast path: Qwen-style <tool_call>...</tool_call> XML wrapper.
        if let openRange = window.range(of: "<tool_call>", options: .backwards),
            let closeRange = window.range(of: "</tool_call>", range: openRange.upperBound ..< window.endIndex),
            openRange.upperBound <= closeRange.lowerBound
        {
            let inner = String(window[openRange.upperBound ..< closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let (name, argsJSON) = extractToolCall(fromJSON: inner), toolNames.contains(name) {
                return (name, argsJSON)
            }
        }

        // General path: search for a JSON object containing a known tool name field.
        for name in toolNames {
            if let range = window.range(of: #""name"\s*:\s*"\#(name)""#, options: [.regularExpression])
                ?? window.range(of: #""tool_name"\s*:\s*"\#(name)""#, options: [.regularExpression])
                ?? window.range(of: #""tool"\s*:\s*"\#(name)""#, options: [.regularExpression])
            {
                if let jsonRange = findEnclosingJSONObject(around: range.lowerBound, in: window) {
                    let candidate = String(window[jsonRange])
                    if let (detectedName, argsJSON) = extractToolCall(fromJSON: candidate),
                        toolNames.contains(detectedName)
                    {
                        return (detectedName, argsJSON)
                    }
                }
            }
        }
        return nil
    }

    private static func findEnclosingJSONObject(
        around index: String.Index,
        in text: String
    ) -> Range<String.Index>? {
        var startPositions: [String.Index] = []
        var i = index
        while i > text.startIndex {
            i = text.index(before: i)
            if text[i] == "{" { startPositions.append(i) }
            if startPositions.count > 4096 { break }
        }
        for start in startPositions {
            if let end = matchJSONObjectEnd(from: start, in: text) {
                if start <= index && index < end { return start ..< end }
            }
        }
        return nil
    }

    private static func matchJSONObjectEnd(from start: String.Index, in text: String) -> String.Index? {
        var depth = 0
        var inString = false
        var isEscaped = false
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if ch == "\\" {
                    isEscaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return text.index(after: i) }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func extractToolCall(fromJSON jsonText: String) -> (String, String)? {
        guard let data = jsonText.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Sorted keys: extracted args become next-turn
        // `tool_calls[].function.arguments`. See `JSONDeterminism.swift`.
        if let function = obj["function"] as? [String: Any], let name = function["name"] as? String {
            if let argsString = function["arguments"] as? String { return (name, argsString) }
            if let argsObj = function["arguments"],
                let argsData = try? JSONSerialization.data(withJSONObject: argsObj, options: .osaurusCanonical),
                let argsJSON = String(data: argsData, encoding: .utf8)
            {
                return (name, argsJSON)
            }
        }
        if let name = obj["tool_name"] as? String {
            if let argsString = obj["arguments"] as? String { return (name, argsString) }
            if let argsObj = obj["arguments"],
                let argsData = try? JSONSerialization.data(withJSONObject: argsObj, options: .osaurusCanonical),
                let argsJSON = String(data: argsData, encoding: .utf8)
            {
                return (name, argsJSON)
            }
        }
        if let name = obj["tool"] as? String {
            // Tool result envelopes also carry a `"tool"` field. They are
            // not invocations and must not be re-executed as calls.
            guard obj["ok"] == nil, obj["result"] == nil else { return nil }
            if let argsString = obj["arguments"] as? String { return (name, argsString) }
            if let argsObj = obj["arguments"] ?? obj["parameters"],
                let argsData = try? JSONSerialization.data(withJSONObject: argsObj, options: .osaurusCanonical),
                let argsJSON = String(data: argsData, encoding: .utf8)
            {
                return (name, argsJSON)
            }
            let reserved = Set(["tool", "tool_name", "name", "function", "arguments", "parameters", "type", "id"])
            let topLevelArgs = obj.filter { !reserved.contains($0.key) }
            if let argsData = try? JSONSerialization.data(withJSONObject: topLevelArgs, options: .osaurusCanonical),
                let argsJSON = String(data: argsData, encoding: .utf8)
            {
                return (name, argsJSON)
            }
        }
        if let name = obj["name"] as? String {
            if let argsString = obj["arguments"] as? String { return (name, argsString) }
            if let argsObj = obj["arguments"],
                let argsData = try? JSONSerialization.data(withJSONObject: argsObj, options: .osaurusCanonical),
                let argsJSON = String(data: argsData, encoding: .utf8)
            {
                return (name, argsJSON)
            }
        }
        return nil
    }
}
