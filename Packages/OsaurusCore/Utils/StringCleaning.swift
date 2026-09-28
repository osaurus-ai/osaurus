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
        // e.g., {"name": "file_read", "result": {
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

    /// Strips leaked agent-action JSON blocks that some models emit as plain
    /// text instead of a structured tool call — e.g. a ReAct
    /// `{"action": "share_artifact", "action_input": {...}}` block or an
    /// OpenAI-style `{"name": "...", "arguments": {...}}`. Only a balanced
    /// `{...}` span that actually parses as JSON and carries tool-call-shaped
    /// keys is removed, so ordinary JSON the user asked to see is left intact.
    /// Display-only: the raw `content` is untouched for round-tripping.
    public static func stripLeakedActionJSON(_ content: String) -> String {
        // Consume the complete XML envelope before stripping its JSON body.
        // Otherwise a successfully recovered call leaves empty protocol tags
        // visible, and a no-argument call without an arguments key leaks whole.
        var content = content
        var cursor = content.startIndex
        while let open = content.range(of: "<tool_call>", range: cursor ..< content.endIndex),
            let close = content.range(of: "</tool_call>", range: open.upperBound ..< content.endIndex)
        {
            let body = String(content[open.upperBound ..< close.lowerBound])
            if isLeakedToolCallJSON(body, allowMissingArguments: true) {
                let offset = content.distance(from: content.startIndex, to: open.lowerBound)
                content.removeSubrange(open.lowerBound ..< close.upperBound)
                cursor = content.index(content.startIndex, offsetBy: offset)
            } else {
                cursor = close.upperBound
            }
        }
        // Cheap guard: only do the work when a tool-call-shaped key is present.
        guard content.contains("\"action\"") || content.contains("\"arguments\"") else {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let chars = Array(content)
        // `isLeakedToolCallJSON` needs a top-level `action` or `name` key.
        // A candidate block can only carry one if a key token (or a JSON
        // `\u` escape that could spell one) starts strictly inside it, so
        // record where those tokens start and skip the brace-match + JSON
        // parse for every `{` that cannot enclose one. Without this, long
        // code/JSON answers cost one parse per brace on the main thread
        // (APPLE-MACOS-1FE / 2PF).
        let keyStarts = leakKeyTokenStarts(in: chars)
        let lastKeyStart = keyStarts.last ?? -1
        var braceMatches: [Int: Int] = [:]

        var output: [Character] = []
        output.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            // No key token starts after `i`: nothing ahead can be a leaked
            // call. Append the remainder verbatim.
            if i >= lastKeyStart {
                output.append(contentsOf: chars[i...])
                break
            }
            if chars[i] == "{",
                let end = matchingBraceIndex(chars, start: i, cache: &braceMatches),
                containsKeyStart(keyStarts, after: i, before: end),
                isLeakedToolCallJSON(String(chars[i ... end]))
            {
                i = end + 1
                continue
            }
            output.append(chars[i])
            i += 1
        }
        return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tokens whose presence is necessary for a `{...}` block to satisfy
    /// `isLeakedToolCallJSON`: the two key literals, plus `\u` because a JSON
    /// unicode escape inside a key could spell either of them.
    private static let leakKeyTokens: [[Character]] = [
        Array("\"action\""), Array("\"name\""), Array("\\u"),
    ]

    /// Sorted start indices (in `chars`) of every `leakKeyTokens` occurrence.
    private static func leakKeyTokenStarts(in chars: [Character]) -> [Int] {
        var starts: [Int] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" || c == "\\" {
                for token in leakKeyTokens where token[0] == c {
                    let end = i + token.count
                    if end <= chars.count, chars[i ..< end].elementsEqual(token) {
                        starts.append(i)
                        break
                    }
                }
            }
            i += 1
        }
        return starts
    }

    /// Whether any key token starts in the open interval `(open, close)`.
    /// `starts` is sorted; binary search for the first entry > `open`.
    private static func containsKeyStart(_ starts: [Int], after open: Int, before close: Int) -> Bool {
        var lo = 0
        var hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= open { lo = mid + 1 } else { hi = mid }
        }
        return lo < starts.count && starts[lo] < close
    }

    /// Index of the `}` that closes the `{` at `start`, respecting string
    /// literals so braces inside JSON string values don't miscount. Returns
    /// nil if the block never closes.
    ///
    /// `cache` maps `{` index → closing index (`-1` = never closes). One scan
    /// resolves not just `start` but every `{` it passes outside a string
    /// literal: a scan starting at such a `{` sees the same characters with
    /// the same string state and a depth offset by a constant, so it closes
    /// exactly where this scan's stack pops it. Braces met inside a string
    /// are not cached — their own scan would start with inverted string
    /// state. This keeps unbalanced code (a stray `'{'` char literal) linear
    /// instead of re-scanning to the end from every brace.
    private static func matchingBraceIndex(_ chars: [Character], start: Int, cache: inout [Int: Int]) -> Int? {
        if let hit = cache[start] { return hit >= 0 ? hit : nil }
        var open: [Int] = []
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                open.append(i)
            } else if c == "}" {
                if let opened = open.popLast() { cache[opened] = i }
                if open.isEmpty { return i }
            }
            i += 1
        }
        for opened in open { cache[opened] = -1 }
        return nil
    }

    /// True when `block` parses as a JSON object that looks like a leaked tool
    /// call: a ReAct `action` + `action_input`, or a `name` + `arguments` /
    /// `parameters` pair.
    private static func isLeakedToolCallJSON(_ block: String, allowMissingArguments: Bool = false) -> Bool {
        guard let data = block.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        if allowMissingArguments, object["name"] is String, Set(object.keys) == ["name"] {
            return true
        }
        if object["action"] != nil, object["action_input"] != nil || object["action_inputs"] != nil {
            return true
        }
        if object["name"] != nil, object["arguments"] != nil || object["parameters"] != nil {
            return true
        }
        return false
    }

    /// Harmony channel labels that can leak into assistant text as a bare word.
    ///
    /// Gemma-4 and other Harmony-channel models put the channel NAME on the
    /// first line — `<|channel>thought\n…payload…<channel|>`. When the closing
    /// tag spelling isn't recognised, the delimiters are stripped but the label
    /// survives, and the user sees a message that is (or begins with) the bare
    /// word `thought`. Reasoning being OFF does not prevent it: the template
    /// still emits the pre-closed empty block that the model echoes.
    ///
    /// Deliberately a CLOSED set rather than "any bare identifier". The
    /// reasoning-pane guard (`ChatTurn.thinkingIsBlank`) can afford the broad
    /// test because nobody reasons in one bare token, but this runs on
    /// user-visible prose, where a one-word answer is legitimate. Restricting
    /// to real channel names means a genuine reply of "Analysis" is only ever
    /// dropped if it is the entire message AND matches a channel label.
    private static let harmonyChannelLabels: Set<String> = [
        "thought", "thinking", "analysis", "commentary", "final", "response",
    ]

    /// Whether `text` is exactly a Harmony channel label. Shared with
    /// `ChatTurn.thinkingIsBlank` so the reasoning pane and the visible answer
    /// agree on what counts as a label, and neither can drift.
    public static func isHarmonyChannelLabel(_ text: String) -> Bool {
        harmonyChannelLabels.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Removes a leaked Harmony channel label from assistant text meant for display.
    ///
    /// Two shapes, both observed: the label as the entire message, and the
    /// label alone on the first line followed by the real answer.
    public static func stripLeakedChannelLabel(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return content }

        // Cheap gate: the shortest label is 5 chars, so anything without one
        // of them in its opening span cannot match either shape.
        if trimmed.count > 24, !harmonyChannelLabels.contains(where: { trimmed.prefix(24).contains($0) }) {
            return content
        }

        // Case-SENSITIVE against lowercase labels. The channel name is emitted
        // lowercase (`thought`); prose that legitimately opens with a heading
        // word capitalises it ("Analysis\nThe data shows…"). Matching
        // case-insensitively ate that heading for every model, which is a
        // worse bug than the one being fixed.
        if harmonyChannelLabels.contains(trimmed) { return "" }

        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return content }
        let head = first.trimmingCharacters(in: .whitespaces)
        guard harmonyChannelLabels.contains(head) else { return content }
        lines.removeFirst()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips Gemini thought-signature markers from assistant text meant for display.
    ///
    /// We keep the raw content intact for Gemini round-tripping, but any UI-facing
    /// rendering should use this sanitized form instead.
    public static func stripGeminiDisplayMetadata(_ content: String) -> String {
        var result = content

        // Runs from `ChatTurn.visibleContent` on every render of every
        // assistant turn — per token while streaming. Almost no content
        // contains Gemini markers, so gate the marker loop and the (per-call
        // recompiled) leak regex on a cheap `contains` scan; only the
        // whitespace normalization below stays unconditional.
        let zws = "\u{200B}"
        let hasTS = result.contains("ts:")

        if hasTS {
            // Normal encoded form: ZWS + ts:SIG + ZWS
            let prefix = "\(zws)ts:"
            while let start = result.range(of: prefix) {
                let markerStart = start.lowerBound
                let signatureStart = start.upperBound
                guard let end = result[signatureStart...].range(of: zws) else { break }
                result.removeSubrange(markerStart ..< end.upperBound)
            }

            // Defensive cleanup for visible leakage if the zero-width markers are lost or
            // rendered unexpectedly in the UI.
            result = result.replacingOccurrences(
                of: #"(?:(?<=^)|(?<=\s))ts:[A-Za-z0-9+/_=-]{16,}(?=\s|$)"#,
                with: "",
                options: .regularExpression
            )
        }

        return
            result
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: " \n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Backwards-compatible alias while call sites migrate to the clearer Gemini-specific name.
    public static func stripDisplayOnlyMetadata(_ content: String) -> String {
        stripGeminiDisplayMetadata(content)
    }
}
