//
//  StreamAccumulator.swift
//  osaurus
//
//  Consumes MLX generation events and emits typed ModelRuntimeEvent with
//  token slicing, stop-sequence handling, and tool-call signaling.
//
//  Tool-call parsing is fully delegated to the upstream ToolCallProcessor
//  (mlx-swift-lm / MLXLMCommon).  The ToolCallFormat is auto-detected by
//  mlx-swift-lm's model-loading pipeline from config.json's `model_type`
//  field and plumbed here via StreamAccumulator.accumulate(…toolCallFormat:).
//  This means new model families (Gemma, LFM2, Mistral, GLM4, Kimi K2, …)
//  are supported automatically as mlx-swift-lm adds parsers for them,
//  without any changes required in osaurus.
//

import Foundation
import MLXLMCommon
import os.log

private let accumSignposter = OSSignposter(subsystem: "ai.osaurus", category: "Generation")
private let accumLog = Logger(subsystem: "ai.osaurus", category: "Generation")

/// An AsyncSequence that transforms a raw `TokenGeneration` stream into
/// typed `ModelRuntimeEvent` values.  All processing happens synchronously
/// inside each `next()` call – no background Task is spawned, so this
/// works correctly in Swift Testing and any other context where unstructured
/// Tasks may not be scheduled.
struct StreamAccumulator: AsyncSequence, Sendable {
    typealias Element = ModelRuntimeEvent

    // MARK: - Configuration (stored for iterator initialisation)

    private let events: AsyncStream<TokenGeneration>
    private let tokenizer: any Tokenizer
    private let stopSequences: [String]
    private let tools: [Tool]?
    private let toolCallFormat: ToolCallFormat
    private let toolsSpec: [[String: any Sendable]]?
    private let generationTask: Task<Void, Never>?
    private let onGeneratedTokenIds: (@Sendable ([Int]) -> Void)?

    // MARK: - Public factory

    /// Accumulate token-ID generation events into a typed model-runtime event stream.
    ///
    /// - Parameters:
    ///   - events: Raw `TokenGeneration` stream from `generateTokenTask`.
    ///   - tokenizer: Used to decode token IDs to text chunks.
    ///   - stopSequences: Hard-stop strings (e.g. EOS surrogates).
    ///   - tools: Tool definitions for tool-call detection (used to decide
    ///     whether to activate the processor at all).
    ///   - toolCallFormat: The format the model uses to encode tool calls.
    ///     Defaults to `.json` (Qwen2/3 `<tool_call>{json}</tool_call>` style).
    ///     Should be sourced from `ModelConfiguration.toolCallFormat` as
    ///     auto-detected by mlx-swift-lm's model-loading pipeline.
    ///   - toolsSpec: Raw tool-spec dictionaries forwarded to `ToolCallProcessor`
    ///     for type-aware argument coercion (e.g. string→int for LFM2/XML formats).
    ///   - generationTask: Backing generation task; cancelled on early exit.
    ///   - onGeneratedTokenIds: Called once when the stream finishes normally,
    ///     with the list of all generated token IDs.
    static func accumulate(
        events: AsyncStream<TokenGeneration>,
        tokenizer: any Tokenizer,
        stopSequences: [String],
        tools: [Tool]?,
        toolCallFormat: ToolCallFormat = .json,
        toolsSpec: [[String: any Sendable]]? = nil,
        generationTask: Task<Void, Never>? = nil,
        onGeneratedTokenIds: (@Sendable ([Int]) -> Void)? = nil
    ) -> StreamAccumulator {
        StreamAccumulator(
            events: events,
            tokenizer: tokenizer,
            stopSequences: stopSequences,
            tools: tools,
            toolCallFormat: toolCallFormat,
            toolsSpec: toolsSpec,
            generationTask: generationTask,
            onGeneratedTokenIds: onGeneratedTokenIds
        )
    }

    /// Wraps the accumulator in an `AsyncThrowingStream` for callers that require that type.
    /// The bridging `Task` runs in the caller's context — call this from an actor or structured
    /// concurrency scope where unstructured Tasks are reliably scheduled.
    func asAsyncThrowingStream() -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        let acc = self
        return AsyncThrowingStream { continuation in
            Task {
                for await event in acc { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    // MARK: - AsyncSequence

    func makeAsyncIterator() -> Iterator {
        Iterator(
            eventIterator: events.makeAsyncIterator(),
            tokenizer: tokenizer,
            stopSequences: stopSequences,
            tools: tools,
            toolCallFormat: toolCallFormat,
            toolsSpec: toolsSpec,
            generationTask: generationTask,
            onGeneratedTokenIds: onGeneratedTokenIds
        )
    }

    // MARK: - Iterator

    struct Iterator: AsyncIteratorProtocol {
        typealias Element = ModelRuntimeEvent

        private var eventIterator: AsyncStream<TokenGeneration>.AsyncIterator
        private let tokenizer: any Tokenizer
        private let stopSequences: [String]
        private let tools: [Tool]?
        private let generationTask: Task<Void, Never>?
        private let onGeneratedTokenIds: (@Sendable ([Int]) -> Void)?

        // Upstream tool-call processor — nil when no tools are present.
        private let processor: ToolCallProcessor?

        // State
        private var rollingBuffer = ""
        private var bufferStartOffset = 0
        private var emittedCount = 0
        private var generatedTokenIds: [Int] = []
        private var firstToken = true
        private var decodedSoFar = ""
        private var finished = false
        private var pendingEvents: [ModelRuntimeEvent] = []
        // Signpost state for the generation interval (first-token → stream-end)
        private var generationSpState: OSSignpostIntervalState? = nil
        private var generationSpStarted = false
        private var generationT0: CFAbsoluteTime = 0

        private var maxStopLen: Int
        private var shouldCheckStop: Bool
        private var hasTools: Bool
        // Tracks how many tool calls the processor has emitted so far so we
        // can detect when processChunk() produces a new one.
        private var knownToolCallCount = 0

        /// Sliding context window used for incremental O(1) token decode.
        /// BPE and byte-level tokenizers may need a few preceding tokens to
        /// correctly decode the newest token (e.g. multi-byte UTF-8 splits
        /// across token boundaries).  8 tokens is enough for any known tokeniser.
        private static let decodeContextSize = 8
        private var decodeContextIds: [Int] = []
        /// Token IDs whose decoded slice ends with U+FFFD (replacement char) —
        /// a strong signal that a multi-byte UTF-8 codepoint (e.g. emoji) is
        /// split across this token boundary. Held back until a subsequent
        /// token completes the sequence. Cap prevents unbounded buffering
        /// when the model legitimately emits an <unk> that decodes as FFFD.
        private var pendingPartialIds: [Int] = []
        private static let maxPendingPartial = 4

        init(
            eventIterator: AsyncStream<TokenGeneration>.AsyncIterator,
            tokenizer: any Tokenizer,
            stopSequences: [String],
            tools: [Tool]?,
            toolCallFormat: ToolCallFormat,
            toolsSpec: [[String: any Sendable]]?,
            generationTask: Task<Void, Never>?,
            onGeneratedTokenIds: (@Sendable ([Int]) -> Void)?
        ) {
            self.eventIterator = eventIterator
            self.tokenizer = tokenizer
            self.stopSequences = stopSequences
            self.tools = tools
            self.generationTask = generationTask
            self.onGeneratedTokenIds = onGeneratedTokenIds
            self.maxStopLen = stopSequences.map { $0.count }.max() ?? 0
            self.shouldCheckStop = !stopSequences.isEmpty
            self.hasTools = tools != nil && !(tools?.isEmpty ?? true)

            // Only create the processor when tools are actually present.
            if hasTools {
                self.processor = ToolCallProcessor(format: toolCallFormat, tools: toolsSpec)
            } else {
                self.processor = nil
            }
        }

        mutating func next() async -> ModelRuntimeEvent? {
            // Drain any buffered events first (e.g., multiple events produced from one token).
            if !pendingEvents.isEmpty { return pendingEvents.removeFirst() }
            if finished { return nil }

            while true {
                // Check cancellation.
                if Task.isCancelled {
                    await finish(cancelled: true)
                    return nil
                }

                // Drain pending (may have been filled by previous iteration).
                if !pendingEvents.isEmpty { return pendingEvents.removeFirst() }

                // Pull the next raw event.
                guard let event = await eventIterator.next() else {
                    // Stream ended naturally.
                    await finish(cancelled: false)
                    return pendingEvents.isEmpty ? nil : pendingEvents.removeFirst()
                }

                // Log info events and surface generation stats downstream.
                if let info = event.info {
                    print(
                        String(
                            format: "[MLX] prompt: %d tokens %.1f tok/s (%.2fs) | gen: %d tokens %.1f tok/s (%.2fs)",
                            info.promptTokenCount,
                            info.promptTokensPerSecond,
                            info.promptTime,
                            info.generationTokenCount,
                            info.tokensPerSecond,
                            info.generateTime
                        )
                    )
                    // Emit GPU-accurate stats as a signpost event so they appear in
                    // Instruments and can be captured by `log stream --type signpost`.
                    accumSignposter.emitEvent(
                        "mlxStats",
                        id: .exclusive,
                        "prompt: \(info.promptTokenCount, privacy: .public) tok \(info.promptTokensPerSecond, privacy: .public) tok/s \(info.promptTime, privacy: .public)s | gen: \(info.generationTokenCount, privacy: .public) tok \(info.tokensPerSecond, privacy: .public) tok/s \(info.generateTime, privacy: .public)s"
                    )
                    // Also emit as a Logger.info so it appears in `log stream`.
                    accumLog.info(
                        "[perf] mlxStats promptTokens=\(info.promptTokenCount, privacy: .public) promptTps=\(info.promptTokensPerSecond, privacy: .public) promptMs=\(Int(info.promptTime * 1000), privacy: .public) genTokens=\(info.generationTokenCount, privacy: .public) genTps=\(info.tokensPerSecond, privacy: .public) genMs=\(Int(info.generateTime * 1000), privacy: .public)"
                    )
                    pendingEvents.append(
                        .completionInfo(
                            tokenCount: info.generationTokenCount,
                            tokensPerSecond: info.tokensPerSecond
                        )
                    )
                    continue
                }

                guard let tokenId = event.token else { continue }

                // Signal prefill complete on first token; start generation interval.
                if firstToken {
                    firstToken = false
                    generationT0 = CFAbsoluteTimeGetCurrent()
                    generationSpState = accumSignposter.beginInterval(
                        "generation",
                        id: accumSignposter.makeSignpostID()
                    )
                    generationSpStarted = true
                    InferenceProgressManager.shared.prefillDidFinishAsync()
                }

                generatedTokenIds.append(tokenId)

                // Incremental decode — O(1) per token regardless of sequence length.
                // Decode [context ++ pending ++ newToken] minus [context] to isolate
                // the new text. `pending` accumulates tokens whose isolated decode
                // ended in U+FFFD (partial multi-byte codepoint); once a subsequent
                // token completes the sequence the entire group is emitted at once.
                let combinedNew = pendingPartialIds + [tokenId]
                let contextWithNew = decodeContextIds + combinedNew
                let withNewDecoded = tokenizer.decode(tokenIds: contextWithNew)
                let contextDecoded =
                    decodeContextIds.isEmpty
                    ? ""
                    : tokenizer.decode(tokenIds: decodeContextIds)
                let token: String
                if withNewDecoded.count > contextDecoded.count {
                    token = String(withNewDecoded.dropFirst(contextDecoded.count))
                } else {
                    token = ""
                }

                // Defer emission if the tail is still a partial UTF-8 sequence,
                // unless we've already buffered the maximum — at which point the
                // FFFD is real (e.g. legitimate <unk>) and we flush as-is to
                // avoid losing user-visible characters.
                if token.last == "\u{FFFD}" && pendingPartialIds.count < Self.maxPendingPartial {
                    pendingPartialIds.append(tokenId)
                    continue
                }

                decodedSoFar += token

                // Advance the sliding context window to cover every token we just
                // emitted (any buffered partials plus this one).
                decodeContextIds.append(contentsOf: combinedNew)
                pendingPartialIds.removeAll(keepingCapacity: true)
                while decodeContextIds.count > Self.decodeContextSize {
                    decodeContextIds.removeFirst()
                }

                guard !token.isEmpty else { continue }

                rollingBuffer += token

                if rollingBuffer.count > 10_000 {
                    let removeCount = rollingBuffer.count - 5_000
                    rollingBuffer.removeFirst(removeCount)
                    bufferStartOffset += removeCount
                }

                // Tool-call detection: delegate entirely to ToolCallProcessor.
                // processChunk() returns:
                //   - The token text (or leading non-tool text) to emit normally, OR
                //   - nil  when the processor is buffering a potential tool call
                //          and nothing should be shown in the UI yet.
                // When toolCalls.count grows, a complete tool call was parsed.
                if let proc = processor {
                    let displayText = proc.processChunk(token)
                    let newCount = proc.toolCalls.count

                    if newCount > knownToolCallCount {
                        // A complete tool call was just parsed.
                        let toolCall = proc.toolCalls[knownToolCallCount]
                        knownToolCallCount = newCount
                        InferenceProgressManager.shared.prefillDidFinishAsync()
                        generationTask?.cancel()
                        finished = true
                        let argsJSON = serializeArguments(toolCall.function.arguments)
                        return .toolInvocation(name: toolCall.function.name, argsJSON: argsJSON)
                    }

                    // If processChunk returned nil, the token is being buffered
                    // as part of a potential tool call — don't emit it to the UI.
                    guard let visible = displayText, !visible.isEmpty else { continue }

                    // There's visible text to forward through the stop-sequence pipeline.
                    let visibleToken = visible

                    // Stop-sequence check on the visible portion.
                    if shouldCheckStop {
                        if let result = processWithStopCheck(token: visibleToken) {
                            return result
                        }
                        continue
                    }
                    emittedCount += visibleToken.count
                    return .tokens(visibleToken)
                }

                // Stop-sequence check (no tools path).
                if shouldCheckStop {
                    if let result = processWithStopCheck(token: token) {
                        return result
                    }
                    continue
                }

                // Normal emission.
                emittedCount += token.count
                return .tokens(token)
            }
        }

        /// Process a token with stop-sequence lookahead.
        /// Returns an event to emit, or nil if nothing to emit yet (continue looping).
        /// Sets `finished = true` and populates `pendingEvents` for stop matches.
        private mutating func processWithStopCheck(token: String) -> ModelRuntimeEvent? {
            let checkLen = maxStopLen + token.count + 1
            let searchStart =
                rollingBuffer.index(
                    rollingBuffer.endIndex,
                    offsetBy: -checkLen,
                    limitedBy: rollingBuffer.startIndex
                ) ?? rollingBuffer.startIndex
            let searchRange = searchStart ..< rollingBuffer.endIndex

            if let match = stopSequences.compactMap({ s -> (String, Range<String.Index>)? in
                guard let r = rollingBuffer.range(of: s, range: searchRange) else { return nil }
                return (s, r)
            }).min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
                let stopRange = match.1
                let stopLocalIndex = rollingBuffer.distance(from: rollingBuffer.startIndex, to: stopRange.lowerBound)
                let stopGlobalIndex = bufferStartOffset + stopLocalIndex

                generationTask?.cancel()
                finished = true

                // When a stop sequence marks the end of a tool-call block, call
                // processEOS so ToolCallProcessor can extract any buffered call.
                if let proc = processor {
                    let stopEndIndex = stopRange.upperBound
                    // Feed everything up to and including the stop tag into the processor.
                    let tail = String(rollingBuffer[rollingBuffer.startIndex ..< stopEndIndex])
                    // We already fed all prior tokens; only the remaining suffix needs feeding.
                    // Since processor has already received all tokens up to (but not including)
                    // the current `token`, and processWithStopCheck is called after processChunk
                    // has returned the displayText, the stop tag arrived inside `token` itself.
                    // Call processEOS to flush any buffered content.
                    proc.processEOS()
                    let newCount = proc.toolCalls.count
                    if newCount > knownToolCallCount {
                        let toolCall = proc.toolCalls[knownToolCallCount]
                        knownToolCallCount = newCount
                        let argsJSON = serializeArguments(toolCall.function.arguments)
                        return .toolInvocation(name: toolCall.function.name, argsJSON: argsJSON)
                    }
                    _ = tail  // suppress unused-variable warning
                }

                if stopGlobalIndex > emittedCount {
                    let yieldGlobalStart = Swift.max(emittedCount, bufferStartOffset)
                    let yieldGlobalEnd = stopGlobalIndex
                    if yieldGlobalStart < yieldGlobalEnd {
                        let localStart = yieldGlobalStart - bufferStartOffset
                        let localEnd = yieldGlobalEnd - bufferStartOffset
                        if localStart >= 0 && localEnd <= rollingBuffer.count {
                            let startIdx = rollingBuffer.index(rollingBuffer.startIndex, offsetBy: localStart)
                            let endIdx = rollingBuffer.index(rollingBuffer.startIndex, offsetBy: localEnd)
                            let content = String(rollingBuffer[startIdx ..< endIdx])
                            if !content.isEmpty { return .tokens(content) }
                        }
                    }
                }
                return nil
            }

            // Safe prefix emission: emit everything except the last maxStopLen chars.
            // Holding back exactly maxStopLen chars guarantees no complete stop sequence
            // can appear in the emitted portion (since stop sequences are at most maxStopLen long).
            let safeEnd = rollingBuffer.count - maxStopLen
            let safeGlobalEnd = bufferStartOffset + safeEnd
            if safeGlobalEnd > emittedCount && safeEnd > 0 {
                let yieldStart = Swift.max(emittedCount, bufferStartOffset)
                let yieldEnd = safeGlobalEnd
                if yieldStart < yieldEnd {
                    let localStart = yieldStart - bufferStartOffset
                    let localEnd = yieldEnd - bufferStartOffset
                    if localStart >= 0 && localEnd <= rollingBuffer.count {
                        let startIdx = rollingBuffer.index(rollingBuffer.startIndex, offsetBy: localStart)
                        let endIdx = rollingBuffer.index(rollingBuffer.startIndex, offsetBy: localEnd)
                        let content = String(rollingBuffer[startIdx ..< endIdx])
                        if !content.isEmpty {
                            emittedCount += content.count
                            return .tokens(content)
                        }
                    }
                }
            }
            return nil
        }

        /// Called when the iteration finishes (either naturally or cancelled).
        private mutating func finish(cancelled: Bool) async {
            guard !finished else { return }
            finished = true

            if generationSpStarted, let spState = generationSpState {
                let tokenCount = generatedTokenIds.count
                let durationMs = Int((CFAbsoluteTimeGetCurrent() - generationT0) * 1000)
                let suffix = cancelled ? " (cancelled)" : ""
                accumSignposter.endInterval(
                    "generation",
                    spState,
                    "\(tokenCount, privacy: .public) tokens\(suffix, privacy: .public)"
                )
                accumLog.info(
                    "[perf] generation durationMs=\(durationMs, privacy: .public) tokenCount=\(tokenCount, privacy: .public) cancelled=\(cancelled, privacy: .public)"
                )
            }

            if cancelled {
                InferenceProgressManager.shared.prefillDidFinishAsync()
                generationTask?.cancel()
                return
            }

            // On natural EOS, flush any buffered tool-call content.
            // This handles formats like Mistral where the end tag is the EOS
            // token itself (intercepted at the token-ID level, never delivered
            // as text), so processChunk never saw the closing delimiter.
            if let proc = processor {
                proc.processEOS()
                let newCount = proc.toolCalls.count
                if newCount > knownToolCallCount {
                    let toolCall = proc.toolCalls[knownToolCallCount]
                    knownToolCallCount = newCount
                    let argsJSON = serializeArguments(toolCall.function.arguments)
                    pendingEvents.append(.toolInvocation(name: toolCall.function.name, argsJSON: argsJSON))
                    // Don't flush stop-sequence buffer — tool call replaces it.
                    InferenceProgressManager.shared.prefillDidFinishAsync()
                    onGeneratedTokenIds?(generatedTokenIds)
                    return
                }
            }

            // Flush any tokens still in the partial-UTF-8 buffer. They would
            // otherwise be lost if the stream ends with a deferred tail, or if
            // the model emits a legitimate <unk> that never got a completing
            // codepoint. Accept whatever the tokenizer produces (possibly a
            // U+FFFD) rather than dropping characters.
            if !pendingPartialIds.isEmpty {
                let contextWithPending = decodeContextIds + pendingPartialIds
                let withPendingDecoded = tokenizer.decode(tokenIds: contextWithPending)
                let contextDecoded =
                    decodeContextIds.isEmpty
                    ? ""
                    : tokenizer.decode(tokenIds: decodeContextIds)
                if withPendingDecoded.count > contextDecoded.count {
                    let tail = String(withPendingDecoded.dropFirst(contextDecoded.count))
                    if !tail.isEmpty {
                        decodedSoFar += tail
                        if shouldCheckStop {
                            // Let the stop-sequence flush below surface it.
                            rollingBuffer += tail
                        } else {
                            // No stop-sequence path: emit directly.
                            pendingEvents.append(.tokens(tail))
                            emittedCount += tail.count
                        }
                    }
                }
                decodeContextIds.append(contentsOf: pendingPartialIds)
                pendingPartialIds.removeAll(keepingCapacity: false)
                while decodeContextIds.count > Self.decodeContextSize {
                    decodeContextIds.removeFirst()
                }
            }

            // Flush buffered stop-sequence lookahead on natural finish.
            if shouldCheckStop && emittedCount < bufferStartOffset + rollingBuffer.count {
                let yieldStart = Swift.max(emittedCount, bufferStartOffset)
                let yieldEnd = bufferStartOffset + rollingBuffer.count
                if yieldStart < yieldEnd {
                    let localStart = yieldStart - bufferStartOffset
                    let localEnd = yieldEnd - bufferStartOffset
                    if localStart >= 0 && localEnd <= rollingBuffer.count {
                        let startIdx = rollingBuffer.index(rollingBuffer.startIndex, offsetBy: localStart)
                        let endIdx = rollingBuffer.index(rollingBuffer.startIndex, offsetBy: localEnd)
                        let content = String(rollingBuffer[startIdx ..< endIdx])
                        if !content.isEmpty { pendingEvents.append(.tokens(content)) }
                    }
                }
            }

            if let generationTask {
                await generationTask.value
            }
            InferenceProgressManager.shared.prefillDidFinishAsync()
            onGeneratedTokenIds?(generatedTokenIds)
        }

        // MARK: - Argument serialisation

        /// Converts `[String: JSONValue]` (upstream ToolCall argument type) to a
        /// compact JSON string suitable for `ModelRuntimeEvent.toolInvocation(argsJSON:)`.
        private func serializeArguments(_ arguments: [String: MLXLMCommon.JSONValue]) -> String {
            let anyDict = arguments.mapValues { $0.anyValue }
            guard let data = try? JSONSerialization.data(withJSONObject: anyDict),
                let json = String(data: data, encoding: .utf8)
            else { return "{}" }
            return json
        }
    }

    // MARK: - Private init

    private init(
        events: AsyncStream<TokenGeneration>,
        tokenizer: any Tokenizer,
        stopSequences: [String],
        tools: [Tool]?,
        toolCallFormat: ToolCallFormat,
        toolsSpec: [[String: any Sendable]]?,
        generationTask: Task<Void, Never>?,
        onGeneratedTokenIds: (@Sendable ([Int]) -> Void)?
    ) {
        self.events = events
        self.tokenizer = tokenizer
        self.stopSequences = stopSequences
        self.tools = tools
        self.toolCallFormat = toolCallFormat
        self.toolsSpec = toolsSpec
        self.generationTask = generationTask
        self.onGeneratedTokenIds = onGeneratedTokenIds
    }
}
