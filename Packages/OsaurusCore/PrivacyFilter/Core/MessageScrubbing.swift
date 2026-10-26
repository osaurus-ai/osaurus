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
                    // Detection must see the DECODED string leaves,
                    // not the raw serialized JSON: substitution
                    // (`substituteJSONArguments`) parses the JSON and
                    // replaces decoded leaves, so an original captured
                    // from the raw text spanning an escape sequence
                    // (`\n`, `\"`, `\\`) would never match at scrub
                    // time — the substitution silently no-ops and the
                    // post-scrub per-original assertion blocks the
                    // send. Scanning the same decoded view keeps
                    // detect and scrub symmetric. Falls back to the
                    // raw string on parse failure, matching the
                    // substitution fallback.
                    for leaf in ChatMessage.jsonStringLeaves(argsText) {
                        ChatMessage.appendCapped(leaf, into: &out)
                    }
                }
            }
        }
        if let reasoning_content, !reasoning_content.isEmpty {
            ChatMessage.appendCapped(reasoning_content, into: &out)
        }
        for text in ResponsesItemPayload.scrubbableTexts((responses_output_items ?? []) + (anthropic_thinking_blocks ?? [])) {
            ChatMessage.appendCapped(text, into: &out)
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

        let newItems = responses_output_items.map { items in
            ResponsesItemPayload.applyingScrub(items, mapping: mapping, order: order)
        }
        return ChatMessage(
            scrubbing: self, content: newContent, parts: newParts,
            calls: newToolCalls, reasoning: newReasoning, providerItems: newItems,
            mappingForAnthropic: mapping, orderForAnthropic: order
        )
    }

    /// Preserve every in-process field, including media/audio and opaque
    /// provider identity, while replacing only the scanned payload fields.
    private init(
        scrubbing source: ChatMessage, content: String?, parts: [MessageContentPart]?,
        calls: [ToolCall]?, reasoning: String?, providerItems: [JSONValue]?,
        mappingForAnthropic: [String: String], orderForAnthropic: [String]
    ) {
        self.role = source.role
        self.content = content
        self.contentParts = parts
        self.localAudioSamples = source.localAudioSamples
        self.tool_calls = calls
        self.tool_call_id = source.tool_call_id
        self.reasoning_content = reasoning
        self.reasoning_item_id = source.reasoning_item_id
        self.reasoning_encrypted = source.reasoning_encrypted
        self.responses_output_items = providerItems
        self.anthropic_thinking_blocks = source.anthropic_thinking_blocks.map {
            ResponsesItemPayload.applyingScrub($0, mapping: mappingForAnthropic, order: orderForAnthropic)
        }
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

    /// Decoded string leaves of a tool-call `arguments` JSON body, in
    /// deterministic (sorted-key) order. Returns `[raw]` when the body
    /// isn't valid JSON so detection scans the same text the
    /// substitution fallback would rewrite. Keys are excluded — they
    /// are schema-defined parameter names and `substituteJSONArguments`
    /// never touches them, so detecting PII in a key could only
    /// produce an unsubstitutable original.
    fileprivate static func jsonStringLeaves(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return [raw]
        }
        var out: [String] = []
        collectStringLeaves(value, into: &out)
        return out
    }

    private static func collectStringLeaves(_ value: Any, into out: inout [String]) {
        switch value {
        case let dict as [String: Any]:
            // Sorted keys keep segment order deterministic across
            // calls (JSONSerialization dictionaries are unordered).
            for (_, leaf) in dict.sorted(by: { $0.key < $1.key }) {
                collectStringLeaves(leaf, into: &out)
            }
        case let arr as [Any]:
            for item in arr {
                collectStringLeaves(item, into: &out)
            }
        case let str as String:
            if !str.isEmpty { out.append(str) }
        default:
            break
        }
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
        // A privacy map on another field must not rewrite unaffected argument
        // bytes and break the next turn's exact template/prefix match.
        if (value as? NSObject)?.isEqual(scrubbed) == true { return raw }
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


/// Payload traversal shared by privacy detection and substitution. Provider
/// identity/discriminators/encrypted blobs and binary media are not language.
/// Unknown payload fields are walked rather than silently bypassing scanning.
enum ResponsesItemPayload {
    private static let rootIdentity: Set<String> = [
        "id", "type", "role", "status", "phase", "call_id", "name", "encrypted_content", "signature",
    ]
    private static let mediaTypes: Set<String> = [
        "input_image", "image_url", "input_audio", "audio_input", "input_video", "video_url", "input_file",
    ]
    private static let mediaPayload: Set<String> = [
        "image_url", "audio_url", "video_url", "file_url", "url", "data", "file_data", "file_id", "format", "detail",
    ]

    static func scrubbableTexts(_ items: [JSONValue]) -> [String] {
        var strings: [String] = []
        for item in items {
            _ = transform(item, root: true, scanning: true) { text, arguments in
                strings += arguments ? ChatMessage.jsonStringLeaves(text) : [text]
                return text
            }
        }
        return strings.filter { !$0.isEmpty }
    }

    static func signedThinkingWouldChange(_ items: [JSONValue], mapping: [String: String], order: [String]) -> Bool {
        func containsChange(_ value: JSONValue) -> Bool {
            switch value {
            case .object(let fields):
                if fields["type"] == .string("redacted_thinking") { return false }
                if fields["type"] == .string("thinking"),
                    case .string(let signature) = fields["signature"], !signature.isEmpty {
                    let changed = transform(value, root: true, scanning: true) { text, arguments in
                        arguments
                            ? ChatMessage.substituteJSONArguments(text, mapping: mapping, order: order)
                            : ChatMessage.substitute(text, mapping: mapping, order: order)
                    }
                    if changed != value { return true }
                }
                return fields.values.contains(where: containsChange)
            case .array(let values): return values.contains(where: containsChange)
            default: return false
            }
        }
        return items.contains(where: containsChange)
    }

    static func applyingScrub(_ items: [JSONValue], mapping: [String: String], order: [String]) -> [JSONValue] {
        items.map { item in
            transform(item, root: true) { text, arguments in
                arguments
                    ? ChatMessage.substituteJSONArguments(text, mapping: mapping, order: order)
                    : ChatMessage.substitute(text, mapping: mapping, order: order)
            }
        }
    }

    private static func transform(
        _ value: JSONValue, root: Bool, scanning: Bool = false,
        payload: (String, Bool) -> String
    ) -> JSONValue {
        switch value {
        case .string(let text): return .string(payload(text, false))
        case .array(let values): return .array(values.map { transform($0, root: root, scanning: scanning, payload: payload) })
        case .object(let fields):
            let type: String? = { if case .string(let value) = fields["type"] { return value }; return nil }()
            if root && type == "redacted_thinking" { return value }
            if root && type == "thinking", !scanning,
                case .string(let signature) = fields["signature"], !signature.isEmpty { return value }
            let media = type.map { mediaTypes.contains($0) } ?? false
            var updated = fields
            for key in fields.keys.sorted() {
                guard let value = fields[key] else { continue }
                if root && rootIdentity.contains(key) { continue }
                if type != nil && key == "type" { continue }
                if media && mediaPayload.contains(key) { continue }
                if root && ((type == "function_call" && key == "arguments")
                    || (type == "function_call_output" && key == "output")), case .string(let text) = value {
                    updated[key] = .string(payload(text, true))
                } else {
                    let childIsItem = root && (key == "item" || key == "response"
                        || (key == "output" && fields["object"] == .string("response")))
                    updated[key] = transform(value, root: childIsItem, scanning: scanning, payload: payload)
                }
            }
            return .object(updated)
        default: return value
        }
    }
}
