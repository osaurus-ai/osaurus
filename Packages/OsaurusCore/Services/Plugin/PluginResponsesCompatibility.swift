import Foundation

/// Legacy plugin ABI projection only. Internal model steps keep the complete
/// Responses result; no transport request is replayed or converted here.
enum PluginResponsesCompatibility {
    enum Failure: Error, LocalizedError {
        case upstreamCancelled
        case incomplete(String?)
        var errorDescription: String? {
            switch self {
            case .upstreamCancelled: return "The upstream model or provider cancelled generation."
            case .incomplete(let reason): return "The model response was incomplete (\(reason ?? "unknown reason"))."
            }
        }
    }

    static func classify(_ result: ResponsesGenerationResult, toolsWereOffered: Bool) throws -> AgentLoopModelStep {
        switch result.completion.status {
        case .cancelled: throw Failure.upstreamCancelled
        case .incomplete:
            if result.completion.stopReason == "length" { return .lengthExhausted }
            throw Failure.incomplete(result.completion.stopReason)
        case .completed: break
        }
        let calls = result.completion.dispatchableFunctionCalls
        if !calls.isEmpty {
            return .toolCalls(calls.map {
                ServiceToolInvocation(
                    toolName: $0.name, jsonArguments: $0.arguments, toolCallId: $0.callID,
                    geminiThoughtSignature: $0.geminiThoughtSignature
                )
            })
        }
        return AgentLoopModelStep.classifyTerminal(
            contentIsBlank: result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            thinkingIsBlank: result.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            stopReason: result.completion.stopReason, unclosedReasoning: result.completion.unclosedReasoning,
            requiresVisibleFinalResponse: true, toolsWereOffered: toolsWereOffered, content: result.text
        )
    }

    /// Sparse runtime metering. Unreported counts/rates are never zero-filled
    /// or replaced with a wall-time estimate.
    static func reportedUsage(_ result: ResponsesGenerationResult) -> [String: Any] {
        var usage: [String: Any] = ["unclosed_reasoning": result.completion.unclosedReasoning]
        if let count = result.inputTokenCount { usage["prompt_tokens"] = count }
        if let count = result.completion.tokenCount { usage["completion_tokens"] = count }
        if let input = result.inputTokenCount, let output = result.completion.tokenCount {
            usage["total_tokens"] = input + output
        }
        if let rate = result.completion.tokensPerSecond { usage["tokens_per_second"] = rate }
        if let rate = result.completion.promptTokensPerSecond { usage["prefill_tokens_per_second"] = rate }
        if let cached = result.completion.cachedInputTokenCount {
            usage["prompt_tokens_details"] = ["cached_tokens": cached]
        }
        return usage
    }

    /// Chat Completions-shaped compatibility response for the existing plugin
    /// ABI. Its usage object is optional; only emit it when both counts exist.
    static func response(
        _ result: ResponsesGenerationResult, model: String, contentOverride: String? = nil
    ) throws -> [String: Any] {
        switch result.completion.status {
        case .cancelled: throw Failure.upstreamCancelled
        case .incomplete: throw Failure.incomplete(result.completion.stopReason)
        case .completed: break
        }
        let message = try contentOverride.map { ChatMessage(role: "assistant", content: $0) }
            ?? result.completedAssistantInput()
        let recorded = SecretArgumentScrubber.recordedAssistantMessage(message)
        let data = try JSONEncoder.osaurusCanonical().encode(recorded)
        let projected = try JSONSerialization.jsonObject(with: data)
        var response: [String: Any] = [
            "id": result.completion.responseID, "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970), "model": model,
            "choices": [[
                "index": 0, "message": projected,
                "finish_reason": contentOverride != nil ? "stop"
                    : (result.completion.dispatchableFunctionCalls.isEmpty ? (result.completion.stopReason ?? "stop") : "tool_calls"),
            ]],
        ]
        let usage = reportedUsage(result)
        response["generation_metrics"] = usage
        if result.inputTokenCount != nil, result.completion.tokenCount != nil { response["usage"] = usage }
        return response
    }
}
