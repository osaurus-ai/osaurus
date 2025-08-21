//
//  ToolCallParser.swift
//  osaurus
//
//  Created by Terence on 8/21/25.
//

import Foundation

/// Parses assistant outputs to extract OpenAI-compatible tool calls.
/// Accepts minor formatting noise such as code fences or role prefixes.
struct ToolCallParser {
    private struct ToolCallsEnvelope: Codable { let tool_calls: [RawToolCall] }
    private struct RawToolCall: Codable {
        let id: String?
        let type: String?
        let function: RawToolFunction
    }
    private struct RawToolFunction: Codable {
        let name: String
        // Models should emit `arguments` as a JSON-escaped string; unknown keys are ignored
        let arguments: String?
    }

    /// Parse tool calls from a model output string.
    /// - Parameter text: Raw model output, possibly including code fences or prefixes
    /// - Returns: Array of `ToolCall` if present; otherwise nil
    static func parse(from text: String) -> [ToolCall]? {
        // Normalize common wrappers: code fences, role prefixes
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip leading role labels like "assistant:" or "Assistant:"
        if let range = s.range(of: "assistant:", options: [.caseInsensitive, .anchored]) {
            s.removeSubrange(range)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip code fences ```json ... ``` or ``` ... ```
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let fenceRange = s.range(of: "```", options: .backwards) {
                s.removeSubrange(fenceRange.lowerBound..<s.endIndex)
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func decodeEnvelope(from json: String) -> [ToolCall]? {
            guard let data = json.data(using: .utf8), let envelope = try? JSONDecoder().decode(ToolCallsEnvelope.self, from: data) else {
                return nil
            }
            let normalized: [ToolCall] = envelope.tool_calls.compactMap { raw in
                let id = raw.id ?? "call_\(UUID().uuidString.prefix(8))"
                let type = raw.type ?? "function"
                if let args = raw.function.arguments, !args.isEmpty {
                    let norm = normalizeArgumentsString(args)
                    return ToolCall(id: id, type: type, function: ToolCallFunction(name: raw.function.name, arguments: norm))
                } else {
                    return nil
                }
            }
            return normalized.isEmpty ? nil : normalized
        }

        // Strategy 1: Try decoding the whole string directly as the envelope
        if let calls = decodeEnvelope(from: s) ?? decodeWithJSONSerialization(from: s) {
            return calls
        }

        // Strategy 2: Extract the tool_calls array by bracket matching (ignoring quotes), then wrap
        if let arrayStr = extractJSONArrayString(named: "tool_calls", in: s) {
            let wrapped = "{\"tool_calls\": \(arrayStr)}"
            if let calls = decodeEnvelope(from: wrapped) ?? decodeWithJSONSerialization(from: wrapped) {
                return calls
            }
        }

        // Strategy 3: Fallback to naive outermost object extraction
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end {
            let jsonSub = String(s[start...end])
            if let calls = decodeEnvelope(from: jsonSub) ?? decodeWithJSONSerialization(from: jsonSub) {
                return calls
            }
        }
        // Strategy 4: Heuristic scan for a single function call
        if let call = parseHeuristically(from: s) {
            return [call]
        }
        return nil
    }

    /// Extracts a top-level JSON array substring for the given key by matching brackets,
    /// while correctly handling quoted strings and escapes.
    private static func extractJSONArrayString(named key: String, in s: String) -> String? {
        guard let keyRange = s.range(of: "\"\(key)\"", options: .caseInsensitive) else { return nil }
        let idx = keyRange.upperBound
        // Find the first '[' after the key
        guard let arrayStart = s[idx...].firstIndex(of: "[") else { return nil }
        var i = arrayStart
        var level = 0
        var inString = false
        var prev: Character = "\0"
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if c == "\"" && prev != "\\" {
                    inString = false
                }
            } else {
                if c == "\"" { inString = true }
                else if c == "[" { level += 1 }
                else if c == "]" {
                    level -= 1
                    if level == 0 {
                        return String(s[arrayStart...i])
                    }
                }
            }
            prev = c
            i = s.index(after: i)
        }
        return nil
    }

    /// Fallback JSON parsing using JSONSerialization to tolerate unknown structures.
    private static func decodeWithJSONSerialization(from json: String) -> [ToolCall]? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let callsAny = obj["tool_calls"] as? [Any] else { return nil }
        var result: [ToolCall] = []
        for item in callsAny {
            guard let dict = item as? [String: Any] else { continue }
            let id = (dict["id"] as? String) ?? "call_\(UUID().uuidString.prefix(8))"
            let type = (dict["type"] as? String) ?? "function"
            guard let fn = dict["function"] as? [String: Any], let name = fn["name"] as? String else { continue }
            if let args = fn["arguments"] as? String, !args.isEmpty {
                let norm = normalizeArgumentsString(args)
                result.append(ToolCall(id: id, type: type, function: ToolCallFunction(name: name, arguments: norm)))
            } else if let params = fn["parameters"], let paramsData = try? JSONSerialization.data(withJSONObject: params, options: []), let paramsStr = String(data: paramsData, encoding: .utf8) {
                result.append(ToolCall(id: id, type: type, function: ToolCallFunction(name: name, arguments: paramsStr)))
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Final fallback: heuristic string scan to extract one function tool call
    private static func parseHeuristically(from s: String) -> ToolCall? {
        guard let nameKeyRange = s.range(of: "\"name\"", options: .caseInsensitive) else { return nil }
        var i = s[nameKeyRange.upperBound...].startIndex
        // Move to first quote after colon
        if let colon = s[nameKeyRange.upperBound...].firstIndex(of: ":") {
            i = colon
        }
        guard let firstQuote = s[i...].firstIndex(of: "\"") else { return nil }
        var j = s.index(after: firstQuote)
        var name = ""
        while j < s.endIndex {
            let c = s[j]
            if c == "\"" { break }
            name.append(c)
            j = s.index(after: j)
        }
        if name.isEmpty { return nil }

        // Find arguments string (best-effort)
        var argumentsStr = "{}"
        if let argsKeyRange = s.range(of: "\"arguments\"", options: .caseInsensitive) {
            var k = argsKeyRange.upperBound
            if let colon2 = s[k...].firstIndex(of: ":") { k = colon2 }
            // Expect a starting quote for the string value
            if let startQuote = s[k...].firstIndex(of: "\"") {
                var m = s.index(after: startQuote)
                var buf: String = ""
                var prev: Character = "\0"
                while m < s.endIndex {
                    let c = s[m]
                    if c == "\"" && prev != "\\" { break }
                    buf.append(c)
                    prev = c
                    m = s.index(after: m)
                }
                if !buf.isEmpty { argumentsStr = buf }
            }
        }
        let norm = normalizeArgumentsString(argumentsStr)
        return ToolCall(id: "call_\(UUID().uuidString.prefix(8))", type: "function", function: ToolCallFunction(name: name, arguments: norm))
    }

    /// Replace escaped quotes with literal quotes to normalize JSON-like argument strings
    private static func normalizeArgumentsString(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.contains("\\\"") {
            out = out.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return out
    }
}


