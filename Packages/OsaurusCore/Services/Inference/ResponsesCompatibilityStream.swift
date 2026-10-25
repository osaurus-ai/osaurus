import Foundation
import os

extension ResponsesGenerationStream {
    private struct CompatibilityUsage: Sendable {
        var tokenCount: Int?
        var tokensPerSecond: Double?
        var unclosedReasoning = false
        var stopReason: String?
        var prefillTokensPerSecond: Double?
        var inputTokenCount: Int?
        var cachedInputTokenCount: Int?
        var mtp: MTPStatsSummary?
    }

    /// Boundary for an explicitly selected legacy service/provider. This does
    /// not retry a request or choose a second wire protocol after a failure.
    /// Native MLX uses `native` and never passes through this string decoder.
    static func compatibility(
        _ upstream: AsyncThrowingStream<String, Error>,
        responseID: String = "resp_" + UUID().uuidString
    ) -> AsyncThrowingStream<ResponsesGenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ResponsesGenerationEvent, Error>.makeStream()
        let responseCompleted = OSAllocatedUnfairLock(initialState: false)
        let producer = Task {
            var usage = CompatibilityUsage()
            var invocations: [ServiceToolInvocation] = []
            var exhausted = false
            do {
                for try await delta in upstream {
                    if Task.isCancelled { continue }
                    if let count = StreamingInputTokenHint.decode(delta) {
                        usage.inputTokenCount = count
                        continuation.yield(.inputTokenCount(count))
                    } else if let stats = StreamingStatsHint.decode(delta) {
                        usage.tokenCount = stats.tokenCount
                        usage.tokensPerSecond = stats.tokensPerSecond
                        usage.unclosedReasoning = stats.unclosedReasoning
                        usage.stopReason = stats.stopReason
                        usage.prefillTokensPerSecond = stats.prefillTokensPerSecond
                        usage.inputTokenCount = stats.inputTokenCount ?? usage.inputTokenCount
                        usage.cachedInputTokenCount = stats.cachedInputTokenCount
                        usage.mtp = stats.mtp
                    } else if let text = StreamingReasoningHint.decode(delta) {
                        continuation.yield(.reasoningDelta(text))
                    } else if let progress = StreamingPrefillProgressHint.decode(delta) {
                        continuation.yield(.prefillProgress(progress))
                    } else if let progress = StreamingToolCallProgressHint.decode(delta) {
                        continuation.yield(.toolEnvelopeDelta(progress))
                    } else if let item = StreamingResponsesOutputItemHint.decode(delta) {
                        continuation.yield(.providerOutputItem(item))
                    } else if let item = StreamingReasoningItemHint.decode(delta) {
                        continuation.yield(.reasoningItem(item))
                    } else if let billing = StreamingBillingHint.decode(delta) {
                        continuation.yield(.billing(billing))
                    } else if let artifacts = StreamingArtifactHint.decode(delta) {
                        continuation.yield(.artifacts(artifacts))
                    } else if let tool = StreamingAgentToolHint.decode(delta) {
                        continuation.yield(.agentTool(tool))
                    } else if let tool = StreamingToolHint.decodeDone(delta) {
                        continuation.yield(.remoteToolCompleted(tool))
                    } else if let name = StreamingToolHint.decode(delta) {
                        continuation.yield(name.isEmpty ? .functionPreviewReset : .functionNamePreview(name))
                    } else if let args = StreamingToolHint.decodeArgs(delta) {
                        continuation.yield(.functionArgumentsPreview(args))
                    } else if StreamingToolHint.isSentinel(delta) {
                        continuation.yield(.compatibilityMetadata(delta))
                    } else {
                        continuation.yield(.outputTextDelta(delta))
                    }
                }
            } catch let batch as ServiceToolInvocations {
                invocations = batch.invocations
            } catch let call as ServiceToolInvocation {
                invocations = [call]
            } catch is ServiceToolResponseExhausted {
                exhausted = true
            } catch {
                continuation.finish(throwing: error)
                return
            }
            guard !Task.isCancelled else {
                continuation.finish(throwing: CancellationError())
                return
            }
            let calls = invocations.enumerated().map { index, call in
                ResponsesFunctionCall(
                    id: "fc_\(responseID)_\(index)",
                    callID: call.toolCallId ?? "call_\(responseID)_\(index)",
                    name: call.toolName,
                    arguments: call.jsonArguments,
                    geminiThoughtSignature: call.geminiThoughtSignature
                )
            }
            let status: ResponsesGenerationCompletion.Status
            if exhausted || usage.stopReason == "length" {
                status = .incomplete
            } else if usage.stopReason == "cancelled" {
                status = .cancelled
            } else {
                status = .completed
            }
            for call in calls { continuation.yield(.functionCallAdded(call)) }
            responseCompleted.withLock { $0 = true }
            continuation.yield(
                .responseCompleted(
                    ResponsesGenerationCompletion(
                        responseID: responseID,
                        status: status,
                        functionCalls: calls,
                        tokenCount: usage.tokenCount,
                        tokensPerSecond: usage.tokensPerSecond,
                        unclosedReasoning: usage.unclosedReasoning,
                        stopReason: exhausted ? "length" : usage.stopReason,
                        promptTokensPerSecond: usage.prefillTokensPerSecond,
                        mtp: usage.mtp,
                        inputTokenCount: usage.inputTokenCount,
                        cachedInputTokenCount: usage.cachedInputTokenCount
                    )
                )
            )
            // Only this compatibility adapter has drained. Provider-native
            // cache/durability telemetry remains separate from wire EOF.
            continuation.yield(.compatibilityStreamClosed)
            continuation.finish()
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination, !responseCompleted.withLock({ $0 }) {
                producer.cancel()
            }
        }
        return stream
    }
}
