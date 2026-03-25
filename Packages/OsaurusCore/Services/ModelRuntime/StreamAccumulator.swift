//
//  StreamAccumulator.swift
//  osaurus
//
//  Consumes MLX generation events and emits typed ModelRuntimeEvent with
//  token slicing, stop-sequence handling, and tool-call signaling.
//

import Foundation
import MLXLMCommon
import Tokenizers

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
    private let generationTask: Task<Void, Never>?
    private let onGeneratedTokenIds: (@Sendable ([Int]) -> Void)?

    // MARK: - Public factory

    /// Accumulate token-ID generation events into a typed model-runtime event stream.
    ///
    /// - Parameters:
    ///   - events: Raw `TokenGeneration` stream from `generateTokenTask`.
    ///   - tokenizer: Used to decode token IDs to text chunks.
    ///   - stopSequences: Hard-stop strings (e.g. EOS surrogates).
    ///   - tools: Tool definitions for inline tool-call detection.
    ///   - generationTask: Backing generation task; cancelled on early exit.
    ///   - onGeneratedTokenIds: Called once when the stream finishes normally,
    ///     with the list of all generated token IDs.
    static func accumulate(
        events: AsyncStream<TokenGeneration>,
        tokenizer: any Tokenizer,
        stopSequences: [String],
        tools: [Tool]?,
        generationTask: Task<Void, Never>? = nil,
        onGeneratedTokenIds: (@Sendable ([Int]) -> Void)? = nil
    ) -> StreamAccumulator {
        StreamAccumulator(
            events: events,
            tokenizer: tokenizer,
            stopSequences: stopSequences,
            tools: tools,
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

        // State
        private var rollingBuffer = ""
        private var bufferStartOffset = 0
        private var emittedCount = 0
        private var generatedTokenIds: [Int] = []
        private var firstToken = true
        private var decodedSoFar = ""
        private var braceDepth = 0
        private var seenOpenBrace = false
        private var finished = false
        private var pendingEvents: [ModelRuntimeEvent] = []

        private var maxStopLen: Int
        private var shouldCheckStop: Bool
        private var hasTools: Bool

        init(
            eventIterator: AsyncStream<TokenGeneration>.AsyncIterator,
            tokenizer: any Tokenizer,
            stopSequences: [String],
            tools: [Tool]?,
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

                // Skip info events (just log them).
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
                    continue
                }

                guard let tokenId = event.token else { continue }

                // Signal prefill complete on first token.
                if firstToken {
                    firstToken = false
                    InferenceProgressManager.shared.prefillDidFinishAsync()
                }

                generatedTokenIds.append(tokenId)

                // Incremental decode.
                let newDecoded = tokenizer.decode(tokens: generatedTokenIds)
                let token =
                    newDecoded.count > decodedSoFar.count
                    ? String(newDecoded.dropFirst(decodedSoFar.count))
                    : ""
                decodedSoFar = newDecoded

                guard !token.isEmpty else { continue }

                rollingBuffer += token

                if rollingBuffer.count > 10_000 {
                    let removeCount = rollingBuffer.count - 5_000
                    rollingBuffer.removeFirst(removeCount)
                    bufferStartOffset += removeCount
                }

                // Tool detection.
                if hasTools {
                    for ch in token {
                        if ch == "{" {
                            braceDepth += 1; seenOpenBrace = true
                        } else if ch == "}" {
                            braceDepth = Swift.max(0, braceDepth - 1)
                        }
                    }
                    if seenOpenBrace && braceDepth == 0 {
                        if let tools,
                            let (name, argsJSON) = ToolDetection.detectInlineToolCall(in: rollingBuffer, tools: tools)
                        {
                            InferenceProgressManager.shared.prefillDidFinishAsync()
                            generationTask?.cancel()
                            finished = true
                            return .toolInvocation(name: name, argsJSON: argsJSON)
                        }
                        seenOpenBrace = false
                    }
                }

                // Stop-sequence check.
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

                // When a stop sequence marks the end of an XML-wrapped tool call
                // (e.g. `</tool_call>`), include everything up to and including
                // the stop sequence in the tool-detection window so the XML regex
                // can match the complete block.
                if hasTools, let tools {
                    let stopEndIndex = stopRange.upperBound
                    let bufferWithStop = String(rollingBuffer[rollingBuffer.startIndex ..< stopEndIndex])
                    if let (name, argsJSON) = ToolDetection.detectInlineToolCall(in: bufferWithStop, tools: tools) {
                        return .toolInvocation(name: name, argsJSON: argsJSON)
                    }
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

            // Safe prefix emission: emit everything except the last (maxStopLen - 1) chars.
            let safeEnd = rollingBuffer.count - (maxStopLen - 1)
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

            if cancelled {
                InferenceProgressManager.shared.prefillDidFinishAsync()
                generationTask?.cancel()
                return
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
    }

    // MARK: - Private init

    private init(
        events: AsyncStream<TokenGeneration>,
        tokenizer: any Tokenizer,
        stopSequences: [String],
        tools: [Tool]?,
        generationTask: Task<Void, Never>?,
        onGeneratedTokenIds: (@Sendable ([Int]) -> Void)?
    ) {
        self.events = events
        self.tokenizer = tokenizer
        self.stopSequences = stopSequences
        self.tools = tools
        self.generationTask = generationTask
        self.onGeneratedTokenIds = onGeneratedTokenIds
    }
}
