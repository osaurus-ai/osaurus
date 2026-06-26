import Foundation

/// Shared wire framing for OpenAI-compatible streaming providers.
///
/// Keep provider-specific product behavior (billing, account updates,
/// diagnostics) outside this type. This layer only turns bytes/lines into
/// provider event payloads and applies explicitly enabled compatibility
/// tolerances for OpenAI-compatible APIs.
struct OpenAICompatibleStreamFramer {
    struct Options: Sendable, Equatable {
        var allowsRawJSONBodyFallback: Bool = false
        var repairsSplitDataJSON: Bool = false

        static let strict = Options()
        static let routerCompatible = Options(
            allowsRawJSONBodyFallback: true,
            repairsSplitDataJSON: true
        )
    }

    /// Byte-level SSE line tokenizer. Splits a stream of bytes into logical SSE
    /// lines, treating LF, CR, and CRLF as line terminators. It intentionally
    /// does not split on Unicode separators such as U+2028, which can appear
    /// inside JSON string values.
    struct SSELineParser {
        private var lineBuffer = Data()
        private var carriageReturnLast = false
        private var completedLines: [Data] = []
        private var nextOutputIndex = 0

        mutating func append(_ data: Data) {
            for byte in data {
                switch byte {
                case 0x0D:
                    completedLines.append(lineBuffer)
                    lineBuffer = Data()
                    carriageReturnLast = true
                case 0x0A:
                    if carriageReturnLast {
                        carriageReturnLast = false
                    } else {
                        completedLines.append(lineBuffer)
                        lineBuffer = Data()
                    }
                default:
                    carriageReturnLast = false
                    lineBuffer.append(byte)
                }
            }
        }

        mutating func nextLine() -> Data? {
            guard nextOutputIndex < completedLines.count else {
                if nextOutputIndex > 0 {
                    completedLines.removeFirst(nextOutputIndex)
                    nextOutputIndex = 0
                }
                return nil
            }
            let line = completedLines[nextOutputIndex]
            nextOutputIndex += 1
            return line
        }

        mutating func flushPending() {
            if !lineBuffer.isEmpty {
                completedLines.append(lineBuffer)
                lineBuffer = Data()
            }
            carriageReturnLast = false
        }
    }

    @inline(__always)
    static func processLine(_ line: Data, into eventData: inout String) {
        processLine(line, options: .strict, into: &eventData)
    }

    @inline(__always)
    static func processLine(_ line: Data, options: Options, into eventData: inout String) {
        guard !line.isEmpty else { return }

        if options.allowsRawJSONBodyFallback,
            shouldAppendRawJSONContinuation(line, currentEventData: eventData)
        {
            eventData += "\n" + String(decoding: line, as: UTF8.self)
            return
        }

        if options.allowsRawJSONBodyFallback,
            shouldTreatLineAsRawJSON(line, currentEventData: eventData)
        {
            eventData = String(decoding: line, as: UTF8.self)
            return
        }

        processSSEFieldLine(line, into: &eventData)
    }

    static func repairedSplitDataJSONPayload(_ jsonData: Data, options: Options) -> Data? {
        guard options.repairsSplitDataJSON,
            let payload = String(data: jsonData, encoding: .utf8),
            payload.contains("\n")
        else { return nil }

        // Some OpenAI-compatible proxies incorrectly split one JSON SSE payload
        // across multiple data: lines. The spec joins those with LF, which is
        // correct for compliant streams but makes illegal literal newlines
        // inside JSON strings for the broken stream. Retry with only framing
        // CR/LF removed after strict JSON decode has failed.
        let normalized =
            payload
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard normalized != payload else { return nil }
        return normalized.data(using: .utf8)
    }

    @inline(__always)
    private static func processSSEFieldLine(_ line: Data, into eventData: inout String) {
        let lineStr = String(decoding: line, as: UTF8.self)
        if lineStr.first == ":" { return }

        let field: Substring
        var value: Substring
        if let colonIdx = lineStr.firstIndex(of: ":") {
            field = lineStr[..<colonIdx]
            value = lineStr[lineStr.index(after: colonIdx)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(lineStr)
            value = Substring("")
        }

        guard field == "data" else { return }
        if eventData.isEmpty {
            eventData = String(value)
        } else {
            eventData += "\n" + value
        }
    }

    @inline(__always)
    private static func shouldAppendRawJSONContinuation(
        _ line: Data,
        currentEventData: String
    ) -> Bool {
        guard let firstEventByte = currentEventData.utf8.first(where: { !isASCIIWhitespace($0) }),
            firstEventByte == UInt8(ascii: "{") || firstEventByte == UInt8(ascii: "[")
        else { return false }
        return !looksLikeSSEFieldLine(line)
    }

    @inline(__always)
    private static func shouldTreatLineAsRawJSON(_ line: Data, currentEventData: String) -> Bool {
        guard currentEventData.isEmpty,
            let first = line.first(where: { !isASCIIWhitespace($0) })
        else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    @inline(__always)
    private static func looksLikeSSEFieldLine(_ line: Data) -> Bool {
        let trimmed = line.drop(while: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") })
        if trimmed.first == UInt8(ascii: ":") { return true }
        return trimmed.starts(with: Array("data:".utf8))
            || trimmed.starts(with: Array("event:".utf8))
            || trimmed.starts(with: Array("id:".utf8))
            || trimmed.starts(with: Array("retry:".utf8))
    }

    @inline(__always)
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
            return true
        default:
            return false
        }
    }
}

struct OpenAICompatibleToolCallAccumulator {
    struct ValidatedToolCallJSON {
        let json: String
        let wasRepaired: Bool
    }

    static func resolveAccumulatedToolCall(
        from accumulated: [Int: RemoteProviderService.StreamingState.ToolSlot],
        finishMarker: String
    ) -> RemoteProviderService.AccumulatedToolCallResult {
        guard let (invocation, wasRepaired) = makeToolInvocation(from: accumulated) else {
            return .none
        }
        if wasRepaired {
            return .truncated(
                truncatedToolCallError(
                    from: accumulated,
                    toolName: invocation.toolName,
                    finishMarker: finishMarker
                )
            )
        }
        return .ready(invocation)
    }

    static func makeToolInvocation(
        from accumulated: [Int: RemoteProviderService.StreamingState.ToolSlot]
    ) -> (invocation: ServiceToolInvocation, wasRepaired: Bool)? {
        guard let first = accumulated.min(by: { $0.key < $1.key }),
            let name = first.value.name
        else { return nil }

        let validated = validateToolCallJSON(first.value.args)
        return (
            ServiceToolInvocation(
                toolName: name,
                jsonArguments: validated.json,
                toolCallId: first.value.id,
                geminiThoughtSignature: first.value.thoughtSignature
            ),
            validated.wasRepaired
        )
    }

    @inline(__always)
    static func resolveToolCallSlot(
        explicitIndex: Int?,
        callId: String?,
        accumulated: [Int: RemoteProviderService.StreamingState.ToolSlot],
        idToIndex: inout [String: Int],
        nextFallback: inout Int,
        lastTouchedSlot: Int?
    ) -> Int {
        if let idx = explicitIndex {
            if let id = callId { idToIndex[id] = idx }
            nextFallback = max(nextFallback, idx + 1)
            return idx
        }
        if let id = callId, let known = idToIndex[id] {
            return known
        }
        if callId == nil, let last = lastTouchedSlot, accumulated[last] != nil {
            return last
        }
        let highest = accumulated.keys.max() ?? -1
        let idx = max(highest + 1, nextFallback)
        nextFallback = idx + 1
        if let id = callId { idToIndex[id] = idx }
        return idx
    }

    static func validateToolCallJSON(_ json: String) -> ValidatedToolCallJSON {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ValidatedToolCallJSON(json: "{}", wasRepaired: false) }

        if let data = trimmed.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return ValidatedToolCallJSON(json: trimmed, wasRepaired: false)
        }

        var repaired = ""
        var inString = false
        var isEscaped = false
        var braceCount = 0
        var bracketCount = 0

        for ch in trimmed {
            if inString {
                if isEscaped {
                    isEscaped = false
                    repaired.append(ch)
                } else if ch == "\\" {
                    isEscaped = true
                    repaired.append(ch)
                } else if ch == "\"" {
                    inString = false
                    repaired.append(ch)
                } else if ch.isNewline {
                    if ch == "\n" {
                        repaired.append("\\n")
                    } else if ch == "\r" {
                        repaired.append("\\r")
                    }
                } else {
                    repaired.append(ch)
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    braceCount += 1
                } else if ch == "}" {
                    braceCount -= 1
                } else if ch == "[" {
                    bracketCount += 1
                } else if ch == "]" {
                    bracketCount -= 1
                }
                repaired.append(ch)
            }
        }

        if inString {
            if isEscaped {
                repaired.append("\\")
            }
            repaired.append("\"")
        }

        let trimmedForComma = repaired.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedForComma.hasSuffix(",") {
            repaired = String(trimmedForComma.dropLast())
        }

        for _ in 0 ..< bracketCount {
            repaired.append("]")
        }
        for _ in 0 ..< braceCount {
            repaired.append("}")
        }

        if let data = repaired.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            print("[Osaurus] Repaired incomplete tool call JSON (\(json.count) -> \(repaired.count) chars)")
            return ValidatedToolCallJSON(json: repaired, wasRepaired: true)
        }

        print("[Osaurus] Warning: Tool call JSON is malformed and could not be repaired: \(json.prefix(200))")
        return ValidatedToolCallJSON(json: json, wasRepaired: true)
    }

    private static func truncatedArgsSummary(
        from accumulated: [Int: RemoteProviderService.StreamingState.ToolSlot],
        toolName: String
    ) -> String {
        guard let entry = accumulated.first(where: { $0.value.name == toolName })?.value
        else { return "received 0 bytes" }
        let args = entry.args
        let bytes = args.utf8.count
        let tail = args.suffix(40).replacingOccurrences(of: "\n", with: "\\n")
        return "received \(bytes) bytes, ends with `\(tail)`"
    }

    private static func truncatedToolCallError(
        from accumulated: [Int: RemoteProviderService.StreamingState.ToolSlot],
        toolName: String,
        finishMarker: String
    ) -> RemoteProviderServiceError {
        let argsSummary = truncatedArgsSummary(from: accumulated, toolName: toolName)
        print(
            "[Osaurus] Discarding truncated tool call '\(toolName)' - "
                + "args needed repair (finish marker: \(finishMarker)). \(argsSummary)"
        )
        return RemoteProviderServiceError.streamingError(
            "Stream ended before tool call '\(toolName)' arguments were complete "
                + "(finish marker: \(finishMarker)). The provider closed the connection "
                + "mid-argument; retry the request."
        )
    }
}

struct OpenAICompatibleStreamParser {
    enum DecodeMode: Sendable, Equatable {
        case strict
        case lenient
    }

    struct Options: Sendable, Equatable {
        var decodeMode: DecodeMode
        var framing: OpenAICompatibleStreamFramer.Options
        /// When true, a tool-call finish (`finish_reason=tool_calls`) does NOT
        /// short-circuit the stream. The accumulated call is left for the
        /// finish boundary (`[DONE]`/stream-end) to dispatch, so the final
        /// `usage` chunk that OpenAI emits AFTER `finish_reason` (only when
        /// `stream_options.include_usage` was requested) is consumed first and
        /// surfaced as completion-token telemetry — mirroring the local vmlx
        /// path, which forwards a tool-call step's decode stats before
        /// finishing-by-throw. Bounded-safe: the leftover call is always
        /// dispatched by `dispatchFinal` at `[DONE]` or natural stream-end, so
        /// a provider that omits `[DONE]` cannot hang or drop the call. Only
        /// enabled for upstreams we actually request usage from (see
        /// `RemoteProviderService.requestsStreamUsageOptions`), so every other
        /// provider keeps the original dispatch-at-`finish_reason` timing.
        var deferToolCallDispatchUntilUsage: Bool = false

        static let strict = Options(decodeMode: .strict, framing: .strict)
        static let routerCompatible = Options(decodeMode: .lenient, framing: .routerCompatible)
    }

    static func handleEvent(
        jsonData: Data,
        options: Options,
        state: inout RemoteProviderService.StreamingState,
        yield: (String) -> Void
    ) throws -> RemoteProviderService.StreamEventOutcome {
        do {
            return try decodeEvent(jsonData, options: options, state: &state, yield: yield)
        } catch {
            if let recovered = tryRecoverSplitDataJSON(
                jsonData,
                options: options,
                state: &state,
                yield: yield
            ) {
                return recovered
            }
            throw error
        }
    }

    private static func tryRecoverSplitDataJSON(
        _ jsonData: Data,
        options: Options,
        state: inout RemoteProviderService.StreamingState,
        yield: (String) -> Void
    ) -> RemoteProviderService.StreamEventOutcome? {
        guard
            let normalizedData = OpenAICompatibleStreamFramer.repairedSplitDataJSONPayload(
                jsonData,
                options: options.framing
            )
        else { return nil }

        do {
            return try decodeEvent(normalizedData, options: options, state: &state, yield: yield)
        } catch {
            return nil
        }
    }

    private static func decodeEvent(
        _ jsonData: Data,
        options: Options,
        state: inout RemoteProviderService.StreamingState,
        yield: (String) -> Void
    ) throws -> RemoteProviderService.StreamEventOutcome {
        switch options.decodeMode {
        case .strict:
            let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: jsonData)
            // OpenAI emits usage on a dedicated final chunk (empty `choices`)
            // when `stream_options.include_usage` was set; on every other chunk
            // `usage` is null. Capture whatever is present — surfaced at the
            // finish boundary by `dispatchFinal`.
            state.captureProviderUsage(chunk.usage)
            let choice = chunk.choices.first
            return processChoice(
                delta: choice?.delta,
                finishReason: choice?.finish_reason,
                deferToolCallDispatchUntilUsage: options.deferToolCallDispatchUntilUsage,
                state: &state,
                yield: yield
            )
        case .lenient:
            let chunk = try JSONDecoder().decode(LenientChatCompletionChunk.self, from: jsonData)
            state.captureProviderUsage(chunk.usage)
            let choice = chunk.choices?.first
            if let message = choice?.message {
                return processMessageCompletion(
                    message,
                    finishReason: choice?.finish_reason,
                    deferToolCallDispatchUntilUsage: options.deferToolCallDispatchUntilUsage,
                    state: &state,
                    yield: yield
                )
            }
            return processChoice(
                delta: choice?.delta,
                finishReason: choice?.finish_reason,
                deferToolCallDispatchUntilUsage: options.deferToolCallDispatchUntilUsage,
                state: &state,
                yield: yield
            )
        }
    }

    private static func processMessageCompletion(
        _ message: DeltaContent,
        finishReason: String?,
        deferToolCallDispatchUntilUsage: Bool,
        state: inout RemoteProviderService.StreamingState,
        yield: (String) -> Void
    ) -> RemoteProviderService.StreamEventOutcome {
        let outcome = processChoice(
            delta: message,
            finishReason: finishReason ?? "stop",
            deferToolCallDispatchUntilUsage: deferToolCallDispatchUntilUsage,
            state: &state,
            yield: yield
        )
        if case .continue = outcome {
            return .finishNormal
        }
        return outcome
    }

    private static func processChoice(
        delta: DeltaContent?,
        finishReason: String?,
        deferToolCallDispatchUntilUsage: Bool,
        state: inout RemoteProviderService.StreamingState,
        yield: (String) -> Void
    ) -> RemoteProviderService.StreamEventOutcome {
        if let toolCalls = delta?.tool_calls {
            for toolCall in toolCalls {
                let idx = OpenAICompatibleToolCallAccumulator.resolveToolCallSlot(
                    explicitIndex: toolCall.index,
                    callId: toolCall.id,
                    accumulated: state.accumulatedToolCalls,
                    idToIndex: &state.toolCallIdToIndex,
                    nextFallback: &state.nextFallbackToolCallIndex,
                    lastTouchedSlot: state.lastTouchedToolSlot
                )
                var current =
                    state.accumulatedToolCalls[idx] ?? (
                        id: nil, name: nil, args: "", thoughtSignature: nil
                    )
                if let id = toolCall.id { current.id = id }
                if let name = toolCall.function?.name, current.name == nil {
                    current.name = name
                    print("[Osaurus] OpenAI tool call detected: index=\(idx), name=\(name)")
                    yield(StreamingToolHint.encode(name))
                }
                if let args = toolCall.function?.arguments {
                    current.args += args
                    yield(StreamingToolHint.encodeArgs(args))
                }
                state.accumulatedToolCalls[idx] = current
                state.lastTouchedToolSlot = idx
            }
        }

        if state.accumulatedToolCalls.isEmpty,
            let reasoning = delta?.reasoning_content,
            !reasoning.isEmpty
        {
            state.yieldedReasoningCount += 1
            yield(StreamingReasoningHint.encode(reasoning))
        }

        if state.accumulatedToolCalls.isEmpty,
            let content = delta?.content,
            !content.isEmpty
        {
            if var splitter = state.thinkSplitter {
                let segments = splitter.process(content)
                state.thinkSplitter = splitter
                for segment in segments {
                    switch segment {
                    case .reasoning(let reasoning):
                        if !reasoning.isEmpty { yield(StreamingReasoningHint.encode(reasoning)) }
                    case .content(let visible):
                        guard !visible.isEmpty else { continue }
                        let (truncated, hitStop) = applyStopSequences(
                            visible,
                            stopSequences: state.stopSequences
                        )
                        state.recordYield(truncated)
                        yield(truncated)
                        if hitStop { return .finishNormal }
                    }
                }
            } else {
                let (truncated, hitStop) = applyStopSequences(content, stopSequences: state.stopSequences)
                state.recordYield(truncated)
                yield(truncated)
                if hitStop { return .finishNormal }
            }
        }

        if let finishReason, !finishReason.isEmpty {
            state.lastFinishReason = finishReason
            if finishReason == "length",
                state.accumulatedToolCalls.isEmpty,
                state.yieldedTextCount == 0,
                state.yieldedReasoningCount == 0
            {
                return .finishWithError(
                    RemoteProviderServiceError.streamingError(
                        "Provider reached the output token limit before emitting visible text, reasoning, or a tool call (finish_reason=length). Increase max_tokens or reduce the prompt/tool context."
                    )
                )
            }
            switch OpenAICompatibleToolCallAccumulator.resolveAccumulatedToolCall(
                from: state.accumulatedToolCalls,
                finishMarker: "finish_reason=\(finishReason)"
            ) {
            case .none: break
            case .ready(let inv):
                // Normally dispatch the tool the moment the provider signals it.
                // For usage-enabled upstreams, keep iterating instead so the
                // trailing `usage` chunk (which arrives AFTER `finish_reason`)
                // is captured first; `dispatchFinal` re-resolves the same
                // accumulated call at `[DONE]`/stream-end and dispatches it
                // there, after emitting the completion-token stats hint. The
                // call is preserved in `state.accumulatedToolCalls`, and
                // visible content stays suppressed (the content/reasoning yield
                // guards above already key off a non-empty tool-call map), so
                // deferring cannot leak post-tool text.
                if deferToolCallDispatchUntilUsage {
                    break
                }
                return .finishWithToolCall(inv)
            case .truncated(let err): return .finishWithError(err)
            }
        }

        return .continue
    }

    @inline(__always)
    private static func applyStopSequences(
        _ text: String,
        stopSequences: [String]
    ) -> (text: String, hitStop: Bool) {
        guard !stopSequences.isEmpty else { return (text, false) }
        for seq in stopSequences {
            if let range = text.range(of: seq) {
                return (String(text[..<range.lowerBound]), true)
            }
        }
        return (text, false)
    }

    private struct LenientChatCompletionChunk: Decodable {
        let choices: [Choice]?
        let usage: Usage?

        struct Choice: Decodable {
            let index: Int?
            let delta: DeltaContent?
            let message: DeltaContent?
            let finish_reason: String?
        }
    }
}
