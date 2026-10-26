import Foundation

/// Shared typed collection/classification for evaluation drivers. Evaluation
/// results keep the same terminal and item boundaries as production callers;
/// fixtures and explicit judge/benchmark settings remain named at their callsite.
@MainActor
enum ResponsesEvaluationStep {
    enum Failure: Error, LocalizedError {
        case upstreamCancelled
        case incomplete(String?)
        case invalidCallIDs
        var errorDescription: String? {
            switch self {
            case .upstreamCancelled: return "The upstream model or provider cancelled the evaluation step."
            case .incomplete(let reason): return "The evaluation response was incomplete (\(reason ?? "unknown reason"))."
            case .invalidCallIDs: return "The evaluation response contains missing or duplicate tool-call identities."
            }
        }
    }

    static func collect(
        engine: any ResponsesEngineProtocol,
        request: ResponsesInferenceRequest,
        endAt: ResponsesGenerationResult.EndAt = .logicalCompletion,
        observe: ((ResponsesGenerationEvent) -> Void)? = nil
    ) async throws -> ResponsesGenerationResult {
        let stream = try await engine.streamResponses(request: request)
        var accumulator = ResponsesGenerationAccumulator()
        for try await event in stream {
            try Task.checkCancellation()
            observe?(event)
            try accumulator.consume(event)
            if case .responseCompleted = event, case .logicalCompletion = endAt {
                return try accumulator.result()
            }
        }
        try Task.checkCancellation()
        return try accumulator.result()
    }

    static func classify(
        _ response: ResponsesGenerationResult,
        toolsWereOffered: Bool
    ) throws -> AgentLoopModelStep {
        switch response.completion.status {
        case .cancelled: throw Failure.upstreamCancelled
        case .incomplete:
            if response.completion.stopReason == "length" { return .lengthExhausted }
            throw Failure.incomplete(response.completion.stopReason)
        case .completed: break
        }
        if response.completion.stopReason == "length" { return .lengthExhausted }
        if response.completion.unclosedReasoning { return .incompleteReasoning }
        let calls = response.completion.functionCalls
        if !calls.isEmpty {
            let ids = calls.map(\.callID)
            guard ids.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                Set(ids).count == ids.count
            else { throw Failure.invalidCallIDs }
            return .toolCalls(calls.map {
                ServiceToolInvocation(
                    toolName: $0.name, jsonArguments: $0.arguments,
                    toolCallId: $0.callID, geminiThoughtSignature: $0.geminiThoughtSignature
                )
            })
        }
        return AgentLoopModelStep.classifyTerminal(
            contentIsBlank: response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            thinkingIsBlank: response.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            stopReason: response.completion.stopReason,
            unclosedReasoning: response.completion.unclosedReasoning,
            requiresVisibleFinalResponse: true, toolsWereOffered: toolsWereOffered,
            content: response.text
        )
    }

    static func requireNaturalFinal(_ response: ResponsesGenerationResult) throws {
        switch response.completion.status {
        case .cancelled: throw Failure.upstreamCancelled
        case .incomplete: throw Failure.incomplete(response.completion.stopReason)
        case .completed: break
        }
        guard response.completion.stopReason != "length", !response.completion.unclosedReasoning,
            response.completion.functionCalls.isEmpty,
            !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw Failure.incomplete(response.completion.stopReason) }
    }
}
