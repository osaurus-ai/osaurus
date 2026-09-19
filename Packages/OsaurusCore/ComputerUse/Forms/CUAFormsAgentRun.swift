import Foundation

struct CUAFormsRunReceipt: Sendable {
    let checkpointSignature: String
    let batches: Int
    let scoredFields: Int
    let appliedFields: Int
    let scoringSeconds: Double

    var payload: [String: Any] {
        [
            "model": "cua-ai/cua-s1-forms", "device": "cpu", "batches": batches,
            "checkpoint_signature": checkpointSignature,
            "scored_fields": scoredFields, "applied_fields": appliedFields, "scoring_seconds": scoringSeconds,
        ]
    }
}

/// One CPU scorer and immutable granted profile per automation run. It is not
/// a language model and never loads another LLM or changes residency policy.
actor CUAFormsAgentRun {
    nonisolated let context: CUAFormsRunContext
    private let store: CUAFormContextStore
    private let executionAllowed: @Sendable () async -> Bool
    private var scorer: CUAFormsScorer?
    private var checkpointSignature: String?
    private var batches = 0
    private var scoredFields = 0
    private var appliedFields = 0
    private var scoringSeconds = 0.0

    init(
        context: CUAFormsRunContext,
        store: CUAFormContextStore = CUAFormContextStore(),
        executionAllowed: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.context = context
        self.store = store
        self.executionAllowed = executionAllowed
    }

    static func resolve(agentID: UUID, kind: String, store: CUAFormContextStore = CUAFormContextStore()) async throws
        -> CUAFormsAgentRun?
    {
        guard let context = try CUAFormsRunContext.resolve(configuration: await store.load(), agentID: agentID) else {
            return nil
        }
        return CUAFormsAgentRun(
            context: context,
            store: store,
            executionAllowed: {
                await MainActor.run {
                    guard let agent = AgentManager.shared.agent(for: agentID), !agent.isBuiltIn, agent.toolsEnabled
                    else { return false }
                    switch kind {
                    case "browser_use": return agent.settings.browserUseEnabled
                    case "computer_use": return agent.settings.computerUseEnabled
                    default: return false
                    }
                }
            }
        )
    }

    func validate() async throws {
        try Task.checkCancellation()
        guard await executionAllowed() else {
            throw CUAFormsError.invalid("This agent's automation permission was revoked.")
        }
        try context.validateCurrent(await store.load())
    }

    func score(elements: [CUElement], title: String, feed: SubagentFeed?) async throws -> [CUAFormDecision] {
        try await validate()
        if scorer == nil {
            scorer = try CUAFormsScorer(directory: URL(fileURLWithPath: context.modelDirectory, isDirectory: true))
        }
        guard let scorer else { throw CUAFormsError.invalid("The form scorer is unavailable.") }
        let scored = try await CUAFormsPlanner.score(
            profile: context.profile,
            elements: elements,
            title: title,
            scorer: scorer
        )
        try await validate()
        batches += 1
        checkpointSignature = await scorer.signature
        scoredFields += elements.count
        scoringSeconds += scored.seconds
        feed?.emit(
            SubagentActivityEvent(
                kind: .perceive,
                title: "CUA S1 Forms · local CPU",
                detail: String(format: "%d fields scored in %.1f ms", elements.count, scored.seconds * 1000),
                success: true
            )
        )
        return scored.decisions
    }

    func recordApplied() { appliedFields += 1 }

    /// Recorded only after real inference, never because a setting is enabled.
    func receipt() -> CUAFormsRunReceipt? {
        guard batches > 0, let checkpointSignature else { return nil }
        return CUAFormsRunReceipt(
            checkpointSignature: checkpointSignature,
            batches: batches,
            scoredFields: scoredFields,
            appliedFields: appliedFields,
            scoringSeconds: scoringSeconds
        )
    }
}
