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
            var accumulated = ""
            var alreadyEmitted = 0
            let shouldCheckStop = !stopSequences.isEmpty
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
                accumulated += token

                // Fallback: detect inline tool-call JSON in generated text
                if let tools, !tools.isEmpty,
                    let (name, argsJSON) = ToolDetection.detectInlineToolCall(in: accumulated, tools: tools)
                {
                    continuation.yield(.toolInvocation(name: name, argsJSON: argsJSON))
                    continuation.finish()
                    return
                }

                let newSlice = String(accumulated.dropFirst(alreadyEmitted))
                if shouldCheckStop {
                    if let stopIndex = stopSequences.compactMap({ s in accumulated.range(of: s)?.lowerBound })
                        .first
                    {
                        let finalRange =
                            accumulated.index(accumulated.startIndex, offsetBy: alreadyEmitted) ..< stopIndex
                        let finalContent = String(accumulated[finalRange])
                        if !finalContent.isEmpty { continuation.yield(.tokens(finalContent)) }
                        continuation.finish()
                        return
                    }
                }
                if !newSlice.isEmpty {
                    continuation.yield(.tokens(newSlice))
                    alreadyEmitted += newSlice.count
                }
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
