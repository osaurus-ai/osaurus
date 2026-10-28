import Foundation
import os

/// One desktop step owns one observed action. A model batch cannot be reduced
/// to its first call: later actions may require a new captured view or policy
/// decision before they are safe to propose, so unsupported batches fail before
/// any desktop side effect.
enum DesktopResponsesModelStep {
    enum Failure: Error, LocalizedError, Sendable {
        case upstreamCancelled
        case incomplete(String?)
        case unsupportedCalls(expected: String, names: [String])
        case missingCallID
        case missingVisibleAnswer
        case missingRequiredCall(String)

        var errorDescription: String? {
            switch self {
            case .upstreamCancelled:
                return "The upstream model or provider cancelled the desktop model step."
            case .incomplete(let reason):
                return "The desktop model response was incomplete (\(reason ?? "unknown reason"))."
            case .unsupportedCalls(let expected, let names):
                return "This desktop step requires one '\(expected)' call; received \(names.count) call(s): \(names.joined(separator: ", ")). No action was executed."
            case .missingCallID:
                return "The desktop model call has no call ID. No action was executed."
            case .missingVisibleAnswer:
                return "The desktop model ended without an action or visible answer."
            case .missingRequiredCall(let name):
                return "The model did not produce the required '\(name)' call."
            }
        }
    }

    /// Keep the complete typed response available to diagnostics even when its
    /// action shape cannot be executed. The user-facing error reveals only the
    /// reason, not opaque provider payloads.
    struct InvalidResponse: Error, LocalizedError, Sendable {
        let reason: Failure
        let response: ResponsesGenerationResult
        var errorDescription: String? { reason.errorDescription }
    }

    /// Collect through logical completion while observing whether retry would
    /// replay any generated output. The native producer still owns its drain.
    static func completeResponse(
        engine: any ResponsesEngineProtocol,
        request: ResponsesInferenceRequest,
        attempt: DesktopResponsesAttempt?
    ) async throws -> ResponsesGenerationResult {
        let stream = try await engine.streamResponses(request: request)
        var accumulator = ResponsesGenerationAccumulator()
        for try await event in stream {
            try Task.checkCancellation()
            attempt?.observe(event)
            try accumulator.consume(event)
            if case .responseCompleted = event { return try accumulator.result() }
        }
        try Task.checkCancellation()
        return try accumulator.result()
    }

    static func actionCall(
        from result: ResponsesGenerationResult,
        expectedTool: String,
        required: Bool
    ) throws -> ModelActionCall? {
        switch result.completion.status {
        case .cancelled: throw InvalidResponse(reason: .upstreamCancelled, response: result)
        case .incomplete: throw InvalidResponse(reason: .incomplete(result.completion.stopReason), response: result)
        case .completed: break
        }
        guard !result.completion.unclosedReasoning, result.completion.stopReason != "length" else {
            throw InvalidResponse(reason: .incomplete(result.completion.stopReason), response: result)
        }
        let calls = result.completion.functionCalls
        if calls.isEmpty {
            if required {
                // Preserve the required/named-tool contract used by the native
                // runtime and the Computer Use loop's bounded protocol path.
                throw NSError(domain: "OsaurusToolChoice", code: 422, userInfo: [
                    NSLocalizedDescriptionKey: "The model did not produce the required '\(expectedTool)' call.",
                    NSUnderlyingErrorKey: InvalidResponse(reason: .missingRequiredCall(expectedTool), response: result)
                ])
            }
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw InvalidResponse(reason: .missingVisibleAnswer, response: result)
            }
            return nil
        }
        guard calls.count == 1, calls[0].name == expectedTool else {
            throw InvalidResponse(reason: .unsupportedCalls(expected: expectedTool, names: calls.map(\.name)), response: result)
        }
        guard !calls[0].callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InvalidResponse(reason: .missingCallID, response: result)
        }
        return ModelActionCall(id: calls[0].callID, arguments: calls[0].arguments)
    }
}

/// Retry scope is one model step, before any desktop action. Once output or a
/// terminal event arrives, neither a transport error nor a timeout can replay
/// that attempt. Authentication, model, rate, protocol and incomplete errors
/// are not transport retries.
final class DesktopResponsesAttempt: Sendable {
    private let outputObserved = OSAllocatedUnfairLock(initialState: false)

    func observe(_ event: ResponsesGenerationEvent) {
        let output: Bool
        switch event {
        case .providerEvent, .providerOutputItem, .anthropicThinkingBlock, .reasoningItem, .responseCompleted:
            output = true
        default:
            output = event.isGeneratedOutput
        }
        if output { outputObserved.withLock { $0 = true } }
    }

    func permitsRetry(_ error: Error, isTimeout: Bool = false) -> Bool {
        guard !outputObserved.withLock({ $0 }), !(error is CancellationError) else { return false }
        if isTimeout { return true }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
        ].contains(nsError.code)
    }
}
