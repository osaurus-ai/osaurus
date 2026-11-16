import Foundation

/// Lossless one-shot aggregation of the internal typed stream. Collection is
/// separate from provider wire encoding and from execution of any returned call.
struct ResponsesGenerationResult: Sendable {
    enum EndAt: Sendable {
        case logicalCompletion
        case streamEnd
    }

    enum DrainStatus: Sendable {
        case notObserved
        case nativeProducerDrained
        case compatibilityStreamClosed
    }

    enum CollectionError: Error {
        case missingCompletion
        case duplicateCompletion
        case outputAfterCompletion
        case incomplete(String?)
        case drainFailed(String)
        case drainBeforeCompletion
    }

    let text: String
    let reasoning: String
    let completion: ResponsesGenerationCompletion
    let inputTokenCount: Int?
    let providerOutputItems: [JSONValue]
    let reasoningItem: StreamingReasoningItemHint.Item?
    let billing: RouterBillingSummary?
    let artifacts: [RemoteRunArtifact]
    let agentToolTraces: [StreamingAgentToolHint.Trace]
    let remoteToolCompletions: [StreamingToolHint.ToolCallDone]
    let compatibilityMetadata: [String]
    let drainStatus: DrainStatus
    var anthropicThinkingBlocks: [JSONValue] = []

    /// Rendering input for the next model step. Preserve native reasoning,
    /// original provider Items and IDs; an incomplete response is not silently
    /// promoted into executable tool history.
    func completedAssistantInput() throws -> ChatMessage {
        switch completion.status {
        case .cancelled: throw CancellationError()
        case .incomplete: throw CollectionError.incomplete(completion.stopReason)
        case .completed: break
        }
        let calls = completion.functionCalls.map { call in
            ToolCall(
                id: call.callID,
                type: "function",
                function: ToolCallFunction(name: call.name, arguments: call.arguments),
                geminiThoughtSignature: call.geminiThoughtSignature
            )
        }
        return ChatMessage(
            role: "assistant",
            content: text.isEmpty && !calls.isEmpty ? nil : text,
            tool_calls: calls.isEmpty ? nil : calls,
            tool_call_id: nil,
            reasoning_content: reasoning.isEmpty ? nil : reasoning,
            reasoning_item_id: reasoningItem?.id,
            reasoning_encrypted: reasoningItem?.encryptedContent,
            responses_output_items: providerOutputItems.isEmpty ? nil : providerOutputItems,
            anthropic_thinking_blocks: anthropicThinkingBlocks.isEmpty ? nil : anthropicThinkingBlocks
        )
    }

    static func collect(
        _ stream: AsyncThrowingStream<ResponsesGenerationEvent, Error>,
        endAt: EndAt = .logicalCompletion
    ) async throws -> ResponsesGenerationResult {
        var accumulator = ResponsesGenerationAccumulator()
        for try await event in stream {
            try Task.checkCancellation()
            try accumulator.consume(event)
            if case .responseCompleted = event, case .logicalCompletion = endAt {
                return try accumulator.result()
            }
        }
        try Task.checkCancellation()
        return try accumulator.result()
    }
}
