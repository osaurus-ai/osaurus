import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

// Regressions reproduced during the RAM admission cross-function audit.
@Suite("RAM admission cross-function audit")
struct RAMAdmissionAuditProbes {
    @Test("a free engine slot must not be subtracted again by sibling reservations")
    func engineAvailabilityIsNotAnAggregateCeiling() async {
        let admission = SubagentAdmission()
        #expect(await admission.reserveLocalInPlace(
            modelKey: "same", requestedSlots: 1, slotCapacity: 2
        ) == .admitted(slots: 1))
        let window = SpawnBatchTool.engineAdmissionWindow(
            configuredMaximum: 2,
            snapshot: ModelBatchCapacitySnapshot(
                modelName: "same", configuredMaximum: 2, activeCount: 1,
                pendingCount: 0, nominalAvailableCount: 1, activeHighWatermark: 1,
                isAcceptingRequests: true, isShutdown: false
            )
        )
        let plan = SubagentBatchAdmissionPlanner.plan(.init(
            localJobCount: 1, remoteJobCount: 0, agentParallelLimit: 2,
            engineParallelLimit: 2, engineSubmissionLimit: window.parallelLimit, continuousBatchingEnabled: true,
            ramSafetyEnabled: false, failClosedWhenEstimateUnknown: false, memory: nil
        ))
        let second = await admission.reserveLocalInPlace(
            modelKey: "same", requestedSlots: 1, slotCapacity: plan.localCapacity,
            timeoutSeconds: 0
        )
        print("ENGINE_AUDIT live_free=1 aggregate_ceiling=\(plan.localCapacity) result=\(second)")
        #expect(second == .admitted(slots: 1))
        await admission.releaseLocalInPlace(modelKey: "same", slots: 2)
    }

    @Test("admission must not cap a request below a prompt the runtime retains uncapped")
    func softKVDefaultIsNotAHardMemoryCeiling() {
        let config = CacheCoordinatorConfig(defaultMaxKVSize: 8_192, longPromptMultiplier: 2)
        let runtimePolicy = config.resolveKVPolicy(kvMode: .none, maxKVSize: nil, promptTokenCount: 12_000)
        #expect(runtimePolicy.maxKVSize == nil)
        let priced = SubagentChildRequestEstimate(
            seedCharacters: nil, maxOutputTokens: nil, enforcedPositionCeiling: 14_048
        ).boundedPositionBudget()
        print("KV_CAP_AUDIT prompt_tokens=12000 runtime_cap=nil priced_positions=\(priced ?? -1)")
        #expect((priced ?? 0) >= 12_000)
    }

    @Test("exact admission check rejects tokenizer-heavy input missed by heuristic trimming")
    func delegatedCeilingIsOnlyAnEstimate() throws {
        let input = String(repeating: "1 2 3 4 5 6 7 8 9 0 ", count: 1_000)
        // Exact local Gemma E2B tokenizer.json measurement, no model load:
        // tokenizer-estimates.json: 20,000 tokens for these 20,000 ASCII chars.
        let measuredTokens = 20_000
        let contract = try #require(DelegatedRunContract.derive(
            seedCharacters: input.count, systemPromptCharacters: 0, toolSchemaTokens: 0,
            budgets: SubagentBudgets(), toolEnabled: false, resolvedContextWindow: 65_536
        ))
        let manager = AgentLoopBudget.makeBudgetManager(
            contextWindow: contract.contextPositions, systemPromptChars: 0,
            toolTokens: 0, maxResponseTokens: contract.responseTokens
        )
        let result = AgentLoopBudget.trimPreservingSystemPrefixReportingOverflow(
            [ChatMessage(role: "user", content: input)], with: manager
        )
        #expect(result.messages.first?.content == input)
        print("TOKEN_AUDIT actual_input=\(measuredTokens) contract=\(contract.contextPositions) over_budget=\(result.overBudget)")
        #expect(throws: AdmissionPositionLimit.self) {
            try AdmissionPositionLimit.validate(
                promptTokens: measuredTokens, outputTokens: contract.responseTokens,
                limit: contract.contextPositions
            )
        }
    }

    @Test("exact position guard covers output, equality, overflow, and ordinary requests")
    func exactPositionBoundary() throws {
        try AdmissionPositionLimit.validate(promptTokens: 10_000, outputTokens: 2_000, limit: 12_000)
        try AdmissionPositionLimit.validate(promptTokens: Int.max, outputTokens: 2_000, limit: nil)
        for (prompt, output, limit) in [(10_001, 2_000, 12_000), (Int.max, 1, Int.max), (1, 1, 0)] {
            #expect(throws: AdmissionPositionLimit.self) {
                try AdmissionPositionLimit.validate(promptTokens: prompt, outputTokens: output, limit: limit)
            }
        }
    }
}
