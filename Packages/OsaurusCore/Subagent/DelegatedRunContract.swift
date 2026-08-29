//
//  DelegatedRunContract.swift
//  osaurus
//
//  The concrete, ENFORCED execution contract of a delegated spawn
//  (`spawn_agent` → `runDelegated` → a real chat session of the target
//  agent). Historically the launcher's `SubagentBudgets` were display
//  values on this path — the dispatched chat loop ignored them — so RAM
//  admission had nothing bounded to price and fell back to the model-wide
//  KV retention cap. On a 16 GB Mac that cap-priced charge alone turned an
//  affordable same-resident-model child into `ramSlots == 0`.
//
//  This type is the single source of truth for both sides of the fix:
//  - ENFORCEMENT: `runDelegated` hands these values to the dispatched
//    session (`ChatSession.delegationBudget`), which clamps its
//    per-generation max tokens to `responseTokens`, its tool-loop attempts
//    to `assistantTurns`, and its budget-manager context window to
//    `contextPositions` (history is trimmed to that window on every
//    request, so the position ceiling holds even when tool results grow
//    the transcript).
//  - PRICING: `TextSubagentKind.admissionRequestEstimate()` prices the
//    child at exactly `contextPositions` — the same number the session
//    enforces, so admission cost can never drift from the run's reality.
//

import Foundation

public struct DelegatedRunContract: Sendable, Equatable {
    /// Per-generation `max_tokens` ceiling (tightens the target agent's own
    /// setting; never raises it).
    public let responseTokens: Int
    /// Tool-loop attempt ceiling (tightens `maxToolAttempts`).
    public let assistantTurns: Int
    /// Context-window position ceiling the dispatched session's budget
    /// manager trims to. This is the number admission prices.
    public let contextPositions: Int

    /// Wrapper allowance absorbed into every contract for the child's system
    /// prompt, chat-template scaffolding, and tool schemas. This is a
    /// CONSERVATIVE POLICY VALUE, not a measured size — chosen to match the
    /// 4,096-token floor `SubagentChildRequestEstimate` has always priced
    /// for small requests. A composed prompt larger than this allowance is
    /// not silently exceeded: the enforced window trims history, and a
    /// prompt that cannot fit at all surfaces the loop's over-budget exit
    /// instead of running an unpriced model step.
    public static let promptOverheadTokens = 4_096

    /// Per-turn context allowance for appended tool results when the target
    /// agent runs with tools. Also a CONSERVATIVE POLICY VALUE (one
    /// canonical response reservation per turn, mirroring
    /// `AgentLoopBudget.defaultResponseReservation`), not a measured tool
    /// output size: a bounded delegation is budgeted for tool results the
    /// size of a full response each turn; anything larger is trimmed by the
    /// enforced window or ends in the over-budget exit — never silently
    /// charged past the priced ceiling.
    public static let toolResultAllowancePerTurn = 4_096

    public init(responseTokens: Int, assistantTurns: Int, contextPositions: Int) {
        self.responseTokens = responseTokens
        self.assistantTurns = assistantTurns
        self.contextPositions = contextPositions
    }

    // MARK: - Enforcement clamps (tighten-only)
    //
    // The dispatched chat surface applies these three at the exact points
    // the corresponding limits are decided. Each only ever TIGHTENS the
    // surface's own value — a target agent configured below the contract
    // keeps its smaller setting; the contract can never raise a limit.

    /// Per-generation `max_tokens`: the tighter of the target agent's own
    /// configured value and the contract's response ceiling.
    public func clampedResponseTokens(agentConfigured: Int?) -> Int {
        min(agentConfigured ?? responseTokens, responseTokens)
    }

    /// Tool-loop attempt ceiling: the tighter of the surface's configured
    /// `maxToolAttempts` and the contract's turn ceiling, floored at one
    /// attempt so a run can always take its first model step.
    public func clampedToolAttempts(surfaceConfigured: Int) -> Int {
        max(1, min(surfaceConfigured, assistantTurns))
    }

    /// Budget-manager context window: the tighter of the resolved window
    /// and the contract's position ceiling. History is trimmed to this on
    /// every request, so the ceiling holds even when tool results grow the
    /// transcript; a transcript that cannot fit at all ends the run with
    /// the loop's `.overBudget` exit before any model step.
    public func clampedContextWindow(resolved: Int) -> Int {
        min(resolved, contextPositions)
    }

    /// Derive the contract from the launcher's (normalized) budgets, the
    /// delegation seed, whether the target agent runs with tools, and the
    /// context window the dispatched session would otherwise resolve
    /// (`AgentLoopBudget.resolveContextWindow`: bundle window ∩ the user's
    /// context-length cap). The derived position ceiling only ever TIGHTENS
    /// that resolved window. Seed token math rounds UP (chars/4 × 1.5
    /// safety = chars × 3 / 8, ceiling) — the same conversion
    /// `SubagentChildRequestEstimate` uses.
    ///
    /// Every arithmetic step is overflow-checked and the derivation FAILS
    /// CLOSED: nil means "no bounded contract" — the caller keeps the
    /// conservative model-wide cap pricing and applies no session clamps,
    /// never a partially-computed or wrapped bound.
    public static func derive(
        seedCharacters: Int,
        budgets: SubagentBudgets,
        toolEnabled: Bool,
        resolvedContextWindow: Int
    ) -> DelegatedRunContract? {
        guard resolvedContextWindow > 0 else { return nil }
        let normalized = budgets.normalized
        guard normalized.maxDelegateTokens > 0 else { return nil }
        let turns = max(1, normalized.maxDelegateTurns)

        // ceil(seedCharacters × 3 / 8), overflow-checked.
        let (seedTimes3, seedMulOverflow) = max(0, seedCharacters)
            .multipliedReportingOverflow(by: 3)
        guard !seedMulOverflow else { return nil }
        let (seedNumerator, seedAddOverflow) = seedTimes3.addingReportingOverflow(7)
        guard !seedAddOverflow else { return nil }
        let seedTokens = seedNumerator / 8

        let (perTurn, perTurnOverflow) = normalized.maxDelegateTokens
            .addingReportingOverflow(toolEnabled ? toolResultAllowancePerTurn : 0)
        guard !perTurnOverflow else { return nil }
        let (turnBudget, turnMulOverflow) = perTurn.multipliedReportingOverflow(by: turns)
        guard !turnMulOverflow else { return nil }
        let (withOverhead, overheadOverflow) = turnBudget
            .addingReportingOverflow(promptOverheadTokens)
        guard !overheadOverflow else { return nil }
        let (requested, requestOverflow) = withOverhead
            .addingReportingOverflow(seedTokens)
        guard !requestOverflow else { return nil }

        return DelegatedRunContract(
            responseTokens: normalized.maxDelegateTokens,
            assistantTurns: turns,
            contextPositions: min(requested, resolvedContextWindow)
        )
    }
}
