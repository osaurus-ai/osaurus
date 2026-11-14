import Foundation
import Testing

@testable import OsaurusCore

@Suite("Resident delegated context admission")
struct ResidentDelegationContextAdmissionTests {
    private let requested = 299_770
    private let minimum = 17_146
    private let fitted = 287_568
    private let footprint: UInt64 = 3_662_928_280
    private let allocator: UInt64 = 1_073_741_824

    /// Exact refusal receipt. The model is already resident, kernel pressure
    /// is normal, and no parent model is offered as reclaimable memory.
    private func facts(
        resident: Bool = true,
        pressure: SubagentMemoryPressure = .normal,
        available: UInt64? = 14_395_670_528,
        budget: UInt64? = 36_077_725_286,
        allocator: UInt64? = 1_073_741_824,
        bounded: UInt64? = 13_884_180_480,
        load: UInt64? = 3_662_928_280
    ) -> SubagentBatchMemoryFacts {
        .init(
            canonicalModelKey: "resident-raptor-regression",
            targetAlreadyResident: resident,
            targetLoadFootprintBytes: load,
            perActiveChildHeadroomBytes: 48_389_160_960,
            requestBoundedChildHeadroomBytes: bounded,
            reclaimableBytes: available,
            releasableParentBytes: 0,
            resolvedLoadBudgetBytes: budget,
            osHeadroomBytes: 3_221_225_472,
            memoryPressure: pressure,
            allocatorCacheAllowanceBytes: allocator
        )
    }

    /// 9 full + 27 sliding layers, 512 sliding rows, K/V 4 x 256 BF16,
    /// including the estimator's 25% architecture slack.
    private func price(_ positions: Int) -> UInt64? {
        guard positions > 0 else { return nil }
        let (variable, overflow) = UInt64(positions).multipliedReportingOverflow(by: 46_080)
        let (bytes, addOverflow) = variable.addingReportingOverflow(70_778_880)
        return overflow || addOverflow ? nil : bytes
    }

    private func ceiling(_ memory: SubagentBatchMemoryFacts, requested: Int? = nil,
                         minimum: Int? = nil) -> Int? {
        SubagentBatchAdmissionPlanner.affordablePositionCeiling(
            requested: requested ?? self.requested, minimum: minimum ?? self.minimum,
            memory: memory, headroomForPositions: price
        )
    }

    private func plan(_ memory: SubagentBatchMemoryFacts, jobs: Int = 1,
                      limit: Int = 1) -> SubagentBatchAdmissionPlan {
        SubagentBatchAdmissionPlanner.plan(.init(
            localJobCount: jobs, remoteJobCount: 0, agentParallelLimit: limit,
            engineParallelLimit: limit, continuousBatchingEnabled: true,
            ramSafetyEnabled: true, failClosedWhenEstimateUnknown: true, memory: memory
        ))
    }

    private func kind() -> TextSubagentKind {
        let kind = TextSubagentKind(agentID: UUID(), input: "source-only admission regression")
        kind.delegatedContract = DelegatedRunContract(
            responseTokens: 8_192, assistantTurns: 24, contextPositions: requested)
        kind.minimumAdmissionContextPositions = minimum
        return kind
    }

    private func withRaptorGeometry(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Synthetic config metadata reproduces the reported topology. No
        // installed model lookup, weights, tokenizer, load, or GPU is required.
        let config: [String: Any] = [
            "model_type": "resident_delegation_test",
            "num_hidden_layers": 36,
            "num_attention_heads": 16,
            "num_key_value_heads": 4,
            "head_dim": 256,
            "sliding_window": 512,
            "max_position_embeddings": 1_048_576,
            "kv_cache_dtype": "bfloat16",
            "layer_types": (0..<36).map { ($0 + 1) % 4 == 0 ? "full_attention" : "sliding_attention" },
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("config.json"))
        try body(directory)
    }

    @Test("exact refusal receipt fits one child only after enforcing the largest affordable window")
    func liveReceiptLargestAffordableWindow() throws {
        let original = facts()
        #expect(price(requested) == 13_884_180_480)
        #expect(original.perActiveChildHeadroomBytes == 48_389_160_960)
        #expect(plan(original).ramSlots == 0)
        #expect(plan(original).localCapacity == 0)
        let positions = try #require(ceiling(original))
        #expect(positions == fitted)
        let bytes = try #require(price(positions))
        #expect(bytes == 13_321_912_320)
        #expect(original.reclaimableBytes! - allocator == 13_321_928_704)
        let repriced = original.pricingChildHeadroom(bytes)
        let admitted = plan(repriced)
        #expect(admitted.verdict == .admitted)
        #expect(admitted.ramSlots == 1)
        #expect(admitted.localCapacity == 1)
        #expect(admitted.incrementalWeightChargeBytes == 0)
        #expect(admitted.projectedIncrementalPeakBytes == allocator + bytes)
        #expect(admitted.projectedModelWorkingSetBytes == footprint + allocator + bytes)
        #expect(price(positions + 1) == 13_321_958_400)
        #expect(plan(original.pricingChildHeadroom(try #require(price(positions + 1)))).localCapacity == 0)
    }

    @Test("actual ModelRuntime topology estimator reproduces cap, original, floor and fitted prices")
    func architectureEstimatorPricesExactGeometry() throws {
        try withRaptorGeometry { directory in
            let mix = ModelRuntime.attentionLayerMix(in: try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json")))
                    as? [String: Any]))
            #expect(mix.fullAttention == 9)
            #expect(mix.slidingAttention == 27)
            #expect(mix.slidingWindow == 512)
            #expect(ModelRuntime.estimatedKVHeadroomBytes(
                forWeights: Int64(footprint), modelDirectory: directory, kvRetentionCap: nil) == 48_389_160_960)
            for positions in [minimum, fitted, fitted + 1, requested] {
                #expect(ModelRuntime.estimatedKVHeadroomBytes(
                    forWeights: Int64(footprint), modelDirectory: directory,
                    kvRetentionCap: nil, requestPositionLimit: positions) == Int64(try #require(price(positions))))
            }
            let actual = SubagentBatchAdmissionPlanner.affordablePositionCeiling(
                requested: requested, minimum: minimum, memory: facts(), headroomForPositions: { positions in
                    let bytes = ModelRuntime.estimatedKVHeadroomBytes(
                        forWeights: Int64(footprint), modelDirectory: directory,
                        kvRetentionCap: nil, requestPositionLimit: positions)
                    return bytes > 0 ? UInt64(bytes) : nil
                })
            #expect(actual == fitted)
        }
    }

    @Test("resolved model budget is an independent exact boundary even with more reclaimable RAM")
    func budgetThresholdIndependentlyLimitsWindow() throws {
        let bytes = try #require(price(fitted))
        let threshold = footprint + allocator + bytes
        let exact = facts(available: 60_000_000_000, budget: threshold)
        #expect(ceiling(exact) == fitted)
        #expect(plan(exact.pricingChildHeadroom(bytes)).localCapacity == 1)
        let below = facts(available: 60_000_000_000, budget: threshold - 1)
        #expect(ceiling(below) == fitted - 1)
        #expect(plan(below.pricingChildHeadroom(bytes)).localCapacity == 0)
    }

    @Test("a first round that cannot fit is refused instead of tightening below its composed seed")
    func minimumRoundCannotFit() throws {
        // These synthetic composer sizes give the receipt's 4,858-position
        // prefix reserve. Lifetime work remains 24 turns, not one turn.
        let full = try #require(DelegatedRunContract.derive(
            seedCharacters: 800, systemPromptCharacters: 8_000, toolSchemaTokens: 1_558,
            budgets: SubagentBudgets(maxDelegateTokens: 8_192, maxDelegateTurns: 24),
            toolEnabled: true, resolvedContextWindow: 1_048_576))
        let first = try #require(DelegatedRunContract.derive(
            seedCharacters: 800, systemPromptCharacters: 8_000, toolSchemaTokens: 1_558,
            budgets: SubagentBudgets(maxDelegateTokens: 8_192, maxDelegateTurns: 1),
            toolEnabled: true, resolvedContextWindow: 1_048_576))
        #expect(full.contextPositions == requested)
        #expect(first.contextPositions == minimum)
        let floorCost = try #require(price(minimum))
        #expect(ceiling(facts(available: allocator + floorCost - 1)) == nil)
        #expect(ceiling(facts(budget: footprint + allocator + floorCost - 1)) == nil)
        #expect(ceiling(facts(available: allocator + floorCost)) == minimum)
    }

    @Test("unknown pressure, critical, warning, cold and missing authoritative facts fail closed")
    func untrustedFactsDoNotAdapt() {
        for memory in [facts(pressure: .unknown), facts(pressure: .critical), facts(pressure: .warning),
                       facts(resident: false), facts(allocator: nil), facts(budget: nil),
                       facts(available: nil), facts(bounded: nil), facts(load: nil)] {
            #expect(ceiling(memory) == nil)
        }
        #expect(ceiling(facts(allocator: UInt64.max)) == nil)
    }

    @Test("unknown prices and invalid bounds cannot manufacture a partial fitted window")
    func invalidBoundsAndPricesFailClosed() {
        for (request, floor) in [(requested, 0), (requested, -1), (minimum, minimum), (minimum - 1, minimum)] {
            #expect(ceiling(facts(), requested: request, minimum: floor) == nil)
        }
        for unknown: (Int) -> UInt64? in [{ _ in nil }, { _ in 0 }] {
            #expect(SubagentBatchAdmissionPlanner.affordablePositionCeiling(
                requested: requested, minimum: minimum, memory: facts(), headroomForPositions: unknown) == nil)
        }
    }

    @Test("repricing preserves the exact sampled facts and an already fitting contract stays unchanged")
    func repricingKeepsSampleAndAlreadyFitContract() throws {
        let original = facts()
        let snapshot = original
        let bytes = try #require(price(fitted))
        let changed = original.pricingChildHeadroom(bytes)
        #expect(original == snapshot)
        #expect(original.requestBoundedChildHeadroomBytes == 13_884_180_480)
        #expect(changed.requestBoundedChildHeadroomBytes == bytes)
        #expect(changed.effectiveChildHeadroomBytes == bytes)
        #expect(changed.canonicalModelKey == original.canonicalModelKey)
        #expect(changed.targetAlreadyResident == original.targetAlreadyResident)
        #expect(changed.targetLoadFootprintBytes == original.targetLoadFootprintBytes)
        #expect(changed.perActiveChildHeadroomBytes == original.perActiveChildHeadroomBytes)
        #expect(changed.reclaimableBytes == original.reclaimableBytes)
        #expect(changed.releasableParentBytes == 0)
        #expect(changed.resolvedLoadBudgetBytes == original.resolvedLoadBudgetBytes)
        #expect(changed.osHeadroomBytes == original.osHeadroomBytes)
        #expect(changed.memoryPressure == original.memoryPressure)
        #expect(changed.allocatorCacheAllowanceBytes == original.allocatorCacheAllowanceBytes)
        #expect(ceiling(changed, requested: fitted) == nil)
        #expect(plan(changed).ramSlots == 1)
    }

    @Test("kind tightens only context, preserves lifetime work and keeps memory-fit state sticky")
    func kindTightensOnlyContext() throws {
        let kind = kind()
        let original = try #require(kind.delegatedContract)
        #expect(!kind.admissionContextWasMemoryFitted)
        for invalid in [minimum - 1, requested, requested + 1] {
            #expect(!kind.tightenAdmissionContextPositions(to: invalid))
            #expect(kind.delegatedContract == original)
            #expect(!kind.admissionContextWasMemoryFitted)
        }
        #expect(kind.tightenAdmissionContextPositions(to: fitted))
        #expect(kind.admissionContextWasMemoryFitted)
        #expect(kind.delegatedContract?.responseTokens == 8_192)
        #expect(kind.delegatedContract?.assistantTurns == 24)
        #expect(kind.delegatedContract?.contextPositions == fitted)
        #expect(!kind.tightenAdmissionContextPositions(to: fitted + 1))
        #expect(kind.admissionContextWasMemoryFitted)
        #expect(kind.tightenAdmissionContextPositions(to: minimum))
        #expect(kind.delegatedContract?.contextPositions == minimum)
        #expect(kind.delegatedContract?.responseTokens == original.responseTokens)
        #expect(kind.delegatedContract?.assistantTurns == original.assistantTurns)
        let unresolved = TextSubagentKind(agentID: UUID(), input: "unresolved")
        #expect(!unresolved.tightenAdmissionContextPositions(to: minimum))
        unresolved.delegatedContract = original
        #expect(!unresolved.tightenAdmissionContextPositions(to: minimum))
    }

    @Test("fitted history never creates fan-out: four jobs serialize while true three-slot RAM facts stay visible")
    func fittedContextSerializesWithoutRaisingRefusedCapacity() throws {
        let bytes = try #require(price(minimum))
        let memory = facts(available: allocator + 3 * bytes).pricingChildHeadroom(bytes)
        var decision = plan(memory, jobs: 4, limit: 4)
        #expect(decision.ramSlots == 3)
        #expect(decision.localCapacity == 3)
        #expect(decision.localParallelism == 3)
        #expect(decision.localSubwaveSizes == [3, 1])
        decision.serializeMemoryFittedContext(jobCount: 4, positions: minimum)
        #expect(decision.localCapacity == 1)
        #expect(decision.localParallelism == 1)
        #expect(decision.localSubwaveSizes == [1, 1, 1, 1])
        #expect(decision.ramSlots == 3)
        #expect(decision.memoryFacts == memory)
        #expect(decision.memoryDiagnostics["ram_slots"] as? Int == 3)
        #expect(decision.memoryDiagnostics["memory_fitted_context_positions"] as? Int == minimum)
        var refused = plan(facts(), jobs: 4, limit: 4)
        refused.serializeMemoryFittedContext(jobCount: 4, positions: fitted)
        #expect(refused.localCapacity == 0)
        #expect(refused.localParallelism == 0)
        #expect(refused.localSubwaveSizes.isEmpty)
        #expect(refused.verdict == .rejected(.insufficientMemory))
    }

    @Test("the tightened kind estimate is the exact dispatch-session contract and all clamps only tighten")
    @MainActor
    func fittedContractEstimatorMatchesDispatchedEnforcement() throws {
        let kind = kind()
        #expect(kind.admissionRequestEstimate()?.boundedPositionBudget() == requested)
        #expect(kind.tightenAdmissionContextPositions(to: fitted))
        let contract = try #require(kind.delegatedContract)
        let estimate = try #require(kind.admissionRequestEstimate())
        #expect(estimate.enforcedPositionCeiling == fitted)
        #expect(estimate.boundedPositionBudget() == fitted)
        #expect(estimate.seedCharacters == nil)
        #expect(estimate.maxOutputTokens == nil)
        let request = DispatchRequest(
            prompt: "source-only contract propagation", agentId: UUID(), source: .delegation,
            delegationResponseTokenCap: contract.responseTokens,
            delegationContextPositionCap: contract.contextPositions,
            delegationAssistantTurnCap: contract.assistantTurns)
        #expect(request.delegationContract == contract)
        let context = BackgroundTaskManager.shared.makeContextForTesting(request)
        let enforced = try #require(context.chatSession.delegationBudget)
        #expect(enforced == contract)
        #expect(enforced.clampedContextWindow(resolved: 1_048_576) == fitted)
        #expect(enforced.clampedContextWindow(resolved: 131_072) == 131_072)
        #expect(enforced.clampedResponseTokens(agentConfigured: nil) == 8_192)
        #expect(enforced.clampedResponseTokens(agentConfigured: 16_384) == 8_192)
        #expect(enforced.clampedResponseTokens(agentConfigured: 2_048) == 2_048)
        #expect(enforced.clampedToolAttempts(surfaceConfigured: 100) == 24)
        #expect(enforced.clampedToolAttempts(surfaceConfigured: 5) == 5)
    }
}
