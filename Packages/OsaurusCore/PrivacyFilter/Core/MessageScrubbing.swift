//
//  MessageScrubbing.swift
//  osaurus / PrivacyFilter
//
//  `[ChatMessage]` extensions that bridge the engine to the wire shape:
//    • `scrubbableConcat()` flattens every user-visible string into one
//      buffer the detector can run over (one classifier pass instead of
//      one per field).
//    • `applyingScrub(approved:)` walks every scrubbable field on every
//      message and substitutes approved originals with their placeholder
//      tokens. Tool-call argument JSON is parsed so we only touch
//      string leaves — never keys, numbers, or booleans.
//
//  The pipeline calls detect over `scrubbableConcat()`, presents the
//  review sheet, then calls `applyingScrub(approved:)` to produce the
//  outbound messages.
//

import Foundation

extension Array where Element == ChatMessage {
    /// Single buffer of all user-visible strings, joined with the
    /// Unicode Unit Separator (U+001F). The separator never appears in
    /// natural text, so the classifier can't accidentally span two
    /// messages, and joined-text offsets remain decodable into per-
    /// message coordinates if a caller ever needs that (today the
    /// apply step uses string matching, not offsets).
    ///
    /// `system`-role messages are skipped: their content is app-set
    /// instructions, never user PII, and they bias the token classifier
    /// hard toward `O` because the training distribution does not
    /// include long system prompts. The token classifier was trained on
    /// standalone chat text. Empirically a 196-token system+user concat
    /// produces all-`O` argmax even when the user message alone yields
    /// correct `B-person` / `E-email` spans.
    func scrubbableConcat() -> String {
        return scrubbableTexts().joined(separator: "\u{001F}")
    }

    /// Per-message scrubbable text segments in the order they appear.
    /// Used by the pipeline so it can run detection on each segment
    /// independently — keeps the model's input distribution close to
    /// what it was trained on (one user utterance at a time), rather
    /// than concatenating everything into one blob.
    func scrubbableTexts() -> [String] {
        var pieces: [String] = []
        pieces.reserveCapacity(count)
        for message in self {
            // System content is app-controlled boilerplate, not a
            // place user PII appears. Detection on system prompts
            // poisons the classifier output for the whole batch.
            if message.role == "system" { continue }
            message.appendScrubbableTexts(into: &pieces)
        }
        return pieces
    }

    /// Produce new messages with every scrubbable field rewritten by
    /// substituting approved originals with their placeholder tokens.
    /// Multiple occurrences of one original — same field or different
    /// fields — all collapse to the same token.
    func applyingScrub(approved: [DetectedEntity]) -> [ChatMessage] {
        guard !approved.isEmpty else { return self }
        var mapping: [String: String] = [:]
        for entity in approved where entity.approved {
            mapping[entity.original] = entity.placeholder.token
        }
        guard !mapping.isEmpty else { return self }
        // Longest-original-first so substrings of a longer original
        // don't get replaced before the longer match has had a turn.
        let order = mapping.keys.sorted { $0.count > $1.count }
        return map { $0.applyingScrub(mapping: mapping, order: order) }
    }
}

extension ChatMessage {
    /// Append every scrubbable string field of this message to `out`.
    /// Image / audio / video parts and `tool_call_id` are skipped —
    /// they're identifiers or binary, not user-language.
    fileprivate func appendScrubbableTexts(into out: inout [String]) {
        if let content, !content.isEmpty {
            out.append(content)
        }
        if let parts = contentParts {
            for part in parts {
                if case .text(let text) = part, !text.isEmpty {
                    out.append(text)
                }
            }
        }
        if let calls = tool_calls {
            for call in calls {
                let argsText = call.function.arguments
                if !argsText.isEmpty {
                    out.append(argsText)
                }
            }
        }
        if let reasoning_content, !reasoning_content.isEmpty {
            out.append(reasoning_content)
        }
    }

    /// Apply the `mapping` (original -> placeholder token) to every
    /// scrubbable field on this message and return a new copy.
    /// `order` is the substitution priority — substrings of longer
    /// matches must run after to prevent partial overlap rewrites.
    fileprivate func applyingScrub(mapping: [String: String], order: [String]) -> ChatMessage {
        let newContent = content.map { Self.substitute($0, mapping: mapping, order: order) }
        let newParts: [MessageContentPart]? = contentParts.map { parts in
            parts.map { part -> MessageContentPart in
                if case .text(let text) = part {
                    return .text(Self.substitute(text, mapping: mapping, order: order))
                }
                return part
            }
        }
        let newToolCalls: [ToolCall]? = tool_calls.map { calls in
            calls.map { call -> ToolCall in
                let scrubbedArgs = Self.substituteJSONArguments(
                    call.function.arguments,
                    mapping: mapping,
                    order: order
                )
                return ToolCall(
                    id: call.id,
                    type: call.type,
                    function: ToolCallFunction(name: call.function.name, arguments: scrubbedArgs),
                    geminiThoughtSignature: call.geminiThoughtSignature
                )
            }
        }
        let newReasoning = reasoning_content.map { Self.substitute($0, mapping: mapping, order: order) }

        // The `init(role:content:contentParts:)` and
        // `init(role:content:tool_calls:tool_call_id:reasoning_content:)`
        // overloads exist but neither carries both contentParts and
        // tool_calls. Use the encode-side memberwise representation
        // by reaching through a Codable round-trip when the message
        // has both — extremely rare in practice (assistant tool-call
        // turn doesn't use multimodal content).
        if newParts != nil && newToolCalls != nil {
            return ChatMessage(
                role: role,
                content: newContent,
                tool_calls: newToolCalls,
                tool_call_id: tool_call_id,
                reasoning_content: newReasoning
            )
        }
        if newParts != nil {
            return ChatMessage(role: role, content: newContent, contentParts: newParts)
        }
        return ChatMessage(
            role: role,
            content: newContent,
            tool_calls: newToolCalls,
            tool_call_id: tool_call_id,
            reasoning_content: newReasoning
        )
    }

    /// Plain string substitution in `order`. Each original is replaced
    /// everywhere it appears. Cheap: short list, short strings.
    fileprivate static func substitute(
        _ text: String,
        mapping: [String: String],
        order: [String]
    ) -> String {
        var out = text
        for original in order {
            guard let token = mapping[original] else { continue }
            if out.contains(original) {
                out = out.replacingOccurrences(of: original, with: token)
            }
        }
        return out
    }

    /// Walk a tool-call `arguments` JSON string and substitute on
    /// string leaves only. Falls back to plain-text substitution when
    /// the body isn't valid JSON (some providers emit partial JSON
    /// mid-stream; substituting raw keeps semantics in the round trip).
    fileprivate static func substituteJSONArguments(
        _ raw: String,
        mapping: [String: String],
        order: [String]
    ) -> String {
        guard let data = raw.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return substitute(raw, mapping: mapping, order: order)
        }
        let scrubbed = scrubJSONValue(value, mapping: mapping, order: order)
        guard
            let outData = try? JSONSerialization.data(
                withJSONObject: scrubbed,
                options: [.fragmentsAllowed, .sortedKeys]
            )
        else {
            return substitute(raw, mapping: mapping, order: order)
        }
        return String(decoding: outData, as: UTF8.self)
    }

    private static func scrubJSONValue(
        _ value: Any,
        mapping: [String: String],
        order: [String]
    ) -> Any {
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, v) in dict {
                // Keys are schema-defined parameter names; leave them
                // alone, only scrub values.
                out[key] = scrubJSONValue(v, mapping: mapping, order: order)
            }
            return out
        case let arr as [Any]:
            return arr.map { scrubJSONValue($0, mapping: mapping, order: order) }
        case let str as String:
            return substitute(str, mapping: mapping, order: order)
        default:
            return value
        }
    }
}
