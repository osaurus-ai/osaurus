import Foundation

/// Shared ordered event reducer for one-shot and streaming callers. It never
/// executes previews; callers classify the complete terminal response.
struct ResponsesGenerationAccumulator: Sendable {
    private typealias CollectionError = ResponsesGenerationResult.CollectionError
    private typealias DrainStatus = ResponsesGenerationResult.DrainStatus
    init() {}
    var text = ""
    var reasoning = ""
    var completion: ResponsesGenerationCompletion?
    var inputTokens: Int?
    var items: [JSONValue] = []
    var reasoningItem: StreamingReasoningItemHint.Item?
    var anthropicThinkingBlocks: [JSONValue] = []
    var billing: RouterBillingSummary?
    var artifacts: [RemoteRunArtifact] = []
    var traces: [StreamingAgentToolHint.Trace] = []
    var toolsDone: [StreamingToolHint.ToolCallDone] = []
    var metadata: [String] = []
    private var drainStatus: DrainStatus = .notObserved

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
            drainStatus: drainStatus,
            anthropicThinkingBlocks: anthropicThinkingBlocks
        )
    }

    mutating func consume(_ event: ResponsesGenerationEvent) throws {
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
        case .anthropicThinkingBlock(let block):
            guard completion == nil else { throw CollectionError.outputAfterCompletion }
            anthropicThinkingBlocks.append(block)
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
        case .drained:
            guard completion != nil else { throw CollectionError.drainBeforeCompletion }
            drainStatus = .nativeProducerDrained
        case .compatibilityStreamClosed:
            guard completion != nil else { throw CollectionError.drainBeforeCompletion }
            drainStatus = .compatibilityStreamClosed
        case .drainFailed(let message): throw CollectionError.drainFailed(message)
        case .providerEvent, .prefillProgress, .toolEnvelopeDelta, .functionCallAdded, .functionNamePreview,
            .functionPreviewReset, .functionArgumentsPreview:
            break
        }
    }
}
