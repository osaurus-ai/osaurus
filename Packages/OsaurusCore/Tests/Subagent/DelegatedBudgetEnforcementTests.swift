//
//  DelegatedBudgetEnforcementTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Full-chain proof that the `DelegatedRunContract` ceilings are ENFORCED
//  by the machinery a dispatched delegated chat actually runs through —
//  not merely stored. The chain under test:
//
//    DispatchRequest (three caps)
//      → ExecutionContext (forms the contract, stamps the session)
//        → ChatSession.delegationBudget
//          → clampedContextWindow → AgentLoopBudget.makeBudgetManager
//            → trimming / `.overBudget` (ContextBudgetManager)
//          → clampedToolAttempts → AgentLoopPolicy.maxIterations
//            → AgentToolLoop `.iterationCapReached`
//          → clampedResponseTokens → per-generation `max_tokens`
//
//  The propagation link (DispatchRequest → session) is pinned in
//  `SubagentAdmission16GBRegressionTests.dispatchCapsPropagateToSession`;
//  this file pins the enforcement links below the session.
//

import Foundation
import Testing
import os

@testable import OsaurusCore

@Suite("Delegated budget enforcement chain")
struct DelegatedBudgetEnforcementTests {

    /// The default tool-enabled contract (2,048 × 2 against 64K) used by
    /// every test — the same shape as the reported 16 GiB configuration.
    private var contract: DelegatedRunContract {
        DelegatedRunContract.derive(
            seedCharacters: 800,
            systemPromptCharacters: 2_000,
            toolSchemaTokens: 375,
            budgets: SubagentBudgets(),
            toolEnabled: true,
            resolvedContextWindow: 65_536
        )!
    }

    private func delegatedBudgetManager(
        _ contract: DelegatedRunContract,
        systemPromptChars: Int = 2_000,
        toolTokens: Int = 500
    ) -> ContextBudgetManager {
        AgentLoopBudget.makeBudgetManager(
            contextWindow: contract.clampedContextWindow(resolved: 65_536),
            systemPromptChars: systemPromptChars,
            toolTokens: toolTokens,
            maxResponseTokens: contract.clampedResponseTokens(agentConfigured: nil)
        )
    }

    // MARK: Context ceiling → budget manager → trimming

    /// The budget manager built from the clamped window has an effective
    /// budget derived from the CONTRACT's ceiling, not the model window,
    /// and trimming brings a tool-bloated transcript back under the
    /// history budget while preserving the system prefix.
    @Test("clamped window bounds the manager and trims tool bloat under it")
    func clampedWindowBoundsManagerAndTrims() {
        let contract = self.contract
        let manager = delegatedBudgetManager(contract)

        // Effective budget reflects the 13,713-position ceiling × the 0.85
        // safety margin — nowhere near the 65,536-window budget.
        #expect(manager.effectiveBudget == Int(Double(13_713) * 0.85))
        #expect(manager.historyBudget < 13_713)

        // A transcript whose OLDER turns carry tool results far past the
        // per-turn allowance (100K chars ≈ 25K tokens each — the universal
        // tool result cap) trims back under the history budget: middle
        // bloat is summarized/dropped while the original task and the
        // recent small tail survive.
        let bigResult = String(repeating: "x", count: 100_000)
        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: "delegated child system prompt"),
            ChatMessage(role: "user", content: "original delegated task"),
        ]
        for i in 0..<3 {
            messages.append(ChatMessage(role: "assistant", content: "step \(i)"))
            messages.append(ChatMessage(role: "tool", content: bigResult))
        }
        for i in 0..<3 {
            messages.append(ChatMessage(role: "user", content: "recent question \(i)"))
            messages.append(ChatMessage(role: "assistant", content: "recent answer \(i)"))
        }

        let result = AgentLoopBudget.trimPreservingSystemPrefixReportingOverflow(
            messages, with: manager)
        #expect(result.overBudget == false)
        #expect(result.messages.first?.role == "system", "system prefix is never trimmed")
        let joined = result.messages.dropFirst().compactMap(\.content).joined()
        #expect(
            ContextBudgetManager.estimateTokens(for: joined) <= manager.historyBudget,
            "trimmed history must fit the contract-derived budget")
        #expect(
            !result.messages.contains { ($0.content?.count ?? 0) >= 100_000 },
            "no over-allowance tool result survives verbatim")

        // The SAME bloat sitting in the PROTECTED recent tail cannot be
        // trimmed away — and the honest outcome is the reported overflow
        // (which the loop turns into `.overBudget` before any model step),
        // never a silently over-ceiling request.
        var recentBloat: [ChatMessage] = [
            ChatMessage(role: "system", content: "delegated child system prompt")
        ]
        for i in 0..<4 {
            recentBloat.append(ChatMessage(role: "user", content: "step \(i)"))
            recentBloat.append(ChatMessage(role: "tool", content: bigResult))
        }
        recentBloat.append(ChatMessage(role: "user", content: "final question"))
        let bloated = AgentLoopBudget.trimPreservingSystemPrefixReportingOverflow(
            recentBloat, with: manager)
        #expect(bloated.overBudget == true, "protected-tail overrun must be REPORTED")
    }

    /// A system prompt larger than the contract's MEASURED reservation
    /// (derivation saw 2,000 chars; the live composition grew) does not
    /// silently blow the ceiling — the manager absorbs it as a reservation
    /// and the history budget shrinks instead, so the priced position
    /// ceiling still holds.
    @Test("system prompt beyond the measured reservation shrinks history, never the ceiling")
    func oversizedSystemPromptShrinksHistoryBudget() {
        let contract = self.contract
        let modest = delegatedBudgetManager(contract, systemPromptChars: 2_000)
        // 40,000 chars ≈ 10,000 tokens — 20× the measured 2,000-char prompt.
        let huge = delegatedBudgetManager(contract, systemPromptChars: 40_000)
        #expect(huge.effectiveBudget == modest.effectiveBudget, "ceiling is fixed")
        #expect(huge.historyBudget < modest.historyBudget, "overrun comes out of history")
    }

    // MARK: Context ceiling → loop `.overBudget` before any model step

    /// A transcript that cannot fit even fully compacted ends the run with
    /// `.overBudget` BEFORE the model step: zero model calls, zero charged
    /// iterations. This is the "no model step runs after overflow" proof.
    @Test("unfittable transcript exits overBudget with no model step")
    func overBudgetExitsBeforeModelStep() async throws {
        let contract = self.contract
        let manager = delegatedBudgetManager(contract)

        // One un-droppable user message bigger than the whole history
        // budget: trimming keeps the current query, so overBudget reports.
        let giant = String(repeating: "y", count: manager.historyBudget * 8)
        let messages = [
            ChatMessage(role: "system", content: "sys"),
            ChatMessage(role: "user", content: giant),
        ]

        let modelSteps = ModelStepCounter()
        let hooks = AgentLoopHooks(
            isCancelled: { false },
            buildMessages: { notices in
                AgentLoopBudget.composeIterationMessages(
                    messages, notices: notices, manager: manager)
            },
            modelStep: { _, _ in
                modelSteps.count.withLock { $0 += 1 }
                return .finalResponse
            },
            prepareIncompleteReasoningContinuation: {},
            willProcessCall: { _, _ in },
            onDedupedResult: { _, _, _ in },
            executeTool: { inv, _ in
                AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: inv.toolName, text: "ok"))
            },
            onBatchComplete: { _ in }
        )

        let result = try await AgentToolLoop.run(
            policy: AgentLoopPolicy(
                maxIterations: contract.clampedToolAttempts(surfaceConfigured: 15),
                stopOnToolRejection: true,
                dedupeNoticeEnabled: true
            ),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result.exit == .overBudget)
        #expect(result.iterations == 0, "the doomed build charges no iteration")
        #expect(modelSteps.count.withLock { $0 } == 0, "NO model step after overflow")
    }

    // MARK: Turn ceiling → loop `.iterationCapReached`

    /// The contract's turn ceiling, fed through `clampedToolAttempts` into
    /// `AgentLoopPolicy.maxIterations`, ends a tool-hungry run at exactly
    /// the contract's turns — the surface's 15-attempt default never runs.
    @Test("contract turn ceiling caps the loop at its iterations")
    func turnCeilingCapsLoopIterations() async throws {
        let contract = self.contract
        #expect(contract.clampedToolAttempts(surfaceConfigured: 15) == 2)

        let modelSteps = ModelStepCounter()
        let hooks = AgentLoopHooks(
            isCancelled: { false },
            buildMessages: { _ in
                AgentLoopIterationInput(
                    messages: [ChatMessage(role: "user", content: "task")],
                    overBudget: false
                )
            },
            modelStep: { _, _ in
                modelSteps.count.withLock { $0 += 1 }
                // Always ask for another tool — an unbounded appetite.
                return .toolCalls([
                    ServiceToolInvocation(
                        toolName: "probe", jsonArguments: "{}", toolCallId: nil)
                ])
            },
            prepareIncompleteReasoningContinuation: {},
            willProcessCall: { _, _ in },
            onDedupedResult: { _, _, _ in },
            executeTool: { inv, _ in
                AgentLoopToolExecution(
                    result: ToolEnvelope.success(tool: inv.toolName, text: "ok"))
            },
            onBatchComplete: { _ in }
        )

        let result = try await AgentToolLoop.run(
            policy: AgentLoopPolicy(
                maxIterations: contract.clampedToolAttempts(surfaceConfigured: 15),
                stopOnToolRejection: true,
                dedupeNoticeEnabled: true
            ),
            state: AgentTaskState(),
            hooks: hooks
        )

        #expect(result.exit == .iterationCapReached)
        #expect(result.iterations == 2)
        #expect(modelSteps.count.withLock { $0 } == 2, "no model step past the cap")
    }

    // MARK: Response ceiling → capped reservation

    /// The clamped response tokens flow into the same
    /// `cappedResponseReservation` the send gate uses — the contract's
    /// 2,048 replaces the default 4,096 reservation, and an agent already
    /// configured lower keeps its own value.
    @Test("contract response ceiling drives the response reservation")
    func responseCeilingDrivesReservation() {
        let contract = self.contract
        let window = contract.clampedContextWindow(resolved: 65_536)
        let effectiveBudget = Int(Double(window) * ContextBudgetManager.safetyMargin)

        let reservation = AgentLoopBudget.cappedResponseReservation(
            contract.clampedResponseTokens(agentConfigured: nil),
            effectiveBudget: effectiveBudget
        )
        #expect(reservation == 2_048)

        let agentTighter = AgentLoopBudget.cappedResponseReservation(
            contract.clampedResponseTokens(agentConfigured: 1_024),
            effectiveBudget: effectiveBudget
        )
        #expect(agentTighter == 1_024)
    }
}

private final class ModelStepCounter: Sendable {
    let count = OSAllocatedUnfairLock(initialState: 0)
}
