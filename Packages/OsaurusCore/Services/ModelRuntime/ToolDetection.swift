//
//  ToolDetection.swift
//  osaurus
//
//  Best-effort detection of inline tool-call JSON in generated text.
//

import Foundation

enum ToolDetection {
    // Cached regex instances — compiled once at first use, reused on every call.
    // NSRegularExpression is thread-safe for matching after initialisation.
    private static let functionRegex = try! NSRegularExpression(
        pattern: "(?s)<function=([^>]+)>(.*?)</function>")
    private static let parameterRegex = try! NSRegularExpression(
        pattern: "(?s)<parameter=([^>]+)>(.*?)</parameter>")
    private static let truncatedFunctionRegex = try! NSRegularExpression(
        pattern: #""name"\s*:\s*"([^"]+)""#)
    /// Best-effort detector for inline tool-call JSON in generated text. Returns (toolName, argsJSON).
    ///
    /// Supports multiple formats:
    /// - Plain JSON: `{"name": "fn", "arguments": {...}}`
    /// - Qwen XML-wrapped: `<tool_call>{"name": "fn", "arguments": {...}}</tool_call>`
    /// - Command-R XML: `<function=NAME><parameter=KEY>VALUE</parameter></function>`
    static func detectInlineToolCall(
        in text: String,
        tools: [Tool]
    ) -> (String, String)? {
        guard !tools.isEmpty, !text.isEmpty else { return nil }
        let window = String(text.suffix(5000))
        let toolNames = Set(tools.map { $0.function.name })

        // Fast path: Qwen-style <tool_call>...</tool_call> XML wrapper.
        // The Qwen2.5/3/3.5 Jinja2 chat template always wraps tool calls in
        // these tags. Search backwards for the *last* open tag so that prior
        // tool calls in the conversation history don't shadow the current one,
        // then search forward for the matching close tag.
        if let openRange = window.range(of: "<tool_call>", options: .backwards),
           let closeRange = window.range(of: "</tool_call>", range: openRange.upperBound ..< window.endIndex),
           openRange.upperBound <= closeRange.lowerBound
        {
            // Extract the content between the tags
            let inner = String(window[openRange.upperBound ..< closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let (name, argsJSON) = extractToolCall(fromJSON: inner) {
                return (name, argsJSON)
            }
        }

        // Support native XML function block syntax independent of `<tool_call>` bounding logic
        if let (name, argsJSON) = extractXMLAttributes(fromXML: window) {
            return (name, argsJSON)
        }

        // General path: search for a JSON object containing a known tool name field.
        // Prevent generic JSON matching if an XML <tool_call> is currently being generated.
        // Use an efficient substring-count helper instead of components(separatedBy:) to avoid
        // allocating two full arrays on every token in the hot path.
        if substringCount(of: "<tool_call>", in: window) > substringCount(of: "</tool_call>", in: window) {
            return nil
        }

        for name in toolNames {
            if let range = window.range(of: #""name"\s*:\s*"\#(name)""#, options: [.regularExpression])
                ?? window.range(of: #""tool_name"\s*:\s*"\#(name)""#, options: [.regularExpression])
            {
                if let jsonRange = findEnclosingJSONObject(around: range.lowerBound, in: window) {
                    let candidate = String(window[jsonRange])
                    if let (detectedName, argsJSON) = extractToolCall(fromJSON: candidate) {
                        if toolNames.contains(detectedName) {
                            return (detectedName, argsJSON)
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Locate the smallest JSON object enclosing a character index.
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

    /// Return index just after the end of the JSON object that starts at `start`.
    private static func matchJSONObjectEnd(
        from start: String.Index,
        in text: String
    ) -> String.Index? {
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
                    if depth == 0 {
                        return text.index(after: i)
                    }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Attempt to parse a tool-call from JSON text. Supports {"function":{"name":...,"arguments":...}}
    /// and {"tool_name":..., "arguments": ...}. Returns (toolName, argsJSON) if found.
    private static func extractToolCall(fromJSON jsonText: String) -> (String, String)? {
        guard let data = jsonText.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let function = obj["function"] as? [String: Any], let name = function["name"] as? String {
            if let argsString = function["arguments"] as? String {
                return (name, argsString)
            }
            if let argsObj = function["arguments"],
                let argsData = try? JSONSerialization.data(withJSONObject: argsObj),
                let argsJSON = String(data: argsData, encoding: .utf8)
            {
                return (name, argsJSON)
            }
        }
        if let name = obj["tool_name"] as? String {
            if let argsString = obj["arguments"] as? String {
                return (name, argsString)
            }
            if let argsObj = obj["arguments"],
                let argsData = try? JSONSerialization.data(withJSONObject: argsObj),
                let argsJSON = String(data: argsData, encoding: .utf8)
            {
                return (name, argsJSON)
            }
        }
        if let name = obj["name"] as? String {
            if let argsString = obj["arguments"] as? String { return (name, argsString) }
            if let argsObj = obj["arguments"],
                let argsData = try? JSONSerialization.data(withJSONObject: argsObj),
                let argsJSON = String(data: argsData, encoding: .utf8)
            {
                return (name, argsJSON)
            }
        }
        return nil
    }

    /// Fallback for alternative parameter-based XML formats generated by some models (like Command-R).
    /// Extracts `<function=NAME><parameter=KEY>[JSON_LITERAL]</parameter></function>` syntax.
    private static func extractXMLAttributes(fromXML xmlText: String) -> (String, String)? {
        let nsText = xmlText as NSString
        let fullRange = NSRange(xmlText.startIndex..., in: xmlText)
        guard let match = functionRegex.firstMatch(in: xmlText, range: fullRange) else { return nil }

        guard let nameRange = Range(match.range(at: 1), in: xmlText),
              let bodyRange = Range(match.range(at: 2), in: xmlText) else { return nil }
        let _ = nsText  // keep NSString alive across bridging

        let name = String(xmlText[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = String(xmlText[bodyRange])

        let bodyRange2 = NSRange(body.startIndex..., in: body)
        let paramMatches = parameterRegex.matches(in: body, range: bodyRange2)

        var argsDictionary: [String: Any] = [:]
        for pm in paramMatches {
            guard let keyRange = Range(pm.range(at: 1), in: body),
                  let valRange = Range(pm.range(at: 2), in: body) else { continue }

            let keyStr = String(body[keyRange])
            let valStr = String(body[valRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            if let data = valStr.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
                argsDictionary[keyStr] = parsed
            } else {
                argsDictionary[keyStr] = valStr
            }
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: argsDictionary),
              let argsJSON = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        return (name, argsJSON)
    }

    /// Extract a tool name from a partial/truncated `<tool_call>` JSON block.
    /// Used when generation ends mid-block (e.g. max-tokens hit or crash).
    /// Looks for `"name": "toolname"` inside whatever was buffered.
    static func extractToolNameFromPartialQwenBlock(_ text: String) -> String? {
        let fullRange = NSRange(text.startIndex..., in: text)
        guard let match = truncatedFunctionRegex.firstMatch(in: text, range: fullRange),
              let nameRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[nameRange])
    }

    /// Count non-overlapping occurrences of `substring` in `text` without allocating an array.
    private static func substringCount(of substring: String, in text: String) -> Int {
        var count = 0
        var searchRange = text.startIndex ..< text.endIndex
        while let range = text.range(of: substring, range: searchRange) {
            count += 1
            searchRange = range.upperBound ..< text.endIndex
        }
        return count
    }
}
