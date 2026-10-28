import Foundation
import os

/// Internal generation events. Text, tool previews and completion are distinct;
/// callers never need to parse a transport sentinel or throw a tool as an error.
enum ResponsesGenerationEvent: Sendable {
    case inputTokenCount(Int)
    case outputTextDelta(String)
    case reasoningDelta(String)
    case prefillProgress(PrefillProgressState)
    case toolEnvelopeDelta(String)
    case functionCallAdded(ResponsesFunctionCall)
    case functionNamePreview(String)
    case functionPreviewReset
    case functionArgumentsPreview(String)
    /// Ordered provider-native SSE lifecycle event, emitted before its
    /// portable projections. Retains response/item IDs and content indices
    /// for a Responses wire proxy; portable consumers ignore this metadata.
    case providerEvent(JSONValue)
    case providerOutputItem(JSONValue)
    case reasoningItem(StreamingReasoningItemHint.Item)
    /// Provider-tagged signed/redacted reasoning. Never a Responses Item.
    case anthropicThinkingBlock(JSONValue)
    case billing(RouterBillingSummary)
    case artifacts([RemoteRunArtifact])
    case agentTool(StreamingAgentToolHint.Trace)
    case remoteToolCompleted(StreamingToolHint.ToolCallDone)
    /// Opaque reserved metadata from an older service extension. Preserve it
    /// for diagnostics; it is never model text or an executable tool call.
    case compatibilityMetadata(String)
    case responseCompleted(ResponsesGenerationCompletion)
    /// The producer has drained and released its generation lease. This is
    /// distinct from response completion and is not a disk durability receipt.
    case drained
    /// The legacy service stream closed. Its protocol exposes no producer
    /// lease or cache-durability fence; do not equate this with native drain.
    case compatibilityStreamClosed
    /// A cache/cleanup failure after logical completion must stay observable,
    /// without replacing the already delivered response with a second terminal.
    case drainFailed(String)

    /// First-output timing is driven by actual generated content, reasoning
    /// or tool syntax. Prefill/accounting/lifecycle metadata is not a token.
    var isGeneratedOutput: Bool {
        switch self {
        case .outputTextDelta(let text), .reasoningDelta(let text), .toolEnvelopeDelta(let text),
            .functionNamePreview(let text), .functionArgumentsPreview(let text):
            return !text.isEmpty
        case .functionCallAdded(let call):
            return !call.name.isEmpty || !call.arguments.isEmpty
        default:
            return false
        }
    }
}

struct ResponsesFunctionCall: Sendable {
    let id: String
    let callID: String
    let name: String
    let arguments: String
    var geminiThoughtSignature: String? = nil
}

struct ResponsesGenerationCompletion: Sendable {
    enum Status: Sendable {
        case completed
        case incomplete
        case cancelled
    }

    let responseID: String
    let status: Status
    let functionCalls: [ResponsesFunctionCall]
    let tokenCount: Int?
    let tokensPerSecond: Double?
    let unclosedReasoning: Bool
    let stopReason: String?
    let promptTokensPerSecond: Double?
    let mtp: MTPStatsSummary?
    var inputTokenCount: Int? = nil
    var cachedInputTokenCount: Int? = nil

    /// Previewed calls are never actionable until the whole response completes.
    /// In particular a length/cancellation boundary cannot execute partial work.
    var dispatchableFunctionCalls: [ResponsesFunctionCall] {
        if case .completed = status { return functionCalls }
        return []
    }
}

enum ResponsesGenerationStream {
    enum StreamError: Error {
        case missingCompletion
    }

    /// Adapt the typed native runtime without a JSON/string round trip. Keep
    /// draining after completion so normal tool dispatch cannot cancel cache
    /// persistence. Only cancellation of the consumer cancels the producer.
    static func native(
        _ upstream: AsyncThrowingStream<ModelRuntimeEvent, Error>,
        responseID: String = "resp_" + UUID().uuidString,
        waitForProducerDrain: @escaping @Sendable () async -> Void = {}
    ) -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ResponsesGenerationEvent, Error>.makeStream()
        let responseCompleted = OSAllocatedUnfairLock(initialState: false)
        let producer = Task {
            var calls: [ResponsesFunctionCall] = []
            var inputTokens: Int?
            var cachedInputTokens: Int?
            var completed = false
            var hasCompletedToolPreview = false
            do {
                for try await event in upstream {
                    // Reach next() after cancellation even when a buffered event
                    // won the race; AsyncThrowingStream then cancels upstream.
                    if Task.isCancelled { continue }
                    if completed { continue }
                    switch event {
                    case .inputTokenCount(let count):
                        inputTokens = count
                        continuation.yield(.inputTokenCount(count))
                    case .cachedInputTokenCount(let count):
                        // Prompt tokens restored from the prefix cache (L1/L2/L3 hit): reported as
                        // usage.prompt_tokens_details.cached_tokens on the completion.
                        cachedInputTokens = count
                    case .tokens(let text):
                        continuation.yield(.outputTextDelta(text))
                    case .reasoning(let text):
                        continuation.yield(.reasoningDelta(text))
                    case .prefillProgress(let progress):
                        continuation.yield(.prefillProgress(progress))
                    case .toolCallProgress(let delta):
                        if hasCompletedToolPreview {
                            continuation.yield(.functionPreviewReset)
                            hasCompletedToolPreview = false
                        }
                        continuation.yield(.toolEnvelopeDelta(delta))
                    case .toolInvocation(let name, let arguments):
                        // The native parser has no transport ID. Assign it once
                        // at the parsed-item boundary and reuse it at completion.
                        let call = ResponsesFunctionCall(
                            id: "fc_\(responseID)_\(calls.count)",
                            callID: "call_\(responseID)_\(calls.count)",
                            name: name,
                            arguments: arguments
                        )
                        calls.append(call)
                        hasCompletedToolPreview = true
                        continuation.yield(.functionCallAdded(call))
                    case .completionInfo(let count, let speed, let unclosed, let reason, let prefill, let mtp):
                        let status: ResponsesGenerationCompletion.Status
                        switch reason {
                        case "length": status = .incomplete
                        case "cancelled": status = .cancelled
                        default: status = .completed
                        }
                        completed = true
                        responseCompleted.withLock { $0 = true }
                        continuation.yield(
                            .responseCompleted(
                                ResponsesGenerationCompletion(
                                    responseID: responseID,
                                    status: status,
                                    functionCalls: calls,
                                    tokenCount: count,
                                    tokensPerSecond: speed,
                                    unclosedReasoning: unclosed,
                                    stopReason: reason,
                                    promptTokensPerSecond: prefill,
                                    mtp: mtp,
                                    inputTokenCount: inputTokens,
                                    cachedInputTokenCount: cachedInputTokens
                                )
                            )
                        )
                    }
                }
                await waitForProducerDrain()
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                } else if completed {
                    continuation.yield(.drained)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: StreamError.missingCompletion)
                }
            } catch {
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    await waitForProducerDrain()
                } else if completed {
                    await waitForProducerDrain()
                    continuation.yield(.drainFailed(error.localizedDescription))
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                    await waitForProducerDrain()
                }
            }
        }
        continuation.onTermination = { termination in
            // Closing a completed response to start the next tool step must
            // not abort the previous producer's GPU/cache cleanup.
            if case .cancelled = termination,
                !responseCompleted.withLock({ $0 })
            {
                producer.cancel()
            }
        }
        return stream
    }
}
