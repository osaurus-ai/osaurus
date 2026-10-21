//
//  PhoneContextUsage.swift
//  osaurus
//
//  The chat composer's context ring for a phone chat (MOBILE_PROTOCOL
//  §14.13): the same breakdown and budget math the Mac's own chip runs
//  (`FloatingInputCard.contextBudget`), priced for the next send from the
//  saved session, the agent's composed prompt and tools, and its memory.
//  Typing and attachments aren't counted: the phone hasn't sent them.
//

import Foundation

@MainActor
enum PhoneContextUsage {

    struct Response: Encodable, Equatable {
        /// Estimated tokens the next send occupies.
        let tokens: Int
        /// The effective budget the runtime trims against (window × safety
        /// margin): the ring's denominator. Nil when the window is unknown.
        let usable_tokens: Int?
        /// The model's full context window.
        let max_tokens: Int?
        /// `tokens` over `usable_tokens`; nil when the window is unknown.
        let ratio: Double?
        /// At or past 85% of the budget: older messages will be compacted.
        let near_limit: Bool
        /// The prompt, tools and memory alone don't fit the window.
        let hard_overflow: Bool
    }

    static func compute(sessionId: UUID?, agentId: UUID, model: String?) async -> Response {
        var turns: [ChatTurn] = []
        var summary: ConversationSummary?
        if let sessionId, let data = await ChatSessionStore.loadAsync(id: sessionId) {
            turns = data.turns.map(ChatTurn.init(from:))
            summary = data.conversationSummary.flatMap {
                ContextCompactionService.summaryIsValid($0, for: turns) ? $0 : nil
            }
        }
        // With a compaction summary the model sees it instead of the turns it covers.
        let covered = Set(summary?.coveredTurnIds ?? [])
        let visible = covered.isEmpty ? turns : turns.filter { !covered.contains($0.id) }
        let outputTokens = ContextBudgetManager.estimateOutputTokens(for: visible)
        let conversationTokens = ContextBudgetManager.estimateTokens(for: visible) - outputTokens

        let model = model ?? AgentManager.shared.effectiveModel(for: agentId)
        let context = SystemPromptComposer.composePreviewContext(
            agentId: agentId,
            executionMode: executionMode(for: agentId),
            model: model
        )
        var breakdown = ContextBreakdown.from(
            manifest: context.manifest,
            toolTokens: context.toolTokens,
            memoryTokens: await memoryTokens(for: agentId),
            conversationTokens: conversationTokens,
            outputTokens: outputTokens
        )
        if let summary {
            breakdown.setTokens(
                for: "summary",
                in: \.messages,
                tokens: ContextBudgetManager.estimateTokens(for: summary.contextMessageText),
                label: L("Summary"),
                tint: .teal
            )
        }

        let window = model.map { AgentLoopBudget.resolveContextWindowResolutionSync(modelId: $0).tokens }
        let assessment =
            window.map {
                AgentLoopBudget.assess(
                    breakdown: breakdown,
                    contextWindow: $0,
                    maxResponseTokens: AgentManager.shared.effectiveMaxTokens(for: agentId)
                )
            } ?? .empty
        return Response(
            tokens: breakdown.total,
            usable_tokens: window.map { ContextBudgetManager(contextLength: $0).effectiveBudget },
            max_tokens: window,
            ratio: assessment.usageRatio,
            near_limit: assessment.nearLimit,
            hard_overflow: assessment.hardOverflow
        )
    }

    /// As a phone run resolves it: no host folder, and sandbox when
    /// autonomous is on even before its tools register (as the chip does).
    private static func executionMode(for agentId: UUID) -> ExecutionMode {
        let autonomous = AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
        let resolved = ToolRegistry.shared.resolveExecutionMode(folderContext: nil, autonomousEnabled: autonomous)
        if autonomous && !resolved.usesSandboxTools { return .sandbox(hostRead: nil, hostWrite: false) }
        return resolved
    }

    /// The memory snippet the next send would carry, as the chip prices it.
    private static func memoryTokens(for agentId: UUID) async -> Int {
        guard !AgentManager.shared.effectiveMemoryDisabled(for: agentId) else { return 0 }
        let context = await MemoryContextAssembler.assembleContext(
            agentId: agentId.uuidString,
            config: MemoryConfigurationStore.load()
        )
        return ContextBudgetManager.estimateTokens(for: context)
    }
}
