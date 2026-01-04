//
//  StreamAccumulator.swift
//  osaurus
//
//  Consumes MLX generation events and emits typed ModelRuntimeEvent with
//  token slicing, stop-sequence handling, and tool-call signaling.
//

import Foundation
import MLXLMCommon

struct StreamAccumulator {
    static func accumulate(
        events: AsyncStream<MLXLMCommon.Generation>,
        stopSequences: [String],
        tools: [Tool]?
    ) -> AsyncThrowingStream<ModelRuntimeEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ModelRuntimeEvent, Error>.makeStream()
        let producerTask = Task {
            // Bounded Rolling Buffer: efficiently manages the active text window
            // This avoids O(N) memory growth and eliminates string reconstruction costs
            var rollingBuffer = ""
            var bufferStartOffset = 0  // Tracks how many characters have been pruned
            var emittedCount = 0  // Global count of emitted characters

            let maxStopLen = stopSequences.map { $0.count }.max() ?? 0
            let shouldCheckStop = !stopSequences.isEmpty
            // Tool detection needs ~5000 chars. We prune when buffer is roughly double that to amortize shifting costs.
            let maxBufferSize = 10_000
            let pruneToSize = 5_000

            for await event in events {
                // Check for task cancellation to allow early termination
                if Task.isCancelled {
                    continuation.finish()
                    return
                }
                if let toolCall = event.toolCall {
                    let argsData = try? JSONSerialization.data(
                        withJSONObject: toolCall.function.arguments.mapValues { $0.anyValue }
                    )
                    let argsString = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    continuation.yield(.toolInvocation(name: toolCall.function.name, argsJSON: argsString))
                    continuation.finish()
                    return
                }
                guard let token = event.chunk, !token.isEmpty else { continue }

                rollingBuffer += token

                // Prune buffer if needed (Amortized O(1))
                if rollingBuffer.count > maxBufferSize {
                    let removeCount = rollingBuffer.count - pruneToSize
                    rollingBuffer.removeFirst(removeCount)
                    bufferStartOffset += removeCount
                }

                // Fallback: detect inline tool-call JSON in generated text
                if let tools, !tools.isEmpty, token.contains("}") {
                    // rollingBuffer already represents the active window, pass directly
                    if let (name, argsJSON) = ToolDetection.detectInlineToolCall(in: rollingBuffer, tools: tools) {
                        continuation.yield(.toolInvocation(name: name, argsJSON: argsJSON))
                        continuation.finish()
                        return
                    }
                }

                if shouldCheckStop {
                    // Check tail of the rolling buffer
                    let checkLen = maxStopLen + token.count + 1

                    // Use bidirectional index calculation
                    let searchStart =
                        rollingBuffer.index(
                            rollingBuffer.endIndex,
                            offsetBy: -checkLen,
                            limitedBy: rollingBuffer.startIndex
                        ) ?? rollingBuffer.startIndex
                    let searchRange = searchStart ..< rollingBuffer.endIndex

                    if let match = stopSequences.compactMap({ s -> (String, Range<String.Index>)? in
                        guard let range = rollingBuffer.range(of: s, range: searchRange) else { return nil }
                        return (s, range)
                    }).min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
                        // Found a stop sequence
                        let stopRange = match.1

                        // Calculate global index of the stop match
                        // bufferIndex -> globalIndex = index + bufferStartOffset
                        let stopLocalIndex = rollingBuffer.distance(
                            from: rollingBuffer.startIndex,
                            to: stopRange.lowerBound
                        )
                        let stopGlobalIndex = bufferStartOffset + stopLocalIndex

                        // Yield content before the stop sequence if it hasn't been emitted yet
                        if stopGlobalIndex > emittedCount {
                            // Determine local range to yield
                            // We want from [emittedCount] to [stopGlobalIndex]
                            // But emittedCount might be before our current buffer (pruned)
                            // So we start from max(emittedCount, bufferStartOffset)

                            let yieldGlobalStart = max(emittedCount, bufferStartOffset)
                            let yieldGlobalEnd = stopGlobalIndex

                            if yieldGlobalStart < yieldGlobalEnd {
                                let localStart = yieldGlobalStart - bufferStartOffset
                                let localEnd = yieldGlobalEnd - bufferStartOffset

                                // Safety checks for indices
                                if localStart >= 0 && localEnd <= rollingBuffer.count {
                                    let startIdx = rollingBuffer.index(rollingBuffer.startIndex, offsetBy: localStart)
                                    let endIdx = rollingBuffer.index(rollingBuffer.startIndex, offsetBy: localEnd)
                                    let content = String(rollingBuffer[startIdx ..< endIdx])
                                    if !content.isEmpty { continuation.yield(.tokens(content)) }
                                }
                            }
                        }

                        continuation.finish()
                        return
                    }
                }

                // No stop sequence found, yield the token
                continuation.yield(.tokens(token))
                emittedCount += token.count
            }
            continuation.finish()
        }

        // Cancel producer task when consumer stops consuming
        continuation.onTermination = { @Sendable _ in
            producerTask.cancel()
        }

        return stream
    }
}
