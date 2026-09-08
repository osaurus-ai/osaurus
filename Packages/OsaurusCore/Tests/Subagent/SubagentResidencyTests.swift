//
//  SubagentResidencyTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Model-free coverage of the shared residency DECISION (`SubagentResidency`)
//  that every chat-driven kind (spawn / computer_use) uses to
//  decide whether running its resolved model must unload the resident chat
//  model. The middleware itself is covered by `ResidencyHandoffTests`; here we
//  pin the pure `decidePlan` control flow and the `handoff(for:)` mapping.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Subagent residency decision")
struct SubagentResidencyTests {
    private let denied = "handoff disabled"

    @Test("a remote model never touches local residency")
    func remoteModelNeedsNoSwap() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: false,
            modelName: "remote/model",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 123,
            idleWaitSeconds: 60,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
    }

    @Test("the same local model already resident runs in place")
    func sameLocalRunsInPlace() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-a",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 60,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.ramSafetyEnabled)
        #expect(plan.requiredBytes == 4096)
        #expect(plan.maxElapsedSeconds == 60)
    }

    @Test("the same model in a different case is treated as resident (no swap)")
    func sameLocalCaseInsensitive() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "Local-A",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: false,
            requiredBytes: 0,
            idleWaitSeconds: 60,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.ramSafetyEnabled == false)
        #expect(plan.requiredBytes == 0)
        #expect(plan.maxElapsedSeconds == 60)
    }

    @Test("same invoking parent reuses target despite unrelated protected residency")
    func sameParentTargetIgnoresUnrelatedProtectedResidency() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-a",
            residentChatModels: ["LOCAL-A"],
            protectedResidentModels: ["api-b"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(!plan.shouldUnload)
        #expect(!plan.coexists)
        #expect(plan.requiredBytes == 4096)
        #expect(plan.ramSafetyEnabled)
        #expect(plan.maxElapsedSeconds == 90)
    }

    @Test("nothing else resident means nothing to evict")
    func nothingResidentNeedsNoSwap() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: [],
            handoffEnabled: false,  // irrelevant — nothing to evict
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.ramSafetyEnabled)
        #expect(plan.requiredBytes == 4096)
        #expect(plan.maxElapsedSeconds == 90)
    }

    @Test("a different local model with the handoff enabled unloads, carrying the plan")
    func differentLocalUnloads() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == true)
        #expect(plan.requiredBytes == 4096)
        #expect(plan.ramSafetyEnabled == true)
        #expect(plan.maxElapsedSeconds == 90)
    }

    @Test("handoff refuses before unloading when unrelated non-chat work is resident")
    func unrelatedProtectedResidentRefusesHandoff() {
        do {
            _ = try SubagentResidency.decidePlan(
                isLocal: true,
                modelName: "local-c",
                residentChatModels: ["local-a"],
                protectedResidentModels: ["api-b"],
                handoffEnabled: true,
                ramSafetyEnabled: true,
                requiredBytes: 4096,
                idleWaitSeconds: 90,
                deniedMessage: denied
            )
            Issue.record("unrelated protected residency should refuse before handoff")
        } catch let error as SubagentError {
            guard case .unavailable(let message) = error else {
                Issue.record("expected unavailable, got \(error)")
                return
            }
            #expect(message.contains("api-b"))
            #expect(message.contains("non-chat"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("protected target refuses before a non-coexisting parent handoff")
    func protectedTargetRefusesBeforeParentUnload() {
        do {
            _ = try SubagentResidency.decidePlan(
                isLocal: true,
                modelName: "api-b",
                residentChatModels: ["local-a"],
                protectedResidentModels: ["api-b"],
                handoffEnabled: true,
                ramSafetyEnabled: true,
                requiredBytes: 4096,
                idleWaitSeconds: 90,
                deniedMessage: denied
            )
            Issue.record("protected target should refuse before the parent is unloaded")
        } catch let error as SubagentError {
            guard case .unavailable(let message) = error else {
                Issue.record("expected unavailable, got \(error)")
                return
            }
            #expect(message.contains("api-b"))
            #expect(message.contains("restored"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("RAM-safe coexistence (toggle OFF) may reuse a protected target without unloading the parent")
    func protectedTargetCanBeReusedByCoexistence() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "api-b",
            residentChatModels: ["local-a"],
            protectedResidentModels: ["api-b"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 2_000,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            coexistence: SubagentCoexistence(
                allowed: true,
                availableBytes: 10_000_000_000,
                residentBytes: 4_000,
                flexibleBudgetBytes: 10_000
            )
        )
        #expect(plan.coexists)
        #expect(!plan.shouldUnload)
    }

    @Test("protected target coexistence (toggle OFF) does not double-charge resident weights")
    func protectedTargetReuseDoesNotDoubleChargeWeights() throws {
        let gb: Int64 = 1 << 30
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "api-b",
            residentChatModels: ["local-a"],
            protectedResidentModels: ["api-b"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 4 * gb,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            coexistence: SubagentCoexistence(
                allowed: true,
                availableBytes: 5 * gb,
                residentBytes: 8 * gb,
                // A+B fits, A+B+B does not. Reusing B must add zero weight.
                flexibleBudgetBytes: 10 * gb,
                // A tightened profile may reject a new cold load, but the
                // target is already protected and resident in this row.
                memorySafetyAllowsTargetLoad: false
            )
        )
        #expect(plan.coexists)
        #expect(!plan.shouldUnload)
    }

    @Test("RAM-safe coexistence (toggle OFF) may add a child without reclaiming protected residents")
    func coexistenceCanPreserveProtectedResident() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-c",
            residentChatModels: ["local-a"],
            protectedResidentModels: ["api-b"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 2_000,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            coexistence: SubagentCoexistence(
                allowed: true,
                availableBytes: 10_000_000_000,
                residentBytes: 4_000,
                flexibleBudgetBytes: 10_000
            )
        )
        #expect(plan.coexists)
        #expect(!plan.shouldUnload)
    }

    @Test("a different local model with the handoff toggle OFF runs with NO sequencing (never a refusal)")
    func differentLocalHandoffDisabledRunsWithoutSequencing() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.coexists == false)
        #expect(plan.sequencingDisabled == true)
        #expect(plan.mode == "sequencing_off")
        // Toggle OFF maps to the passthrough handoff: nothing unloaded, nothing restored.
        #expect(SubagentResidency.handoff(for: plan) is PassthroughHandoff)
    }

    @Test("handoff toggle ON + main chat model NOT loaded: the reload leg still runs (parity)")
    func differentLocalMainNotLoadedStillRestores() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: [],  // main model evicted / never warmed
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            invokingParentModelName: "local-a"
        )
        #expect(plan.shouldUnload == true)
        #expect(plan.mode == "swap_unload_reload")
        #expect(SubagentResidency.handoff(for: plan) is ResidencyHandoff)
    }

    @Test("handoff toggle OFF + main chat model NOT loaded: run in place, no reload leg")
    func differentLocalMainNotLoadedToggleOffRunsInPlace() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: [],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            invokingParentModelName: "local-a"
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.coexists == false)
    }

    @Test("main NOT loaded + delegate IS the parent model: no churn even with the toggle ON")
    func sameModelMainNotLoadedNoChurn() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "Local-A",
            residentChatModels: [],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            invokingParentModelName: "local-a"
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.sequencingDisabled == false)
        #expect(plan.mode == "in_place")
    }

    @Test("nested agent caller: the invoking agent's own model is the one swapped out and restored")
    func nestedAgentCallerSwapsItsOwnModel() throws {
        // A custom agent (model `agent-c`) chatting and delegating to an agent
        // whose model is `local-b`: the residency decision is made for the
        // CALLER's resident model, not the default chat model.
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["agent-c"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            invokingParentModelName: "agent-c"
        )
        #expect(plan.shouldUnload == true)
        // The nested caller delegating to its OWN model still runs in place.
        let same = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "agent-c",
            residentChatModels: ["agent-c"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            invokingParentModelName: "agent-c"
        )
        #expect(same.shouldUnload == false)
    }

    @Test("handoff(for:) maps an unload plan to a residency handoff, else passthrough")
    func handoffMapping() {
        #expect(SubagentResidency.handoff(for: ResidencyPlan(shouldUnload: true)) is ResidencyHandoff)
        #expect(SubagentResidency.handoff(for: .none) is PassthroughHandoff)
        #expect(
            SubagentResidency.handoff(
                for: ResidencyPlan(shouldUnload: false, coexists: true)
            ) is CoexistenceHandoff
        )
    }

    // MARK: - RAM-aware coexistence gate

    /// 10 GB model, plenty of reclaimable RAM, well under the flexible cap.
    private func roomyCoexistence(allowed: Bool = true) -> SubagentCoexistence {
        SubagentCoexistence(
            allowed: allowed,
            availableBytes: 64 * 1_073_741_824,
            residentBytes: 8 * 1_073_741_824,
            flexibleBudgetBytes: 96 * 1_073_741_824
        )
    }

    private let tenGB: Int64 = 10 * 1_073_741_824

    @Test("coexistence (toggle OFF): both fit under flexible policy → run alongside, no unload")
    func coexistenceFitsRunsAlongside() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: tenGB,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            coexistence: roomyCoexistence()
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.coexists == true)
        #expect(plan.maxElapsedSeconds == 90)
    }

    @Test("handoff toggle ON always sequences: coexistence never overrides the swap")
    func handoffOnIgnoresCoexistence() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: tenGB,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            coexistence: roomyCoexistence()
        )
        #expect(plan.shouldUnload == true)
        #expect(plan.coexists == false)
        #expect(plan.mode == "swap_unload_reload")
    }

    @Test("coexistence disabled (default) keeps the single-residency handoff")
    func coexistenceDisabledKeepsHandoff() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: tenGB,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            coexistence: .disabled
        )
        #expect(plan.shouldUnload == true)
        #expect(plan.coexists == false)
    }

    // With the toggle OFF there is no swap to fall back to: a projection that
    // does not fit degrades to the plain no-sequencing run (still never a
    // refusal), and the toggle-ON path sequences regardless of the projection.

    @Test("coexistence (toggle OFF): tight reclaimable RAM falls back to the no-sequencing run")
    func coexistenceTightRAMFallsBack() throws {
        var inputs = roomyCoexistence()
        // 10 GB * 1.3 + 3 GB headroom = 16 GB needed; only 12 GB available.
        inputs.availableBytes = 12 * 1_073_741_824
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: tenGB,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            coexistence: inputs
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.coexists == false)
        #expect(plan.sequencingDisabled == true)
    }

    @Test("coexistence (toggle OFF): exceeding the flexible resident budget falls back (runtime would evict)")
    func coexistenceOverFlexibleBudgetFallsBack() throws {
        var inputs = roomyCoexistence()
        // resident 8 GB + incoming 10 GB > 16 GB cap → the runtime's own
        // budget eviction would evict the orchestrator with no restore lease.
        inputs.flexibleBudgetBytes = 16 * 1_073_741_824
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: tenGB,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            coexistence: inputs
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.coexists == false)
        #expect(plan.sequencingDisabled == true)
    }

    @Test("coexistence (toggle OFF): Memory Safety target-load refusal falls back before loading")
    func coexistenceMemorySafetyRefusalFallsBack() throws {
        var inputs = roomyCoexistence()
        inputs.memorySafetyAllowsTargetLoad = false
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: tenGB,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            coexistence: inputs
        )
        #expect(!plan.shouldUnload)
        #expect(!plan.coexists)
        #expect(plan.sequencingDisabled)
    }

    @Test("coexistence (toggle OFF): unknown model size cannot prove the fit → no-sequencing run")
    func coexistenceUnknownSizeFallsBack() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 0,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            coexistence: roomyCoexistence()
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.coexists == false)
        #expect(plan.sequencingDisabled == true)
    }

    @Test("coexistence is the toggle-OFF alternative: applies with the handoff OFF (nothing is unloaded)")
    func coexistenceBypassesHandoffToggle() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: tenGB,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            coexistence: roomyCoexistence()
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.coexists == true)
    }

    @Test("coexistence never fires for same-model or remote targets")
    func coexistenceIrrelevantForSameOrRemote() throws {
        let same = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-a",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: tenGB,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            coexistence: roomyCoexistence()
        )
        #expect(same.coexists == false)

        let remote = try SubagentResidency.decidePlan(
            isLocal: false,
            modelName: "xai/grok-4.3",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: tenGB,
            idleWaitSeconds: 90,
            deniedMessage: denied,
            coexistence: roomyCoexistence()
        )
        #expect(remote.coexists == false)
    }

    @Test("admission class: coexist and unload plans are exclusive; in-place shares; remote never contends")
    func admissionClassMapping() {
        #expect(
            SubagentResidency.admissionClass(
                isLocal: true,
                plan: ResidencyPlan(shouldUnload: true)
            ) == .localExclusive
        )
        #expect(
            SubagentResidency.admissionClass(
                isLocal: true,
                plan: ResidencyPlan(shouldUnload: false, coexists: true)
            ) == .localExclusive
        )
        #expect(
            SubagentResidency.admissionClass(isLocal: true, plan: .none) == .localInPlace
        )
        #expect(
            SubagentResidency.admissionClass(isLocal: false, plan: .none) == .remote
        )
    }

    @Test("coexistence handoff: waits for idle then runs; a busy GPU refuses the run")
    func coexistenceHandoffIdleGate() async throws {
        let scope = SubagentScope(
            sessionId: "coexist-test",
            toolCallId: "call-1",
            agentId: UUID()
        )
        let resolved = ResolvedModel(name: "local-b", isLocal: true)
        let feed = SubagentFeed(toolCallId: "call-1", kindId: "spawn", title: "test")

        let ranBody = CoexistenceProbe()
        let idle = CoexistenceHandoff(maxElapsedSeconds: 30, waitForIdle: { _ in true })
        let result = try await idle.around(scope: scope, resolved: resolved, feed: feed) {
            ranBody.mark()
            return SubagentResult(payload: ["ok": true], summary: "done")
        }
        #expect(result.summary == "done")
        #expect(ranBody.wasMarked)

        let busy = CoexistenceHandoff(maxElapsedSeconds: 30, waitForIdle: { _ in false })
        do {
            _ = try await busy.around(scope: scope, resolved: resolved, feed: feed) {
                Issue.record("body must not run when the idle wait fails")
                return SubagentResult(payload: [:], summary: "")
            }
            Issue.record("expected an unavailable error")
        } catch let error as SubagentError {
            guard case .unavailable = error else {
                Issue.record("expected .unavailable, got \(error)")
                return
            }
        }
    }

    // MARK: - Named four-direction proof
    //
    // The same `decidePlan` outcomes above, restated as the FOUR
    // orchestrator→target residency directions the live `spawn_model_residency`
    // lane exercises end-to-end, so "all four directions" is legible and
    // asserted by name. `isLocal` is the TARGET's residency; `residentChatModels`
    // models the ORCHESTRATOR (a remote orchestrator has no resident local chat
    // model, so it is `[]`). Only local→local with a different model does real
    // work — every other direction runs in place.

    @Test("direction local→local (same model): run in place, no swap")
    func directionLocalToLocalSame() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-a",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
    }

    @Test("direction local→local (different, handoff ON): unload then reload")
    func directionLocalToLocalDifferentOn() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == true)
    }

    @Test("direction local→local (different, handoff OFF): runs with no sequencing, never refused")
    func directionLocalToLocalDifferentOff() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: ["local-a"],
            handoffEnabled: false,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
        #expect(plan.sequencingDisabled == true)
    }

    @Test("direction local→remote: remote target never touches local GPU")
    func directionLocalToRemote() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: false,
            modelName: "xai/grok-4.3",
            residentChatModels: ["local-a"],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
    }

    @Test("direction remote→local: remote orchestrator has no resident local to evict")
    func directionRemoteToLocal() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: true,
            modelName: "local-b",
            residentChatModels: [],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
    }

    @Test("direction remote→remote: nothing local in play")
    func directionRemoteToRemote() throws {
        let plan = try SubagentResidency.decidePlan(
            isLocal: false,
            modelName: "xai/grok-4.3",
            residentChatModels: [],
            handoffEnabled: true,
            ramSafetyEnabled: true,
            requiredBytes: 4096,
            idleWaitSeconds: 90,
            deniedMessage: denied
        )
        #expect(plan.shouldUnload == false)
    }
}

/// Tiny thread-safe flag for the handoff body probe.
private final class CoexistenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() {
        lock.lock()
        defer { lock.unlock() }
        marked = true
    }
    var wasMarked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return marked
    }
}
