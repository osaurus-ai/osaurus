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
            responses_output_items: providerOutputItems.isEmpty ? nil : providerOutputItems
        )
    }

    static func collect(
        _ stream: AsyncThrowingStream<ResponsesGenerationEvent, Error>,
        endAt: EndAt = .logicalCompletion
    ) async throws -> ResponsesGenerationResult {
        var text = ""
        var reasoning = ""
        var completion: ResponsesGenerationCompletion?
        var inputTokens: Int?
        var items: [JSONValue] = []
        var reasoningItem: StreamingReasoningItemHint.Item?
        var billing: RouterBillingSummary?
        var artifacts: [RemoteRunArtifact] = []
        var traces: [StreamingAgentToolHint.Trace] = []
        var toolsDone: [StreamingToolHint.ToolCallDone] = []
        var metadata: [String] = []
        var drainStatus: DrainStatus = .notObserved

        func result() throws -> ResponsesGenerationResult {
            guard let completion else { throw CollectionError.missingCompletion }
            return ResponsesGenerationResult(
                text: text,
                reasoning: reasoning,
                completion: completion,
                inputTokenCount: completion.inputTokenCount ?? inputTokens,
                providerOutputItems: items,
                reasoningItem: reasoningItem,
                billing: billing,
                artifacts: artifacts,
                agentToolTraces: traces,
                remoteToolCompletions: toolsDone,
                compatibilityMetadata: metadata,
                drainStatus: drainStatus
            )
        }

        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .inputTokenCount(let count): inputTokens = count
            case .outputTextDelta(let delta):
                guard completion == nil else { throw CollectionError.outputAfterCompletion }
                text += delta
            case .reasoningDelta(let delta):
                guard completion == nil else { throw CollectionError.outputAfterCompletion }
                reasoning += delta
            case .providerOutputItem(let item):
                guard completion == nil else { throw CollectionError.outputAfterCompletion }
                items.append(item)
            case .reasoningItem(let item):
                guard completion == nil else { throw CollectionError.outputAfterCompletion }
                reasoningItem = item
            case .billing(let summary): billing = summary
            case .artifacts(let values): artifacts.append(contentsOf: values)
            case .agentTool(let trace): traces.append(trace)
            case .remoteToolCompleted(let tool): toolsDone.append(tool)
            case .compatibilityMetadata(let raw): metadata.append(raw)
            case .responseCompleted(let value):
                guard completion == nil else { throw CollectionError.duplicateCompletion }
                completion = value
                if case .logicalCompletion = endAt { return try result() }
            case .drained:
                guard completion != nil else { throw CollectionError.drainBeforeCompletion }
                drainStatus = .nativeProducerDrained
            case .compatibilityStreamClosed:
                guard completion != nil else { throw CollectionError.drainBeforeCompletion }
                drainStatus = .compatibilityStreamClosed
            case .drainFailed(let message): throw CollectionError.drainFailed(message)
            case .prefillProgress, .toolEnvelopeDelta, .functionCallAdded, .functionNamePreview,
                .functionPreviewReset, .functionArgumentsPreview:
                break
            }
        }
        try Task.checkCancellation()
        return try result()
    }
}
