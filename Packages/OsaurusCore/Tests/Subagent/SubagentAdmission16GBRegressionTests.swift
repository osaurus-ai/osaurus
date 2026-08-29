//
//  SubagentAdmission16GBRegressionTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Deterministic regressions for the 16 GB same-resident-model spawn
//  rejection (osaurus 0.24.1 report): admission priced every child at the
//  model-wide KV retention envelope, so a single bounded 2,048-token
//  delegation against the ALREADY-RESIDENT parent model computed
//  ramSlots == 0 even though its actual incremental state fits easily.
//  The fix prices a child from its bounded request (seed + max output,
//  clamped to policy) when the request is known, and never above the
//  conservative cap-priced estimate. RAM safety is ON in every scenario
//  here — nothing bypasses the gate; genuinely unsafe children still fail.
//
//  Scenario constants model the report: 16 GiB physical memory, parent and
//  child use the identical canonical Gemma E2B bundle (~3 GiB effective
//  footprint), RAM safety on, handoff on, coexistence off. With the E2B
//  architecture and a 64K retention cap the cap-priced per-child estimate
//  lands in the multi-GiB range; the bounded 2K-output estimate is a few
//  hundred MiB. Free memory after the resident parent is ~6 GiB and the
//  fixed OS reserve is 3 GiB.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("16 GiB same-resident-model spawn admission")
struct SubagentAdmission16GBRegressionTests {
    private let gib: UInt64 = 1 << 30
    private let mib: UInt64 = 1 << 20

    /// Facts shaped like the 16 GiB report: Gemma E2B resident, ~6 GiB
    /// reclaimable, 3 GiB OS reserve, no releasable parent (same-model
    /// spawns run in place and unload nothing).
    private func sixteenGBFacts(
        capPricedChildBytes: UInt64,
        boundedChildBytes: UInt64?
    ) -> SubagentBatchMemoryFacts {
        SubagentBatchMemoryFacts(
            canonicalModelKey: "osaurusai/gemma-4-e2b-it-qat",
            targetAlreadyResident: true,
            targetLoadFootprintBytes: 3 * gib,
            perActiveChildHeadroomBytes: capPricedChildBytes,
            requestBoundedChildHeadroomBytes: boundedChildBytes,
            reclaimableBytes: 6 * gib,
            releasableParentBytes: 0,
            resolvedLoadBudgetBytes: 13 * gib,
            osHeadroomBytes: 3 * gib
        )
    }

    private func input(
        local: Int,
        memory: SubagentBatchMemoryFacts
    ) -> SubagentBatchAdmissionInput {
        SubagentBatchAdmissionInput(
            localJobCount: local,
            remoteJobCount: 0,
            agentParallelLimit: 3,
            engineParallelLimit: 3,
            continuousBatchingEnabled: true,
            ramSafetyEnabled: true,
            failClosedWhenEstimateUnknown: true,
            memory: memory
        )
    }

    /// The REPORTED failure, unfixed shape: cap-priced 4 GiB per child
    /// against (6 GiB reclaimable − 3 GiB OS reserve) = 3 GiB residual →
    /// zero slots → the exact rejection, even for ONE child.
    @Test("cap-priced child yields ramSlots=0 on 16GiB — the reported defect shape")
    func capPricedChildIsRejected() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 1,
                memory: sixteenGBFacts(
                    capPricedChildBytes: 4 * gib,
                    boundedChildBytes: nil
                )
            )
        )
        guard case .rejected(let reason) = plan.verdict else {
            Issue.record("expected rejection, got \(plan.verdict)")
            return
        }
        #expect(reason == .insufficientMemory)
        #expect(plan.ramSlots == 0)
    }

    /// The fix: the same machine and model, but the child is priced from
    /// its bounded request (2,048-token output ⇒ a few hundred MiB) — one
    /// child is admitted.
    @Test("request-bounded single child is admitted on 16GiB")
    func boundedSingleChildAdmitted() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 1,
                memory: sixteenGBFacts(
                    capPricedChildBytes: 4 * gib,
                    boundedChildBytes: 400 * mib
                )
            )
        )
        #expect(plan.verdict == .admitted)
        #expect(plan.localParallelism == 1)
        #expect(plan.incrementalWeightChargeBytes == 0, "resident weights charged once, not twice")
        #expect(plan.perActiveChildHeadroomBytes == 400 * mib)
    }

    /// Two/three bounded children split into safe waves when the residual
    /// only affords part of the batch at once.
    @Test("two and three bounded children split into safe waves")
    func boundedWavesSplitSafely() {
        // Residual = 6 − 3 = 3 GiB; at 1.4 GiB per bounded child → 2 slots.
        let facts = sixteenGBFacts(
            capPricedChildBytes: 4 * gib,
            boundedChildBytes: 1400 * mib
        )
        let two = SubagentBatchAdmissionPlanner.plan(input(local: 2, memory: facts))
        #expect(two.verdict == .admitted)
        #expect(two.localParallelism == 2)
        #expect(two.localSubwaveSizes == [2])

        let three = SubagentBatchAdmissionPlanner.plan(input(local: 3, memory: facts))
        #expect(three.verdict == .admitted)
        #expect(three.localParallelism == 2)
        #expect(three.localSubwaveSizes == [2, 1], "third child waits for a free slot")
    }

    /// A genuinely unsafe single child still fails closed: even the
    /// bounded request cannot fit the residual.
    @Test("genuinely insufficient bounded child remains rejected")
    func genuinelyInsufficientStillRejected() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 1,
                memory: sixteenGBFacts(
                    capPricedChildBytes: 6 * gib,
                    boundedChildBytes: 5 * gib
                )
            )
        )
        guard case .rejected(let reason) = plan.verdict else {
            Issue.record("expected rejection, got \(plan.verdict)")
            return
        }
        #expect(reason == .insufficientMemory)
    }

    /// A bounded estimate can only SHRINK the charge: if a caller ever
    /// supplies a bounded value above the cap-priced envelope, the
    /// conservative value wins.
    @Test("bounded estimate never exceeds the cap-priced envelope")
    func boundedEstimateClampedToCap() {
        let facts = sixteenGBFacts(
            capPricedChildBytes: 2 * gib,
            boundedChildBytes: 10 * gib
        )
        #expect(facts.effectiveChildHeadroomBytes == 2 * gib)
    }

    /// Identical normalized model keys receive identical admission
    /// decisions — SysAdmin vs Research is a label, not a memory class.
    @Test("identical canonical model facts produce identical decisions")
    func identicalFactsIdenticalDecisions() {
        let facts = sixteenGBFacts(
            capPricedChildBytes: 4 * gib,
            boundedChildBytes: 400 * mib
        )
        let sysAdmin = SubagentBatchAdmissionPlanner.plan(input(local: 1, memory: facts))
        let research = SubagentBatchAdmissionPlanner.plan(input(local: 1, memory: facts))
        #expect(sysAdmin == research)
    }

    /// The bounded-position budget math itself: a 2,048-output child with a
    /// short instruction stays at the 4,096 floor, far below a 64K policy
    /// cap; a huge seed clamps to the cap, never above it; token math
    /// rounds UP (ceiling), never truncates.
    @Test("bounded position budget: floor, clamp, ceiling")
    func boundedPositionBudgetMath() {
        let small = SubagentChildRequestEstimate(
            seedCharacters: 800, maxOutputTokens: 2048)
        #expect(small.boundedPositionBudget(policyCap: 65536) == 4096)

        let huge = SubagentChildRequestEstimate(
            seedCharacters: 1_000_000, maxOutputTokens: 2048)
        #expect(huge.boundedPositionBudget(policyCap: 65536) == 65536)

        // Ceiling: 13,001 chars × 3 = 39,003; /8 truncating would give
        // 4,875 — the estimator must round UP to 4,876.
        let ceiling = SubagentChildRequestEstimate(
            seedCharacters: 13_001, maxOutputTokens: 10_000)
        #expect(ceiling.boundedPositionBudget(policyCap: 65536) == 4876 + 10_000)
    }

    /// An INCOMPLETE contract is not a bound: a missing seed OR a missing
    /// (or non-positive) output ceiling must fall back to conservative
    /// cap pricing, never a partial guess.
    @Test("incomplete request bounds fall back to conservative pricing")
    func incompleteBoundsFallBack() {
        #expect(
            SubagentChildRequestEstimate(seedCharacters: nil, maxOutputTokens: 2048)
                .boundedPositionBudget(policyCap: 65536) == nil)
        #expect(
            SubagentChildRequestEstimate(seedCharacters: 800, maxOutputTokens: nil)
                .boundedPositionBudget(policyCap: 65536) == nil)
        #expect(
            SubagentChildRequestEstimate(seedCharacters: 800, maxOutputTokens: 0)
                .boundedPositionBudget(policyCap: 65536) == nil)
        #expect(
            SubagentChildRequestEstimate(seedCharacters: nil, maxOutputTokens: nil)
                .boundedPositionBudget(policyCap: 65536) == nil)
    }

    /// CAUSAL: a delegated agent target prices ONLY ceilings its execution
    /// path enforces — the resolved context window captured during model
    /// resolution. Before resolution no window exists, so the estimator
    /// fails CLOSED to conservative cap pricing rather than guessing from
    /// launcher display limits (`runDelegated`'s chat loop historically
    /// ignored them; pricing an unenforced 2K limit against a 16K-capable
    /// chat would be a fail-open admission).
    @Test("unresolved delegated target fails closed to cap pricing")
    func unresolvedDelegatedTargetFailsClosed() {
        let delegated = TextSubagentKind(agentID: UUID(), input: "audit the disk")
        #expect(delegated.admissionRequestEstimate() == nil)
    }

    /// The delegated enforced-window contract: an estimate carrying ONLY the
    /// execution-enforced position ceiling (the resolved context window the
    /// chat loop trims to) is a complete bound on its own — no seed/output
    /// pair required — and the policy cap still clamps it.
    @Test("enforced position ceiling alone is a complete bound")
    func enforcedCeilingAloneBounds() {
        let windowOnly = SubagentChildRequestEstimate(
            seedCharacters: nil, maxOutputTokens: nil,
            enforcedPositionCeiling: 8192)
        #expect(windowOnly.boundedPositionBudget(policyCap: 65536) == 8192)

        // The 4096 wrapper/template floor still applies below it.
        let tiny = SubagentChildRequestEstimate(
            seedCharacters: nil, maxOutputTokens: nil,
            enforcedPositionCeiling: 2048)
        #expect(tiny.boundedPositionBudget(policyCap: 65536) == 4096)

        // Policy cap clamps a huge window down.
        let huge = SubagentChildRequestEstimate(
            seedCharacters: nil, maxOutputTokens: nil,
            enforcedPositionCeiling: 262_144)
        #expect(huge.boundedPositionBudget(policyCap: 65536) == 65536)
    }

    /// When BOTH bounds are present (tool-less delegated target: launcher
    /// budgets enforced by the session clamp AND the resolved window), the
    /// tighter one wins in each direction.
    @Test("tighter of budget-bound and enforced window wins")
    func tighterBoundWins() {
        // seed+output (≈ 300 + 4096 → floor 4416... under window 32K) wins.
        let budgetTighter = SubagentChildRequestEstimate(
            seedCharacters: 800, maxOutputTokens: 4096,
            enforcedPositionCeiling: 32_768)
        #expect(budgetTighter.boundedPositionBudget(policyCap: 65536) == 4396)

        // window (8K) tighter than seed+output (22,500 + 10,000) wins.
        let windowTighter = SubagentChildRequestEstimate(
            seedCharacters: 60_000, maxOutputTokens: 10_000,
            enforcedPositionCeiling: 8192)
        #expect(windowTighter.boundedPositionBudget(policyCap: 65536) == 8192)
    }

    /// CAUSAL, the reported 16 GiB Gemma flip: the same machine/model facts
    /// move from the false rejection (cap-priced, no bounded estimate) to
    /// admission once the child is priced at its ENFORCED window — while a
    /// genuinely unsafe window-priced child stays refused. This is the
    /// planner-level statement of "reported configuration flips
    /// false-refusal → admission; unsafe runs remain refused".
    @Test("enforced-window pricing flips the reported refusal to admission")
    func enforcedWindowFlipsRefusalToAdmission() {
        // Before: cap-priced only → the reported ramSlots == 0 rejection.
        let before = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 1,
                memory: sixteenGBFacts(
                    capPricedChildBytes: 4 * gib,
                    boundedChildBytes: nil
                )
            )
        )
        guard case .rejected = before.verdict else {
            Issue.record("expected the unfixed shape to reject, got \(before.verdict)")
            return
        }

        // After: the SAME facts with the window-derived bounded price →
        // admitted with one slot.
        let after = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 1,
                memory: sixteenGBFacts(
                    capPricedChildBytes: 4 * gib,
                    boundedChildBytes: 600 * mib
                )
            )
        )
        #expect(after.verdict == .admitted)
        #expect(after.localParallelism == 1)

        // Unsafe control: a window-priced child that genuinely exceeds the
        // residual is still refused — the bound is a price, not a bypass.
        let unsafe = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 1,
                memory: sixteenGBFacts(
                    capPricedChildBytes: 6 * gib,
                    boundedChildBytes: 4 * gib
                )
            )
        )
        guard case .rejected(let reason) = unsafe.verdict else {
            Issue.record("expected unsafe child to stay rejected, got \(unsafe.verdict)")
            return
        }
        #expect(reason == .insufficientMemory)
    }

    /// CAUSAL: the bare `spawn_model` path IS governed by launcher budgets
    /// (per-generation `maxDelegateTokens` × at most `maxDelegateTurns`
    /// iterations, no tool access) — it produces a bounded estimate whose
    /// output ceiling reflects turns × per-turn, not a single turn.
    @Test("bare model target produces a turns-aware bounded estimate")
    func bareModelTargetBoundedEstimate() {
        let bare = TextSubagentKind(model: "some/model", input: "summarize this")
        let estimate = bare.admissionRequestEstimate()
        #expect(estimate != nil)
        #expect(estimate?.seedCharacters == "summarize this".count)
        // Defaults: maxDelegateTokens 2048 × maxDelegateTurns 2.
        #expect(estimate?.maxOutputTokens == 2048 * 2)
    }

    /// The enforced delegated contract, derived for the REPORTED shape: a
    /// tool-enabled target agent (SysAdmin has tools) with the default
    /// launcher budgets (2,048 tokens × 2 turns) against a 64K window.
    /// The ceiling must land far below the window — seed + 4,096 overhead
    /// + 2 × (2,048 response + 4,096 tool allowance) — because THIS is the
    /// number both the session enforces and admission prices. Without it,
    /// a tool-enabled delegated child collapsed back to cap pricing.
    @Test("tool-enabled delegated contract stays far below the window")
    func toolEnabledDelegatedContractBounded() throws {
        let contract = try #require(
            DelegatedRunContract.derive(
                seedCharacters: 800,
                systemPromptCharacters: 2_000,
                toolSchemaCharacters: 1_000,
                budgets: SubagentBudgets(),  // defaults: 2048 tokens × 2 turns
                toolEnabled: true,
                resolvedContextWindow: 65_536
            ))
        // MEASURED reservations (no fixed overhead guess): seed 800 chars →
        // 300 tokens, system prompt 2,000 → 750, tool schemas 1,000 → 375;
        // 300 + 750 + 375 + 2×(2048 + 4096 tool allowance) = 13,713.
        #expect(contract.contextPositions == 13_713)
        #expect(contract.responseTokens == 2048)
        #expect(contract.assistantTurns == 2)
        #expect(contract.contextPositions < 65_536 / 3)

        // Tool-less variant drops the per-turn tool allowance:
        // 300 + 750 + 375 + 2×2048 = 5,521.
        let toolLess = DelegatedRunContract.derive(
            seedCharacters: 800,
            systemPromptCharacters: 2_000,
            toolSchemaCharacters: 1_000,
            budgets: SubagentBudgets(),
            toolEnabled: false,
            resolvedContextWindow: 65_536
        )
        #expect(toolLess?.contextPositions == 5_521)

        // A bigger composed prompt raises the priced reservation — the
        // contract tracks the ACTUAL prompt, not an allowance.
        let bigPrompt = DelegatedRunContract.derive(
            seedCharacters: 800,
            systemPromptCharacters: 40_000,
            toolSchemaCharacters: 1_000,
            budgets: SubagentBudgets(),
            toolEnabled: true,
            resolvedContextWindow: 65_536
        )
        // 40,000 chars → 15,000 tokens: 300 + 15,000 + 375 + 12,288 = 27,963.
        #expect(bigPrompt?.contextPositions == 27_963)

        // A small resolved window (user cap / small bundle) tightens further.
        let smallWindow = DelegatedRunContract.derive(
            seedCharacters: 800,
            systemPromptCharacters: 2_000,
            toolSchemaCharacters: 1_000,
            budgets: SubagentBudgets(),
            toolEnabled: true,
            resolvedContextWindow: 8_192
        )
        #expect(smallWindow?.contextPositions == 8_192)

        // Un-normalized budgets are clamped before derivation.
        let wild = DelegatedRunContract.derive(
            seedCharacters: 0,
            systemPromptCharacters: 0,
            toolSchemaCharacters: 0,
            budgets: SubagentBudgets(maxDelegateTokens: 999_999, maxDelegateTurns: 99),
            toolEnabled: false,
            resolvedContextWindow: 1_000_000
        )
        // tokens clamp to 32,768, turns to 8 → 8×32,768 = 262,144.
        #expect(wild?.contextPositions == 262_144)
        #expect(wild?.responseTokens == 32_768)
        #expect(wild?.assistantTurns == 8)
    }

    /// Overflow and degenerate inputs FAIL CLOSED (nil — cap pricing, no
    /// clamps), never a wrapped or partially-computed bound.
    @Test("contract derivation fails closed on overflow and degenerate input")
    func contractDerivationFailsClosed() {
        #expect(
            DelegatedRunContract.derive(
                seedCharacters: Int.max,
                systemPromptCharacters: 0,
                toolSchemaCharacters: 0,
                budgets: SubagentBudgets(),
                toolEnabled: true,
                resolvedContextWindow: 65_536
            ) == nil, "seed × 3 overflow must fail closed")
        #expect(
            DelegatedRunContract.derive(
                seedCharacters: 800,
                systemPromptCharacters: Int.max,
                toolSchemaCharacters: 0,
                budgets: SubagentBudgets(),
                toolEnabled: true,
                resolvedContextWindow: 65_536
            ) == nil, "system-prompt overflow must fail closed")
        #expect(
            DelegatedRunContract.derive(
                seedCharacters: 800,
                systemPromptCharacters: 0,
                toolSchemaCharacters: Int.max,
                budgets: SubagentBudgets(),
                toolEnabled: true,
                resolvedContextWindow: 65_536
            ) == nil, "tool-schema overflow must fail closed")
        #expect(
            DelegatedRunContract.derive(
                seedCharacters: 800,
                systemPromptCharacters: 0,
                toolSchemaCharacters: 0,
                budgets: SubagentBudgets(),
                toolEnabled: true,
                resolvedContextWindow: 0
            ) == nil, "no usable window must fail closed")
        #expect(
            DelegatedRunContract.derive(
                seedCharacters: 800,
                systemPromptCharacters: 0,
                toolSchemaCharacters: 0,
                budgets: SubagentBudgets(),
                toolEnabled: true,
                resolvedContextWindow: -5
            ) == nil, "negative window must fail closed")
    }

    /// Tighten-only clamp semantics: the contract can never RAISE a limit
    /// the target agent or surface already set lower.
    @Test("contract clamps tighten and never raise")
    func contractClampsTightenOnly() {
        let contract = DelegatedRunContract(
            responseTokens: 2048, assistantTurns: 2, contextPositions: 16_684)

        // Response: agent's smaller setting survives; larger is clamped;
        // unset falls to the contract value.
        #expect(contract.clampedResponseTokens(agentConfigured: 1024) == 1024)
        #expect(contract.clampedResponseTokens(agentConfigured: 8192) == 2048)
        #expect(contract.clampedResponseTokens(agentConfigured: nil) == 2048)

        // Turns: surface's 15-attempt default clamps to 2; a surface already
        // at 1 stays at 1; the floor keeps at least one attempt.
        #expect(contract.clampedToolAttempts(surfaceConfigured: 15) == 2)
        #expect(contract.clampedToolAttempts(surfaceConfigured: 1) == 1)
        let degenerate = DelegatedRunContract(
            responseTokens: 2048, assistantTurns: 0, contextPositions: 16_684)
        #expect(degenerate.clampedToolAttempts(surfaceConfigured: 15) == 1)

        // Window: resolved 65,536 clamps to the ceiling; a smaller resolved
        // window survives.
        #expect(contract.clampedContextWindow(resolved: 65_536) == 16_684)
        #expect(contract.clampedContextWindow(resolved: 8_192) == 8_192)
    }

    /// PRODUCTION PATH: the estimator prices EXACTLY the stored contract's
    /// ceiling — the same object `runDelegated` hands to the dispatched
    /// session — and fails closed (nil) when no contract was derived.
    @Test("delegated estimator prices exactly the enforced contract")
    func delegatedEstimatorPricesContract() {
        let kind = TextSubagentKind(agentID: UUID(), input: "audit the disk")
        #expect(kind.admissionRequestEstimate() == nil, "no contract → cap pricing")

        kind.delegatedContract = DelegatedRunContract(
            responseTokens: 2048, assistantTurns: 2, contextPositions: 16_684)
        let estimate = kind.admissionRequestEstimate()
        #expect(estimate?.enforcedPositionCeiling == 16_684)
        #expect(estimate?.seedCharacters == nil)
        #expect(estimate?.maxOutputTokens == nil)
        #expect(estimate?.boundedPositionBudget(policyCap: 65_536) == 16_684)
    }

    /// PROPAGATION, production path: `BackgroundTaskManager.createContext`
    /// (via its testing seam) converts the request's three caps into the
    /// contract stamped on the dispatched `ChatSession` — the object that
    /// enforces them. All three must be present to form a contract; a
    /// partial contract is no contract.
    @Test("dispatch caps propagate onto the dispatched chat session")
    @MainActor
    func dispatchCapsPropagateToSession() {
        let request = DispatchRequest(
            prompt: "hello",
            agentId: UUID(),
            delegationResponseTokenCap: 2048,
            delegationContextPositionCap: 16_684,
            delegationAssistantTurnCap: 2
        )
        #expect(
            request.delegationContract
                == DelegatedRunContract(
                    responseTokens: 2048, assistantTurns: 2, contextPositions: 16_684))

        // The REAL conversion, not a re-derivation.
        let context = BackgroundTaskManager.shared.makeContextForTesting(request)
        #expect(context.chatSession.delegationBudget?.responseTokens == 2048)
        #expect(context.chatSession.delegationBudget?.assistantTurns == 2)
        #expect(context.chatSession.delegationBudget?.contextPositions == 16_684)

        // Partial caps form NO contract anywhere in the chain.
        let partial = DispatchRequest(
            prompt: "hello",
            agentId: UUID(),
            delegationResponseTokenCap: 2048
        )
        #expect(partial.delegationContract == nil)
        let partialContext = BackgroundTaskManager.shared.makeContextForTesting(partial)
        #expect(partialContext.chatSession.delegationBudget == nil)

        let none = ExecutionContext(agentId: UUID())
        #expect(none.chatSession.delegationBudget == nil)
    }

    /// WIRING PIN: the clamped `effectiveMaxTokensForAgent` is the ONLY
    /// value the chat surface passes as the generation request's
    /// `max_tokens`, and the delegation clamp is applied at its single
    /// definition site before any use. Reads the production source so a
    /// regression that adds an unclamped `max_tokens:` feed, or drops the
    /// clamp, fails this test.
    @Test("clamped max tokens is the only generation-request feed")
    func clampedMaxTokensIsOnlyRequestFeed() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let chatView = testFile
            .deletingLastPathComponent()  // (file name)
            .deletingLastPathComponent()  // Subagent
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Views/Chat/ChatView.swift")
        let source = try String(contentsOf: chatView, encoding: .utf8)

        // Exactly one definition, immediately followed by the clamp.
        let definitions = source.components(
            separatedBy: "var effectiveMaxTokensForAgent"
        ).count - 1
        #expect(definitions == 1, "one definition site for the request budget")
        #expect(
            source.contains(
                ".clampedResponseTokens(agentConfigured: effectiveMaxTokensForAgent)"),
            "the delegation clamp guards the definition")

        // Every `max_tokens:` the surface sends comes from that variable.
        let feeds = source.components(separatedBy: "max_tokens:").dropFirst()
        #expect(!feeds.isEmpty)
        for feed in feeds {
            let value = feed.trimmingCharacters(in: .whitespaces)
            #expect(
                value.hasPrefix("effectiveMaxTokensForAgent"),
                "every request max_tokens must be the clamped value")
        }
    }

    /// CAUSAL: a longer seed (system prompt + schemas + instruction all
    /// arrive as seed characters) raises the priced bound monotonically —
    /// context the child must hold is context admission must charge.
    @Test("larger seed raises the priced bound")
    func largerSeedRaisesBound() {
        let short = SubagentChildRequestEstimate(
            seedCharacters: 1_000, maxOutputTokens: 4_096)
        let long = SubagentChildRequestEstimate(
            seedCharacters: 60_000, maxOutputTokens: 4_096)
        let shortBudget = short.boundedPositionBudget(policyCap: 65536)!
        let longBudget = long.boundedPositionBudget(policyCap: 65536)!
        #expect(longBudget > shortBudget)
        // 60,000 chars → ceil(60000×3/8)=22,500 tokens + 4,096 = 26,596.
        #expect(longBudget == 22_500 + 4_096)
    }
}
