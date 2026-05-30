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

    /// Scrubbable segments contributed by the latest user turn only —
    /// i.e. the slice starting at the most recent `role == "user"`
    /// message and extending to the end of the array. Detection only
    /// needs to scan new originals, because anything already scrubbed
    /// on a prior turn is captured by the per-session `RedactionMap`
    /// and re-applied via `applyingScrub(approved:)`.
    ///
    /// Returns the whole-history segments as a fallback when there is
    /// no user message in scope (e.g. a system-only kickoff or an
    /// assistant-led plugin agent transcript) so we don't accidentally
    /// skip detection on a turn that actually does carry PII.
    func latestUserTurnSegments() -> [String] {
        guard let lastUserIdx = lastIndex(where: { $0.role == "user" }) else {
            return scrubbableTexts()
        }
        let slice = self[lastUserIdx...]
        var pieces: [String] = []
        pieces.reserveCapacity(slice.count)
        for message in slice {
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
    /// Hard cap on the per-segment character count handed to the
    /// classifier. Segments above this size are split into chunks of
    /// `maxSegmentChars` characters so a single multi-megabyte paste
    /// can't:
    ///   * blow MLX VRAM on the classifier forward pass, or
    ///   * starve the rest of the pipeline by stretching one segment's
    ///     detection into multi-minute latency.
    ///
    /// `MessageScrubbing` is intentionally NOT in charge of warning
    /// the user — the chat layer surfaces a "scan truncated" hint
    /// when the count of emitted segments exceeds the message count
    /// (i.e. at least one was chunked).
    static let maxSegmentChars: Int = 8_000

    /// Append every scrubbable string field of this message to `out`.
    /// Image / audio / video parts and `tool_call_id` are skipped —
    /// they're identifiers or binary, not user-language.
    ///
    /// **Multimodal limitation:** non-text content parts (image URLs,
    /// inlined base64 image data, audio attachments) are NOT scanned.
    /// The Privacy Filter is text-only by design; OCR'd PII in a
    /// pasted screenshot bypasses the filter. This is documented in
    /// `docs/PRIVACY_FILTER.md#limitations` and in the master toggle
    /// description.
    fileprivate func appendScrubbableTexts(into out: inout [String]) {
        if let content, !content.isEmpty {
            ChatMessage.appendCapped(content, into: &out)
        }
        if let parts = contentParts {
            for part in parts {
                if case .text(let text) = part, !text.isEmpty {
                    ChatMessage.appendCapped(text, into: &out)
                }
            }
        }
        if let calls = tool_calls {
            for call in calls {
                let argsText = call.function.arguments
                if !argsText.isEmpty {
                    ChatMessage.appendCapped(argsText, into: &out)
                }
            }
        }
        if let reasoning_content, !reasoning_content.isEmpty {
            ChatMessage.appendCapped(reasoning_content, into: &out)
        }
    }

    /// Split `text` at `maxSegmentChars` boundaries and append each
    /// chunk to `out`. Sub-cap inputs append as a single element so
    /// the common case stays zero-overhead.
    fileprivate static func appendCapped(_ text: String, into out: inout [String]) {
        if text.count <= ChatMessage.maxSegmentChars {
            out.append(text)
            return
        }
        var idx = text.startIndex
        while idx < text.endIndex {
            let end =
                text.index(idx, offsetBy: ChatMessage.maxSegmentChars, limitedBy: text.endIndex)
                ?? text.endIndex
            out.append(String(text[idx ..< end]))
            idx = end
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
                reasoning_content: newReasoning,
                reasoning_item_id: reasoning_item_id,
                reasoning_encrypted: reasoning_encrypted
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
            reasoning_content: newReasoning,
            reasoning_item_id: reasoning_item_id,
            reasoning_encrypted: reasoning_encrypted
        )
    }

    /// Single-pass substitution. Builds one alternation regex from
    /// the originals (longest-first so substrings of a longer match
    /// can't win at the same position) and walks the text once,
    /// stitching non-match runs together with the placeholder tokens.
    ///
    /// Why this matters: the old implementation called
    /// `replacingOccurrences` once per original, each pass copying
    /// the entire buffer. With N originals and text of length M
    /// that's `O(N × M)` allocations and string copies; the regex
    /// pass below is effectively `O(M + matches)` driven by the
    /// NSRegularExpression NFA, which is roughly Aho-Corasick under
    /// the hood.
    ///
    /// Falls back to a single linear scan if the regex fails to
    /// compile (shouldn't happen — all originals are run through
    /// `NSRegularExpression.escapedPattern` first — but the fallback
    /// keeps semantics identical to the previous implementation).
    fileprivate static func substitute(
        _ text: String,
        mapping: [String: String],
        order: [String]
    ) -> String {
        if text.isEmpty || order.isEmpty { return text }

        var nonEmpty: [String] = []
        nonEmpty.reserveCapacity(order.count)
        for original in order where !original.isEmpty && mapping[original] != nil {
            nonEmpty.append(original)
        }
        if nonEmpty.isEmpty { return text }

        let pattern =
            nonEmpty
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")

        guard
            let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators]
            )
        else {
            return slowSubstitute(text, mapping: mapping, order: nonEmpty)
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: fullRange)
        if matches.isEmpty { return text }

        var out = ""
        out.reserveCapacity(nsText.length)
        var cursor = 0
        for match in matches {
            let r = match.range
            guard r.location != NSNotFound, r.location >= cursor else { continue }
            if r.location > cursor {
                out.append(nsText.substring(with: NSRange(location: cursor, length: r.location - cursor)))
            }
            let original = nsText.substring(with: r)
            if let token = mapping[original] {
                out.append(token)
            } else {
                out.append(original)
            }
            cursor = r.location + r.length
        }
        if cursor < nsText.length {
            out.append(nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor)))
        }
        return out
    }

    /// Defensive fallback used only when the alternation regex fails
    /// to compile. Behaviourally identical to the pre-P3 multi-pass
    /// loop.
    private static func slowSubstitute(
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
